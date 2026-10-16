//! Bounded worker preparations over a frozen logical snapshot. These are
//! ordinary command continuations, not registered roots or another timeline.
use super::*;
use crate::bulk::GraphemeSeekState;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogicalTextEdit {
    pub start: u64,
    pub end: u64,
    pub old_text: String,
    pub new_text: String,
}
#[derive(Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum LogicalCommandRequest {
    Grapheme {
        at: u64,
        forward: bool,
    },
    Paragraph {
        at: u64,
        include_line_endings: bool,
    },
    Edits {
        edits: Vec<LogicalTextEdit>,
        selection: Option<LogicalSelection>,
    },
    Wrapping {
        selection: LogicalSelection,
        prefix: String,
        suffix: String,
        toggles: bool,
    },
    Imported {
        selection: LogicalSelection,
        revision: Revision,
    },
    LinePrefix {
        selection: LogicalSelection,
        prefix: String,
    },
}
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogicalSelection {
    pub start: u64,
    pub length: u64,
    pub focus_at_end: bool,
}
impl LogicalSelection {
    fn end(self, summary: TextSummary) -> Result<u64> {
        self.start
            .checked_add(self.length)
            .filter(|end| *end <= summary.utf16)
            .ok_or(Error::Invalid("logical command selection"))
    }
    fn focus(self, summary: TextSummary) -> Result<u64> {
        let end = self.end(summary)?;
        Ok(if self.focus_at_end { end } else { self.start })
    }
}
pub enum LogicalCommandResult {
    Point(TextSummary),
    Paragraph(ParagraphBounds),
    Edit {
        edit: LogicalEdit,
        selection: LogicalSelection,
    },
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogicalCommandProgress {
    pub complete: bool,
    pub buffered_bytes: usize,
    pub needs_writer: bool,
}
enum State {
    Grapheme(GraphemeSeekState),
    Paragraph(ParagraphState),
    Prefix(Box<LogicalPrefix>),
    Ready,
}
pub struct LogicalCommand {
    state: State,
    result: Option<LogicalCommandResult>,
}
impl LogicalCommand {
    pub fn requires_writes(&self) -> bool {
        matches!(&self.state, State::Prefix(state) if state.requires_writes())
    }
    pub fn new<S: PageProvider>(
        engine: &mut TextEngine<S>,
        source: LogicalSnapshot,
        request: LogicalCommandRequest,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Self> {
        check_cancel(cancelled)?;
        let state = match request {
            LogicalCommandRequest::Grapheme { at, forward } => {
                State::Grapheme(GraphemeSeekState::logical(engine, source, at, forward)?)
            }
            LogicalCommandRequest::Paragraph {
                at,
                include_line_endings,
            } => State::Paragraph(ParagraphState::logical(
                engine,
                source,
                at,
                include_line_endings,
            )?),
            LogicalCommandRequest::LinePrefix { selection, prefix } => State::Prefix(Box::new(
                LogicalPrefix::new(engine, source, selection, prefix)?,
            )),
            request => {
                return Ok(Self {
                    state: State::Ready,
                    result: Some(engine.prepare_logical_command(&source, request, cancelled)?),
                });
            }
        };
        Ok(Self {
            state,
            result: None,
        })
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LogicalCommandProgress> {
        check_cancel(cancelled)?;
        let buffered = match &mut self.state {
            State::Grapheme(state) => {
                let progress = state.step(engine)?;
                if let Some(point) = progress.result {
                    self.result = Some(LogicalCommandResult::Point(point));
                }
                progress.buffered_bytes
            }
            State::Paragraph(state) => {
                let progress = state.step(engine)?;
                if let Some(bounds) = progress.result {
                    self.result = Some(LogicalCommandResult::Paragraph(bounds));
                }
                progress.buffered_bytes
            }
            State::Prefix(state) => {
                state.step(engine, cancelled)?;
                if let Some(result) = state.ready.take() {
                    self.result = Some(result);
                }
                state.buffer.len() + state.piece.as_ref().map_or(0, |piece| piece.bytes.len())
            }
            State::Ready => 0,
        };
        check_cancel(cancelled)?;
        if self.result.is_some() {
            self.state = State::Ready;
        }
        Ok(LogicalCommandProgress {
            complete: self.result.is_some(),
            buffered_bytes: buffered,
            needs_writer: self.requires_writes(),
        })
    }
    pub fn finish(self) -> Result<LogicalCommandResult> {
        self.result
            .ok_or(Error::Invalid("logical command not joined"))
    }
}
impl<S: PageProvider> TextEngine<S> {
    fn command_edit(
        &mut self,
        mut candidate: LogicalSource,
        selection: LogicalSelection,
        changed: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LogicalCommandResult> {
        let snapshot = candidate.capture_for_publication()?;
        let start = self.logical_position(&snapshot, selection.start, false)?;
        let _end = self.logical_position(&snapshot, selection.end(snapshot.summary())?, false)?;
        let focus = selection.focus(snapshot.summary())?;
        let window = self.logical_window(&snapshot, focus, 16 * 1024, cancelled)?;
        Ok(LogicalCommandResult::Edit {
            edit: LogicalEdit {
                changed,
                window,
                cursor: start,
            },
            selection,
        })
    }
    fn prepare_logical_command(
        &mut self,
        source: &LogicalSnapshot,
        request: LogicalCommandRequest,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LogicalCommandResult> {
        let mut candidate = LogicalSource::preparing(source.clone());
        match request {
            LogicalCommandRequest::Edits { edits, selection } => {
                if edits.is_empty() || edits.len() > 32 {
                    return Err(Error::Invalid("logical explicit edit count"));
                }
                let mut prior = source.summary().bytes;
                let mut charge = 0_usize;
                let mut changed = false;
                let mut last_cursor = TextSummary::EMPTY;
                for edit in edits {
                    check_cancel(cancelled)?;
                    charge = charge
                        .checked_add(edit.old_text.len())
                        .and_then(|n| n.checked_add(edit.new_text.len()))
                        .filter(|n| *n <= WINDOW_BYTES)
                        .ok_or(Error::Invalid("logical explicit edit byte bound"))?;
                    if edit.start > edit.end
                        || edit.end > prior
                        || edit.end - edit.start != edit.old_text.len() as u64
                    {
                        return Err(Error::Invalid("logical explicit edit ranges"));
                    }
                    let old = self.logical_read_range(source, edit.start..edit.end, cancelled)?;
                    if old != edit.old_text.as_bytes() {
                        return Err(Error::Stale);
                    }
                    let snapshot = candidate.capture();
                    let start = self.logical_byte_position(&snapshot, edit.start)?;
                    let end = self.logical_byte_position(&snapshot, edit.end)?;
                    if edit.old_text != edit.new_text {
                        last_cursor = candidate
                            .replace_positions(&start, &end, &edit.new_text)?
                            .point();
                        changed = true;
                    }
                    let _frozen = candidate.capture_for_publication()?;
                    prior = edit.start;
                }
                self.command_edit(
                    candidate,
                    selection.unwrap_or(LogicalSelection {
                        start: last_cursor.utf16,
                        length: 0,
                        focus_at_end: false,
                    }),
                    changed,
                    cancelled,
                )
            }
            LogicalCommandRequest::Wrapping {
                selection,
                prefix,
                suffix,
                toggles,
            } => {
                if prefix.is_empty() || suffix.is_empty() || prefix.len() > 64 || suffix.len() > 64
                {
                    return Err(Error::Invalid("logical delimiter bound"));
                }
                let end = selection.end(source.summary())?;
                let start_point = self
                    .logical_position(source, selection.start, false)?
                    .point();
                let end_point = self.logical_position(source, end, false)?.point();
                let p = TextSummary::of(&prefix);
                let q = TextSummary::of(&suffix);
                let wrapped_inside = toggles
                    && end_point.bytes - start_point.bytes >= p.bytes + q.bytes
                    && self.logical_read_range(
                        source,
                        start_point.bytes..start_point.bytes + p.bytes,
                        cancelled,
                    )? == prefix.as_bytes()
                    && self.logical_read_range(
                        source,
                        end_point.bytes - q.bytes..end_point.bytes,
                        cancelled,
                    )? == suffix.as_bytes();
                let wrapped_outside = !wrapped_inside
                    && toggles
                    && start_point.bytes >= p.bytes
                    && source.summary().bytes - end_point.bytes >= q.bytes
                    && self.logical_read_range(
                        source,
                        start_point.bytes - p.bytes..start_point.bytes,
                        cancelled,
                    )? == prefix.as_bytes()
                    && self.logical_read_range(
                        source,
                        end_point.bytes..end_point.bytes + q.bytes,
                        cancelled,
                    )? == suffix.as_bytes();
                let (first, last, selected) = if wrapped_inside {
                    (
                        start_point.bytes,
                        end_point.bytes - q.bytes,
                        LogicalSelection {
                            start: selection.start,
                            length: selection
                                .length
                                .checked_sub(p.utf16 + q.utf16)
                                .ok_or(Error::Invalid("logical delimiter selection"))?,
                            ..selection
                        },
                    )
                } else if wrapped_outside {
                    (
                        start_point.bytes - p.bytes,
                        end_point.bytes,
                        LogicalSelection {
                            start: selection.start - p.utf16,
                            ..selection
                        },
                    )
                } else {
                    (
                        start_point.bytes,
                        end_point.bytes,
                        LogicalSelection {
                            start: selection
                                .start
                                .checked_add(p.utf16)
                                .ok_or(Error::Invalid("logical delimiter cursor"))?,
                            ..selection
                        },
                    )
                };
                let root = candidate.capture();
                let a = self.logical_byte_position(&root, last)?;
                let b = self.logical_byte_position(
                    &root,
                    if wrapped_inside || wrapped_outside {
                        last + q.bytes
                    } else {
                        last
                    },
                )?;
                candidate.replace_positions(
                    &a,
                    &b,
                    if wrapped_inside || wrapped_outside {
                        ""
                    } else {
                        &suffix
                    },
                )?;
                let _frozen = candidate.capture_for_publication()?;
                let root = candidate.capture();
                let a = self.logical_byte_position(&root, first)?;
                let b = self.logical_byte_position(
                    &root,
                    if wrapped_inside || wrapped_outside {
                        first + p.bytes
                    } else {
                        first
                    },
                )?;
                candidate.replace_positions(
                    &a,
                    &b,
                    if wrapped_inside || wrapped_outside {
                        ""
                    } else {
                        &prefix
                    },
                )?;
                self.command_edit(candidate, selected, true, cancelled)
            }
            LogicalCommandRequest::Imported {
                selection,
                revision,
            } => {
                revision.validate()?;
                if revision.owner_id != source.origin().owner_id
                    || revision.document_id != source.origin().document_id
                {
                    return Err(Error::Invalid("logical imported tree owner"));
                }
                self.open(revision.clone())?;
                let start = self.logical_position(source, selection.start, false)?;
                let end = self.logical_position(source, selection.end(source.summary())?, false)?;
                let changed = start.point() != end.point() || revision.summary().bytes != 0;
                let cursor = candidate.replace_file_positions(&start, &end, revision)?;
                self.command_edit(
                    candidate,
                    LogicalSelection {
                        start: cursor.point().utf16,
                        length: 0,
                        focus_at_end: false,
                    },
                    changed,
                    cancelled,
                )
            }
            _ => Err(Error::Invalid("logical command preparation kind")),
        }
    }
}

/// Inspect toggling on a captured source, then stream the transformed range
/// through the existing fixed import frontier. The installed logical result
/// has one file span, not two resident spans per line. No root is published.
struct LogicalPrefix {
    source: LogicalSnapshot,
    prefix: String,
    selection: LogicalSelection,
    phase: PrefixPhase,
    start: TextSummary,
    end: TextSummary,
    at: TextSummary,
    piece: Option<SourcePiece>,
    line_start: bool,
    after_cr: bool,
    matched: usize,
    removing: bool,
    added: TextSummary,
    removed: TextSummary,
    buffer: Vec<u8>,
    flush: bool,
    builder: prefix::Builder,
    built: Option<Revision>,
    ready: Option<LogicalCommandResult>,
}
enum PrefixPhase {
    Start(ParagraphState),
    End(ParagraphState),
    Inspect,
    Build,
    Finalize,
    Finish,
}
impl LogicalPrefix {
    fn new<S: PageProvider>(
        engine: &mut TextEngine<S>,
        source: LogicalSnapshot,
        selection: LogicalSelection,
        prefix: String,
    ) -> Result<Self> {
        selection.end(source.summary())?;
        if prefix.is_empty() || prefix.len() > 256 || prefix.chars().any(paragraph::separator) {
            return Err(Error::Invalid("logical line prefix bound"));
        }
        let bounds = ParagraphState::logical(engine, source.clone(), selection.start, true)?;
        Ok(Self {
            source,
            prefix,
            selection,
            phase: PrefixPhase::Start(bounds),
            start: TextSummary::EMPTY,
            end: TextSummary::EMPTY,
            at: TextSummary::EMPTY,
            piece: None,
            line_start: true,
            after_cr: false,
            matched: 0,
            removing: true,
            added: TextSummary::EMPTY,
            removed: TextSummary::EMPTY,
            buffer: Vec::with_capacity(TEXT_PAGE_BYTES),
            flush: false,
            builder: prefix::Builder::new(),
            built: None,
            ready: None,
        })
    }
    fn requires_writes(&self) -> bool {
        self.flush || matches!(self.phase, PrefixPhase::Finalize)
    }
    fn reset(&mut self) {
        self.at = self.start;
        self.piece = None;
        self.line_start = true;
        self.after_cr = false;
        self.matched = 0;
    }
    fn flush_page<S: PageProvider>(&mut self, engine: &mut TextEngine<S>) -> Result<()> {
        if self.buffer.is_empty() {
            self.flush = false;
            return Ok(());
        }
        let text = std::str::from_utf8(&self.buffer)
            .map_err(|_| Error::Invalid("logical prefix output UTF8"))?;
        let summary = TextSummary::of(text);
        let paragraphs = Some(ParagraphSummary::of(text));
        let page = engine.write_page(self.source.origin(), PageKind::Text, &self.buffer)?;
        self.builder.piece(
            engine,
            self.source.origin(),
            Piece {
                chunk: page,
                start: 0,
                end: u32::try_from(self.buffer.len())
                    .map_err(|_| Error::Invalid("logical prefix output extent"))?,
                summary,
                paragraphs,
            },
        )?;
        self.buffer.clear();
        self.flush = false;
        Ok(())
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        check_cancel(cancelled)?;
        if self.flush {
            return self.flush_page(engine);
        }
        match &mut self.phase {
            PrefixPhase::Start(state) => {
                if let Some(bounds) = state.step(engine)?.result {
                    self.start = bounds.start;
                    let end = self.selection.end(self.source.summary())?;
                    let mut at = if end > self.selection.start {
                        end - 1
                    } else {
                        end
                    };
                    let rounded = engine.logical_position(&self.source, at, true)?.point();
                    if rounded.utf16 > at {
                        at = at
                            .checked_sub(1)
                            .ok_or(Error::Invalid("logical prefix half scalar"))?;
                    }
                    self.phase = PrefixPhase::End(ParagraphState::logical(
                        engine,
                        self.source.clone(),
                        at,
                        true,
                    )?);
                }
                return Ok(());
            }
            PrefixPhase::End(state) => {
                if let Some(bounds) = state.step(engine)?.result {
                    self.end = bounds.end;
                    self.reset();
                    self.phase = PrefixPhase::Inspect;
                }
                return Ok(());
            }
            PrefixPhase::Finalize => {
                if let Some(root) = self.builder.finish_step(engine, self.source.origin())? {
                    let expected =
                        logical::difference(self.end, self.start)?.checked_add(self.added)?;
                    let expected = logical::difference(expected, self.removed)?;
                    let mut revision = self.source.origin().clone();
                    revision.root = root;
                    revision.validate()?;
                    if revision.summary() != expected || self.builder.summary != expected {
                        return Err(Error::Invalid("logical prefix final extent"));
                    }
                    self.built = Some(revision);
                    self.phase = PrefixPhase::Finish;
                }
                return Ok(());
            }
            PrefixPhase::Finish => {
                let revision = self
                    .built
                    .take()
                    .ok_or(Error::Invalid("logical prefix missing candidate"))?;
                let selected = LogicalSelection {
                    start: self.start.utf16,
                    length: revision.summary().utf16,
                    focus_at_end: self.selection.focus_at_end,
                };
                let mut candidate = LogicalSource::preparing(self.source.clone());
                candidate.replace_file_positions(
                    &LogicalPosition::at(self.source.clone(), self.start),
                    &LogicalPosition::at(self.source.clone(), self.end),
                    revision,
                )?;
                self.ready = Some(engine.command_edit(
                    candidate,
                    selected,
                    self.added.bytes != 0 || self.removed.bytes != 0,
                    cancelled,
                )?);
                return Ok(());
            }
            _ => {}
        }
        if self.at.bytes == self.end.bytes {
            if matches!(self.phase, PrefixPhase::Inspect) {
                if self.matched != 0 || self.start == self.end {
                    self.removing = false;
                }
                self.reset();
                self.phase = PrefixPhase::Build;
            } else {
                // A collapsed caret on an empty final paragraph prefixes it;
                // a selected range ending in a terminator adds no extra line.
                if self.start == self.end && self.line_start && self.selection.length == 0 {
                    self.buffer.extend_from_slice(self.prefix.as_bytes());
                    self.added = self.added.checked_add(TextSummary::of(&self.prefix))?;
                    self.line_start = false;
                }
                if self.buffer.is_empty() {
                    self.phase = PrefixPhase::Finalize;
                } else {
                    self.flush = true;
                }
            }
            return Ok(());
        }
        if self.piece.is_none() {
            self.piece = Some(engine.logical_source_piece(&self.source, self.at.bytes)?);
            return Ok(());
        }
        let inspecting = matches!(self.phase, PrefixPhase::Inspect);
        let piece = self
            .piece
            .take()
            .ok_or(Error::Invalid("logical prefix source piece"))?;
        let local = usize::try_from(self.at.bytes - piece.before.bytes)
            .map_err(|_| Error::Invalid("logical prefix piece cursor"))?;
        let text = piece
            .text()?
            .get(local..)
            .ok_or(Error::Invalid("logical prefix scalar start"))?;
        for ch in text.chars().take(4096) {
            check_cancel(cancelled)?;
            if self.at.bytes == self.end.bytes {
                break;
            }
            let mut encoded = [0_u8; 4];
            let bytes = ch.encode_utf8(&mut encoded).as_bytes();
            if self.after_cr {
                self.after_cr = false;
                if ch == '\n' {
                    if !inspecting {
                        if self.buffer.len() + bytes.len() > TEXT_PAGE_BYTES {
                            self.after_cr = true;
                            self.flush = true;
                            break;
                        }
                        self.buffer.extend_from_slice(bytes);
                    }
                    self.at = self.at.checked_add(paragraph::scalar(ch))?;
                    continue;
                }
            }
            if self.line_start {
                if inspecting || self.removing {
                    let next = self
                        .matched
                        .checked_add(bytes.len())
                        .ok_or(Error::Invalid("logical prefix match"))?;
                    if self.prefix.as_bytes().get(self.matched..next) != Some(bytes) {
                        if inspecting {
                            self.removing = false;
                            self.reset();
                            self.phase = PrefixPhase::Build;
                            return Ok(());
                        }
                        return Err(Error::Invalid("immutable logical prefix changed"));
                    }
                    self.matched = next;
                    self.at = self.at.checked_add(paragraph::scalar(ch))?;
                    if self.matched == self.prefix.len() {
                        if !inspecting {
                            self.removed =
                                self.removed.checked_add(TextSummary::of(&self.prefix))?;
                        }
                        self.line_start = false;
                        self.matched = 0;
                    }
                    continue;
                }
                if self.buffer.len() + self.prefix.len() > TEXT_PAGE_BYTES {
                    self.flush = true;
                    break;
                }
                self.buffer.extend_from_slice(self.prefix.as_bytes());
                self.added = self.added.checked_add(TextSummary::of(&self.prefix))?;
                self.line_start = false;
            }
            if !inspecting {
                if self.buffer.len() + bytes.len() > TEXT_PAGE_BYTES {
                    self.flush = true;
                    break;
                }
                self.buffer.extend_from_slice(bytes);
            }
            self.at = self.at.checked_add(paragraph::scalar(ch))?;
            if paragraph::separator(ch) {
                self.line_start = true;
                self.after_cr = ch == '\r';
            }
        }
        let end = piece
            .before
            .bytes
            .checked_add(piece.text()?.len() as u64)
            .ok_or(Error::Invalid("logical prefix piece extent"))?;
        if self.at.bytes < end && self.at.bytes < self.end.bytes {
            self.piece = Some(piece);
        }
        Ok(())
    }
}
