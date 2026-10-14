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
    pub batch: Option<crate::batch::Execution>,
}

/// The actual prefix lookup result. None on a legacy record means unknown.
/// This descriptor is deliberately not a complete warm replay transcript.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionOrigin {
    pub schema: u32,
    pub cache_algorithm: String,
    pub cached_prompt_tokens: usize,
    pub cache_miss_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub independent_cohort: Option<IndependentTextCohortOrigin>,
}
impl ExecutionOrigin {
    fn valid_identifier(value: &str) -> bool {
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_'))
    }
    fn validate(&self, prompt_tokens: usize, expected: &Identity) -> Result<(), Error> {
        require(
            self.schema == 1
                && prompt_tokens > 0
                && prompt_tokens <= 16_384
                && self.cached_prompt_tokens < prompt_tokens
                && Self::valid_identifier(&self.cache_algorithm)
                && if self.cached_prompt_tokens == 0 {
                    self.cache_miss_reason
                        .as_deref()
                        .is_some_and(Self::valid_identifier)
                } else {
                    self.cache_miss_reason.is_none()
                },
            "Invalid captured execution origin; records retained.",
        )?;
        if let Some(cohort) = &self.independent_cohort {
            cohort.validate(prompt_tokens, self.cached_prompt_tokens, expected)?;
        }
        Ok(())
    }
}

