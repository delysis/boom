//! Actual source-bound angle recognition. A failed lookahead rewinds only this
//! derived reader, never the logical editor/root. The paragraph limit comes
//! from the same pinned first-pass follower, not an arbitrary page EOF.
use super::*;
use pulldown_cmark::paged::{AngleGuard, AngleKind, AngleStatus, AngleStream};

pub(super) struct PendingAngle {
    pub resume: TextSummary,
    pub start: InlinePoint,
    pub resume_references: u64,
    pub resume_pipe: bool,
    pub scanner: AngleStream,
}
impl PendingAngle {
    pub fn new(
        stream: &InlineRunStream,
        resume: TextSummary,
        guard: AngleGuard,
        resume_references: u64,
        resume_pipe: bool,
    ) -> Result<Self> {
        let start = stream.angle_start().map_err(inline_error)?;
        if start.bytes != resume.bytes || start.utf16 != resume.utf16 {
            return Err(Error::Invalid("markup angle captured source counters"));
        }
        Ok(Self {
            resume,
            start,
            resume_references,
            resume_pipe,
            scanner: AngleStream::new(start.bytes, guard),
        })
    }
}
impl LongParagraph {
    pub(super) fn step_angle<S: PageProvider>(
        &mut self,
        pending: &mut PendingAngle,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<bool> {
        let limit = self
            .code_limit
            .ok_or(Error::Invalid("markup angle actual paragraph limit"))?;
        if self.summary.bytes > limit.bytes {
            return Err(Error::Invalid("markup angle past paragraph"));
        }
        if self.buffer.is_empty() && self.summary.bytes < limit.bytes {
            if !self.read_more(engine, snapshot)? {
                return Err(Error::Invalid("markup angle source ended before paragraph"));
            }
            return Ok(false);
        }
        let count =
            usize::try_from((limit.bytes - self.summary.bytes).min(self.buffer.len() as u64))
                .map_err(|_| Error::Invalid("markup angle input address space"))?;
        let input = self
            .buffer
            .get(..count)
            .ok_or(Error::Invalid("markup angle scalar input extent"))?;
        let block_end = self.summary.bytes.checked_add(count as u64) == Some(limit.bytes);
        let result = pending
            .scanner
            .feed(input, block_end, cancelled)
            .map_err(inline_error)?;
        self.consume(result.consumed)?;
        match result.status {
            AngleStatus::Pending => Ok(false),
            AngleStatus::Rejected => {
                self.angle_guard = pending.scanner.guard();
                self.stream
                    .resume_angle(pending.start, None)
                    .map_err(inline_error)?;
                self.summary = pending.resume.checked_add(TextSummary::of("<"))?;
                self.reference_slots = pending.resume_references;
                self.has_pipe = pending.resume_pipe;
                self.buffer.clear();
                Ok(true)
            }
            AngleStatus::Matched(kind) => {
                let end = InlinePoint {
                    bytes: self.summary.bytes,
                    utf16: self.summary.utf16,
                };
                self.angle_guard = pending.scanner.guard();
                self.stream
                    .resume_angle(pending.start, Some(end))
                    .map_err(inline_error)?;
                if mode == MarkupMode::Style && kind != AngleKind::Html {
                    self.styles.append(vec![InlineStyle {
                        kind: InlineStyleKind::Link,
                        start: pending.start,
                        end,
                    }])?;
                }
                if mode == MarkupMode::Media
                    && let Some(raw) = pending.scanner.attachment_candidate()
                    && let Ok(uri) = std::str::from_utf8(raw)
                    && let Some(value) = uri.strip_prefix("boom-attachment:")
                    && value.len() == 36
                    && let Ok(id) = Uuid::parse_str(value)
                {
                    self.styles.append_media(id, pending.start, end)?;
                }
                Ok(true)
            }
        }
    }
}
