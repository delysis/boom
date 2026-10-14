use crate::{Error, require, sampling_policy::Prefill};
use serde::{Deserialize, Serialize};

const GIB: u64 = 1 << 30;
const CONTEXT_CEILING: u64 = 16_384;
const APPLICATION_CEILING: u64 = 24 * GIB;
const WORKING_RESERVE: u64 = 2 * GIB;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub application_bytes: u64,
    pub allocator_bytes: u64,
    pub cache_bytes: u64,
    pub working_reserve_bytes: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FullContextInputs {
    pub context_tokens: u64,
    pub input_tokens: [u64; 2],
    pub output_tokens: u64,
}

/// Qualification preserves its registered workload even under memory pressure.
/// Ordinary admission may shrink; that is a failed gate, never a shorter trial.
pub fn qualification_context(writing: u64, consultation: u64) -> Result<FullContextInputs, Error> {
    require(
        writing == CONTEXT_CEILING && consultation == CONTEXT_CEILING,
        &format!(
            "Full-context qualification requires both {CONTEXT_CEILING}-token contexts; writing admits {writing}, consultation admits {consultation}. The registered workload was not shortened."
        ),
    )?;
    Ok(FullContextInputs {
        context_tokens: CONTEXT_CEILING,
        input_tokens: [CONTEXT_CEILING - 256; 2],
        output_tokens: 256,
    })
}

/// Keeping weights resident is useful only while both ordinary experiences
/// retain their context ceiling. Otherwise the inactive model must make room.
pub fn retain_pair(writing: u64, consultation: u64) -> Result<bool, Error> {
    require(
        writing <= CONTEXT_CEILING && consultation <= CONTEXT_CEILING,
        "Resident context capacity exceeds the configured ceiling.",
    )?;
    Ok(writing == CONTEXT_CEILING && consultation == CONTEXT_CEILING)
}

pub fn limits(physical: u64, metal: u64) -> Limits {
    let os_reserve = (8 * GIB).max(physical / 4);
    let metal_budget = (u128::from(metal) * 85 / 100) as u64;
    let application_bytes = APPLICATION_CEILING
        .min(physical.saturating_sub(os_reserve))
        .min(metal_budget);
    Limits {
        application_bytes,
        allocator_bytes: application_bytes.saturating_sub(GIB),
        cache_bytes: (128 << 20).min(application_bytes / 16),
        working_reserve_bytes: WORKING_RESERVE,
    }
}

pub fn admit_cache_probe(physical: u64, metal: u64, cache: u64) -> Result<bool, Error> {
    let policy = limits(physical, metal);
    require(
        cache > 0
            && cache <= policy.working_reserve_bytes / 2
            && cache <= policy.application_bytes / 16,
        "The allocator-cache probe exceeds the application reserve.",
    )?;
    Ok(true)
}

pub fn admit_load(physical: u64, metal: u64, resident: u64, weights: u64) -> Result<bool, Error> {
    require(weights > 0, "The model has no weight files.")?;
    let policy = limits(physical, metal);
    let available = policy.application_bytes.saturating_sub(resident);
    Ok(policy.working_reserve_bytes < available
        && weights < available - policy.working_reserve_bytes)
}

/// Fields used by the pinned Gemma runtime's full/sliding cache construction.
/// Other checkpoint configuration fields do not affect this calculation.
#[derive(Deserialize)]
pub struct CacheConfiguration {
    num_hidden_layers: u64,
    num_kv_shared_layers: u64,
    num_key_value_heads: u64,
    #[serde(default)]
    num_global_key_value_heads: Option<u64>,
    head_dim: u64,
    global_head_dim: u64,
    attention_k_eq_v: bool,
    sliding_window: u64,
    max_position_embeddings: u64,
    layer_types: Vec<String>,
}

