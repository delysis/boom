//! Actual completed inline subtrees reuse the pinned LinkStack and the SAME
//! source-bound reference query. Pending labels are not absence proofs.
use super::*;
use pulldown_cmark::paged::{InlineLinkFragment, probe_inline_link, probe_inline_link_with_definitions};

pub(super) struct PendingLink {
    start: InlinePoint,
    image: bool,
    quantum: usize,
    lookup: Option<MarkupQuery>,
    checked: Option<(usize, Option<InlineLinkFragment>)>,
}
impl PendingLink {
    pub(super) fn buffered_bytes(&self) -> usize {
        self.lookup.as_ref().map_or(0, MarkupQuery::copied_source_bytes)
    }
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
            // Rewind this derived reader only; no source/Undo mutation.
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
            lookup: None,
            checked: None,
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
        if let Some(lookup) = &mut pending.lookup {
            if !lookup.step(engine, cancelled)?.complete { return Ok(false); }
            let mut context = pending.lookup.take().ok_or(Error::Invalid("markup inline lookup missing"))?.finish()?;
            if !context.reference_budget_proven { self.unsupported = true; return Ok(true); }
            let fragment = context.fragments.first().ok_or(Error::Invalid("markup inline lookup operand missing"))?;
            let found = probe_inline_link_with_definitions(&fragment.text, mode.options(),
                context.definitions_for(fragment)?, true, None, cancelled).map_err(inline_error)?;
            if context.fragments.len() != 1 { return Err(Error::Invalid("markup inline lookup operand shape")); }
            self.buffer = context.fragments.pop().ok_or(Error::Invalid("markup inline lookup operand lost"))?.text;
            pending.checked = Some((self.buffer.len(), found));
            return Ok(false);
        }
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
        let found = match pending.checked {
            Some((checked, found)) if checked == count => found,
            _ => {
                let independent = probe_inline_link(&self.buffer[..count], mode.options(), cancelled).map_err(inline_error)?;
                if independent.is_none() && let Some(index) = &self.reference_index {
                    // Move the only copied source operand into the existing
                    // query. Drop unused tail; immutable pages can reread it.
                    self.buffer.truncate(count);
                    let start = self.start.checked_add(self.summary)?;
                    pending.lookup = Some(MarkupQuery::inline_operand(snapshot, Arc::clone(index), start,
                        std::mem::take(&mut self.buffer))?);
                    return Ok(false);
                }
                independent
            }
        };
        if let Some(found) = found {
            if found.is_image() != pending.image {
                return Err(Error::Invalid("markup inline opener changed kind"));
            }
            self.consume(found.end())?;
            let end = InlinePoint {
                bytes: self.summary.bytes,
                utf16: self.summary.utf16,
            };
            self.stream
                .resume_bracket_with_ending(pending.start, end, found.ending())
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
            pending.checked = None;
            return Ok(false);
        }
        if self.reference_index.is_none() && self.may_defer() {
            // The real scope survey already proved where this paragraph
            // ends and excluded a reference definition or possible table.
            // A raw pipe conservatively withholds this new deferred route
            // until the actual paged table grammar is available.
            // Continue global block indexing, then return under that SAME
            // captured source after first-definition lookup is possible.
            self.defer_requested = true;
        } else {
            self.unsupported = true;
        }
        Ok(true)
    }
}
