//! Resumable forms of scanners.rs' URI/email/HTML recognizers. Their predicates
//! and finite transitions are shared with the ordinary scanners; source text
//! and normalized URL/tag bodies are never retained by the paged producer.
//! Locally authored/adapted extension under the crate's MIT license.
use super::{InlineRunError, PROBE_BYTES};
use crate::scanners::{is_ascii_alphanumeric, is_ascii_letterdigitdash, is_ascii_whitespace,
    is_ascii_whitespace_no_nl, is_valid_unquoted_attr_value_char};

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum Scan { More, Match, No }
#[derive(Clone, Copy)]
enum UriState { First, Scheme(u8), Body, Dead, Done }
pub(crate) struct Uri(UriState);
impl Uri {
    pub(crate) fn new() -> Self { Self(UriState::First) }
    pub(crate) fn step(&mut self, c: u8) -> Scan {
        self.0 = match self.0 {
            UriState::First if c.is_ascii_alphabetic() => UriState::Scheme(1),
            UriState::Scheme(count) if c == b':' && (2..=32).contains(&count) => UriState::Body,
            UriState::Scheme(count) if count < 32 && (is_ascii_alphanumeric(c) || matches!(c, b'.' | b'-' | b'+')) => UriState::Scheme(count + 1),
            UriState::Body if c == b'>' => UriState::Done,
            UriState::Body if c > b' ' && c != b'<' => UriState::Body,
            _ => UriState::Dead,
        };
        match self.0 { UriState::Done => Scan::Match, UriState::Dead => Scan::No, _ => Scan::More }
    }
}
#[derive(Clone, Copy)]
enum EmailState { Local(bool), Domain { count: u8, dash: bool }, Dead, Done }
pub(crate) struct Email(EmailState);
impl Email {
    pub(crate) fn new() -> Self { Self(EmailState::Local(false)) }
    pub(crate) fn step(&mut self, c: u8) -> Scan {
        self.0 = match self.0 {
            EmailState::Local(true) if c == b'@' => EmailState::Domain { count: 0, dash: false },
            EmailState::Local(_) if is_ascii_alphanumeric(c) || matches!(c,
                b'.' | b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'*' | b'+' | b'/' | b'=' | b'?'
                | b'^' | b'_' | b'`' | b'{' | b'|' | b'}' | b'~' | b'-') => EmailState::Local(true),
            EmailState::Domain { count, .. } if count < 63 && is_ascii_alphanumeric(c) => EmailState::Domain { count: count + 1, dash: false },
            EmailState::Domain { count, .. } if (1..63).contains(&count) && c == b'-' => EmailState::Domain { count: count + 1, dash: true },
            EmailState::Domain { count, dash: false } if count > 0 && c == b'.' => EmailState::Domain { count: 0, dash: false },
            EmailState::Domain { count, dash: false } if count > 0 && c == b'>' => EmailState::Done,
            _ => EmailState::Dead,
        };
        match self.0 { EmailState::Done => Scan::Match, EmailState::Dead => Scan::No, _ => Scan::More }
    }
}
#[derive(Clone, Copy)]
enum TagState { Less, Start, FirstName(bool), Name(bool), CloseSpace, Between(bool),
    AttrName, AfterAttr(bool), BeforeValue, Quoted(u8), Unquoted, Slash, Done, Dead }
