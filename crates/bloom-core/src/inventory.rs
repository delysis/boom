//! Record availability and original identity without filesystem or key authority.
use crate::{Error, TEXT_LIMIT, require};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

const WORKSPACE: Uuid = Uuid::from_u128(0x726b3a822eb1493b9d8ef17c7a6e4b8a);
const LIMIT: usize = 100_000;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Original {
    pub id: Uuid,
    pub digest: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Reply {
    pub id: Uuid,
    pub role: String,
    pub state: String,
    pub has_model: bool,
    pub authored: bool,
    pub has_text: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub has_index: bool,
    pub documents: Vec<Uuid>,
    pub attachments: Vec<Original>,
    pub imported_originals: Vec<Original>,
    pub candidates: Vec<Uuid>,
    pub replies: Vec<Reply>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub name: String,
    pub regular: bool,
    pub digest: Option<String>,
    pub bytes: Option<usize>,
}

fn identities(ids: impl Iterator<Item = Uuid>) -> Result<BTreeSet<Uuid>, Error> {
    let mut unique = BTreeSet::new();
    for id in ids {
        require(
            !id.is_nil() && unique.insert(id),
            "Duplicate or empty private record identity; records retained.",
        )?;
    }
    Ok(unique)
}

pub fn validate(manifest: &Manifest, entries: &[Entry]) -> Result<bool, Error> {
    require(
        entries.len() <= LIMIT
            && manifest.documents.len() <= LIMIT
            && manifest.attachments.len() <= LIMIT
            && manifest.imported_originals.len() <= LIMIT
            && manifest.candidates.len() <= LIMIT
            && manifest.replies.len() <= LIMIT,
        "Private inventory exceeds its format bound; records retained.",
    )?;
    require(
        manifest.has_index || entries.is_empty(),
        "The workspace index is missing while private files exist; records retained.",
    )?;
    let mut actual = BTreeMap::new();
    for entry in entries {
        let (kind, id) = entry
            .name
            .strip_suffix(".sealed")
            .and_then(|name| name.split_once('-'))
            .ok_or_else(|| Error("Unknown private record name; records retained.".into()))?;
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
            "Unknown private record kind; records retained.",
        )?;
        let id = Uuid::parse_str(id)
            .map_err(|_| Error("Invalid private record identity; records retained.".into()))?;
        require(
            entry.regular
                && !id.is_nil()
                && entry.name == format!("{kind}-{}.sealed", id.to_string().to_uppercase())
                && actual.insert((kind, id), entry).is_none(),
            "Unsafe or ambiguous private record; records retained.",
        )?;
    }
    let needed = |kind: &str, id: Uuid| {
        actual
            .get(&(kind, id))
            .copied()
            .ok_or_else(|| Error("A required private record is missing; records retained.".into()))
    };
    if manifest.has_index {
        needed("workspace", WORKSPACE)?;
    }
    let documents = identities(manifest.documents.iter().copied())?;
    for id in &documents {
        needed("document", *id)?;
    }
    for id in identities(manifest.candidates.iter().copied())? {
        needed("candidate", id)?;
    }
    identities(manifest.attachments.iter().map(|original| original.id))?;
    identities(
        manifest
            .imported_originals
            .iter()
            .map(|original| original.id),
    )?;
    let mut originals = BTreeMap::new();
    for (group, limit) in [
        (&manifest.attachments, 64 * 1024 * 1024),
        (&manifest.imported_originals, TEXT_LIMIT),
    ] {
        for original in group {
            require(
                original.digest.len() == 64
                    && original.digest.bytes().all(|byte| byte.is_ascii_hexdigit()),
                "Invalid original digest; records retained.",
            )?;
            if let Some(previous) = originals.insert(original.id, &original.digest) {
                require(
                    previous == &original.digest,
                    "Conflicting original identities; records retained.",
                )?;
            }
            let entry = needed("attachment", original.id)?;
            require(
                entry.digest.as_ref() == Some(&original.digest)
                    && entry.bytes.is_some_and(|bytes| bytes <= limit),
                "An original is changed or exceeds its bound; records retained.",
            )?;
        }
    }
    for original in &manifest.attachments {
        needed("receipt", original.id)?;
    }
    for original in &manifest.imported_originals {
        require(
            documents.contains(&original.id),
            "An imported original has no document; records retained.",
        )?;
    }
    for reply in &manifest.replies {
        require(
            !reply.id.is_nil()
                && ["user", "assistant"].contains(&reply.role.as_str())
                && ["pending", "complete", "failed", "cancelled"].contains(&reply.state.as_str()),
            "Invalid conversation record; records retained.",
        )?;
        if reply.role == "assistant"
            && reply.has_model
            && !reply.authored
            && (reply.state == "complete" || reply.has_text)
        {
            needed("receipt", reply.id)?;
        }
    }
    // Unindexed records are retained, including interrupted imports and journals.
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(kind: &str, id: Uuid) -> Entry {
        Entry {
            name: format!("{kind}-{}.sealed", id.to_string().to_uppercase()),
            regular: true,
            digest: Some("a".repeat(64)),
            bytes: Some(5),
        }
    }
    fn fixture() -> (Manifest, Vec<Entry>) {
        let doc = Uuid::new_v4();
        let original = Uuid::new_v4();
        let candidate = Uuid::new_v4();
        let reply = Uuid::new_v4();
        (
            Manifest {
                has_index: true,
                documents: vec![doc],
                attachments: vec![Original {
                    id: original,
                    digest: "a".repeat(64),
                }],
                imported_originals: vec![],
                candidates: vec![candidate],
                replies: vec![Reply {
                    id: reply,
                    role: "assistant".into(),
                    state: "complete".into(),
                    has_model: true,
                    authored: false,
                    has_text: true,
                }],
            },
            vec![
                entry("workspace", WORKSPACE),
                entry("document", doc),
                entry("attachment", original),
                entry("receipt", original),
                entry("candidate", candidate),
                entry("receipt", reply),
            ],
        )
    }
    #[test]
    fn every_referenced_record_is_required_but_unindexed_evidence_is_retained() -> Result<(), Error>
    {
        let (manifest, mut entries) = fixture();
        assert!(validate(&manifest, &entries)?);
        for index in 0..entries.len() {
            let mut missing: Vec<_> = entries.iter().collect();
            missing.remove(index);
            let missing: Vec<_> = missing
                .into_iter()
                .map(|e| Entry {
                    name: e.name.clone(),
                    regular: e.regular,
                    digest: e.digest.clone(),
                    bytes: e.bytes,
                })
                .collect();
            assert!(validate(&manifest, &missing).is_err());
        }
        entries.push(entry("attachment", Uuid::new_v4()));
        entries.push(entry("generationJournal", Uuid::new_v4()));
        assert!(validate(&manifest, &entries)?);
        Ok(())
    }
    #[test]
    fn invalid_names_types_aliases_and_duplicates_cannot_be_admitted() -> Result<(), Error> {
        let (manifest, mut entries) = fixture();
        for name in [
            ".retained",
            "legacy-726B3A82-2EB1-493B-9D8E-F17C7A6E4B8A.sealed",
            "workspace-726b3a82-2eb1-493b-9d8e-f17c7a6e4b8a.sealed",
            "workspace-00000000-0000-0000-0000-000000000000.sealed",
        ] {
            entries.push(Entry {
                name: name.into(),
                regular: true,
                digest: None,
                bytes: None,
            });
            assert!(validate(&manifest, &entries).is_err());
            entries.pop();
        }
        entries[0].regular = false;
        assert!(validate(&manifest, &entries).is_err());
        entries[0].regular = true;
        entries.push(entry("workspace", WORKSPACE));
        assert!(validate(&manifest, &entries).is_err());
        assert!(validate(&Manifest::default(), &entries).is_err());
        assert!(validate(&Manifest::default(), &[])?);
        Ok(())
    }
    #[test]
    fn originals_require_exact_hashes_limits_and_unambiguous_owners() -> Result<(), Error> {
        let (mut manifest, mut entries) = fixture();
        entries[2].digest = Some("b".repeat(64));
        assert!(validate(&manifest, &entries).is_err());
        entries[2].digest = Some("a".repeat(64));
        entries[2].bytes = Some(64 * 1024 * 1024 + 1);
        assert!(validate(&manifest, &entries).is_err());
        entries[2].bytes = Some(5);
        let id = manifest.documents[0];
        manifest.imported_originals.push(Original {
            id,
            digest: "a".repeat(64),
        });
        entries.push(entry("attachment", id));
        assert!(validate(&manifest, &entries)?);
        let added = entries.len() - 1;
        entries[added].bytes = Some(TEXT_LIMIT + 1);
        assert!(validate(&manifest, &entries).is_err());
        entries[added].bytes = Some(5);
        manifest.attachments.push(Original {
            id,
            digest: "b".repeat(64),
        });
        assert!(validate(&manifest, &entries).is_err());
        manifest.documents.push(id);
        assert!(validate(&manifest, &entries).is_err());
        Ok(())
    }
    #[test]
    fn authored_and_never_started_replies_do_not_invent_generation_receipts() -> Result<(), Error> {
        let (mut manifest, mut entries) = fixture();
        entries.pop();
        manifest.replies[0].authored = true;
        assert!(validate(&manifest, &entries)?);
        manifest.replies[0].authored = false;
        manifest.replies[0].state = "failed".into();
        manifest.replies[0].has_text = false;
        assert!(validate(&manifest, &entries)?);
        manifest.replies[0].has_text = true;
        assert!(validate(&manifest, &entries).is_err());
        Ok(())
    }
}
