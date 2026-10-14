//! Bounded access to the pinned block grammar. These APIs do not parse an
//! arbitrary substring as a document: their input starts at a proved root
//! checkpoint, and only a prefix closed by actual following source is emitted.
use crate::{CowStr, Options, RefDefs};
use crate::parse::LinkDef;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::ops::Range;
use unicase::UniCase;

mod emphasis;
pub(crate) use emphasis::eligible;
pub use emphasis::{InlineStyle, InlineStyleKind, OpenDelimiter, PreparedDelimiterMatch, prepare_delimiter_match};

mod inline_stack;
pub use inline_stack::{DelimiterReducer, DelimiterStack, ReduceProgress};

mod code_runs;
pub use code_runs::{CodeRun, CodeRunStream, CodeRuns, PreparedCodePair, prepare_code_pair};

mod link;
pub use link::{DestinationStatus, DestinationStep, LinkDestinationStream, InlineLinkFragment, probe_inline_link};
pub(crate) use link::scan_destination;

mod inline_runs;
pub use inline_runs::{InlinePoint, InlineRunError, InlineRunStream, InlineStop, InlineToken, ScannedRuns};

mod html_block;
pub use html_block::{HtmlBlockStep, HtmlContinuation, HtmlOpening, HtmlOpeningChoice, HtmlOpeningStatus, HtmlOpeningStep};
pub(crate) use html_block::may_be_type_seven;

pub const PROBE_BYTES: usize = 32 * 1024;

/// Cancellation of a checked inline walk. The partially mutated derived AST
/// is discarded; it is never emitted as a complete parser result.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Cancelled;
impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("Markdown parse cancelled") }
}
impl std::error::Error for Cancelled {}
pub(crate) fn check(cancelled: &mut impl FnMut() -> bool) -> Result<(), Cancelled> {
    if cancelled() { Err(Cancelled) } else { Ok(()) }
}


/// The actual open container spine at a completed child-block boundary. It
/// carries grammar state, not a source capability or a guessed prefix string.
/// Lists can be arbitrarily long without retaining their previous children.
/// Only options supported by the paged producer are admitted here.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BlockCarry {
    pub(crate) containers: Vec<Container>,
    pub(crate) begin_list_item: bool,
    pub(crate) last_line_blank: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Container {
    Quote,
    List { tight: bool, character: u8, index: u64 },
    Item { indent: usize },
}

