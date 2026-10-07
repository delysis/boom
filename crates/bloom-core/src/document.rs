//! Captured document authority and atomic, revision-bound edits.
use crate::{Error, TEXT_LIMIT, digest, require};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "PascalCase")]
pub enum Mode {
    #[default]
    Ask,
    Propose,
    Edit,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Document {
    pub id: Uuid,
    pub title: String,
    pub text: String,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Authority {
    pub mode: Mode,
    pub target: Option<Document>,
}

impl Authority {
    pub fn instructions(&self) -> Result<String, Error> {
        if self.mode == Mode::Ask {
            return Ok("Document permission: Ask (read only). You have no tool to modify documents in this request. Never claim you have saved, updated, or edited a document. You may offer wording in your answer. If asked to apply an edit, explain briefly that the user can choose Propose or Edit beside the message field.".into());
        }
        let target = self
            .target
            .as_ref()
            .ok_or_else(|| Error("Choose a document before requesting edits.".into()))?;
        require(target.text.len() <= TEXT_LIMIT, "Document exceeds 2 MiB.")?;
        let action = if self.mode == Mode::Edit {
            "Edit: a valid patch will be applied by Bloom after validation."
        } else {
            "Propose: a valid patch will be shown for user review. It will not be applied automatically."
        };
        Ok(crate::hashline::instructions(target, action))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Replacement {
    pub old: String,
    pub new: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<ByteRange>,
}

/// An internal anchor resolved against the complete captured document. Not an
/// authority token: validation still requires identity, revision and exact bytes.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ByteRange {
    pub start: usize,
    pub end: usize,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Patch {
    #[serde(rename = "documentID")]
    pub document_id: Uuid,
    pub revision: String,
    pub replacements: Vec<Replacement>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub reply: String,
    pub edits: Vec<Patch>,
}

pub fn decode(text: &str) -> Result<Envelope, Error> {
    require(
        text.len() <= 262_144,
        "Assistant edit response exceeds 256 KiB.",
    )?;
    let envelope: Envelope = serde_json::from_str(text).map_err(|_| {
        Error("Expected whole-response JSON with reply and edits, and no extra fields.".into())
    })?;
    require(
        envelope.edits.len() <= 1,
        "An answer can contain at most one document patch.",
    )?;
    Ok(envelope)
}

#[derive(Serialize)]
pub struct Edit {
    pub location: usize,
    pub length: usize,
    pub replacement: String,
}

#[derive(Serialize)]
pub struct Plan {
    pub document: Document,
    pub edits: Vec<Edit>,
}

pub fn plan(patch: &Patch, authority: &Authority, current: &Document) -> Result<Plan, Error> {
    let validated = validate(patch, authority, current)?;
    let mut text = current.text.clone();
    for edit in &validated {
        text.replace_range(edit.start..edit.end, &edit.replacement);
    }
    // Prefer minimal native ranges, preserving the author's caret and text undo
    // outside the change. A bounded diff failure on an unchanged base can use
    // the already validated literal ranges without weakening edit admission.
    let edits = match crate::merge::minimal(&current.text, &text) {
        Ok(edits) => edits
            .into_iter()
            .rev()
            .map(|edit| Edit {
                location: current.text[..edit.range.start].encode_utf16().count(),
                length: current.text[edit.range.clone()].encode_utf16().count(),
                replacement: edit.text.into(),
            })
            .collect(),
        Err(_) => validated
            .into_iter()
            .map(|edit| Edit {
                location: current.text[..edit.start].encode_utf16().count(),
                length: current.text[edit.start..edit.end].encode_utf16().count(),
                replacement: edit.replacement.into_owned(),
            })
            .collect(),
    };
    Ok(Plan {
        document: Document {
            id: current.id,
            title: current.title.clone(),
            text,
        },
        edits,
    })
}

struct ByteEdit<'a> {
    start: usize,
    end: usize,
    replacement: Cow<'a, str>,
}

fn validate<'a>(
    patch: &'a Patch,
    authority: &Authority,
    current: &Document,
) -> Result<Vec<ByteEdit<'a>>, Error> {
    require(
        authority.mode != Mode::Ask,
        "Ask mode has no edit authority.",
    )?;
    let target = authority
        .target
        .as_ref()
        .ok_or_else(|| Error("Missing captured document.".into()))?;
    require(
        patch.document_id == target.id && current.id == target.id,
        "An edit cannot change its target document.",
    )?;
    require(
        target.text.len() <= TEXT_LIMIT && current.text.len() <= TEXT_LIMIT,
        "Document exceeds 2 MiB.",
    )?;
    require(
        patch.revision == digest(target.text.as_bytes()),
        "The patch does not match its captured document revision.",
    )?;
    require(
        (1..=32).contains(&patch.replacements.len()),
        "An edit needs 1–32 replacements.",
    )?;
    let mut edits = Vec::with_capacity(patch.replacements.len());
    let mut new_bytes = 0_usize;
    let boundaries: Vec<usize> = target
        .text
        .grapheme_indices(true)
        .map(|(offset, _)| offset)
        .chain(std::iter::once(target.text.len()))
        .collect();
    for replacement in &patch.replacements {
        new_bytes = new_bytes.saturating_add(replacement.new.len());
        require(
            new_bytes <= 262_144 && replacement.old.len() <= TEXT_LIMIT,
            "Edit payload exceeds its bound.",
        )?;
        let (start, end) = if let Some(range) = &replacement.range {
            require(
                range.start <= range.end
                    && target.text.get(range.start..range.end) == Some(&replacement.old),
                "The captured line range no longer matches the document.",
            )?;
            (range.start, range.end)
        } else if replacement.old.is_empty() {
            require(
                target.text.is_empty() && patch.replacements.len() == 1,
                "Empty old text is only allowed for an empty document.",
            )?;
            (0, 0)
        } else {
            let start = target
                .text
                .find(&replacement.old)
                .ok_or_else(|| Error("The exact old text was not found.".into()))?;
            // A second occurrence can overlap the first; match_indices alone misses it.
            let next = start
                + target.text[start..]
                    .chars()
                    .next()
                    .map_or(0, char::len_utf8);
            require(
                !target.text[next..].contains(&replacement.old),
                "The old text is ambiguous. Include more surrounding text.",
            )?;
            (start, start + replacement.old.len())
        };
        require(
            boundaries.binary_search(&start).is_ok() && boundaries.binary_search(&end).is_ok(),
            "An edit cannot split a Unicode character.",
        )?;
        edits.push(ByteEdit {
            start,
            end,
            replacement: Cow::Borrowed(&replacement.new),
        });
    }
    edits.sort_by_key(|edit| edit.start);
    require(
        edits
            .windows(2)
            .all(|pair| pair[0].end <= pair[1].start && pair[0].start != pair[1].start),
        "Replacements overlap.",
    )?;
    let removed: usize = edits.iter().map(|edit| edit.end - edit.start).sum();
    require(
        target.text.len() - removed + new_bytes <= TEXT_LIMIT,
        "Resulting document exceeds 2 MiB.",
    )?;
    edits.reverse();
    if current.text != target.text {
        let mut proposed = target.text.clone();
        for edit in &edits {
            proposed.replace_range(edit.start..edit.end, &edit.replacement);
        }
        edits = crate::merge::rebase(&target.text, &current.text, &proposed)?
            .into_iter()
            .map(|edit| ByteEdit {
                start: edit.range.start,
                end: edit.range.end,
                replacement: Cow::Owned(edit.text.into()),
            })
            .collect();
        let current_boundaries: Vec<_> = current
            .text
            .grapheme_indices(true)
            .map(|(offset, _)| offset)
            .chain(std::iter::once(current.text.len()))
            .collect();
        for edit in &edits {
            require(
                current_boundaries.binary_search(&edit.start).is_ok()
                    && current_boundaries.binary_search(&edit.end).is_ok(),
                "The current Unicode boundaries conflict with this edit.",
            )?;
        }
        let removed: usize = edits.iter().map(|e| e.end - e.start).sum();
        let added: usize = edits.iter().map(|e| e.replacement.len()).sum();
        require(
            current.text.len() - removed + added <= TEXT_LIMIT,
            "Merged document exceeds 2 MiB.",
        )?;
        edits.reverse();
    }
    Ok(edits)
}

pub fn validated_edits(
    patch: &Patch,
    authority: &Authority,
    current: &Document,
) -> Result<Vec<Edit>, Error> {
    Ok(validate(patch, authority, current)?
        .into_iter()
        .map(|edit| Edit {
            location: current.text[..edit.start].encode_utf16().count(),
            length: current.text[edit.start..edit.end].encode_utf16().count(),
            replacement: edit.replacement.into_owned(),
        })
        .collect())
}

pub fn apply(patch: &Patch, authority: &Authority, current: &Document) -> Result<Document, Error> {
    let edits = validate(patch, authority, current)?;
    let mut text = current.text.clone();
    for edit in edits {
        text.replace_range(edit.start..edit.end, &edit.replacement);
    }
    Ok(Document {
        id: current.id,
        title: current.title.clone(),
        text,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(text: &str, replacements: &[(&str, &str)]) -> (Document, Authority, Patch) {
        let document = Document {
            id: Uuid::new_v4(),
            title: "Fixture".into(),
            text: text.into(),
        };
        let patch = Patch {
            document_id: document.id,
            revision: digest(text.as_bytes()),
            replacements: replacements
                .iter()
                .map(|(old, new)| Replacement {
                    old: (*old).into(),
                    new: (*new).into(),
                    range: None,
                })
                .collect(),
        };
        let authority = Authority {
            mode: Mode::Edit,
            target: Some(document.clone()),
        };
        (document, authority, patch)
    }
    #[test]
    fn edits_are_atomic_literal_and_grapheme_bound() -> Result<(), Error> {
        let (document, authority, patch) = fixture(
            "👩‍💻 <aside>Old</aside> e\u{301}",
            &[("<aside>Old</aside>", "<aside>New</aside>")],
        );
        let edits = validated_edits(&patch, &authority, &document)?;
        assert_eq!((edits[0].location, edits[0].length), (6, 18));
        assert_eq!(
            apply(&patch, &authority, &document)?.text,
            "👩‍💻 <aside>New</aside> e\u{301}"
        );
        for (text, replacements) in [
            ("aaa", vec![("aa", "b")]),
            ("abcdef", vec![("abc", "A"), ("cde", "B")]),
            ("alpha beta", vec![("alpha", "A"), ("missing", "B")]),
            ("e\u{301}", vec![("e", "a")]),
            ("not empty", vec![("", "a")]),
        ] {
            let (document, authority, patch) = fixture(text, &replacements);
            assert!(apply(&patch, &authority, &document).is_err());
            assert_eq!(document.text, text);
        }
        let (document, authority, patch) = fixture("", &[("", "A new beginning.")]);
        assert_eq!(
            apply(&patch, &authority, &document)?.text,
            "A new beginning."
        );
        Ok(())
    }
    #[test]
    fn authority_is_captured_and_never_follows_later_selection() -> Result<(), Error> {
        let (mut current, mut authority, patch) = fixture("old", &[("old", "new")]);
        assert!(authority.instructions()?.contains(&patch.revision));
        current.text.push(' ');
        assert_eq!(apply(&patch, &authority, &current)?.text, "new ");
        current.text = "old".into();
        current.id = Uuid::new_v4();
        assert!(apply(&patch, &authority, &current).is_err());
        authority.mode = Mode::Ask;
        assert!(apply(&patch, &authority, &current).is_err());
        assert!(authority.instructions()?.contains("Never claim"));
        Ok(())
    }
    #[test]
    fn envelope_rejects_prose_unknown_duplicate_and_multiple_tools() -> Result<(), Error> {
        assert_eq!(decode(r#"{"reply":"Ready","edits":[]}"#)?.reply, "Ready");
        for text in [
            r#"```json {"reply":"Ready","edits":[]} ```"#,
            r#"{"reply":"Ready","edits":[],"shell":"ls"}"#,
            r#"{"reply":"Ready","reply":"Other","edits":[]}"#,
        ] {
            assert!(decode(text).is_err());
        }
        let (_, _, patch) = fixture("old", &[("old", "new")]);
        let native_wire = format!(
            r#"{{"reply":"Ready","edits":[{{"documentID":"{}","revision":"{}","replacements":[{{"old":"old","new":"new"}}]}}]}}"#,
            patch.document_id, patch.revision
        );
        assert_eq!(
            decode(&native_wire)?.edits[0].document_id,
            patch.document_id
        );
        let patch = serde_json::to_string(&patch).map_err(|e| Error(e.to_string()))?;
        assert!(
            decode(&format!(
                "{{\"reply\":\"Ready\",\"edits\":[{patch},{patch}]}}"
            ))
            .is_err()
        );
        Ok(())
    }
}
