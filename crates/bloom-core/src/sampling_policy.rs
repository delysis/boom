//! Checkpoint-authored control tokens are policy, not lexical prose filters.
use crate::{Error, require};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum TextDecoding {
    #[serde(rename = "checkpoint_raw_v1")]
    CheckpointRawV1,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Policy {
    pub schema: u32,
    pub vocabulary_size: u32,
    #[serde(rename = "eosTokenIDs")]
    pub eos_token_ids: Vec<u32>,
    #[serde(rename = "suppressedTokenIDs")]
    pub suppressed_token_ids: Vec<u32>,
    #[serde(rename = "controlTokenIDs")]
    pub control_token_ids: Vec<u32>,
    // Earlier records remain readable, but replay cannot silently adopt the
    // decoder that preserves punctuation and spacing exactly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_decoding: Option<TextDecoding>,
}

impl Policy {
    pub fn validate(&self) -> Result<(), Error> {
        require(
            self.schema == 1 && (2..=1_048_576).contains(&self.vocabulary_size),
            "Unsupported model generation policy.",
        )?;
        for ids in [
            &self.eos_token_ids,
            &self.suppressed_token_ids,
            &self.control_token_ids,
        ] {
            require(
                ids.len() <= 4096
                    && ids.iter().all(|id| *id < self.vocabulary_size)
                    && ids.windows(2).all(|pair| pair[0] < pair[1]),
                "Invalid, repeated, or unordered model control tokens.",
            )?;
        }
        require(
            !self.eos_token_ids.is_empty()
                && self.control_token_ids.len() < self.vocabulary_size as usize
                && self
                    .eos_token_ids
                    .iter()
                    .all(|id| self.control_token_ids.contains(id))
                && self.suppressed_token_ids.iter().all(|id| {
                    self.control_token_ids.contains(id) && !self.eos_token_ids.contains(id)
                }),
            "The checkpoint suppresses an end token or an ordinary prose token.",
        )
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum EndTokens {
    One(u32),
    Many(Vec<u32>),
}

#[derive(Deserialize)]
struct Configuration {
    eos_token_id: EndTokens,
    suppress_tokens: Vec<u32>,
}

pub fn compile(
    vocabulary_size: u32,
    configuration: serde_json::Value,
    mut control_token_ids: Vec<u32>,
    tokenizer_eos: Option<u32>,
) -> Result<Policy, Error> {
    let config: Configuration = serde_json::from_value(configuration)
        .map_err(|_| Error("Invalid checkpoint generation configuration.".into()))?;
    let mut eos_token_ids = match config.eos_token_id {
        EndTokens::One(id) => vec![id],
        EndTokens::Many(ids) => ids,
    };
    if let Some(id) = tokenizer_eos {
        eos_token_ids.push(id);
    }
    eos_token_ids.sort_unstable();
    eos_token_ids.dedup();
    control_token_ids.sort_unstable();
    control_token_ids.dedup();
    let mut suppressed_token_ids = config.suppress_tokens;
    // Duplicate suppression entries are malformed input, not another policy.
    suppressed_token_ids.sort_unstable();
    let policy = Policy {
        schema: 1,
        vocabulary_size,
        eos_token_ids,
        suppressed_token_ids,
        control_token_ids,
        text_decoding: Some(TextDecoding::CheckpointRawV1),
    };
    policy.validate()?;
    Ok(policy)
}

pub fn admit(captured: Option<&Policy>, loaded: &Policy) -> Result<bool, Error> {
    loaded.validate()?;
    let captured = captured.ok_or_else(|| Error(
        "This earlier continuation did not record its token policy. Explore again to create replayable alternatives.".into()))?;
    captured.validate()?;
    require(
        captured == loaded,
        "Replay requires the original token and decoding policy. Captured outputs were retained; Explore again to create new alternatives.",
    )?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn policy() -> Result<Policy, Error> {
        compile(
            16,
            json!({"eos_token_id": [1, 3], "suppress_tokens": [15, 14]}),
            vec![0, 1, 3, 14, 15],
            Some(1),
        )
    }
    #[test]
    fn checkpoint_masks_are_canonical_and_never_lexical() -> Result<(), Error> {
        let policy = policy()?;
        assert_eq!(policy.suppressed_token_ids, vec![14, 15]);
        assert_eq!(policy.eos_token_ids, vec![1, 3]);
        assert!(admit(Some(&policy), &policy)?);
        for config in [
            json!({"eos_token_id": 1}),
            json!({"eos_token_id": 1, "suppress_tokens": [1]}),
            json!({"eos_token_id": 1, "suppress_tokens": [14, 14]}),
            json!({"eos_token_id": 1, "suppress_tokens": [16]}),
            json!({"eos_token_id": 1, "suppress_tokens": [7]}),
            json!({"eos_token_id": [], "suppress_tokens": []}),
        ] {
            assert!(compile(16, config, vec![0, 1, 3, 14, 15], None).is_err());
        }
        Ok(())
    }
    #[test]
    fn replay_never_silently_adopts_changed_or_unrecorded_policy() -> Result<(), Error> {
        let policy = policy()?;
        assert!(admit(None, &policy).is_err());
        let mut changed = policy.clone();
        changed.suppressed_token_ids.clear();
        assert!(admit(Some(&changed), &policy).is_err());
        let mut legacy = policy.clone();
        legacy.text_decoding = None;
        legacy.validate()?;
        assert!(admit(Some(&legacy), &policy).is_err());
        let mut encoded = serde_json::to_value(&policy).expect("policy is serializable");
        encoded
            .as_object_mut()
            .expect("policy is an object")
            .remove("textDecoding");
        assert_eq!(
            serde_json::from_value::<Policy>(encoded.clone()).expect("legacy policy"),
            legacy
        );
        encoded["textDecoding"] = json!("unknown_decoder");
        assert!(serde_json::from_value::<Policy>(encoded).is_err());
        changed.schema = 2;
        assert!(admit(Some(&changed), &changed).is_err());
        Ok(())
    }
}
