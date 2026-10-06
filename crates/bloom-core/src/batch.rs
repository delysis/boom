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

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvaluationGroup {
    pub id: String,
    pub fixture: usize,
    pub profile: String,
    pub seeds: Vec<u64>,
    pub names: Vec<String>,
    pub replay_of: Option<String>,
}

/// Evaluate the product's three-row shape, then replay every row after other
/// profiles have run. A remainder keeps its original width and seed order.
pub fn evaluation_plan(fixtures: usize, seeds: &[u64]) -> Result<Vec<EvaluationGroup>, Error> {
    require(
        (1..=16).contains(&fixtures)
            && (1..=16).contains(&seeds.len())
            && seeds.iter().collect::<std::collections::HashSet<_>>().len() == seeds.len(),
        "Use one to sixteen fixtures and distinct seeds.",
    )?;
    let mut groups = Vec::new();
    for fixture in 0..fixtures {
        for replay in [false, true] {
            for profile in ["steady", "standard", "open"] {
                for (index, seeds) in seeds.chunks(3).enumerate() {
                    let original = format!("fixture-{fixture}-{profile}-batch-{index}");
                    let suffix = if replay { "-replay" } else { "" };
                    groups.push(EvaluationGroup {
                        id: format!("{original}{suffix}"),
                        fixture,
                        profile: profile.into(),
                        seeds: seeds.to_vec(),
                        names: seeds
                            .iter()
                            .map(|seed| format!("fixture-{fixture}-{profile}-{seed}{suffix}"))
                            .collect(),
                        replay_of: replay.then_some(original),
                    });
                }
            }
        }
    }
    Ok(groups)
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

    #[test]
    fn evaluation_replays_the_same_rows_after_intervening_profiles() -> Result<(), Error> {
        let seeds = [42, 2026, u64::MAX, 0, 17];
        let groups = evaluation_plan(2, &seeds)?;
        assert_eq!(groups.len(), 24);
        assert_eq!(groups[0].seeds, seeds[..3]);
        assert_eq!(groups[1].seeds, seeds[3..]);
        assert_eq!(groups[2].profile, "standard");
        assert_eq!(groups[4].profile, "open");
        for replay in groups.iter().filter(|group| group.replay_of.is_some()) {
            let position = groups.iter().position(|group| group.id == replay.id);
            let original = groups
                .iter()
                .position(|group| Some(&group.id) == replay.replay_of.as_ref());
            let (Some(position), Some(original)) = (position, original) else {
                return Err(Error("Missing evaluation replay identity".into()));
            };
            assert!(position > original + 1);
            assert_eq!(groups[original].fixture, replay.fixture);
            assert_eq!(groups[original].profile, replay.profile);
            assert_eq!(groups[original].seeds, replay.seeds);
            for (name, replay_name) in groups[original].names.iter().zip(&replay.names) {
                assert_eq!(replay_name, &format!("{name}-replay"));
            }
        }
        Ok(())
    }

    #[test]
    fn evaluation_bounds_and_all_seed_widths_keep_complete_unique_coverage() -> Result<(), Error> {
        for count in 1..=16 {
            let seeds: Vec<u64> = (0..count).collect();
            let groups = evaluation_plan(16, &seeds)?;
            let names: Vec<_> = groups.iter().flat_map(|group| &group.names).collect();
            assert_eq!(names.len(), 16 * 3 * 2 * count as usize);
            assert_eq!(
                names.iter().collect::<std::collections::HashSet<_>>().len(),
                names.len()
            );
            assert!(
                groups
                    .iter()
                    .all(|group| (1..=3).contains(&group.seeds.len()))
            );
            for fixture in 0..16 {
                for profile in ["steady", "standard", "open"] {
                    for replay in [false, true] {
                        let supplied: Vec<_> = groups
                            .iter()
                            .filter(|group| {
                                group.fixture == fixture
                                    && group.profile == profile
                                    && group.replay_of.is_some() == replay
                            })
                            .flat_map(|group| group.seeds.iter().copied())
                            .collect();
                        assert_eq!(supplied, seeds);
                    }
                }
            }
        }
        for fixtures in [0, 17, usize::MAX] {
            assert!(evaluation_plan(fixtures, &[42]).is_err());
        }
        assert!(evaluation_plan(1, &[]).is_err());
        assert!(evaluation_plan(1, &[42, 42]).is_err());
        assert!(evaluation_plan(1, &(0..17).collect::<Vec<_>>()).is_err());
        Ok(())
    }
}
