//! Cooperative whole-file work. No stream, callback, pointer or host context is
//! retained between calls. Two fixed-size sessions share the ordinary page cache.
use super::*;
use std::io;
use unicode_segmentation::{GraphemeCursor, GraphemeIncomplete};

pub const BULK_OPERATION_COUNT: usize = 2;
/// Decode/advance/copy work has its own bound: a file made of tiny pieces must
/// yield even when it has not filled its 64 KiB output buffer.
pub const BULK_STEP_WORK: usize = 64;

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BulkProgress {
    pub processed_bytes: u64,
    pub validated_bytes: u64,
    pub complete: bool,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GraphemeSeekProgress {
    pub complete: bool,
    pub result: Option<TextSummary>,
    /// Retained backing page bytes, including unused bytes of a split piece.
    pub buffered_bytes: usize,
    pub examined_bytes: u64,
}

pub(super) struct Registry {
    slots: [Option<Job>; BULK_OPERATION_COUNT],
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            slots: std::array::from_fn(|_| None),
        }
    }
}
struct Job {
    id: Uuid,
    owner: Uuid,
    document: Uuid,
    state: State,
}
enum State {
    Import(Box<ImportState>),
    Stream(Box<StreamState>),
    Grapheme(Box<GraphemeSeekState>),
    Paragraph(Box<ParagraphState>),
    LinePrefix(Box<LinePrefixState>),
}
impl Registry {
    fn available(&self) -> Result<usize> {
        self.slots
            .iter()
            .position(Option::is_none)
            .ok_or(Error::Invalid("bulk operation budget"))
    }
    fn insert(&mut self, owner: Uuid, document: Uuid, state: State) -> Result<Uuid> {
        let slot = self.available()?;
        let mut id = Uuid::new_v4();
        while self.slots.iter().flatten().any(|job| job.id == id) {
            id = Uuid::new_v4();
        }
        self.slots[slot] = Some(Job {
            id,
            owner,
            document,
            state,
        });
        Ok(id)
    }
    fn index(&self, owner: Uuid, document: Uuid, id: Uuid) -> Result<usize> {
        let slot = self
            .slots
            .iter()
            .position(|job| job.as_ref().is_some_and(|job| job.id == id))
            .ok_or(Error::Stale)?;
        let job = self.slots[slot].as_ref().ok_or(Error::Stale)?;
        if job.owner != owner || job.document != document {
            return Err(Error::Invalid("bulk operation owner"));
        }
        Ok(slot)
    }
    fn take_import(&mut self, owner: Uuid, document: Uuid, id: Uuid) -> Result<(usize, Job)> {
        let slot = self.index(owner, document, id)?;
        if !matches!(
            self.slots[slot].as_ref().map(|job| &job.state),
            Some(State::Import(_))
        ) {
            return Err(Error::Invalid("bulk operation kind"));
        }
        Ok((slot, self.slots[slot].take().ok_or(Error::Stale)?))
    }
    fn take_stream(&mut self, revision: &Revision, id: Uuid) -> Result<(usize, Job)> {
        let slot = self.index(revision.owner_id, revision.document_id, id)?;
        match self.slots[slot].as_ref().map(|job| &job.state) {
            Some(State::Stream(state)) if state.revision == *revision => {}
            Some(State::Stream(_)) => return Err(Error::Stale),
            _ => return Err(Error::Invalid("bulk operation kind")),
        }
        Ok((slot, self.slots[slot].take().ok_or(Error::Stale)?))
    }
    fn take_grapheme(&mut self, revision: &Revision, id: Uuid) -> Result<(usize, Job)> {
        let slot = self.index(revision.owner_id, revision.document_id, id)?;
        match self.slots[slot].as_ref().map(|job| &job.state) {
            Some(State::Grapheme(state)) if state.revision == *revision => {}
            Some(State::Grapheme(_)) => return Err(Error::Stale),
            _ => return Err(Error::Invalid("bulk operation kind")),
        }
        Ok((slot, self.slots[slot].take().ok_or(Error::Stale)?))
    }
    fn restore(&mut self, slot: usize, job: Job) -> Result<()> {
        if self.slots[slot].is_some() {
            return Err(Error::Invalid("bulk operation slot changed"));
        }
        self.slots[slot] = Some(job);
        Ok(())
    }
    fn take_paragraph(&mut self, revision: &Revision, id: Uuid) -> Result<(usize, Job)> {
        let slot = self.index(revision.owner_id, revision.document_id, id)?;
        match self.slots[slot].as_ref().map(|job| &job.state) {
            Some(State::Paragraph(state)) if state.revision == *revision => {}
            Some(State::Paragraph(_)) => return Err(Error::Stale),
            _ => return Err(Error::Invalid("bulk operation kind")),
        }
        Ok((slot, self.slots[slot].take().ok_or(Error::Stale)?))
    }
    fn take_prefix(&mut self, revision: &Revision, id: Uuid) -> Result<(usize, Job)> {
        let slot = self.index(revision.owner_id, revision.document_id, id)?;
        match self.slots[slot].as_ref().map(|job| &job.state) {
            Some(State::LinePrefix(state)) if state.revision == *revision => {}
            Some(State::LinePrefix(_)) => return Err(Error::Stale),
            _ => return Err(Error::Invalid("bulk operation kind")),
        }
        Ok((slot, self.slots[slot].take().ok_or(Error::Stale)?))
    }
}

