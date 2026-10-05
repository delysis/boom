//! Captured generation identities and append-only token checkpoints.
use crate::{Error, TEXT_LIMIT, require};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Consultation,
    DocumentResponse,
    Writing,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    pub kind: Kind,
    #[serde(rename = "operationID")]
    pub operation_id: Uuid,
    #[serde(rename = "recordID")]
    pub record_id: Uuid,
    #[serde(rename = "attemptID")]
    pub attempt_id: Uuid,
    pub model: String,
    pub seed: u64,
    pub request_digest: String,
    pub max_tokens: usize,
    pub generation_policy: Option<crate::sampling_policy::Policy>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Progress {
    pub text: String,
    #[serde(rename = "tokenIDs")]
    pub token_ids: Vec<u32>,
    pub prompt_digest: String,
    pub prompt_tokens: usize,
    pub first_token_seconds: Option<f64>,
    pub elapsed_seconds: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Checkpoint {
    pub schema: u32,
    pub identity: Identity,
    pub progress: Progress,
    pub stop_reason: Option<String>,
    #[serde(rename = "stopTokenID")]
    pub stop_token_id: Option<u32>,
}

fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid(checkpoint: &Checkpoint, expected: &Identity) -> Result<(), Error> {
    require(
        checkpoint.schema == 1 && &checkpoint.identity == expected,
        "Generation checkpoint does not match its captured attempt; records retained.",
    )?;
    require(
        !expected.operation_id.is_nil()
            && !expected.record_id.is_nil()
            && !expected.attempt_id.is_nil()
            && !expected.model.is_empty()
            && expected.model.len() <= 4096
            && hash(&expected.request_digest)
            && (1..=4096).contains(&expected.max_tokens),
        "Invalid captured generation identity.",
    )?;
    let progress = &checkpoint.progress;
    if let Some(policy) = &expected.generation_policy {
        policy.validate()?;
        require(
            progress
                .token_ids
                .iter()
                .all(|id| *id < policy.vocabulary_size && !policy.control_token_ids.contains(id)),
            "A generation checkpoint contains a control token in its prose ledger.",
        )?;
        let reason = checkpoint.stop_reason.as_deref();
        let stop = checkpoint.stop_token_id;
        require(
            match (reason, stop) {
                (Some("eos"), Some(id)) => policy.eos_token_ids.contains(&id),
                (Some("model_control"), Some(id)) => {
                    policy.control_token_ids.contains(&id)
                        && !policy.eos_token_ids.contains(&id)
                        && !policy.suppressed_token_ids.contains(&id)
                }
                (Some("cancelled"), Some(id)) => {
                    policy.control_token_ids.contains(&id)
                        && !policy.suppressed_token_ids.contains(&id)
                }
                (Some("eos" | "model_control"), None) => false,
                (_, None) => true,
                _ => false,
            },
            "The stopping token does not match the captured model policy.",
        )?;
    } else {
        require(
            checkpoint.stop_token_id.is_none(),
            "A stopping token requires a captured model policy.",
        )?;
    }
    require(
        hash(&progress.prompt_digest)
            && progress.prompt_tokens > 0
            && progress.prompt_tokens.saturating_add(expected.max_tokens) <= 16_384
            && progress.token_ids.len() <= expected.max_tokens
            && progress
                .token_ids
                .iter()
                .all(|token| *token <= i32::MAX as u32)
            && progress.text.len() <= TEXT_LIMIT
            && (progress.text.is_empty() || !progress.token_ids.is_empty()),
        "Generation checkpoint exceeds its captured budget or has inconsistent output.",
    )?;
    require(
        progress.elapsed_seconds.is_finite()
            && progress.elapsed_seconds >= 0.0
            && progress.first_token_seconds.is_none_or(|first| {
                first.is_finite() && first >= 0.0 && first <= progress.elapsed_seconds
            })
            && (progress.token_ids.is_empty() == progress.first_token_seconds.is_none()),
        "Generation checkpoint has inconsistent timing.",
    )?;
    require(
        checkpoint.stop_reason.as_deref().is_none_or(|reason| {
            matches!(
                reason,
                "eos" | "model_control" | "output_limit" | "cancelled"
            )
        }),
        "Unknown generation stop reason.",
    )
}

pub fn validate(
    expected: &Identity,
    previous: Option<&Checkpoint>,
    next: Checkpoint,
) -> Result<Checkpoint, Error> {
    valid(&next, expected)?;
    if let Some(previous) = previous {
        valid(previous, expected)?;
        require(
            previous.stop_reason.is_none()
                && next.progress.prompt_digest == previous.progress.prompt_digest
                && next.progress.prompt_tokens == previous.progress.prompt_tokens
                && next
                    .progress
                    .token_ids
                    .starts_with(&previous.progress.token_ids)
                && next.progress.elapsed_seconds >= previous.progress.elapsed_seconds
                && (previous.progress.first_token_seconds.is_none()
                    || next.progress.first_token_seconds == previous.progress.first_token_seconds),
            "Stale or rewritten generation checkpoint; existing record retained.",
        )?;
    }
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn checkpoint() -> Checkpoint {
        Checkpoint {
            schema: 1,
            identity: Identity {
                kind: Kind::Writing,
                operation_id: Uuid::from_u128(1),
                record_id: Uuid::from_u128(2),
                attempt_id: Uuid::from_u128(3),
                model: "captured model".into(),
                seed: u64::MAX,
                request_digest: "a".repeat(64),
                max_tokens: 64,
                generation_policy: None,
            },
            progress: Progress {
                text: "At the shore, 👩🏽‍💻é".into(),
                token_ids: vec![1, 2],
                prompt_digest: "b".repeat(64),
                prompt_tokens: 12,
                first_token_seconds: Some(0.1),
                elapsed_seconds: 0.2,
            },
            stop_reason: None,
            stop_token_id: None,
        }
    }
    #[test]
    fn checkpoints_preserve_unicode_and_bind_every_captured_identity() -> Result<(), Error> {
        let next = checkpoint();
        let expected = next.identity.clone();
        let value = validate(&expected, None, next.clone())?;
        assert_eq!(value.progress.text, next.progress.text);
        assert_eq!(value.identity.seed, u64::MAX);
        for field in [
            "kind",
            "operationID",
            "recordID",
            "attemptID",
            "model",
            "seed",
            "requestDigest",
            "maxTokens",
        ] {
            let mut wire = serde_json::to_value(&next).map_err(|e| Error(e.to_string()))?;
            wire["identity"][field] = match field {
                "kind" => serde_json::json!("consultation"),
                "seed" => serde_json::json!(0),
                "maxTokens" => serde_json::json!(63),
                "model" => serde_json::json!("different model"),
                "requestDigest" => serde_json::json!("c".repeat(64)),
                _ => serde_json::json!(Uuid::from_u128(4)),
            };
            let changed = serde_json::from_value(wire).map_err(|e| Error(e.to_string()))?;
            assert!(validate(&expected, None, changed).is_err(), "{field}");
        }
        Ok(())
    }
    #[test]
    fn delayed_tokens_cannot_rewrite_or_reopen_a_finished_attempt() -> Result<(), Error> {
        let before = checkpoint();
        let mut after = before.clone();
        after.progress.token_ids.push(3);
        after.progress.text.push_str(" continues.");
        after.progress.elapsed_seconds = 0.3;
        assert!(validate(&before.identity, Some(&before), after.clone()).is_ok());
        after.progress.token_ids[0] = 7;
        assert!(validate(&before.identity, Some(&before), after.clone()).is_err());
        assert!(
            validate(&before.identity, Some(&checkpoint()), {
                let mut value = checkpoint();
                value.progress.elapsed_seconds = 0.1;
                value
            })
            .is_err()
        );
        let mut terminal = before.clone();
        terminal.stop_reason = Some("cancelled".into());
        assert!(validate(&before.identity, Some(&terminal), after).is_err());
        Ok(())
    }
    #[test]
    fn terminal_tokens_are_excluded_from_prose_and_bound_to_the_policy() -> Result<(), Error> {
        let mut base = checkpoint();
        base.identity.generation_policy = Some(crate::sampling_policy::compile(
            16,
            serde_json::json!({"eos_token_id": 1, "suppress_tokens": [14, 15]}),
            vec![0, 1, 3, 14, 15],
            Some(1),
        )?);
        base.progress.token_ids = vec![4, 5];
        for (reason, token) in [("eos", 1), ("model_control", 3), ("cancelled", 1)] {
            let mut terminal = base.clone();
            terminal.stop_reason = Some(reason.into());
            terminal.stop_token_id = Some(token);
            assert!(validate(&base.identity, Some(&base), terminal).is_ok());
        }
        for (reason, token) in [
            ("eos", Some(3)),
            ("eos", None),
            ("model_control", Some(1)),
            ("model_control", Some(14)),
            ("model_control", Some(16)),
            ("output_limit", Some(1)),
        ] {
            let mut terminal = base.clone();
            terminal.stop_reason = Some(reason.into());
            terminal.stop_token_id = token;
            assert!(validate(&base.identity, Some(&base), terminal).is_err());
        }
        for token in [0, 1, 3, 14, 15, 16] {
            let mut bad = base.clone();
            bad.progress.token_ids.push(token);
            assert!(validate(&base.identity, Some(&base), bad).is_err());
        }
        let mut altered = base.clone();
        if let Some(policy) = altered.identity.generation_policy.as_mut() {
            policy.suppressed_token_ids.clear();
        }
        assert!(validate(&base.identity, Some(&base), altered).is_err());
        Ok(())
    }
    #[test]
    fn checkpoint_bounds_and_inconsistent_timing_fail_closed() {
        let base = checkpoint();
        let mut invalid = base.clone();
        invalid.progress.token_ids = vec![1; 65];
        assert!(validate(&base.identity, None, invalid).is_err());
        let mut invalid = base.clone();
        invalid.progress.prompt_tokens = 16_384;
        assert!(validate(&base.identity, None, invalid).is_err());
        let mut invalid = base.clone();
        invalid.progress.elapsed_seconds = f64::NAN;
        assert!(validate(&base.identity, None, invalid).is_err());
        let mut invalid = base.clone();
        invalid.progress.first_token_seconds = None;
        assert!(validate(&base.identity, None, invalid).is_err());
        let mut invalid = base.clone();
        invalid.progress.token_ids.clear();
        assert!(validate(&base.identity, None, invalid).is_err());
    }
}
