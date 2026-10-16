//! Bounded emphasis reduction shared with the pinned parser's stack match.
//! This prepares candidate annotations; it grants no completed block/rendering
//! proof. Precedence, opener search and source/index binding remain producer
//! responsibilities. Locally authored MIT-licensed pulldown-cmark extension.
use super::{InlinePoint, InlineRunError, InlineToken};
use crate::Options;

/// The ordinary stack and paged run matcher use one rule. Modulo reduction
/// avoids overflowing when a decoded large run is checked before admission.
pub(crate) fn eligible(character: u8, run: u64, both: bool, open_character: u8, open_run: u64, open_both: bool) -> bool {
    if character == b'~' && run != open_run { return false; }
    open_character == character && (!both && !open_both
        || (run % 3 + open_run % 3) % 3 != 0 || run % 3 == 0)
}
fn moved(point: InlinePoint, count: u64) -> Result<InlinePoint, InlineRunError> {
    Ok(InlinePoint {
        bytes: point.bytes.checked_add(count).ok_or(InlineRunError::Invalid("delimiter byte range"))?,
        utf16: point.utf16.checked_add(count).ok_or(InlineRunError::Invalid("delimiter UTF16 range"))?,
    })
}
fn backed(point: InlinePoint, count: u64) -> Result<InlinePoint, InlineRunError> {
    Ok(InlinePoint {
        bytes: point.bytes.checked_sub(count).ok_or(InlineRunError::Invalid("delimiter byte range"))?,
        utf16: point.utf16.checked_sub(count).ok_or(InlineRunError::Invalid("delimiter UTF16 range"))?,
    })
}
pub(super) fn check_run(start: InlinePoint, end: InlinePoint, character: u8, count: u64) -> Result<(), InlineRunError> {
    if !matches!(character, b'*' | b'_' | b'~') || count == 0 || moved(start, count)? != end {
        return Err(InlineRunError::Invalid("delimiter token binding"));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OpenDelimiter { pub(super) start: InlinePoint, pub(super) count: u64, pub(super) run_length: u64, pub(super) character: u8, pub(super) both: bool }
impl OpenDelimiter {
    pub fn from_token(token: InlineToken) -> Result<Self, InlineRunError> {
        let InlineToken::Delimiter { start, end, character, count, can_open, can_close } = token else {
            return Err(InlineRunError::Invalid("opener requires a delimiter token"));
        };
        check_run(start, end, character, count)?;
        if !can_open { return Err(InlineRunError::Invalid("delimiter cannot open")); }
        Ok(Self { start, count, run_length: count, character, both: can_open && can_close })
    }
    /// Fixed data for existing derived Index pages. Caller still validates the
    /// captured source, paragraph and options; these words are not authority.
    pub fn checkpoint(&self) -> [u64; 7] {
        [self.start.bytes, self.start.utf16, self.count, self.run_length, u64::from(self.character), u64::from(self.both), 0]
    }
    pub fn from_checkpoint(value: [u64; 7]) -> Result<Self, InlineRunError> {
        let [bytes, utf16, count, run_length, character, both, reserved] = value;
        if character > u64::from(u8::MAX) || both > 1 || reserved != 0 || count == 0 || run_length < count {
            return Err(InlineRunError::Invalid("opener checkpoint"));
        }
        let start = InlinePoint { bytes, utf16 }; let character = character as u8;
        check_run(start, moved(start, count)?, character, count)?;
        Ok(Self { start, count, run_length, character, both: both == 1 })
    }
    pub fn remaining(&self) -> u64 { self.count }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InlineStyleKind { Strong, Emphasis, Strike, Syntax, Code, Link }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InlineStyle { pub kind: InlineStyleKind, pub start: InlinePoint, pub end: InlinePoint }
pub struct PreparedDelimiterMatch {
    pub opener: Option<OpenDelimiter>,
    pub consumed_closing: u64,
    /// At most two style unions plus the two actual syntax ranges. Nested
    /// repetitions have identical native traits and are unioned, not expanded
    /// into one resident item or on-disk annotation per delimiter character.
    pub styles: Vec<InlineStyle>,
}

/// Reduce one ACTUAL chosen opener/closer match. This does not search an
/// invented bounded stack, or claim that code/link/HTML precedence is done.
/// The selected pair must come from the producer's paged pinned-stack search.
pub fn prepare_delimiter_match(open: OpenDelimiter, closing: InlineToken, closing_run_length: u64, options: Options) -> Result<Option<PreparedDelimiterMatch>, InlineRunError> {
    let InlineToken::Delimiter { start, end, character, count, can_open, can_close } = closing else {
        return Err(InlineRunError::Invalid("closer requires a delimiter token"));
    };
    check_run(start, end, character, count)?;
    if closing_run_length < count { return Err(InlineRunError::Invalid("closer original run length")); }
    let open_end = moved(open.start, open.count)?;
    if open_end.bytes > start.bytes || open_end.utf16 > start.utf16 {
        return Err(InlineRunError::Invalid("opener/closer source order"));
    }
    if character == b'~' && (!options.contains(Options::ENABLE_STRIKETHROUGH) || closing_run_length > 2 || open.run_length > 2) {
        return Err(InlineRunError::Invalid("unsupported delimiter option"));
    }
    if !can_close || !eligible(character, closing_run_length, can_open && can_close, open.character, open.run_length, open.both) {
        return Ok(None);
    }
    let matched = open.count.min(count);
    let first = backed(open_end, matched)?;
    let last = moved(start, matched)?;
    let mut styles = Vec::with_capacity(4);
    if character == b'~' {
        styles.push(InlineStyle { kind: InlineStyleKind::Strike, start: first, end: last });
    } else {
        if matched >= 2 {
            let inset = matched % 2;
            styles.push(InlineStyle { kind: InlineStyleKind::Strong, start: moved(first, inset)?, end: backed(last, inset)? });
        }
        if matched % 2 != 0 {
            styles.push(InlineStyle { kind: InlineStyleKind::Emphasis, start: first, end: last });
        }
    }
    // The existing Core consumer uses "~~" syntax for a strike event; its
    // pinned one-tilde strike has no hidden syntax span. Preserve that exact
    // presentation behavior rather than adding a new formatting rule.
    if character != b'~' || matched >= 2 {
        styles.push(InlineStyle { kind: InlineStyleKind::Syntax, start: first, end: open_end });
        styles.push(InlineStyle { kind: InlineStyleKind::Syntax, start, end: last });
    }
    let remaining = open.count - matched;
    let opener = (remaining > 0).then_some(OpenDelimiter { count: remaining, ..open });
    Ok(Some(PreparedDelimiterMatch { opener, consumed_closing: matched, styles }))
}