#[derive(Clone)]
pub(crate) struct Tag { state: TagState, allow_newlines: bool }
impl Tag {
    pub(crate) fn new(allow_newlines: bool) -> Self { Self { state: TagState::Less, allow_newlines } }
    pub(crate) fn step(&mut self, c: u8) -> Scan {
        loop {
            self.state = match self.state {
                TagState::Less if c == b'<' => TagState::Start,
                TagState::Start if c == b'/' => TagState::FirstName(true),
                TagState::Start if c.is_ascii_alphabetic() => TagState::Name(false),
                TagState::FirstName(close) if c.is_ascii_alphabetic() => TagState::Name(close),
                TagState::Name(close) if is_ascii_letterdigitdash(c) => TagState::Name(close),
                TagState::Name(close) => { self.state = if close { TagState::CloseSpace } else { TagState::Between(false) }; continue; }
                TagState::CloseSpace if is_ascii_whitespace_no_nl(c) => TagState::CloseSpace,
                TagState::CloseSpace if c == b'>' => TagState::Done,
                TagState::Between(_) if c == b'>' => TagState::Done,
                TagState::Between(_) if c == b'/' => TagState::Slash,
                TagState::Between(_) if is_ascii_whitespace(c) && (self.allow_newlines || !matches!(c, b'\n' | b'\r')) => TagState::Between(true),
                TagState::Between(true) if c.is_ascii_alphabetic() || matches!(c, b'_' | b':') => TagState::AttrName,
                TagState::AttrName if is_ascii_alphanumeric(c) || matches!(c, b'_' | b'.' | b':' | b'-') => TagState::AttrName,
                TagState::AttrName => { self.state = TagState::AfterAttr(false); continue; }
                TagState::AfterAttr(_) if is_ascii_whitespace(c) && (self.allow_newlines || !matches!(c, b'\n' | b'\r')) => TagState::AfterAttr(true),
                TagState::AfterAttr(_) if c == b'=' => TagState::BeforeValue,
                TagState::AfterAttr(space) => { self.state = TagState::Between(space); continue; }
                TagState::BeforeValue if is_ascii_whitespace(c) && (self.allow_newlines || !matches!(c, b'\n' | b'\r')) => TagState::BeforeValue,
                TagState::BeforeValue if matches!(c, b'\'' | b'"') => TagState::Quoted(c),
                TagState::BeforeValue if is_valid_unquoted_attr_value_char(c) => TagState::Unquoted,
                TagState::Quoted(quote) if c == quote => TagState::Between(false),
                TagState::Quoted(quote) if self.allow_newlines || !matches!(c, b'\n' | b'\r') => TagState::Quoted(quote),
                TagState::Unquoted if is_valid_unquoted_attr_value_char(c) => TagState::Unquoted,
                TagState::Unquoted => { self.state = TagState::Between(false); continue; }
                TagState::Slash if c == b'>' => TagState::Done,
                _ => TagState::Dead,
            };
            return match self.state { TagState::Done => Scan::Match, TagState::Dead => Scan::No, _ => Scan::More };
        }
    }
}

/// Same four failed-scan witnesses as the ordinary parser. Offsets are global
/// within this captured paragraph; they carry no source/publication rights.
#[derive(Clone, Default)]
pub struct AngleGuard { pub(crate) cdata: u64, pub(crate) processing: u64,
    pub(crate) declaration: u64, pub(crate) comment: u64 }
#[derive(Clone, Copy)]
enum SpecialState { Less, Start, Bang, Dash, Comment(u8), CdataPrefix(u8), Cdata, Brackets,
    Declaration, Processing(bool), Done, Dead }