#[derive(Clone, Copy)]
enum GraphemeFetch {
    Piece(u64),
    Context(usize),
}
struct GraphemeSeekState {
    revision: Revision,
    cursor: GraphemeCursor,
    forward: bool,
    piece: Option<SourcePiece>,
    fetch: Option<GraphemeFetch>,
    ready: Option<TextSummary>,
    examined: u64,
}
impl GraphemeSeekState {
    fn progress(&self) -> GraphemeSeekProgress {
        GraphemeSeekProgress {
            complete: self.ready.is_some(),
            result: self.ready,
            buffered_bytes: self.piece.as_ref().map_or(0, |piece| piece.bytes.len()),
            examined_bytes: self.examined,
        }
    }
    /// One piece/context fetch OR one cursor advance per call. A long cluster
    /// returns to the actual host/engine lane rather than yielding while locked.
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
    ) -> Result<GraphemeSeekProgress> {
        if self.ready.is_some() {
            return Ok(self.progress());
        }
        if let Some(fetch) = self.fetch.take() {
            // Drop the prior backing page before fetching context or a next
            // piece. The cursor only retains its small algorithm state. After
            // context admission, reload the original piece on a later step.
            let resume_at = match fetch {
                GraphemeFetch::Context(_) => Some(
                    self.piece
                        .take()
                        .ok_or(Error::Invalid("grapheme context lost its piece"))?
                        .before
                        .bytes,
                ),
                GraphemeFetch::Piece(_) => {
                    self.piece = None;
                    None
                }
            };
            let at = match fetch {
                GraphemeFetch::Piece(at) => at,
                GraphemeFetch::Context(end) => u64::try_from(
                    end.checked_sub(1)
                        .ok_or(Error::Invalid("grapheme context at start"))?,
                )
                .map_err(|_| Error::Invalid("grapheme context exceeds u64"))?,
            };
            let piece = engine.source_piece(&self.revision, at)?;
            self.examined = self
                .examined
                .checked_add(
                    u64::try_from(piece.text()?.len())
                        .map_err(|_| Error::Invalid("grapheme piece exceeds u64"))?,
                )
                .ok_or(Error::Invalid("grapheme examined bytes overflow"))?;
            match fetch {
                GraphemeFetch::Piece(_) => self.piece = Some(piece),
                GraphemeFetch::Context(end) => {
                    let start = usize::try_from(piece.before.bytes)
                        .map_err(|_| Error::Invalid("grapheme context exceeds usize"))?;
                    let count = end
                        .checked_sub(start)
                        .ok_or(Error::Invalid("grapheme context range"))?;
                    let context = piece
                        .text()?
                        .get(..count)
                        .ok_or(Error::Invalid("grapheme context UTF8 extent"))?;
                    self.cursor.provide_context(context, start);
                    self.fetch = Some(GraphemeFetch::Piece(
                        resume_at.ok_or(Error::Invalid("grapheme context lost its origin"))?,
                    ));
                }
            }
            return Ok(self.progress());
        }
        let piece = self
            .piece
            .as_ref()
            .ok_or(Error::Invalid("grapheme seek lost its piece"))?;
        let start = usize::try_from(piece.before.bytes)
            .map_err(|_| Error::Invalid("grapheme start exceeds usize"))?;
        let query = if self.forward {
            self.cursor.next_boundary(piece.text()?, start)
        } else {
            self.cursor.prev_boundary(piece.text()?, start)
        };
        match query {
            Ok(Some(at)) => {
                self.ready = Some(piece.position(
                    u64::try_from(at).map_err(|_| Error::Invalid("grapheme result exceeds u64"))?,
                )?)
            }
            Ok(None) => {
                self.ready = Some(if self.forward {
                    self.revision.summary()
                } else {
                    TextSummary::EMPTY
                })
            }
            Err(GraphemeIncomplete::PreContext(end)) => {
                self.fetch = Some(GraphemeFetch::Context(end))
            }
            Err(GraphemeIncomplete::NextChunk) => {
                self.fetch = Some(GraphemeFetch::Piece(
                    u64::try_from(self.cursor.cur_cursor())
                        .map_err(|_| Error::Invalid("grapheme next chunk exceeds u64"))?,
                ))
            }
            Err(GraphemeIncomplete::PrevChunk) => {
                self.fetch = Some(GraphemeFetch::Piece(
                    piece
                        .before
                        .bytes
                        .checked_sub(1)
                        .ok_or(Error::Invalid("grapheme previous chunk before start"))?,
                ))
            }
            Err(GraphemeIncomplete::InvalidOffset) => {
                return Err(Error::Invalid("grapheme chunk does not cover cursor"));
            }
        }
        Ok(self.progress())
    }
}

