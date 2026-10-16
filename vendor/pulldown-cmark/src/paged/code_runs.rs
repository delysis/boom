//! Grouped MaybeCode input matching firstpass::parse_line. This is a survey,
//! not a completed inline proof: actual host search and higher-precedence
//! masking must join before source-bound code annotations can be emitted.
//! Locally authored extension, distributed under pulldown-cmark's MIT license.
use super::{InlinePoint, InlineRunError, PROBE_BYTES};

const RUNS_PER_STEP: usize = 128;
fn advance(point: InlinePoint, value: char) -> Result<InlinePoint, InlineRunError> {
    Ok(InlinePoint { bytes: point.bytes.checked_add(value.len_utf8() as u64)
        .ok_or(InlineRunError::Invalid("code survey byte counter"))?,
        utf16: point.utf16.checked_add(value.len_utf16() as u64)
        .ok_or(InlineRunError::Invalid("code survey UTF16 counter"))? })
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CodeRun {
    pub start: InlinePoint,
    pub end: InlinePoint,
    pub count: u64,
    pub preceded_by_backslash: bool,
}
impl CodeRun {
    fn validate(&self) -> Result<(), InlineRunError> {
        if self.count == 0 || self.start.bytes.checked_add(self.count) != Some(self.end.bytes)
            || self.start.utf16.checked_add(self.count) != Some(self.end.utf16) {
            return Err(InlineRunError::Invalid("code run source extent"));
        }
        Ok(())
    }
    pub fn checkpoint(&self) -> [u64; 6] {
        [self.start.bytes, self.start.utf16, self.end.bytes, self.end.utf16, self.count,
            u64::from(self.preceded_by_backslash)]
    }
    pub fn from_checkpoint(words: [u64; 6]) -> Result<Self, InlineRunError> {
        let [bytes, utf16, end_bytes, end_utf16, count, escaped] = words;
        if escaped > 1 { return Err(InlineRunError::Invalid("code run escape flag")); }
        let value = Self { start: InlinePoint { bytes, utf16 }, end: InlinePoint { bytes: end_bytes, utf16: end_utf16 },
            count, preceded_by_backslash: escaped == 1 };
        value.validate()?; Ok(value)
    }
    /// Matches the opening-side adjustment in handle_inline_pass1. A later
    /// closer's full count is used even when that run had an escaped prefix.
    pub fn opening_count(&self) -> Result<u64, InlineRunError> {
        self.validate()?; Ok(self.count - u64::from(self.preceded_by_backslash))
    }
}

pub struct CodeRuns {
    pub consumed: usize,
    pub runs: Vec<CodeRun>,
    pub line_boundary: bool,
    pub complete: bool,
}
/// One run counter, one escape-parity bit and exact counters survive a source
/// chunk. No code body, String, per-character token table or count map is kept.
pub struct CodeRunStream {
    point: InlinePoint,
    run: Option<CodeRun>,
    escape: bool,
    stopped: bool,
    complete: bool,
    failed: bool,
}
impl CodeRunStream {
    pub(super) fn new() -> Self {
        Self { point: InlinePoint::default(), run: None, escape: false, stopped: false, complete: false, failed: false }
    }
    pub(super) fn at(point: InlinePoint, escape: bool) -> Self {
        Self { point, run: None, escape, stopped: false, complete: false, failed: false }
    }
    pub fn finish_line(&mut self, ending: &str) -> Result<(), InlineRunError> {
        self.continue_line(ending, "")?; self.complete = true; Ok(())
    }
    pub fn point(&self) -> InlinePoint { self.point }
    pub fn retained_text_bytes(&self) -> usize { 0 }
    fn flush(&mut self, output: &mut Vec<CodeRun>) -> bool {
        if self.run.is_none() { return true; }
        if output.len() == RUNS_PER_STEP { return false; }
        output.push(self.run.take().expect("checked code run")); true
    }
    pub fn continue_line(&mut self, ending: &str, indentation: &str) -> Result<(), InlineRunError> {
        if self.failed || self.complete || !self.stopped || self.run.is_some()
            || !matches!(ending, "\n" | "\r" | "\r\n") || indentation.len() > PROBE_BYTES
            || !indentation.bytes().all(|byte| matches!(byte, b' ' | b'\t')) {
            return Err(InlineRunError::Invalid("code survey actual line continuation"));
        }
        let mut point = self.point;
        for value in ending.chars().chain(indentation.chars()) { point = advance(point, value)?; }
        self.point = point; self.escape = false; self.stopped = false; Ok(())
    }
    /// The same real paragraph/line scope without collecting MaybeCode runs.
    /// Used before an angle construct: URLs/HTML can contain arbitrary tick
    /// density, so scope discovery must not sort code hidden inside them.
    pub fn scan_scope(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<CodeRuns, InlineRunError> {
        if self.failed { return Err(InlineRunError::Invalid("paragraph scope already failed")); }
        let result = self.scan_scope_inner(input, eof, cancelled);
        if result.is_err() { self.failed = true; } result
    }
    fn scan_scope_inner(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<CodeRuns, InlineRunError> {
        if cancelled() { return Err(InlineRunError::Cancelled); }
        if input.len() > PROBE_BYTES || self.run.is_some() || (self.stopped || self.complete) && !input.is_empty() {
            return Err(InlineRunError::Invalid("paragraph scope input bound/state"));
        }
        let mut consumed = 0usize; let mut next_check = 0usize;
        for c in input.chars() {
            if consumed >= next_check {
                if cancelled() { return Err(InlineRunError::Cancelled); }
                next_check = consumed.saturating_add(256);
            }
            if matches!(c, '\r' | '\n') { self.stopped = true; break; }
            self.point = advance(self.point, c)?; consumed += c.len_utf8();
        }
        if eof && consumed == input.len() && !self.stopped { self.complete = true; }
        Ok(CodeRuns { consumed, runs: Vec::new(), line_boundary: self.stopped, complete: self.complete })
    }
    pub fn feed(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<CodeRuns, InlineRunError> {
        if self.failed { return Err(InlineRunError::Invalid("code survey already failed")); }
        let result = self.feed_inner(input, eof, cancelled);
        if result.is_err() { self.failed = true; }
        result
    }
    fn feed_inner(&mut self, input: &str, eof: bool, cancelled: &mut impl FnMut() -> bool) -> Result<CodeRuns, InlineRunError> {
        if cancelled() { return Err(InlineRunError::Cancelled); }
        if input.len() > PROBE_BYTES || (self.stopped || self.complete) && !input.is_empty() {
            return Err(InlineRunError::Invalid("code survey input bound/state"));
        }
        let mut at = 0usize; let mut next_check = 0usize; let mut runs = Vec::with_capacity(RUNS_PER_STEP);
        if self.stopped || self.complete { return Ok(CodeRuns { consumed: 0, runs, line_boundary: self.stopped, complete: self.complete }); }
        while at < input.len() && runs.len() < RUNS_PER_STEP {
            if at >= next_check {
                if cancelled() { return Err(InlineRunError::Cancelled); }
                next_check = at.saturating_add(256);
            }
            let value = input[at..].chars().next().ok_or(InlineRunError::Invalid("code survey scalar"))?;
            if value == '`' {
                self.point = advance(self.point, value)?;
                if let Some(run) = &mut self.run {
                    run.count = run.count.checked_add(1).ok_or(InlineRunError::Invalid("code survey run counter"))?;
                    run.end = self.point;
                } else {
                    let start = InlinePoint { bytes: self.point.bytes - 1, utf16: self.point.utf16 - 1 };
                    self.run = Some(CodeRun { start, end: self.point, count: 1, preceded_by_backslash: self.escape });
                }
                self.escape = false; at += 1; continue;
            }
            if !self.flush(&mut runs) { break; }
            if matches!(value, '\r' | '\n') { self.stopped = true; break; }
            self.escape = if value == '\\' { !self.escape } else { false };
            self.point = advance(self.point, value)?; at += value.len_utf8();
        }
        if eof && at == input.len() && !self.stopped && self.flush(&mut runs) {
            if cancelled() { return Err(InlineRunError::Cancelled); }
            self.complete = true;
        }
        Ok(CodeRuns { consumed: at, runs, line_boundary: self.stopped, complete: self.complete })
    }
}

/// The actual nearest compatible closer must be selected by the host's paged
/// search after higher-precedence constructs have been excluded. This value
/// describes exact SOURCE ranges only and never materializes normalized code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PreparedCodePair {
    pub start: InlinePoint,
    pub end: InlinePoint,
    pub opening_end: InlinePoint,
    pub closing_start: InlinePoint,
}
pub fn prepare_code_pair(open: CodeRun, close: CodeRun) -> Result<Option<PreparedCodePair>, InlineRunError> {
    open.validate()?; close.validate()?;
    if open.end.bytes > close.start.bytes || open.end.utf16 > close.start.utf16 {
        return Err(InlineRunError::Invalid("code pair source order"));
    }
    let count = open.opening_count()?;
    if count == 0 || count != close.count { return Ok(None); }
    let escaped = u64::from(open.preceded_by_backslash);
    let start = InlinePoint { bytes: open.start.bytes.checked_add(escaped).ok_or(InlineRunError::Invalid("code pair byte start"))?,
        utf16: open.start.utf16.checked_add(escaped).ok_or(InlineRunError::Invalid("code pair UTF16 start"))? };
    Ok(Some(PreparedCodePair { start, end: close.end, opening_end: open.end, closing_start: close.start }))
}
