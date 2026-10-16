//! Blessenger's authority-free product rules. Native code owns storage, models,
//! clocks and devices; these values never acquire file or microphone authority.
mod addressing;
mod speech;
mod turn;

use crate::Error;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use addressing::{Contact, ContactKind, Draft, Group, resolve, validate_draft};
pub use speech::{Fragment, SpeechCursor, SpeechEmission, speech_fragments};
pub use turn::{CallEvent, CallGate, CallTransition, TurnDecision, advance_call};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
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
        } => value(speech_fragments(cursor, &text, finished)?),
        Request::Call { gate, event } => value(advance_call(gate, event)?),
    }
}
