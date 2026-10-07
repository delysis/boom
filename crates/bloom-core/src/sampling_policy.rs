//! Checkpoint-authored control tokens are policy, not lexical prose filters.
use crate::{Error, require};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum TextDecoding {
    #[serde(rename = "checkpoint_raw_v1")]
    CheckpointRawV1,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum PrefillChunking {
    #[serde(rename = "balanced_v1")]
    BalancedV1,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Prefill {
    pub chunking: PrefillChunking,
    pub token_ceiling: u32,
}

impl Default for Prefill {
    fn default() -> Self {
        Self {
            chunking: PrefillChunking::BalancedV1,
            token_ceiling: 512,
        }
    }
}

impl Prefill {
    pub fn validate(self) -> Result<(), Error> {
        require(
            matches!(self.token_ceiling, 256 | 512 | 1024),
            "Unsupported prefill geometry.",
        )
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefill: Option<Prefill>,
}

impl Policy {
    pub fn validate(&self) -> Result<(), Error> {
        if let Some(prefill) = self.prefill {
            prefill.validate()?;
        }
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
    #[serde(default)]
    suppress_tokens: Vec<u32>,
}

pub fn compile(
    vocabulary_size: u32,
    configuration: serde_json::Value,
    mut control_token_ids: Vec<u32>,
    tokenizer_eos: Option<u32>,
    prefill_tokens: Option<u32>,
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
        prefill: Some(Prefill {
            token_ceiling: prefill_tokens.unwrap_or(Prefill::default().token_ceiling),
            ..Prefill::default()
        }),
    };
    policy.validate()?;
    Ok(policy)
}

pub fn admit(captured: Option<&Policy>, loaded: &Policy) -> Result<bool, Error> {
    loaded.validate()?;
    require(
        loaded.text_decoding.is_some() && loaded.prefill.is_some(),
        "The loaded model must declare decoding and prefill geometry.",
    )?;
    let captured = captured.ok_or_else(|| Error(
        "This continuation cannot be replayed in this build. The original is saved; Explore creates a new set.".into()))?;
    captured.validate()?;
    require(
        captured == loaded,
        "Replay requires the original model settings. Your saved continuations were retained; Explore creates a new set.",
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
            None,
        )
    }
    #[test]
    fn checkpoint_masks_are_canonical_and_never_lexical() -> Result<(), Error> {
        let policy = policy()?;
        assert_eq!(policy.suppressed_token_ids, vec![14, 15]);
        assert_eq!(policy.eos_token_ids, vec![1, 3]);
        assert!(admit(Some(&policy), &policy)?);
        let unsuppressed = compile(
            16,
            json!({"eos_token_id": 1}),
            vec![0, 1, 3, 14, 15],
            None,
            None,
        )?;
        assert!(unsuppressed.suppressed_token_ids.is_empty());
        for config in [
            json!({"eos_token_id": 1, "suppress_tokens": "invalid"}),
            json!({"eos_token_id": 1, "suppress_tokens": [1]}),
            json!({"eos_token_id": 1, "suppress_tokens": [14, 14]}),
            json!({"eos_token_id": 1, "suppress_tokens": [16]}),
            json!({"eos_token_id": 1, "suppress_tokens": [7]}),
            json!({"eos_token_id": [], "suppress_tokens": []}),
        ] {
            assert!(compile(16, config, vec![0, 1, 3, 14, 15], None, None).is_err());
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

    #[test]
    fn prefill_geometry_is_bounded_and_part_of_replay_identity() -> Result<(), Error> {
        let steady = policy()?;
        assert_eq!(steady.prefill, Some(Prefill::default()));
        let wider = compile(
            16,
            json!({"eos_token_id":1,"suppress_tokens":[]}),
            vec![0, 1, 3, 14, 15],
            Some(1),
            Some(1024),
        )?;
        let mut changed = steady.clone();
        changed.prefill = wider.prefill;
        changed.validate()?;
        assert!(admit(Some(&changed), &steady).is_err());
        assert!(admit(Some(&changed), &changed)?);
        changed.prefill = None;
        changed.validate()?;
        assert!(admit(Some(&changed), &steady).is_err());
        for ceiling in [0, 1, 255, 257, 511, 513, 1025, u32::MAX] {
            assert!(
                compile(
                    16,
                    json!({"eos_token_id":1,"suppress_tokens":[]}),
                    vec![0, 1],
                    Some(1),
                    Some(ceiling)
                )
                .is_err()
            );
        }
        let mut captured = serde_json::to_value(&steady).map_err(|e| Error(e.to_string()))?;
        captured["prefill"]["chunking"] = json!("unknown_chunking");
        assert!(serde_json::from_value::<Policy>(captured).is_err());
        Ok(())
    }

    #[test]
    fn smaller_prefill_is_captured_without_changing_the_default() -> Result<(), Error> {
        let default = policy()?;
        let smaller = compile(
            16,
            json!({"eos_token_id":1,"suppress_tokens":[]}),
            vec![0, 1, 3, 14, 15],
            Some(1),
            Some(256),
        )?;
        assert_eq!(Prefill::default().token_ceiling, 512);
        assert_eq!(default.prefill, Some(Prefill::default()));
        assert_eq!(
            smaller.prefill,
            Some(Prefill {
                token_ceiling: 256,
                ..Prefill::default()
            })
        );
        assert!(admit(Some(&smaller), &smaller)?);
        assert!(admit(Some(&smaller), &default).is_err());
        assert!(admit(Some(&default), &smaller).is_err());
        let encoded = serde_json::to_vec(&smaller).map_err(|e| Error(e.to_string()))?;
        let restored: Policy =
            serde_json::from_slice(&encoded).map_err(|e| Error(e.to_string()))?;
        assert_eq!(restored, smaller);
        Ok(())
    }
}
