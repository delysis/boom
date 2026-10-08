//! Cheap deterministic shot probes, bounded visual coverage, and timed sound.
//! This is a sampling heuristic, not a claim to semantic scene understanding.
use crate::{Error, require};
use serde::{Deserialize, Serialize};

pub const COVERAGE_MS: u64 = 60_000;
pub const GAP_MS: u64 = 5_000;
const MAX_FRAMES: usize = 16;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioWindow {
    pub start_ms: u64,
    pub end_ms: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanPlan {
    pub covered_ms: u64,
    pub probe_times_ms: Vec<u64>,
    pub audio_windows: Vec<AudioWindow>,
}
pub fn scan_plan(duration_ms: u64) -> Result<ScanPlan, Error> {
    require(
        duration_ms > 0 && duration_ms <= 7_200_000,
        "Invalid storyboard duration.",
    )?;
    let covered_ms = duration_ms.min(COVERAGE_MS);
    Ok(ScanPlan {
        covered_ms,
        probe_times_ms: (0..covered_ms).step_by(250).collect(),
        audio_windows: (0..covered_ms)
            .step_by(30_000)
            .map(|start_ms| AudioWindow {
                start_ms,
                end_ms: (start_ms + 30_000).min(covered_ms),
            })
            .collect(),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Probe {
    pub at_ms: u64,
    // A fixed 32x18 RGB thumbnail, independent of decoder pixel layout.
    pub rgb: Vec<u8>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub indices: Vec<usize>,
    pub covered_ms: u64,
    pub detected_cuts: usize,
    pub omitted_cuts: usize,
}

fn distance(a: &Probe, b: &Probe) -> f64 {
    a.rgb
        .iter()
        .zip(&b.rgb)
        .map(|(a, b)| f64::from(a.abs_diff(*b)))
        .sum::<f64>()
        / (a.rgb.len() as f64 * 255.0)
}

pub fn select(duration_ms: u64, probes: &[Probe]) -> Result<Selection, Error> {
    let covered_ms = duration_ms.min(COVERAGE_MS);
    require(
        duration_ms > 0 && duration_ms <= 7_200_000 && !probes.is_empty() && probes.len() <= 242,
        "Invalid storyboard duration or probe budget.",
    )?;
    require(
        probes
            .iter()
            .all(|p| p.rgb.len() == 32 * 18 * 3 && p.at_ms < covered_ms)
            && probes[0].at_ms <= 250
            && covered_ms - probes.last().map_or(0, |p| p.at_ms) <= GAP_MS
            && probes
                .windows(2)
                .all(|p| p[0].at_ms < p[1].at_ms && p[1].at_ms - p[0].at_ms <= GAP_MS),
        "Invalid storyboard probe coverage.",
    )?;
    let mut cuts = Vec::new();
    let mut previous_delta = 0.0_f64;
    for i in 1..probes.len() {
        let delta = distance(&probes[i - 1], &probes[i]);
        // Persistent abrupt changes: discount sustained motion and one-probe
        // flashes. RGB catches isoluminant cuts that grayscale would miss.
        let spike = delta - previous_delta * 0.5;
        let persists =
            i + 1 < probes.len() && distance(&probes[i - 1], &probes[i + 1]) >= delta * 0.65;
        if delta >= 0.12
            && spike >= 0.10
            && persists
            && !(i >= 2 && distance(&probes[i - 2], &probes[i]) < 0.08)
        {
            cuts.push((i, spike));
        }
        previous_delta = delta;
    }
    let mut indices = vec![0];
    // Coverage is a hard constraint. Scene ranking cannot create a long blind gap.
    while covered_ms - probes[*indices.last().expect("initial frame")].at_ms > GAP_MS {
        let last = *indices.last().expect("initial frame");
        let target = probes[last].at_ms + GAP_MS;
        let next = probes
            .iter()
            .enumerate()
            .skip(last + 1)
            .take_while(|(_, p)| p.at_ms <= target)
            .last()
            .map(|(i, _)| i)
            .ok_or_else(|| Error("Storyboard coverage cannot advance.".into()))?;
        indices.push(next);
    }
    cuts.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    for &(i, _) in &cuts {
        if indices.len() == MAX_FRAMES {
            break;
        }
        if !indices.contains(&i) {
            indices.push(i);
        }
    }
    indices.sort_unstable();
    // Cut representatives can make a periodic anchor redundant. Remove only
    // non-cut anchors whose neighbors still satisfy the coverage constraint.
    let mut position = 1;
    while position < indices.len() {
        let next_time = indices
            .get(position + 1)
            .map_or(covered_ms, |i| probes[*i].at_ms);
        if !cuts.iter().any(|(i, _)| *i == indices[position])
            && next_time - probes[indices[position - 1]].at_ms <= GAP_MS
        {
            indices.remove(position);
        } else {
            position += 1;
        }
    }
    for &(i, _) in &cuts {
        if indices.len() == MAX_FRAMES {
            break;
        }
        if !indices.contains(&i) {
            indices.push(i);
        }
    }
    indices.sort_unstable();
    let omitted_cuts = cuts.iter().filter(|(i, _)| !indices.contains(i)).count();
    Ok(Selection {
        indices,
        covered_ms,
        detected_cuts: cuts.len(),
        omitted_cuts,
    })
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioSegment {
    pub start_ms: u64,
    pub end_ms: u64,
    pub digest: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Timeline {
    pub duration_ms: u64,
    pub covered_ms: u64,
    pub frame_times_ms: Vec<u64>,
    pub audio: Vec<AudioSegment>,
    pub detected_cuts: usize,
    pub omitted_cuts: usize,
    #[serde(default)]
    pub soundtrack_omitted: bool,
}

impl Timeline {
    pub fn validate(&self, frames: usize) -> Result<(), Error> {
        require(
            self.duration_ms > 0
                && self.duration_ms <= 7_200_000
                && self.covered_ms == self.duration_ms.min(COVERAGE_MS)
                && (1..=MAX_FRAMES).contains(&frames)
                && self.frame_times_ms.len() == frames
                && self.frame_times_ms[0] <= 250
                && self.frame_times_ms.iter().all(|t| *t < self.covered_ms)
                && self.covered_ms - self.frame_times_ms[frames - 1] <= GAP_MS
                && self
                    .frame_times_ms
                    .windows(2)
                    .all(|t| t[0] < t[1] && t[1] - t[0] <= GAP_MS)
                && self.detected_cuts <= 241
                && self.omitted_cuts <= self.detected_cuts,
            "Invalid storyboard timeline.",
        )?;
        require(
            !self.soundtrack_omitted || self.audio.is_empty(),
            "Omitted soundtrack contains audio segments.",
        )?;
        if !self.audio.is_empty() {
            let windows = scan_plan(self.duration_ms)?.audio_windows;
            require(
                self.audio.len() == windows.len(),
                "Soundtrack window count changed.",
            )?;
            for (clip, window) in self.audio.iter().zip(windows) {
                let start = window.start_ms;
                let end = window.end_ms;
                require(
                    clip.start_ms == start
                        && clip.end_ms == end
                        && start < end
                        && end - start <= 30_000
                        && clip.digest.len() == 64
                        && clip.digest.bytes().all(|b| b.is_ascii_hexdigit()),
                    "Invalid soundtrack interval or identity.",
                )?;
            }
        }
        Ok(())
    }

    pub fn prompt_content(&self) -> String {
        let mut text = String::new();
        let mut audio_index = 0;
        for (i, at) in self.frame_times_ms.iter().enumerate() {
            text.push_str(&format!(
                "[Video {:02}:{:02}.{:03}]\n<|video|>\n",
                at / 60_000,
                at / 1_000 % 60,
                at % 1_000
            ));
            let window_end = self
                .frame_times_ms
                .get(i + 1)
                .copied()
                .unwrap_or(self.covered_ms);
            while let Some(audio) = self
                .audio
                .get(audio_index)
                .filter(|audio| audio.end_ms <= window_end)
            {
                text.push_str(&format!(
                    "[Sound {:.3}–{:.3}s]\n<|audio|>\n",
                    audio.start_ms as f64 / 1000.0,
                    audio.end_ms as f64 / 1000.0
                ));
                audio_index += 1;
            }
        }
        if self.soundtrack_omitted {
            text.push_str("[Video soundtrack omitted: this model receives frames only]\n");
        } else if self.audio.is_empty() {
            text.push_str("[Video has no audio track]\n");
        }
        if self.covered_ms < self.duration_ms {
            text.push_str(&format!(
                "[Video after {:.3}s omitted; original duration {:.3}s]\n",
                self.covered_ms as f64 / 1000.0,
                self.duration_ms as f64 / 1000.0
            ));
        }
        if self.omitted_cuts > 0 {
            text.push_str(&format!(
                "[{} detected cuts omitted from storyboard]\n",
                self.omitted_cuts
            ));
        }
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn probes(colors: impl Fn(u64) -> [u8; 3], end: u64) -> Vec<Probe> {
        (0..end)
            .step_by(250)
            .map(|at_ms| Probe {
                at_ms,
                rgb: colors(at_ms).repeat(32 * 18),
            })
            .collect()
    }
    #[test]
    fn cuts_flash_and_static_maximum_gap() {
        let p = probes(
            |t| {
                if t == 1500 {
                    [255; 3]
                } else if t < 2750 {
                    [255, 0, 0]
                } else {
                    [0, 0, 255]
                }
            },
            60_000,
        );
        let s = select(80_000, &p).expect("selection");
        assert!(s.indices.contains(&11));
        assert!(!s.indices.contains(&6));
        assert_eq!(s.detected_cuts, 1);
        assert_eq!(s.covered_ms, 60_000);
        assert!(s.indices.len() <= 16);
        assert!(
            s.indices
                .windows(2)
                .all(|i| p[i[1]].at_ms - p[i[0]].at_ms <= GAP_MS)
        );
        assert!(60_000 - p[*s.indices.last().expect("last")].at_ms <= GAP_MS);
    }
    #[test]
    fn steady_motion_is_discounted_and_dense_cuts_are_bounded() {
        let motion = probes(|t| [(t / 250) as u8; 3], 10_000);
        assert_eq!(select(10_000, &motion).expect("motion").detected_cuts, 0);
        let dense = probes(
            |t| if (t / 750) % 2 == 0 { [0; 3] } else { [255; 3] },
            60_000,
        );
        let s = select(60_000, &dense).expect("dense");
        assert_eq!(s.indices.len(), 16);
        assert!(s.omitted_cuts > 0);
    }
    #[test]
    fn invalid_timing_and_soundtrack_fail_closed() {
        assert!(scan_plan(0).is_err());
        assert!(scan_plan(7_200_001).is_err());
        let scan = scan_plan(80_000).expect("bounded scan");
        assert_eq!(scan.covered_ms, 60_000);
        assert_eq!(scan.probe_times_ms.len(), 240);
        assert_eq!(scan.audio_windows.len(), 2);
        assert_eq!(scan.audio_windows[1].start_ms, 30_000);
        let mut p = probes(|_| [0; 3], 1000);
        p[1].at_ms = 0;
        assert!(select(1000, &p).is_err());
        let mut t = Timeline {
            duration_ms: 1000,
            covered_ms: 1000,
            frame_times_ms: vec![0],
            audio: vec![AudioSegment {
                start_ms: 0,
                end_ms: 1000,
                digest: "a".repeat(64),
            }],
            detected_cuts: 0,
            omitted_cuts: 0,
            soundtrack_omitted: false,
        };
        assert!(t.validate(1).is_ok());
        t.audio[0].start_ms = 1;
        assert!(t.validate(1).is_err());
    }
    #[test]
    fn audio_windows_preserve_speech_across_shots_and_are_timed_between_groups() {
        let mut t = Timeline {
            duration_ms: 60_000,
            covered_ms: 60_000,
            frame_times_ms: (0..60_000).step_by(5_000).collect(),
            audio: vec![
                AudioSegment {
                    start_ms: 0,
                    end_ms: 30_000,
                    digest: "a".repeat(64),
                },
                AudioSegment {
                    start_ms: 30_000,
                    end_ms: 60_000,
                    digest: "b".repeat(64),
                },
            ],
            detected_cuts: 0,
            omitted_cuts: 0,
            soundtrack_omitted: false,
        };
        assert!(t.validate(12).is_ok());
        let prompt = t.prompt_content();
        let image = prompt.find("[Video 00:30.000]").expect("frame");
        assert!(prompt.find("[Sound 0.000–30.000s]").expect("first sound") < image);
        assert!(prompt.find("[Sound 30.000–60.000s]").expect("last sound") > image);
        t.audio[1].start_ms = 29_999;
        assert!(t.validate(12).is_err());
        t.audio[1].start_ms = 30_000;
        t.soundtrack_omitted = true;
        assert!(t.validate(12).is_err());
    }
}