impl CacheConfiguration {
    fn row_bytes(&self, tokens: u64, prefill: Prefill) -> u64 {
        // Float16/bfloat16 K and V, including cache growth rounding, a prefill
        // chunk beside the sliding window, old/new allocation overlap, and
        // the single prefill row during batch expansion. K=V is deliberately
        // counted twice even where the runtime aliases the tensors.
        let positions = tokens.div_ceil(256) * 256;
        let sliding = positions.min(self.sliding_window + u64::from(prefill.token_ceiling));
        let concrete = self.num_hidden_layers - self.num_kv_shared_layers;
        let per_row = self.layer_types[..concrete as usize]
            .iter()
            .map(|kind| {
                if kind == "full_attention" {
                    let heads = if self.attention_k_eq_v {
                        self.num_global_key_value_heads
                            .unwrap_or(self.num_key_value_heads)
                    } else {
                        self.num_key_value_heads
                    };
                    positions * heads * self.global_head_dim * 4
                } else {
                    sliding * self.num_key_value_heads * self.head_dim * 4
                }
            })
            .sum::<u64>();
        per_row
    }
    fn bytes(&self, tokens: u64, width: u64, prefill: Prefill) -> u64 {
        self.row_bytes(tokens, prefill) * (2 * width + u64::from(width > 1))
    }
    fn validate(&self) -> Result<(), Error> {
        require(
            (1..=256).contains(&self.num_hidden_layers)
                && self.num_kv_shared_layers < self.num_hidden_layers
                && (1..=128).contains(&self.num_key_value_heads)
                && self
                    .num_global_key_value_heads
                    .is_none_or(|heads| (1..=128).contains(&heads))
                && (1..=1024).contains(&self.head_dim)
                && (1..=1024).contains(&self.global_head_dim)
                && (1..=262_144).contains(&self.sliding_window)
                && self.max_position_embeddings > 0
                && self.layer_types.len() == self.num_hidden_layers as usize
                && self
                    .layer_types
                    .iter()
                    .all(|kind| kind == "sliding_attention" || kind == "full_attention"),
            "Unsupported model cache configuration.",
        )
    }
}

