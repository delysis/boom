//! Long paragraph execution on the existing derived Index-page owner. Neither
//! opener pages nor annotations can change text or publish a document root.
//! Physical-line continuation uses the actual pinned first-pass decisions.
//! Unsupported earlier inline passes stop without granting completion to
//! their unfinished block; a copied source edge is never an EOF proof.
use super::*;
mod angle;
mod code;
mod link;
use angle::PendingAngle;
pub(super) use code::CodeRef;
use code::{Lookup, Survey};
use link::PendingLink;
use pulldown_cmark::paged::AngleGuard;
use pulldown_cmark::paged::{CodeRun, PreparedCodePair};
use pulldown_cmark::paged::{
    DelimiterReducer, DelimiterStack, InlinePoint, InlineRunError, InlineRunStream, InlineStop,
    InlineStyle, InlineStyleKind, InlineToken, OpenDelimiter, OpenParagraph, ParagraphFollowing,
};

const INLINE_PAGE_ITEMS: usize = 32;
fn inline_error(error: InlineRunError) -> Error {
    match error {
        InlineRunError::Cancelled => Error::Cancelled,
        InlineRunError::Invalid(value) => Error::Invalid(value),
    }
}
struct StackError(Error);
impl From<InlineRunError> for StackError {
    fn from(value: InlineRunError) -> Self {
        Self(inline_error(value))
    }
}
impl From<Error> for StackError {
    fn from(value: Error) -> Self {
        Self(value)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct OpenersRef {
    page: PageRef,
    count: u64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct OpenersPage {
    previous: Option<OpenersRef>,
    items: Vec<[u64; 7]>,
}
#[derive(Clone)]
struct OpenersChunk {
    previous: Option<OpenersRef>,
    items: Vec<OpenDelimiter>,
}
impl OpenersChunk {
    fn base(&self) -> u64 {
        self.previous.as_ref().map_or(0, |value| value.count)
    }
    fn end(&self) -> Result<u64> {
        self.base()
            .checked_add(self.items.len() as u64)
            .ok_or(Error::Invalid("markup opener count"))
    }
    fn contains(&self, index: u64) -> bool {
        index >= self.base() && index - self.base() < self.items.len() as u64
    }
    fn at(&self, index: u64) -> Result<OpenDelimiter> {
        let index = usize::try_from(
            index
                .checked_sub(self.base())
                .ok_or(Error::Invalid("markup opener index"))?,
        )
        .map_err(|_| Error::Invalid("markup opener address space"))?;
        self.items
            .get(index)
            .copied()
            .ok_or(Error::Invalid("markup opener page index"))
    }
}
struct Openers {
    tail: OpenersChunk,
    read: Option<OpenersChunk>,
    count: u64,
    source_limit: TextSummary,
}
impl Openers {
    fn new(source_limit: TextSummary) -> Self {
        Self {
            tail: OpenersChunk {
                previous: None,
                items: Vec::with_capacity(INLINE_PAGE_ITEMS),
            },
            read: None,
            count: 0,
            source_limit,
        }
    }
}
struct StackAccess<'a, S: PageProvider> {
    stack: &'a mut Openers,
    engine: &'a mut TextEngine<S>,
    source: &'a Revision,
    mode: MarkupMode,
}
impl<S: PageProvider> DelimiterStack for StackAccess<'_, S> {
    type Error = StackError;
    fn len(&self) -> u64 {
        self.stack.count
    }
    fn read(&mut self, index: u64) -> std::result::Result<Option<OpenDelimiter>, StackError> {
        if index >= self.stack.count {
            return Err(Error::Invalid("markup opener read extent").into());
        }
        if self.stack.tail.contains(index) {
            return Ok(Some(self.stack.tail.at(index)?));
        }
        if let Some(chunk) = &self.stack.read
            && chunk.contains(index)
        {
            return Ok(Some(chunk.at(index)?));
        }
        let previous = self
            .stack
            .read
            .as_ref()
            .filter(|chunk| index < chunk.base())
            .and_then(|chunk| chunk.previous.clone())
            .or_else(|| self.stack.tail.previous.clone())
            .ok_or(Error::Invalid("markup opener predecessor"))?;
        validate_page(&previous.page, PageKind::Index)?;
        let MarkNode::InlineOpeners(page) =
            self.engine
                .read_mark_page(self.source, self.mode, &previous.page)?
        else {
            return Err(Error::Invalid("markup opener page kind").into());
        };
        if page.items.len() != INLINE_PAGE_ITEMS {
            return Err(Error::Invalid("markup opener page count").into());
        }
        let base = page.previous.as_ref().map_or(0, |value| value.count);
        if base.checked_add(page.items.len() as u64) != Some(previous.count)
            || previous.count > self.stack.count
            || base % INLINE_PAGE_ITEMS as u64 != 0
            || previous.count % INLINE_PAGE_ITEMS as u64 != 0
        {
            return Err(Error::Invalid("markup opener page lineage").into());
        }
        if let Some(value) = &page.previous {
            validate_page(&value.page, PageKind::Index)?;
            if value.count >= previous.count {
                return Err(Error::Invalid("markup opener predecessor count").into());
            }
        }
        let mut items = Vec::with_capacity(INLINE_PAGE_ITEMS);
        let mut last = InlinePoint::default();
        for words in page.items {
            let value = OpenDelimiter::from_checkpoint(words)?;
            let end = InlinePoint {
                bytes: words[0]
                    .checked_add(words[2])
                    .ok_or(Error::Invalid("markup opener byte extent"))?,
                utf16: words[1]
                    .checked_add(words[2])
                    .ok_or(Error::Invalid("markup opener UTF16 extent"))?,
            };
            if words[0] < last.bytes
                || words[1] < last.utf16
                || end.bytes > self.stack.source_limit.bytes
                || end.utf16 > self.stack.source_limit.utf16
            {
                return Err(Error::Invalid("markup opener source order").into());
            }
            last = end;
            items.push(value);
        }
        self.stack.read = Some(OpenersChunk {
            previous: page.previous,
            items,
        });
        // One read per step, including long failed searches. The reducer is
        // resumed only after its host has yielded the actual reader lane.
        Ok(None)
    }
    fn truncate(&mut self, len: u64) -> std::result::Result<(), StackError> {
        if len > self.stack.count {
            return Err(Error::Invalid("markup opener truncate extent").into());
        }
        if len < self.stack.tail.base() {
            let chunk = self
                .stack
                .read
                .take()
                .ok_or(Error::Invalid("markup opener matched page missing"))?;
            if !chunk.contains(len) {
                return Err(Error::Invalid("markup opener matched page identity").into());
            }
            self.stack.tail = chunk;
        }
        let count = usize::try_from(
            len.checked_sub(self.stack.tail.base())
                .ok_or(Error::Invalid("markup opener truncate base"))?,
        )
        .map_err(|_| Error::Invalid("markup opener truncate address space"))?;
        self.stack.tail.items.truncate(count);
        self.stack.count = len;
        self.stack.read = None;
        Ok(())
    }
    fn push(&mut self, value: OpenDelimiter) -> std::result::Result<(), StackError> {
        if self.stack.tail.end()? != self.stack.count {
            return Err(Error::Invalid("markup opener live count").into());
        }
        if self.stack.tail.items.len() == INLINE_PAGE_ITEMS {
            let page = OpenersPage {
                previous: self.stack.tail.previous.clone(),
                items: self
                    .stack
                    .tail
                    .items
                    .iter()
                    .map(OpenDelimiter::checkpoint)
                    .collect(),
            };
            let page = self.engine.write_mark_page(
                self.source,
                self.mode,
                MarkNode::InlineOpeners(page),
            )?;
            self.stack.tail = OpenersChunk {
                previous: Some(OpenersRef {
                    page,
                    count: self.stack.count,
                }),
                items: Vec::with_capacity(INLINE_PAGE_ITEMS),
            };
        }
        self.stack.count = self
            .stack
            .count
            .checked_add(1)
            .ok_or(Error::Invalid("markup opener push count"))?;
        self.stack.tail.items.push(value);
        self.stack.read = None;
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct InlineRef {
    page: PageRef,
    height: u8,
    count: u64,
    first: [u64; 2],
    last: [u64; 2],
}
impl InlineRef {
    fn validate(&self, summary: TextSummary) -> Result<()> {
        validate_page(&self.page, PageKind::Index)?;
        TextSummary {
            bytes: self.first[0],
            utf16: self.first[1],
            lf_count: 0,
        }
        .validate()?;
        TextSummary {
            bytes: self.last[0],
            utf16: self.last[1],
            lf_count: 0,
        }
        .validate()?;
        if self.height > MARK_HEIGHT
            || self.count == 0
            || self.first[0] >= self.last[0]
            || self.first[1] >= self.last[1]
            || self.last[0] > summary.bytes
            || self.last[1] > summary.utf16
        {
            return Err(Error::Invalid("markup inline reference"));
        }
        Ok(())
    }
    fn overlaps(&self, first: u64, last: u64) -> bool {
        self.first[0] < last && self.last[0] > first
    }
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct InlineParagraph {
    pub root: Option<InlineRef>,
    pub heading: Option<u8>,
}
impl InlineParagraph {
    pub fn validate(&self, summary: TextSummary) -> Result<()> {
        if summary.bytes == 0 || self.heading.is_some_and(|level| !(1..=2).contains(&level)) {
            return Err(Error::Invalid("markup completed paragraph summary"));
        }
        if let Some(root) = &self.root {
            root.validate(summary)?;
        }
        Ok(())
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub(super) enum InlineRow {
    Style([u64; 5]),
    Media([u64; 6]),
    Fragment([u64; 4]),
}
fn media_row(value: [u64; 6]) -> Result<(Uuid, InlinePoint, InlinePoint)> {
    let [first, utf16_first, last, utf16_last, high, low] = value;
    let extent = decode_style([0, first, utf16_first, last, utf16_last])?;
    Ok((
        Uuid::from_u128((u128::from(high) << 64) | u128::from(low)),
        extent.start,
        extent.end,
    ))
}
fn row_extent(value: &InlineRow) -> Result<(InlinePoint, InlinePoint)> {
    match value {
        InlineRow::Style(words) => {
            let value = decode_style(*words)?;
            Ok((value.start, value.end))
        }
        InlineRow::Media(words) => {
            let (_, start, end) = media_row(*words)?;
            Ok((start, end))
        }
        InlineRow::Fragment([first, utf16_first, last, utf16_last]) => {
            let value = decode_style([0, *first, *utf16_first, *last, *utf16_last])?;
            if last - first > PROBE_BYTES as u64 {
                return Err(Error::Invalid("markup inline fragment bound"));
            }
            Ok((value.start, value.end))
        }
    }
}
fn style_words(style: InlineStyle) -> Result<[u64; 5]> {
    let kind = match style.kind {
        InlineStyleKind::Strong => 0,
        InlineStyleKind::Emphasis => 1,
        InlineStyleKind::Strike => 2,
        InlineStyleKind::Syntax => 3,
        InlineStyleKind::Code => 4,
        InlineStyleKind::Link => 5,
    };
    let words = [
        kind,
        style.start.bytes,
        style.start.utf16,
        style.end.bytes,
        style.end.utf16,
    ];
    decode_style(words)?;
    Ok(words)
}
fn decode_style(value: [u64; 5]) -> Result<InlineStyle> {
    let [kind, first, utf16_first, last, utf16_last] = value;
    let kind = match kind {
        0 => InlineStyleKind::Strong,
        1 => InlineStyleKind::Emphasis,
        2 => InlineStyleKind::Strike,
        3 => InlineStyleKind::Syntax,
        4 => InlineStyleKind::Code,
        5 => InlineStyleKind::Link,
        _ => return Err(Error::Invalid("markup inline style kind")),
    };
    if first >= last || utf16_first >= utf16_last || last - first < utf16_last - utf16_first {
        return Err(Error::Invalid("markup inline style extent"));
    }
    Ok(InlineStyle {
        kind,
        start: InlinePoint {
            bytes: first,
            utf16: utf16_first,
        },
        end: InlinePoint {
            bytes: last,
            utf16: utf16_last,
        },
    })
}
fn style_bounds(values: &[InlineRow]) -> Result<([u64; 2], [u64; 2])> {
    if values.is_empty() || values.len() > INLINE_PAGE_ITEMS {
        return Err(Error::Invalid("markup inline leaf bound"));
    }
    let mut first = [u64::MAX; 2];
    let mut last = [0; 2];
    for row in values {
        let (start, end) = row_extent(row)?;
        first[0] = first[0].min(start.bytes);
        first[1] = first[1].min(start.utf16);
        last[0] = last[0].max(end.bytes);
        last[1] = last[1].max(end.utf16);
    }
    Ok((first, last))
}
fn style_aggregate(page: PageRef, values: &[InlineRow]) -> Result<InlineRef> {
    let (first, last) = style_bounds(values)?;
    Ok(InlineRef {
        page,
        height: 0,
        count: values.len() as u64,
        first,
        last,
    })
}
fn branch_aggregate(
    page: PageRef,
    values: &[InlineRef],
    summary: TextSummary,
) -> Result<InlineRef> {
    if values.is_empty() || values.len() > MARK_FANOUT {
        return Err(Error::Invalid("markup inline branch bound"));
    }
    let height = values[0]
        .height
        .checked_add(1)
        .filter(|height| *height <= MARK_HEIGHT)
        .ok_or(Error::Invalid("markup inline branch height"))?;
    let mut count = 0u64;
    let mut first = [u64::MAX; 2];
    let mut last = [0; 2];
    for value in values {
        value.validate(summary)?;
        if value.height.checked_add(1) != Some(height) {
            return Err(Error::Invalid("markup inline child height"));
        }
        count = count
            .checked_add(value.count)
            .ok_or(Error::Invalid("markup inline aggregate count"))?;
        for index in 0..2 {
            first[index] = first[index].min(value.first[index]);
            last[index] = last[index].max(value.last[index]);
        }
    }
    Ok(InlineRef {
        page,
        height,
        count,
        first,
        last,
    })
}
impl<S: PageProvider> TextEngine<S> {
    fn inline_leaf(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<InlineRow>,
    ) -> Result<InlineRef> {
        // Validate before writing any derived frame, then bind its real page.
        let (first, last) = style_bounds(&values)?;
        let count = values.len() as u64;
        let page = self.write_mark_page(source, mode, MarkNode::InlineStyles(values))?;
        Ok(InlineRef {
            page,
            height: 0,
            count,
            first,
            last,
        })
    }
    fn inline_branch(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<InlineRef>,
        summary: TextSummary,
    ) -> Result<InlineRef> {
        let page = values
            .first()
            .ok_or(Error::Invalid("markup inline empty branch"))?
            .page
            .clone();
        let mut root = branch_aggregate(page, &values, summary)?;
        root.page = self.write_mark_page(source, mode, MarkNode::InlineBranch(values))?;
        Ok(root)
    }
}

struct StyleWrite {
    items: Vec<InlineRow>,
    frontier: Vec<Vec<InlineRef>>,
    pending: Option<(usize, InlineRef)>,
    finishing: bool,
    fold: usize,
    tail: Option<InlineRef>,
    complete: bool,
}
impl StyleWrite {
    fn new() -> Self {
        Self {
            items: Vec::with_capacity(INLINE_PAGE_ITEMS + 4),
            frontier: vec![Vec::new()],
            pending: None,
            finishing: false,
            fold: 0,
            tail: None,
            complete: false,
        }
    }
    fn append(&mut self, styles: Vec<InlineStyle>) -> Result<()> {
        if self.finishing || self.items.len() >= INLINE_PAGE_ITEMS || styles.len() > 4 {
            return Err(Error::Invalid("markup inline output step bound"));
        }
        for style in styles {
            self.items.push(InlineRow::Style(style_words(style)?));
        }
        Ok(())
    }
    fn append_media(&mut self, id: Uuid, start: InlinePoint, end: InlinePoint) -> Result<()> {
        if self.finishing || self.items.len() >= INLINE_PAGE_ITEMS {
            return Err(Error::Invalid("markup media output bound"));
        }
        let bits = id.as_u128();
        let words = [
            start.bytes,
            start.utf16,
            end.bytes,
            end.utf16,
            (bits >> 64) as u64,
            bits as u64,
        ];
        media_row(words)?;
        self.items.push(InlineRow::Media(words));
        Ok(())
    }
    fn append_fragment(&mut self, start: InlinePoint, end: InlinePoint) -> Result<()> {
        if self.finishing || self.items.len() >= INLINE_PAGE_ITEMS {
            return Err(Error::Invalid("markup inline fragment output bound"));
        }
        let row = InlineRow::Fragment([start.bytes, start.utf16, end.bytes, end.utf16]);
        row_extent(&row)?;
        self.items.push(row);
        Ok(())
    }
    fn needs_step(&self) -> bool {
        self.pending.is_some()
            || self.items.len() >= INLINE_PAGE_ITEMS
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
                return Err(Error::Invalid("markup inline frontier height"));
            }
            if level == self.frontier.len() {
                self.frontier.push(Vec::new());
            }
            self.frontier[level].push(value);
            if self.frontier[level].len() == MARK_FANOUT {
                let root = engine.inline_branch(
                    source,
                    mode,
                    std::mem::take(&mut self.frontier[level]),
                    summary,
                )?;
                self.pending = Some((level + 1, root));
                return Ok(());
            }
        }
        if self.items.len() >= INLINE_PAGE_ITEMS || self.finishing && !self.items.is_empty() {
            let count = self.items.len().min(INLINE_PAGE_ITEMS);
            let values = self.items.drain(..count).collect();
            let root = engine.inline_leaf(source, mode, values)?;
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
                    self.tail = Some(engine.inline_branch(source, mode, vec![value], summary)?);
                    return Ok(());
                }
                if usize::from(value.height) != level {
                    return Err(Error::Invalid("markup inline fold height"));
                }
                self.frontier[level].push(value);
            }
            let mut values = std::mem::take(&mut self.frontier[level]);
            self.fold += 1;
            if values.len() == 1 {
                self.tail = values.pop();
            } else {
                self.tail = Some(engine.inline_branch(source, mode, values, summary)?);
                return Ok(());
            }
        }
        self.complete = true;
        Ok(())
    }
}

struct PendingCode {
    run: CodeRun,
    collected: bool,
    lookup: Option<Lookup>,
    chosen: Option<Option<PreparedCodePair>>,
}
impl PendingCode {
    fn new(stream: &InlineRunStream) -> Result<Self> {
        let (start, escaped) = stream.code_run_start().map_err(inline_error)?;
        Ok(Self {
            run: CodeRun {
                start,
                end: start,
                count: 0,
                preceded_by_backslash: escaped,
            },
            collected: false,
            lookup: None,
            chosen: None,
        })
    }
}
pub(super) struct LongParagraph {
    start: TextSummary,
    summary: TextSummary,
    stream: InlineRunStream,
    reducer: DelimiterReducer,
    openers: Openers,
    styles: StyleWrite,
    buffer: String,
    tokens: VecDeque<InlineToken>,
    seed: OpenParagraph,
    line_boundary: bool,
    code_survey: Option<Survey>,
    code_root: Option<CodeRef>,
    code_known: bool,
    code_limit: Option<TextSummary>,
    code_pending: Option<PendingCode>,
    angle_guard: AngleGuard,
    angle_pending: Option<PendingAngle>,
    link_pending: Option<PendingLink>,
    survey_link: bool,
    heading: Option<u8>,
    heading_syntax: u64,
    prefix_open: bool,
    scanned: bool,
    complete: bool,
    unsupported: bool,
}
impl LongParagraph {
    pub fn new(
        seed: &OpenParagraph,
        start: TextSummary,
        initial: String,
        source: TextSummary,
        mode: MarkupMode,
    ) -> Result<Self> {
        if seed.start() != 0
            || !seed.containers().is_root()
            || !(PROBE_BYTES - 3..=PROBE_BYTES).contains(&initial.len())
        {
            return Err(Error::Invalid("markup long paragraph seed"));
        }
        let prefix_open = initial.starts_with('#');
        Ok(Self {
            start,
            summary: TextSummary::EMPTY,
            stream: seed.run_stream(),
            reducer: DelimiterReducer::new(mode.options()),
            openers: Openers::new(source),
            styles: StyleWrite::new(),
            buffer: initial,
            tokens: VecDeque::new(),
            seed: seed.clone(),
            line_boundary: false,
            code_survey: None,
            code_root: None,
            code_known: false,
            code_limit: None,
            code_pending: None,
            angle_guard: AngleGuard::default(),
            angle_pending: None,
            link_pending: None,
            survey_link: false,
            heading: None,
            heading_syntax: 0,
            prefix_open,
            scanned: false,
            complete: false,
            unsupported: false,
        })
    }
    pub fn complete(&self) -> bool {
        self.complete
    }
    pub fn unsupported(&self) -> bool {
        self.unsupported
    }
    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len() + self.code_survey.as_ref().map_or(0, Survey::buffered_bytes)
    }
    fn at_eof(&self, snapshot: &LogicalSnapshot) -> bool {
        self.start
            .bytes
            .checked_add(self.summary.bytes)
            .and_then(|value| value.checked_add(self.buffer.len() as u64))
            == Some(snapshot.summary().bytes)
    }
    fn read_more<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
    ) -> Result<bool> {
        let at = self
            .start
            .bytes
            .checked_add(self.summary.bytes)
            .and_then(|value| value.checked_add(self.buffer.len() as u64))
            .ok_or(Error::Invalid("markup paragraph source cursor"))?;
        if at == snapshot.summary().bytes {
            return Ok(false);
        }
        if at > snapshot.summary().bytes || self.buffer.len() > PROBE_BYTES {
            return Err(Error::Invalid("markup paragraph source extent"));
        }
        let free = PROBE_BYTES - self.buffer.len();
        if free == 0 {
            self.unsupported = true;
            return Ok(false);
        }
        let piece = engine.logical_source_piece(snapshot, at)?;
        let first = usize::try_from(at - piece.before.bytes)
            .map_err(|_| Error::Invalid("markup paragraph piece offset"))?;
        let text = piece.text()?;
        let mut end = first
            .checked_add(free)
            .ok_or(Error::Invalid("markup paragraph piece extent"))?
            .min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        if first == end {
            self.unsupported = true;
            return Ok(false);
        }
        self.buffer.push_str(&text[first..end]);
        Ok(true)
    }
    fn consume(&mut self, count: usize) -> Result<()> {
        if count > self.buffer.len() || !self.buffer.is_char_boundary(count) {
            return Err(Error::Invalid("markup paragraph consume boundary"));
        }
        self.summary = self
            .summary
            .checked_add(TextSummary::of(&self.buffer[..count]))?;
        self.buffer.drain(..count);
        Ok(())
    }
    fn following<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
    ) -> Result<()> {
        let eof = self.at_eof(snapshot);
        let ending = if self.buffer.starts_with("\r\n") {
            2
        } else if self.buffer.starts_with('\n') {
            1
        } else if self.buffer.starts_with('\r') {
            if self.buffer.len() == 1 && !eof {
                self.read_more(engine, snapshot)?;
                return Ok(());
            }
            1
        } else {
            return Err(Error::Invalid("markup actual paragraph line ending"));
        };
        let decision = self
            .seed
            .following_line(&self.buffer[ending..], eof)
            .ok_or(Error::Invalid("markup pinned paragraph follower"))?;
        match decision {
            ParagraphFollowing::NeedMore => {
                self.read_more(engine, snapshot)?;
            }
            ParagraphFollowing::Continue { skip } => {
                let count = ending
                    .checked_add(skip)
                    .ok_or(Error::Invalid("markup paragraph indentation extent"))?;
                let indentation = self
                    .buffer
                    .get(ending..count)
                    .ok_or(Error::Invalid("markup paragraph indentation source"))?;
                self.stream
                    .continue_line(&self.buffer[..ending], indentation)
                    .map_err(inline_error)?;
                self.consume(count)?;
                self.line_boundary = false;
                self.prefix_open = false;
            }
            ParagraphFollowing::End | ParagraphFollowing::Setext { .. } => {
                self.stream
                    .finish_line(&self.buffer[..ending])
                    .map_err(inline_error)?;
                let count = if let ParagraphFollowing::Setext { consumed, level } = decision {
                    self.heading = Some(level);
                    if mode == MarkupMode::Style && self.heading_syntax > 0 {
                        self.styles.append(vec![InlineStyle {
                            kind: InlineStyleKind::Syntax,
                            start: InlinePoint::default(),
                            end: InlinePoint {
                                bytes: self.heading_syntax,
                                utf16: self.heading_syntax,
                            },
                        }])?;
                    }
                    ending
                        .checked_add(consumed)
                        .ok_or(Error::Invalid("markup setext source extent"))?
                } else {
                    ending
                };
                self.consume(count)?;
                self.scanned = true;
                self.line_boundary = false;
            }
        }
        Ok(())
    }
    fn step_code<S: PageProvider>(
        &mut self,
        pending: &mut PendingCode,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
    ) -> Result<bool> {
        if !pending.collected {
            if self.buffer.is_empty() && !self.at_eof(snapshot) {
                self.read_more(engine, snapshot)?;
                return Ok(false);
            }
            let ticks = self.buffer.bytes().take_while(|byte| *byte == b'`').count();
            let amount = u64::try_from(ticks)
                .map_err(|_| Error::Invalid("markup code run address space"))?;
            pending.run.count = pending
                .run
                .count
                .checked_add(amount)
                .ok_or(Error::Invalid("markup code run count"))?;
            pending.run.end.bytes = pending
                .run
                .end
                .bytes
                .checked_add(amount)
                .ok_or(Error::Invalid("markup code run byte"))?;
            pending.run.end.utf16 = pending
                .run
                .end
                .utf16
                .checked_add(amount)
                .ok_or(Error::Invalid("markup code run UTF16"))?;
            self.consume(ticks)?;
            if self.buffer.is_empty() && !self.at_eof(snapshot) {
                return Ok(false);
            }
            CodeRun::from_checkpoint(pending.run.checkpoint()).map_err(inline_error)?;
            pending.collected = true;
            pending.lookup = Some(Lookup::new(self.code_root.clone(), pending.run)?);
            return Ok(false);
        }
        if pending.chosen.is_none() {
            let lookup = pending
                .lookup
                .as_mut()
                .ok_or(Error::Invalid("markup code lookup missing"))?;
            if let Some(chosen) = lookup.step(engine, snapshot, mode)? {
                if let Some(pair) = chosen {
                    let limit = self
                        .code_limit
                        .ok_or(Error::Invalid("markup code paragraph limit missing"))?;
                    if pair.end.bytes > limit.bytes || pair.end.utf16 > limit.utf16 {
                        return Err(Error::Invalid(
                            "markup code closer outside actual paragraph",
                        ));
                    }
                }
                pending.chosen = Some(chosen);
                pending.lookup = None;
            }
            return Ok(false);
        }
        let chosen = pending
            .chosen
            .ok_or(Error::Invalid("markup code chosen result missing"))?;
        let end = chosen.map_or(pending.run.end, |pair| pair.end);
        if self.summary.bytes < end.bytes {
            if self.buffer.is_empty() {
                if !self.read_more(engine, snapshot)? {
                    return Err(Error::Invalid("markup code ended before proven closer"));
                }
                return Ok(false);
            }
            let count =
                usize::try_from((end.bytes - self.summary.bytes).min(self.buffer.len() as u64))
                    .map_err(|_| Error::Invalid("markup code skip address space"))?;
            self.consume(count)?;
            return Ok(false);
        }
        if self.summary.bytes != end.bytes || self.summary.utf16 != end.utf16 {
            return Err(Error::Invalid("markup consumed code source counters"));
        }
        self.stream
            .resume_code(pending.run, chosen)
            .map_err(inline_error)?;
        if mode == MarkupMode::Style
            && let Some(pair) = chosen
        {
            self.styles.append(vec![
                InlineStyle {
                    kind: InlineStyleKind::Code,
                    start: pair.start,
                    end: pair.end,
                },
                InlineStyle {
                    kind: InlineStyleKind::Syntax,
                    start: pair.start,
                    end: pair.opening_end,
                },
                InlineStyle {
                    kind: InlineStyleKind::Syntax,
                    start: pair.closing_start,
                    end: pair.end,
                },
            ])?;
        }
        Ok(true)
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        check_cancel(cancelled)?;
        if self.complete || self.unsupported {
            return Ok(());
        }
        if let Some(mut survey) = self.code_survey.take() {
            survey.step(engine, snapshot, mode, cancelled)?;
            if survey.unsupported {
                self.unsupported = true;
            } else if survey.complete() {
                let resume = survey.resume;
                let for_code = survey.collect_code;
                let (root, limit) = survey.finish()?;
                if self.code_limit.is_some_and(|old| old != limit) {
                    return Err(Error::Invalid("markup paragraph scope changed"));
                }
                self.summary = resume;
                self.buffer.clear();
                self.code_limit = Some(limit);
                if for_code {
                    self.code_root = root;
                    self.code_known = true;
                    self.code_pending = Some(PendingCode::new(&self.stream)?);
                } else if self.survey_link {
                    self.begin_link()?;
                    self.survey_link = false;
                } else {
                    self.angle_pending = Some(PendingAngle::new(
                        &self.stream,
                        self.summary,
                        self.angle_guard.clone(),
                    )?);
                }
            } else {
                self.code_survey = Some(survey);
            }
            return check_cancel(cancelled);
        }
        if self.styles.needs_step() {
            self.styles
                .step(engine, snapshot.origin(), mode, snapshot.summary())?;
            if self.styles.complete {
                self.complete = true;
            }
            return Ok(());
        }
        if let Some(mut pending) = self.angle_pending.take() {
            if !self.step_angle(&mut pending, engine, snapshot, mode, cancelled)? {
                self.angle_pending = Some(pending);
            }
            return check_cancel(cancelled);
        }
        if let Some(mut pending) = self.link_pending.take() {
            if !self.step_link(&mut pending, engine, snapshot, mode, cancelled)? {
                self.link_pending = Some(pending);
            }
            return check_cancel(cancelled);
        }
        if let Some(mut pending) = self.code_pending.take() {
            if !self.step_code(&mut pending, engine, snapshot, mode)? {
                self.code_pending = Some(pending);
            }
            return check_cancel(cancelled);
        }
        if !self.reducer.is_idle() {
            let mut stack = StackAccess {
                stack: &mut self.openers,
                engine,
                source: snapshot.origin(),
                mode,
            };
            let progress = self.reducer.step(&mut stack).map_err(|error| error.0)?;
            self.styles.append(progress.styles)?;
            return Ok(());
        }
        if let Some(token) = self.tokens.pop_front() {
            // The media grammar has no emphasis presentation. Its exact
            // stream must still exclude brackets/code/HTML before completion,
            // but it needs no duplicate opener/annotation archive.
            if mode == MarkupMode::Media {
                return Ok(());
            }
            self.reducer
                .begin(token, self.openers.count)
                .map_err(inline_error)?;
            return Ok(());
        }
        if self.line_boundary {
            return self.following(engine, snapshot, mode);
        }
        if self.scanned {
            self.styles.finishing = true;
            self.styles
                .step(engine, snapshot.origin(), mode, snapshot.summary())?;
            if self.styles.complete {
                self.complete = true;
            }
            return Ok(());
        }
        if self.buffer.is_empty() {
            self.read_more(engine, snapshot)?;
        }
        let eof = self.at_eof(snapshot);
        let scanned = self
            .stream
            .feed(&self.buffer, eof, cancelled)
            .map_err(inline_error)?;
        if scanned.consumed > self.buffer.len() || scanned.tokens.len() > 128 {
            return Err(Error::Invalid("markup paragraph token step bound"));
        }
        if self.prefix_open {
            for &byte in &self.buffer.as_bytes()[..scanned.consumed] {
                if matches!(byte, b'#' | b' ' | b'\t') {
                    self.heading_syntax = self
                        .heading_syntax
                        .checked_add(1)
                        .ok_or(Error::Invalid("markup heading prefix extent"))?;
                } else {
                    self.prefix_open = false;
                    break;
                }
            }
        }
        self.consume(scanned.consumed)?;
        self.tokens.extend(scanned.tokens);
        self.scanned = scanned.complete;
        self.line_boundary = scanned.stopped == Some(InlineStop::ParagraphBoundary);
        if scanned.stopped == Some(InlineStop::OtherInlinePass) {
            if self.buffer.starts_with('`') {
                if self.code_known {
                    self.code_pending = Some(PendingCode::new(&self.stream)?);
                } else {
                    let stream = self.stream.code_survey().map_err(inline_error)?;
                    self.code_survey = Some(Survey::new(
                        self.start,
                        self.summary,
                        self.seed.clone(),
                        stream,
                        std::mem::take(&mut self.buffer),
                        true,
                    )?);
                }
            } else if self.buffer.starts_with('<') {
                if self.code_limit.is_some() {
                    self.angle_pending = Some(PendingAngle::new(
                        &self.stream,
                        self.summary,
                        self.angle_guard.clone(),
                    )?);
                } else {
                    let stream = self.stream.code_survey().map_err(inline_error)?;
                    self.code_survey = Some(Survey::new(
                        self.start,
                        self.summary,
                        self.seed.clone(),
                        stream,
                        std::mem::take(&mut self.buffer),
                        false,
                    )?);
                }
            } else if self.buffer.starts_with('[') {
                if self.code_limit.is_some() {
                    self.begin_link()?;
                } else {
                    let stream = self.stream.code_survey().map_err(inline_error)?;
                    self.survey_link = true;
                    self.code_survey = Some(Survey::new(
                        self.start,
                        self.summary,
                        self.seed.clone(),
                        stream,
                        std::mem::take(&mut self.buffer),
                        false,
                    )?);
                }
            } else {
                self.unsupported = true;
            }
        }
        if self.scanned
            && (!self.buffer.is_empty()
                || self.start.checked_add(self.summary)? != snapshot.summary())
        {
            return Err(Error::Invalid("markup paragraph completion extent"));
        }
        check_cancel(cancelled)
    }
    pub fn finish(self) -> Result<(TextSummary, InlineParagraph, String)> {
        if !self.complete
            || self.unsupported
            || self.line_boundary
            || !self.tokens.is_empty()
            || !self.reducer.is_idle()
            || self.code_survey.is_some()
            || self.code_pending.is_some()
            || self.angle_pending.is_some()
            || self.link_pending.is_some()
        {
            return Err(Error::Invalid("markup paragraph not joined"));
        }
        let value = InlineParagraph {
            root: self.styles.tail,
            heading: self.heading,
        };
        value.validate(self.summary)?;
        Ok((self.summary, value, self.buffer))
    }
}

