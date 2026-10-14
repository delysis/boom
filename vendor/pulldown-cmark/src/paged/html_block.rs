//! Constant-state continuation of an HTML block already selected by firstpass.
//! This is locally authored under the crate's MIT license. It retains neither
//! HTML text nor a second block grammar: firstpass supplies the actual ending.
use super::{BlockCarry, InlineRunError, OpenParagraph, PROBE_BYTES};
use crate::Options;
use crate::scanners::is_ascii_whitespace_no_nl;

/// Only used after the actual root first pass has rejected types1–6. A
/// syntactically unfinished type7 first line is not yet a proved paragraph.
pub(crate) fn may_be_type_seven(text: &[u8]) -> bool {
    use super::angle::{Scan, Tag};
    let mut tag = Tag::new(false);
    for (at, byte) in text.iter().copied().enumerate() {
        match tag.step(byte) {
            Scan::No => return false,
            Scan::Match => return text[at + 1..].iter().copied().all(is_ascii_whitespace_no_nl),
            Scan::More => (),
        }
    }
    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HtmlOpeningStatus { Pending, Html, Paragraph }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HtmlOpeningStep { pub consumed: usize, pub status: HtmlOpeningStatus }

#[derive(Clone, Copy)]
enum OpeningState { Tag, AfterTag, Decided(HtmlOpeningStatus), Failed }

/// The actual first pass excluded types1–6 at this root. This state resolves
/// only its remaining type7 decision using the SAME ordinary Tag transitions.
/// No tag, whitespace tail, body, candidate tree or normalized text is kept.
#[derive(Clone)]
pub struct HtmlOpening {
    tag: super::angle::Tag,
    state: OpeningState,
    scanned: u64,
    paragraph: OpenParagraph,
    html_at_prefix: HtmlContinuation,
}

#[derive(Clone, Debug)]
pub enum HtmlOpeningChoice { Html(HtmlContinuation), Paragraph(OpenParagraph) }

impl HtmlOpening {
    pub(crate) fn from_first_pass(text: &str, options: Options, start: usize) -> Option<Self> {
        if start != 0 || text.is_empty() || text.len() > PROBE_BYTES || !text.starts_with('<') { return None; }
        let mut value = Self { tag: super::angle::Tag::new(false), state: OpeningState::Tag,
            scanned: 0, paragraph: OpenParagraph::new(0, options, BlockCarry::default()),
            html_at_prefix: HtmlContinuation::until_blank_line() };
        let step = value.consume(text, false, &mut || false).ok()?;
        if step.status != HtmlOpeningStatus::Pending || step.consumed != text.len() { return None; }
        // Pending Tag/AfterTag proves this prefix has no real line ending and
        // begins with the actual '<'. A later HTML choice will replay FROM
        // this prefix endpoint, not from the scanner's distant decision point.
        value.html_at_prefix.blank = false;
        Some(value)
    }
    pub fn scanned_bytes(&self) -> u64 { self.scanned }
    fn decided(&mut self, text: &str, consumed: usize, status: HtmlOpeningStatus) -> Result<HtmlOpeningStep, InlineRunError> {
        if !text.is_char_boundary(consumed) {
            self.state = OpeningState::Failed;
            return Err(InlineRunError::Invalid("HTML opening scalar boundary"));
        }
        let bytes = u64::try_from(consumed).map_err(|_| InlineRunError::Invalid("HTML opening address space"))?;
        self.scanned = self.scanned.checked_add(bytes)
            .ok_or(InlineRunError::Invalid("HTML opening counter"))?;
        self.state = OpeningState::Decided(status);
        Ok(HtmlOpeningStep { consumed, status })
    }
    /// One bounded actual source slice, with cancellation within the tag and
    /// arbitrarily long trailing whitespace. Only real EOL/EOF proves a blank
    /// suffix; any other byte returns the actual paragraph fallback witness.
    pub fn consume(&mut self, text: &str, eof: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<HtmlOpeningStep, InlineRunError> {
        use super::angle::Scan;
        let Ok(bytes) = u64::try_from(text.len()) else {
            self.state = OpeningState::Failed;
            return Err(InlineRunError::Invalid("HTML opening address space"));
        };
        if matches!(self.state, OpeningState::Decided(_) | OpeningState::Failed) || text.len() > PROBE_BYTES
            || self.scanned.checked_add(bytes).is_none() {
            self.state = OpeningState::Failed;
            return Err(InlineRunError::Invalid("HTML opening lifecycle or bound"));
        }
        for (at, byte) in text.bytes().enumerate() {
            if at % 256 == 0 && cancelled() {
                self.state = OpeningState::Failed; return Err(InlineRunError::Cancelled);
            }
            match self.state {
                OpeningState::Tag => match self.tag.step(byte) {
                    Scan::More => (),
                    Scan::Match => self.state = OpeningState::AfterTag,
                    Scan::No => return self.decided(text, at, HtmlOpeningStatus::Paragraph),
                },
                OpeningState::AfterTag if is_ascii_whitespace_no_nl(byte) => (),
                OpeningState::AfterTag if matches!(byte, b'\r' | b'\n') => {
                    return self.decided(text, at + 1, HtmlOpeningStatus::Html);
                }
                OpeningState::AfterTag => return self.decided(text, at, HtmlOpeningStatus::Paragraph),
                OpeningState::Decided(_) | OpeningState::Failed => {
                    self.state = OpeningState::Failed;
                    return Err(InlineRunError::Invalid("HTML opening active state"));
                }
            }
        }
        if cancelled() { self.state = OpeningState::Failed; return Err(InlineRunError::Cancelled); }
        if eof {
            let status = if matches!(self.state, OpeningState::AfterTag) { HtmlOpeningStatus::Html } else { HtmlOpeningStatus::Paragraph };
            return self.decided(text, text.len(), status);
        }
        self.scanned += bytes; // checked for the whole slice above
        Ok(HtmlOpeningStep { consumed: text.len(), status: HtmlOpeningStatus::Pending })
    }
    pub fn finish(self) -> Result<HtmlOpeningChoice, InlineRunError> {
        match self.state {
            OpeningState::Decided(HtmlOpeningStatus::Html) => Ok(HtmlOpeningChoice::Html(self.html_at_prefix)),
            OpeningState::Decided(HtmlOpeningStatus::Paragraph) => Ok(HtmlOpeningChoice::Paragraph(self.paragraph)),
            _ => Err(InlineRunError::Invalid("HTML opening decision has not joined")),
        }
    }
}

const ENDINGS: [&[u8]; 8] = [
    b"</pre>", b"</style>", b"</script>", b"</textarea>", b"-->", b"?>", b"]]>", b">",
];

/// A derived checkpoint, bound by its caller to an exact immutable source
/// prefix. It grants no permission to parse an arbitrary fragment as a block.
#[derive(Clone, Debug)]
pub struct HtmlContinuation {
    ending: u8,
    matched: u8,
    found: bool,
    blank: bool,
    stopped: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HtmlBlockStep {
    pub consumed: usize,
    /// A real ending line, blank line, or genuine source EOF completed this
    /// block. A matching tag alone does not end its physical HTML line.
    pub closed: bool,
}

impl HtmlContinuation {
    pub(crate) fn terminated_by(ending: &str) -> Option<Self> {
        let ending = ENDINGS.iter().position(|value| *value == ending.as_bytes())?;
        Some(Self { ending: (ending + 1) as u8, matched: 0, found: false, blank: true, stopped: false })
    }
    pub(crate) fn until_blank_line() -> Self {
        Self { ending: 0, matched: 0, found: false, blank: true, stopped: false }
    }
    pub(crate) fn after_prefix(mut self, text: &str) -> Option<Self> {
        let step = self.consume(text, false, &mut || false).ok()?;
        (step.consumed == text.len() && !step.closed).then_some(self)
    }
    pub fn checkpoint(&self) -> [u64; 4] {
        [u64::from(self.ending), u64::from(self.matched), u64::from(self.found), u64::from(self.blank)]
    }
    pub fn from_checkpoint(value: [u64; 4]) -> Option<Self> {
        let [ending, matched, found, blank] = value;
        if ending > ENDINGS.len() as u64 || found > 1 || blank > 1 { return None; }
        if ending == 0 {
            if matched != 0 || found != 0 { return None; }
        } else if matched >= ENDINGS[ending as usize - 1].len() as u64
            || found == 1 && (matched != 0 || blank != 0) { return None; }
        Some(Self { ending: ending as u8, matched: matched as u8,
            found: found == 1, blank: blank == 1, stopped: false })
    }
    /// One bounded source quantum. Pinned HTML1–5 uses scan_nextline (LF),
    /// followed by a case-sensitive contains(ending) on that complete line.
    /// HTML6/7 instead ends at scan_blank_line; a bare CR can end such a blank
    /// line. A trailing possible CRLF is retained for one real following byte.
    pub fn consume(&mut self, text: &str, eof: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<HtmlBlockStep, InlineRunError> {
        if self.stopped || text.len() > PROBE_BYTES {
            self.stopped = true;
            return Err(InlineRunError::Invalid("HTML block continuation lifecycle or bound"));
        }
        let pattern = if self.ending == 0 { &[][..] } else { ENDINGS[self.ending as usize - 1] };
        // At most eleven entries, independent of source/line length. The
        // prefix fallback preserves overlapping '-->' without rescanning text.
        let mut fallback = [0u8; 11];
        for at in 1..pattern.len() {
            let mut prior = usize::from(fallback[at - 1]);
            while prior > 0 && pattern[prior] != pattern[at] { prior = usize::from(fallback[prior - 1]); }
            if pattern[prior] == pattern[at] { prior += 1; }
            fallback[at] = prior as u8;
        }
        let bytes = text.as_bytes();
        for (at, byte) in bytes.iter().copied().enumerate() {
            if at % 256 == 0 && cancelled() {
                self.stopped = true; return Err(InlineRunError::Cancelled);
            }
            if self.ending == 0 && self.blank && byte == b'\r' {
                if at + 1 == bytes.len() && !eof {
                    return Ok(HtmlBlockStep { consumed: at, closed: false });
                }
                self.stopped = true;
                return Ok(HtmlBlockStep { consumed: at + 1 + usize::from(bytes.get(at + 1) == Some(&b'\n')), closed: true });
            }
            if byte == b'\n' {
                if self.ending == 0 && self.blank || self.ending != 0 && self.found {
                    self.stopped = true;
                    return Ok(HtmlBlockStep { consumed: at + 1, closed: true });
                }
                self.blank = true; self.matched = 0; self.found = false;
                continue;
            }
            self.blank &= is_ascii_whitespace_no_nl(byte);
            if !pattern.is_empty() && !self.found {
                let mut matched = usize::from(self.matched);
                while matched > 0 && pattern[matched] != byte { matched = usize::from(fallback[matched - 1]); }
                if pattern[matched] == byte { matched += 1; }
                if matched == pattern.len() { self.found = true; matched = 0; }
                self.matched = matched as u8;
            }
        }
        if cancelled() { self.stopped = true; return Err(InlineRunError::Cancelled); }
        self.stopped = eof;
        Ok(HtmlBlockStep { consumed: bytes.len(), closed: eof })
    }
}