pub fn context_capacity(
    config: &CacheConfiguration,
    available: u64,
    width: u64,
    prefill: Prefill,
) -> Result<u64, Error> {
    config.validate()?;
    prefill.validate()?;
    require((1..=4).contains(&width), "Invalid inference batch width.")?;
    let budget = available.saturating_sub(WORKING_RESERVE);
    let mut low = 0;
    let mut high = CONTEXT_CEILING.min(config.max_position_embeddings);
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        if config.bytes(middle, width, prefill) <= budget {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    Ok(low)
}

/// Independent rows have two distinct padding extents: the longest cached
/// prefix and the longest new suffix. Original parents are already in measured
/// U. Reserve selected row hydration, padding/concatenation intermediates and
/// final merge, plus old/new forward destinations. No estimated release credit.
pub fn independent_kv_allocation(
    config: &CacheConfiguration,
    prompts: &[u64],
    cached: &[u64],
    outputs: &[u64],
    prefill: Prefill,
    initial: bool,
    value_bytes: u64,
) -> Result<u64, Error> {
    config.validate()?;
    prefill.validate()?;
    let width = prompts.len();
    require(
        (2..=4).contains(&width)
            && cached.len() == width
            && outputs.len() == width
            && matches!(value_bytes, 2 | 4),
        "Invalid independent cache shape.",
    )?;
    let mut prefix = 0;
    let mut suffix = 0;
    let mut output = 0;
    let mut hydration = 0;
    for ((prompt, count), limit) in prompts.iter().zip(cached).zip(outputs) {
        require(
            *prompt > 0
                && *count < *prompt
                && (1..=4096).contains(limit)
                && prompt.checked_add(*limit).is_some_and(|total| {
                    total <= CONTEXT_CEILING.min(config.max_position_embeddings)
                }),
            "Independent row exceeds its actual context ceiling.",
        )?;
        prefix = prefix.max(*count);
        suffix = suffix.max(prompt - count);
        output = output.max(*limit);
        if initial && *count > 0 {
            hydration += config.row_bytes(*count, prefill);
        }
    }
    // Bounds above cap every intermediate; the configured dimensions are also
    // validated before this arithmetic. Even maximally ragged physical padding
    // is distinct from each row's RoPE/accepted logical length.
    let padded = prefix + suffix + output;
    let forward = config.row_bytes(padded, prefill) * 2 * width as u64;
    let merge = if initial && prefix > 0 {
        config.row_bytes(prefix, prefill) * 3 * width as u64 + hydration
    } else {
        0
    };
    // Existing row algebra is for 2-byte values. A cold Gemma request reserves
    // float32; after submission its real parent dtype supplies this multiplier.
    forward
        .checked_add(merge)
        .and_then(|bytes| bytes.checked_mul(value_bytes / 2))
        .ok_or_else(|| Error("Independent allocation overflowed.".into()))
}

/// Caller-supplied native shape/capacity bytes at a joined, measured boundary.
/// Existing source parents are already in used_bytes; no release credit exists.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IncrementalKvAllocation {
    destination_bytes: u64,
    zero_extension_bytes: u64,
    hydration_bytes: u64,
    shared_prefill_bytes: u64,
    grows: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncrementalKvAdmission {
    pub admitted: bool,
    pub additional_bytes_upper_bound: u64,
    pub required_bytes: u64,
    pub scope: &'static str,
}

pub fn incremental_kv_admission(
    application: u64,
    used: u64,
    reserve: u64,
    layers: &[IncrementalKvAllocation],
) -> Result<IncrementalKvAdmission, Error> {
    require(
        application <= APPLICATION_CEILING
            && reserve == WORKING_RESERVE
            && (1..=256).contains(&layers.len()),
        "Invalid incremental native KV admission boundary.",
    )?;
    let checked_add = |a: u64, b: u64| {
        a.checked_add(b)
            .ok_or_else(|| Error("Native KV allocation bound overflowed.".into()))
    };
    let mut additional = 0;
    for layer in layers {
        require(
            layer.destination_bytes > 0
                && layer.zero_extension_bytes <= layer.destination_bytes
                && layer.shared_prefill_bytes <= layer.destination_bytes,
            "Invalid native KV allocation dimensions.",
        )?;
        // No-growth SliceUpdate may need a complete destination COW. Growth
        // may hold zero extension + concatenate output + SliceUpdate output.
        let update = if layer.grows {
            checked_add(
                checked_add(layer.destination_bytes, layer.destination_bytes)?,
                layer.zero_extension_bytes,
            )?
        } else {
            layer.destination_bytes
        };
        additional = checked_add(
            additional,
            checked_add(
                checked_add(update, layer.hydration_bytes)?,
                layer.shared_prefill_bytes,
            )?,
        )?;
    }
    incremental_kv_readmission(application, used, reserve, additional)
}

/// Scalar envelope was derived from actual native layers before graph creation.
/// At an existing submission boundary, used includes queued Metal allocations.
/// No source release, donation or prior GPU completion is credited.
pub fn incremental_kv_readmission(
    application: u64,
    used: u64,
    reserve: u64,
    additional: u64,
) -> Result<IncrementalKvAdmission, Error> {
    require(
        application <= APPLICATION_CEILING && reserve == WORKING_RESERVE && additional > 0,
        "Invalid native KV readmission envelope.",
    )?;
    let required = used
        .checked_add(additional)
        .and_then(|v| v.checked_add(reserve))
        .ok_or_else(|| Error("Native KV allocation bound overflowed.".into()))?;
    Ok(IncrementalKvAdmission {
        admitted: required <= application,
        additional_bytes_upper_bound: additional,
        required_bytes: required,
        scope: "measured_submitted_boundary_allocation_horizon_with_operation_memory_watch",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incremental_admission_keeps_full_cow_and_true_parent_usage() -> Result<(), Error> {
        let layer = IncrementalKvAllocation {
            destination_bytes: 64,
            zero_extension_bytes: 0,
            hydration_bytes: 0,
            shared_prefill_bytes: 0,
            grows: false,
        };
        let used = 24 * GIB - WORKING_RESERVE - 64;
        let fits = incremental_kv_admission(24 * GIB, used, WORKING_RESERVE, &[layer])?;
        assert!(fits.admitted);
        assert_eq!(fits.additional_bytes_upper_bound, 64);
        let layer = IncrementalKvAllocation {
            destination_bytes: 64,
            zero_extension_bytes: 0,
            hydration_bytes: 0,
            shared_prefill_bytes: 0,
            grows: false,
        };
        assert!(!incremental_kv_admission(24 * GIB, used + 1, WORKING_RESERVE, &[layer])?.admitted);
        Ok(())
    }
    #[test]
    fn incremental_growth_includes_extension_and_both_destinations() -> Result<(), Error> {
        let layer = IncrementalKvAllocation {
            destination_bytes: 96,
            zero_extension_bytes: 32,
            hydration_bytes: 16,
            shared_prefill_bytes: 48,
            grows: true,
        };
        let result = incremental_kv_admission(24 * GIB, 0, WORKING_RESERVE, &[layer])?;
        assert_eq!(result.additional_bytes_upper_bound, 2 * 96 + 32 + 16 + 48);
        Ok(())
    }
    #[test]
    fn incremental_native_math_rejects_overflow_and_unsupported_bounds() {
        let layer = IncrementalKvAllocation {
            destination_bytes: u64::MAX,
            zero_extension_bytes: 0,
            hydration_bytes: 0,
            shared_prefill_bytes: 0,
            grows: true,
        };
        assert!(incremental_kv_admission(24 * GIB, 0, WORKING_RESERVE, &[layer]).is_err());
        assert!(incremental_kv_admission(u64::MAX, 0, WORKING_RESERVE, &[]).is_err());
        assert!(incremental_kv_admission(24 * GIB, 0, 0, &[]).is_err());
        let layer = IncrementalKvAllocation {
            destination_bytes: 0,
            zero_extension_bytes: 0,
            hydration_bytes: 0,
            shared_prefill_bytes: 0,
            grows: false,
        };
        assert!(incremental_kv_admission(24 * GIB, 0, WORKING_RESERVE, &[layer]).is_err());
    }
    #[test]
    fn native_readmission_counts_prior_queued_allocations_without_release_credit()
    -> Result<(), Error> {
        let allowance = 128;
        let used = 24 * GIB - WORKING_RESERVE - allowance;
        assert!(incremental_kv_readmission(24 * GIB, used, WORKING_RESERVE, allowance)?.admitted);
        assert!(
            !incremental_kv_readmission(24 * GIB, used + 1, WORKING_RESERVE, allowance)?.admitted
        );
        assert!(
            incremental_kv_readmission(24 * GIB, u64::MAX, WORKING_RESERVE, allowance).is_err()
        );
        assert!(incremental_kv_readmission(24 * GIB, 0, WORKING_RESERVE, 0).is_err());
        Ok(())
    }
    #[test]
    fn paired_weights_cannot_take_the_active_context_budget() -> Result<(), Error> {
        let config = gemma();
        let prefill = Prefill::default();
        let writing = context_capacity(&config, 3 * GIB, 3, prefill)?;
        let consultation = context_capacity(&config, 3 * GIB, 1, prefill)?;
        assert!(writing < CONTEXT_CEILING);
        assert!(!retain_pair(writing, consultation)?);
        assert!(retain_pair(
            context_capacity(&config, 10 * GIB, 3, prefill)?,
            context_capacity(&config, 10 * GIB, 1, prefill)?,
        )?);
        assert!(retain_pair(CONTEXT_CEILING + 1, CONTEXT_CEILING).is_err());
        Ok(())
    }

    #[test]
    fn qualification_keeps_both_full_context_inputs_and_output_reservations() -> Result<(), Error> {
        let inputs = qualification_context(16_384, 16_384)?;
        assert_eq!(inputs.context_tokens, 16_384);
        assert_eq!(inputs.input_tokens, [16_128; 2]);
        assert_eq!(inputs.output_tokens, 256);
        Ok(())
    }

    #[test]
    fn qualification_rejects_reduced_or_changed_admission_instead_of_resizing_the_trial() {
        for (writing, consultation) in [
            (16_128, 16_384),
            (16_384, 16_128),
            (0, 16_384),
            (16_384, 0),
            (16_385, 16_384),
            (u64::MAX, u64::MAX),
        ] {
            assert!(qualification_context(writing, consultation).is_err());
        }
    }

    fn gemma() -> CacheConfiguration {
        CacheConfiguration {
            num_hidden_layers: 48,
            num_kv_shared_layers: 0,
            num_key_value_heads: 8,
            num_global_key_value_heads: Some(1),
            head_dim: 256,
            global_head_dim: 512,
            attention_k_eq_v: true,
            sliding_window: 1024,
            max_position_embeddings: 262_144,
            layer_types: (0..48)
                .map(|index| {
                    if index % 6 == 5 {
                        "full_attention"
                    } else {
                        "sliding_attention"
                    }
                    .into()
                })
                .collect(),
        }
    }

    #[test]
    fn optional_global_heads_match_the_pinned_e_series_runtime() -> Result<(), Error> {
        let mut config = gemma();
        config.num_kv_shared_layers = 20;
        config.attention_k_eq_v = false;
        config.num_global_key_value_heads = None;
        config.num_key_value_heads = 2;
        config.validate()?;
        let absent = serde_json::json!({
            "num_hidden_layers":48,"num_kv_shared_layers":20,"num_key_value_heads":2,
            "num_global_key_value_heads":null,"head_dim":256,"global_head_dim":512,
            "attention_k_eq_v":false,"sliding_window":1024,"max_position_embeddings":262144,
            "layer_types":config.layer_types
        });
        let decoded: CacheConfiguration =
            serde_json::from_value(absent).map_err(|e| Error(e.to_string()))?;
        assert_eq!(
            decoded.bytes(16384, 3, Prefill::default()),
            config.bytes(16384, 3, Prefill::default())
        );
        config.attention_k_eq_v = true;
        let fallback = config.bytes(16384, 1, Prefill::default());
        config.num_global_key_value_heads = Some(2);
        assert_eq!(fallback, config.bytes(16384, 1, Prefill::default()));
        config.num_global_key_value_heads = Some(0);
        assert!(config.validate().is_err());
        Ok(())
    }

    #[test]
    fn application_budget_caps_large_hosts_and_reserves_small_hosts() {
        assert_eq!(limits(128 * GIB, 96 * GIB).application_bytes, 24 * GIB);
        assert_eq!(limits(32 * GIB, 32 * GIB).application_bytes, 24 * GIB);
        assert_eq!(
            limits(32 * GIB, 24 * GIB).application_bytes,
            24 * GIB * 85 / 100
        );
        assert_eq!(limits(8 * GIB, 8 * GIB).application_bytes, 0);
        assert_eq!(limits(u64::MAX, u64::MAX).application_bytes, 24 * GIB);
        let plan = limits(128 * GIB, 96 * GIB);
        assert_eq!(plan.allocator_bytes, 23 * GIB);
        assert_eq!(plan.cache_bytes, 128 << 20);
    }

    #[test]
    fn load_admission_accounts_for_new_residents_and_keeps_the_reserve() -> Result<(), Error> {
        assert!(admit_load(128 * GIB, 96 * GIB, 8 * GIB, 8 * GIB)?);
        assert!(!admit_load(128 * GIB, 96 * GIB, 16 * GIB, 8 * GIB)?);
        assert!(admit_load(32 * GIB, 32 * GIB, 16 * GIB, 6 * GIB - 1)?);
        assert!(!admit_load(32 * GIB, 32 * GIB, 16 * GIB, 6 * GIB)?);
        assert!(!admit_load(32 * GIB, 24 * GIB, 16 * GIB, 6 * GIB - 1)?);
        assert!(!admit_load(8 * GIB, 8 * GIB, 0, 1)?);
        assert!(!admit_load(u64::MAX, u64::MAX, u64::MAX, u64::MAX)?);
        assert!(!admit_load(128 * GIB, 96 * GIB, 0, u64::MAX)?);
        assert!(admit_load(128 * GIB, 96 * GIB, 0, 0).is_err());
        Ok(())
    }

    #[test]
    fn full_context_admission_includes_sliding_growth_and_batch_overlap() -> Result<(), Error> {
        let config = gemma();
        let prefill = Prefill::default();
        let full = config.bytes(16_384, 3, prefill);
        assert_eq!(full, (8 * 16_384 * 512 * 4 + 40 * 1536 * 8 * 256 * 4) * 7);
        assert_eq!(
            context_capacity(&config, full + WORKING_RESERVE, 3, prefill)?,
            16_384
        );
        assert!(context_capacity(&config, full + WORKING_RESERVE - 1, 3, prefill)? < 16_384);
        assert_eq!(context_capacity(&config, WORKING_RESERVE, 3, prefill)?, 0);
        for width in 1..=4 {
            for available in [0, WORKING_RESERVE, 3 * GIB, 5 * GIB, 8 * GIB, u64::MAX] {
                let admitted = context_capacity(&config, available, width, prefill)?;
                assert!(
                    config.bytes(admitted, width, prefill)
                        <= available.saturating_sub(WORKING_RESERVE)
                );
                if admitted < 16_384 {
                    assert!(
                        config.bytes(admitted + 1, width, prefill)
                            > available.saturating_sub(WORKING_RESERVE)
                    );
                }
            }
        }
        Ok(())
    }

    #[test]
    fn configuration_and_geometry_fail_closed() {
        let mut config = gemma();
        assert!(context_capacity(&config, u64::MAX, 0, Prefill::default()).is_err());
        assert!(context_capacity(&config, u64::MAX, 5, Prefill::default()).is_err());
        config.layer_types[0] = "unknown".into();
        assert!(context_capacity(&config, u64::MAX, 1, Prefill::default()).is_err());
        config = gemma();
        config.num_hidden_layers = u64::MAX;
        assert!(context_capacity(&config, u64::MAX, 1, Prefill::default()).is_err());
        config = gemma();
        config.num_kv_shared_layers = 48;
        assert!(context_capacity(&config, u64::MAX, 1, Prefill::default()).is_err());
    }

    #[test]
    fn larger_prefill_is_budgeted_before_admission() -> Result<(), Error> {
        let config = gemma();
        let small = Prefill::default();
        let large = Prefill {
            token_ceiling: 1024,
            ..small
        };
        let available = config.bytes(16_384, 3, small) + WORKING_RESERVE;
        assert_eq!(context_capacity(&config, available, 3, small)?, 16_384);
        assert!(context_capacity(&config, available, 3, large)? < 16_384);
        assert_eq!(
            context_capacity(
                &config,
                config.bytes(16_384, 3, large) + WORKING_RESERVE,
                3,
                large
            )?,
            16_384
        );
        let invalid = Prefill {
            token_ceiling: u32::MAX,
            ..small
        };
        assert!(context_capacity(&config, u64::MAX, 1, invalid).is_err());
        Ok(())
    }

    #[test]
    fn cache_probe_stays_inside_the_existing_reserve() -> Result<(), Error> {
        for cache in [128 << 20, 512 << 20, GIB] {
            assert!(admit_cache_probe(128 * GIB, 96 * GIB, cache)?);
        }
        assert!(admit_cache_probe(128 * GIB, 96 * GIB, 0).is_err());
        assert!(admit_cache_probe(128 * GIB, 96 * GIB, GIB + 1).is_err());
        assert!(admit_cache_probe(8 * GIB, 8 * GIB, 128 << 20).is_err());
        assert!(admit_cache_probe(32 * GIB, GIB, 128 << 20).is_err());
        Ok(())
    }

    #[test]
    fn independent_budget_counts_ragged_padding_and_real_parent_overlap() -> Result<(), Error> {
        let config = gemma();
        let p = Prefill::default();
        let prompts = [511, 512, 513];
        let cold =
            independent_kv_allocation(&config, &prompts, &[0, 0, 0], &[8, 8, 8], p, true, 2)?;
        let ragged =
            independent_kv_allocation(&config, &prompts, &[510, 0, 0], &[8, 8, 8], p, true, 2)?;
        let next =
            independent_kv_allocation(&config, &prompts, &[510, 0, 0], &[8, 8, 8], p, false, 2)?;
        assert_eq!(
            independent_kv_allocation(&config, &prompts, &[510, 0, 0], &[8, 8, 8], p, true, 4)?,
            ragged * 2
        );
        assert!(
            independent_kv_allocation(&config, &prompts, &[0, 0, 0], &[8, 8, 8], p, true, 1)
                .is_err()
        );
        assert!(ragged > cold && ragged > next);
        assert_eq!(next, config.row_bytes(510 + 513 + 8, p) * 6);
        let used = 24 * GIB - WORKING_RESERVE - ragged;
        assert!(incremental_kv_readmission(24 * GIB, used, WORKING_RESERVE, ragged)?.admitted);
        assert!(!incremental_kv_readmission(24 * GIB, used + 1, WORKING_RESERVE, ragged)?.admitted);
        for cached in [&[511, 0, 0][..], &[0, 0][..]] {
            assert!(
                independent_kv_allocation(&config, &prompts, cached, &[8, 8, 8], p, true, 2)
                    .is_err()
            );
        }
        assert!(
            independent_kv_allocation(&config, &[16_384, 512], &[0, 0], &[1, 8], p, true, 2)
                .is_err()
        );
        Ok(())
    }
}
