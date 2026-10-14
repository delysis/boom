//! Derived run-length/source-order index for the pinned MaybeCode search.
//! Bounded sorted leaves merge on the existing Index-page owner. Every merge,
//! seek and source step yields between page operations; no paragraph-sized map
//! or normalized code body is retained. Intermediate pages remain subject to
//! the same cold reclamation as other abandoned derived pages.
use super::*;
use pulldown_cmark::paged::{CodeRun, CodeRunStream, PreparedCodePair, prepare_code_pair};

const SORT_LEVELS: usize = 64;
type Key = [u64; 2];
fn key(run: CodeRun) -> Key {
    [run.count, run.start.bytes]
}
fn decode(words: [u64; 6], summary: TextSummary) -> Result<CodeRun> {
    let run = CodeRun::from_checkpoint(words).map_err(inline_error)?;
    TextSummary {
        bytes: run.start.bytes,
        utf16: run.start.utf16,
        lf_count: 0,
    }
    .validate()?;
    TextSummary {
        bytes: run.end.bytes,
        utf16: run.end.utf16,
        lf_count: 0,
    }
    .validate()?;
    if run.end.bytes > summary.bytes || run.end.utf16 > summary.utf16 {
        return Err(Error::Invalid("markup code run source extent"));
    }
    Ok(run)
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in crate::markup) struct CodeRef {
    page: PageRef,
    height: u8,
    count: u64,
    first: Key,
    last: Key,
}
impl CodeRef {
    fn validate(&self, summary: TextSummary) -> Result<()> {
        validate_page(&self.page, PageKind::Index)?;
        if self.height > MARK_HEIGHT
            || self.count == 0
            || self.first > self.last
            || self.first[0] == 0
            || self.last[0] > summary.bytes
            || self.last[1] >= summary.bytes
        {
            return Err(Error::Invalid("markup code index reference"));
        }
        Ok(())
    }
}
fn leaf_keys(values: &[[u64; 6]], summary: TextSummary) -> Result<(Key, Key)> {
    if values.is_empty() || values.len() > INLINE_PAGE_ITEMS {
        return Err(Error::Invalid("markup code leaf bound"));
    }
    let mut previous = None;
    for &words in values {
        let run = decode(words, summary)?;
        if previous.is_some_and(|last| last >= key(run)) {
            return Err(Error::Invalid("markup code leaf order"));
        }
        previous = Some(key(run));
    }
    Ok((
        key(decode(values[0], summary)?),
        previous.ok_or(Error::Invalid("markup code empty leaf"))?,
    ))
}
fn leaf_ref(page: PageRef, values: &[[u64; 6]], summary: TextSummary) -> Result<CodeRef> {
    let (first, last) = leaf_keys(values, summary)?;
    Ok(CodeRef {
        page,
        height: 0,
        count: values.len() as u64,
        first,
        last,
    })
}
fn branch_ref(page: PageRef, values: &[CodeRef], summary: TextSummary) -> Result<CodeRef> {
    if values.is_empty() || values.len() > MARK_FANOUT {
        return Err(Error::Invalid("markup code branch bound"));
    }
    let height = values[0]
        .height
        .checked_add(1)
        .filter(|value| *value <= MARK_HEIGHT)
        .ok_or(Error::Invalid("markup code branch height"))?;
    let mut count = 0u64;
    let mut last = None;
    for value in values {
        value.validate(summary)?;
        if value.height.checked_add(1) != Some(height) || last.is_some_and(|key| key >= value.first)
        {
            return Err(Error::Invalid("markup code child order"));
        }
        count = count
            .checked_add(value.count)
            .ok_or(Error::Invalid("markup code count"))?;
        last = Some(value.last);
    }
    Ok(CodeRef {
        page,
        height,
        count,
        first: values[0].first,
        last: last.ok_or(Error::Invalid("markup code empty branch"))?,
    })
}
impl<S: PageProvider> TextEngine<S> {
    fn code_leaf(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<[u64; 6]>,
        summary: TextSummary,
    ) -> Result<CodeRef> {
        let (first, last) = leaf_keys(&values, summary)?;
        let count = values.len() as u64;
        let page = self.write_mark_page(source, mode, MarkNode::CodeRuns(values))?;
        Ok(CodeRef {
            page,
            height: 0,
            count,
            first,
            last,
        })
    }
    fn code_branch(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<CodeRef>,
        summary: TextSummary,
    ) -> Result<CodeRef> {
        let page = values
            .first()
            .ok_or(Error::Invalid("markup code empty children"))?
            .page
            .clone();
        let mut root = branch_ref(page, &values, summary)?;
        root.page = self.write_mark_page(source, mode, MarkNode::CodeBranch(values))?;
        Ok(root)
    }
}
struct OrderedWrite {
    items: Vec<[u64; 6]>,
    frontier: Vec<Vec<CodeRef>>,
    pending: Option<(usize, CodeRef)>,
    finishing: bool,
    fold: usize,
    tail: Option<CodeRef>,
    complete: bool,
    last: Option<Key>,
}
impl OrderedWrite {
    fn new() -> Self {
        Self {
            items: Vec::with_capacity(INLINE_PAGE_ITEMS),
            frontier: vec![Vec::new()],
            pending: None,
            finishing: false,
            fold: 0,
            tail: None,
            complete: false,
            last: None,
        }
    }
    fn append(&mut self, run: CodeRun) -> Result<()> {
        if self.finishing
            || self.items.len() == INLINE_PAGE_ITEMS
            || self.last.is_some_and(|last| last >= key(run))
        {
            return Err(Error::Invalid("markup code ordered append"));
        }
        self.last = Some(key(run));
        self.items.push(run.checkpoint());
        Ok(())
    }
    fn needs_step(&self) -> bool {
        self.pending.is_some()
            || self.items.len() == INLINE_PAGE_ITEMS
            || self.finishing && !self.complete
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
        summary: TextSummary,
    ) -> Result<()> {
        if let Some((level, value)) = self.pending.take() {
            if level > usize::from(MARK_HEIGHT) {
                return Err(Error::Invalid("markup code frontier height"));
            }
            if level == self.frontier.len() {
                self.frontier.push(Vec::new());
            }
            self.frontier[level].push(value);
            if self.frontier[level].len() == MARK_FANOUT {
                let root = engine.code_branch(
                    source,
                    mode,
                    std::mem::take(&mut self.frontier[level]),
                    summary,
                )?;
                self.pending = Some((level + 1, root));
                return Ok(());
            }
        }
        if self.items.len() == INLINE_PAGE_ITEMS || self.finishing && !self.items.is_empty() {
            let root = engine.code_leaf(source, mode, std::mem::take(&mut self.items), summary)?;
            self.items = Vec::with_capacity(INLINE_PAGE_ITEMS);
            self.pending = Some((0, root));
            return Ok(());
        }
        if !self.finishing {
            return Ok(());
        }
        while self.fold < self.frontier.len() {
            let level = self.fold;
            if self.frontier[level].is_empty() {
                self.fold += 1;
                continue;
            }
            if let Some(value) = self.tail.take() {
                if usize::from(value.height) < level {
                    self.tail = Some(engine.code_branch(source, mode, vec![value], summary)?);
                    return Ok(());
                }
                if usize::from(value.height) != level {
                    return Err(Error::Invalid("markup code fold height"));
                }
                self.frontier[level].push(value);
            }
            let mut values = std::mem::take(&mut self.frontier[level]);
            self.fold += 1;
            if values.len() == 1 {
                self.tail = values.pop();
            } else {
                self.tail = Some(engine.code_branch(source, mode, values, summary)?);
                return Ok(());
            }
        }
        self.complete = true;
        Ok(())
    }
}
enum Next {
    Pending,
    Value(CodeRun),
    End,
}
struct Walk {
    stack: Vec<CodeRef>,
    items: VecDeque<CodeRun>,
    seek: Option<Key>,
}
impl Walk {
    fn new(root: Option<CodeRef>, seek: Option<Key>) -> Self {
        Self {
            stack: root.into_iter().collect(),
            items: VecDeque::new(),
            seek,
        }
    }
    fn next<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
        summary: TextSummary,
    ) -> Result<Next> {
        if let Some(run) = self.items.pop_front() {
            return Ok(Next::Value(run));
        }
        let Some(root) = self.stack.pop() else {
            return Ok(Next::End);
        };
        root.validate(summary)?;
        match engine.read_mark_page(source, mode, &root.page)? {
            MarkNode::CodeRuns(values) if root.height == 0 => {
                if leaf_ref(root.page.clone(), &values, summary)? != root {
                    return Err(Error::Invalid("markup code leaf aggregate"));
                }
                for words in values {
                    let run = decode(words, summary)?;
                    if self.seek.is_none_or(|first| key(run) >= first) {
                        self.items.push_back(run);
                    }
                }
            }
            MarkNode::CodeBranch(values) if root.height > 0 => {
                if branch_ref(root.page.clone(), &values, summary)? != root {
                    return Err(Error::Invalid("markup code branch aggregate"));
                }
                self.stack.extend(
                    values
                        .into_iter()
                        .rev()
                        .filter(|child| self.seek.is_none_or(|first| child.last >= first)),
                );
                if self.stack.len() > usize::from(MARK_HEIGHT + 1) * MARK_FANOUT {
                    return Err(Error::Invalid("markup code traversal bound"));
                }
            }
            _ => return Err(Error::Invalid("markup code index page kind")),
        }
        // Exactly one page has been read. Do not hide another read in next().
        Ok(Next::Pending)
    }
}
struct Merge {
    left: Walk,
    right: Walk,
    a: Option<CodeRun>,
    b: Option<CodeRun>,
    left_end: bool,
    right_end: bool,
    out: OrderedWrite,
}
impl Merge {
    fn new(left: CodeRef, right: CodeRef) -> Self {
        Self {
            left: Walk::new(Some(left), None),
            right: Walk::new(Some(right), None),
            a: None,
            b: None,
            left_end: false,
            right_end: false,
            out: OrderedWrite::new(),
        }
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
        summary: TextSummary,
    ) -> Result<()> {
        if self.out.needs_step() {
            return self.out.step(engine, source, mode, summary);
        }
        for _ in 0..INLINE_PAGE_ITEMS {
            if self.a.is_none() && !self.left_end {
                match self.left.next(engine, source, mode, summary)? {
                    Next::Pending => return Ok(()),
                    Next::Value(value) => self.a = Some(value),
                    Next::End => self.left_end = true,
                }
            }
            if self.b.is_none() && !self.right_end {
                match self.right.next(engine, source, mode, summary)? {
                    Next::Pending => return Ok(()),
                    Next::Value(value) => self.b = Some(value),
                    Next::End => self.right_end = true,
                }
            }
            let run = match (self.a, self.b) {
                (Some(a), Some(b)) if key(a) == key(b) => {
                    return Err(Error::Invalid("markup duplicate code source run"));
                }
                (Some(a), Some(b)) if key(a) < key(b) => self.a.take(),
                (Some(_), Some(_)) => self.b.take(),
                (Some(_), None) => self.a.take(),
                (None, Some(_)) => self.b.take(),
                (None, None) => {
                    self.out.finishing = true;
                    return Ok(());
                }
            };
            self.out
                .append(run.ok_or(Error::Invalid("markup code merge source"))?)?;
            if self.out.needs_step() {
                return Ok(());
            }
        }
        Ok(())
    }
}
struct Sort {
    items: Vec<CodeRun>,
    frontier: Vec<Option<CodeRef>>,
    pending: Option<(usize, CodeRef)>,
    merge: Option<(Option<usize>, Merge)>,
    finishing: bool,
    fold: usize,
    tail: Option<CodeRef>,
    complete: bool,
}
impl Sort {
    fn new() -> Self {
        Self {
            items: Vec::with_capacity(INLINE_PAGE_ITEMS),
            frontier: Vec::new(),
            pending: None,
            merge: None,
            finishing: false,
            fold: 0,
            tail: None,
            complete: false,
        }
    }
    fn push(&mut self, value: CodeRun) -> Result<()> {
        if self.finishing || self.items.len() == INLINE_PAGE_ITEMS {
            return Err(Error::Invalid("markup code sort append"));
        }
        self.items.push(value);
        Ok(())
    }
    fn needs_step(&self) -> bool {
        self.pending.is_some()
            || self.merge.is_some()
            || self.items.len() == INLINE_PAGE_ITEMS
            || self.finishing && !self.complete
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
        summary: TextSummary,
    ) -> Result<()> {
        if let Some((destination, merge)) = &mut self.merge {
            merge.step(engine, source, mode, summary)?;
            if merge.out.complete {
                let root = merge
                    .out
                    .tail
                    .clone()
                    .ok_or(Error::Invalid("markup code empty merge"))?;
                if let Some(level) = *destination {
                    self.pending = Some((level, root));
                } else {
                    self.tail = Some(root);
                }
                self.merge = None;
            }
            return Ok(());
        }
        if let Some((level, root)) = self.pending.take() {
            if level >= SORT_LEVELS {
                return Err(Error::Invalid("markup code sort frontier bound"));
            }
            if level == self.frontier.len() {
                self.frontier.push(None);
            }
            if let Some(previous) = self.frontier[level].take() {
                self.merge = Some((Some(level + 1), Merge::new(previous, root)));
            } else {
                self.frontier[level] = Some(root);
            }
            return Ok(());
        }
        if self.items.len() == INLINE_PAGE_ITEMS || self.finishing && !self.items.is_empty() {
            self.items.sort_unstable_by_key(|value| key(*value));
            let values = self
                .items
                .drain(..)
                .map(|value| value.checkpoint())
                .collect();
            self.pending = Some((0, engine.code_leaf(source, mode, values, summary)?));
            return Ok(());
        }
        if self.finishing {
            while self.fold < self.frontier.len() {
                let value = self.frontier[self.fold].take();
                self.fold += 1;
                if let Some(value) = value {
                    if let Some(tail) = self.tail.take() {
                        self.merge = Some((None, Merge::new(value, tail)));
                        return Ok(());
                    }
                    self.tail = Some(value);
                }
            }
            self.complete = true;
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
pub(super) struct ParagraphScope {
    pub content: TextSummary,
    pub block: TextSummary,
    pub references: u64,
    pub has_pipe: bool,
}
pub(super) struct Survey {
    paragraph_start: TextSummary,
    pub resume: TextSummary,
    summary: TextSummary,
    seed: OpenParagraph,
    stream: CodeRunStream,
    buffer: String,
    runs: VecDeque<CodeRun>,
    sort: Sort,
    line_boundary: bool,
    scanned: bool,
    pub unsupported: bool,
    pub collect_code: bool,
    references: u64,
    block_extra: TextSummary,
    has_pipe: bool,
}
impl Survey {
    pub fn new(
        paragraph_start: TextSummary,
        resume: TextSummary,
        seed: OpenParagraph,
        stream: CodeRunStream,
        buffer: String,
        collect_code: bool,
    ) -> Result<Self> {
        if stream.point().bytes != resume.bytes
            || stream.point().utf16 != resume.utf16
            || buffer.len() > PROBE_BYTES
        {
            return Err(Error::Invalid("markup code survey captured point"));
        }
        Ok(Self {
            paragraph_start,
            resume,
            summary: resume,
            seed,
            stream,
            buffer,
            runs: VecDeque::new(),
            sort: Sort::new(),
            line_boundary: false,
            scanned: false,
            unsupported: false,
            collect_code,
            references: 0,
            block_extra: TextSummary::EMPTY,
            has_pipe: false,
        })
    }
    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len()
    }
    pub fn complete(&self) -> bool {
        self.sort.complete
    }
    pub fn finish(self) -> Result<(Option<CodeRef>, ParagraphScope)> {
        if !self.complete() || self.unsupported || !self.scanned || !self.runs.is_empty() {
            return Err(Error::Invalid("markup unfinished code survey"));
        }
        Ok((
            self.sort.tail,
            ParagraphScope {
                content: self.summary,
                block: self.summary.checked_add(self.block_extra)?,
                references: self.references,
                has_pipe: self.has_pipe,
            },
        ))
    }
    fn eof(&self, snapshot: &LogicalSnapshot) -> bool {
        self.paragraph_start
            .bytes
            .checked_add(self.summary.bytes)
            .and_then(|value| value.checked_add(self.buffer.len() as u64))
            == Some(snapshot.summary().bytes)
    }
    fn consume(&mut self, count: usize) -> Result<()> {
        let text = self
            .buffer
            .get(..count)
            .ok_or(Error::Invalid("markup code survey source boundary"))?;
        self.has_pipe |= text.as_bytes().contains(&b'|');
        self.references = self
            .references
            .checked_add(text.bytes().filter(|byte| *byte == b'[').count() as u64)
            .ok_or(Error::Invalid("markup scope reference count"))?;
        self.summary = self.summary.checked_add(TextSummary::of(text))?;
        self.buffer.drain(..count);
        Ok(())
    }
    fn read_more<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
    ) -> Result<()> {
        let at = self
            .paragraph_start
            .bytes
            .checked_add(self.summary.bytes)
            .and_then(|value| value.checked_add(self.buffer.len() as u64))
            .ok_or(Error::Invalid("markup code survey read position"))?;
        if at == snapshot.summary().bytes {
            return Ok(());
        }
        if at > snapshot.summary().bytes || self.buffer.len() >= PROBE_BYTES {
            self.unsupported = true;
            return Ok(());
        }
        let piece = engine.logical_source_piece(snapshot, at)?;
        let text = piece.text()?;
        let first = usize::try_from(at - piece.before.bytes)
            .map_err(|_| Error::Invalid("markup code survey piece offset"))?;
        let mut end = first
            .checked_add(PROBE_BYTES - self.buffer.len())
            .ok_or(Error::Invalid("markup code survey read extent"))?
            .min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        if first == end {
            self.unsupported = true;
            return Ok(());
        }
        self.buffer.push_str(&text[first..end]);
        Ok(())
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        check_cancel(cancelled)?;
        if self.unsupported || self.complete() {
            return Ok(());
        }
        if self.sort.needs_step() {
            return self
                .sort
                .step(engine, snapshot.origin(), mode, snapshot.summary());
        }
        for _ in 0..INLINE_PAGE_ITEMS {
            let Some(run) = self.runs.pop_front() else {
                break;
            };
            self.sort.push(run)?;
            if self.sort.needs_step() {
                return Ok(());
            }
        }
        if !self.runs.is_empty() {
            return Ok(());
        }
        if self.scanned {
            self.sort.finishing = true;
            return Ok(());
        }
        if self.line_boundary {
            let eof = self.eof(snapshot);
            let ending = if self.buffer.starts_with("\r\n") {
                2
            } else if self.buffer.starts_with('\n') {
                1
            } else if self.buffer.starts_with('\r') {
                if self.buffer.len() == 1 && !eof {
                    return self.read_more(engine, snapshot);
                }
                1
            } else {
                return Err(Error::Invalid("markup code actual line boundary"));
            };
            let following = self
                .seed
                .following_line(&self.buffer[ending..], eof)
                .ok_or(Error::Invalid("markup code paragraph follower"))?;
            match following {
                ParagraphFollowing::NeedMore => self.read_more(engine, snapshot)?,
                ParagraphFollowing::Continue { skip } => {
                    let count = ending
                        .checked_add(skip)
                        .ok_or(Error::Invalid("markup code indentation extent"))?;
                    let indentation = self
                        .buffer
                        .get(ending..count)
                        .ok_or(Error::Invalid("markup code indentation source"))?;
                    self.stream
                        .continue_line(&self.buffer[..ending], indentation)
                        .map_err(inline_error)?;
                    self.consume(count)?;
                    self.line_boundary = false;
                }
                ParagraphFollowing::End | ParagraphFollowing::Setext { .. } => {
                    // Code matching ends at the actual paragraph's content,
                    // before a setext delimiter or a following block.
                    if let ParagraphFollowing::Setext { consumed, .. } = following {
                        let last = ending
                            .checked_add(consumed)
                            .ok_or(Error::Invalid("markup scope setext extent"))?;
                        let delimiter = self
                            .buffer
                            .get(ending..last)
                            .ok_or(Error::Invalid("markup scope setext source"))?;
                        self.block_extra = TextSummary::of(delimiter);
                        self.references = self
                            .references
                            .checked_add(
                                delimiter.bytes().filter(|byte| *byte == b'[').count() as u64
                            )
                            .ok_or(Error::Invalid("markup scope setext reference count"))?;
                    }
                    self.stream
                        .finish_line(&self.buffer[..ending])
                        .map_err(inline_error)?;
                    self.consume(ending)?;
                    self.scanned = true;
                    self.line_boundary = false;
                }
            }
            return check_cancel(cancelled);
        }
        if self.buffer.is_empty() {
            self.read_more(engine, snapshot)?;
        }
        let eof = self.eof(snapshot);
        let result = (if self.collect_code {
            self.stream.feed(&self.buffer, eof, cancelled)
        } else {
            self.stream.scan_scope(&self.buffer, eof, cancelled)
        })
        .map_err(inline_error)?;
        if result.runs.len() > 128 {
            return Err(Error::Invalid("markup code survey run bound"));
        }
        self.consume(result.consumed)?;
        self.runs.extend(result.runs);
        self.line_boundary = result.line_boundary;
        self.scanned = result.complete;
        check_cancel(cancelled)
    }
}
pub(super) struct Lookup {
    open: CodeRun,
    scan: Walk,
}
impl Lookup {
    pub fn new(root: Option<CodeRef>, open: CodeRun) -> Result<Self> {
        let count = open.opening_count().map_err(inline_error)?;
        Ok(Self {
            open,
            scan: Walk::new(root, Some([count, open.end.bytes])),
        })
    }
    /// None is pending; Some(None) is an actual completed failed lookup.
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
    ) -> Result<Option<Option<PreparedCodePair>>> {
        if self.open.opening_count().map_err(inline_error)? == 0 {
            return Ok(Some(None));
        }
        match self
            .scan
            .next(engine, snapshot.origin(), mode, snapshot.summary())?
        {
            Next::Pending => Ok(None),
            Next::End => Ok(Some(None)),
            Next::Value(close) => {
                if close.count != self.open.opening_count().map_err(inline_error)? {
                    return Ok(Some(None));
                }
                Ok(Some(
                    prepare_code_pair(self.open, close).map_err(inline_error)?,
                ))
            }
        }
    }
}
