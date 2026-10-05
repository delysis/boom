//! Validate a captured folder import before any encrypted records are admitted.
use super::{Error, TEXT_LIMIT, require};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ImportedText {
    pub path: String,
    pub text: String,
}

pub fn validate_import(files: Vec<ImportedText>) -> Result<Vec<ImportedText>, Error> {
    require(
        (1..=512).contains(&files.len()),
        "Import 1 to 512 text files at a time.",
    )?;
    let mut paths = HashSet::new();
    let mut total = 0_usize;
    for file in &files {
        let components: Vec<_> = file.path.split('/').collect();
        require(
            file.path.len() <= 4096
                && components.len() <= 16
                && components.iter().all(|part| {
                    !part.is_empty()
                        && ![".", ".."].contains(part)
                        && !part.chars().any(|c| c.is_control() || c == '\\')
                }),
            "An imported file has an invalid relative path.",
        )?;
        let extension = file.path.rsplit('.').next().unwrap_or_default();
        require(
            ["md", "markdown", "txt"]
                .iter()
                .any(|e| extension.eq_ignore_ascii_case(e)),
            "Folder import supports Markdown and plain text files.",
        )?;
        require(paths.insert(&file.path), "The import repeats a file path.")?;
        require(
            file.text.len() <= TEXT_LIMIT && !file.text.contains('\0'),
            "An imported document exceeds 2 MiB or contains a null character.",
        )?;
        total = total.saturating_add(file.text.len());
        require(
            total <= 8 * 1024 * 1024,
            "Import at most 8 MiB of text at a time.",
        )?;
    }
    Ok(files)
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
}
