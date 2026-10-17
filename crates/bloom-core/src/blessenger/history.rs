//! Metadata-only admission before any original is read or decoded. A unit is an
//! authored question and all its replies. Original bytes are charged once; each
//! chronological media occurrence is charged independently, including aliases.
use crate::{Error, require};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const MAX_SOURCES: usize = 32;
const MAX_MEDIA: usize = 8;
const MAX_OCCURRENCES: usize = 16;
const MAX_ORIGINAL_BYTES: u64 = 128 * 1024 * 1024;
const MAX_TEXT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_MESSAGES: usize = 4096;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub id: Uuid,
    pub media: bool,
    pub original_bytes: u64,
    pub available: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Unit {
    pub id: Uuid,
    pub messages: Vec<Uuid>,
    pub text_bytes: u64,
    pub sources: Vec<Uuid>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Input {
    pub units: Vec<Unit>,
    pub sources: Vec<Source>,
    pub current: Vec<Uuid>,
    pub current_text_bytes: u64,
    pub maximum_units: usize,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub units: Vec<Uuid>,
    pub messages: Vec<Uuid>,
    pub source_ids: Vec<Uuid>,
    pub raw_source_ids: Vec<Uuid>,
    pub media_occurrences: usize,
    pub original_bytes: u64,
    pub text_bytes: u64,
    pub omitted_units: usize,
    pub omitted_messages: usize,
    pub reason: Option<&'static str>,
}
#[derive(Clone, Default)]
struct Charge {
    sources: HashSet<Uuid>,
    media: usize,
    occurrences: usize,
    originals: u64,
    text: u64,
    messages: usize,
}
impl Charge {
    fn append(
        &mut self,
        ids: &[Uuid],
        sources: &HashMap<Uuid, &Source>,
        text: u64,
        messages: usize,
    ) -> Result<(), &'static str> {
        self.text = self.text.checked_add(text).ok_or("text_budget")?;
        self.messages = self
            .messages
            .checked_add(messages)
            .ok_or("message_budget")?;
        if self.text > MAX_TEXT_BYTES {
            return Err("text_budget");
        }
        if self.messages > MAX_MESSAGES {
            return Err("message_budget");
        }
        for id in ids {
            let source = sources.get(id).ok_or("source_unavailable")?;
            if !source.available {
                return Err("source_unavailable");
            }
            if source.media {
                self.occurrences += 1;
                if self.occurrences > MAX_OCCURRENCES {
                    return Err("media_occurrence_budget");
                }
            }
            if self.sources.insert(*id) {
                if self.sources.len() > MAX_SOURCES {
                    return Err("source_budget");
                }
                self.originals = self
                    .originals
                    .checked_add(source.original_bytes)
                    .ok_or("original_byte_budget")?;
                if self.originals > MAX_ORIGINAL_BYTES {
                    return Err("original_byte_budget");
                }
                if source.media {
                    self.media += 1;
                    if self.media > MAX_MEDIA {
                        return Err("media_source_budget");
                    }
                }
            }
        }
        Ok(())
    }
}

