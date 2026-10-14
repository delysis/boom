//! Chunked delimiter input for the pinned first pass's unfinished paragraph.
//! This is token preparation, not another block grammar or completed inline
//! parser. Flanking decisions call the SAME helpers as ordinary parse_line.
//! Locally authored extension to pulldown-cmark; distributed under its MIT
//! license. No input String, source-sized token array, cache or file owner.
use super::{PROBE_BYTES, check, CodeRun, CodeRunStream, PreparedCodePair};
use crate::Options;

const TOKENS_PER_STEP: usize = 128;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct InlinePoint { pub bytes: u64, pub utf16: u64 }
impl InlinePoint {
    fn after(self, value: char) -> Result<Self, InlineRunError> {
        Ok(Self {
            bytes: self.bytes.checked_add(value.len_utf8() as u64).ok_or(InlineRunError::Invalid("inline byte counter"))?,
            utf16: self.utf16.checked_add(value.len_utf16() as u64).ok_or(InlineRunError::Invalid("inline UTF16 counter"))?,
        })
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineToken {
    Text { start: InlinePoint, end: InlinePoint },
    Delimiter { start: InlinePoint, end: InlinePoint, character: u8, count: u64,
        can_open: bool, can_close: bool },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineStop { ParagraphBoundary, OtherInlinePass }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineRunError { Cancelled, Invalid(&'static str) }
impl std::fmt::Display for InlineRunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self { Self::Cancelled => f.write_str("inline token preparation cancelled"), Self::Invalid(message) => f.write_str(message) }
    }
}
impl std::error::Error for InlineRunError {}

pub struct ScannedRuns {
    pub consumed: usize,
    pub tokens: Vec<InlineToken>,
    /// Only the token walk is complete. The block follower, code/link/HTML
    /// precedence and emphasis resolution must still be completed by producer.
    pub complete: bool,
    pub stopped: Option<InlineStop>,
}
#[derive(Clone, Copy, Debug)]
struct PendingRun { start: InlinePoint, character: u8, count: u64, previous: Option<char> }

/// At most one scalar, one run counter and one escape survive a source chunk.
/// A multi-megabyte delimiter run still owns no multi-megabyte String/tokens.
/// Worker handoffs retain this operation value under their existing source job.
pub struct InlineRunStream {
    options: Options,
    point: InlinePoint,
    previous: Option<char>,
    plain: Option<InlinePoint>,
    run: Option<PendingRun>,
    escape: Option<InlinePoint>,
    pending_bang: bool,
    stopped: Option<InlineStop>,
    complete: bool,
    failed: bool,
}
impl InlineRunStream {
    pub(super) fn new(options: Options) -> Self {
        Self { options, point: InlinePoint::default(), previous: None, plain: None,
            run: None, escape: None, pending_bang: false, stopped: None, complete: false, failed: false }
    }
    pub fn point(&self) -> InlinePoint { self.point }
    pub fn retained_text_bytes(&self) -> usize { 0 }
    fn advance(&mut self, value: char) -> Result<(), InlineRunError> {
        self.point = self.point.after(value)?; self.previous = Some(value); Ok(())
    }
    fn emit_plain(&mut self, tokens: &mut Vec<InlineToken>) -> bool {
        if let Some(start) = self.plain {
            if start == self.point { self.plain = None; return true; }
            if tokens.len() == TOKENS_PER_STEP { return false; }
            tokens.push(InlineToken::Text { start, end: self.point }); self.plain = None;
        }
        true
    }
    fn emit_run(&mut self, next: Option<char>, tokens: &mut Vec<InlineToken>) -> Result<bool, InlineRunError> {
        let Some(run) = self.run else { return Ok(true); };
        if tokens.len() == TOKENS_PER_STEP { return Ok(false); }
        let count = usize::try_from(run.count).map_err(|_| InlineRunError::Invalid("inline run address space"))?;
        let can_open = crate::firstpass::delimiter_can_open(run.previous, next, run.character, count, false, false);
        let can_close = crate::firstpass::delimiter_can_close(run.previous, next, run.character, count, false, false);
        // parse_line intentionally treats a >2 tilde run as ordinary text.
        if (can_open || can_close) && (run.character != b'~' || count <= 2) {
            tokens.push(InlineToken::Delimiter { start: run.start, end: self.point,
                character: run.character, count: run.count, can_open, can_close });
        } else {
            tokens.push(InlineToken::Text { start: run.start, end: self.point });
        }
        self.run = None;
        Ok(true)
    }
    /// Resume only after the actual first-pass follower admitted this physical
    /// continuation. Exact source counters include the real line ending and
    /// skipped indentation; flanks restart exactly as ordinary parse_line.
    pub fn continue_line(&mut self, ending: &str, indentation: &str) -> Result<(), InlineRunError> {
        if self.failed || self.complete || self.stopped != Some(InlineStop::ParagraphBoundary)
            || self.run.is_some() || self.plain.is_some() || self.escape.is_some()
            || !matches!(ending, "\n" | "\r" | "\r\n")
            || indentation.len() > PROBE_BYTES || !indentation.bytes().all(|byte| matches!(byte, b' ' | b'\t')) {
            return Err(InlineRunError::Invalid("inline actual line continuation"));
        }
        let mut point = self.point;
        for value in ending.chars().chain(indentation.chars()) { point = point.after(value)?; }
        self.point = point; self.previous = None; self.pending_bang = false;
        self.stopped = None; Ok(())
    }
    pub fn finish_line(&mut self, ending: &str) -> Result<(), InlineRunError> {
        self.continue_line(ending, "")?; self.complete = true; Ok(())
    }
    /// Called only at an actual stopped backtick source point. The host retains
    /// that exact source and reads the rest of the same admitted paragraph.
    pub fn code_survey(&self) -> Result<CodeRunStream, InlineRunError> {
        if self.failed || self.complete || self.stopped != Some(InlineStop::OtherInlinePass)
            || self.plain.is_some() || self.run.is_some() {
            return Err(InlineRunError::Invalid("inline code survey state"));
        }
        Ok(CodeRunStream::at(self.point, self.escape.is_some()))
    }
    pub fn code_run_start(&self) -> Result<(InlinePoint, bool), InlineRunError> {
        self.code_survey()?; Ok((self.point, self.escape.is_some()))
    }
    pub fn angle_start(&self) -> Result<InlinePoint, InlineRunError> {
        self.code_survey()?;
        if self.escape.is_some() { return Err(InlineRunError::Invalid("escaped angle is ordinary text")); }
        Ok(self.point)
    }
    pub fn bracket_start(&self) -> Result<(InlinePoint, bool), InlineRunError> {
        let mut point = self.angle_start()?;
        if self.pending_bang {
            point.bytes = point.bytes.checked_sub(1).ok_or(InlineRunError::Invalid("image opener byte"))?;
            point.utf16 = point.utf16.checked_sub(1).ok_or(InlineRunError::Invalid("image opener UTF16"))?;
        }
        Ok((point, self.pending_bang))
    }
    /// The host has consumed a complete pinned Inline Link/Image subtree and
    /// keeps its child emphasis scope separate from this outer delimiter stack.
    pub fn resume_bracket(&mut self, start: InlinePoint, end: InlinePoint) -> Result<(), InlineRunError> {
        let (actual, image) = self.bracket_start()?;
        let minimum = if image { 5 } else { 4 };
        if actual != start || end.bytes.checked_sub(start.bytes).is_none_or(|count| count < minimum)
            || end.utf16 <= self.point.utf16 || end.bytes - start.bytes < end.utf16 - start.utf16 {
            return Err(InlineRunError::Invalid("inline bracket subtree extent"));
        }
        self.point = end; self.previous = Some(')'); self.pending_bang = false;
        self.stopped = None; Ok(())
    }
    /// The source host checked every copied scalar/counter before passing a
    /// matched endpoint. Failed lookahead consumes only the known opening <.
    pub fn resume_angle(&mut self, start: InlinePoint, matched: Option<InlinePoint>) -> Result<(), InlineRunError> {
        if self.angle_start()? != start { return Err(InlineRunError::Invalid("angle source origin changed")); }
        let end = if let Some(end) = matched {
            if end.bytes <= start.bytes || end.utf16 <= start.utf16 || end.bytes - start.bytes < end.utf16 - start.utf16 {
                return Err(InlineRunError::Invalid("angle matched source extent"));
            }
            end
        } else { start.after('<')? };
        self.point = end; self.previous = Some(if matched.is_some() { '>' } else { '<' });
        self.stopped = None; Ok(())
    }
    /// Resume from a chosen actual MaybeCode pair after the host consumed and
    /// checked the same immutable bytes/UTF16 counters. Internal emphasis and
    /// apparent links/HTML in code never enter later inline passes.
    pub fn resume_code(&mut self, open: CodeRun, chosen: Option<PreparedCodePair>) -> Result<(), InlineRunError> {
        let (point, escaped) = self.code_run_start()?;
        CodeRun::from_checkpoint(open.checkpoint())?;
        if open.start != point || open.preceded_by_backslash != escaped {
            return Err(InlineRunError::Invalid("inline code captured opener"));
        }
        let end = if let Some(pair) = chosen {
            let inset = u64::from(escaped);
            if point.bytes.checked_add(inset) != Some(pair.start.bytes)
                || point.utf16.checked_add(inset) != Some(pair.start.utf16)
                || pair.opening_end != open.end || pair.closing_start.bytes < open.end.bytes
                || pair.closing_start.utf16 < open.end.utf16 || pair.end.bytes <= pair.closing_start.bytes
                || pair.end.utf16 <= pair.closing_start.utf16
                || pair.closing_start.bytes.checked_add(open.opening_count()?) != Some(pair.end.bytes)
                || pair.closing_start.utf16.checked_add(open.opening_count()?) != Some(pair.end.utf16) {
                return Err(InlineRunError::Invalid("inline code chosen source range"));
            }
            pair.end
        } else { open.end };
        self.point = end; self.previous = Some('`'); self.escape = None;
        self.stopped = None; Ok(())
    }
    /// Consume at most one <=32KiB source chunk and emit <=128 grouped tokens.
    /// A returned consumed offset is scalar-complete and has exact counters.
    /// The caller retains the remainder of its actual source piece, then yields
    /// its existing worker lane; no parser producer/FD is held by this value.
    pub fn feed(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<ScannedRuns, InlineRunError> {
        if self.failed { return Err(InlineRunError::Invalid("inline stream already failed")); }
        let result = self.feed_inner(input, eof, cancelled);
        if result.is_err() { self.failed = true; }
        result
    }
    fn feed_inner(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<ScannedRuns, InlineRunError> {
        check(cancelled).map_err(|_| InlineRunError::Cancelled)?;
        if input.len() > PROBE_BYTES { return Err(InlineRunError::Invalid("inline source chunk bound")); }
        if self.complete || self.stopped.is_some() {
            if !input.is_empty() { return Err(InlineRunError::Invalid("input after inline stop")); }
            return Ok(ScannedRuns { consumed: 0, tokens: Vec::new(), complete: self.complete, stopped: self.stopped });
        }
        let mut at = 0usize; let mut next_check = 0usize;
        let mut tokens = Vec::with_capacity(TOKENS_PER_STEP);
        while at < input.len() && tokens.len() < TOKENS_PER_STEP {
            if at >= next_check {
                check(cancelled).map_err(|_| InlineRunError::Cancelled)?; next_check = at.saturating_add(256);
            }
            let value = input[at..].chars().next().ok_or(InlineRunError::Invalid("inline scalar"))?;
            if let Some(mut run) = self.run {
                if value as u32 == u32::from(run.character) {
                    run.count = run.count.checked_add(1).ok_or(InlineRunError::Invalid("inline run counter"))?;
                    self.advance(value)?; self.run = Some(run); at += value.len_utf8(); continue;
                }
                if !self.emit_run(Some(value), &mut tokens)? { break; }
                continue;
            }
            if self.pending_bang {
                if value == '[' {
                    if !self.emit_plain(&mut tokens) { break; }
                    self.stopped = Some(InlineStop::OtherInlinePass); break;
                }
                self.pending_bang = false;
            }
            if let Some(slash) = self.escape.take() {
                if value.is_ascii_punctuation() {
                    if value == '`' {
                        self.escape = Some(slash); self.stopped = Some(InlineStop::OtherInlinePass); break;
                    }
                    // parse_line's escaped punctuation is text; its backslash
                    // belongs to source counters but not the text-node range.
                    self.plain.get_or_insert(self.point);
                    self.advance(value)?; at += value.len_utf8(); continue;
                }
                self.plain.get_or_insert(slash);
            }
            if value == '\n' || value == '\r' {
                if !self.emit_plain(&mut tokens) { break; }
                self.stopped = Some(InlineStop::ParagraphBoundary); break;
            }
            if matches!(value, '[' | '<' | '`') ||
                (value == '|' && self.options.contains(Options::ENABLE_TABLES)) {
                if !self.emit_plain(&mut tokens) { break; }
                self.stopped = Some(InlineStop::OtherInlinePass); break;
            }
            let delimiter = matches!(value, '*' | '_') ||
                (value == '~' && self.options.contains(Options::ENABLE_STRIKETHROUGH));
            if delimiter {
                if !self.emit_plain(&mut tokens) { break; }
                let run = PendingRun { start: self.point, character: value as u8, count: 1, previous: self.previous };
                self.advance(value)?; self.run = Some(run);
            } else if value == '\\' {
                if !self.emit_plain(&mut tokens) { break; }
                self.escape = Some(self.point); self.advance(value)?;
            } else {
                self.plain.get_or_insert(self.point); self.advance(value)?;
                // The actual first pass emits MaybeImage only for ! followed
                // by [. Carry one bit across a source chunk; a lone ! is text.
                self.pending_bang = value == '!';
            }
            at += value.len_utf8();
        }
        if eof && at == input.len() && self.stopped.is_none() {
            check(cancelled).map_err(|_| InlineRunError::Cancelled)?;
            if self.emit_run(None, &mut tokens)? {
                if let Some(slash) = self.escape.take() { self.plain.get_or_insert(slash); }
                if self.emit_plain(&mut tokens) { self.pending_bang = false; self.complete = true; }
            }
        }
        Ok(ScannedRuns { consumed: at, tokens, complete: self.complete, stopped: self.stopped })
    }
}