#[derive(Clone, Copy)]
enum ImportPhase {
    Reading,
    Pieces,
    Levels(usize),
    Ready,
}
struct ImportState {
    revision: Revision,
    expected_bytes: u64,
    processed: u64,
    validated: u64,
    buffer: Vec<u8>,
    used: usize,
    valid_in_page: usize,
    page_summary: TextSummary,
    pieces: Vec<Piece>,
    levels: Vec<Vec<TreeRef>>,
    hash: Sha256,
    phase: ImportPhase,
    ready: Option<Imported>,
}
impl ImportState {
    fn new(revision: Revision, expected_bytes: u64) -> Self {
        Self {
            revision,
            expected_bytes,
            processed: 0,
            validated: 0,
            buffer: vec![0; TEXT_PAGE_BYTES],
            used: 0,
            valid_in_page: 0,
            page_summary: TextSummary::EMPTY,
            pieces: Vec::with_capacity(FANOUT),
            levels: (0..=MAX_HEIGHT)
                .map(|_| Vec::with_capacity(FANOUT))
                .collect(),
            hash: Sha256::new(),
            phase: ImportPhase::Reading,
            ready: None,
        }
    }
    fn progress(&self) -> BulkProgress {
        BulkProgress {
            processed_bytes: self.processed,
            validated_bytes: self.validated,
            complete: matches!(self.phase, ImportPhase::Ready),
        }
    }
    fn flush_page<S: PageProvider>(&mut self, engine: &mut TextEngine<S>) -> Result<()> {
        let count = self.valid_in_page;
        if count == 0 {
            return Ok(());
        }
        let chunk = engine.write_page(&self.revision, PageKind::Text, &self.buffer[..count])?;
        self.pieces.push(Piece {
            chunk,
            start: 0,
            end: count as u32,
            summary: self.page_summary,
            paragraphs: Some(ParagraphSummary::of(
                std::str::from_utf8(&self.buffer[..count])
                    .map_err(|_| Error::Invalid("import paragraph UTF8"))?,
            )),
        });
        if self.pieces.len() == FANOUT {
            self.flush_pieces(engine)?;
        }
        self.buffer.copy_within(count..self.used, 0);
        self.used -= count;
        self.valid_in_page = 0;
        self.page_summary = TextSummary::EMPTY;
        Ok(())
    }
    fn flush_pieces<S: PageProvider>(&mut self, engine: &mut TextEngine<S>) -> Result<()> {
        if self.pieces.is_empty() {
            return Ok(());
        }
        let pieces = std::mem::replace(&mut self.pieces, Vec::with_capacity(FANOUT));
        let leaf = engine.write_node(&self.revision, Node::Leaf(pieces), 0)?;
        // At most MAX_HEIGHT + 1 node writes, even for a full carry chain.
        engine.frontier_push(&self.revision, &mut self.levels, 0, leaf)
    }
    fn make_ready(&mut self, root: Option<TreeRef>) -> Result<()> {
        self.revision.root = root;
        self.revision.validate()?;
        if self.revision.summary().bytes != self.expected_bytes
            || self.validated != self.expected_bytes
        {
            return Err(Error::Invalid("import final summary"));
        }
        let hash = std::mem::replace(&mut self.hash, Sha256::new());
        self.ready = Some(Imported {
            document: Document {
                revision: self.revision.clone(),
            },
            whole_text_sha256: format!("{:x}", hash.finalize()),
        });
        self.phase = ImportPhase::Ready;
        Ok(())
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        reader: &mut impl Read,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<BulkProgress> {
        check_cancel(cancelled)?;
        match self.phase {
            ImportPhase::Ready => {}
            ImportPhase::Reading => {
                let remaining = self
                    .expected_bytes
                    .checked_sub(self.processed)
                    .ok_or(Error::Invalid("import extent overflow"))?;
                let room = self.buffer.len() - self.used;
                let capacity = (remaining.saturating_add(1).min(room as u64)) as usize;
                if capacity == 0 {
                    return Err(Error::Invalid("import page did not advance"));
                }
                // Exactly one read. A short read keeps the fixed page buffer;
                // only its new bytes and <=3-byte scalar carry are validated.
                let count = match reader.read(&mut self.buffer[self.used..self.used + capacity]) {
                    Ok(count) if count <= capacity => count,
                    Ok(_) => return Err(Error::Invalid("import read exceeds capacity")),
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                        check_cancel(cancelled)?;
                        return Ok(self.progress());
                    }
                    Err(error) => return Err(Error::Io(error)),
                };
                if count as u64 > remaining {
                    return Err(Error::Stale);
                }
                let eof = count == 0;
                self.processed += count as u64;
                self.used += count;
                let tail = &self.buffer[self.valid_in_page..self.used];
                let valid = match std::str::from_utf8(tail) {
                    Ok(_) => tail.len(),
                    Err(error) if !eof && error.error_len().is_none() => error.valid_up_to(),
                    Err(_) => return Err(Error::Invalid("import UTF8")),
                };
                if tail.len() - valid > 3 {
                    return Err(Error::Invalid("import scalar carry"));
                }
                let text = std::str::from_utf8(&tail[..valid])
                    .map_err(|_| Error::Invalid("import UTF8"))?;
                self.page_summary = self.page_summary.checked_add(TextSummary::of(text))?;
                self.hash.update(text.as_bytes());
                self.validated = self
                    .validated
                    .checked_add(valid as u64)
                    .ok_or(Error::Invalid("import extent overflow"))?;
                self.valid_in_page += valid;
                if eof && self.processed != self.expected_bytes {
                    return Err(Error::Stale);
                }
                if self.used == TEXT_PAGE_BYTES || eof {
                    self.flush_page(engine)?;
                }
                if eof {
                    if self.used != 0 {
                        return Err(Error::Invalid("incomplete import UTF8"));
                    }
                    self.phase = ImportPhase::Pieces;
                }
            }
            ImportPhase::Pieces => {
                self.flush_pieces(engine)?;
                self.phase = ImportPhase::Levels(0);
            }
            ImportPhase::Levels(mut level) => {
                while level < self.levels.len() && self.levels[level].is_empty() {
                    level += 1;
                }
                if level == self.levels.len() {
                    self.make_ready(None)?;
                } else {
                    let higher = self.levels[level + 1..].iter().any(|slot| !slot.is_empty());
                    let children = std::mem::take(&mut self.levels[level]);
                    if !higher && children.len() == 1 {
                        self.make_ready(children.into_iter().next())?;
                    } else {
                        let height = u8::try_from(level + 1)
                            .map_err(|_| Error::Invalid("import tree height"))?;
                        let tree =
                            engine.write_node(&self.revision, Node::Branch(children), height)?;
                        if higher {
                            engine.frontier_push(
                                &self.revision,
                                &mut self.levels,
                                level + 1,
                                tree,
                            )?;
                            self.phase = ImportPhase::Levels(level + 1);
                        } else {
                            self.make_ready(Some(tree))?;
                        }
                    }
                }
            }
        }
        check_cancel(cancelled)?;
        Ok(self.progress())
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum StreamKind {
    Hash,
    Export,
}
struct Frame {
    node: Node,
    next: usize,
}
struct PieceCursor {
    bytes: Arc<[u8]>,
    at: usize,
    end: usize,
}
struct TreeCursor {
    tree: Option<TreeRef>,
    stack: Vec<Frame>,
    piece: Option<PieceCursor>,
    complete: bool,
}
impl TreeCursor {
    fn new(root: Option<TreeRef>) -> Self {
        let complete = root.is_none();
        Self {
            tree: root,
            stack: Vec::with_capacity(usize::from(MAX_HEIGHT) + 1),
            piece: None,
            complete,
        }
    }
    fn fill<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
        output: &mut [u8],
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<usize> {
        let mut copied = 0;
        for _ in 0..BULK_STEP_WORK {
            check_cancel(cancelled)?;
            if copied == output.len() || self.complete {
                break;
            }
            if let Some(piece) = &mut self.piece {
                let count = (piece.end - piece.at).min(output.len() - copied);
                output[copied..copied + count]
                    .copy_from_slice(&piece.bytes[piece.at..piece.at + count]);
                copied += count;
                piece.at += count;
                if piece.at == piece.end {
                    self.piece = None;
                }
            } else if let Some(tree) = self.tree.take() {
                if self.stack.len() > usize::from(MAX_HEIGHT) {
                    return Err(Error::Invalid("stream cursor depth"));
                }
                let node = engine.node(revision, &tree)?;
                self.stack.push(Frame { node, next: 0 });
            } else if let Some(frame) = self.stack.last_mut() {
                match &frame.node {
                    Node::Leaf(pieces) if frame.next < pieces.len() => {
                        let piece = pieces[frame.next].clone();
                        frame.next += 1;
                        let bytes = engine.piece_text(revision, &piece)?;
                        self.piece = Some(PieceCursor {
                            bytes,
                            at: piece.start as usize,
                            end: piece.end as usize,
                        });
                    }
                    Node::Branch(children) if frame.next < children.len() => {
                        self.tree = Some(children[frame.next].clone());
                        frame.next += 1;
                    }
                    _ => {
                        let _ = self.stack.pop();
                    }
                }
            } else {
                self.complete = true;
            }
        }
        Ok(copied)
    }
}
struct StreamState {
    revision: Revision,
    kind: StreamKind,
    cursor: TreeCursor,
    buffer: Vec<u8>,
    at: usize,
    used: usize,
    processed: u64,
    hash: Sha256,
    ready: Option<String>,
}
impl StreamState {
    fn new(revision: Revision, kind: StreamKind) -> Self {
        Self {
            cursor: TreeCursor::new(revision.root.clone()),
            revision,
            kind,
            buffer: vec![0; TEXT_PAGE_BYTES],
            at: 0,
            used: 0,
            processed: 0,
            hash: Sha256::new(),
            ready: None,
        }
    }
    fn progress(&self) -> BulkProgress {
        BulkProgress {
            processed_bytes: self.processed,
            validated_bytes: self.processed,
            complete: self.ready.is_some(),
        }
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        writer: Option<&mut dyn Write>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<BulkProgress> {
        check_cancel(cancelled)?;
        if self.ready.is_some() {
            return Ok(self.progress());
        }
        if self.kind == StreamKind::Export && writer.is_none() {
            return Err(Error::Invalid("missing export stream"));
        }
        if self.at == self.used {
            self.at = 0;
            self.used = self
                .cursor
                .fill(engine, &self.revision, &mut self.buffer, cancelled)?;
        }
        if self.at < self.used {
            let bytes = &self.buffer[self.at..self.used];
            let count = match self.kind {
                StreamKind::Hash => bytes.len(),
                StreamKind::Export => {
                    let writer = writer.ok_or(Error::Invalid("missing export stream"))?;
                    match writer.write(bytes) {
                        Ok(0) => {
                            return Err(Error::Io(io::Error::new(
                                io::ErrorKind::WriteZero,
                                "Text export did not advance.",
                            )));
                        }
                        Ok(count) if count <= bytes.len() => count,
                        Ok(_) => return Err(Error::Invalid("export write exceeds capacity")),
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                            check_cancel(cancelled)?;
                            return Ok(self.progress());
                        }
                        Err(error) => return Err(Error::Io(error)),
                    }
                }
            };
            self.hash.update(&bytes[..count]);
            self.processed = self
                .processed
                .checked_add(count as u64)
                .ok_or(Error::Invalid("stream extent overflow"))?;
            self.at += count;
        }
        if self.cursor.complete && self.at == self.used {
            if self.processed != self.revision.summary().bytes {
                return Err(Error::Invalid("stream final extent"));
            }
            let hash = std::mem::replace(&mut self.hash, Sha256::new());
            self.ready = Some(format!("{:x}", hash.finalize()));
        }
        check_cancel(cancelled)?;
        Ok(self.progress())
    }
}

impl<S: PageProvider> TextEngine<S> {
    pub fn active_bulk_operations(&self) -> usize {
        self.bulk.slots.iter().flatten().count()
    }
    pub fn line_prefix_begin(
        &mut self,
        revision: Revision,
        start: u64,
        end: u64,
        prefix: String,
    ) -> Result<Uuid> {
        self.bulk.available()?;
        let state = LinePrefixState::new(self, revision, start, end, prefix)?;
        self.bulk.insert(
            state.revision.owner_id,
            state.revision.document_id,
            State::LinePrefix(Box::new(state)),
        )
    }
    pub fn line_prefix_step(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LinePrefixProgress> {
        revision.validate()?;
        let (slot, mut job) = self.bulk.take_prefix(revision, id)?;
        check_cancel(cancelled)?;
        let State::LinePrefix(state) = &mut job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        let progress = state.step(self)?;
        check_cancel(cancelled)?;
        self.bulk.restore(slot, job)?;
        Ok(progress)
    }
    pub fn line_prefix_finish(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LinePrefixResult> {
        revision.validate()?;
        let (_, job) = self.bulk.take_prefix(revision, id)?;
        check_cancel(cancelled)?;
        let State::LinePrefix(state) = job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        state
            .ready
            .ok_or(Error::Invalid("line prefix has not completed"))
    }
    pub fn paragraph_bounds_begin(
        &mut self,
        revision: Revision,
        utf16: u64,
        include_line_endings: bool,
    ) -> Result<Uuid> {
        self.bulk.available()?;
        let state = ParagraphState::new(self, revision, utf16, include_line_endings)?;
        self.bulk.insert(
            state.revision.owner_id,
            state.revision.document_id,
            State::Paragraph(Box::new(state)),
        )
    }
    pub fn paragraph_bounds_step(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<ParagraphProgress> {
        revision.validate()?;
        let (slot, mut job) = self.bulk.take_paragraph(revision, id)?;
        check_cancel(cancelled)?;
        let State::Paragraph(state) = &mut job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        let progress = state.step(self)?;
        check_cancel(cancelled)?;
        self.bulk.restore(slot, job)?;
        Ok(progress)
    }
    pub fn paragraph_bounds_finish(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<ParagraphBounds> {
        revision.validate()?;
        let (_, job) = self.bulk.take_paragraph(revision, id)?;
        check_cancel(cancelled)?;
        let State::Paragraph(state) = job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        state
            .ready
            .ok_or(Error::Invalid("paragraph bounds have not completed"))
    }
    /// Capture an immutable revision and exact scalar origin. Only the next
    /// boundary in the requested direction is sought; no source is changed.
    pub fn grapheme_seek_begin(
        &mut self,
        revision: Revision,
        utf16: u64,
        forward: bool,
    ) -> Result<Uuid> {
        self.bulk.available()?;
        let document = self.open(revision)?;
        let length = usize::try_from(document.summary().bytes)
            .map_err(|_| Error::Invalid("grapheme source exceeds usize"))?;
        let at = self.byte_at_utf16(&document, document.revision(), utf16)?;
        let revision = document.revision;
        let offset =
            usize::try_from(at).map_err(|_| Error::Invalid("grapheme origin exceeds usize"))?;
        let endpoint = if forward {
            offset == length
        } else {
            offset == 0
        };
        let ready = endpoint.then_some(if forward {
            revision.summary()
        } else {
            TextSummary::EMPTY
        });
        let fetch = if endpoint {
            None
        } else {
            Some(GraphemeFetch::Piece(if forward { at } else { at - 1 }))
        };
        let owner = revision.owner_id;
        let document = revision.document_id;
        let state = GraphemeSeekState {
            revision,
            cursor: GraphemeCursor::new(offset, length, true),
            forward,
            piece: None,
            fetch,
            ready,
            examined: 0,
        };
        self.bulk
            .insert(owner, document, State::Grapheme(Box::new(state)))
    }
    pub fn grapheme_seek_step(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<GraphemeSeekProgress> {
        revision.validate()?;
        let (slot, mut job) = self.bulk.take_grapheme(revision, id)?;
        check_cancel(cancelled)?;
        let State::Grapheme(state) = &mut job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        let progress = state.step(self)?;
        check_cancel(cancelled)?;
        self.bulk.restore(slot, job)?;
        Ok(progress)
    }
    pub fn grapheme_seek_finish(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<TextSummary> {
        revision.validate()?;
        let (_, job) = self.bulk.take_grapheme(revision, id)?;
        check_cancel(cancelled)?;
        let State::Grapheme(state) = job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        state
            .ready
            .ok_or(Error::Invalid("grapheme seek has not completed"))
    }
    pub fn import_begin(
        &mut self,
        owner: Uuid,
        document: Uuid,
        expected_bytes: u64,
    ) -> Result<Uuid> {
        let revision = Revision {
            schema: 1,
            owner_id: owner,
            document_id: document,
            root: None,
        };
        revision.validate()?;
        self.bulk.available()?;
        self.bulk.insert(
            owner,
            document,
            State::Import(Box::new(ImportState::new(revision, expected_bytes))),
        )
    }
    pub fn import_step(
        &mut self,
        owner: Uuid,
        document: Uuid,
        id: Uuid,
        reader: &mut impl Read,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<BulkProgress> {
        let (slot, mut job) = self.bulk.take_import(owner, document, id)?;
        let State::Import(state) = &mut job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        // Any error after captured identity admission drops this exact session.
        let progress = state.step(self, reader, cancelled)?;
        self.bulk.restore(slot, job)?;
        Ok(progress)
    }
    pub fn import_finish(
        &mut self,
        owner: Uuid,
        document: Uuid,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Imported> {
        let (_, job) = self.bulk.take_import(owner, document, id)?;
        check_cancel(cancelled)?;
        let State::Import(mut state) = job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        state
            .ready
            .take()
            .ok_or(Error::Invalid("import has not completed"))
    }
    fn stream_begin(&mut self, revision: Revision, kind: StreamKind) -> Result<Uuid> {
        self.bulk.available()?;
        let document = self.open(revision)?;
        let revision = document.revision;
        self.bulk.insert(
            revision.owner_id,
            revision.document_id,
            State::Stream(Box::new(StreamState::new(revision, kind))),
        )
    }
    pub fn export_begin(&mut self, revision: Revision) -> Result<Uuid> {
        self.stream_begin(revision, StreamKind::Export)
    }
    pub fn hash_begin(&mut self, revision: Revision) -> Result<Uuid> {
        self.stream_begin(revision, StreamKind::Hash)
    }
    pub fn stream_step(
        &mut self,
        revision: &Revision,
        id: Uuid,
        writer: Option<&mut dyn Write>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<BulkProgress> {
        revision.validate()?;
        let (slot, mut job) = self.bulk.take_stream(revision, id)?;
        let State::Stream(state) = &mut job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        let progress = state.step(self, writer, cancelled)?;
        self.bulk.restore(slot, job)?;
        Ok(progress)
    }
    pub fn stream_finish(
        &mut self,
        revision: &Revision,
        id: Uuid,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<String> {
        revision.validate()?;
        let (_, job) = self.bulk.take_stream(revision, id)?;
        check_cancel(cancelled)?;
        let State::Stream(mut state) = job.state else {
            return Err(Error::Invalid("bulk operation kind"));
        };
        state
            .ready
            .take()
            .ok_or(Error::Invalid("stream has not completed"))
    }
    pub fn bulk_abort(&mut self, owner: Uuid, document: Uuid, id: Uuid) -> Result<bool> {
        if owner.is_nil() || document.is_nil() || id.is_nil() {
            return Err(Error::Invalid("bulk operation identity"));
        }
        let slot = match self.bulk.index(owner, document, id) {
            Ok(slot) => slot,
            Err(Error::Stale) => return Ok(true),
            Err(error) => return Err(error),
        };
        self.bulk.slots[slot] = None;
        Ok(true)
    }
}
