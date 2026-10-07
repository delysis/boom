//! Independent, read-only authenticated-record verification. No plaintext,
//! keys or decrypted JSON are written to disk or standard output.
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    error::Error,
    fs,
    io::{self, Write},
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
type Result<T> = std::result::Result<T, Box<dyn Error>>;
const FILE_LIMIT: u64 = 134_217_728;
const TOTAL_LIMIT: u64 = 536_870_912;
fn require(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn read(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let info = fs::symlink_metadata(path)?;
    require(
        info.is_file() && info.len() <= limit,
        "Unsafe or oversized verifier input",
    )?;
    let bytes = fs::read(path)?;
    require(
        bytes.len() as u64 <= limit,
        "Verifier input changed beyond its bound",
    )?;
    Ok(bytes)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn plist_json(value: &plist::Value, depth: usize) -> Result<Value> {
    require(depth <= 128, "Structured record exceeds its nesting bound")?;
    Ok(match value {
        plist::Value::Dictionary(values) => {
            let mut object = serde_json::Map::new();
            for (key, value) in values {
                object.insert(key.clone(), plist_json(value, depth + 1)?);
            }
            Value::Object(object)
        }
        plist::Value::Array(values) => Value::Array(
            values
                .iter()
                .map(|v| plist_json(v, depth + 1))
                .collect::<Result<_>>()?,
        ),
        plist::Value::String(value) => json!(value),
        plist::Value::Boolean(value) => json!(value),
        plist::Value::Integer(value) => {
            if let Some(unsigned) = value.as_unsigned() {
                json!(unsigned)
            } else {
                json!(
                    value.as_signed().ok_or_else(|| io::Error::other(
                        "Structured integer exceeds JSON precision"
                    ))?
                )
            }
        }
        plist::Value::Real(value) => Value::Number(
            serde_json::Number::from_f64(*value)
                .ok_or_else(|| io::Error::other("Nonfinite structured number"))?,
        ),
        // Foundation's default JSON encoding uses base64 data and seconds from
        // 2001-01-01 for Date; reproduce those representations without export.
        plist::Value::Data(value) => json!(STANDARD.encode(value)),
        plist::Value::Date(value) => {
            let time: SystemTime = (*value).into();
            let seconds = match time.duration_since(UNIX_EPOCH) {
                Ok(duration) => duration.as_secs_f64(),
                Err(error) => -error.duration().as_secs_f64(),
            };
            json!(seconds - 978_307_200.0)
        }
        _ => return Err(io::Error::other("Unsupported structured record value").into()),
    })
}
fn structured_digest(plaintext: &[u8]) -> Result<Option<String>> {
    let value = if plaintext.starts_with(b"bplist00") {
        let value = plist::Value::from_reader(io::Cursor::new(plaintext))?;
        plist_json(&value, 0)?
    } else if let Ok(value) = serde_json::from_slice::<Value>(plaintext) {
        value
    } else {
        return Ok(None);
    };
    Ok(Some(bloom_vault_reference::canonical_digest(value)?))
}
fn audit(root: &Path, cipher: &Aes256Gcm, records: &mut Vec<Value>) -> Result<()> {
    require(
        fs::symlink_metadata(root)?.is_dir(),
        "Record root must be a real directory",
    )?;
    let mut entries = fs::read_dir(root)?.collect::<std::result::Result<Vec<_>, _>>()?;
    require(
        !entries.is_empty() && entries.len() <= 10_000,
        "Empty or excessive record inventory",
    )?;
    entries.sort_by_key(|entry| entry.file_name());
    let mut total = 0_u64;
    for entry in entries {
        let name = entry.file_name();
        let name = name
            .to_str()
            .ok_or_else(|| io::Error::other("Non-UTF-8 record identity"))?;
        let stem = name
            .strip_suffix(".sealed")
            .ok_or_else(|| io::Error::other("Unexpected record extension"))?;
        let (kind, id) = stem
            .split_once('-')
            .ok_or_else(|| io::Error::other("Missing record identity"))?;
        require(
            [
                "workspace",
                "document",
                "attachment",
                "receipt",
                "candidate",
                "editJournal",
                "saveJournal",
                "generationJournal",
            ]
            .contains(&kind),
            "Unknown authenticated record kind",
        )?;
        let identity = Uuid::parse_str(id)?;
        require(
            identity.hyphenated().to_string().to_uppercase() == id,
            "Noncanonical record identity",
        )?;
        let bytes = read(&entry.path(), FILE_LIMIT)?;
        total = total
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| io::Error::other("Record size overflow"))?;
        require(
            total <= TOTAL_LIMIT && bytes.len() >= 28,
            "Record size exceeds the verifier bound",
        )?;
        let aad = format!("bloom/v1/{kind}/{id}");
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&bytes[..12]),
                Payload {
                    msg: &bytes[12..],
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|_| io::Error::other("Authenticated record verification failed"))?;
        // Native documents and originals are raw bytes; a manuscript that
        // begins with a plist or JSON marker is still authored text.
        let canonical_json_sha256 = if ["document", "attachment"].contains(&kind) {
            None
        } else {
            structured_digest(&plaintext)?
        };
        records.push(json!({"kind":kind,"id":id,"authenticated":true,
            "ciphertext_sha256":digest(&bytes),"plaintext_sha256":digest(&plaintext),
            "plaintext_bytes":plaintext.len(),"canonical_json_sha256":canonical_json_sha256}));
    }
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    require(
        args.len() == 4 && args[1..].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute RECORD_DIRECTORY KEY_FILE NEW_REPORT_JSON",
    )?;
    let report = Path::new(&args[3]);
    require(!report.exists(), "Refuse to replace a verification report")?;
    let key = read(Path::new(&args[2]), 32)?;
    require(
        key.len() == 32,
        "Require an explicit 32-byte verifier key file",
    )?;
    let cipher =
        Aes256Gcm::new_from_slice(&key).map_err(|_| io::Error::other("Invalid verifier key"))?;
    let mut records = Vec::new();
    let result = audit(Path::new(&args[1]), &cipher, &mut records);
    let receipt = json!({"schema":1,"reference":"rustcrypto-aes-gcm-0.10.3",
        "status":if result.is_ok() {"passed"} else {"failed"},"complete":result.is_ok(),
        "error":result.as_ref().err().map(ToString::to_string),"records":records,
        "plaintext_exported":false,"keychain_accessed":false,"network_features_enabled":false,
        "canonicalization":"sorted_json_native_float32_sampling_v1",
        "scope":"authenticated native-record verification; key ownership and OS caches not qualified"});
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(report)?
        .write_all(&serde_json::to_vec_pretty(&receipt)?)?;
    result?;
    println!(
        "Authenticated {} native encrypted records; plaintext was not exported",
        records.len()
    );
    Ok(())
}