/// Heterogeneous execution provenance, not permission to replay one seed at
/// width one. Other row inputs are digest-bound, never copied between namespaces.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IndependentTextCohortRow {
    #[serde(rename = "operationID")]
    pub operation_id: uuid::Uuid,
    #[serde(rename = "attemptID")]
    pub attempt_id: uuid::Uuid,
    pub namespace: uuid::Uuid,
    #[serde(rename = "recordID")]
    pub record_id: uuid::Uuid,
    pub request_digest: String,
    pub prepared_token_digest: String,
    pub prompt_tokens: usize,
    pub cached_tokens: usize,
    pub seed: u64,
    pub output_limit: usize,
    pub sampling_digest: String,
    #[serde(rename = "cacheParentID")]
    pub cache_parent_id: Option<uuid::Uuid>,
    pub cache_history_digest: String,
    pub cache_lengths: Vec<usize>,
    pub cache_padding: Vec<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CohortPrefillGeometry {
    pub chunking: String,
    pub token_ceiling: usize,
    pub chunk_stride: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IndependentTextCohortOrigin {
    pub schema: u32,
    #[serde(rename = "cohortID")]
    pub cohort_id: uuid::Uuid,
    pub row: usize,
    pub rows: Vec<IndependentTextCohortRow>,
    pub policy_digest: String,
    pub prompt_width: usize,
    pub mask_digest: String,
    pub cache_widths: Vec<usize>,
    pub prefill: CohortPrefillGeometry,
}
impl IndependentTextCohortOrigin {
    fn validate(
        &self,
        prompt_tokens: usize,
        cached_tokens: usize,
        expected: &Identity,
    ) -> Result<(), Error> {
        require(
            self.schema == 1
                && !self.cohort_id.is_nil()
                && (2..=4).contains(&self.rows.len())
                && self.row < self.rows.len()
                && hash(&self.policy_digest)
                && hash(&self.mask_digest)
                && (1..=16_384).contains(&self.prompt_width)
                && (1..=128).contains(&self.cache_widths.len())
                && self.cache_widths.iter().all(|width| *width <= 16_384)
                && matches!(
                    self.prefill.chunking.as_str(),
                    "balanced" | "remainder" | "unchunked"
                )
                && (1..=16_384).contains(&self.prefill.token_ceiling)
                && self
                    .prefill
                    .chunk_stride
                    .is_none_or(|stride| (1..=16_384).contains(&stride)),
            "Invalid independent text cohort geometry; records retained.",
        )?;
        let own = &self.rows[self.row];
        require(
            own.prompt_tokens == prompt_tokens
                && own.cached_tokens == cached_tokens
                && own.operation_id == expected.operation_id
                && own.attempt_id == expected.attempt_id
                && own.record_id == expected.record_id
                && own.seed == expected.seed
                && own.output_limit == expected.max_tokens
                && own.request_digest == expected.request_digest
                && expected.batch.is_none(),
            "Independent cohort does not match this captured attempt; records retained.",
        )?;
        for (index, row) in self.rows.iter().enumerate() {
            require(
                !row.operation_id.is_nil()
                    && !row.attempt_id.is_nil()
                    && !row.namespace.is_nil()
                    && !row.record_id.is_nil()
                    && hash(&row.request_digest)
                    && hash(&row.prepared_token_digest)
                    && hash(&row.sampling_digest)
                    && hash(&row.cache_history_digest)
                    && (1..=16_384).contains(&row.prompt_tokens)
                    && row.cached_tokens < row.prompt_tokens
                    && (1..=4096).contains(&row.output_limit)
                    && row.cache_lengths.len() == self.cache_widths.len()
                    && row.cache_padding.len() == self.cache_widths.len()
                    && self.rows[..index]
                        .iter()
                        .all(|prior| prior.attempt_id != row.attempt_id),
                "Invalid independent cohort row; records retained.",
            )?;
            require(
                self.cache_widths.iter().enumerate().all(|(layer, width)| {
                    row.cache_lengths[layer] <= *width
                        && row.cache_padding[layer] == *width - row.cache_lengths[layer]
                }),
                "Invalid independent cohort padding; records retained.",
            )?;
        }
        require(
            self.rows
                .iter()
                .map(|row| row.prompt_tokens - row.cached_tokens)
                .max()
                == Some(self.prompt_width),
            "Independent cohort mask width differs from its actual suffixes; records retained.",
        )
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_origin: Option<ExecutionOrigin>,
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
    if let Some(origin) = &progress.execution_origin {
        origin.validate(progress.prompt_tokens, expected)?;
        if let Some(cohort) = &origin.independent_cohort {
            require(
                cohort.rows[cohort.row].prepared_token_digest == progress.prompt_digest,
                "Cohort prompt digest differs from the actual row checkpoint; records retained.",
            )?;
        }
    }
    if let Some(batch) = &expected.batch {
        require(
            expected.kind == Kind::Writing,
            "Only writing uses a captured inference batch.",
        )?;
        batch.validate(expected.seed)?;
        crate::batch::admit(
            batch.seeds.len(),
            progress.prompt_tokens,
            expected.max_tokens,
            16_384,
        )?;
    }
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
                && next.progress.execution_origin == previous.progress.execution_origin
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
                batch: None,
            },
            progress: Progress {
                text: "At the shore, 👩🏽‍💻é".into(),
                token_ids: vec![1, 2],
                prompt_digest: "b".repeat(64),
                prompt_tokens: 12,
                first_token_seconds: Some(0.1),
                elapsed_seconds: 0.2,
                execution_origin: None,
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
    fn batch_geometry_is_authenticated_and_cannot_be_changed_on_recovery() -> Result<(), Error> {
        let mut next = checkpoint();
        next.identity.batch = Some(crate::batch::Execution {
            algorithm: "shared-prefill-fixed-batch-v1".into(),
            seeds: vec![17, u64::MAX, 42],
            lane: 1,
        });
        let expected = next.identity.clone();
        validate(&expected, None, next.clone())?;
        let mut changed = next.clone();
        changed
            .identity
            .batch
            .as_mut()
            .ok_or_else(|| Error("Missing fixture batch".into()))?
            .seeds
            .pop();
        assert!(validate(&expected, None, changed.clone()).is_err());
        changed.identity.kind = Kind::Consultation;
        assert!(validate(&changed.identity, None, changed.clone()).is_err());
        changed.identity.kind = Kind::Writing;
        changed.identity.seed = 42;
        assert!(validate(&changed.identity, None, changed.clone()).is_err());
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
            None,
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
    #[test]
    fn origins_bind_actual_prefix_counts_and_cold_miss_reasons() -> Result<(), Error> {
        let base = checkpoint();
        for (count, miss) in [
            (0, Some("no_owner")),
            (0, Some("unsupported_input")),
            (0, Some("residency_evicted")),
            (11, None),
        ] {
            let mut next = base.clone();
            next.progress.execution_origin = Some(ExecutionOrigin {
                schema: 1,
                cache_algorithm: "resident-hybrid-prefix-v3".into(),
                cached_prompt_tokens: count,
                cache_miss_reason: miss.map(str::to_owned),
                independent_cohort: None,
            });
            validate(&next.identity, None, next.clone())?;
            for malformed in ["schema", "algorithm", "miss"] {
                let mut invalid = next.clone();
                let origin = invalid
                    .progress
                    .execution_origin
                    .as_mut()
                    .ok_or_else(|| Error("Missing fixture origin".into()))?;
                match malformed {
                    "schema" => origin.schema = 2,
                    "algorithm" => origin.cache_algorithm = String::new(),
                    _ => {
                        origin.cached_prompt_tokens = 0;
                        origin.cache_miss_reason = Some("free-form content".into());
                    }
                }
                assert!(validate(&base.identity, None, invalid).is_err());
            }
            for (invalid_count, invalid_miss) in [(12, None), (0, None), (1, Some("no_owner"))] {
                let mut invalid = next.clone();
                let origin = invalid
                    .progress
                    .execution_origin
                    .as_mut()
                    .ok_or_else(|| Error("Missing fixture origin".into()))?;
                origin.cached_prompt_tokens = invalid_count;
                origin.cache_miss_reason = invalid_miss.map(str::to_owned);
                assert!(validate(&base.identity, None, invalid).is_err());
            }
        }
        Ok(())
    }
    #[test]
    fn legacy_origins_stay_unknown_and_checkpoints_cannot_change_their_origin() -> Result<(), Error>
    {
        let legacy = checkpoint();
        let wire = serde_json::to_value(&legacy).map_err(|error| Error(error.to_string()))?;
        assert!(wire["progress"].get("executionOrigin").is_none());
        let restored: Checkpoint =
            serde_json::from_value(wire).map_err(|error| Error(error.to_string()))?;
        assert!(restored.progress.execution_origin.is_none());
        validate(&restored.identity, None, restored.clone())?;
        let mut warm = restored.clone();
        warm.progress.execution_origin = Some(ExecutionOrigin {
            schema: 1,
            cache_algorithm: "resident-hybrid-prefix-v3".into(),
            cached_prompt_tokens: 8,
            cache_miss_reason: None,
            independent_cohort: None,
        });
        assert!(validate(&warm.identity, Some(&restored), warm.clone()).is_err());
        let mut cold = warm.clone();
        cold.progress.execution_origin = Some(ExecutionOrigin {
            schema: 1,
            cache_algorithm: "resident-hybrid-prefix-v3".into(),
            cached_prompt_tokens: 0,
            cache_miss_reason: Some("no_owner".into()),
            independent_cohort: None,
        });
        assert!(validate(&warm.identity, Some(&warm), cold).is_err());
        let mut missing = warm.clone();
        missing.progress.execution_origin = None;
        assert!(validate(&warm.identity, Some(&warm), missing).is_err());
        let mut next = warm.clone();
        next.progress.token_ids.push(3);
        next.progress.text.push_str(" more");
        next.progress.elapsed_seconds = 0.3;
        validate(&warm.identity, Some(&warm), next)?;
        Ok(())
    }

    #[test]
    fn independent_origins_bind_row_identity_and_prepared_digest_without_laundering_geometry()
    -> Result<(), Error> {
        let mut next = checkpoint();
        next.identity.kind = Kind::Consultation;
        let row = IndependentTextCohortRow {
            operation_id: next.identity.operation_id,
            attempt_id: next.identity.attempt_id,
            namespace: Uuid::from_u128(20),
            record_id: next.identity.record_id,
            request_digest: next.identity.request_digest.clone(),
            prepared_token_digest: next.progress.prompt_digest.clone(),
            prompt_tokens: 12,
            cached_tokens: 0,
            seed: next.identity.seed,
            output_limit: next.identity.max_tokens,
            sampling_digest: "c".repeat(64),
            cache_parent_id: None,
            cache_history_digest: "d".repeat(64),
            cache_lengths: vec![0],
            cache_padding: vec![4],
        };
        let mut peer = row.clone();
        peer.operation_id = Uuid::from_u128(7);
        peer.attempt_id = Uuid::from_u128(8);
        peer.namespace = Uuid::from_u128(21);
        peer.record_id = Uuid::from_u128(9);
        peer.prompt_tokens = 10;
        peer.cached_tokens = 4;
        peer.cache_lengths = vec![4];
        peer.cache_padding = vec![0];
        peer.cache_parent_id = Some(Uuid::from_u128(30));
        let cohort = IndependentTextCohortOrigin {
            schema: 1,
            cohort_id: Uuid::from_u128(31),
            row: 0,
            rows: vec![row, peer],
            policy_digest: "e".repeat(64),
            prompt_width: 12,
            mask_digest: "f".repeat(64),
            cache_widths: vec![4],
            prefill: CohortPrefillGeometry {
                chunking: "remainder".into(),
                token_ceiling: 512,
                chunk_stride: Some(11),
            },
        };
        next.progress.execution_origin = Some(ExecutionOrigin {
            schema: 1,
            cache_algorithm: "independent-text-cohort-v1".into(),
            cached_prompt_tokens: 0,
            cache_miss_reason: Some("no_active_supported_prefix".into()),
            independent_cohort: Some(cohort),
        });
        let wire = serde_json::to_value(&next).map_err(|e| Error(e.to_string()))?;
        let restored: Checkpoint =
            serde_json::from_value(wire.clone()).map_err(|e| Error(e.to_string()))?;
        assert_eq!(
            restored.progress.execution_origin,
            next.progress.execution_origin
        );
        validate(&next.identity, None, restored)?;
        for field in ["seed", "attemptID", "preparedTokenDigest", "cachePadding"] {
            let mut changed = wire.clone();
            changed["progress"]["executionOrigin"]["independentCohort"]["rows"][0][field] =
                match field {
                    "seed" => serde_json::json!(1),
                    "attemptID" => serde_json::json!(Uuid::from_u128(88)),
                    "preparedTokenDigest" => serde_json::json!("0".repeat(64)),
                    _ => serde_json::json!([0]),
                };
            let changed = serde_json::from_value(changed).map_err(|e| Error(e.to_string()))?;
            assert!(validate(&next.identity, None, changed).is_err(), "{field}");
        }
        let mut changed = next.clone();
        changed
            .progress
            .execution_origin
            .as_mut()
            .expect("Checkpoint fixture has an execution origin")
            .independent_cohort
            .as_mut()
            .expect("Checkpoint fixture has its admitted independent cohort")
            .row = 1;
        assert!(validate(&next.identity, None, changed).is_err());
        // Subsequent checkpoints cannot silently erase a heterogeneous cohort
        // and claim a scalar cold execution for a previously admitted row.
        let mut scalar = next.clone();
        scalar
            .progress
            .execution_origin
            .as_mut()
            .expect("Checkpoint fixture has an execution origin")
            .independent_cohort = None;
        assert!(validate(&next.identity, Some(&next), scalar).is_err());
        Ok(())
    }
}
