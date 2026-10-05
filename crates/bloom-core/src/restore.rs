//! Replacement requires an empty semantic workspace and its exact private inventory.
use crate::{Error, document::Document, require};
use serde_json::Value;
use std::collections::HashSet;
use uuid::Uuid;

const WORKSPACE_ID: &str = "726B3A82-2EB1-493B-9D8E-F17C7A6E4B8A";
const COLLECTIONS: &[&str] = &[
    "voices",
    "voiceVersions",
    "candidateIDs",
    "manuscriptOrigins",
    "attachments",
    "proposals",
];
const OPTIONAL_COLLECTIONS: &[&str] = &["importedFolders", "importedFiles"];
const OTHER_FIELDS: &[&str] = &[
    "schema",
    "documents",
    "chats",
    "selectedDocument",
    "selectedChat",
    "showLibrary",
    "showDocument",
    "showChat",
    "autocomplete",
    "theme",
];

fn empty_collection(value: &Value) -> bool {
    match value {
        Value::Array(items) => items.is_empty(),
        Value::Object(items) => items.is_empty(),
        _ => false,
    }
}

pub fn admit(
    state: &Value,
    documents: &[Document],
    entries: &[String],
    has_index: bool,
) -> Result<bool, Error> {
    let denied = "Restore into a fresh workspace. Existing authored and unindexed private records were retained.";
    let state = state.as_object().ok_or_else(|| Error(denied.into()))?;
    require(state.get("schema") == Some(&Value::from(1)), denied)?;
    require(
        state.keys().all(|key| {
            COLLECTIONS.contains(&key.as_str())
                || OPTIONAL_COLLECTIONS.contains(&key.as_str())
                || OTHER_FIELDS.contains(&key.as_str())
        }),
        denied,
    )?;
    for key in COLLECTIONS {
        require(state.get(*key).is_some_and(empty_collection), denied)?;
    }
    for key in OPTIONAL_COLLECTIONS {
        require(
            state
                .get(*key)
                .is_none_or(|v| v.is_null() || empty_collection(v)),
            denied,
        )?;
    }
    let indexed = state
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(|| Error(denied.into()))?;
    let mut expected = HashSet::new();
    if has_index {
        expected.insert(format!("workspace-{WORKSPACE_ID}.sealed"));
    }
    require(indexed.len() == documents.len(), denied)?;
    for (item, document) in indexed.iter().zip(documents) {
        require(
            item.as_object().is_some_and(|item| {
                item.keys()
                    .all(|key| ["id", "title"].contains(&key.as_str()))
            }),
            denied,
        )?;
        let id = item
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| Uuid::parse_str(id).ok());
        require(
            id == Some(document.id)
                && !document.id.is_nil()
                && item.get("title").and_then(Value::as_str) == Some("Untitled")
                && document.title == "Untitled"
                && document.text.is_empty(),
            denied,
        )?;
        require(
            expected.insert(format!(
                "document-{}.sealed",
                document.id.to_string().to_uppercase()
            )),
            denied,
        )?;
    }
    let chats = state
        .get("chats")
        .and_then(Value::as_array)
        .ok_or_else(|| Error(denied.into()))?;
    let mut chat_ids = HashSet::new();
    for chat in chats {
        let chat = chat.as_object().ok_or_else(|| Error(denied.into()))?;
        let id = chat
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| Uuid::parse_str(id).ok());
        require(
            id.is_some_and(|id| !id.is_nil() && chat_ids.insert(id)),
            denied,
        )?;
        require(
            chat.keys().all(|key| {
                [
                    "id",
                    "title",
                    "messages",
                    "attachedDocumentID",
                    "instructions",
                    "messageVersions",
                ]
                .contains(&key.as_str())
            }),
            denied,
        )?;
        require(
            chat.get("title").and_then(Value::as_str) == Some("New chat")
                && chat.get("messages").is_some_and(empty_collection)
                && chat
                    .get("instructions")
                    .is_none_or(|v| v.is_null() || v.as_str() == Some(""))
                && chat
                    .get("messageVersions")
                    .is_none_or(|v| v.is_null() || empty_collection(v))
                && chat.get("attachedDocumentID").is_none_or(Value::is_null),
            denied,
        )?;
    }
    let actual: HashSet<_> = entries.iter().cloned().collect();
    require(actual.len() == entries.len() && actual == expected, denied)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fresh() -> Value {
        json!({"schema":1,"documents":[],"chats":[],"voices":[],"voiceVersions":[],
            "candidateIDs":[],"manuscriptOrigins":[],"attachments":[],"proposals":[]})
    }
    #[test]
    fn fresh_stub_admits_only_exact_index_and_documents() -> Result<(), Error> {
        let mut state = fresh();
        assert!(admit(&state, &[], &[], false)?);
        let index = format!("workspace-{WORKSPACE_ID}.sealed");
        assert!(admit(&state, &[], std::slice::from_ref(&index), true)?);
        let document = Document {
            id: Uuid::new_v4(),
            title: "Untitled".into(),
            text: String::new(),
        };
        state["documents"] = json!([{"id": document.id, "title":"Untitled"}]);
        let entries = vec![
            index,
            format!("document-{}.sealed", document.id.to_string().to_uppercase()),
        ];
        assert!(admit(
            &state,
            std::slice::from_ref(&document),
            &entries,
            true
        )?);
        assert!(admit(&state, &[document], &entries[..1], true).is_err());
        Ok(())
    }
    #[test]
    fn orphan_records_unknown_entries_and_hidden_authorship_prevent_replacement() {
        for name in [
            "attachment-unknown.sealed",
            "saveJournal-unknown.sealed",
            "private-notes.txt",
            ".retained",
        ] {
            assert!(admit(&fresh(), &[], &[name.into()], false).is_err());
        }
        let chat = json!({"id": Uuid::new_v4(),"title":"New chat","messages":[]});
        let mut state = fresh();
        state["chats"] = json!([chat]);
        assert!(admit(&state, &[], &[], false).is_ok());
        for (key, value) in [
            ("title", json!("My title")),
            ("instructions", json!("Instructions")),
            ("messageVersions", json!([{"text":"Old answer"}])),
            ("attachedDocumentID", json!(Uuid::new_v4())),
            ("futureAuthoredField", json!("Keep this")),
        ] {
            let mut changed = state.clone();
            changed["chats"][0][key] = value;
            assert!(admit(&changed, &[], &[], false).is_err());
        }
        state["futureAuthoredField"] = json!("Keep this");
        assert!(admit(&state, &[], &[], false).is_err());
        state = fresh();
        state["manuscriptOrigins"] = json!([Uuid::new_v4(), {"revision":"captured"}]);
        assert!(admit(&state, &[], &[], false).is_err());
    }
}
