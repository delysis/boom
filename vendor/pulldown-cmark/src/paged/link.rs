//! Raw destination transitions shared with the pinned ordinary link scanner.
//! This recognizes only that grammar production, not brackets, reference
//! labels, titles or an accepted Link/Image node. Locally authored under the
//! crate's MIT license. No destination String or normalized URL is retained.
use super::{InlineRunError, PROBE_BYTES};
use crate::scanners::is_ascii_punctuation;
use std::ops::Range;

/// The actual ordinary inline passes accepted one complete Inline Link/Image
/// subtree at this source origin. This carries no source or render authority.
/// References and unfinished code/HTML dependencies remain unproved. Matched
/// children use the actual pinned pass, rather than a second child grammar.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InlineLinkFragment { end: usize, image: bool }
impl InlineLinkFragment {
    pub fn end(&self) -> usize { self.end }
    pub fn is_image(&self) -> bool { self.image }
}

/// Reuse the actual LinkStack and child emphasis parser, including disabled
/// outer links and images that can contain links. A copied page EOF cannot
/// prove a reference absent or an unresolved earlier code/HTML scan failed.
pub fn probe_inline_link(text: &str, options: crate::Options,
    cancelled: &mut impl FnMut() -> bool,
) -> Result<Option<InlineLinkFragment>, InlineRunError> {
    use crate::{BrokenLink, CowStr, Event, LinkType, Parser, Tag};
    if text.len() > PROBE_BYTES { return Err(InlineRunError::Invalid("inline link fragment bound")); }
    if cancelled() { return Err(InlineRunError::Cancelled); }
    if !text.starts_with('[') && !text.starts_with("![") { return Ok(None); }
    let mut first_reference = usize::MAX;
    let found = {
        let mut unresolved = |broken: BrokenLink<'_>| -> Option<(CowStr<'_>, CowStr<'_>)> {
            first_reference = first_reference.min(broken.span.start); None
        };
        let parser = Parser::new_with_broken_link_callback_for_inline(text, options, Some(&mut unresolved))
            .ok_or(InlineRunError::Invalid("inline link parser bound"))?;
        let mut events = parser.into_offset_iter();
        if !matches!(events.next_with_check(cancelled).map_err(|_| InlineRunError::Cancelled)?,
            Some((Event::Start(Tag::Paragraph), _))) { return Ok(None); }
        let Some((event, range)) = events.next_with_check(cancelled).map_err(|_| InlineRunError::Cancelled)? else { return Ok(None); };
        let image = match event {
            Event::Start(Tag::Link { link_type: LinkType::Inline, .. }) => false,
            Event::Start(Tag::Image { link_type: LinkType::Inline, .. }) => true,
            _ => return Ok(None),
        };
        if range.start != 0 || range.end == 0 || range.end > text.len()
            || text.as_bytes()[range.end - 1] != b')' { return Ok(None); }
        let mut depth = 1usize;
        while depth != 0 {
            let Some((event, _)) = events.next_with_check(cancelled).map_err(|_| InlineRunError::Cancelled)? else { return Ok(None); };
            match event {
                Event::Start(_) => depth = depth.checked_add(1).ok_or(InlineRunError::Invalid("inline link child depth"))?,
                Event::End(_) => depth -= 1,
                _ => (),
            }
        }
        // This witness is recorded where the actual first inline pass gives
        // up on MaybeCode/MaybeHtml. A copied edge cannot prove those failures
        // final; successful child spans and destination/title tokens skipped
        // by the actual LinkStack require no guessed absence proof.
        if !events.inline_probe_stable_through(range.end) { return Ok(None); }
        InlineLinkFragment { end: range.end, image }
    };
    if first_reference < found.end { return Ok(None); }
    if cancelled() { return Err(InlineRunError::Cancelled); }
    Ok(Some(found))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DestinationStatus { Pending, Matched, Rejected }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DestinationStep {
    /// This quantum's source bytes, excluding a terminating bare delimiter.
    pub consumed: usize,
    pub status: DestinationStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State { Start, Angle, Bare, Matched, Rejected, Failed }

/// `scan_link_dest`'s raw source grammar, retained across actual source chunks.
/// Genuine paragraph-end information belongs to the caller; supplying a page
/// edge as EOF would invent a successful bare destination. A match only proves
/// this production and grants no Link/Image or rendering authority.
pub struct LinkDestinationStream {
    state: State,
    maximum_nesting: usize,
    nesting: usize,
    escape: bool,
    bytes: u64,
    raw_start: u64,
    raw_end: u64,
}

impl LinkDestinationStream {
    pub fn new(maximum_nesting: usize) -> Self {
        Self { state: State::Start, maximum_nesting, nesting: 0, escape: false,
            bytes: 0, raw_start: 0, raw_end: 0 }
    }
    pub fn retained_text_bytes(&self) -> usize { 0 }
    pub fn scanned_bytes(&self) -> u64 { self.bytes }
    pub fn raw_range(&self) -> Option<Range<u64>> {
        (self.state == State::Matched).then_some(self.raw_start..self.raw_end)
    }
    fn status(&self) -> DestinationStatus {
        match self.state {
            State::Matched => DestinationStatus::Matched,
            State::Rejected | State::Failed => DestinationStatus::Rejected,
            _ => DestinationStatus::Pending,
        }
    }
    fn matched(&mut self, consumed: usize, raw_end: u64) -> DestinationStep {
        self.raw_end = raw_end; self.state = State::Matched;
        DestinationStep { consumed, status: DestinationStatus::Matched }
    }
    fn reject(&mut self, consumed: usize) -> DestinationStep {
        self.state = State::Rejected;
        DestinationStep { consumed, status: DestinationStatus::Rejected }
    }
    pub fn feed(&mut self, text: &str, eof: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<DestinationStep, InlineRunError> {
        if matches!(self.state, State::Matched | State::Rejected | State::Failed) {
            return Err(InlineRunError::Invalid("destination continuation consumed"));
        }
        let result = self.feed_inner(text, eof, cancelled);
        if result.is_err() { self.state = State::Failed; }
        result
    }
    fn feed_inner(&mut self, text: &str, eof: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<DestinationStep, InlineRunError> {
        if cancelled() { return Err(InlineRunError::Cancelled); }
        if text.len() > PROBE_BYTES { return Err(InlineRunError::Invalid("destination input quantum")); }
        let length = u64::try_from(text.len()).map_err(|_| InlineRunError::Invalid("destination input address space"))?;
        self.bytes.checked_add(length).ok_or(InlineRunError::Invalid("destination source extent"))?;
        let mut at = 0usize;
        let mut next_check = 0usize;
        while let Some(&byte) = text.as_bytes().get(at) {
            if at >= next_check {
                if cancelled() { return Err(InlineRunError::Cancelled); }
                next_check = at.saturating_add(256);
            }
            if self.state == State::Start {
                if byte == b'<' {
                    self.state = State::Angle;
                    self.bytes += 1; self.raw_start = self.bytes; at += 1;
                    continue;
                }
                self.state = State::Bare;
            }
            // The ordinary scanner skips a backslash AND the next byte only
            // when that next byte is ASCII punctuation. A chunk-ending slash
            // cannot decide this in advance. If it is not punctuation, replay
            // the current byte through the ordinary production below.
            if self.escape {
                self.escape = false;
                if is_ascii_punctuation(byte) {
                    self.bytes += 1; at += 1; continue;
                }
            }
            match (self.state, byte) {
                (State::Angle, b'\n' | b'\r' | b'<') => return Ok(self.reject(at)),
                (State::Angle, b'>') => {
                    let end = self.bytes;
                    self.bytes += 1; at += 1;
                    return Ok(self.matched(at, end));
                }
                (State::Bare, 0..=0x20) => {
                    if self.nesting != 0 { return Ok(self.reject(at)); }
                    return Ok(self.matched(at, self.bytes));
                }
                (State::Bare, b'(') => {
                    // Preserve the pinned check BEFORE incrementing: with
                    // maximum32, a depth33 destination is accepted;34 is not.
                    if self.nesting > self.maximum_nesting { return Ok(self.reject(at)); }
                    self.nesting = self.nesting.checked_add(1)
                        .ok_or(InlineRunError::Invalid("destination parenthesis depth"))?;
                }
                (State::Bare, b')') => {
                    if self.nesting == 0 { return Ok(self.matched(at, self.bytes)); }
                    self.nesting -= 1;
                }
                (State::Angle | State::Bare, b'\\') => self.escape = true,
                (State::Angle | State::Bare, _) => (),
                _ => return Err(InlineRunError::Invalid("destination active state")),
            }
            self.bytes += 1; at += 1;
        }
        if cancelled() { return Err(InlineRunError::Cancelled); }
        if eof {
            if self.state != State::Angle && self.nesting == 0 {
                return Ok(self.matched(at, self.bytes));
            }
            return Ok(self.reject(at));
        }
        // Pending input consumed the whole scalar-complete supplied piece.
        // A successful/rejected endpoint above is always before/after ASCII.
        Ok(DestinationStep { consumed: at, status: self.status() })
    }
}

/// The ordinary parser borrows its destination exactly as before. Calling the
/// shared transitions in bounded chunks does not impose a destination limit or
/// retain a second copy. Its actual contiguous source EOF is authoritative.
pub(crate) fn scan_destination(data: &str, start: usize, maximum_nesting: usize) -> Option<(usize, &str)> {
    let input = data.get(start..)?;
    let mut stream = LinkDestinationStream::new(maximum_nesting);
    let mut at = 0usize;
    loop {
        let mut end = at.checked_add(PROBE_BYTES)?.min(input.len());
        while !input.is_char_boundary(end) { end -= 1; }
        let step = stream.feed(input.get(at..end)?, end == input.len(), &mut || false).ok()?;
        at = at.checked_add(step.consumed)?;
        match step.status {
            DestinationStatus::Pending if at == end && end < input.len() => (),
            DestinationStatus::Matched => {
                let raw = stream.raw_range()?;
                let first = usize::try_from(raw.start).ok()?;
                let last = usize::try_from(raw.end).ok()?;
                return Some((at, input.get(first..last)?));
            }
            _ => return None,
        }
    }
}
