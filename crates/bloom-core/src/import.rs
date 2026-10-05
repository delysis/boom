//! Validate a captured folder import before any encrypted records are admitted.
use super::{Error, TEXT_LIMIT, require};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use uuid::Uuid;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ImportedText {
    pub path: String,
    pub text: String,
}

pub fn validate_import(files: Vec<ImportedText>) -> Result<Vec<ImportedText>, Error> {
    validate_files(files, true)
}

pub fn validate_documents(files: Vec<ImportedText>) -> Result<Vec<ImportedText>, Error> {
    validate_files(files, false)
}

fn validate_path(path: &str, from_folder: bool) -> Result<(), Error> {
    let components: Vec<_> = path.split('/').collect();
    require(
        path.len() <= 4096
            && components.len() <= if from_folder { 16 } else { 1 }
            && components.iter().all(|part| {
                !part.is_empty()
                    && ![".", ".."].contains(part)
                    && !part.chars().any(|c| c.is_control() || c == '\\')
            }),
        "An imported file has an invalid relative path.",
    )?;
    if from_folder {
        let extension = path.rsplit('.').next().unwrap_or_default();
        require(
            ["md", "markdown", "txt"]
                .iter()
                .any(|e| extension.eq_ignore_ascii_case(e)),
            "Folder import supports Markdown and plain text files.",
        )?;
    }
    Ok(())
}

fn validate_files(files: Vec<ImportedText>, from_folder: bool) -> Result<Vec<ImportedText>, Error> {
    validate_budget(files.len(), 0)?;
    let mut paths = HashSet::new();
    let mut total = 0_usize;
    for file in &files {
        validate_path(&file.path, from_folder)?;
        require(
            !from_folder || paths.insert(&file.path),
            "The import repeats a file path.",
        )?;
        require(
            file.text.len() <= TEXT_LIMIT && !file.text.contains('\0'),
            "An imported document exceeds 2 MiB or contains a null character.",
        )?;
        total = total.saturating_add(file.text.len());
        validate_budget(files.len(), total)?;
    }
    Ok(files)
}

pub fn validate_budget(files: usize, bytes: usize) -> Result<bool, Error> {
    require(
        (1..=512).contains(&files),
        "Import 1 to 512 text files at a time.",
    )?;
    require(
        bytes <= 8 * 1024 * 1024,
        "Import at most 8 MiB of text at a time.",
    )?;
    Ok(true)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Original {
    pub id: Uuid,
    #[serde(rename = "folderID")]
    pub folder_id: Option<Uuid>,
    pub path: String,
    #[serde(rename = "originalDigest")]
    pub digest: String,
}

pub fn validate_manifest(
    documents: &[Uuid],
    folders: &[Uuid],
    files: &[Original],
) -> Result<bool, Error> {
    let document_ids: HashSet<_> = documents.iter().copied().collect();
    let folder_ids: HashSet<_> = folders.iter().copied().collect();
    require(
        document_ids.len() == documents.len()
            && folder_ids.len() == folders.len()
            && !document_ids.contains(&Uuid::nil())
            && !folder_ids.contains(&Uuid::nil()),
        "Inconsistent imported-document identities; encrypted records retained.",
    )?;
    let mut ids = HashSet::new();
    let mut paths = HashSet::new();
    for file in files {
        require(
            ids.insert(file.id)
                && document_ids.contains(&file.id)
                && file.folder_id.is_none_or(|id| folder_ids.contains(&id))
                && file.digest.len() == 64
                && file.digest.bytes().all(|b| b.is_ascii_hexdigit()),
            "Inconsistent imported-original identity; encrypted records retained.",
        )?;
        validate_path(&file.path, file.folder_id.is_some())?;
        if let Some(folder) = file.folder_id {
            require(
                paths.insert((folder, &file.path)),
                "The imported folder repeats a file path.",
            )?;
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn file(path: &str, text: &str) -> ImportedText {
        ImportedText {
            path: path.into(),
            text: text.into(),
        }
    }
    #[test]
    fn folder_import_preserves_authored_bytes_and_rejects_escaping_or_ambiguous_paths()
    -> Result<(), Error> {
        let text = "# 私の本\r\n\r\nCafe\u{301} 👩‍💻\n";
        let result = validate_import(vec![file("Drafts/章.md", text)])?;
        assert_eq!(result[0].text.as_bytes(), text.as_bytes());
        for path in [
            "../other.md",
            "/root.md",
            "a//b.md",
            "a/./b.md",
            "a\\b.md",
            "a\0.md",
            "weights.bin",
        ] {
            assert!(validate_import(vec![file(path, "x")]).is_err());
        }
        assert!(validate_import(vec![file("same.md", "a"), file("same.md", "b")]).is_err());
        assert!(validate_import(vec![file("large.md", &"x".repeat(TEXT_LIMIT + 1))]).is_err());
        assert!(validate_import(vec![]).is_err());
        Ok(())
    }

    #[test]
    fn selected_documents_preserve_bytes_and_allow_same_names_from_different_sources()
    -> Result<(), Error> {
        let text = "\u{feff}# 章\r\nCafe\u{301} 👩‍💻\n";
        let files = validate_documents(vec![file("notes.log", text), file("notes.log", "")])?;
        assert_eq!(files[0].text.as_bytes(), text.as_bytes());
        assert_eq!(files[1].text, "");
        for path in ["../notes.txt", "sub/notes.md", "bad\nname.txt"] {
            assert!(validate_documents(vec![file(path, text)]).is_err());
        }
        assert!(validate_documents(vec![file("notes.md", "a\0b")]).is_err());
        assert!(validate_documents(vec![file("notes.md", &"x".repeat(TEXT_LIMIT + 1))]).is_err());
        assert!(validate_budget(512, 8 * 1024 * 1024)?);
        assert!(validate_budget(513, 0).is_err());
        assert!(validate_budget(1, 8 * 1024 * 1024 + 1).is_err());
        Ok(())
    }

    #[test]
    fn originals_bind_to_documents_and_optional_folders_without_colliding_names()
    -> Result<(), Error> {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let folder = Uuid::new_v4();
        let mut files = vec![
            Original {
                id: a,
                folder_id: None,
                path: "notes.md".into(),
                digest: "a".repeat(64),
            },
            Original {
                id: b,
                folder_id: None,
                path: "notes.md".into(),
                digest: "b".repeat(64),
            },
        ];
        assert!(validate_manifest(&[a, b], &[], &files)?);
        files[0].folder_id = Some(folder);
        assert!(validate_manifest(&[a, b], &[], &files).is_err());
        assert!(validate_manifest(&[a, b], &[folder], &files)?);
        files[1].folder_id = Some(folder);
        assert!(validate_manifest(&[a, b], &[folder], &files).is_err());
        files[1].path = "other.md".into();
        assert!(validate_manifest(&[a], &[folder], &files).is_err());
        files[1].digest.clear();
        assert!(validate_manifest(&[a, b], &[folder], &files).is_err());
        Ok(())
    }
}
