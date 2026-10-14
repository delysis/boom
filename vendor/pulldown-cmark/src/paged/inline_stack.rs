//! Stepped execution of the pinned emphasis stack. The host stores the actual
//! opener sequence in its existing derived pages. A step tests at most one
//! opener and emits at most four union annotations; it never owns paragraph
//! text, an unbounded token stack, or a source publication capability.
//! Locally authored extension, distributed under pulldown-cmark's MIT license.
use super::{InlineRunError, InlineStyle, InlineToken, OpenDelimiter, prepare_delimiter_match};
use crate::Options;

/// A pending read yields after one bounded host page load. Truncate follows
/// only an actual successful read of that same index, so a host can retain one
/// page cursor rather than rereading the whole opener chain on every token.
pub trait DelimiterStack {
    type Error: From<InlineRunError>;
    fn len(&self) -> u64;
    fn is_empty(&self) -> bool { self.len() == 0 }
    fn read(&mut self, index: u64) -> Result<Option<OpenDelimiter>, Self::Error>;
    fn truncate(&mut self, len: u64) -> Result<(), Self::Error>;
    fn push(&mut self, value: OpenDelimiter) -> Result<(), Self::Error>;
}

pub struct ReduceProgress {
    pub complete: bool,
    pub styles: Vec<InlineStyle>,
}
#[derive(Clone, Copy)]
struct Closing {
    token: InlineToken,
    original_run: u64,
    before: u64,
    lower: u64,
}

/// Lower-bound classes and truncation exactly mirror InlineStack. They skip
/// only previously failed searches under the pinned rule-of-three predicate.
/// No cap silently removes an otherwise eligible opener.
pub struct DelimiterReducer {
    options: Options,
    lower: [u64; 9],
    closing: Option<Closing>,
}
impl DelimiterReducer {
    pub fn new(options: Options) -> Self { Self { options, lower: [0; 9], closing: None } }
    pub fn is_idle(&self) -> bool { self.closing.is_none() }
    fn lower_bound(&self, character: u8, run: u64, both: bool) -> u64 {
        let modulo = (run % 3) as usize;
        match character {
            b'_' => if both { self.lower[6 + modulo] } else { self.lower[6 + modulo].min(self.lower[0]) },
            b'*' => if both { self.lower[2 + modulo] } else { self.lower[2 + modulo].min(self.lower[1]) },
            _ => self.lower[5],
        }
    }
    fn failed(&mut self, character: u8, run: u64, both: bool, len: u64) {
        let modulo = (run % 3) as usize;
        match character {
            b'_' => if both { self.lower[6 + modulo] = len; } else { self.lower[0] = len; },
            b'*' => { self.lower[2 + modulo] = len; if !both { self.lower[1] = len; } },
            _ => self.lower[5] = len,
        }
    }
    fn push<S: DelimiterStack>(&mut self, stack: &mut S, value: OpenDelimiter) -> Result<(), S::Error> {
        if value.character == b'~' { self.lower[5] = self.lower[5].min(stack.len()); }
        stack.push(value)
    }
    pub fn begin(&mut self, token: InlineToken, stack_len: u64) -> Result<(), InlineRunError> {
        if self.closing.is_some() { return Err(InlineRunError::Invalid("delimiter reduction already pending")); }
        let InlineToken::Delimiter { start, end, character, count, can_open, can_close } = token else { return Ok(()); };
        super::emphasis::check_run(start, end, character, count)?;
        if !can_open && !can_close { return Err(InlineRunError::Invalid("inactive delimiter token")); }
        self.closing = Some(Closing { token, original_run: count, before: stack_len,
            lower: self.lower_bound(character, count, can_open && can_close).min(stack_len) });
        Ok(())
    }
    pub fn step<S: DelimiterStack>(&mut self, stack: &mut S) -> Result<ReduceProgress, S::Error> {
        let Some(mut closing) = self.closing else {
            return Ok(ReduceProgress { complete: true, styles: Vec::new() });
        };
        let InlineToken::Delimiter { mut start, end, character, mut count, can_open, can_close } = closing.token else {
            return Err(InlineRunError::Invalid("pending delimiter token").into());
        };
        if closing.before > stack.len() || closing.lower > closing.before {
            return Err(InlineRunError::Invalid("delimiter search bounds").into());
        }
        if can_close && closing.before > closing.lower {
            let index = closing.before - 1;
            let Some(open) = stack.read(index)? else {
                return Ok(ReduceProgress { complete: false, styles: Vec::new() });
            };
            if let Some(matched) = prepare_delimiter_match(open, closing.token, closing.original_run, self.options)? {
                // The pinned stack discards every unmatched opener above the
                // actual chosen pair. Their source remains ordinary text.
                stack.truncate(index)?;
                for bound in &mut self.lower { *bound = (*bound).min(index); }
                if let Some(open) = matched.opener { self.push(stack, open)?; }
                count = count.checked_sub(matched.consumed_closing).ok_or(InlineRunError::Invalid("delimiter closing remainder"))?;
                start.bytes = start.bytes.checked_add(matched.consumed_closing).ok_or(InlineRunError::Invalid("delimiter closing byte"))?;
                start.utf16 = start.utf16.checked_add(matched.consumed_closing).ok_or(InlineRunError::Invalid("delimiter closing UTF16"))?;
                if count == 0 { self.closing = None; }
                else {
                    closing.token = InlineToken::Delimiter { start, end, character, count, can_open, can_close };
                    closing.before = stack.len();
                    closing.lower = self.lower_bound(character, closing.original_run, can_open && can_close).min(stack.len());
                    self.closing = Some(closing);
                }
                return Ok(ReduceProgress { complete: self.closing.is_none(), styles: matched.styles });
            }
            closing.before = index; self.closing = Some(closing);
            return Ok(ReduceProgress { complete: false, styles: Vec::new() });
        }
        if can_close { self.failed(character, closing.original_run, can_open && can_close, stack.len()); }
        if can_open {
            self.push(stack, OpenDelimiter { start, count, run_length: closing.original_run, character, both: can_open && can_close })?;
        }
        self.closing = None;
        Ok(ReduceProgress { complete: true, styles: Vec::new() })
    }
}
