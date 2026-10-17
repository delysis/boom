//! Speech/assistant packages use the same transfer and immutable-file contract
//! as conversational checkpoints. Their I/O requirements are not Gemma chat's.
use crate::{Error, checkpoint, require};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AssetKind {
    Qwen,
    Mtp,
    Turn,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AssetPackage {
    pub id: AssetKind,
    pub repository: String,
    pub revision: String,
    pub files: Vec<checkpoint::File>,
}

pub fn requirements(package: &AssetPackage) -> Result<checkpoint::Requirements, Error> {
    let name = |v: &str| {
        !v.is_empty()
            && v.len() <= 160
            && !v.starts_with('.')
            && !v.contains("..")
            && v.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    let hash = |v: &str, n| {
        v.len() == n
            && v.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    let repository: Vec<_> = package.repository.split('/').collect();
    require(
        repository.len() == 2 && repository.iter().all(|v| name(v)),
        "Invalid model repository.",
    )?;
    require(
        hash(&package.revision, 40),
        "Model revision must be an immutable commit.",
    )?;
    require(
        (1..=256).contains(&package.files.len()),
        "Model package file bound exceeded.",
    )?;
    let mut paths = BTreeSet::new();
    let mut download = 0_u64;
    let mut weights = 0_u64;
    for file in &package.files {
        require(
            file.path.len() <= 1024
                && file.path.split('/').all(name)
                && paths.insert(file.path.as_str()),
            "Model file paths must be unique bounded relative data paths.",
        )?;
        require(
            file.bytes > 0 && file.bytes <= 64 << 30 && hash(&file.sha256, 64),
            "Invalid file identity.",
        )?;
        let allowed = match package.id {
            AssetKind::Turn => {
                file.path.starts_with("smart_turn.mlmodelc/")
                    || file.path == "config.json"
                    || ["README.md", "LICENSE", "LICENSE.txt"].contains(&file.path.as_str())
            }
            AssetKind::Qwen | AssetKind::Mtp => {
                file.path.ends_with(".safetensors")
                    || file.path.ends_with(".json")
                    || [
                        "README.md",
                        "LICENSE",
                        "LICENSE.txt",
                        "NOTICE",
                        "merges.txt",
                        "vocab.json",
                        "chat_template.jinja",
                    ]
                    .contains(&file.path.as_str())
            }
        };
        require(allowed, "The package contains an unsupported file kind.")?;
        download = download
            .checked_add(file.bytes)
            .ok_or_else(|| Error("Package size overflow.".into()))?;
        if file.path.ends_with(".safetensors") || file.path.starts_with("smart_turn.mlmodelc/") {
            weights = weights
                .checked_add(file.bytes)
                .ok_or_else(|| Error("Package weight size overflow.".into()))?;
        }
    }
    require(
        download <= 64 << 30 && weights > 0 && paths.contains("config.json"),
        "Model package is incomplete or oversized.",
    )?;
    let required: &[&str] = match package.id {
        AssetKind::Qwen => &[
            "model.safetensors",
            "vocab.json",
            "merges.txt",
            "speech_tokenizer/model.safetensors",
            "speech_tokenizer/config.json",
        ],
        AssetKind::Mtp => &[],
        AssetKind::Turn => &[],
    };
    require(
        required.iter().all(|p| paths.contains(p)),
        "Speech package configuration is incomplete.",
    )?;
    // No listed file may also be a directory of another listed file.
    for path in &paths {
        let components: Vec<_> = path.split('/').collect();
        for end in 1..components.len() {
            require(
                !paths.contains(components[..end].join("/").as_str()),
                "File/directory collision in model package.",
            )?;
        }
    }
    Ok(checkpoint::Requirements {
        identity: format!("{}@{}", package.repository, package.revision),
        weight_bytes: weights,
        download_bytes: download,
        disk_bytes: download + (64 << 20),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn package() -> AssetPackage {
        AssetPackage {
            id: AssetKind::Turn,
            repository: "aufklarer/Smart-Turn-v3.2-CoreML".into(),
            revision: "a".repeat(40),
            files: [
                "config.json",
                "smart_turn.mlmodelc/model.mil",
                "smart_turn.mlmodelc/weights/weight.bin",
            ]
            .iter()
            .map(|path| checkpoint::File {
                path: (*path).into(),
                bytes: 128,
                sha256: "b".repeat(64),
            })
            .collect(),
        }
    }
    #[test]
    fn compiled_turn_packages_are_bounded_data_not_chat_models() {
        assert!(requirements(&package()).is_ok());
        for path in [
            "../model.mil",
            "smart_turn.mlmodelc/../model.mil",
            "/model.mil",
            "smart_turn.mlmodelc//a",
            "script.py",
        ] {
            let mut p = package();
            p.files[1].path = path.into();
            assert!(requirements(&p).is_err(), "{path}");
        }
    }
    #[test]
    fn root_file_and_nested_parent_cannot_collide() {
        let mut p = package();
        p.files[1].path = "smart_turn.mlmodelc/weights".into();
        assert!(requirements(&p).is_err());
    }
}