impl BlockCarry {
    pub fn is_root(&self) -> bool {
        self.containers.is_empty() && !self.begin_list_item && !self.last_line_blank
    }
    /// The number and flags are cheap captured metadata; a worker serializes
    /// one bounded chunk at a time instead of copying the complete spine.
    pub fn checkpoint_len(&self) -> usize { self.containers.len() }
    pub fn checkpoint_flags(&self) -> (bool, bool) {
        (self.begin_list_item, self.last_line_blank)
    }
    pub fn checkpoint_chunk(&self, start: usize) -> Option<Vec<[u64; 4]>> {
        let tail = self.containers.get(start..)?;
        Some(tail.iter().take(128).map(|value| match *value {
            Container::Quote => [0, 0, 0, 0],
            Container::List { tight, character, index } => [1, u64::from(tight), u64::from(character), index],
            Container::Item { indent } => [2, indent as u64, 0, 0],
        }).collect())
    }
    /// The page owner serializes these bounded words into derived Index pages.
    /// Pinned-parser reconstruction checks each word before using it.
    pub fn checkpoint(&self) -> (Vec<[u64; 4]>, bool, bool) {
        let values = self.containers.iter().map(|value| match *value {
            Container::Quote => [0, 0, 0, 0],
            Container::List { tight, character, index } => [1, u64::from(tight), u64::from(character), index],
            Container::Item { indent } => [2, indent as u64, 0, 0],
        }).collect();
        (values, self.begin_list_item, self.last_line_blank)
    }
    pub fn from_checkpoint(values: &[[u64; 4]], begin_list_item: bool, last_line_blank: bool) -> Option<Self> {
        // This limits one materialized spine to the existing first-pass input
        // envelope. Deeper spines require the same paged-tree cursor, not an
        // enlarged source probe or a successful-looking truncated container.
        if values.len() > PROBE_BYTES { return None; }
        if values.is_empty() && (begin_list_item || last_line_blank) { return None; }
        let mut containers = Vec::with_capacity(values.len());
        for &[kind, a, b, c] in values {
            let value = match kind {
                0 if a == 0 && b == 0 && c == 0 => Container::Quote,
                1 if a <= 1 && matches!(b, 42 | 43 | 45 | 46 | 41) && c <= 999_999_999 &&
                    (matches!(b, 46 | 41) || c == 0) =>
                    Container::List { tight: a == 1, character: b as u8, index: c },
                2 if a <= 16 && b == 0 && c == 0 => Container::Item { indent: usize::try_from(a).ok()? },
                _ => return None,
            };
            if matches!(value, Container::Item { .. }) && !matches!(containers.last(), Some(Container::List { .. })) {
                return None;
            }
            containers.push(value);
        }
        if begin_list_item && !matches!(containers.last(), Some(Container::Item { .. })) { return None; }
        Some(Self { containers, begin_list_item, last_line_blank })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockKind { Parsed, Code, Html }

#[derive(Clone, Debug)]
pub struct BlockRange {
    pub input_start: usize,
    pub range: Range<usize>,
    pub kind: BlockKind,
}

/// Its private label comes from scan_link_label_rest in the first pass.
/// A consumer cannot mint a normalized definition from a fragment guess.
#[derive(Clone, Debug)]
pub struct ParsedReference<'a> {
    pub(crate) label: CowStr<'a>,
    pub(crate) definition: LinkDef<'a>,
}
impl ParsedReference<'_> {
    pub fn label(&self) -> &str { self.label.as_ref() }
    pub fn definition(&self) -> &LinkDef<'_> { &self.definition }
    pub fn label_matches(&self, other: &str) -> bool {
        reference_labels_equal(self.label.as_ref(), other)
    }
    pub fn label_hash(&self) -> u64 { reference_label_hash(self.label.as_ref()) }
    /// Borrow these immutable parsed bytes while their actual owner is held.
    /// This introduces neither a new label normalizer nor URL/title copies.
    pub fn borrowed(&self) -> ParsedReference<'_> {
        ParsedReference { label: CowStr::Borrowed(self.label.as_ref()), definition: LinkDef {
            dest: CowStr::Borrowed(self.definition.dest.as_ref()),
            title: self.definition.title.as_ref().map(|title| CowStr::Borrowed(title.as_ref())),
            span: self.definition.span.clone(),
        } }
    }
    /// Requested owned payload, excluding inline values and borrowed bytes.
    /// Allocator bookkeeping and temporary parser arrays are not included.
    pub fn owned_payload_bytes(&self) -> usize {
        let heap = |value: &CowStr<'_>| match value { CowStr::Boxed(value) => value.len(), _ => 0 };
        heap(&self.label) + heap(&self.definition.dest) + self.definition.title.as_ref().map_or(0, heap)
    }
}
pub fn reference_labels_equal(a: &str, b: &str) -> bool { UniCase::new(a) == UniCase::new(b) }

/// An index may use this only as a negative filter. Collisions require reading
/// the actual candidate and comparing the parser-normalized labels again.
pub fn reference_label_hash(label: &str) -> u64 {
    let mut hash = DefaultHasher::new();
    UniCase::new(label).hash(&mut hash);
    hash.finish()
}

