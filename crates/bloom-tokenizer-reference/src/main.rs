//! Offline developer reference using Hugging Face's independent Rust tokenizer.
//! This executable is not linked into the native application.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{error::Error, fs, io, path::Path};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
fn require(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn read(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let metadata = fs::metadata(path)?;
    require(
        metadata.is_file() && metadata.len() <= limit,
        "Reference input exceeds its file bound",
    )?;
    let bytes = fs::read(path)?;
    require(
        bytes.len() as u64 <= limit,
        "Reference input changed beyond its file bound",
    )?;
    Ok(bytes)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn main() -> Result<()> {
    let arguments: Vec<_> = std::env::args().collect();
    require(
        arguments.len() == 4
            && ["encode", "decode"].contains(&arguments[2].as_str())
            && Path::new(&arguments[1]).is_absolute()
            && Path::new(&arguments[3]).is_absolute(),
        "Use absolute TOKENIZER_JSON encode|decode ABSOLUTE_INPUT_FILE",
    )?;
    let description = read(Path::new(&arguments[1]), 64 << 20)?;
    let input = read(Path::new(&arguments[3]), 4 << 20)?;
    let tokenizer = tokenizers::Tokenizer::from_bytes(&description)
        .map_err(|e| io::Error::other(e.to_string()))?;
    let mut receipt = json!({"schema":1, "reference":"huggingface-tokenizers-rust-0.22.2",
        "tokenizer_sha256": digest(&description), "input_sha256":digest(&input),
        "operation":arguments[2], "network_features_enabled":false});
    if arguments[2] == "encode" {
        let text = std::str::from_utf8(&input)?;
        let processed = tokenizer
            .encode(text, true)
            .map_err(|e| io::Error::other(e.to_string()))?;
        let raw = tokenizer
            .encode(text, false)
            .map_err(|e| io::Error::other(e.to_string()))?;
        let empty = tokenizer
            .encode("", true)
            .map_err(|e| io::Error::other(e.to_string()))?;
        receipt["input_processing"] = json!("checkpoint_postprocessed_v1");
        receipt["token_ids"] = json!(processed.get_ids());
        receipt["token_count"] = json!(processed.len());
        receipt["prompt_digest"] = json!(digest(&serde_json::to_vec(processed.get_ids())?));
        receipt["empty_input_token_ids"] = json!(empty.get_ids());
        receipt["without_special_token_count"] = json!(raw.len());
        receipt["without_special_prompt_digest"] =
            json!(digest(&serde_json::to_vec(raw.get_ids())?));
        // Bloom's Rust compiler supplies the boundary explicitly. Compare the
        // whole compilation path, rather than inferring it from an encode flag.
        if let Some(authored) = text.strip_prefix("<bos>") {
            let canonical = tokenizer
                .encode(authored, true)
                .map_err(|e| io::Error::other(e.to_string()))?;
            receipt["compiled_writing_comparison"] = json!({
                "authored_input_sha256": digest(authored.as_bytes()),
                "checkpoint_token_count": canonical.len(),
                "checkpoint_prompt_digest": digest(&serde_json::to_vec(canonical.get_ids())?),
                "matches_checkpoint_postprocessing": raw.get_ids() == canonical.get_ids(),
                "compiled_first_token": raw.get_ids().first(),
                "checkpoint_first_token": canonical.get_ids().first(),
            });
        }
    } else {
        let ids: Vec<u32> = serde_json::from_slice(&input)?;
        require(
            ids.len() <= 262_144 && ids.iter().all(|id| tokenizer.id_to_token(*id).is_some()),
            "Reference token IDs exceed their bound or vocabulary",
        )?;
        receipt["token_count"] = json!(ids.len());
        receipt["text"] = Value::String(
            tokenizer
                .decode(&ids, false)
                .map_err(|e| io::Error::other(e.to_string()))?,
        );
    }
    println!("{}", serde_json::to_string_pretty(&receipt)?);
    Ok(())
}
