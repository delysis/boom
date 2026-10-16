use crate::{Error, digest, require, valid_slug};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ContactKind {
    Contact,
    Chat,
}

/// An immutable reference, not a second definition of a Contact. The matching
/// Voice or captured chat remains in the application's one conversation store.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Contact {
    pub id: Uuid,
    pub revision: String,
    pub handle: String,
    pub name: String,
    pub kind: ContactKind,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Group {
    pub id: Uuid,
    pub handle: String,
    pub name: String,
    pub members: Vec<Contact>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Draft {
    pub id: Uuid,
    pub version: Uuid,
    pub text: String,
    pub attachments: Vec<Uuid>,
    pub recipients: Vec<Contact>,
    pub group_name: Option<String>,
    #[serde(default)]
    pub recipient_query: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftValidation {
    pub digest: String,
    pub sendable: bool,
}

fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn name(value: &str) -> bool {
    !value.trim().is_empty() && value.chars().count() <= 120 && !value.chars().any(char::is_control)
}

fn contact(value: &Contact) -> Result<(), Error> {
    require(
        !value.id.is_nil()
            && hash(&value.revision)
            && valid_slug(&value.handle)
            && !value.name.trim().is_empty()
            && value.name.len() <= 256
            && !value.name.chars().any(char::is_control),
        "The Contact reference is invalid.",
    )
}

fn contacts(values: &[Contact]) -> Result<(), Error> {
    require(values.len() <= 4, "Choose at most four different Contacts.")?;
    let mut seen = HashSet::new();
    for value in values {
        contact(value)?;
        require(seen.insert(value.id), "A Contact was addressed twice.")?;
    }
    Ok(())
}

pub fn validate_draft(draft: &Draft) -> Result<DraftValidation, Error> {
    require(
        draft.recipient_query.chars().count() <= 256
            && !draft.recipient_query.chars().any(char::is_control),
        "The recipient query exceeds its supported bound.",
    )?;
    require(
        !draft.id.is_nil() && !draft.version.is_nil(),
        "The draft has no stable identity.",
    )?;
    require(
        draft.text.len() <= 2 * 1024 * 1024,
        "The unsent message exceeds 2 MiB; its text is retained.",
    )?;
    require(
        draft.attachments.len() <= 8,
        "Choose at most eight attachments.",
    )?;
    let mut attachments = HashSet::new();
    for id in &draft.attachments {
        require(
            !id.is_nil() && attachments.insert(*id),
            "Attachment identities must be unique.",
        )?;
    }
    contacts(&draft.recipients)?;
    if let Some(value) = &draft.group_name {
        // No trim/truncate/normalization of an authored group name.
        require(
            name(value),
            "A group name needs 1–120 Unicode characters without control characters.",
        )?;
    }
    let encoded = serde_json::to_vec(draft).map_err(|error| Error(error.to_string()))?;
    Ok(DraftValidation {
        digest: digest(&encoded),
        sendable: draft.recipient_query.trim().is_empty()
            && (!draft.text.trim().is_empty() || !draft.attachments.is_empty()),
    })
}

/// Resolve every requested identity before returning any of them. Ordered union
/// does not rewrite message bytes. A fifth participant or one missing member
/// refuses the entire send; partial groups are never silently dispatched.
pub fn resolve(
    host: Option<Uuid>,
    recipients: &[Contact],
    mentions: &[String],
    library: &[Contact],
    historical: &[Contact],
    groups: &[Group],
    frozen: bool,
) -> Result<Vec<Contact>, Error> {
    contacts(recipients)?;
    require(
        library.len() <= 4096
            && historical.len() <= 16384
            && groups.len() <= 1024
            && mentions.len() <= 128,
        "Addressing exceeds its bounded local inventory.",
    )?;
    let mut by_id = HashMap::new();
    let mut by_handle = HashMap::new();
    for item in library {
        contact(item)?;
        require(
            by_id.insert(item.id, item).is_none()
                && by_handle.insert(item.handle.as_str(), item).is_none(),
            "The Contact library contains ambiguous identities or handles.",
        )?;
    }
    let mut versions = HashMap::new();
    for item in historical {
        contact(item)?;
        if let Some(previous) = versions.insert((item.id, item.revision.as_str()), item) {
            require(
                previous == item,
                "A historical Contact revision is ambiguous.",
            )?;
        }
    }
    let mut group_handles = HashMap::new();
    let mut group_ids = HashSet::new();
    for group in groups {
        require(
            !group.id.is_nil()
                && group_ids.insert(group.id)
                && valid_slug(&group.handle)
                && name(&group.name)
                && !group.members.is_empty(),
            "The saved group is invalid.",
        )?;
        contacts(&group.members)?;
        require(
            !by_handle.contains_key(group.handle.as_str())
                && group_handles.insert(group.handle.as_str(), group).is_none(),
            "A group handle is ambiguous.",
        )?;
    }
    let mut result: Vec<Contact> = Vec::new();
    let mut add = |target: &Contact, frozen: bool| -> Result<(), Error> {
        require(
            host != Some(target.id),
            "A conversation cannot consult itself.",
        )?;
        let live = by_id
            .get(&target.id)
            .ok_or_else(|| Error(format!("{} is no longer available.", target.name)))?;
        if *live != target {
            require(
                frozen
                    && versions
                        .get(&(target.id, target.revision.as_str()))
                        .copied()
                        == Some(target),
                "A selected Contact changed. Select the current Contact deliberately before sending.",
            )?;
        }
        if let Some(prior) = result.iter().find(|prior| prior.id == target.id) {
            require(
                prior == target,
                "The same Contact was requested at different revisions.",
            )?;
        } else {
            require(
                result.len() < 4,
                "The combined To and mention recipients exceed four Contacts.",
            )?;
            result.push(target.clone());
        }
        Ok(())
    };
    for recipient in recipients {
        add(recipient, frozen)?;
    }
    for handle in mentions {
        require(valid_slug(handle), "The mention handle is invalid.")?;
        if let Some(target) = by_handle.get(handle.as_str()) {
            // An explicit mention of an already addressed Contact preserves the
            // captured version instead of upgrading its recipient silently.
            if let Some(target) = recipients.iter().find(|item| item.id == target.id) {
                add(target, frozen)?;
            } else {
                add(target, false)?;
            }
        } else if let Some(group) = group_handles.get(handle.as_str()) {
            for member in &group.members {
                add(member, false)?;
            }
        } else {
            return Err(Error(format!("Unknown Contact or group @{handle}.")));
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(n: u128) -> Contact {
        Contact {
            id: Uuid::from_u128(n),
            revision: "a".repeat(64),
            handle: format!("contact{n}"),
            name: format!("Contact {n}"),
            kind: ContactKind::Contact,
        }
    }
    fn draft() -> Draft {
        Draft {
            id: Uuid::from_u128(100),
            version: Uuid::from_u128(101),
            text: "  original\r\nα e\u{301}  ".into(),
            attachments: vec![],
            recipients: vec![entry(1)],
            group_name: None,
            recipient_query: String::new(),
        }
    }
    #[test]
    fn exact_bytes_and_revision_are_in_the_admission_witness() {
        let a = draft();
        let mut b = a.clone();
        b.text = b.text.trim().into();
        assert_ne!(
            validate_draft(&a).expect("a").digest,
            validate_draft(&b).expect("b").digest
        );
        b = a.clone();
        b.version = Uuid::from_u128(102);
        assert_ne!(
            validate_draft(&a).expect("a").digest,
            validate_draft(&b).expect("b").digest
        );
    }
    #[test]
    fn a_picked_contact_does_not_make_an_empty_draft_sendable() {
        let mut a = draft();
        a.text = " \n\t".into();
        assert!(!validate_draft(&a).expect("valid").sendable);
        a.attachments.push(Uuid::from_u128(50));
        assert!(validate_draft(&a).expect("valid").sendable);
    }
    #[test]
    fn names_use_scalars_not_utf16_and_are_not_truncated() {
        let mut a = draft();
        a.group_name = Some("🪷".repeat(120));
        assert!(validate_draft(&a).is_ok());
        a.group_name = Some("🪷".repeat(121));
        assert!(validate_draft(&a).is_err());
        a.group_name = Some("a\nb".into());
        assert!(validate_draft(&a).is_err());
    }
    #[test]
    fn ordered_union_keeps_four_and_refuses_five() {
        let lib: Vec<_> = (1..=5).map(entry).collect();
        let group = Group {
            id: Uuid::from_u128(80),
            handle: "team".into(),
            name: "Team".into(),
            members: lib[1..4].to_vec(),
        };
        let result = resolve(
            None,
            &lib[..2],
            &["team".into(), "contact1".into()],
            &lib,
            &[],
            std::slice::from_ref(&group),
            false,
        )
        .expect("union");
        assert_eq!(result, lib[..4]);
        assert!(
            resolve(
                None,
                &lib[..2],
                &["team".into(), "contact5".into()],
                &lib,
                &[],
                &[group],
                false
            )
            .is_err()
        );
    }
    #[test]
    fn changed_pending_contact_is_not_silently_upgraded() {
        let old = entry(1);
        let mut current = old.clone();
        current.revision = "b".repeat(64);
        assert!(
            resolve(
                None,
                std::slice::from_ref(&old),
                &[],
                &[current.clone()],
                std::slice::from_ref(&old),
                &[],
                false
            )
            .is_err()
        );
        assert_eq!(
            resolve(
                None,
                std::slice::from_ref(&old),
                &[],
                &[current],
                std::slice::from_ref(&old),
                &[],
                true
            )
            .expect("frozen"),
            vec![old]
        );
    }
    #[test]
    fn removed_contact_and_partial_group_fail_closed() {
        let group = Group {
            id: Uuid::from_u128(80),
            handle: "team".into(),
            name: "Team".into(),
            members: vec![entry(1), entry(2)],
        };
        assert!(
            resolve(
                None,
                &[],
                &["team".into()],
                &[entry(1)],
                &[entry(2)],
                &[group],
                false
            )
            .is_err()
        );
        assert!(resolve(None, &[entry(1)], &[], &[], &[entry(1)], &[], true).is_err());
    }
    #[test]
    fn self_reference_duplicate_ids_and_handle_collisions_refuse() {
        assert!(
            resolve(
                Some(entry(1).id),
                &[entry(1)],
                &[],
                &[entry(1)],
                &[],
                &[],
                false
            )
            .is_err()
        );
        let mut other = entry(2);
        other.handle = entry(1).handle;
        assert!(resolve(None, &[], &[], &[entry(1), other], &[], &[], false).is_err());
        assert!(
            resolve(
                None,
                &[entry(1), entry(1)],
                &[],
                &[entry(1)],
                &[],
                &[],
                false
            )
            .is_err()
        );
    }
    #[test]
    fn unresolved_address_is_retained_but_never_sendable() {
        let mut value = draft();
        value.text = "The exact case question".into();
        value.recipient_query = "unresolved name".into();
        assert!(!validate_draft(&value).expect("valid unsent query").sendable);
        let old_digest = validate_draft(&value).expect("digest").digest;
        value.recipient_query.clear();
        let ready = validate_draft(&value).expect("resolved");
        assert!(ready.sendable);
        assert_ne!(ready.digest, old_digest);
        value.recipient_query = "x".repeat(257);
        assert!(validate_draft(&value).is_err());
    }
}