pub(super) struct InlineScan {
    before: TextSummary,
    summary: TextSummary,
    first: u64,
    last: u64,
    stack: Vec<InlineRef>,
}
impl InlineScan {
    pub fn new(
        value: &InlineParagraph,
        before: TextSummary,
        summary: TextSummary,
        window: &Range<u64>,
    ) -> Result<Self> {
        value.validate(summary)?;
        let first = window.start.saturating_sub(before.bytes);
        let last = window.end.saturating_sub(before.bytes).min(summary.bytes);
        Ok(Self {
            before,
            summary,
            first,
            last,
            stack: value
                .root
                .as_ref()
                .filter(|value| value.overlaps(first, last))
                .cloned()
                .into_iter()
                .collect(),
        })
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
        styles: &mut Vec<InlineStyle>,
        media: &mut Vec<(Uuid, InlinePoint, InlinePoint)>,
        fragments: &mut VecDeque<(InlinePoint, InlinePoint)>,
    ) -> Result<bool> {
        let Some(root) = self.stack.pop() else {
            return Ok(true);
        };
        root.validate(self.summary)?;
        match engine.read_mark_page(source, mode, &root.page)? {
            MarkNode::InlineStyles(values) if root.height == 0 => {
                let actual = style_aggregate(root.page.clone(), &values)?;
                if actual != root {
                    return Err(Error::Invalid("markup inline leaf aggregate"));
                }
                for row in values {
                    let (mut start, mut end) = row_extent(&row)?;
                    if start.bytes < self.last && end.bytes > self.first {
                        start.bytes = start
                            .bytes
                            .checked_add(self.before.bytes)
                            .ok_or(Error::Invalid("markup inline source byte"))?;
                        end.bytes = end
                            .bytes
                            .checked_add(self.before.bytes)
                            .ok_or(Error::Invalid("markup inline source byte"))?;
                        start.utf16 = start
                            .utf16
                            .checked_add(self.before.utf16)
                            .ok_or(Error::Invalid("markup inline source UTF16"))?;
                        end.utf16 = end
                            .utf16
                            .checked_add(self.before.utf16)
                            .ok_or(Error::Invalid("markup inline source UTF16"))?;
                        match row {
                            InlineRow::Style(words) => {
                                if styles.len() == 20_000 {
                                    return Err(Error::Invalid(
                                        "markup window exceeds 20000 inline styles",
                                    ));
                                }
                                styles.push(InlineStyle {
                                    kind: decode_style(words)?.kind,
                                    start,
                                    end,
                                });
                            }
                            InlineRow::Media(words) => {
                                if media.len() == 4096 {
                                    return Err(Error::Invalid(
                                        "markup window exceeds 4096 media ranges",
                                    ));
                                }
                                media.push((media_row(words)?.0, start, end));
                            }
                            InlineRow::Fragment(_) => {
                                if fragments.len() == INLINE_PAGE_ITEMS {
                                    return Err(Error::Invalid("markup pending inline fragments"));
                                }
                                fragments.push_back((start, end));
                            }
                        }
                    }
                }
            }
            MarkNode::InlineBranch(values) if root.height > 0 => {
                if branch_aggregate(root.page.clone(), &values, self.summary)? != root {
                    return Err(Error::Invalid("markup inline branch aggregate"));
                }
                self.stack.extend(
                    values
                        .into_iter()
                        .rev()
                        .filter(|value| value.overlaps(self.first, self.last)),
                );
            }
            _ => return Err(Error::Invalid("markup inline projection page kind")),
        }
        Ok(self.stack.is_empty())
    }
}
