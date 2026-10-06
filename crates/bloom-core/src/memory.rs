use crate::{Error, require};
use serde::{Deserialize, Serialize};

const GIB: u64 = 1 << 30;
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

/// Fields used by the pinned Gemma runtime's full/sliding cache construction.
/// Other checkpoint configuration fields do not affect this calculation.
#[derive(Deserialize)]
pub struct CacheConfiguration {
    num_hidden_layers: u64,
    num_kv_shared_layers: u64,
    num_key_value_heads: u64,
    num_global_key_value_heads: u64,
    head_dim: u64,
    global_head_dim: u64,
    attention_k_eq_v: bool,
    sliding_window: u64,
    max_position_embeddings: u64,
    layer_types: Vec<String>,
}

impl CacheConfiguration {
    fn bytes(&self, tokens: u64, width: u64) -> u64 {
        // Float16/bfloat16 K and V, including cache growth rounding, a prefill
        // chunk beside the sliding window, old/new allocation overlap, and
        // the single prefill row during batch expansion. K=V is deliberately
        // counted twice even where the runtime aliases the tensors.
        let positions = tokens.div_ceil(256) * 256;
        let sliding = positions.min(self.sliding_window + 512);
        let concrete = self.num_hidden_layers - self.num_kv_shared_layers;
        let per_row = self.layer_types[..concrete as usize]
            .iter()
            .map(|kind| {
                if kind == "full_attention" {
                    let heads = if self.attention_k_eq_v {
                        self.num_global_key_value_heads
                    } else {
                        self.num_key_value_heads
                    };
                    positions * heads * self.global_head_dim * 4
                } else {
                    sliding * self.num_key_value_heads * self.head_dim * 4
                }
            })
            .sum::<u64>();
        per_row * (2 * width + u64::from(width > 1))
    }
    fn validate(&self) -> Result<(), Error> {
        require(
            (1..=256).contains(&self.num_hidden_layers)
                && self.num_kv_shared_layers < self.num_hidden_layers
                && (1..=128).contains(&self.num_key_value_heads)
                && (1..=128).contains(&self.num_global_key_value_heads)
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
) -> Result<u64, Error> {
    config.validate()?;
    require((1..=4).contains(&width), "Invalid inference batch width.")?;
    let budget = available.saturating_sub(WORKING_RESERVE);
    let mut low = 0;
    let mut high = 16_384.min(config.max_position_embeddings);
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        if config.bytes(middle, width) <= budget {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    Ok(low)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gemma() -> CacheConfiguration {
        CacheConfiguration {
            num_hidden_layers: 48,
            num_kv_shared_layers: 0,
            num_key_value_heads: 8,
            num_global_key_value_heads: 1,
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
    fn full_context_admission_includes_sliding_growth_and_batch_overlap() -> Result<(), Error> {
        let config = gemma();
        let full = config.bytes(16_384, 3);
        assert_eq!(full, (8 * 16_384 * 512 * 4 + 40 * 1536 * 8 * 256 * 4) * 7);
        assert_eq!(
            context_capacity(&config, full + WORKING_RESERVE, 3)?,
            16_384
        );
        assert!(context_capacity(&config, full + WORKING_RESERVE - 1, 3)? < 16_384);
        assert_eq!(context_capacity(&config, WORKING_RESERVE, 3)?, 0);
        for width in 1..=4 {
            for available in [0, WORKING_RESERVE, 3 * GIB, 5 * GIB, 8 * GIB, u64::MAX] {
                let admitted = context_capacity(&config, available, width)?;
                assert!(config.bytes(admitted, width) <= available.saturating_sub(WORKING_RESERVE));
                if admitted < 16_384 {
                    assert!(
                        config.bytes(admitted + 1, width)
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
        assert!(context_capacity(&config, u64::MAX, 0).is_err());
        assert!(context_capacity(&config, u64::MAX, 5).is_err());
        config.layer_types[0] = "unknown".into();
        assert!(context_capacity(&config, u64::MAX, 1).is_err());
        config = gemma();
        config.num_hidden_layers = u64::MAX;
        assert!(context_capacity(&config, u64::MAX, 1).is_err());
        config = gemma();
        config.num_kv_shared_layers = 48;
        assert!(context_capacity(&config, u64::MAX, 1).is_err());
    }
}
