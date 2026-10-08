//! Exact suffix selection with an external tokenizer oracle. Vocabulary bounds
//! only exclude impossible candidates; they never admit a prompt on their own.
use crate::{Error, TEXT_LIMIT, WritingPrompt, digest, require, writing_prompt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Vocabulary {
    vocabulary: Vec<String>,
    normalizer: Value,
    pre_tokenizer: Value,
    model: Value,
    added_tokens: Vec<Value>,
}

#[derive(Default)]
struct Node {
    edges: Vec<(u8, usize)>,
    terminal: bool,
}

struct Dictionary {
    nodes: Vec<Node>,
    max_bytes: usize,
}

struct Crossing {
    node: usize,
    cost: u32,
    remaining: usize,
}
struct PrefixCosts {
    free_bound: u32,
    complete: u32,
    crossings: Vec<Crossing>,
}
impl PrefixCosts {
    fn joined(&self, dictionary: &Dictionary, bytes: &[u8], start: usize, costs: &[u32]) -> u32 {
        let mut best = self.complete + costs[start];
        for crossing in &self.crossings {
            dictionary.endings_from(crossing.node, bytes, start, crossing.remaining, |end| {
                best = best.min(crossing.cost + costs[end])
            });
        }
        best
    }
}

impl Dictionary {
    fn validated(descriptor: Vocabulary) -> Result<Self, Error> {
        require(
            descriptor.normalizer
                == json!({"type":"Replace","pattern":{"String":" "},"content":"▁"})
                && descriptor.pre_tokenizer
                    == json!({"type":"Split","pattern":{"String":" "},"behavior":"MergedWithPrevious","invert":false}),
            "This tokenizer's normalization is not qualified for context bounds.",
        )?;
        let m = descriptor.model;
        require(
            m["type"] == "BPE"
                && m["byte_fallback"] == true
                && m["dropout"].is_null()
                && m["continuing_subword_prefix"].is_null()
                && m["end_of_word_suffix"].is_null()
                && m["ignore_merges"] == false,
            "This tokenizer's BPE configuration is not qualified for context bounds.",
        )?;
        require(
            !descriptor.vocabulary.is_empty()
                && descriptor.vocabulary.len() <= 300_000
                && descriptor.added_tokens.len() <= 4096,
            "Unsupported context vocabulary size.",
        )?;
        let mut words = descriptor.vocabulary;
        for added in descriptor.added_tokens {
            let content = added["content"]
                .as_str()
                .ok_or_else(|| Error("Invalid added token.".into()))?;
            require(
                added["single_word"] == false
                    && added["lstrip"] == false
                    && added["rstrip"] == false
                    && added["normalized"] == false
                    && !content.contains(' '),
                "This tokenizer's added tokens are not qualified for context bounds.",
            )?;
            words.push(content.into());
        }
        // Byte fallback prevents unknown-token fusion from representing arbitrary
        // text in one token. Include literal aliases too: extra paths can only
        // lower the bound, so they cannot exclude a fitting suffix.
        let present: std::collections::HashSet<&str> = words.iter().map(String::as_str).collect();
        require(
            (0..=255).all(|b| present.contains(format!("<0x{b:02X}>").as_str())),
            "The tokenizer does not provide complete byte fallback.",
        )?;
        Self::new(&words)
    }

    fn new(words: &[String]) -> Result<Self, Error> {
        let mut nodes = vec![Node::default()];
        let mut max_bytes = 1;
        let mut bytes = 0usize;
        for word in words {
            require(
                !word.is_empty() && word.len() <= 1024,
                "Invalid context vocabulary token.",
            )?;
            bytes = bytes.saturating_add(word.len());
            require(
                bytes <= 16 * TEXT_LIMIT,
                "Context vocabulary exceeds 32 MiB.",
            )?;
            max_bytes = max_bytes.max(word.len());
            let mut node = 0;
            for byte in word.bytes() {
                let next = nodes[node].edges.iter().find(|e| e.0 == byte).map(|e| e.1);
                node = match next {
                    Some(next) => next,
                    None => {
                        let next = nodes.len();
                        nodes.push(Node::default());
                        nodes[node].edges.push((byte, next));
                        next
                    }
                };
            }
            nodes[node].terminal = true;
        }
        for node in &mut nodes {
            node.edges.sort_unstable_by_key(|e| e.0);
        }
        Ok(Self { nodes, max_bytes })
    }

    fn child(&self, node: usize, byte: u8) -> Option<usize> {
        let edges = &self.nodes[node].edges;
        edges
            .binary_search_by_key(&byte, |e| e.0)
            .ok()
            .map(|i| edges[i].1)
    }
    fn endings_from(
        &self,
        mut node: usize,
        bytes: &[u8],
        start: usize,
        limit: usize,
        mut visit: impl FnMut(usize),
    ) {
        for (offset, byte) in bytes[start..].iter().take(limit).enumerate() {
            let Some(next) = self.child(node, *byte) else {
                break;
            };
            node = next;
            if self.nodes[node].terminal {
                visit(start + offset + 1);
            }
        }
    }
    fn endings(&self, bytes: &[u8], start: usize, visit: impl FnMut(usize)) {
        self.endings_from(0, bytes, start, self.max_bytes, visit);
    }

    fn suffix_costs(&self, bytes: &[u8]) -> Vec<u32> {
        let mut costs = vec![0; bytes.len() + 1];
        for start in (0..bytes.len()).rev() {
            let mut best = 1 + costs[start + 1];
            self.endings(bytes, start, |end| best = best.min(1 + costs[end]));
            costs[start] = best;
        }
        costs
    }

    fn prefix_costs(&self, bytes: &[u8]) -> PrefixCosts {
        let mut costs = vec![u32::MAX; bytes.len() + 1];
        costs[0] = 0;
        for start in 0..bytes.len() {
            let next = costs[start] + 1;
            costs[start + 1] = costs[start + 1].min(next);
            self.endings(bytes, start, |end| costs[end] = costs[end].min(next));
        }
        // A join-crossing token may consume up to max_bytes - 1 prefix bytes.
        // Give that fragment away rather than tokenize a truncated fragment.
        let free_bound = costs[bytes.len().saturating_sub(self.max_bytes - 1)..]
            .iter()
            .copied()
            .min()
            .unwrap_or(0);
        let mut crossings = Vec::new();
        for start in bytes.len().saturating_sub(self.max_bytes - 1)..bytes.len() {
            let node = bytes[start..]
                .iter()
                .try_fold(0, |node, byte| self.child(node, *byte));
            if let Some(node) = node {
                crossings.push(Crossing {
                    node,
                    cost: costs[start] + 1,
                    remaining: self.max_bytes - (bytes.len() - start),
                });
            }
        }
        PrefixCosts {
            free_bound,
            complete: costs[bytes.len()],
            crossings,
        }
    }
}

fn normalized(text: &str) -> Vec<u8> {
    text.replace(' ', "▁").into_bytes()
}

fn suffix_bounds(costs: &[u32], window: usize) -> Vec<u32> {
    let mut bounds = vec![0; costs.len()];
    let mut queue: VecDeque<usize> = VecDeque::new();
    for start in (0..costs.len()).rev() {
        while queue.front().is_some_and(|end| *end >= start + window) {
            queue.pop_front();
        }
        while queue.back().is_some_and(|end| costs[*end] >= costs[start]) {
            queue.pop_back();
        }
        queue.push_back(start);
        if let Some(end) = queue.front() {
            bounds[start] = costs[*end];
        }
    }
    bounds
}

struct Search {
    dictionary: Arc<Dictionary>,
    prefix: String,
    authored: String,
    boundaries: Vec<(usize, usize)>,
    allowed: Vec<bool>,
    bounds: Vec<u32>,
    costs: Vec<u32>,
    normalized: Vec<u8>,
    prefix_costs: Option<PrefixCosts>,
    capacity: u32,
    current: Option<usize>,
    tested: usize,
    finished: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    id: Uuid,
    status: &'static str,
    candidate: Option<WritingPrompt>,
    tested_candidates: usize,
}

impl Search {
    #[cfg(test)]
    fn new(
        dictionary: &Arc<Dictionary>,
        text: &str,
        caret: usize,
        examples: &[String],
        capacity: u32,
    ) -> Result<Self, Error> {
        Self::new_with_media(dictionary, text, caret, examples, capacity, &[])
    }
    fn new_with_media(
        dictionary: &Arc<Dictionary>,
        text: &str,
        caret: usize,
        examples: &[String],
        capacity: u32,
        media: &[crate::writing::MediaReference],
    ) -> Result<Self, Error> {
        require(
            (1..=16_384).contains(&capacity),
            "Invalid writing context capacity.",
        )?;
        let full = writing_prompt(text, caret, examples, usize::MAX)?;
        require(
            full.total_characters > 0,
            "Write some text before requesting a continuation.",
        )?;
        let prefix = writing_prompt(text, caret, examples, 0)?.prompt;
        let authored = full.prompt[prefix.len()..].to_owned();
        // Bounds use the compiled marker spelling, not a filename/UUID that
        // disappears from model input. Expanded soft-token blocks can only
        // increase that bound. Suffix cuts never split an embedded object.
        let compiled_prefix = crate::writing::compile_media_prompt(&prefix, media)?.prompt;
        let compiled_authored = crate::writing::compile_media_prompt(&authored, media)?.prompt;
        let spans = crate::markdown::media_spans(&authored)?
            .into_iter()
            .filter(|span| media.iter().any(|reference| reference.id == span.id))
            .collect::<Vec<_>>();
        let mut normalized_offset = 0;
        let mut utf16 = 0;
        let mut allowed = Vec::new();
        let boundaries = authored
            .grapheme_indices(true)
            .map(|(byte, grapheme)| {
                let span = spans
                    .iter()
                    .find(|span| utf16 >= span.location && utf16 < span.location + span.length);
                let pair = (byte, normalized_offset);
                allowed.push(span.is_none_or(|span| utf16 == span.location));
                if let Some(span) = span {
                    if utf16 == span.location {
                        let reference = media
                            .iter()
                            .find(|reference| reference.id == span.id)
                            .expect("filtered media");
                        let content = reference.prompt_content();
                        normalized_offset +=
                            content.len() + content.bytes().filter(|b| *b == b' ').count() * 2;
                    }
                } else {
                    normalized_offset +=
                        grapheme.len() + grapheme.bytes().filter(|b| *b == b' ').count() * 2;
                }
                utf16 += grapheme.encode_utf16().count();
                pair
            })
            .collect();
        // Normalization never shortens text. This cheap bound also avoids a DP
        // over a many-megabyte selection of examples that cannot possibly fit.
        let (prefix_costs, normalized, costs, bounds) =
            if compiled_prefix.len() > (capacity as usize + 1) * dictionary.max_bytes {
                (None, Vec::new(), Vec::new(), Vec::new())
            } else {
                let p = dictionary.prefix_costs(&normalized(&compiled_prefix));
                let bytes = normalized(&compiled_authored);
                let costs = dictionary.suffix_costs(&bytes);
                let bounds = suffix_bounds(&costs, dictionary.max_bytes);
                (Some(p), bytes, costs, bounds)
            };
        Ok(Self {
            dictionary: Arc::clone(dictionary),
            prefix,
            authored,
            boundaries,
            allowed,
            bounds,
            prefix_costs,
            costs,
            normalized,
            capacity,
            current: None,
            tested: 0,
            finished: false,
        })
    }

    fn prompt(&self, index: usize) -> WritingPrompt {
        let mut prompt = self.prefix.clone();
        prompt.push_str(&self.authored[self.boundaries[index].0..]);
        WritingPrompt {
            digest: digest(prompt.as_bytes()),
            prompt,
            total_characters: self.boundaries.len(),
            omitted_characters: index,
        }
    }

    fn next(&mut self, id: Uuid) -> Step {
        let start = self.current.map_or(0, |i| i + 1);
        let fitting = (start..self.boundaries.len()).find(|i| {
            if !self.allowed[*i] {
                return false;
            }
            let at = self.boundaries[*i].1;
            self.prefix_costs.as_ref().is_some_and(|prefix| {
                // The cheap free-fragment bound rejects distant suffixes first.
                // For the remaining ones, include every vocabulary token that
                // can cross the join. This is minimum possible segmentation,
                // not BPE's rank-selected segmentation: the oracle still decides.
                prefix.free_bound + self.bounds[at] <= self.capacity
                    && prefix.joined(&self.dictionary, &self.normalized, at, &self.costs)
                        <= self.capacity
            })
        });
        self.current = fitting;
        self.finished = fitting.is_none();
        Step {
            id,
            status: if fitting.is_some() {
                "candidate"
            } else {
                "exhausted"
            },
            candidate: fitting.map(|i| self.prompt(i)),
            tested_candidates: self.tested,
        }
    }

    fn counted(&mut self, id: Uuid, prompt_digest: &str, count: u32) -> Result<Step, Error> {
        require(!self.finished, "This context search has finished.")?;
        let index = self
            .current
            .ok_or_else(|| Error("No context candidate is awaiting a count.".into()))?;
        let prompt = self.prompt(index);
        require(
            prompt.digest == prompt_digest && (1..=64 * 1024 * 1024).contains(&count),
            "Token count does not identify the pending context candidate.",
        )?;
        self.tested += 1;
        if count <= self.capacity {
            self.finished = true;
            Ok(Step {
                id,
                status: "selected",
                candidate: Some(prompt),
                tested_candidates: self.tested,
            })
        } else {
            Ok(self.next(id))
        }
    }
}

#[derive(Default)]
struct Sessions {
    dictionaries: HashMap<Uuid, Arc<Dictionary>>,
    searches: HashMap<Uuid, Search>,
}
fn sessions() -> &'static Mutex<Sessions> {
    static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();
    SESSIONS.get_or_init(Mutex::default)
}
fn locked() -> Result<std::sync::MutexGuard<'static, Sessions>, Error> {
    sessions()
        .lock()
        .map_err(|_| Error("Context planner is unavailable after an internal failure.".into()))
}
pub fn vocabulary(descriptor: Vocabulary) -> Result<Uuid, Error> {
    let dictionary = Arc::new(Dictionary::validated(descriptor)?);
    let mut sessions = locked()?;
    require(
        sessions.dictionaries.len() < 4,
        "Too many loaded context vocabularies.",
    )?;
    let id = Uuid::new_v4();
    sessions.dictionaries.insert(id, dictionary);
    Ok(id)
}
pub fn release_vocabulary(id: Uuid) -> Result<bool, Error> {
    Ok(locked()?.dictionaries.remove(&id).is_some())
}
pub fn begin(
    dictionary: Uuid,
    text: &str,
    caret: usize,
    examples: &[String],
    capacity: u32,
    media: &[crate::writing::MediaReference],
) -> Result<Step, Error> {
    let dictionary = locked()?
        .dictionaries
        .get(&dictionary)
        .cloned()
        .ok_or_else(|| Error("The context vocabulary was released.".into()))?;
    let mut search = Search::new_with_media(&dictionary, text, caret, examples, capacity, media)?;
    let mut sessions = locked()?;
    require(
        sessions.searches.len() < 8,
        "Too many active context searches.",
    )?;
    let id = Uuid::new_v4();
    let step = search.next(id);
    // Reject an unrepresentable first response before retaining its private
    // snapshot. Later suffixes only shorten the prompt; leave envelope space.
    let encoded = serde_json::to_vec(&step).map_err(|e| Error(e.to_string()))?;
    require(
        encoded.len() <= 8 * 1024 * 1024 - 1024,
        "The context candidate exceeds the product response limit.",
    )?;
    sessions.searches.insert(id, search);
    Ok(step)
}
pub fn counted(id: Uuid, prompt_digest: &str, count: u32) -> Result<Step, Error> {
    locked()?
        .searches
        .get_mut(&id)
        .ok_or_else(|| Error("This context search was released.".into()))?
        .counted(id, prompt_digest, count)
}
pub fn release_search(id: Uuid) -> Result<bool, Error> {
    Ok(locked()?.searches.remove(&id).is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dictionary(words: &[&str]) -> Arc<Dictionary> {
        Arc::new(
            Dictionary::new(&words.iter().map(|s| (*s).into()).collect::<Vec<_>>())
                .expect("fixture"),
        )
    }
    #[test]
    fn boundary_bounds_do_not_overestimate_any_segmentation() {
        let d = dictionary(&["a", "b", "ab", "ba", "aba", "▁", "▁ab", "a▁b"]);
        for size in 0..=7 {
            for pattern in 0..3usize.pow(size) {
                let mut n = pattern;
                let mut text = String::new();
                for _ in 0..size {
                    text.push(['a', 'b', ' '][n % 3]);
                    n /= 3;
                }
                let bytes = normalized(&text);
                let costs = d.suffix_costs(&bytes);
                let bounds = suffix_bounds(&costs, d.max_bytes);
                for split in 0..=bytes.len() {
                    let p = &bytes[..split];
                    let s = &bytes[split..];
                    let joined = d.suffix_costs(&bytes)[0];
                    let prefix = d.prefix_costs(p);
                    let suffix_costs = d.suffix_costs(s);
                    let suffix = suffix_bounds(&suffix_costs, d.max_bytes)[0];
                    assert!(prefix.free_bound + suffix <= joined);
                    assert_eq!(prefix.joined(&d, s, 0, &suffix_costs), joined);
                }
                for i in 0..costs.len() {
                    assert_eq!(
                        bounds[i],
                        *costs[i..(i + d.max_bytes).min(costs.len())]
                            .iter()
                            .min()
                            .expect("window")
                    );
                }
            }
        }
    }
    #[test]
    fn exact_counts_are_checked_in_order_including_nonmonotonic_counts() {
        let d = dictionary(&["<bos>", "abcdef", "bcdef", "cdef", "def", "ef", "f"]);
        let id = Uuid::new_v4();
        let mut search = Search::new(&d, "abcdef AFTER", 6, &[], 2).expect("search");
        let mut step = search.next(id);
        for count in [4, 5, 2] {
            let candidate = step.candidate.as_ref().expect("candidate");
            step = search.counted(id, &candidate.digest, count).expect("count");
        }
        assert_eq!(step.status, "selected");
        assert_eq!(step.candidate.expect("selected").prompt, "<bos>cdef");
        assert_eq!(step.tested_candidates, 3);
        assert!(search.counted(id, "stale", 1).is_err());
    }
    #[test]
    fn media_bounds_do_not_charge_a_removed_uuid_or_cut_inside_its_reference() {
        let media = crate::writing::MediaReference {
            id: Uuid::from_u128(1),
            name: "clip.wav".into(),
            root_digest: "a".repeat(64),
            kind: "audio".into(),
            text: None,
            source_digest: None,
            frame_digests: None,
        };
        let link = format!("[Attachment: clip](boom-attachment:{})", media.id);
        let text = format!("{link}z");
        let dictionary = dictionary(&["<bos>", "<|audio|>", "z"]);
        let mut search = Search::new_with_media(
            &dictionary,
            &text,
            text.encode_utf16().count(),
            &[],
            3,
            &[media],
        )
        .expect("search");
        let id = Uuid::new_v4();
        let step = search.next(id);
        assert_eq!(
            step.candidate
                .as_ref()
                .expect("candidate")
                .omitted_characters,
            0
        );
        // A real token oracle can reject the expanded audio block. The next
        // admissible suffix starts after the whole reference, never in its UUID.
        let next = search
            .counted(id, &step.candidate.expect("candidate").digest, 40)
            .expect("count");
        assert_eq!(next.candidate.expect("candidate").prompt, "<bos>z");
    }
    #[test]
    fn full_fit_is_considered_before_empty_example_prompt() {
        let d = dictionary(&["<bos>", "long\n\na"]);
        let id = Uuid::new_v4();
        let mut search = Search::new(&d, "a AFTER", 1, &["long".into()], 2).expect("search");
        let step = search.next(id);
        let candidate = step.candidate.expect("candidate");
        assert_eq!(candidate.omitted_characters, 0);
        assert_eq!(
            search
                .counted(id, &candidate.digest, 2)
                .expect("count")
                .status,
            "selected"
        );
    }
    #[test]
    fn candidates_use_rust_graphemes_and_never_supply_after_caret() {
        let text = "e\u{301}👩‍💻z AFTER";
        let d = dictionary(&["<bos>", "e\u{301}👩‍💻z", "👩‍💻z", "z"]);
        let mut search =
            Search::new(&d, text, "e\u{301}👩‍💻z".encode_utf16().count(), &[], 2).expect("search");
        let id = Uuid::new_v4();
        let first = search.next(id).candidate.expect("full");
        assert_eq!(first.total_characters, 3);
        let next = search
            .counted(id, &first.digest, 9)
            .expect("next")
            .candidate
            .expect("emoji");
        assert_eq!(next.prompt, "<bos>👩‍💻z");
        assert_eq!(next.omitted_characters, 1);
        assert!(search.counted(id, &first.digest, 1).is_err());
        assert!(Search::new(&d, text, 1, &[], 1).is_err());
    }
    fn descriptor() -> Vocabulary {
        Vocabulary {
            vocabulary: (0..=255)
                .map(|b| format!("<0x{b:02X}>"))
                .chain(["<bos>".into(), "abcdef".into()])
                .collect(),
            normalizer: json!({"type":"Replace","pattern":{"String":" "},"content":"▁"}),
            pre_tokenizer: json!({"type":"Split","pattern":{"String":" "},"behavior":"MergedWithPrevious","invert":false}),
            model: json!({"type":"BPE","byte_fallback":true,"dropout":null,"continuing_subword_prefix":null,"end_of_word_suffix":null,"ignore_merges":false}),
            added_tokens: vec![
                json!({"content":"<bos>","single_word":false,"lstrip":false,"rstrip":false,"normalized":false}),
            ],
        }
    }
    #[test]
    fn unqualified_normalization_or_byte_fallback_is_rejected() {
        assert!(Dictionary::validated(descriptor()).is_ok());
        let mut d = descriptor();
        d.normalizer["content"] = json!("");
        assert!(Dictionary::validated(d).is_err());
        let mut d = descriptor();
        d.vocabulary.remove(127);
        assert!(Dictionary::validated(d).is_err());
        let mut d = descriptor();
        d.added_tokens[0]["lstrip"] = json!(true);
        assert!(Dictionary::validated(d).is_err());
        let mut d = descriptor();
        d.added_tokens[0]["content"] = json!("two words");
        assert!(Dictionary::validated(d).is_err());
        let mut d = descriptor();
        d.model["continuing_subword_prefix"] = json!("##");
        assert!(Dictionary::validated(d).is_err());
    }
    #[test]
    fn released_searches_reject_late_counts_and_release_private_snapshots() {
        let dictionary = vocabulary(descriptor()).expect("dictionary");
        let first = begin(dictionary, "abcdef", 6, &[], 2, &[]).expect("search");
        let second = begin(dictionary, "abcdef", 6, &[], 2, &[]).expect("search");
        let digest = first.candidate.expect("candidate").digest;
        assert!(counted(first.id, "wrong digest", 1).is_err());
        assert!(release_search(first.id).expect("release"));
        assert!(counted(first.id, &digest, 1).is_err());
        assert_eq!(
            counted(second.id, &digest, 2).expect("count").status,
            "selected"
        );
        assert!(release_search(second.id).expect("release"));
        assert!(release_vocabulary(dictionary).expect("release"));
        assert!(begin(dictionary, "abcdef", 6, &[], 2, &[]).is_err());
    }
    #[test]
    fn impossible_examples_and_final_grapheme_return_exhaustion() {
        let d = dictionary(&["<bos>"]);
        let id = Uuid::new_v4();
        let mut search = Search::new(&d, "z", 1, &["x".repeat(100)], 1).expect("search");
        assert_eq!(search.next(id).status, "exhausted");
        let mut search = Search::new(&d, "z", 1, &[], 2).expect("search");
        let first = search.next(id).candidate.expect("candidate");
        let step = search.counted(id, &first.digest, 3).expect("count");
        assert_eq!(step.status, "exhausted");
        assert!(step.candidate.is_none());
    }
}
