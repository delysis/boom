//! Cooperative line prefixing: share immutable source, build only new indexes.
use super::*;
use paragraph::{scalar, separator};

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LinePrefixProgress {
    pub complete: bool,
    pub processed_bytes: u64,
    pub examined_bytes: u64,
    pub buffered_bytes: usize,
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LinePrefixResult {
    pub revision: Revision,
    pub byte_start: u64,
    pub byte_end: u64,
    pub utf16_start: u64,
    pub utf16_length: u64,
    pub removing: bool,
    pub changed: bool,
}
struct RangeFrame {
    node: Node,
    next: usize,
    before: TextSummary,
}
struct RangeCursor {
    tree: Option<(TreeRef, TextSummary)>,
    stack: Vec<RangeFrame>,
    start: u64,
    end: u64,
    complete: bool,
}
enum Unit {
    Shared(TreeRef),
    Piece(Piece, u32, u32),
}
impl RangeCursor {
    fn new(revision: &Revision, start: u64, end: u64) -> Self {
        Self {
            tree: revision.root.clone().map(|r| (r, TextSummary::EMPTY)),
            stack: Vec::with_capacity(usize::from(MAX_HEIGHT) + 1),
            start,
            end,
            complete: start == end,
        }
    }
    fn next<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
        share: bool,
    ) -> Result<Option<Unit>> {
        for _ in 0..BULK_STEP_WORK {
            if self.complete {
                return Ok(None);
            }
            if let Some((tree, before)) = self.tree.take() {
                let end = before
                    .bytes
                    .checked_add(tree.summary.bytes)
                    .ok_or(Error::Invalid("prefix tree extent"))?;
                if end <= self.start || before.bytes >= self.end {
                    continue;
                }
                if share
                    && before.bytes >= self.start
                    && end <= self.end
                    && tree.paragraphs.is_some_and(|p| p.breaks == 0)
                {
                    return Ok(Some(Unit::Shared(tree)));
                }
                if self.stack.len() > usize::from(MAX_HEIGHT) {
                    return Err(Error::Invalid("prefix cursor height"));
                }
                self.stack.push(RangeFrame {
                    node: engine.node(revision, &tree)?,
                    next: 0,
                    before,
                });
            } else if let Some(frame) = self.stack.last_mut() {
                match &frame.node {
                    Node::Branch(children) if frame.next < children.len() => {
                        let child = children[frame.next].clone();
                        let before = frame.before;
                        frame.next += 1;
                        frame.before = frame.before.checked_add(child.summary)?;
                        self.tree = Some((child, before));
                    }
                    Node::Leaf(pieces) if frame.next < pieces.len() => {
                        let piece = pieces[frame.next].clone();
                        let before = frame.before;
                        frame.next += 1;
                        frame.before = frame.before.checked_add(piece.summary)?;
                        if frame.before.bytes <= self.start || before.bytes >= self.end {
                            continue;
                        }
                        let left = self.start.saturating_sub(before.bytes);
                        let right = (self.end - before.bytes).min(piece.summary.bytes);
                        let start = piece
                            .start
                            .checked_add(
                                u32::try_from(left)
                                    .map_err(|_| Error::Invalid("prefix clip u32"))?,
                            )
                            .ok_or(Error::Invalid("prefix clip overflow"))?;
                        let end = piece
                            .start
                            .checked_add(
                                u32::try_from(right)
                                    .map_err(|_| Error::Invalid("prefix clip u32"))?,
                            )
                            .ok_or(Error::Invalid("prefix clip overflow"))?;
                        return Ok(Some(Unit::Piece(piece, start, end)));
                    }
                    _ => {
                        let _ = self.stack.pop();
                    }
                }
            } else {
                self.complete = true;
            }
        }
        Ok(None)
    }
}
pub(super) struct Builder {
    pieces: Vec<Piece>,
    levels: Vec<Vec<TreeRef>>,
    pub(super) summary: TextSummary,
}
impl Builder {
    pub(super) fn new() -> Self {
        Self {
            pieces: Vec::with_capacity(FANOUT),
            levels: (0..=MAX_HEIGHT)
                .map(|_| Vec::with_capacity(FANOUT))
                .collect(),
            summary: TextSummary::EMPTY,
        }
    }
    fn flush<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
    ) -> Result<()> {
        if self.pieces.is_empty() {
            return Ok(());
        }
        let pieces = std::mem::replace(&mut self.pieces, Vec::with_capacity(FANOUT));
        if let Some(leaf) = engine.leaf(revision, pieces)? {
            engine.frontier_push(revision, &mut self.levels, 0, leaf)?;
        }
        Ok(())
    }
    pub(super) fn piece<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
        piece: Piece,
    ) -> Result<()> {
        self.summary = self.summary.checked_add(piece.summary)?;
        self.pieces.push(piece);
        if self.pieces.len() == FANOUT {
            self.flush(engine, revision)?;
        }
        Ok(())
    }
    fn shared<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
        tree: TreeRef,
    ) -> Result<()> {
        self.flush(engine, revision)?;
        // Complete lower pending levels before inserting this larger source
        // subtree. The existing bounded import frontier preserves source order.
        for level in 0..usize::from(tree.height) {
            if self.levels[level].is_empty() {
                continue;
            }
            let children = std::mem::replace(&mut self.levels[level], Vec::with_capacity(FANOUT));
            let node = engine.write_node(
                revision,
                Node::Branch(children),
                u8::try_from(level + 1).map_err(|_| Error::Invalid("prefix height"))?,
            )?;
            engine.frontier_push(revision, &mut self.levels, level + 1, node)?;
        }
        self.summary = self.summary.checked_add(tree.summary)?;
        engine.frontier_push(revision, &mut self.levels, usize::from(tree.height), tree)
    }
    pub(super) fn finish_step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        revision: &Revision,
    ) -> Result<Option<Option<TreeRef>>> {
        if !self.pieces.is_empty() {
            self.flush(engine, revision)?;
            return Ok(None);
        }
        let Some(level) = self.levels.iter().position(|s| !s.is_empty()) else {
            return Ok(Some(None));
        };
        let higher = self.levels[level + 1..].iter().any(|s| !s.is_empty());
        let children = std::mem::replace(&mut self.levels[level], Vec::with_capacity(FANOUT));
        if !higher && children.len() == 1 {
            return Ok(Some(children.into_iter().next()));
        }
        let height = u8::try_from(level + 1).map_err(|_| Error::Invalid("prefix height"))?;
        let node = engine.write_node(revision, Node::Branch(children), height)?;
        if !higher {
            return Ok(Some(Some(node)));
        }
        engine.frontier_push(revision, &mut self.levels, level + 1, node)?;
        Ok(None)
    }
}
struct Loaded {
    piece: Piece,
    bytes: Arc<[u8]>,
    at: usize,
    end: usize,
    run: usize,
}
impl Loaded {
    fn next_char(&self) -> Result<char> {
        let first = *self
            .bytes
            .get(self.at)
            .filter(|_| self.at < self.end)
            .ok_or(Error::Invalid("prefix empty scalar"))?;
        let width = match first {
            0..=0x7f => 1,
            0xc2..=0xdf => 2,
            0xe0..=0xef => 3,
            0xf0..=0xf4 => 4,
            _ => return Err(Error::Invalid("prefix scalar lead")),
        };
        let end = self
            .at
            .checked_add(width)
            .filter(|end| *end <= self.end)
            .ok_or(Error::Invalid("prefix scalar extent"))?;
        // The page/piece was admitted once. Validate only this scalar here,
        // rather than repeatedly scanning its entire remaining UTF8 suffix.
        std::str::from_utf8(
            self.bytes
                .get(self.at..end)
                .ok_or(Error::Invalid("prefix scalar slice"))?,
        )
        .map_err(|_| Error::Invalid("prefix scalar"))?
        .chars()
        .next()
        .ok_or(Error::Invalid("prefix empty scalar"))
    }
    fn segment<S: PageProvider>(
        &self,
        builder: &mut Builder,
        engine: &mut TextEngine<S>,
        revision: &Revision,
        end: usize,
    ) -> Result<()> {
        if self.run == end {
            return Ok(());
        }
        let text = std::str::from_utf8(
            self.bytes
                .get(self.run..end)
                .ok_or(Error::Invalid("prefix segment extent"))?,
        )
        .map_err(|_| Error::Invalid("prefix segment scalar"))?;
        builder.piece(
            engine,
            revision,
            Piece {
                chunk: self.piece.chunk.clone(),
                start: u32::try_from(self.run).map_err(|_| Error::Invalid("prefix segment u32"))?,
                end: u32::try_from(end).map_err(|_| Error::Invalid("prefix segment u32"))?,
                summary: TextSummary::of(text),
                paragraphs: Some(ParagraphSummary::of(text)),
            },
        )
    }
}
enum Phase {
    StartBounds(ParagraphState),
    EndBounds(ParagraphState),
    Inspect,
    Prepare,
    Build,
    Finalize,
    Assemble,
    Ready,
}
pub(super) struct LinePrefixState {
    pub(super) revision: Revision,
    original_start: u64,
    original_end: u64,
    prefix: Vec<u8>,
    phase: Phase,
    start: TextSummary,
    end: TextSummary,
    cursor: RangeCursor,
    loaded: Option<Loaded>,
    builder: Builder,
    left: Option<TreeRef>,
    right: Option<TreeRef>,
    body: Option<TreeRef>,
    prefix_piece: Option<Piece>,
    line_start: bool,
    after_cr: bool,
    matched: usize,
    lines: u64,
    removing: bool,
    processed: u64,
    source_at: u64,
    examined: u64,
    pub(super) ready: Option<LinePrefixResult>,
}
impl LinePrefixState {
    pub(super) fn new<S: PageProvider>(
        engine: &mut TextEngine<S>,
        revision: Revision,
        start: u64,
        end: u64,
        prefix: String,
    ) -> Result<Self> {
        if prefix.is_empty() || prefix.len() > 256 || prefix.chars().any(separator) {
            return Err(Error::Invalid("line prefix bound or separator"));
        }
        let doc = engine.open(revision)?;
        let revision = doc.revision.clone();
        if start > end || end > revision.summary().utf16 {
            return Err(Error::Invalid("line prefix selection"));
        }
        let _ = engine.byte_at_utf16(&doc, &revision, end)?;
        let bounds = ParagraphState::new(engine, revision.clone(), start, true)?;
        Ok(Self {
            cursor: RangeCursor::new(&revision, 0, 0),
            revision,
            original_start: start,
            original_end: end,
            prefix: prefix.into_bytes(),
            phase: Phase::StartBounds(bounds),
            start: TextSummary::EMPTY,
            end: TextSummary::EMPTY,
            loaded: None,
            builder: Builder::new(),
            left: None,
            right: None,
            body: None,
            prefix_piece: None,
            line_start: true,
            after_cr: false,
            matched: 0,
            lines: 0,
            removing: false,
            processed: 0,
            source_at: 0,
            examined: 0,
            ready: None,
        })
    }
    pub(super) fn progress(&self) -> Result<LinePrefixProgress> {
        let bound = match &self.phase {
            Phase::StartBounds(s) | Phase::EndBounds(s) => Some(s.progress()),
            _ => None,
        };
        Ok(LinePrefixProgress {
            complete: self.ready.is_some(),
            processed_bytes: self.processed,
            examined_bytes: self
                .examined
                .checked_add(bound.map_or(0, |p| p.examined_bytes))
                .ok_or(Error::Invalid("prefix examined overflow"))?,
            buffered_bytes: bound.map_or_else(
                || self.loaded.as_ref().map_or(0, |p| p.bytes.len()),
                |p| p.buffered_bytes,
            ),
        })
    }
    fn advance(&mut self, n: u64) -> Result<()> {
        self.processed = self
            .processed
            .checked_add(n)
            .ok_or(Error::Invalid("prefix progress overflow"))?;
        self.source_at = self
            .source_at
            .checked_add(n)
            .filter(|n| *n <= self.end.bytes)
            .ok_or(Error::Invalid("prefix source progress"))?;
        Ok(())
    }
    fn reset_scan(&mut self) {
        self.cursor = RangeCursor::new(&self.revision, self.start.bytes, self.end.bytes);
        self.loaded = None;
        self.source_at = self.start.bytes;
        self.line_start = true;
        self.after_cr = false;
        self.matched = 0;
        self.lines = 0;
    }
    fn complete(&mut self, revision: Revision) -> Result<()> {
        let changed = revision != self.revision;
        self.ready = Some(LinePrefixResult {
            revision,
            byte_start: self.start.bytes,
            byte_end: self
                .start
                .bytes
                .checked_add(self.builder.summary.bytes)
                .ok_or(Error::Invalid("prefix result overflow"))?,
            utf16_start: self.start.utf16,
            utf16_length: self.builder.summary.utf16,
            removing: self.removing,
            changed,
        });
        self.phase = Phase::Ready;
        Ok(())
    }
    pub(super) fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
    ) -> Result<LinePrefixProgress> {
        // Bounds are themselves a small continuation, not another registered
        // operation or a resident list of selected paragraphs.
        match &mut self.phase {
            Phase::StartBounds(state) => {
                let progress = state.step(engine)?;
                if let Some(bounds) = progress.result {
                    self.examined = self
                        .examined
                        .checked_add(progress.examined_bytes)
                        .ok_or(Error::Invalid("prefix examined overflow"))?;
                    self.start = bounds.start;
                    let doc = engine.open(self.revision.clone())?;
                    let at = if self.original_end > self.original_start {
                        engine
                            .scalar_position(&doc, &self.revision, self.original_end - 1, false)?
                            .utf16
                    } else {
                        self.original_end
                    };
                    self.phase = Phase::EndBounds(ParagraphState::new(
                        engine,
                        self.revision.clone(),
                        at,
                        true,
                    )?);
                }
                return self.progress();
            }
            Phase::EndBounds(state) => {
                let progress = state.step(engine)?;
                if let Some(bounds) = progress.result {
                    self.examined = self
                        .examined
                        .checked_add(progress.examined_bytes)
                        .ok_or(Error::Invalid("prefix examined overflow"))?;
                    self.end = bounds.end;
                    self.reset_scan();
                    self.phase = Phase::Inspect;
                }
                return self.progress();
            }
            Phase::Ready => return self.progress(),
            _ => {}
        }
        if matches!(self.phase, Phase::Prepare) {
            if let Some(root) = &self.revision.root {
                let (left, tail) = engine.split(&self.revision, root, self.start.bytes)?;
                self.left = left;
                self.right = match tail {
                    Some(tail) => {
                        engine
                            .split(&self.revision, &tail, self.end.bytes - self.start.bytes)?
                            .1
                    }
                    None => None,
                };
            }
            if !self.removing && self.start.bytes < self.end.bytes {
                let text =
                    std::str::from_utf8(&self.prefix).map_err(|_| Error::Invalid("prefix UTF8"))?;
                let chunk = engine.write_page(&self.revision, PageKind::Text, &self.prefix)?;
                self.prefix_piece = Some(Piece {
                    chunk,
                    start: 0,
                    end: u32::try_from(self.prefix.len())
                        .map_err(|_| Error::Invalid("prefix u32"))?,
                    summary: TextSummary::of(text),
                    paragraphs: Some(ParagraphSummary::of(text)),
                });
            }
            self.reset_scan();
            self.phase = Phase::Build;
            return self.progress();
        }
        if matches!(self.phase, Phase::Finalize) {
            if let Some(root) = self.builder.finish_step(engine, &self.revision)? {
                self.body = root;
                self.phase = Phase::Assemble;
            }
            return self.progress();
        }
        if matches!(self.phase, Phase::Assemble) {
            let left = engine.join(&self.revision, self.left.take(), self.body.take())?;
            let root = engine.join(&self.revision, left, self.right.take())?;
            let mut revision = self.revision.clone();
            revision.root = engine.collapse_root(&self.revision, root)?;
            revision.validate()?;
            self.complete(revision)?;
            return self.progress();
        }
        let inspecting = matches!(self.phase, Phase::Inspect);
        if self.loaded.is_none() {
            // Insert before a reusable paragraph-free subtree without reading
            // its text or copying its immutable payload.
            if !inspecting
                && self.line_start
                && !self.after_cr
                && !self.removing
                && self.source_at < self.end.bytes
            {
                if let Some(prefix) = &self.prefix_piece {
                    self.builder.piece(engine, &self.revision, prefix.clone())?;
                }
                self.line_start = false;
                self.lines = self
                    .lines
                    .checked_add(1)
                    .ok_or(Error::Invalid("prefix line count"))?;
            }
            let share = !self.line_start && !self.after_cr;
            match self.cursor.next(engine, &self.revision, share)? {
                Some(Unit::Shared(tree)) => {
                    self.advance(tree.summary.bytes)?;
                    if !inspecting {
                        self.builder.shared(engine, &self.revision, tree)?;
                    }
                }
                Some(Unit::Piece(piece, start, end)) => {
                    let bytes = engine.piece_text(&self.revision, &piece)?;
                    let at = usize::try_from(start)
                        .map_err(|_| Error::Invalid("prefix cursor usize"))?;
                    let end =
                        usize::try_from(end).map_err(|_| Error::Invalid("prefix cursor usize"))?;
                    let _ = std::str::from_utf8(
                        bytes
                            .get(at..end)
                            .ok_or(Error::Invalid("prefix clip extent"))?,
                    )
                    .map_err(|_| Error::Invalid("prefix clip scalar"))?;
                    self.examined = self
                        .examined
                        .checked_add(
                            u64::try_from(end - at).map_err(|_| Error::Invalid("prefix u64"))?,
                        )
                        .ok_or(Error::Invalid("prefix examined overflow"))?;
                    self.loaded = Some(Loaded {
                        piece,
                        bytes,
                        at,
                        end,
                        run: at,
                    });
                }
                None if self.cursor.complete => {
                    if inspecting {
                        if self.start.bytes == self.end.bytes {
                            self.complete(self.revision.clone())?;
                        } else {
                            self.removing = self.lines > 0 && self.matched == 0;
                            self.phase = Phase::Prepare;
                        }
                    } else {
                        self.phase = Phase::Finalize;
                    }
                }
                None => {}
            }
            return self.progress();
        }
        let mut loaded = self
            .loaded
            .take()
            .ok_or(Error::Invalid("prefix source lost"))?;
        let mut events = 0;
        while loaded.at < loaded.end && events < BULK_STEP_WORK {
            let ch = loaded.next_char()?;
            let n = ch.len_utf8();
            if self.after_cr {
                self.after_cr = false;
                if ch == '\n' {
                    loaded.at += n;
                    self.advance(scalar(ch).bytes)?;
                    continue;
                }
            }
            if self.line_start {
                if self.matched == 0 {
                    self.lines = self
                        .lines
                        .checked_add(1)
                        .ok_or(Error::Invalid("prefix line count"))?;
                }
                if inspecting || self.removing {
                    let end = self
                        .matched
                        .checked_add(n)
                        .ok_or(Error::Invalid("prefix compare overflow"))?;
                    if self.prefix.get(self.matched..end)
                        != Some(&loaded.bytes[loaded.at..loaded.at + n])
                    {
                        if inspecting {
                            self.removing = false;
                            self.phase = Phase::Prepare;
                            return self.progress();
                        }
                        return Err(Error::Invalid("immutable prefix changed between passes"));
                    }
                    if !inspecting && self.matched == 0 {
                        loaded.segment(&mut self.builder, engine, &self.revision, loaded.at)?;
                        events += 1;
                    }
                    self.matched = end;
                    loaded.at += n;
                    self.advance(scalar(ch).bytes)?;
                    if !inspecting {
                        loaded.run = loaded.at;
                    }
                    if self.matched == self.prefix.len() {
                        self.line_start = false;
                        self.matched = 0;
                        events += 1;
                    }
                    continue;
                }
                loaded.segment(&mut self.builder, engine, &self.revision, loaded.at)?;
                loaded.run = loaded.at;
                let prefix = self
                    .prefix_piece
                    .clone()
                    .ok_or(Error::Invalid("prefix candidate missing"))?;
                self.builder.piece(engine, &self.revision, prefix)?;
                self.line_start = false;
                events += 2;
            }
            loaded.at += n;
            self.advance(scalar(ch).bytes)?;
            if separator(ch) {
                self.line_start = true;
                self.after_cr = ch == '\r';
                events += 1;
            }
        }
        if loaded.at == loaded.end {
            if !inspecting {
                loaded.segment(&mut self.builder, engine, &self.revision, loaded.end)?;
            }
        } else {
            self.loaded = Some(loaded);
        }
        self.progress()
    }
}