/// An unfinished paragraph recognized by the actual first pass. A fragment
/// edge is not a completed paragraph, heading, table, or inline parse proof.
#[derive(Clone, Debug)]
pub struct OpenParagraph { start: usize, options: Options, containers: BlockCarry }
impl OpenParagraph {
    pub(crate) fn new(start: usize, options: Options, containers: BlockCarry) -> Self {
        Self { start, options, containers }
    }
    pub fn start(&self) -> usize { self.start }
    pub fn containers(&self) -> &BlockCarry { &self.containers }
    /// The stream's positions are relative to this actual paragraph input.
    /// Completion of the token pass is not completion of block/inline parsing.
    pub fn run_stream(&self) -> InlineRunStream { InlineRunStream::new(self.options) }
    /// Survey only: this records actual MaybeCode runs for the producer's
    /// existing derived pages. HTML/link precedence and nearest-closer search
    /// still have to join before any code/style annotation is published.
    pub fn code_run_stream(&self) -> CodeRunStream { CodeRunStream::new() }
}

/// Actual next-line decision for an already admitted root paragraph. Source
/// is never padded with a fabricated prefix/EOF. NeedMore retains the same
/// producer until the real line(s) required by the pinned grammar are present.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParagraphFollowing {
    NeedMore,
    Continue { skip: usize },
    End,
    Setext { consumed: usize, level: u8 },
}
impl OpenParagraph {
    pub fn following_line(&self, text: &str, eof: bool) -> Option<ParagraphFollowing> {
        if text.len() > PROBE_BYTES || !self.containers.is_root() { return None; }
        crate::firstpass::paged_paragraph_following(text, self.options, eof)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct OpenFence { pub start: usize, pub character: u8, pub length: usize }

#[derive(Clone, Debug)]
pub(crate) struct OpenHtml { pub start: usize, pub continuation: HtmlContinuation }

#[derive(Clone)]
pub enum HtmlBlockWork { Known(usize, HtmlContinuation), Opening(HtmlOpening) }

pub struct BlockProbe {
    pub(crate) prefix: usize,
    pub(crate) blocks: Vec<BlockRange>,
    pub(crate) root_checkpoints: Vec<usize>,
    pub(crate) references: Vec<ParsedReference<'static>>,
    pub(crate) fence: Option<OpenFence>,
    pub(crate) html: Option<OpenHtml>,
    pub(crate) html_opening: Option<HtmlOpening>,
    pub(crate) paragraph: Option<OpenParagraph>,
    pub(crate) incomplete: bool,
    pub(crate) outgoing: BlockCarry,
}
impl BlockProbe {
    pub fn incomplete(&self) -> bool { self.incomplete }
    pub fn prefix_bytes(&self) -> usize { self.prefix }
    pub fn blocks(&self) -> &[BlockRange] { &self.blocks }
    /// Actual first-pass root-spine positions, including reference definitions
    /// which do not create a block node. Every point lies in the proved prefix.
    pub fn root_checkpoints(&self) -> &[usize] { &self.root_checkpoints }
    pub fn references(&self) -> &[ParsedReference<'static>] { &self.references }
    pub fn outgoing(&self) -> &BlockCarry { &self.outgoing }
    pub fn open_paragraph(&self) -> Option<&OpenParagraph> { self.paragraph.as_ref() }
    /// The whole supplied suffix is proved literal code. The opening delimiter
    /// was recognized by parse_fenced_code_block, not by an independent regex.
    pub fn open_fence(&self) -> Option<(usize, FenceContinuation)> {
        self.fence.as_ref().map(|fence| (fence.start, FenceContinuation {
            character: fence.character, length: fence.length as u64,
            state: FenceLine::Leading(0), count: 0,
        }))
    }
    /// The SAME first pass selected this root HTML block. All retained bytes
    /// remain literal HTML; an unfinished tag or arbitrary '<' is not proof.
    pub fn open_html(&self) -> Option<(usize, HtmlContinuation)> {
        self.html.as_ref().map(|html| (html.start, html.continuation.clone()))
    }
    pub fn into_references(self) -> RefDefs<'static> {
        let mut definitions = RefDefs::default();
        for definition in self.references { definitions.insert_parsed(definition); }
        definitions
    }
}

/// Nonfinal input must end in LF, so an unfinished physical line is never
/// treated as an EOF interrupt, optional title, or completed closing fence.
/// Larger/incomplete blocks are retained by the caller up to PROBE_BYTES.
pub fn probe_blocks(text: &str, options: Options, eof: bool) -> Option<BlockProbe> {
    let supported = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    if text.len() > PROBE_BYTES || (!eof && !text.ends_with('\n')) || !(options & !supported).is_empty() {
        return None;
    }
    Some(crate::firstpass::probe_paged_blocks(text, options, eof))
}

/// Resume the same first pass at an actual child-block boundary, including
/// open lists/quotes. A completed paragraph is emitted only after following
/// source proves its end; synthetic EOF never completes a nonfinal paragraph.
pub fn probe_continuing_blocks(text: &str, options: Options, eof: bool, incoming: &BlockCarry) -> Option<BlockProbe> {
    let supported = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    if text.len() > PROBE_BYTES || (!eof && !text.ends_with('\n')) || !(options & !supported).is_empty() {
        return None;
    }
    crate::firstpass::probe_continuing_blocks(text, options, eof, incoming)
}

/// Begin internal paragraph work using the actual first pass on one source
/// prefix. The grammar's choice may still change at a later physical line:
/// this returns no completed block or rendering proof. Its purpose is to
/// continue token work without retaining that prefix as a giant String.
pub fn begin_unfinished_paragraph(text: &str, options: Options, incoming: &BlockCarry) -> Option<OpenParagraph> {
    let supported = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    if text.is_empty() || text.len() > PROBE_BYTES || !(options & !supported).is_empty() { return None; }
    crate::firstpass::probe_continuing_blocks(text, options, false, incoming)?.paragraph
}

/// Physically complete leading blank lines at an already proved root.
/// scan_blank_line is the SAME ordinary first-pass scanner. Its EOF-as-EOL
/// case, and a trailing CR whose optional LF is uncopied, confer no proof.
/// This is only derived source coverage; it does not classify a later block.
pub fn completed_root_blank_prefix(text: &str) -> Option<usize> {
    if text.is_empty() || text.len() > PROBE_BYTES { return None; }
    let bytes = text.as_bytes();
    let mut at = 0usize;
    while let Some(count) = crate::scanners::scan_blank_line(&bytes[at..]) {
        if count == 0 { break; }
        let end = at.checked_add(count)?;
        match bytes.get(end - 1) {
            Some(b'\n') => (),
            Some(b'\r') if end < bytes.len() => (),
            _ => break,
        }
        at = end;
    }
    (at != 0).then_some(at)
}

/// Admit a real first-pass-selected root HTML block even when its current
/// physical line exceeds the probe. Type7 needs its complete actual opening
/// line: a fake prefix EOF cannot establish the required trailing blank line.
pub fn begin_unfinished_html(text: &str, options: Options, incoming: &BlockCarry) -> Option<(usize, HtmlContinuation)> {
    match begin_unfinished_html_work(text, options, incoming)? {
        HtmlBlockWork::Known(start, html) => Some((start, html)),
        HtmlBlockWork::Opening(_) => None,
    }
}

/// Fixed first-pass HTML choice or the SAME first pass's still pending type7
/// opening. An actual later byte must resolve the latter before any coverage
/// or paragraph witness can be published.
pub fn begin_unfinished_html_work(text: &str, options: Options, incoming: &BlockCarry) -> Option<HtmlBlockWork> {
    let supported = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    if text.len() < PROBE_BYTES - 3 || text.len() > PROBE_BYTES || !incoming.is_root()
        || !(options & !supported).is_empty() { return None; }
    let probe = crate::firstpass::probe_continuing_blocks(text, options, false, incoming)?;
    if probe.prefix_bytes() != 0 { return None; }
    if let Some((start, html)) = probe.open_html() { return Some(HtmlBlockWork::Known(start, html)); }
    probe.html_opening.map(HtmlBlockWork::Opening)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FenceLine { Leading(u8), Run, Spaces, Body }

/// Constant resident state for a proved top-level fenced literal. A body line
/// may be arbitrarily long. Container fences remain in the normal block probe;
/// this value is not a guessed continuation for a list or blockquote.
#[derive(Clone, Debug)]
pub struct FenceContinuation {
    character: u8,
    length: u64,
    state: FenceLine,
    count: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FenceEnd {
    /// Bytes consumed, including the CR or LF establishing the closing line.
    pub consumed: usize,
    pub closed: bool,
    /// Closing code range ends before the line ending, matching offset_iter.
    pub range_end: usize,
}
impl FenceContinuation {
    pub fn delimiter(&self) -> (u8, u64) { (self.character, self.length) }
    /// Fixed derived-page representation. The source/index owner must bind it
    /// to the exact proved input prefix; this is never a source edit grant.
    pub fn checkpoint(&self) -> [u64; 4] {
        let state = match self.state {
            FenceLine::Leading(spaces) => u64::from(spaces),
            FenceLine::Run => 4, FenceLine::Spaces => 5, FenceLine::Body => 6,
        };
        [u64::from(self.character), self.length, state, self.count]
    }
    pub fn from_checkpoint(value: [u64; 4]) -> Option<Self> {
        let [character, length, state, count] = value;
        if (character != u64::from(b'`') && character != u64::from(b'~')) || !(3..=PROBE_BYTES as u64).contains(&length) {
            return None;
        }
        let state = match state {
            0..=3 if count == 0 => FenceLine::Leading(state as u8),
            4 if (1..=length).contains(&count) => FenceLine::Run,
            5 if (1..=length).contains(&count) => FenceLine::Spaces,
            6 if count == 0 => FenceLine::Body,
            _ => return None,
        };
        Some(Self { character: character as u8, length, state, count })
    }
    /// Consume one bounded piece. A found terminator leaves the remaining bytes
    /// to the root first pass. No line or cluster String is accumulated.
    pub fn consume(&mut self, bytes: &[u8], eof: bool) -> Option<FenceEnd> {
        for (index, byte) in bytes.iter().copied().enumerate() {
            let closing = matches!(self.state, FenceLine::Run | FenceLine::Spaces) && self.count >= self.length;
            if closing && (byte == b'\n' || byte == b'\r') {
                return Some(FenceEnd { consumed: index + 1, range_end: index, closed: true });
            }
            self.state = match (self.state, byte) {
                (FenceLine::Leading(spaces), b' ') if spaces < 3 => FenceLine::Leading(spaces + 1),
                (FenceLine::Leading(_), found) if found == self.character => {
                    self.count = 1; FenceLine::Run
                }
                (FenceLine::Run, found) if found == self.character => {
                    self.count = self.count.saturating_add(1).min(self.length); FenceLine::Run
                }
                (FenceLine::Run | FenceLine::Spaces, b' ') => FenceLine::Spaces,
                _ => { self.count = 0; FenceLine::Body },
            };
            if byte == b'\n' {
                self.state = FenceLine::Leading(0); self.count = 0;
            }
        }
        if eof {
            // Both an actual closing delimiter at EOF and an unclosed fence
            // end the code range at the genuine document end.
            Some(FenceEnd { consumed: bytes.len(), range_end: bytes.len(), closed: matches!(self.state, FenceLine::Run | FenceLine::Spaces) && self.count >= self.length })
        } else { None }
    }
}

pub(crate) mod angle;
pub use angle::{AngleGuard, AngleKind, AngleStatus, AngleStep, AngleStream};
