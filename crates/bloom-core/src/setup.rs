//! Automatic setup decisions without filesystem, download or GPU authority.
use crate::{Error, checkpoint::Purpose, memory, require};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Candidate {
    pub identity: String,
    pub purpose: Purpose,
    pub weight_bytes: u64,
    pub disk_bytes: u64,
    pub cached: bool,
    pub rank: u8,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub consultation: String,
    pub writing: Option<String>,
    pub reuse_consultation: bool,
    pub weight_limit_bytes: u64,
    pub total_weight_bytes: u64,
    pub required_disk_bytes: u64,
}

pub fn admit_weights(physical: u64, resident: u64, additional: u64) -> bool {
    additional > 0
        && resident
            .checked_add(additional)
            .is_some_and(|total| total <= physical / 2)
}

fn validate(candidates: &[Candidate]) -> Result<(), Error> {
    require(
        (1..=32).contains(&candidates.len()),
        "Automatic setup requires a bounded model catalog.",
    )?;
    let mut identities = BTreeSet::new();
    for candidate in candidates {
        require(
            !candidate.identity.is_empty()
                && candidate.identity.len() <= 256
                && identities.insert(candidate.identity.as_str())
                && (1..=64 << 30).contains(&candidate.weight_bytes)
                && candidate.disk_bytes <= 64 << 30
                && (!candidate.cached || candidate.disk_bytes == 0),
            "Invalid or repeated automatic model candidate.",
        )?;
    }
    Ok(())
}
fn order(candidates: &mut [Candidate]) {
    candidates.sort_by(|a, b| {
        (!a.cached, a.rank, a.weight_bytes, &a.identity).cmp(&(
            !b.cached,
            b.rank,
            b.weight_bytes,
            &b.identity,
        ))
    });
}
fn fits(
    physical: u64,
    metal: u64,
    resident: u64,
    disk: u64,
    weights: u64,
    required_disk: u64,
) -> Result<bool, Error> {
    Ok(admit_weights(physical, 0, weights)
        && required_disk <= disk
        && memory::admit_load(physical, metal, resident, weights)?)
}
/// The picker and automatic plan share validation, ordering and admission.
pub fn eligible(
    physical: u64,
    metal: u64,
    resident: u64,
    disk: u64,
    mut candidates: Vec<Candidate>,
) -> Result<Vec<String>, Error> {
    validate(&candidates)?;
    order(&mut candidates);
    let mut identities = Vec::new();
    for candidate in candidates {
        if fits(
            physical,
            metal,
            resident,
            disk,
            candidate.weight_bytes,
            candidate.disk_bytes,
        )? {
            identities.push(candidate.identity);
        }
    }
    Ok(identities)
}

