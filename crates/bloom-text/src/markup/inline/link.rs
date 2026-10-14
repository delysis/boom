//! Completed bounded inline subtrees use the pinned tokenizer, LinkStack and
//! child emphasis parser. Their source intervals share existing derived pages;
//! there is no duplicate link grammar, retained URL or new source authority.
use super::*;
use pulldown_cmark::paged::probe_inline_link;

pub(super) struct PendingLink {
    start: InlinePoint,
    image: bool,
    quantum: usize,
}
impl LongParagraph {
    pub(super) fn begin_link(&mut self) -> Result<()> {
        let (start, image) = self.stream.bracket_start().map_err(inline_error)?;
        if image {
            if self.summary.bytes.checked_sub(1) != Some(start.bytes)
                || self.summary.utf16.checked_sub(1) != Some(start.utf16)
            {
                return Err(Error::Invalid("markup actual image source origin"));
            }
            // The token walk already consumed the literal ! before seeing
            // [. Rewind this derived reader only, retaining exact LF count.
            self.summary.bytes -= 1;
            self.summary.utf16 -= 1;
            self.buffer.clear();
        } else if self.summary.bytes != start.bytes || self.summary.utf16 != start.utf16 {
            return Err(Error::Invalid("markup actual link source origin"));
        }
        self.link_pending = Some(PendingLink {
            start,
            image,
            quantum: 16,
        });
        Ok(())
    }
    pub(super) fn step_link<S: PageProvider>(
        &mut self,
        pending: &mut PendingLink,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<bool> {
        let limit = self
            .code_limit
            .ok_or(Error::Invalid("markup link actual paragraph limit"))?;
        let remaining = limit
            .bytes
            .checked_sub(self.summary.bytes)
            .ok_or(Error::Invalid("markup link beyond paragraph"))?;
        let target = usize::try_from(remaining.min(pending.quantum as u64))
            .map_err(|_| Error::Invalid("markup link probe address space"))?;
        if self.buffer.len() < target {
            if !self.read_more(engine, snapshot)? {
                return Err(Error::Invalid(
                    "markup link source ended before proved scope",
                ));
            }
            return Ok(false);
        }
        let mut count = target;
        while !self.buffer.is_char_boundary(count) {
            count -= 1;
        }
        let input = &self.buffer[..count];
        if let Some(found) =
            probe_inline_link(input, mode.options(), cancelled).map_err(inline_error)?
        {
            if found.is_image() != pending.image {
                return Err(Error::Invalid("markup inline opener changed kind"));
            }
            self.consume(found.end())?;
            let end = InlinePoint {
                bytes: self.summary.bytes,
                utf16: self.summary.utf16,
            };
            self.stream
                .resume_bracket(pending.start, end)
                .map_err(inline_error)?;
            self.styles.append_fragment(pending.start, end)?;
            return Ok(true);
        }
        if (count as u64) < remaining && pending.quantum < PROBE_BYTES {
            pending.quantum = pending
                .quantum
                .checked_mul(2)
                .filter(|value| *value <= PROBE_BYTES)
                .ok_or(Error::Invalid("markup link probe quantum"))?;
            return Ok(false);
        }
        // Unknown reference/global/code dependencies, invalid outer link
        // nesting and larger subtrees remain literal, never false completed
        // source. The continued general bracket pass can replace this refusal.
        self.unsupported = true;
        Ok(true)
    }
}