pub(crate) struct Special { state: SpecialState, pub(crate) guard: AngleGuard, last_question: u64 }
impl Special {
    pub(crate) fn new(guard: AngleGuard) -> Self { Self { state: SpecialState::Less, guard, last_question: 0 } }
    pub(crate) fn after_bang(guard: AngleGuard) -> Self { Self { state: SpecialState::Bang, guard, last_question: 0 } }
    pub(crate) fn after_question(guard: AngleGuard, at: u64) -> Self {
        Self { state: if at > guard.processing { SpecialState::Processing(false) } else { SpecialState::Dead },
            guard, last_question: at }
    }
    pub(crate) fn step(&mut self, c: u8, at: u64) -> Scan {
        self.state = match self.state {
            SpecialState::Less if c == b'<' => SpecialState::Start,
            SpecialState::Start if c == b'!' => SpecialState::Bang,
            SpecialState::Start if c == b'?' && at.saturating_add(1) > self.guard.processing => {
                self.last_question = at + 1; SpecialState::Processing(false)
            }
            SpecialState::Bang if c == b'-' && at.saturating_add(1) > self.guard.comment => SpecialState::Dash,
            SpecialState::Bang if c == b'[' && at.saturating_add(1) > self.guard.cdata => SpecialState::CdataPrefix(0),
            SpecialState::Bang if c.is_ascii_alphabetic() && at.saturating_add(1) > self.guard.declaration => SpecialState::Declaration,
            SpecialState::Dash if c == b'-' => { self.guard.comment = at; SpecialState::Comment(2) }
            SpecialState::Comment(dashes) if c == b'>' && dashes >= 2 => { self.guard.comment = at.saturating_sub(1); SpecialState::Done }
            SpecialState::Comment(dashes) if c == b'-' => {
                if dashes > 0 { self.guard.comment = at; }
                SpecialState::Comment((dashes + 1).min(2))
            }
            SpecialState::Comment(dashes) => {
                if dashes > 0 { self.guard.comment = at; }
                SpecialState::Comment(0)
            },
            SpecialState::CdataPrefix(index) if b"CDATA[".get(usize::from(index)) == Some(&c) => {
                if index == 5 { SpecialState::Cdata } else { SpecialState::CdataPrefix(index + 1) }
            }
            SpecialState::Cdata if c == b']' => SpecialState::Brackets,
            SpecialState::Cdata => SpecialState::Cdata,
            SpecialState::Brackets if c == b']' => SpecialState::Brackets,
            // Preserve the actual pinned scanner's first-bracket-run decision,
            // including its accepted one-bracket terminator; no spec rewrite.
            SpecialState::Brackets if c == b'>' => SpecialState::Done,
            SpecialState::Brackets => { self.guard.cdata = at; SpecialState::Dead }
            SpecialState::Declaration if c == b'>' => SpecialState::Done,
            SpecialState::Declaration => SpecialState::Declaration,
            SpecialState::Processing(true) if c == b'>' => SpecialState::Done,
            SpecialState::Processing(_) => {
                if c == b'?' { self.last_question = at + 1; }
                SpecialState::Processing(c == b'?')
            }
            _ => SpecialState::Dead,
        };
        match self.state { SpecialState::Done => Scan::Match, SpecialState::Dead => Scan::No, _ => Scan::More }
    }
    pub(crate) fn finish(&mut self, at: u64) {
        match self.state {
            SpecialState::Comment(dashes) if dashes > 0 => self.guard.comment = at,
            SpecialState::Cdata | SpecialState::Brackets => self.guard.cdata = at,
            SpecialState::Declaration => self.guard.declaration = at,
            SpecialState::Processing(_) => self.guard.processing = self.last_question,
            _ => (),
        }
        self.state = SpecialState::Dead;
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AngleKind { Uri, Email, Html }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AngleStatus { Pending, Rejected, Matched(AngleKind) }
pub struct AngleStep { pub consumed: usize, pub status: AngleStatus }
/// Parallel precedence candidates need only finite state and at most52 copied
/// bytes for a possible local attachment URI. Long URLs/tags retain no body.
pub struct AngleStream {
    origin: u64, count: u64, uri: Uri, email: Email, tag: Tag, special: Special,
    uri_state: Scan, email_state: Scan, tag_state: Scan, special_state: Scan,
    candidate: Vec<u8>, candidate_overflow: bool, status: AngleStatus, failed: bool,
}
impl AngleStream {
    pub fn new(origin: u64, guard: AngleGuard) -> Self {
        Self { origin, count: 0, uri: Uri::new(), email: Email::new(), tag: Tag::new(true), special: Special::new(guard),
            uri_state: Scan::More, email_state: Scan::More, tag_state: Scan::More, special_state: Scan::More,
            candidate: Vec::with_capacity(52), candidate_overflow: false, status: AngleStatus::Pending, failed: false }
    }
    pub fn guard(&self) -> AngleGuard { self.special.guard.clone() }
    pub fn attachment_candidate(&self) -> Option<&[u8]> {
        (self.status == AngleStatus::Matched(AngleKind::Uri) && !self.candidate_overflow).then_some(self.candidate.as_slice())
    }
    pub fn retained_text_bytes(&self) -> usize { self.candidate.len() }
    /// block_end must be the actual completed paragraph boundary established
    /// by the first pass. An arbitrary source/page edge must pass false.
    pub fn feed(&mut self, input: &str, block_end: bool, cancelled: &mut impl FnMut() -> bool) -> Result<AngleStep, InlineRunError> {
        if self.failed { return Err(InlineRunError::Invalid("angle stream failed")); }
        let result = self.feed_inner(input, block_end, cancelled);
        if result.is_err() { self.failed = true; } result
    }
    fn feed_inner(&mut self, input: &str, block_end: bool, cancelled: &mut impl FnMut() -> bool) -> Result<AngleStep, InlineRunError> {
        if cancelled() { return Err(InlineRunError::Cancelled); }
        if input.len() > PROBE_BYTES || self.status != AngleStatus::Pending && !input.is_empty() {
            return Err(InlineRunError::Invalid("angle input bound/state"));
        }
        if self.status != AngleStatus::Pending { return Ok(AngleStep { consumed: 0, status: self.status }); }
        for (index, &c) in input.as_bytes().iter().enumerate() {
            if index % 256 == 0 && cancelled() { return Err(InlineRunError::Cancelled); }
            let at = self.origin.checked_add(self.count).ok_or(InlineRunError::Invalid("angle source position"))?;
            let next = self.count.checked_add(1).ok_or(InlineRunError::Invalid("angle source counter"))?;
            self.origin.checked_add(next).ok_or(InlineRunError::Invalid("angle source extent"))?;
            if self.count == 0 {
                if c != b'<' { return Err(InlineRunError::Invalid("angle source opening")); }
            } else {
                if self.uri_state == Scan::More { self.uri_state = self.uri.step(c); }
                if self.email_state == Scan::More { self.email_state = self.email.step(c); }
                if c != b'>' && !self.candidate_overflow {
                    if self.candidate.len() == 52 { self.candidate.clear(); self.candidate_overflow = true; }
                    else { self.candidate.push(c); }
                }
            }
            if self.tag_state == Scan::More { self.tag_state = self.tag.step(c); }
            if self.special_state == Scan::More { self.special_state = self.special.step(c, at); }
            let matched = if self.uri_state == Scan::Match { Some(AngleKind::Uri) }
                else if self.email_state == Scan::Match { Some(AngleKind::Email) }
                else if self.tag_state == Scan::Match || self.special_state == Scan::Match { Some(AngleKind::Html) }
                else { None };
            if let Some(kind) = matched {
                if !input.is_char_boundary(index + 1) { return Err(InlineRunError::Invalid("angle matched scalar boundary")); }
                self.count = next; self.status = AngleStatus::Matched(kind);
                return Ok(AngleStep { consumed: index + 1, status: self.status });
            }
            if self.uri_state == Scan::No && self.email_state == Scan::No && self.tag_state == Scan::No && self.special_state == Scan::No {
                if !input.is_char_boundary(index) { return Err(InlineRunError::Invalid("angle rejected scalar boundary")); }
                self.status = AngleStatus::Rejected;
                // Reject before the bad byte: a nonASCII name byte can be
                // the first byte of a scalar, never return its interior.
                return Ok(AngleStep { consumed: index, status: self.status });
            }
            self.count = next;
        }
        if block_end {
            self.special.finish(self.origin.checked_add(self.count).ok_or(InlineRunError::Invalid("angle paragraph end"))?);
            self.status = AngleStatus::Rejected;
        }
        Ok(AngleStep { consumed: input.len(), status: self.status })
    }
}