pub fn select(input: &Input) -> Result<Window, Error> {
    require(
        input.units.len() <= 131_072
            && input.maximum_units <= MAX_MESSAGES
            && input.sources.len() <= MAX_MESSAGES * 8
            && input.current.len() <= 8,
        "The context metadata exceeds its bound.",
    )?;
    let sources: HashMap<_, _> = input.sources.iter().map(|s| (s.id, s)).collect();
    require(
        sources.len() == input.sources.len()
            && input.sources.iter().all(|s| {
                !s.id.is_nil() && (!s.available || (1..=67_108_864).contains(&s.original_bytes))
            }),
        "Context source identities or original sizes are invalid.",
    )?;
    let mut messages = HashSet::new();
    for unit in &input.units {
        require(
            !unit.id.is_nil()
                && unit.messages.first() == Some(&unit.id)
                && unit.messages.len() <= MAX_MESSAGES
                && unit.sources.len() <= 8
                && unit
                    .messages
                    .iter()
                    .all(|id| !id.is_nil() && messages.insert(*id)),
            "Context units contain duplicate or invalid message identities.",
        )?;
        require(
            unit.sources.iter().collect::<HashSet<_>>().len() == unit.sources.len(),
            "One authored input contains duplicate attachment identities.",
        )?;
    }
    require(
        input.current.iter().collect::<HashSet<_>>().len() == input.current.len(),
        "The current input contains duplicate attachment identities.",
    )?;
    let mut charge = Charge::default();
    charge.append(&input.current, &sources, input.current_text_bytes, 0)
        .map_err(|reason| Error(format!("The current question and attachments exceed admission ({reason}). Nothing was omitted or sent.")))?;
    let mut count = 0;
    let mut reason = None;
    for unit in input.units.iter().rev() {
        if count == input.maximum_units {
            reason = Some("unit_budget");
            break;
        }
        let mut candidate = charge.clone();
        if let Err(issue) = candidate.append(
            &unit.sources,
            &sources,
            unit.text_bytes,
            unit.messages.len(),
        ) {
            reason = Some(issue);
            break;
        }
        charge = candidate;
        count += 1;
    }
    let split = input.units.len() - count;
    let retained = &input.units[split..];
    let mut source_ids = Vec::new();
    let mut seen = HashSet::new();
    for id in retained
        .iter()
        .flat_map(|u| &u.sources)
        .chain(&input.current)
    {
        if seen.insert(*id) {
            source_ids.push(*id);
        }
    }
    Ok(Window {
        units: retained.iter().map(|u| u.id).collect(),
        messages: retained
            .iter()
            .flat_map(|u| u.messages.iter().copied())
            .collect(),
        raw_source_ids: source_ids
            .iter()
            .filter(|id| sources.get(id).is_some_and(|s| s.media))
            .copied()
            .collect(),
        source_ids,
        media_occurrences: charge.occurrences,
        original_bytes: charge.originals,
        text_bytes: charge.text,
        omitted_units: split,
        omitted_messages: input.units[..split].iter().map(|u| u.messages.len()).sum(),
        reason,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source(id: u128, bytes: u64) -> Source {
        Source {
            id: Uuid::from_u128(id),
            media: true,
            original_bytes: bytes,
            available: true,
        }
    }
    fn unit(id: u128, source: u128) -> Unit {
        Unit {
            id: Uuid::from_u128(id),
            messages: vec![Uuid::from_u128(id), Uuid::from_u128(id + 1000)],
            text_bytes: 100,
            sources: vec![Uuid::from_u128(source)],
        }
    }
    fn fixture() -> Input {
        Input {
            units: (1..=100).map(|n| unit(n, n + 10000)).collect(),
            sources: (1..=101).map(|n| source(n + 10000, 64044)).collect(),
            current: vec![Uuid::from_u128(10101)],
            current_text_bytes: 10,
            maximum_units: 4096,
        }
    }
    #[test]
    fn long_history_is_windowed_before_any_decoder() {
        let chosen = select(&fixture()).expect("bounded context");
        assert_eq!(chosen.units.len(), 7);
        assert_eq!(chosen.messages.len(), 14);
        assert_eq!(chosen.raw_source_ids.len(), 8);
        assert_eq!(chosen.omitted_units, 93);
        assert_eq!(chosen.reason, Some("media_source_budget"));
        assert_eq!(chosen.messages[0], Uuid::from_u128(94));
        assert_eq!(chosen.source_ids.last(), Some(&Uuid::from_u128(10101)));
    }
    #[test]
    fn aliases_save_original_bytes_not_occurrence_positions() {
        let mut input = fixture();
        for unit in &mut input.units {
            unit.sources = input.current.clone();
        }
        let chosen = select(&input).expect("bounded aliases");
        assert_eq!(chosen.units.len(), 15);
        assert_eq!(chosen.raw_source_ids.len(), 1);
        assert_eq!(chosen.original_bytes, 64044);
        assert_eq!(chosen.media_occurrences, 16);
        assert_eq!(chosen.reason, Some("media_occurrence_budget"));
    }
    #[test]
    fn never_keep_an_orphan_reply_or_skip_a_recent_oversize_unit() {
        let mut input = fixture();
        input.units.last_mut().expect("unit").text_bytes = MAX_TEXT_BYTES;
        let chosen = select(&input).expect("current remains");
        assert!(chosen.messages.is_empty());
        assert_eq!(chosen.omitted_messages, 200);
        assert_eq!(chosen.reason, Some("text_budget"));
    }
    #[test]
    fn current_input_is_mandatory_and_never_sliced() {
        let mut input = fixture();
        input.current_text_bytes = MAX_TEXT_BYTES + 1;
        assert!(select(&input).is_err());
        input.current_text_bytes = 0;
        input.sources.last_mut().expect("current").available = false;
        assert!(select(&input).is_err());
    }
    #[test]
    fn unknown_old_media_can_be_omitted_but_cannot_be_selected() {
        let mut input = fixture();
        input.sources[0].available = false;
        assert_eq!(
            select(&input).expect("irrelevant old source").units.len(),
            7
        );
        input.sources[99].available = false;
        assert!(select(&input).expect("unavailable suffix").units.is_empty());
    }
    #[test]
    fn actual_token_fit_can_reduce_only_whole_units() {
        let mut input = fixture();
        input.maximum_units = 3;
        let chosen = select(&input).expect("three units");
        assert_eq!(chosen.messages.len(), 6);
        assert_eq!(chosen.units[0], Uuid::from_u128(98));
        input.maximum_units = 0;
        assert_eq!(
            select(&input).expect("mandatory only").source_ids,
            input.current
        );
    }
    #[test]
    fn original_memory_is_charged_before_decoding() {
        let mut input = fixture();
        for source in &mut input.sources {
            source.original_bytes = 64 * 1024 * 1024;
        }
        let chosen = select(&input).expect("128 MiB");
        assert_eq!(chosen.units.len(), 1);
        assert_eq!(chosen.reason, Some("original_byte_budget"));
    }
    #[test]
    fn malformed_metadata_is_not_a_cache_miss() {
        let mut input = fixture();
        input.units[1].messages[0] = input.units[0].id;
        assert!(select(&input).is_err());
        let mut input = fixture();
        input.sources.push(source(10101, 64044));
        assert!(select(&input).is_err());
    }
}
