//! Blessenger's authority-free product rules. Native code owns storage, models,
//! clocks and devices; these values never acquire file or microphone authority.
mod addressing;
mod assets;
mod history;
mod speech;
mod turn;
mod voice;

use crate::Error;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use addressing::{Contact, ContactKind, Draft, Group, resolve, validate_draft};
pub use speech::{
    Fragment, SpeechCursor, SpeechEmission, speech_fragments, speech_fragments_bounded,
};
pub use turn::{CallEvent, CallGate, CallTransition, TurnDecision, advance_call};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    HistoryWindow {
        input: history::Input,
    },
    AssetRequirements {
        package: assets::AssetPackage,
    },
    ValidateSpeechVoice {
        voice: voice::SpeechVoice,
    },
    ValidateDraft {
        draft: Draft,
    },
    Resolve {
        host: Option<uuid::Uuid>,
        recipients: Vec<Contact>,
        mentions: Vec<String>,
        library: Vec<Contact>,
        historical: Vec<Contact>,
        groups: Vec<Group>,
        frozen: bool,
    },
    Speech {
        cursor: SpeechCursor,
        text: String,
        finished: bool,
        maximum_fragments: usize,
    },
    Call {
        gate: CallGate,
        event: CallEvent,
    },
}

fn value<T: Serialize>(value: T) -> Result<Value, Error> {
    serde_json::to_value(value).map_err(|error| Error(error.to_string()))
}

pub fn execute(request: Request) -> Result<Value, Error> {
    match request {
        Request::HistoryWindow { input } => value(history::select(&input)?),
        Request::AssetRequirements { package } => value(assets::requirements(&package)?),
        Request::ValidateSpeechVoice { voice } => value(voice::validate(&voice)?),
        Request::ValidateDraft { draft } => value(validate_draft(&draft)?),
        Request::Resolve {
            host,
            recipients,
            mentions,
            library,
            historical,
            groups,
            frozen,
        } => value(resolve(
            host,
            &recipients,
            &mentions,
            &library,
            &historical,
            &groups,
            frozen,
        )?),
        Request::Speech {
            cursor,
            text,
            finished,
            maximum_fragments,
        } => value(speech_fragments_bounded(
            cursor,
            &text,
            finished,
            maximum_fragments,
        )?),
        Request::Call { gate, event } => value(advance_call(gate, event)?),
    }
}

#[cfg(test)]
mod bridge_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn native_speech_window_dispatch_returns_only_admitted_fragments() {
        let request: Request = serde_json::from_value(json!({
            "op": "speech", "cursor": {"bytes": 0, "digest": "", "next": 0, "finished": false},
            "text": "One two three four five six.", "finished": true, "maximum_fragments": 1
        }))
        .expect("native request");
        let result = execute(request).expect("native dispatch");
        assert_eq!(result["fragments"].as_array().expect("fragments").len(), 1);
        assert_eq!(result["cursor"]["finished"], false);
        let request: Request = serde_json::from_value(json!({
            "op": "speech", "cursor": result["cursor"], "text": "One two three four five six.",
            "finished": true, "maximum_fragments": 1
        }))
        .expect("native continuation");
        let result = execute(request).expect("native continuation dispatch");
        assert_eq!(result["cursor"]["finished"], true);
        assert_eq!(result["fragments"][0]["text"], "five six.");
    }

    #[test]
    fn speech_profile_dispatch_checks_the_same_serialized_shape_as_native_settings() {
        for provider in ["apple", "qwen"] {
            let request: Request = serde_json::from_value(json!({
                "op": "validate_speech_voice", "voice": {
                    "provider": provider, "description": "A conversational voice.", "locale": "en-US"
                }
            })).expect("native voice binding with omitted optional identifier");
            assert_eq!(execute(request).expect("native validation"), true);
        }
        assert!(
            serde_json::from_value::<Request>(json!({
                "op": "validate_speech_voice", "voice": {
                    "provider": "remote", "description": "Unrequested route", "locale": "en-US"
                }
            }))
            .is_err()
        );
    }
}
