//! Second phase of the SAME captured markup builder. Real block coverage
//! supplies the existing definition index before dependent paragraph output
//! can complete. The frontier contains tree paths, never one row per line.
use super::*;

pub(super) enum PassProgress { Working, Complete, Incomplete }
pub(super) struct ReferencePass {
    definitions: Arc<MarkupIndex>,
    stack: Vec<(MarkRef, TextSummary)>,
    segments: VecDeque<(TextSummary, Segment)>,
    current: Option<(TextSummary, Segment)>,
    buffer: String,
    paragraph: Option<LongParagraph>,
}
impl ReferencePass {
    pub fn new(definitions: Arc<MarkupIndex>) -> Self {
        let stack = definitions.root.as_ref().map_or_else(Vec::new,
            |root| vec![(root.clone(), TextSummary::EMPTY)]);
        Self { definitions, stack, segments: VecDeque::new(), current: None,
            buffer: String::new(), paragraph: None }
    }
    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len() + self.paragraph.as_ref().map_or(0, LongParagraph::buffered_bytes)
    }
    pub fn step<S: PageProvider>(&mut self, engine: &mut TextEngine<S>, snapshot: &LogicalSnapshot,
        destination: &mut Option<MarkRef>, cancelled: &mut impl FnMut() -> bool,
    ) -> Result<PassProgress> {
        check_cancel(cancelled)?;
        if snapshot.id() != self.definitions.source.id || !self.definitions.definitions_complete {
            return Err(Error::Stale);
        }
        let mode = self.definitions.mode;
        if let Some(paragraph) = &mut self.paragraph {
            paragraph.step(engine, snapshot, mode, cancelled)?;
            if paragraph.unsupported() { return Ok(PassProgress::Incomplete); }
            if !paragraph.complete() { return Ok(PassProgress::Working); }
            let (summary, inline, _, reference_slots) = self.paragraph.take()
                .ok_or(Error::Invalid("markup reference paragraph lost"))?.finish()?;
            let (before, original) = self.current.take().ok_or(Error::Invalid("markup reference source lost"))?;
            if summary != original.summary || reference_slots != original.reference_slots {
                return Err(Error::Invalid("markup reference pass changed actual paragraph scope/count"));
            }
            let root = destination.take().ok_or(Error::Invalid("markup reference output root missing"))?;
            let (left, right) = engine.mark_split(snapshot, mode, root, before.bytes, 0, SplitMapping { old_base: 0, new_base: 0, keep_prefix: true })?;
            let (old, tail) = engine.mark_split(snapshot, mode,
                right.ok_or(Error::Invalid("markup reference source suffix missing"))?, summary.bytes,
                before.bytes, SplitMapping { old_base: 0, new_base: 0, keep_prefix: false })?;
            if old.as_ref().is_none_or(|root| root.summary != summary || root.pending_inline != 1) {
                return Err(Error::Invalid("markup reference replacement is not one complete pending paragraph"));
            }
            let value = engine.mark_leaf(snapshot.origin(), mode, vec![Segment {
                summary, incoming: Carry::Root, outgoing: Carry::Root, parsed: false, reference_slots,
                code: None, inline: Some(inline), pending_inline: false, dependent_inline: true,
                definitions: None, definition_base: 0, boundaries: Vec::new(), boundary_base: 0, boundary_extent: 0,
            }])?;
            let value = engine.mark_join(snapshot.origin(), mode, left, value)?;
            *destination = engine.mark_join(snapshot.origin(), mode, value, tail)?;
            check_cancel(cancelled)?;
            return Ok(PassProgress::Working);
        }
        if let Some((before, _)) = &self.current {
            if self.buffer.len() >= PROBE_BYTES - 3 {
                let seed = pulldown_cmark::paged::OpenParagraph::from_root_checkpoint(mode.options());
                let mut paragraph = LongParagraph::new(&seed, *before,
                    std::mem::take(&mut self.buffer), snapshot.summary(), mode)?;
                paragraph.resolve_references(Arc::clone(&self.definitions))?;
                self.paragraph = Some(paragraph);
                return Ok(PassProgress::Working);
            }
            let at = before.bytes.checked_add(self.buffer.len() as u64).ok_or(Error::Invalid("markup reference paragraph read cursor"))?;
            if at >= snapshot.summary().bytes { return Err(Error::Invalid("markup reference paragraph seed incomplete")); }
            let piece = engine.logical_source_piece(snapshot, at)?;
            let text = piece.text()?;
            let first = usize::try_from(at.checked_sub(piece.before.bytes).ok_or(Error::Invalid("markup reference piece origin"))?)
                .map_err(|_| Error::Invalid("markup reference piece address space"))?;
            let mut end = first.checked_add(PROBE_BYTES - self.buffer.len()).ok_or(Error::Invalid("markup reference piece extent"))?.min(text.len());
            while !text.is_char_boundary(end) { end -= 1; }
            if end <= first { return Err(Error::Invalid("markup reference empty piece")); }
            self.buffer.push_str(&text[first..end]);
            return Ok(PassProgress::Working);
        }
        if let Some((before, segment)) = self.segments.pop_front() {
            segment.validate()?;
            if !segment.pending_inline { return Err(Error::Invalid("markup reference nonpending source")); }
            self.current = Some((before, segment));
            return Ok(PassProgress::Working);
        }
        let Some((root, before)) = self.stack.pop() else {
            if destination.as_ref().is_some_and(|root| root.pending_inline != 0) {
                return Err(Error::Invalid("markup reference traversal missed a pending paragraph"));
            }
            return Ok(PassProgress::Complete);
        };
        if root.pending_inline == 0 { return Ok(PassProgress::Working); }
        match engine.mark_node(snapshot.origin(), mode, &root)? {
            MarkNode::Branch(values) => {
                let mut at = before;
                let mut children = Vec::with_capacity(MARK_FANOUT);
                for value in values {
                    let end = at.checked_add(value.summary)?;
                    if value.pending_inline != 0 { children.push((value, at)); }
                    at = end;
                }
                self.stack.extend(children.into_iter().rev());
                if self.stack.len() > usize::from(MARK_HEIGHT + 1) * MARK_FANOUT {
                    return Err(Error::Invalid("markup reference traversal frontier bound"));
                }
            }
            MarkNode::Segments(values) => {
                let mut at = before;
                for segment in values {
                    let end = at.checked_add(segment.summary)?;
                    if segment.pending_inline { self.segments.push_back((at, segment)); }
                    at = end;
                }
            }
            _ => return Err(Error::Invalid("markup reference traversal page kind")),
        }
        Ok(PassProgress::Working)
    }
}