pub fn plan(
    physical: u64,
    metal: u64,
    resident: u64,
    disk: u64,
    writing: bool,
    mut candidates: Vec<Candidate>,
) -> Result<Plan, Error> {
    validate(&candidates)?;
    order(&mut candidates);
    let fits =
        |weights, required_disk| fits(physical, metal, resident, disk, weights, required_disk);
    let mut consultation = None;
    for candidate in &candidates {
        if candidate.purpose == Purpose::Consultation
            && fits(candidate.weight_bytes, candidate.disk_bytes)?
        {
            consultation = Some(candidate);
            break;
        }
    }
    let consultation = consultation.ok_or_else(|| Error(
        "No available local model fits this Mac's memory and free disk space. Free some space and retry setup.".into()
    ))?;
    let mut selected_writing = None;
    if writing {
        for candidate in &candidates {
            if candidate.purpose != Purpose::Writing {
                continue;
            }
            let weights = consultation
                .weight_bytes
                .checked_add(candidate.weight_bytes)
                .ok_or_else(|| Error("Model weight size overflow.".into()))?;
            let needed = consultation
                .disk_bytes
                .checked_add(candidate.disk_bytes)
                .ok_or_else(|| Error("Model disk size overflow.".into()))?;
            if fits(weights, needed)? {
                selected_writing = Some(candidate);
                break;
            }
        }
    }
    Ok(Plan {
        consultation: consultation.identity.clone(),
        writing: selected_writing.map(|c| c.identity.clone()),
        reuse_consultation: writing && selected_writing.is_none(),
        weight_limit_bytes: physical / 2,
        total_weight_bytes: consultation.weight_bytes
            + selected_writing.map_or(0, |c| c.weight_bytes),
        required_disk_bytes: consultation.disk_bytes + selected_writing.map_or(0, |c| c.disk_bytes),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    const GIB: u64 = 1 << 30;
    fn candidate(id: &str, purpose: Purpose, weights: u64, disk: u64, rank: u8) -> Candidate {
        Candidate {
            identity: id.into(),
            purpose,
            weight_bytes: weights,
            disk_bytes: disk,
            cached: disk == 0,
            rank,
        }
    }
    #[test]
    fn picker_uses_the_same_memory_disk_and_cache_ordering() -> Result<(), Error> {
        let candidates = vec![
            candidate("remote", Purpose::Consultation, 4 * GIB, 8 * GIB, 0),
            candidate("cached", Purpose::Writing, 8 * GIB, 0, 2),
            candidate("too-big", Purpose::Consultation, 17 * GIB, 0, 0),
        ];
        assert_eq!(
            eligible(32 * GIB, 24 * GIB, GIB, 0, candidates.clone())?,
            vec!["cached"]
        );
        assert_eq!(
            eligible(32 * GIB, 24 * GIB, GIB, 16 * GIB, candidates)?,
            vec!["cached", "remote"]
        );
        assert!(
            eligible(
                32 * GIB,
                4 * GIB,
                GIB,
                0,
                vec![candidate(
                    "metal-limited",
                    Purpose::Consultation,
                    8 * GIB,
                    0,
                    0
                )]
            )?
            .is_empty()
        );
        Ok(())
    }
    #[test]
    fn cached_pair_fits_but_public_pair_reuses_chat_with_half_ram_limit() -> Result<(), Error> {
        for weights in [7 * GIB, 11 * GIB] {
            let p = plan(
                32 * GIB,
                28 * GIB,
                GIB,
                0,
                true,
                vec![
                    candidate("chat", Purpose::Consultation, weights, 0, 0),
                    candidate("base", Purpose::Writing, weights, 0, 0),
                ],
            )?;
            assert_eq!(p.reuse_consultation, weights == 11 * GIB);
            assert!(p.total_weight_bytes <= 16 * GIB);
            assert_eq!(p.writing.is_some(), weights == 7 * GIB);
        }
        Ok(())
    }
    #[test]
    fn smaller_checkpoint_is_selected_for_memory_or_disk_and_chat_needs_one_model()
    -> Result<(), Error> {
        for (physical, disk) in [(16 * GIB, 20 * GIB), (32 * GIB, 6 * GIB)] {
            let p = plan(
                physical,
                physical,
                GIB / 4,
                disk,
                false,
                vec![
                    candidate("large", Purpose::Consultation, 11 * GIB, 12 * GIB, 0),
                    candidate("small", Purpose::Consultation, 5 * GIB, 6 * GIB, 1),
                ],
            )?;
            assert_eq!(p.consultation, "small");
            assert!(!p.reuse_consultation);
            assert!(p.writing.is_none());
        }
        Ok(())
    }
    #[test]
    fn caches_win_without_network_and_metal_and_loading_reserves_are_respected() -> Result<(), Error>
    {
        let p = plan(
            32 * GIB,
            28 * GIB,
            GIB,
            50 * GIB,
            true,
            vec![
                candidate("download", Purpose::Consultation, 11 * GIB, 12 * GIB, 0),
                candidate("cached", Purpose::Consultation, 5 * GIB, 0, 2),
            ],
        )?;
        assert_eq!(p.consultation, "cached");
        assert_eq!(p.required_disk_bytes, 0);
        assert!(
            plan(
                32 * GIB,
                5 * GIB,
                GIB,
                0,
                false,
                vec![candidate("cached", Purpose::Consultation, 5 * GIB, 0, 0)]
            )
            .is_err()
        );
        assert!(
            plan(
                32 * GIB,
                28 * GIB,
                22 * GIB,
                0,
                false,
                vec![candidate("cached", Purpose::Consultation, GIB, 0, 0)]
            )
            .is_err()
        );
        Ok(())
    }
    #[test]
    fn invalid_catalog_and_arithmetic_cannot_admit_weights() {
        assert!(!admit_weights(u64::MAX, u64::MAX, 1));
        assert!(!admit_weights(32 * GIB, 9 * GIB, 8 * GIB));
        assert!(admit_weights(32 * GIB, 8 * GIB, 8 * GIB));
        assert!(
            plan(
                32 * GIB,
                28 * GIB,
                0,
                0,
                false,
                vec![
                    candidate("same", Purpose::Consultation, GIB, 0, 0),
                    candidate("same", Purpose::Writing, GIB, 0, 0),
                ]
            )
            .is_err()
        );
    }
}
