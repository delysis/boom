//! Bounded public-fixture audit. Never scans a user's ordinary workspace or
//! system caches. Plaintext controls are explicit diagnostic/export artifacts.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashSet},
    error::Error,
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const MAX_FILE: u64 = 134_217_728;
const MAX_TOTAL: u64 = 536_870_912;
const WIDTH: usize = 32;

fn require(condition: bool, message: &str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn read(path: &Path) -> Result<Vec<u8>> {
    let info = fs::symlink_metadata(path)?;
    require(
        info.is_file() && info.len() <= MAX_FILE,
        "Unsafe or oversized audit file",
    )?;
    Ok(fs::read(path)?)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn collect_strings(value: &Value, strings: &mut BTreeSet<String>) {
    match value {
        Value::String(text) if text.chars().count() >= 32 && text.contains(char::is_whitespace) => {
            strings.insert(text.clone());
        }
        Value::Array(values) => {
            for value in values {
                collect_strings(value, strings);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                collect_strings(value, strings);
            }
        }
        _ => {}
    }
}
fn encodings(text: &str) -> Result<Vec<Vec<u8>>> {
    let quoted = serde_json::to_string(text)?;
    Ok(vec![
        text.as_bytes().to_vec(),
        text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
        text.encode_utf16().flat_map(u16::to_be_bytes).collect(),
        quoted.as_bytes()[1..quoted.len() - 1].to_vec(),
        quoted[1..quoted.len() - 1].replace('/', "\\/").into_bytes(),
    ])
}
fn needles(strings: &BTreeSet<String>) -> Result<HashSet<[u8; WIDTH]>> {
    let mut result = HashSet::new();
    for text in strings {
        for encoded in encodings(text)? {
            for chunk in encoded.chunks_exact(WIDTH) {
                result.insert(chunk.try_into()?);
            }
        }
    }
    require(
        !result.is_empty() && result.len() <= 20_000,
        "Empty or oversized canary set",
    )?;
    Ok(result)
}
fn detected(bytes: &[u8], needles: &HashSet<[u8; WIDTH]>) -> bool {
    bytes
        .windows(WIDTH)
        .any(|window| <&[u8; WIDTH]>::try_from(window).is_ok_and(|piece| needles.contains(piece)))
}
fn walk(root: &Path, files: &mut Vec<PathBuf>, total: &mut u64, depth: usize) -> Result<()> {
    require(depth <= 16, "Audit directory nesting exceeds its limit")?;
    require(
        fs::symlink_metadata(root)?.is_dir(),
        "Audit root is not a real directory",
    )?;
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let info = entry.file_type()?;
        if info.is_dir() {
            walk(&entry.path(), files, total, depth + 1)?;
        } else {
            require(info.is_file(), "Audit entry is not a regular file")?;
            let bytes = entry.metadata()?.len();
            *total = total
                .checked_add(bytes)
                .ok_or_else(|| io::Error::other("Audit size overflow"))?;
            require(
                bytes <= MAX_FILE && *total <= MAX_TOTAL && files.len() < 10_000,
                "Audit inventory exceeds its limits",
            )?;
            files.push(entry.path());
        }
    }
    Ok(())
}
fn main() -> Result<()> {
    let args = std::env::args_os().skip(1).collect::<Vec<_>>();
    require(
        args.len() == 2,
        "Use bloom-private-files ABS_PUBLIC_FIXTURE ABS_NEW_REPORT",
    )?;
    let root = Path::new(&args[0]);
    let report = Path::new(&args[1]);
    let name = root
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or_default();
    require(
        root.is_absolute()
            && report.is_absolute()
            && !report.exists()
            && root
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|v| v == "work")
            && ["window-privacy-", "explicit-export-"]
                .iter()
                .any(|v| name.starts_with(v)),
        "Require an owned named public fixture and a fresh absolute report",
    )?;
    require(
        fs::symlink_metadata(root)?.is_dir(),
        "Fixture is not a real directory",
    )?;
    let verification: Value = serde_json::from_slice(&read(&root.join("verification.json"))?)?;
    require(
        verification["status"] == "passed" && verification["real_keychain_qualified"] == false,
        "Native fixture verification is missing or failed",
    )?;
    let mut strings = BTreeSet::new();
    let capture = root.join("capture.json");
    let controls = if capture.exists() {
        collect_strings(
            &serde_json::from_slice::<Value>(&read(&capture)?)?,
            &mut strings,
        );
        vec![capture]
    } else {
        require(
            verification["save_panel_interaction_qualified"] == false
                && verification["keychain_lookups"] == 0,
            "Expected the public explicit-export fixture",
        )?;
        let voice = root.join("explicit-exports/voice.json");
        collect_strings(
            &serde_json::from_slice::<Value>(&read(&voice)?)?,
            &mut strings,
        );
        let document = root.join("explicit-exports/document.md");
        let text = String::from_utf8(read(&document)?)?;
        strings.insert(text);
        strings.insert(
            "Public export later-edit canary: this stays in the encrypted manuscript.".to_owned(),
        );
        vec![voice, document, root.join("explicit-exports/original.bin")]
    };
    let patterns = needles(&strings)?;
    let mut positive_controls = Vec::new();
    for control in controls {
        let bytes = read(&control)?;
        require(
            detected(&bytes, &patterns),
            "Plaintext positive control did not trigger",
        )?;
        positive_controls.push(
            json!({"file":control.strip_prefix(root)?, "sha256":digest(&bytes), "detected":true}),
        );
    }
    // Detect each exercised representation independently before inspecting
    // ciphertext. A detector that simply returns false cannot pass this audit.
    for text in &strings {
        for bytes in encodings(text)? {
            require(
                detected(&bytes, &patterns),
                "Encoding control did not trigger",
            )?;
        }
    }
    let mut files = Vec::new();
    let mut total = 0;
    for directory in ["encrypted-workspace", "restored-workspace"] {
        walk(&root.join(directory), &mut files, &mut total, 0)?;
    }
    files.push(root.join("complete.bloombackup"));
    for suffix in [
        "capture.log",
        "verify.log",
        "native.stdout",
        "native.stderr",
    ] {
        let path = root.join(suffix);
        if path.exists() {
            files.push(path);
        }
    }
    let mut inventory = Vec::new();
    let mut leaks = Vec::new();
    let mut scanned_bytes = 0_u64;
    files.sort();
    for file in &files {
        let bytes = read(file)?;
        scanned_bytes = scanned_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| io::Error::other("Audit size overflow"))?;
        require(
            scanned_bytes <= MAX_TOTAL,
            "Audit file total exceeds its limit",
        )?;
        let relative = file.strip_prefix(root)?;
        let leak = detected(&bytes, &patterns);
        if leak {
            leaks.push(relative.to_path_buf());
        }
        inventory.push(json!({"file":relative, "bytes":bytes.len(), "sha256":digest(&bytes), "canary_detected":leak}));
    }
    let result = json!({"status":if leaks.is_empty(){"passed"}else{"failed"},
        "source_inventory_sha256":verification["source_inventory_sha256"],
        "fixture":name, "scanned_bytes":scanned_bytes, "canary_strings":strings.len(), "fragments":patterns.len(), "fragment_bytes":WIDTH,
        "representations":["utf8", "utf16le", "utf16be", "json_literal", "json_escaped_slash"],
        "positive_controls":positive_controls, "files":inventory, "leaks":leaks,
        "scope":"owned encrypted workspace roots, complete backup and present fixture logs; public explicit controls excluded",
        "all_encodings_qualified":false, "os_caches_qualified":false, "real_keychain_qualified":false});
    let bytes = serde_json::to_vec_pretty(&result)?;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(report)?
        .write_all(&bytes)?;
    require(
        leaks.is_empty(),
        "Plaintext fragments found; failed audit retained",
    )?;
    println!(
        "{} files checked against {} canary fragments; all positive controls triggered.",
        files.len(),
        patterns.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn byte_scanner_detects_unicode_encodings_and_escaped_json_at_any_offset() -> Result<()> {
        let strings = BTreeSet::from([
            "Private fixture Café 👩🏽‍💻, quote \" and newline\n plus /path, after the caret."
                .to_owned(),
        ]);
        let patterns = needles(&strings)?;
        for text in &strings {
            for bytes in encodings(text)? {
                let mut wrapped = vec![0xa5; 17];
                wrapped.extend(bytes);
                wrapped.extend([0xa5; 29]);
                assert!(detected(&wrapped, &patterns));
            }
        }
        assert!(!detected(&[0xa5; 4096], &patterns));
        Ok(())
    }
    #[test]
    fn walker_refuses_symbolic_links_before_reading_the_target() -> Result<()> {
        let root =
            std::env::temp_dir().join(format!("bloom-private-scan-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root)?;
        let result = (|| {
            std::os::unix::fs::symlink("absent-private-target", root.join("link"))?;
            let mut files = Vec::new();
            let mut total = 0;
            require(
                walk(&root, &mut files, &mut total, 0).is_err() && files.is_empty(),
                "Symbolic link was admitted",
            )
        })();
        fs::remove_dir_all(&root)?;
        result
    }
}
