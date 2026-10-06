//! A batch's row order is part of seeded replay, not a scheduling detail.
use crate::{Error, require};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Execution {
    pub algorithm: String,
    pub seeds: Vec<u64>,
    pub lane: usize,
}

impl Execution {
    pub fn validate(&self, seed: u64) -> Result<bool, Error> {
        require(
            self.algorithm == "shared-prefill-fixed-batch-v1"
                && (2..=4).contains(&self.seeds.len())
                && self.seeds.get(self.lane) == Some(&seed),
            "The continuation's captured batch or seed is invalid; records retained.",
        )?;
        Ok(true)
    }
}

pub fn admit(width: usize, prompt: usize, output: usize, capacity: usize) -> Result<bool, Error> {
    require(
        (1..=4).contains(&width)
            && prompt > 0
            && (1..=256).contains(&output)
            && (1..=16_384).contains(&capacity)
            && prompt
                .checked_add(output)
                .is_some_and(|total| total <= capacity),
        "The captured alternatives exceed the available batch context; nothing was generated.",
    )?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_order_width_and_seed_are_replay_identity() -> Result<(), Error> {
        let mut execution = Execution {
            algorithm: "shared-prefill-fixed-batch-v1".into(),
            seeds: vec![0, u64::MAX, 17],
            lane: 1,
        };
        assert!(execution.validate(u64::MAX)?);
        assert!(execution.validate(17).is_err());
        execution.seeds.swap(0, 1);
        assert!(execution.validate(u64::MAX).is_err());
        execution.lane = 3;
        assert!(execution.validate(0).is_err());
        execution.lane = 0;
        execution.seeds = vec![0; 5];
        assert!(execution.validate(0).is_err());
        execution.seeds = vec![0, 0]; // Independent rows may intentionally share a seed.
        assert!(execution.validate(0)?);
        execution.algorithm = "future".into();
        assert!(execution.validate(0).is_err());
        Ok(())
    }

    #[test]
    fn exact_context_boundary_and_overflow_fail_closed() -> Result<(), Error> {
        assert!(admit(3, 16_128, 256, 16_384)?);
        assert!(admit(3, 16_129, 256, 16_384).is_err());
        assert!(admit(4, usize::MAX, 256, 16_384).is_err());
        for width in [0, 5, usize::MAX] {
            assert!(admit(width, 100, 64, 1024).is_err());
        }
        assert!(admit(3, 0, 64, 1024).is_err());
        assert!(admit(3, 100, 257, 1024).is_err());
        assert!(admit(3, 100, 64, 16_385).is_err());
        Ok(())
    }
}
