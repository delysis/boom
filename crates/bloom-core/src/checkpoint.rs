//! Immutable published model descriptions. No cache, network, or GPU authority.
use crate::{Error, require};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

const GIB: u64 = 1_073_741_824;
const CHUNK_BYTES: u64 = 33_554_432;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct File {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Checkpoint {
    pub purpose: Purpose,
    pub repository: String,
    pub revision: String,
    pub files: Vec<File>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Consultation,
    Writing,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Requirements {
    pub identity: String,
    pub weight_bytes: u64,
    pub download_bytes: u64,
    pub disk_bytes: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferRange {
    pub first: u64,
    pub last: u64,
    pub bytes: u64,
    pub content_range: String,
}

pub fn transfer_range(file_bytes: u64, offset: u64) -> Result<TransferRange, Error> {
    require(
        file_bytes > 0 && file_bytes <= 64 * GIB && offset < file_bytes,
        "A model transfer needs a bounded file and an unfinished offset.",
    )?;
    let bytes = (file_bytes - offset).min(CHUNK_BYTES);
    let last = offset + bytes - 1;
    Ok(TransferRange {
        first: offset,
        last,
        bytes,
        content_range: format!("bytes {offset}-{last}/{file_bytes}"),
    })
}

pub fn admit_response(
    file_bytes: u64,
    offset: u64,
    status: u16,
    content_range: Option<&str>,
    content_length: Option<u64>,
) -> Result<bool, Error> {
    let range = transfer_range(file_bytes, offset)?;
    require(
        (status == 206 && content_range == Some(range.content_range.as_str()))
            || (status == 200 && offset == 0 && range.bytes == file_bytes),
        "The server did not honor the bounded model range.",
    )?;
    require(
        content_length.is_none_or(|length| length == range.bytes),
        "The model response length differs from the requested range.",
    )?;
    Ok(true)
}

fn name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && !value.starts_with('.')
        && !value.contains("..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
}

fn hash(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn requirements(checkpoint: &Checkpoint) -> Result<Requirements, Error> {
    let parts: Vec<_> = checkpoint.repository.split('/').collect();
    require(
        parts.len() == 2 && parts.iter().all(|part| name(part)),
        "A published model needs one repository owner and name.",
    )?;
    require(
        hash(&checkpoint.revision, 40),
        "A published model needs an immutable revision.",
    )?;
    require(
        (1..=64).contains(&checkpoint.files.len()),
        "A published model needs 1–64 files.",
    )?;
    let mut names = BTreeSet::new();
    let mut download_bytes = 0_u64;
    let mut weight_bytes = 0_u64;
    for file in &checkpoint.files {
        require(
            name(&file.path) && names.insert(file.path.as_str()),
            "Model file names must be unique, plain root-level names.",
        )?;
        require(
            file.path.ends_with(".safetensors")
                || file.path.ends_with(".json")
                || [
                    "README.md",
                    "LICENSE",
                    "LICENSE.txt",
                    "NOTICE",
                    "NOTICE.txt",
                    "chat_template.jinja",
                ]
                .contains(&file.path.as_str()),
            "Published model files must be data or notices.",
        )?;
        require(
            (1..=64 * GIB).contains(&file.bytes) && hash(&file.sha256, 64),
            "A model file needs bounded bytes and an exact SHA-256.",
        )?;
        download_bytes = download_bytes
            .checked_add(file.bytes)
            .ok_or_else(|| Error("Model download size overflow.".into()))?;
        if file.path.ends_with(".safetensors") {
            weight_bytes = weight_bytes
                .checked_add(file.bytes)
                .ok_or_else(|| Error("Model weight size overflow.".into()))?;
        }
    }
    require(
        download_bytes <= 64 * GIB && weight_bytes > 0,
        "A published model needs safetensors within its download bound.",
    )?;
    for required in [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "generation_config.json",
        "processor_config.json",
    ] {
        require(
            names.contains(required),
            "Published model configuration is incomplete.",
        )?;
    }
    Ok(Requirements {
        identity: format!("{}@{}", checkpoint.repository, checkpoint.revision),
        weight_bytes,
        download_bytes,
        // One bounded URLSession file can coexist with a fully verified partial.
        disk_bytes: download_bytes + 2 * CHUNK_BYTES,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Checkpoint {
        Checkpoint {
            purpose: Purpose::Writing,
            repository: "mlx-community/gemma-4-12B-4bit".into(),
            revision: "a".repeat(40),
            files: [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "generation_config.json",
                "processor_config.json",
                "model.safetensors",
            ]
            .into_iter()
            .map(|path| File {
                path: path.into(),
                bytes: 10,
                sha256: "b".repeat(64),
            })
            .collect(),
        }
    }
    #[test]
    fn requirements_count_all_files_and_bound_transfer_overlap() -> Result<(), Error> {
        let value = requirements(&fixture())?;
        assert_eq!(value.weight_bytes, 10);
        assert_eq!(value.download_bytes, 60);
        assert_eq!(value.disk_bytes, 60 + 2 * CHUNK_BYTES);
        assert_eq!(
            value.identity,
            format!("mlx-community/gemma-4-12B-4bit@{}", "a".repeat(40))
        );
        Ok(())
    }
    #[test]
    fn rejects_mutable_revisions_paths_scripts_missing_files_and_bad_hashes() {
        let mut value = fixture();
        value.revision = "main".into();
        assert!(requirements(&value).is_err());
        for path in [
            "../config.json",
            "/config.json",
            ".gitattributes",
            "model.py",
            "config.json",
        ] {
            let mut value = fixture();
            value.files[5].path = path.into();
            assert!(requirements(&value).is_err());
        }
        let mut value = fixture();
        value.files.remove(0);
        assert!(requirements(&value).is_err());
        let mut value = fixture();
        value.files[0].sha256 = "g".repeat(64);
        assert!(requirements(&value).is_err());
        let mut value = fixture();
        value.files[0].bytes = u64::MAX;
        assert!(requirements(&value).is_err());
    }

    #[test]
    fn resumed_ranges_and_server_responses_are_exact_and_bounded() -> Result<(), Error> {
        let total = 2 * CHUNK_BYTES + 7;
        let range = transfer_range(total, CHUNK_BYTES)?;
        assert_eq!(range.first, CHUNK_BYTES);
        assert_eq!(range.last, 2 * CHUNK_BYTES - 1);
        assert_eq!(range.bytes, CHUNK_BYTES);
        assert!(admit_response(
            total,
            CHUNK_BYTES,
            206,
            Some(&range.content_range),
            Some(CHUNK_BYTES)
        )?);
        assert_eq!(transfer_range(total, 2 * CHUNK_BYTES)?.bytes, 7);
        assert!(admit_response(355, 0, 200, None, Some(355))?);
        assert!(admit_response(total, 0, 200, None, Some(total)).is_err());
        assert!(admit_response(total, CHUNK_BYTES, 206, Some("bytes 0-1/2"), None).is_err());
        assert!(
            admit_response(
                total,
                CHUNK_BYTES,
                206,
                Some(&range.content_range),
                Some(CHUNK_BYTES + 1)
            )
            .is_err()
        );
        assert!(transfer_range(total, total).is_err());
        Ok(())
    }
}
