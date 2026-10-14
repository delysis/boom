//! Derived Markdown pages on the same append-page provider as the source.
//! Nothing here can publish, mutate, or rename a text root. The two option sets
//! stay distinct because the existing styling/media parsers have that contract.
use super::*;
use crate::logical::{MarkupSource, difference};
use pulldown_cmark::paged::{
    BlockCarry, FenceContinuation, HtmlBlockWork, HtmlContinuation, HtmlOpening, HtmlOpeningChoice,
    HtmlOpeningStatus, PROBE_BYTES, ParsedReference, probe_continuing_blocks, reference_label_hash,
    reference_labels_equal,
};
use pulldown_cmark::{Options, RefDefs};
use std::sync::Mutex;

// Container references add two bounded carry descriptors to a mark node.
// Eight entries leave room for the largest generated descriptor/definition
// shape inside the unchanged 16KiB Index-page limit.
mod inline;
mod references;
use inline::{InlineParagraph, InlineRef, InlineScan, LongParagraph};
use references::ReferencePass;

const MARK_FANOUT: usize = 8;
const MARK_HEIGHT: u8 = 12;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum MarkupMode {
    Style,
    Media,
}
impl MarkupMode {
    pub(super) fn slot(self) -> usize {
        match self {
            Self::Style => 0,
            Self::Media => 1,
        }
    }
    pub fn options(self) -> Options {
        match self {
            Self::Style => {
                Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS
            }
            Self::Media => Options::empty(),
        }
    }
}

/// Only worker calls lock this. Native edits merely share its Arc. Two handles
/// provide a convergence base even if an older captured worker finishes after
/// later typing. Exact Undo snapshots retain their own already-proved index.
#[derive(Default)]
pub(super) struct MarkupMemo(Mutex<[Option<Arc<MarkupIndex>>; 2]>);
impl MarkupMemo {
    pub fn latest(&self, mode: MarkupMode) -> Result<Option<Arc<MarkupIndex>>> {
        Ok(self
            .0
            .lock()
            .map_err(|_| Error::Invalid("markup memo lock"))?[mode.slot()]
        .clone())
    }
    pub fn completed(&self, value: Arc<MarkupIndex>) -> Result<()> {
        let slot = value.mode.slot();
        self.0
            .lock()
            .map_err(|_| Error::Invalid("markup memo lock"))?[slot] = Some(value);
        Ok(())
    }
}

/// Source translation and retained side for splitting an unchanged interval.
#[derive(Clone, Copy)]
struct SplitMapping {
    old_base: u64,
    new_base: u64,
    keep_prefix: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "state",
    content = "value",
    rename_all = "snake_case",
    deny_unknown_fields
)]
enum Carry {
    Root,
    Fence([u64; 4]),
    Html(HtmlCarry),
    Containers(ContainerCarry),
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HtmlCarry {
    state: [u64; 4],
    #[serde(default, skip_serializing_if = "Option::is_none")]
    opening: Option<HtmlOpeningDependency>,
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HtmlOpeningDependency {
    rewind: u64,
    remaining: u64,
}
impl HtmlCarry {
    fn fixed(state: [u64; 4]) -> Self {
        Self {
            state,
            opening: None,
        }
    }
    fn dependent(state: [u64; 4], prefix: u64, decision: u64) -> Result<Self> {
        let remaining = decision
            .checked_sub(prefix)
            .ok_or(Error::Invalid("markup HTML opening decision extent"))?;
        let value = Self {
            state,
            opening: (remaining > 0).then_some(HtmlOpeningDependency {
                rewind: prefix,
                remaining,
            }),
        };
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<()> {
        HtmlContinuation::from_checkpoint(self.state)
            .ok_or(Error::Invalid("markup HTML checkpoint"))?;
        if self.opening.as_ref().is_some_and(|value| {
            self.state[0] != 0
                || value.rewind == 0
                || value.remaining == 0
                || value.rewind.checked_add(value.remaining).is_none()
        }) {
            return Err(Error::Invalid("markup HTML opening dependency"));
        }
        Ok(())
    }
    fn advance(&self, state: [u64; 4], bytes: u64) -> Result<Self> {
        let opening = match &self.opening {
            Some(value) if value.remaining > bytes => Some(HtmlOpeningDependency {
                rewind: value
                    .rewind
                    .checked_add(bytes)
                    .ok_or(Error::Invalid("markup HTML opening rewind"))?,
                remaining: value.remaining - bytes,
            }),
            _ => None,
        };
        let value = Self { state, opening };
        value.validate()?;
        Ok(value)
    }
}
impl PartialEq for Carry {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Root, Self::Root) => true,
            (Self::Fence(a), Self::Fence(b)) => a == b,
            (Self::Html(a), Self::Html(b)) => a == b,
            (Self::Containers(a), Self::Containers(b)) => {
                a.root.count == b.root.count
                    && a.begin_list_item == b.begin_list_item
                    && a.last_line_blank == b.last_line_blank
                    && a.digest == b.digest
            }
            _ => false,
        }
    }
}
impl Eq for Carry {}
impl Carry {
    fn validate(&self) -> Result<()> {
        if let Self::Fence(value) = self {
            FenceContinuation::from_checkpoint(*value)
                .ok_or(Error::Invalid("markup fence checkpoint"))?;
        }
        if let Self::Containers(value) = self {
            value.validate()?;
        }
        if let Self::Html(value) = self {
            value.validate()?;
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ContainerRef {
    page: PageRef,
    height: u8,
    count: u32,
}
impl ContainerRef {
    fn validate(&self) -> Result<()> {
        validate_page(&self.page, PageKind::Index)?;
        if self.height > MARK_HEIGHT || self.count == 0 || self.count as usize > PROBE_BYTES {
            return Err(Error::Invalid("markup container reference"));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ContainerCarry {
    root: ContainerRef,
    digest: String,
    begin_list_item: bool,
    last_line_blank: bool,
}
impl ContainerCarry {
    fn validate(&self) -> Result<()> {
        self.root.validate()?;
        if self.digest.len() != 64
            || !self
                .digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(Error::Invalid("markup container digest"));
        }
        Ok(())
    }
}

fn container_hasher(count: usize, begin: bool, blank: bool) -> Sha256 {
    let mut hash = Sha256::new();
    hash.update(b"MCC1");
    hash.update((count as u64).to_le_bytes());
    hash.update([u8::from(begin), u8::from(blank)]);
    hash
}
fn hash_container_words(hash: &mut Sha256, values: &[[u64; 4]]) {
    for value in values {
        for word in value {
            hash.update(word.to_le_bytes());
        }
    }
}

/// One existing producer continuation. It writes at most one carry page per
/// call, keeping only the captured grammar spine, one 128-word chunk, and a
/// height-bounded frontier. It has no source publication right of its own.
struct ContainerWrite {
    value: BlockCarry,
    next: usize,
    hash: Sha256,
    frontier: Vec<Vec<ContainerRef>>,
    pending: Option<(usize, ContainerRef)>,
    fold_level: usize,
    tail: Option<ContainerRef>,
    ready: Option<Carry>,
}
impl ContainerWrite {
    fn new(value: BlockCarry) -> Result<Self> {
        let count = value.checkpoint_len();
        if value.is_root() || count == 0 || count > PROBE_BYTES {
            return Err(Error::Invalid("markup container spine bound"));
        }
        let (begin, blank) = value.checkpoint_flags();
        Ok(Self {
            value,
            next: 0,
            hash: container_hasher(count, begin, blank),
            frontier: vec![Vec::new()],
            pending: None,
            fold_level: 0,
            tail: None,
            ready: None,
        })
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
    ) -> Result<bool> {
        if self.ready.is_some() {
            return Ok(true);
        }
        if let Some((level, value)) = self.pending.take() {
            if level > usize::from(MARK_HEIGHT) {
                return Err(Error::Invalid("markup container tree bound"));
            }
            if level == self.frontier.len() {
                self.frontier.push(Vec::new());
            }
            self.frontier
                .get_mut(level)
                .ok_or(Error::Invalid("markup container frontier"))?
                .push(value);
            if self.frontier[level].len() == MARK_FANOUT {
                let value = engine.container_branch(
                    source,
                    mode,
                    std::mem::take(&mut self.frontier[level]),
                )?;
                self.pending = Some((level + 1, value));
                return Ok(false);
            }
        }
        if self.next < self.value.checkpoint_len() {
            let words = self
                .value
                .checkpoint_chunk(self.next)
                .ok_or(Error::Invalid("markup container chunk"))?;
            if words.is_empty() || words.len() > 128 {
                return Err(Error::Invalid("markup container chunk bound"));
            }
            let count = u32::try_from(words.len())
                .map_err(|_| Error::Invalid("markup container chunk count"))?;
            hash_container_words(&mut self.hash, &words);
            let page = engine.write_mark_page(source, mode, MarkNode::Containers(words))?;
            self.next = self
                .next
                .checked_add(count as usize)
                .ok_or(Error::Invalid("markup container cursor"))?;
            self.pending = Some((
                0,
                ContainerRef {
                    page,
                    height: 0,
                    count,
                },
            ));
            return Ok(false);
        }
        // Finish the sparse frontier without emitting a whole spine in one
        // turn. Raising a short tail or joining a level each writes one page.
        while self.fold_level < self.frontier.len() {
            let level = self.fold_level;
            if self.frontier[level].is_empty() {
                self.fold_level += 1;
                continue;
            }
            if let Some(value) = self.tail.take() {
                if usize::from(value.height) < level {
                    self.tail = Some(engine.container_branch(source, mode, vec![value])?);
                    return Ok(false);
                }
                if usize::from(value.height) != level {
                    return Err(Error::Invalid("markup container fold height"));
                }
                self.frontier[level].push(value);
            }
            let mut values = std::mem::take(&mut self.frontier[level]);
            self.fold_level += 1;
            if values.len() == 1 {
                self.tail = values.pop();
            } else {
                self.tail = Some(engine.container_branch(source, mode, values)?);
                return Ok(false);
            }
        }
        let root = self
            .tail
            .take()
            .ok_or(Error::Invalid("markup missing container root"))?;
        if root.count as usize != self.value.checkpoint_len() {
            return Err(Error::Invalid("markup container output count"));
        }
        let (begin_list_item, last_line_blank) = self.value.checkpoint_flags();
        let digest = format!("{:x}", std::mem::take(&mut self.hash).finalize());
        self.ready = Some(Carry::Containers(ContainerCarry {
            root,
            digest,
            begin_list_item,
            last_line_blank,
        }));
        Ok(true)
    }
    fn finish(self) -> Result<(Carry, BlockCarry)> {
        Ok((
            self.ready
                .ok_or(Error::Invalid("markup container write unjoined"))?,
            self.value,
        ))
    }
}

/// A container spine is loaded one derived page per host quantum. It is not
/// an eagerly allocated per-line index or a separately authoritative source.
struct ContainerLoad {
    expected: ContainerCarry,
    stack: Vec<ContainerRef>,
    values: Vec<[u64; 4]>,
    hash: Sha256,
    ready: Option<BlockCarry>,
}
impl ContainerLoad {
    fn new(expected: ContainerCarry) -> Result<Self> {
        expected.validate()?;
        let hash = container_hasher(
            expected.root.count as usize,
            expected.begin_list_item,
            expected.last_line_blank,
        );
        Ok(Self {
            stack: vec![expected.root.clone()],
            values: Vec::new(),
            hash,
            expected,
            ready: None,
        })
    }
    fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: &Revision,
        mode: MarkupMode,
    ) -> Result<bool> {
        let Some(root) = self.stack.pop() else {
            return Ok(true);
        };
        root.validate()?;
        match engine.read_mark_page(source, mode, &root.page)? {
            MarkNode::Containers(values)
                if root.height == 0 && !values.is_empty() && values.len() <= 128 =>
            {
                if values.len() != root.count as usize
                    || self
                        .values
                        .len()
                        .checked_add(values.len())
                        .is_none_or(|count| count > self.expected.root.count as usize)
                {
                    return Err(Error::Invalid("markup container leaf count"));
                }
                hash_container_words(&mut self.hash, &values);
                self.values.extend(values);
            }
            MarkNode::ContainerBranch(values)
                if root.height > 0 && !values.is_empty() && values.len() <= MARK_FANOUT =>
            {
                let mut count = 0u32;
                for value in &values {
                    value.validate()?;
                    if value.height.checked_add(1) != Some(root.height) {
                        return Err(Error::Invalid("markup container branch height"));
                    }
                    count = count
                        .checked_add(value.count)
                        .ok_or(Error::Invalid("markup container count"))?;
                }
                if count != root.count {
                    return Err(Error::Invalid("markup container branch count"));
                }
                self.stack.extend(values.into_iter().rev());
            }
            _ => return Err(Error::Invalid("markup container page shape")),
        }
        if self.stack.is_empty() {
            if self.values.len() != self.expected.root.count as usize
                || format!("{:x}", self.hash.clone().finalize()) != self.expected.digest
            {
                return Err(Error::Invalid("markup container content mismatch"));
            }
            self.ready = Some(
                BlockCarry::from_checkpoint(
                    &self.values,
                    self.expected.begin_list_item,
                    self.expected.last_line_blank,
                )
                .ok_or(Error::Invalid("markup container grammar state"))?,
            );
            return Ok(true);
        }
        Ok(false)
    }
    fn finish(self) -> Result<BlockCarry> {
        self.ready
            .ok_or(Error::Invalid("markup container load unjoined"))
    }
}
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
struct Labels([u64; 4]);
impl Labels {
    fn add(&mut self, hash: u64) {
        for shift in [0, 16, 32, 48] {
            let bit = ((hash >> shift) & 255) as usize;
            self.0[bit / 64] |= 1u64 << (bit % 64);
        }
    }
    fn contains(self, hash: u64) -> bool {
        [0, 16, 32, 48].into_iter().all(|shift| {
            let bit = ((hash >> shift) & 255) as usize;
            self.0[bit / 64] & (1u64 << (bit % 64)) != 0
        })
    }
    fn union(mut self, other: Self) -> Self {
        for (a, b) in self.0.iter_mut().zip(other.0) {
            *a |= b;
        }
        self
    }
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DefinitionCandidate {
    hash: u64,
    start: u32,
    end: u32,
    cost: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DefinitionRef {
    page: PageRef,
    height: u8,
    count: u64,
    labels: Labels,
    max_cost: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Segment {
    summary: TextSummary,
    incoming: Carry,
    outgoing: Carry,
    /// A root-bounded complete input can be reparsed with global definitions.
    parsed: bool,
    reference_slots: u64,
    /// Literal range relative to this segment, as returned by the first pass.
    code: Option<(u32, u32)>,
    /// Completed paged inline output for one actual long paragraph.
    inline: Option<InlineParagraph>,
    /// Exact root paragraph scope withheld until global first definitions join.
    pending_inline: bool,
    /// Its chosen inline tree depends on reference existence/first definitions.
    dependent_inline: bool,
    definitions: Option<DefinitionRef>,
    definition_base: u32,
    // At most two <=8KiB bitmaps for exact first-pass root boundaries. This is
    // paged derived metadata, never a resident per-line/checkpoint vector.
    boundaries: Vec<PageRef>,
    boundary_base: u32,
    boundary_extent: u32,
}
impl Segment {
    fn validate(&self) -> Result<()> {
        self.summary.validate()?;
        self.incoming.validate()?;
        self.outgoing.validate()?;
        if self.summary.bytes == 0
            || (self.summary.bytes > PROBE_BYTES as u64
                && self.inline.is_none()
                && !self.pending_inline)
            || self.reference_slots > self.summary.bytes
        {
            return Err(Error::Invalid("markup segment bound"));
        }
        if self.pending_inline
            && (self.inline.is_some()
                || !self.dependent_inline
                || self.parsed
                || self.incoming != Carry::Root
                || self.outgoing != Carry::Root
                || self.code.is_some()
                || self.definitions.is_some()
                || !self.boundaries.is_empty()
                || self.boundary_base != 0
                || self.boundary_extent != 0)
        {
            return Err(Error::Invalid("markup pending actual paragraph state"));
        }
        if self.dependent_inline && self.inline.is_none() && !self.pending_inline {
            return Err(Error::Invalid(
                "markup reference paragraph without source state",
            ));
        }
        if let Some(inline) = &self.inline {
            inline.validate(self.summary)?;
            if self.parsed
                || self.incoming != Carry::Root
                || self.outgoing != Carry::Root
                || self.code.is_some()
                || self.definitions.is_some()
                || !self.boundaries.is_empty()
                || self.boundary_base != 0
                || self.boundary_extent != 0
            {
                return Err(Error::Invalid("markup completed inline paragraph state"));
            }
        }
        if self.parsed
            && (matches!(self.incoming, Carry::Fence(_) | Carry::Html(_))
                || matches!(self.outgoing, Carry::Fence(_) | Carry::Html(_))
                || self.code.is_some())
        {
            return Err(Error::Invalid("markup parsed block state"));
        }
        if self.code.is_some()
            && (matches!(self.incoming, Carry::Html(_)) || matches!(self.outgoing, Carry::Html(_)))
        {
            return Err(Error::Invalid("markup HTML cannot become code"));
        }
        if let Some((start, end)) = self.code
            && (self.parsed
                || u64::from(start) > u64::from(end)
                || u64::from(end) > self.summary.bytes
                || self.definitions.is_some())
        {
            return Err(Error::Invalid("markup literal extent"));
        }
        if self.boundaries.len() > 2
            || (self.parsed && self.boundaries.is_empty())
            || (!self.parsed && !self.boundaries.is_empty())
            || self.definition_base != self.boundary_base
            || self.inline.is_none()
                && !self.pending_inline
                && u64::from(self.boundary_base)
                    .checked_add(self.summary.bytes)
                    .is_none_or(|end| end > u64::from(self.boundary_extent))
        {
            return Err(Error::Invalid("markup boundary extent"));
        }
        for page in &self.boundaries {
            validate_page(page, PageKind::Index)?;
        }
        if let Some(root) = &self.definitions {
            validate_definition_ref(root)?;
        }
        Ok(())
    }
    fn labels(&self) -> Labels {
        self.definitions
            .as_ref()
            .map_or_else(Labels::default, |root| root.labels)
    }
}
#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MarkRef {
    page: PageRef,
    height: u8,
    summary: TextSummary,
    incoming: Carry,
    outgoing: Carry,
    labels: Labels,
    reference_slots: u64,
    max_definition_cost: u64,
    pending_inline: u64,
    dependent_inline: u64,
}
#[derive(Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "items",
    rename_all = "snake_case",
    deny_unknown_fields
)]
enum MarkNode {
    Segments(Vec<Segment>),
    Branch(Vec<MarkRef>),
    Definitions(Vec<DefinitionCandidate>),
    DefinitionBranch(Vec<DefinitionRef>),
    Containers(Vec<[u64; 4]>),
    ContainerBranch(Vec<ContainerRef>),
    InlineOpeners(inline::OpenersPage),
    InlineStyles(Vec<inline::InlineRow>),
    InlineBranch(Vec<InlineRef>),
    CodeRuns(Vec<[u64; 6]>),
    CodeBranch(Vec<inline::CodeRef>),
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MarkPage {
    schema: u8,
    owner_id: Uuid,
    document_id: Uuid,
    mode: MarkupMode,
    node: MarkNode,
}

/// This is a display annotation, not a text revision or durable history root.
/// Its source shape is shared, with no source-sized line/token array.
pub struct MarkupIndex {
    pub(super) source: MarkupSource,
    pub(super) mode: MarkupMode,
    root: Option<MarkRef>,
    complete: bool,
    // Full real block coverage can prove definition search while an opaque
    // earlier paragraph is still awaiting its inline reference pass.
    definitions_complete: bool,
}
impl MarkupIndex {
    pub fn source_id(&self) -> Uuid {
        self.source.id
    }
    pub fn mode(&self) -> MarkupMode {
        self.mode
    }
    pub fn complete(&self) -> bool {
        self.complete
    }
    pub fn indexed_summary(&self) -> TextSummary {
        self.root
            .as_ref()
            .map_or(TextSummary::EMPTY, |root| root.summary)
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkupProgress {
    pub complete: bool,
    pub incomplete_block: bool,
    pub indexed_bytes: u64,
    pub buffered_bytes: usize,
    pub reused_bytes: u64,
}

fn validate_definition_ref(root: &DefinitionRef) -> Result<()> {
    validate_page(&root.page, PageKind::Index)?;
    if root.height > MARK_HEIGHT || root.count == 0 || root.max_cost > 2 * PROBE_BYTES as u64 {
        return Err(Error::Invalid("markup definition reference"));
    }
    Ok(())
}
fn validate_mark_ref(root: &MarkRef) -> Result<()> {
    validate_page(&root.page, PageKind::Index)?;
    root.summary.validate()?;
    root.incoming.validate()?;
    root.outgoing.validate()?;
    if root.height > MARK_HEIGHT
        || root.summary.bytes == 0
        || root.reference_slots > root.summary.bytes
        || root.max_definition_cost > 2 * PROBE_BYTES as u64
        || root.pending_inline > root.dependent_inline
        || root.dependent_inline > root.summary.bytes
    {
        return Err(Error::Invalid("markup node reference"));
    }
    Ok(())
}
impl<S: PageProvider> TextEngine<S> {
    fn container_branch(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<ContainerRef>,
    ) -> Result<ContainerRef> {
        if values.is_empty() || values.len() > MARK_FANOUT {
            return Err(Error::Invalid("markup container branch fanout"));
        }
        let height = values[0]
            .height
            .checked_add(1)
            .filter(|height| *height <= MARK_HEIGHT)
            .ok_or(Error::Invalid("markup container height"))?;
        let mut count = 0u32;
        for value in &values {
            value.validate()?;
            if value.height.checked_add(1) != Some(height) {
                return Err(Error::Invalid("markup container new branch height"));
            }
            count = count
                .checked_add(value.count)
                .ok_or(Error::Invalid("markup container new count"))?;
        }
        let page = self.write_mark_page(source, mode, MarkNode::ContainerBranch(values))?;
        Ok(ContainerRef {
            page,
            height,
            count,
        })
    }
    fn read_mark_page(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        page: &PageRef,
    ) -> Result<MarkNode> {
        let bytes = self.page(source, PageKind::Index, page)?;
        let value: MarkPage =
            serde_json::from_slice(&bytes).map_err(|_| Error::Invalid("markup page encoding"))?;
        if value.schema != 1
            || value.owner_id != source.owner_id
            || value.document_id != source.document_id
            || value.mode != mode
        {
            return Err(Error::Invalid("markup page source/options"));
        }
        Ok(value.node)
    }
    fn write_mark_page(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        node: MarkNode,
    ) -> Result<PageRef> {
        let bytes = serde_json::to_vec(&MarkPage {
            schema: 1,
            owner_id: source.owner_id,
            document_id: source.document_id,
            mode,
            node,
        })
        .map_err(|_| Error::Invalid("markup page encoding"))?;
        if bytes.len() > INDEX_PAGE_BYTES {
            return Err(Error::Invalid("markup page budget"));
        }
        self.write_page(source, PageKind::Index, &bytes)
    }
    fn mark_node(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        root: &MarkRef,
    ) -> Result<MarkNode> {
        validate_mark_ref(root)?;
        let node = self.read_mark_page(source, mode, &root.page)?;
        let (summary, incoming, outgoing, labels, slots, max_cost, pending, dependent) = match &node
        {
            MarkNode::Segments(values)
                if root.height == 0 && !values.is_empty() && values.len() <= MARK_FANOUT =>
            {
                let mut summary = TextSummary::EMPTY;
                let mut labels = Labels::default();
                let mut slots = 0u64;
                let mut max_cost = 0;
                let mut pending = 0u64;
                let mut dependent = 0u64;
                let mut carry = values[0].incoming.clone();
                for value in values {
                    value.validate()?;
                    if value.incoming != carry {
                        return Err(Error::Invalid("markup leaf carry chain"));
                    }
                    carry = value.outgoing.clone();
                    summary = summary.checked_add(value.summary)?;
                    labels = labels.union(value.labels());
                    slots = slots
                        .checked_add(value.reference_slots)
                        .ok_or(Error::Invalid("markup reference slots"))?;
                    max_cost =
                        max_cost.max(value.definitions.as_ref().map_or(0, |root| root.max_cost));
                    pending = pending
                        .checked_add(u64::from(value.pending_inline))
                        .ok_or(Error::Invalid("markup pending paragraph aggregate"))?;
                    dependent = dependent
                        .checked_add(u64::from(value.dependent_inline))
                        .ok_or(Error::Invalid("markup dependent paragraph aggregate"))?;
                }
                (
                    summary,
                    values[0].incoming.clone(),
                    carry,
                    labels,
                    slots,
                    max_cost,
                    pending,
                    dependent,
                )
            }
            MarkNode::Branch(values)
                if root.height > 0 && !values.is_empty() && values.len() <= MARK_FANOUT =>
            {
                let mut summary = TextSummary::EMPTY;
                let mut labels = Labels::default();
                let mut slots = 0u64;
                let mut max_cost = 0;
                let mut pending = 0u64;
                let mut dependent = 0u64;
                let mut carry = values[0].incoming.clone();
                for value in values {
                    validate_mark_ref(value)?;
                    if value.height.checked_add(1) != Some(root.height) || value.incoming != carry {
                        return Err(Error::Invalid("markup branch shape/carry"));
                    }
                    carry = value.outgoing.clone();
                    summary = summary.checked_add(value.summary)?;
                    labels = labels.union(value.labels);
                    slots = slots
                        .checked_add(value.reference_slots)
                        .ok_or(Error::Invalid("markup reference slots"))?;
                    max_cost = max_cost.max(value.max_definition_cost);
                    pending = pending
                        .checked_add(value.pending_inline)
                        .ok_or(Error::Invalid("markup pending branch aggregate"))?;
                    dependent = dependent
                        .checked_add(value.dependent_inline)
                        .ok_or(Error::Invalid("markup dependent branch aggregate"))?;
                }
                (
                    summary,
                    values[0].incoming.clone(),
                    carry,
                    labels,
                    slots,
                    max_cost,
                    pending,
                    dependent,
                )
            }
            _ => return Err(Error::Invalid("markup node shape")),
        };
        if summary != root.summary
            || incoming != root.incoming
            || outgoing != root.outgoing
            || labels != root.labels
            || slots != root.reference_slots
            || max_cost != root.max_definition_cost
            || pending != root.pending_inline
            || dependent != root.dependent_inline
        {
            return Err(Error::Invalid("markup authenticated aggregate"));
        }
        Ok(node)
    }
    fn mark_leaf(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<Segment>,
    ) -> Result<Option<MarkRef>> {
        if values.is_empty() {
            return Ok(None);
        }
        let mut summary = TextSummary::EMPTY;
        let mut labels = Labels::default();
        let mut slots = 0u64;
        let mut max_cost = 0;
        let mut pending = 0u64;
        let mut dependent = 0u64;
        let incoming = values[0].incoming.clone();
        let mut carry = incoming.clone();
        for value in &values {
            value.validate()?;
            if value.incoming != carry {
                return Err(Error::Invalid("markup new leaf carry"));
            }
            carry = value.outgoing.clone();
            summary = summary.checked_add(value.summary)?;
            labels = labels.union(value.labels());
            slots = slots
                .checked_add(value.reference_slots)
                .ok_or(Error::Invalid("markup leaf reference slots"))?;
            max_cost = max_cost.max(value.definitions.as_ref().map_or(0, |root| root.max_cost));
            pending = pending
                .checked_add(u64::from(value.pending_inline))
                .ok_or(Error::Invalid("markup new pending paragraph count"))?;
            dependent = dependent
                .checked_add(u64::from(value.dependent_inline))
                .ok_or(Error::Invalid("markup new dependent paragraph count"))?;
        }
        if values.len() > MARK_FANOUT {
            return Err(Error::Invalid("markup leaf fanout"));
        }
        let page = self.write_mark_page(source, mode, MarkNode::Segments(values))?;
        Ok(Some(MarkRef {
            page,
            height: 0,
            summary,
            incoming,
            outgoing: carry,
            labels,
            reference_slots: slots,
            max_definition_cost: max_cost,
            pending_inline: pending,
            dependent_inline: dependent,
        }))
    }
    fn mark_branch(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<MarkRef>,
    ) -> Result<Option<MarkRef>> {
        if values.is_empty() {
            return Ok(None);
        }
        if values.len() == 1 {
            return Ok(values.into_iter().next());
        }
        if values.len() > MARK_FANOUT {
            return Err(Error::Invalid("markup branch fanout"));
        }
        let height = values[0]
            .height
            .checked_add(1)
            .filter(|height| *height <= MARK_HEIGHT)
            .ok_or(Error::Invalid("markup index height"))?;
        let incoming = values[0].incoming.clone();
        let mut carry = incoming.clone();
        let mut summary = TextSummary::EMPTY;
        let mut labels = Labels::default();
        let mut slots = 0u64;
        let mut max_cost = 0;
        let mut pending = 0u64;
        let mut dependent = 0u64;
        for value in &values {
            validate_mark_ref(value)?;
            if value.height.checked_add(1) != Some(height) || value.incoming != carry {
                return Err(Error::Invalid("markup new branch carry"));
            }
            carry = value.outgoing.clone();
            summary = summary.checked_add(value.summary)?;
            labels = labels.union(value.labels);
            slots = slots
                .checked_add(value.reference_slots)
                .ok_or(Error::Invalid("markup branch reference slots"))?;
            max_cost = max_cost.max(value.max_definition_cost);
            pending = pending
                .checked_add(value.pending_inline)
                .ok_or(Error::Invalid("markup new pending branch count"))?;
            dependent = dependent
                .checked_add(value.dependent_inline)
                .ok_or(Error::Invalid("markup new dependent branch count"))?;
        }
        let page = self.write_mark_page(source, mode, MarkNode::Branch(values))?;
        Ok(Some(MarkRef {
            page,
            height,
            summary,
            incoming,
            outgoing: carry,
            labels,
            reference_slots: slots,
            max_definition_cost: max_cost,
            pending_inline: pending,
            dependent_inline: dependent,
        }))
    }
    fn mark_join_parts(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        left: MarkRef,
        right: MarkRef,
    ) -> Result<Vec<MarkRef>> {
        if left.outgoing != right.incoming {
            return Err(Error::Invalid("markup join carry"));
        }
        if left.height == right.height {
            match (
                self.mark_node(source, mode, &left)?,
                self.mark_node(source, mode, &right)?,
            ) {
                (MarkNode::Segments(mut a), MarkNode::Segments(b)) => {
                    a.extend(b);
                    let rest = if a.len() > MARK_FANOUT {
                        a.split_off(a.len() / 2)
                    } else {
                        Vec::new()
                    };
                    let mut roots = Vec::with_capacity(2);
                    if let Some(root) = self.mark_leaf(source, mode, a)? {
                        roots.push(root);
                    }
                    if let Some(root) = self.mark_leaf(source, mode, rest)? {
                        roots.push(root);
                    }
                    Ok(roots)
                }
                (MarkNode::Branch(mut a), MarkNode::Branch(b)) => {
                    a.extend(b);
                    let rest = if a.len() > MARK_FANOUT {
                        a.split_off(a.len() / 2)
                    } else {
                        Vec::new()
                    };
                    let mut roots = Vec::with_capacity(2);
                    if let Some(root) = self.mark_branch(source, mode, a)? {
                        roots.push(root);
                    }
                    if let Some(root) = self.mark_branch(source, mode, rest)? {
                        roots.push(root);
                    }
                    Ok(roots)
                }
                _ => Err(Error::Invalid("markup join shape")),
            }
        } else if left.height > right.height {
            let MarkNode::Branch(mut children) = self.mark_node(source, mode, &left)? else {
                return Err(Error::Invalid("markup left branch"));
            };
            let last = children.pop().ok_or(Error::Invalid("markup last child"))?;
            children.extend(self.mark_join_parts(source, mode, last, right)?);
            self.mark_pack_branches(source, mode, children)
        } else {
            let MarkNode::Branch(mut children) = self.mark_node(source, mode, &right)? else {
                return Err(Error::Invalid("markup right branch"));
            };
            let first = children.remove(0);
            let mut heads = self.mark_join_parts(source, mode, left, first)?;
            heads.extend(children);
            self.mark_pack_branches(source, mode, heads)
        }
    }
    fn mark_pack_branches(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        mut children: Vec<MarkRef>,
    ) -> Result<Vec<MarkRef>> {
        let rest = if children.len() > MARK_FANOUT {
            children.split_off(children.len() / 2)
        } else {
            Vec::new()
        };
        let mut roots = Vec::with_capacity(2);
        if let Some(root) = self.mark_branch(source, mode, children)? {
            roots.push(root);
        }
        if let Some(root) = self.mark_branch(source, mode, rest)? {
            roots.push(root);
        }
        Ok(roots)
    }
    fn mark_join(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        a: Option<MarkRef>,
        b: Option<MarkRef>,
    ) -> Result<Option<MarkRef>> {
        let roots = match (a, b) {
            (Some(a), Some(b)) => self.mark_join_parts(source, mode, a, b)?,
            (a, b) => return Ok(a.or(b)),
        };
        self.mark_branch(source, mode, roots)
    }
    /// Reuse offsets relative to nodes. A cut within a parsed segment must be
    /// one of the original first pass's proved root boundaries. The selected
    /// unchanged side supplies its real scalar summary from the current source.
    fn mark_split(
        &mut self,
        snapshot: &LogicalSnapshot,
        mode: MarkupMode,
        root: MarkRef,
        at: u64,
        base: u64,
        mapping: SplitMapping,
    ) -> Result<(Option<MarkRef>, Option<MarkRef>)> {
        let SplitMapping {
            old_base,
            new_base,
            keep_prefix,
        } = mapping;
        if at == 0 {
            return Ok((None, Some(root)));
        }
        if at == root.summary.bytes {
            return Ok((Some(root), None));
        }
        if at > root.summary.bytes {
            return Err(Error::Invalid("markup split extent"));
        }
        match self.mark_node(snapshot.origin(), mode, &root)? {
            MarkNode::Segments(values) => {
                let mut before = 0u64;
                let mut left = Vec::new();
                let mut right = Vec::new();
                for value in values {
                    let end = before
                        .checked_add(value.summary.bytes)
                        .ok_or(Error::Invalid("markup split overflow"))?;
                    if end <= at {
                        left.push(value);
                    } else if before >= at {
                        right.push(value);
                    } else {
                        let cut = at - before;
                        if !value.parsed
                            || !self.mark_boundary(snapshot.origin(), mode, &value, cut)?
                        {
                            return Err(Error::Invalid(
                                "markup split requires actual root checkpoint",
                            ));
                        }
                        let map = |old: u64| {
                            old.checked_sub(old_base)
                                .and_then(|point| new_base.checked_add(point))
                                .ok_or(Error::Invalid("markup unchanged interval mapping"))
                        };
                        let cut_abs = base
                            .checked_add(at)
                            .ok_or(Error::Invalid("markup split address"))?;
                        let edge = if keep_prefix {
                            base.checked_add(before)
                        } else {
                            base.checked_add(end)
                        }
                        .ok_or(Error::Invalid("markup split edge"))?;
                        let point = self.logical_byte_position(snapshot, map(cut_abs)?)?.point();
                        let endpoint = self.logical_byte_position(snapshot, map(edge)?)?.point();
                        let (a, b) = if keep_prefix {
                            let a = difference(point, endpoint)?;
                            (a, difference(value.summary, a)?)
                        } else {
                            let b = difference(endpoint, point)?;
                            (difference(value.summary, b)?, b)
                        };
                        let (lo, hi) = if keep_prefix {
                            (map(edge)?, map(cut_abs)?)
                        } else {
                            (map(cut_abs)?, map(edge)?)
                        };
                        let bytes = self.logical_read_range(snapshot, lo..hi, &mut || false)?;
                        let slots = bytes.iter().filter(|byte| **byte == b'[').count() as u64;
                        let mut first = value.clone();
                        first.summary = a;
                        let mut last = value;
                        last.summary = b;
                        if keep_prefix {
                            first.reference_slots = slots;
                            last.reference_slots = last
                                .reference_slots
                                .checked_sub(slots)
                                .ok_or(Error::Invalid("markup split reference slots"))?;
                        } else {
                            last.reference_slots = slots;
                            first.reference_slots = first
                                .reference_slots
                                .checked_sub(slots)
                                .ok_or(Error::Invalid("markup split reference slots"))?;
                        }
                        let cut =
                            u32::try_from(cut).map_err(|_| Error::Invalid("markup block split"))?;
                        last.boundary_base = last
                            .boundary_base
                            .checked_add(cut)
                            .ok_or(Error::Invalid("markup boundary base"))?;
                        last.definition_base = last.boundary_base;
                        left.push(first);
                        right.push(last);
                    }
                    before = end;
                }
                Ok((
                    self.mark_leaf(snapshot.origin(), mode, left)?,
                    self.mark_leaf(snapshot.origin(), mode, right)?,
                ))
            }
            MarkNode::Branch(values) => {
                let mut before = 0u64;
                let mut left = None;
                let mut right = None;
                for value in values {
                    let end = before
                        .checked_add(value.summary.bytes)
                        .ok_or(Error::Invalid("markup branch split overflow"))?;
                    if end <= at {
                        left = self.mark_join(snapshot.origin(), mode, left, Some(value))?;
                    } else if before >= at {
                        right = self.mark_join(snapshot.origin(), mode, right, Some(value))?;
                    } else {
                        let (a, b) = self.mark_split(
                            snapshot,
                            mode,
                            value,
                            at - before,
                            base.checked_add(before)
                                .ok_or(Error::Invalid("markup subtree split base"))?,
                            mapping,
                        )?;
                        left = self.mark_join(snapshot.origin(), mode, left, a)?;
                        right = self.mark_join(snapshot.origin(), mode, right, b)?;
                    }
                    before = end;
                }
                Ok((left, right))
            }
            _ => Err(Error::Invalid("markup split node")),
        }
    }
    fn mark_segment(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        mut root: MarkRef,
        at: u64,
    ) -> Result<(TextSummary, Segment)> {
        let mut before = TextSummary::EMPTY;
        loop {
            match self.mark_node(source, mode, &root)? {
                MarkNode::Branch(values) => {
                    let mut found = None;
                    for value in values {
                        let end = before.checked_add(value.summary)?;
                        if at < end.bytes {
                            found = Some(value);
                            break;
                        }
                        before = end;
                    }
                    root = found.ok_or(Error::Invalid("markup segment branch"))?;
                }
                MarkNode::Segments(values) => {
                    for value in values {
                        let end = before.checked_add(value.summary)?;
                        if at < end.bytes {
                            return Ok((before, value));
                        }
                        before = end;
                    }
                    return Err(Error::Invalid("markup segment leaf"));
                }
                _ => return Err(Error::Invalid("markup segment node")),
            }
        }
    }
    fn first_reference_paragraph(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        mut root: MarkRef,
    ) -> Result<Option<u64>> {
        if root.dependent_inline == 0 {
            return Ok(None);
        }
        let mut before = 0u64;
        loop {
            match self.mark_node(source, mode, &root)? {
                MarkNode::Branch(values) => {
                    let mut found = None;
                    for value in values {
                        if value.dependent_inline != 0 {
                            found = Some(value);
                            break;
                        }
                        before = before
                            .checked_add(value.summary.bytes)
                            .ok_or(Error::Invalid("markup first reference paragraph extent"))?;
                    }
                    root = found.ok_or(Error::Invalid("markup missing reference branch"))?;
                }
                MarkNode::Segments(values) => {
                    for value in values {
                        if value.dependent_inline {
                            return Ok(Some(before));
                        }
                        before = before
                            .checked_add(value.summary.bytes)
                            .ok_or(Error::Invalid("markup first reference segment extent"))?;
                    }
                    return Err(Error::Invalid("markup missing reference segment"));
                }
                _ => return Err(Error::Invalid("markup reference paragraph node")),
            }
        }
    }
    fn write_boundaries(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        bytes: usize,
        starts: impl Iterator<Item = usize>,
    ) -> Result<Vec<PageRef>> {
        if bytes == 0 || bytes > PROBE_BYTES {
            return Err(Error::Invalid("markup bitmap input bound"));
        }
        let mut bits = vec![0u8; bytes.div_ceil(8)];
        bits[0] |= 1;
        for start in starts {
            if start < bytes {
                bits[start / 8] |= 1u8 << (start % 8);
            }
        }
        let mut pages = Vec::with_capacity(2);
        for (index, bitmap) in bits.chunks(TEXT_PAGE_BYTES / 8).enumerate() {
            let mut page = Vec::with_capacity(45 + bitmap.len());
            page.extend_from_slice(b"MBC1");
            page.extend_from_slice(source.owner_id.as_bytes());
            page.extend_from_slice(source.document_id.as_bytes());
            page.push(mode.slot() as u8);
            page.extend_from_slice(&(bytes as u32).to_le_bytes());
            page.extend_from_slice(&(index as u32).to_le_bytes());
            page.extend_from_slice(bitmap);
            pages.push(self.write_page(source, PageKind::Index, &page)?);
        }
        Ok(pages)
    }
    fn boundary_bits(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        segment: &Segment,
        index: usize,
    ) -> Result<Arc<[u8]>> {
        let reference = segment
            .boundaries
            .get(index)
            .ok_or(Error::Invalid("markup bitmap page"))?;
        let bytes = self.page(source, PageKind::Index, reference)?;
        let count = usize::try_from(segment.boundary_extent)
            .map_err(|_| Error::Invalid("markup bitmap extent"))?
            .div_ceil(8);
        let remaining = count
            .checked_sub(
                index
                    .checked_mul(TEXT_PAGE_BYTES / 8)
                    .ok_or(Error::Invalid("markup bitmap index"))?,
            )
            .ok_or(Error::Invalid("markup bitmap index"))?
            .min(TEXT_PAGE_BYTES / 8);
        if bytes.len() != 45 + remaining
            || bytes.get(..4) != Some(b"MBC1")
            || bytes.get(4..20) != Some(source.owner_id.as_bytes())
            || bytes.get(20..36) != Some(source.document_id.as_bytes())
            || bytes[36] != mode.slot() as u8
            || bytes.get(37..41) != Some(segment.boundary_extent.to_le_bytes().as_slice())
            || bytes.get(41..45) != Some((index as u32).to_le_bytes().as_slice())
        {
            return Err(Error::Invalid("markup bitmap source/shape"));
        }
        Ok(bytes)
    }
    fn mark_boundary(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        segment: &Segment,
        at: u64,
    ) -> Result<bool> {
        if !segment.parsed
            || segment.incoming != Carry::Root
            || segment.outgoing != Carry::Root
            || at >= segment.summary.bytes
        {
            return Ok(false);
        }
        let point = u64::from(segment.boundary_base)
            .checked_add(at)
            .ok_or(Error::Invalid("markup bitmap point"))?;
        let index = usize::try_from(point / TEXT_PAGE_BYTES as u64)
            .map_err(|_| Error::Invalid("markup bitmap index"))?;
        let bits = self.boundary_bits(source, mode, segment, index)?;
        let bit = usize::try_from(point % TEXT_PAGE_BYTES as u64)
            .map_err(|_| Error::Invalid("markup bitmap bit"))?;
        Ok(bits[45 + bit / 8] & (1u8 << (bit % 8)) != 0)
    }
    fn mark_checkpoint_before(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        root: MarkRef,
        at: u64,
    ) -> Result<(u64, Carry)> {
        let (before, segment) = self.mark_segment(source, mode, root, at)?;
        if let Carry::Html(html) = &segment.incoming
            && let Some(dependency) = &html.opening
        {
            return Ok((
                before
                    .bytes
                    .checked_sub(dependency.rewind)
                    .ok_or(Error::Invalid("markup HTML opening checkpoint"))?,
                Carry::Root,
            ));
        }
        if !segment.parsed || segment.incoming != Carry::Root || segment.outgoing != Carry::Root {
            return Ok((before.bytes, segment.incoming));
        }
        let upper = u64::from(segment.boundary_base)
            .checked_add(at - before.bytes)
            .ok_or(Error::Invalid("markup checkpoint upper"))?;
        let first = u64::from(segment.boundary_base);
        let mut index = usize::try_from(upper / TEXT_PAGE_BYTES as u64)
            .map_err(|_| Error::Invalid("markup checkpoint page"))?;
        loop {
            let bits = self.boundary_bits(source, mode, &segment, index)?;
            let low = first.max((index as u64) * TEXT_PAGE_BYTES as u64);
            let high = upper.min(((index + 1) as u64) * TEXT_PAGE_BYTES as u64 - 1);
            for bit in (low..=high).rev() {
                let local = usize::try_from(bit % TEXT_PAGE_BYTES as u64)
                    .map_err(|_| Error::Invalid("markup checkpoint bit"))?;
                if bits[45 + local / 8] & (1u8 << (local % 8)) != 0 {
                    // UTF16/LF at this actual byte boundary is supplied once
                    // by the new captured source, not guessed from a bitset.
                    return Ok((
                        before
                            .bytes
                            .checked_add(bit - first)
                            .ok_or(Error::Invalid("markup checkpoint address"))?,
                        Carry::Root,
                    ));
                }
            }
            if index == 0 {
                return Err(Error::Invalid("markup missing root checkpoint"));
            }
            index -= 1;
        }
    }
    fn write_definitions(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        definitions: &[ParsedReference<'static>],
    ) -> Result<Option<DefinitionRef>> {
        if definitions.is_empty() {
            return Ok(None);
        }
        let mut frontier: Vec<Vec<DefinitionRef>> = vec![Vec::new()];
        for group in definitions.chunks(MARK_FANOUT) {
            let values = group
                .iter()
                .map(|value| {
                    Ok(DefinitionCandidate {
                        hash: value.label_hash(),
                        start: u32::try_from(value.definition().span.start)
                            .map_err(|_| Error::Invalid("markup definition start"))?,
                        end: u32::try_from(value.definition().span.end)
                            .map_err(|_| Error::Invalid("markup definition end"))?,
                        cost: (value.definition().dest.len()
                            + value
                                .definition()
                                .title
                                .as_ref()
                                .map_or(0, |title| title.len()))
                            as u64,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            let mut labels = Labels::default();
            for value in &values {
                labels.add(value.hash);
            }
            let count = values.len() as u64;
            let max_cost = values.iter().map(|value| value.cost).max().unwrap_or(0);
            let page = self.write_mark_page(source, mode, MarkNode::Definitions(values))?;
            let mut value = DefinitionRef {
                page,
                height: 0,
                count,
                labels,
                max_cost,
            };
            let mut level = 0;
            loop {
                if level == frontier.len() {
                    frontier.push(Vec::new());
                }
                frontier[level].push(value);
                if frontier[level].len() < MARK_FANOUT {
                    break;
                }
                let values = std::mem::take(&mut frontier[level]);
                value = self.definition_branch(source, mode, values)?;
                level += 1;
                if level > usize::from(MARK_HEIGHT) {
                    return Err(Error::Invalid("markup definition tree height"));
                }
            }
        }
        let mut tail: Option<DefinitionRef> = None;
        for (level, mut values) in frontier.into_iter().enumerate() {
            if let Some(mut value) = tail.take() {
                while usize::from(value.height) < level {
                    value = self.definition_branch(source, mode, vec![value])?;
                }
                values.push(value);
            }
            if !values.is_empty() {
                tail = Some(self.definition_branch(source, mode, values)?);
            }
        }
        Ok(tail)
    }
    fn definition_branch(
        &mut self,
        source: &Revision,
        mode: MarkupMode,
        values: Vec<DefinitionRef>,
    ) -> Result<DefinitionRef> {
        if values.is_empty() || values.len() > MARK_FANOUT {
            return Err(Error::Invalid("markup definition branch fanout"));
        }
        let height = values[0]
            .height
            .checked_add(1)
            .filter(|height| *height <= MARK_HEIGHT)
            .ok_or(Error::Invalid("markup definition height"))?;
        let mut count = 0u64;
        let mut labels = Labels::default();
        let mut max_cost = 0;
        for value in &values {
            validate_definition_ref(value)?;
            if value.height.checked_add(1) != Some(height) {
                return Err(Error::Invalid("markup definition shape"));
            }
            count = count
                .checked_add(value.count)
                .ok_or(Error::Invalid("markup definition count"))?;
            labels = labels.union(value.labels);
            max_cost = max_cost.max(value.max_cost);
        }
        let page = self.write_mark_page(source, mode, MarkNode::DefinitionBranch(values))?;
        Ok(DefinitionRef {
            page,
            height,
            count,
            labels,
            max_cost,
        })
    }
}

struct ParsedCommit {
    segment: Segment,
    prefix: usize,
    fence: Option<(usize, FenceContinuation)>,
    html: Option<(usize, HtmlContinuation)>,
    literal_bytes: usize,
    incomplete: bool,
}
struct PendingContainerWrite {
    parsed: ParsedCommit,
    write: ContainerWrite,
}

/// One captured indexing operation. A quantum reads at most one <=64KiB source
/// piece, parses <=32KiB pending input, and writes bounded index pages. Hosts
/// yield their existing operation lane between calls; there is no fsync here.
pub struct MarkupIndexBuilder {
    snapshot: LogicalSnapshot,
    mode: MarkupMode,
    previous: Option<Arc<MarkupIndex>>,
    old_suffix: u64,
    new_suffix: u64,
    root: Option<MarkRef>,
    cursor: TextSummary,
    buffer: String,
    carry: Carry,
    containers: Option<BlockCarry>,
    container_load: Option<ContainerLoad>,
    container_write: Option<PendingContainerWrite>,
    long_paragraph: Option<LongParagraph>,
    html_opening: Option<HtmlOpening>,
    reference_pass: Option<ReferencePass>,
    reused: u64,
    stopped: bool,
    incomplete: bool,
    ready: Option<Arc<MarkupIndex>>,
}
impl MarkupIndexBuilder {
    pub fn new<S: PageProvider>(
        engine: &mut TextEngine<S>,
        snapshot: LogicalSnapshot,
        mode: MarkupMode,
    ) -> Result<Self> {
        let exact = snapshot.markup_index(mode);
        let previous = snapshot.previous_markup(mode)?;
        let mut value = Self {
            snapshot,
            mode,
            previous,
            old_suffix: 0,
            new_suffix: 0,
            root: None,
            cursor: TextSummary::EMPTY,
            buffer: String::new(),
            carry: Carry::Root,
            containers: Some(BlockCarry::default()),
            container_load: None,
            container_write: None,
            long_paragraph: None,
            html_opening: None,
            reference_pass: None,
            reused: 0,
            stopped: false,
            incomplete: false,
            ready: exact,
        };
        if let Some(index) = &value.ready {
            value.stopped = true;
            value.root = index.root.clone();
            value.cursor = index.indexed_summary();
            value.incomplete = !index.complete;
            return Ok(value);
        }
        if let Some(previous) = &value.previous {
            let (mut prefix, suffix) = previous.source.common_edges(&value.snapshot)?;
            // A changed later first definition can alter an earlier inline
            // tree, including disabled outer Links and child emphasis scope.
            // Conservatively rebuild from the first actual dependent block.
            if previous.source.id != value.snapshot.id()
                && let Some(root) = previous.root.clone()
                && let Some(at) =
                    engine.first_reference_paragraph(value.snapshot.origin(), mode, root)?
                && at < prefix.bytes
            {
                prefix = engine.logical_byte_position(&value.snapshot, at)?.point();
            }
            value.old_suffix = previous.source.summary.bytes - suffix.bytes;
            value.new_suffix = value.snapshot.summary().bytes - suffix.bytes;
            if previous.complete
                && prefix == previous.source.summary
                && prefix == value.snapshot.summary()
            {
                value.root = previous.root.clone();
                value.cursor = prefix;
                value.reused = prefix.bytes;
                value.complete_index()?;
                return Ok(value);
            }
            let proved = previous.indexed_summary();
            let needed = previous
                .root
                .as_ref()
                .and_then(|root| match &root.outgoing {
                    Carry::Html(html) => html.opening.as_ref().map(|value| value.remaining),
                    _ => None,
                })
                .unwrap_or(0);
            let required_prefix = proved
                .bytes
                .checked_add(needed)
                .ok_or(Error::Invalid("markup partial HTML dependency extent"))?;
            if !previous.complete && prefix.bytes >= required_prefix && proved.bytes > 0 {
                value.root = previous.root.clone();
                value.cursor = proved;
                value.reused = proved.bytes;
                value.carry = previous
                    .root
                    .as_ref()
                    .ok_or(Error::Invalid("markup partial root"))?
                    .outgoing
                    .clone();
                if let Carry::Containers(reference) = &value.carry {
                    value.container_load = Some(ContainerLoad::new(reference.clone())?);
                    value.containers = None;
                }
            } else if prefix.bytes > 0
                && let Some(root) = &previous.root
            {
                // Never reuse an old EOF-only paragraph closure after append.
                let upper = prefix.bytes.min(proved.bytes);
                let (at, carry) = engine.mark_checkpoint_before(
                    value.snapshot.origin(),
                    mode,
                    root.clone(),
                    upper - 1,
                )?;
                let point = engine.logical_byte_position(&value.snapshot, at)?.point();
                let (left, _) = engine.mark_split(
                    &value.snapshot,
                    mode,
                    root.clone(),
                    at,
                    0,
                    SplitMapping {
                        old_base: 0,
                        new_base: 0,
                        keep_prefix: true,
                    },
                )?;
                if left
                    .as_ref()
                    .map_or(TextSummary::EMPTY, |root| root.summary)
                    != point
                {
                    return Err(Error::Invalid("markup reused prefix scalar summary"));
                }
                if let Carry::Containers(reference) = &carry {
                    value.container_load = Some(ContainerLoad::new(reference.clone())?);
                    value.containers = None;
                }
                value.root = left;
                value.cursor = point;
                value.carry = carry;
                value.reused = point.bytes;
            }
        }
        Ok(value)
    }
    pub fn progress(&self) -> MarkupProgress {
        MarkupProgress {
            complete: self.stopped,
            incomplete_block: self.incomplete,
            indexed_bytes: self.cursor.bytes,
            buffered_bytes: self.buffer.len()
                + self
                    .long_paragraph
                    .as_ref()
                    .map_or(0, LongParagraph::buffered_bytes)
                + self
                    .reference_pass
                    .as_ref()
                    .map_or(0, ReferencePass::buffered_bytes),
            reused_bytes: self.reused,
        }
    }
    /// Shares only immutable derived pages and the captured source shape. This
    /// prefix can prove local grammar, never global definition absence/fuel.
    pub fn captured_index(&self) -> Arc<MarkupIndex> {
        self.ready.clone().unwrap_or_else(|| {
            Arc::new(MarkupIndex {
                source: self.snapshot.markup_source(),
                mode: self.mode,
                root: self.root.clone(),
                complete: false,
                definitions_complete: self.reference_pass.is_some(),
            })
        })
    }
    fn complete_index(&mut self) -> Result<()> {
        if self.cursor != self.snapshot.summary() || !self.buffer.is_empty() {
            return Err(Error::Invalid("markup full coverage summary"));
        }
        if self
            .root
            .as_ref()
            .is_some_and(|root| root.pending_inline != 0)
        {
            if self.reference_pass.is_some() {
                return Err(Error::Invalid(
                    "markup reference pass still has pending paragraphs",
                ));
            }
            let definitions = Arc::new(MarkupIndex {
                source: self.snapshot.markup_source(),
                mode: self.mode,
                root: self.root.clone(),
                complete: false,
                definitions_complete: true,
            });
            self.reference_pass = Some(ReferencePass::new(definitions));
            return Ok(());
        }
        let index = Arc::new(MarkupIndex {
            source: self.snapshot.markup_source(),
            mode: self.mode,
            root: self.root.clone(),
            complete: true,
            definitions_complete: true,
        });
        self.snapshot.completed_markup(Arc::clone(&index))?;
        self.ready = Some(index);
        self.stopped = true;
        Ok(())
    }
    fn append<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        segment: Segment,
    ) -> Result<()> {
        if segment.incoming != self.carry {
            return Err(Error::Invalid("markup producer incoming carry"));
        }
        let point = self.cursor.checked_add(segment.summary)?;
        if point.bytes > self.snapshot.summary().bytes {
            return Err(Error::Invalid("markup producer source extent"));
        }
        self.carry = segment.outgoing.clone();
        let leaf = engine.mark_leaf(self.snapshot.origin(), self.mode, vec![segment])?;
        self.root = engine.mark_join(self.snapshot.origin(), self.mode, self.root.take(), leaf)?;
        self.cursor = point;
        self.snapshot.progressed_markup(self.captured_index())?;
        Ok(())
    }
    fn append_parsed<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        mut parsed: ParsedCommit,
        outgoing: Carry,
        next: BlockCarry,
    ) -> Result<()> {
        parsed.segment.outgoing = outgoing;
        self.append(engine, parsed.segment)?;
        self.buffer.drain(..parsed.prefix);
        self.containers = Some(next);
        if parsed.incomplete {
            self.incomplete = true;
            self.stopped = true;
        } else if let Some((start, fence)) = parsed.fence {
            let count = parsed.literal_bytes;
            self.append_literal(
                engine,
                count,
                Some(((start - parsed.prefix) as u32, count as u32)),
                Carry::Fence(fence.checkpoint()),
            )?;
        } else if let Some((_, html)) = parsed.html {
            self.append_literal(
                engine,
                parsed.literal_bytes,
                None,
                Carry::Html(HtmlCarry::fixed(html.checkpoint())),
            )?;
        }
        if !self.stopped && self.cursor == self.snapshot.summary() && self.buffer.is_empty() {
            self.complete_index()?;
        }
        Ok(())
    }
    fn append_literal<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        count: usize,
        code: Option<(u32, u32)>,
        outgoing: Carry,
    ) -> Result<()> {
        if count == 0
            || count > self.buffer.len()
            || count > PROBE_BYTES
            || !self.buffer.is_char_boundary(count)
        {
            return Err(Error::Invalid("markup literal source quantum"));
        }
        let summary = TextSummary::of(&self.buffer[..count]);
        self.append(
            engine,
            Segment {
                summary,
                incoming: self.carry.clone(),
                outgoing,
                parsed: false,
                reference_slots: 0,
                code,
                inline: None,
                pending_inline: false,
                dependent_inline: false,
                definitions: None,
                definition_base: 0,
                boundaries: Vec::new(),
                boundary_base: 0,
                boundary_extent: count as u32,
            },
        )?;
        self.buffer.drain(..count);
        if self.carry == Carry::Root {
            self.containers = Some(BlockCarry::default());
        }
        Ok(())
    }
    fn reuse_suffix<S: PageProvider>(&mut self, engine: &mut TextEngine<S>) -> Result<bool> {
        let Some(previous) = &self.previous else {
            return Ok(false);
        };
        if !previous.complete
            || previous
                .root
                .as_ref()
                .is_some_and(|root| root.dependent_inline != 0)
        {
            return Ok(false);
        }
        if self.cursor.bytes < self.new_suffix || self.new_suffix == self.snapshot.summary().bytes {
            return Ok(false);
        }
        let old = self
            .old_suffix
            .checked_add(self.cursor.bytes - self.new_suffix)
            .ok_or(Error::Invalid("markup suffix mapping"))?;
        let Some(root) = &previous.root else {
            return Ok(false);
        };
        if old >= root.summary.bytes {
            return Ok(false);
        }
        let (before, segment) =
            engine.mark_segment(self.snapshot.origin(), self.mode, root.clone(), old)?;
        let matching = if old == before.bytes {
            self.carry == segment.incoming
        } else {
            self.carry == Carry::Root
                && engine.mark_boundary(
                    self.snapshot.origin(),
                    self.mode,
                    &segment,
                    old - before.bytes,
                )?
        };
        if !matching {
            return Ok(false);
        }
        let (_, suffix) = engine.mark_split(
            &self.snapshot,
            self.mode,
            root.clone(),
            old,
            0,
            SplitMapping {
                old_base: self.old_suffix,
                new_base: self.new_suffix,
                keep_prefix: false,
            },
        )?;
        let bytes = suffix.as_ref().map_or(0, |root| root.summary.bytes);
        self.root =
            engine.mark_join(self.snapshot.origin(), self.mode, self.root.take(), suffix)?;
        self.cursor = self
            .root
            .as_ref()
            .map_or(TextSummary::EMPTY, |root| root.summary);
        self.buffer.clear();
        self.reused = self
            .reused
            .checked_add(bytes)
            .ok_or(Error::Invalid("markup reuse counter"))?;
        self.complete_index()?;
        Ok(true)
    }
    fn begin_long_paragraph(&mut self) -> Result<bool> {
        if self.carry != Carry::Root || self.buffer.len() < PROBE_BYTES - 3 {
            return Ok(false);
        }
        let Some(seed) = pulldown_cmark::paged::begin_unfinished_paragraph(
            &self.buffer,
            self.mode.options(),
            &BlockCarry::default(),
        ) else {
            return Ok(false);
        };
        if seed.start() != 0 || !seed.containers().is_root() {
            return Ok(false);
        }
        self.long_paragraph = Some(LongParagraph::new(
            &seed,
            self.cursor,
            std::mem::take(&mut self.buffer),
            self.snapshot.summary(),
            self.mode,
        )?);
        Ok(true)
    }
    fn begin_long_html<S: PageProvider>(&mut self, engine: &mut TextEngine<S>) -> Result<bool> {
        if self.carry != Carry::Root || self.buffer.len() < PROBE_BYTES - 3 {
            return Ok(false);
        }
        // The LF-only probe can retain a final root blank line in front of
        // a long unfinished physical line. Drain only actual completed blank
        // lines before asking that SAME first pass to admit the long block.
        if let Some(count) = pulldown_cmark::paged::completed_root_blank_prefix(&self.buffer) {
            self.append_literal(engine, count, None, Carry::Root)?;
            return Ok(true);
        }
        let Some(work) = pulldown_cmark::paged::begin_unfinished_html_work(
            &self.buffer,
            self.mode.options(),
            &BlockCarry::default(),
        ) else {
            return Ok(false);
        };
        match work {
            HtmlBlockWork::Known(_, html) => self.append_literal(
                engine,
                self.buffer.len(),
                None,
                Carry::Html(HtmlCarry::fixed(html.checkpoint())),
            )?,
            HtmlBlockWork::Opening(opening) => self.html_opening = Some(opening),
        }
        Ok(true)
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<MarkupProgress> {
        check_cancel(cancelled)?;
        if self.stopped {
            return Ok(self.progress());
        }
        if let Some(mut pass) = self.reference_pass.take() {
            match pass.step(engine, &self.snapshot, &mut self.root, cancelled)? {
                references::PassProgress::Working => self.reference_pass = Some(pass),
                references::PassProgress::Complete => self.complete_index()?,
                references::PassProgress::Incomplete => {
                    self.incomplete = true;
                    self.stopped = true;
                }
            }
            self.snapshot.progressed_markup(self.captured_index())?;
            return Ok(self.progress());
        }
        if let Some(mut opening) = self.html_opening.take() {
            let at = self
                .cursor
                .bytes
                .checked_add(opening.scanned_bytes())
                .ok_or(Error::Invalid("markup HTML opening source cursor"))?;
            let source_end = self.snapshot.summary().bytes;
            if at > source_end {
                return Err(Error::Invalid("markup HTML opening beyond source"));
            }
            let step = if at == source_end {
                opening.consume("", true, cancelled)
            } else {
                let piece = engine.logical_source_piece(&self.snapshot, at)?;
                let text = piece.text()?;
                let offset = at
                    .checked_sub(piece.before.bytes)
                    .ok_or(Error::Invalid("markup HTML opening piece origin"))?;
                let first = usize::try_from(offset)
                    .map_err(|_| Error::Invalid("markup HTML opening piece offset"))?;
                let mut last = first
                    .checked_add(PROBE_BYTES)
                    .ok_or(Error::Invalid("markup HTML opening piece end"))?
                    .min(text.len());
                while !text.is_char_boundary(last) {
                    last -= 1;
                }
                if last <= first {
                    return Err(Error::Invalid("markup HTML opening empty source quantum"));
                }
                let bytes = u64::try_from(last - first)
                    .map_err(|_| Error::Invalid("markup HTML opening address space"))?;
                let end = at
                    .checked_add(bytes)
                    .filter(|end| *end <= source_end)
                    .ok_or(Error::Invalid("markup HTML opening source extent"))?;
                let eof = end == source_end;
                opening.consume(&text[first..last], eof, cancelled)
            }
            .map_err(|error| match error {
                pulldown_cmark::paged::InlineRunError::Cancelled => Error::Cancelled,
                pulldown_cmark::paged::InlineRunError::Invalid(value) => Error::Invalid(value),
            })?;
            match step.status {
                HtmlOpeningStatus::Pending => self.html_opening = Some(opening),
                HtmlOpeningStatus::Html | HtmlOpeningStatus::Paragraph => {
                    let decision = opening.scanned_bytes();
                    match opening.finish().map_err(|error| match error {
                        pulldown_cmark::paged::InlineRunError::Cancelled => Error::Cancelled,
                        pulldown_cmark::paged::InlineRunError::Invalid(value) => {
                            Error::Invalid(value)
                        }
                    })? {
                        HtmlOpeningChoice::Html(html) => {
                            let prefix = u64::try_from(self.buffer.len())
                                .map_err(|_| Error::Invalid("markup HTML prefix address space"))?;
                            let carry = HtmlCarry::dependent(html.checkpoint(), prefix, decision)?;
                            self.append_literal(
                                engine,
                                self.buffer.len(),
                                None,
                                Carry::Html(carry),
                            )?;
                        }
                        HtmlOpeningChoice::Paragraph(seed) => {
                            self.long_paragraph = Some(LongParagraph::new(
                                &seed,
                                self.cursor,
                                std::mem::take(&mut self.buffer),
                                self.snapshot.summary(),
                                self.mode,
                            )?);
                        }
                    }
                }
            }
            check_cancel(cancelled)?;
            return Ok(self.progress());
        }
        if let Some(paragraph) = &mut self.long_paragraph {
            paragraph.step(engine, &self.snapshot, self.mode, cancelled)?;
            check_cancel(cancelled)?;
            if paragraph.deferred() {
                let (summary, reference_slots) = self
                    .long_paragraph
                    .take()
                    .ok_or(Error::Invalid("markup deferred paragraph missing"))?
                    .into_deferred()?;
                self.buffer.clear();
                self.append(
                    engine,
                    Segment {
                        summary,
                        incoming: Carry::Root,
                        outgoing: Carry::Root,
                        parsed: false,
                        reference_slots,
                        code: None,
                        inline: None,
                        pending_inline: true,
                        dependent_inline: true,
                        definitions: None,
                        definition_base: 0,
                        boundaries: Vec::new(),
                        boundary_base: 0,
                        boundary_extent: 0,
                    },
                )?;
                if self.cursor == self.snapshot.summary() {
                    self.complete_index()?;
                }
            } else if paragraph.unsupported() {
                self.incomplete = true;
                self.stopped = true;
                self.long_paragraph = None;
            } else if paragraph.complete() {
                let (summary, inline, remaining, reference_slots) = self
                    .long_paragraph
                    .take()
                    .ok_or(Error::Invalid("markup long paragraph missing"))?
                    .finish()?;
                self.buffer = remaining;
                self.append(
                    engine,
                    Segment {
                        summary,
                        incoming: Carry::Root,
                        outgoing: Carry::Root,
                        parsed: false,
                        reference_slots,
                        code: None,
                        inline: Some(inline),
                        pending_inline: false,
                        dependent_inline: false,
                        definitions: None,
                        definition_base: 0,
                        boundaries: Vec::new(),
                        boundary_base: 0,
                        boundary_extent: 0,
                    },
                )?;
                if self.cursor == self.snapshot.summary() && self.buffer.is_empty() {
                    self.complete_index()?;
                }
            }
            return Ok(self.progress());
        }
        if let Some(load) = &mut self.container_load {
            if load.step(engine, self.snapshot.origin(), self.mode)? {
                self.containers = Some(
                    self.container_load
                        .take()
                        .ok_or(Error::Invalid("markup container load"))?
                        .finish()?,
                );
            }
            return Ok(self.progress());
        }
        if let Some(write) = &mut self.container_write {
            if write
                .write
                .step(engine, self.snapshot.origin(), self.mode)?
            {
                let pending = self
                    .container_write
                    .take()
                    .ok_or(Error::Invalid("markup container write missing"))?;
                let (outgoing, next) = pending.write.finish()?;
                self.append_parsed(engine, pending.parsed, outgoing, next)?;
            }
            check_cancel(cancelled)?;
            return Ok(self.progress());
        }
        if self.reuse_suffix(engine)? {
            return Ok(self.progress());
        }
        if self.begin_long_html(engine)? {
            return Ok(self.progress());
        }
        if self.begin_long_paragraph()? {
            return Ok(self.progress());
        }
        let read_at = self
            .cursor
            .bytes
            .checked_add(self.buffer.len() as u64)
            .ok_or(Error::Invalid("markup source cursor"))?;
        if read_at < self.snapshot.summary().bytes {
            let free = PROBE_BYTES - self.buffer.len();
            if free == 0 {
                // Completed child blocks resume their real container spine.
                // This unfinished individual block still needs paged inline
                // or table/HTML state; do not invent a terminating halo.
                self.incomplete = true;
                self.stopped = true;
                return Ok(self.progress());
            }
            let piece = engine.logical_source_piece(&self.snapshot, read_at)?;
            let text = piece.text()?;
            let first = usize::try_from(read_at - piece.before.bytes)
                .map_err(|_| Error::Invalid("markup source piece start"))?;
            let mut end = first
                .checked_add(free.min(TEXT_PAGE_BYTES))
                .ok_or(Error::Invalid("markup source piece end"))?
                .min(text.len());
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            if end <= first {
                self.incomplete = true;
                self.stopped = true;
                return Ok(self.progress());
            }
            self.buffer.push_str(&text[first..end]);
        }
        let eof = self.cursor.bytes.checked_add(self.buffer.len() as u64)
            == Some(self.snapshot.summary().bytes);
        match &self.carry {
            Carry::Fence(checkpoint) => {
                let mut fence = FenceContinuation::from_checkpoint(*checkpoint)
                    .ok_or(Error::Invalid("markup active fence"))?;
                let end = fence.consume(self.buffer.as_bytes(), eof);
                let (count, code_end, outgoing) = match end {
                    Some(end) => (
                        end.consumed,
                        end.range_end,
                        if end.closed {
                            Carry::Root
                        } else {
                            Carry::Fence(fence.checkpoint())
                        },
                    ),
                    None => (
                        self.buffer.len(),
                        self.buffer.len(),
                        Carry::Fence(fence.checkpoint()),
                    ),
                };
                if count > 0 {
                    self.append_literal(engine, count, Some((0, code_end as u32)), outgoing)?;
                }
            }
            Carry::Html(checkpoint) => {
                let mut html = HtmlContinuation::from_checkpoint(checkpoint.state)
                    .ok_or(Error::Invalid("markup active HTML"))?;
                let count = checkpoint
                    .opening
                    .as_ref()
                    .map_or(Ok(self.buffer.len()), |value| {
                        usize::try_from(value.remaining.min(self.buffer.len() as u64))
                            .map_err(|_| Error::Invalid("markup HTML dependency address space"))
                    })?;
                if !self.buffer.is_char_boundary(count) {
                    return Err(Error::Invalid("markup HTML dependency scalar endpoint"));
                }
                // End one derived segment exactly at the actual choice point;
                // later body edits need not rewind the distant opening again.
                let step = html
                    .consume(
                        &self.buffer[..count],
                        eof && count == self.buffer.len(),
                        cancelled,
                    )
                    .map_err(|error| match error {
                        pulldown_cmark::paged::InlineRunError::Cancelled => Error::Cancelled,
                        pulldown_cmark::paged::InlineRunError::Invalid(value) => {
                            Error::Invalid(value)
                        }
                    })?;
                if step.consumed > 0 {
                    let bytes = u64::try_from(step.consumed)
                        .map_err(|_| Error::Invalid("markup HTML quantum address space"))?;
                    let outgoing = if step.closed {
                        Carry::Root
                    } else {
                        Carry::Html(checkpoint.advance(html.checkpoint(), bytes)?)
                    };
                    self.append_literal(engine, step.consumed, None, outgoing)?;
                }
            }
            Carry::Root | Carry::Containers(_) => {
                let safe = if eof {
                    self.buffer.len()
                } else {
                    self.buffer.rfind('\n').map_or(0, |at| at + 1)
                };
                if safe > 0 {
                    let incoming = self.carry.clone();
                    let containers = self
                        .containers
                        .as_ref()
                        .ok_or(Error::Invalid("markup producer containers missing"))?;
                    let probe = probe_continuing_blocks(
                        &self.buffer[..safe],
                        self.mode.options(),
                        eof,
                        containers,
                    )
                    .ok_or(Error::Invalid("markup bounded first pass"))?;
                    let prefix = probe.prefix_bytes();
                    let fence = probe.open_fence();
                    let html = probe.open_html();
                    let incomplete = probe.incomplete();
                    if prefix > 0 {
                        let next = probe.outgoing().clone();
                        let outgoing = if &next == containers {
                            Some(incoming.clone())
                        } else if next.is_root() {
                            Some(Carry::Root)
                        } else {
                            None
                        };
                        let definitions = engine.write_definitions(
                            self.snapshot.origin(),
                            self.mode,
                            probe.references(),
                        )?;
                        let boundaries = engine.write_boundaries(
                            self.snapshot.origin(),
                            self.mode,
                            prefix,
                            probe.root_checkpoints().iter().copied(),
                        )?;
                        let summary = TextSummary::of(&self.buffer[..prefix]);
                        let parsed = ParsedCommit {
                            prefix,
                            fence,
                            html,
                            literal_bytes: safe - prefix,
                            incomplete,
                            segment: Segment {
                                summary,
                                incoming,
                                outgoing: Carry::Root,
                                parsed: true,
                                reference_slots: self.buffer[..prefix]
                                    .bytes()
                                    .filter(|byte| *byte == b'[')
                                    .count()
                                    as u64,
                                code: None,
                                inline: None,
                                pending_inline: false,
                                dependent_inline: false,
                                definitions,
                                definition_base: 0,
                                boundaries,
                                boundary_base: 0,
                                boundary_extent: prefix as u32,
                            },
                        };
                        if let Some(outgoing) = outgoing {
                            self.append_parsed(engine, parsed, outgoing, next)?;
                        } else {
                            self.container_write = Some(PendingContainerWrite {
                                parsed,
                                write: ContainerWrite::new(next)?,
                            });
                        }
                        check_cancel(cancelled)?;
                        return Ok(self.progress());
                    }
                    if incomplete {
                        self.incomplete = true;
                        self.stopped = true;
                        return Ok(self.progress());
                    }
                    if let Some((start, fence)) = fence {
                        let count = safe - prefix;
                        self.append_literal(
                            engine,
                            count,
                            Some(((start - prefix) as u32, count as u32)),
                            Carry::Fence(fence.checkpoint()),
                        )?;
                    } else if let Some((_, html)) = html {
                        self.append_literal(
                            engine,
                            safe - prefix,
                            None,
                            Carry::Html(HtmlCarry::fixed(html.checkpoint())),
                        )?;
                    }
                }
            }
        }
        check_cancel(cancelled)?;
        if self.cursor == self.snapshot.summary() && self.buffer.is_empty() {
            self.complete_index()?;
        } else if !self.begin_long_html(engine)?
            && !self.begin_long_paragraph()?
            && self.buffer.len() == PROBE_BYTES
        {
            self.incomplete = true;
            self.stopped = true;
        }
        Ok(self.progress())
    }
    /// A partial index remains visibly partial. It cannot prove reference
    /// absence or authorize media/inline projection in an unvisited block.
    pub fn finish(mut self) -> Result<Arc<MarkupIndex>> {
        if !self.stopped {
            return Err(Error::Invalid("markup producer has not joined"));
        }
        if let Some(ready) = self.ready.take() {
            return Ok(ready);
        }
        Ok(Arc::new(MarkupIndex {
            source: self.snapshot.markup_source(),
            mode: self.mode,
            root: self.root.take(),
            complete: false,
            definitions_complete: false,
        }))
    }
}

/// A fragment is bounded complete block input or copied display text. Long
/// paragraph styles come from separately stepped annotations in this SAME
/// context; no fragment slice is reparsed as an invented complete block.
/// Unknown reference/fuel/other unfinished coverage remains explicit.
pub struct MarkupFragment {
    pub start: TextSummary,
    pub text: String,
    pub code: Option<Range<usize>>,
    pub parsed: bool,
    pub containers: BlockCarry,
    /// The actual empty-definition parse attempted no reference lookups in
    /// this complete block. Its local result cannot depend on distant defs or
    /// on the whole-source reference-expansion counter. None means this block
    /// has not yet completed its first actual discovery parse; it is no proof.
    reference_independent: Option<bool>,
    reference_indices: Vec<u16>,
    pub inline_ready: bool,
    /// A complete ordinary inline subtree at its actual paragraph source
    /// point. It cannot be reparsed as a fresh block/reference definition.
    pub inline_only: bool,
}
pub struct MarkupContext {
    pub source_id: Uuid,
    pub mode: MarkupMode,
    pub window: Range<u64>,
    pub window_start: TextSummary,
    pub window_end: TextSummary,
    pub fragments: Vec<MarkupFragment>,
    pub inline_styles: Vec<pulldown_cmark::paged::InlineStyle>,
    pub inline_media: Vec<(
        Uuid,
        pulldown_cmark::paged::InlinePoint,
        pulldown_cmark::paged::InlinePoint,
    )>,
    /// Actual whole-paragraph UTF16 range and pinned setext level.
    pub inline_headings: Vec<(Range<u64>, u8)>,
    references: Vec<NeededReference>,
    /// Every visible parsed block is ready. Per-fragment independent proofs
    /// may be ready before global EOF; dependent blocks still require actual
    /// definition/fuel proof. No partial absence becomes a global assertion.
    pub reference_budget_proven: bool,
    /// The indexed grammar prefix covers this window, not necessarily EOF.
    pub complete_blocks: bool,
}
impl MarkupContext {
    pub fn definitions(&self) -> RefDefs<'_> {
        let mut values = RefDefs::default();
        for reference in &self.references {
            if let Some(value) = &reference.value {
                values.insert_parsed(value.borrowed());
            }
        }
        values
    }
    /// A complete block needs only labels actually accessed by its own parser
    /// iterations. Global first-definition selection has already been proved.
    pub fn definitions_for(&self, fragment: &MarkupFragment) -> Result<RefDefs<'_>> {
        let mut values = RefDefs::default();
        for &index in &fragment.reference_indices {
            let reference = self
                .references
                .get(usize::from(index))
                .ok_or(Error::Invalid("markup fragment reference index"))?;
            if let Some(value) = &reference.value {
                values.insert_parsed(value.borrowed());
            }
        }
        Ok(values)
    }
}
const REFERENCE_BUCKETS: usize = 2048;
const NO_REFERENCE: u16 = u16::MAX;
const REFERENCE_CHAIN_LIMIT: usize = 64;
struct NeededReference {
    label: String,
    hash: u64,
    value: Option<Arc<ParsedReference<'static>>>,
    searched: bool,
    next: u16,
}
fn reference_bucket(hash: u64) -> usize {
    ((hash ^ (hash >> 32)) as usize) & (REFERENCE_BUCKETS - 1)
}
fn find_reference(
    values: &[NeededReference],
    heads: &[u16; REFERENCE_BUCKETS],
    hash: u64,
    label: &str,
    probes: &mut u64,
    maximum: &mut usize,
) -> Result<Option<usize>> {
    let mut at = heads[reference_bucket(hash)];
    let mut count = 0;
    while at != NO_REFERENCE {
        if count == REFERENCE_CHAIN_LIMIT {
            return Err(Error::Invalid("markup reference collision work bound"));
        }
        count += 1;
        *probes = probes
            .checked_add(1)
            .ok_or(Error::Invalid("markup reference probe counter"))?;
        *maximum = (*maximum).max(count);
        let value = values
            .get(usize::from(at))
            .ok_or(Error::Invalid("markup reference bucket index"))?;
        if value.hash == hash && reference_labels_equal(&value.label, label) {
            return Ok(Some(usize::from(at)));
        }
        at = value.next;
    }
    Ok(None)
}
enum ReferenceProgress {
    Scanning,
    Lookup,
    Finished,
}
struct QuerySegment {
    before: TextSummary,
    segment: Segment,
}
struct DefinitionScan {
    root: DefinitionRef,
    before: TextSummary,
    segment: Segment,
}
struct PendingFragment {
    source: QuerySegment,
    start: TextSummary,
    text: String,
    code: Option<Range<usize>>,
    definition: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkupQueryProgress {
    pub complete: bool,
    pub buffered_bytes: usize,
    pub incomplete_inline: bool,
    pub unique_references: usize,
    pub reference_probes: u64,
    pub max_reference_probes: usize,
    /// Actual retained capacities/requested payload for the operation-local
    /// reference index, including Arc values and selected dependency indices.
    /// Excludes allocator overhead, temporary parser maps and the host cache.
    pub retained_reference_bytes: usize,
}

/// Read-only continuation over one exact index/window. One step reads one index
/// page, one source fragment, or one definition candidate fragment. Hosts yield
/// the same independent reader lane between steps, including negative lookups.
pub struct MarkupQuery {
    snapshot: LogicalSnapshot,
    index: Arc<MarkupIndex>,
    window: Range<u64>,
    window_start: TextSummary,
    window_end: TextSummary,
    stack: Vec<(MarkRef, TextSummary)>,
    segments: VecDeque<QuerySegment>,
    fragments: Vec<MarkupFragment>,
    inline_styles: Vec<pulldown_cmark::paged::InlineStyle>,
    inline_media: Vec<(
        Uuid,
        pulldown_cmark::paged::InlinePoint,
        pulldown_cmark::paged::InlinePoint,
    )>,
    inline_headings: Vec<(Range<u64>, u8)>,
    inline_scans: VecDeque<InlineScan>,
    inline_fragments: VecDeque<(
        pulldown_cmark::paged::InlinePoint,
        pulldown_cmark::paged::InlinePoint,
    )>,
    inline_fragment_bytes: usize,
    last_inline_fragment_end: u64,
    fragment_text_bytes: usize,
    references: Vec<NeededReference>,
    reference_heads: Box<[u16; REFERENCE_BUCKETS]>,
    reference_probes: u64,
    max_reference_probes: usize,
    reference_payload_bytes: usize,
    dependency_capacity_bytes: usize,
    definition_stack: Vec<DefinitionScan>,
    candidate: Option<QuerySegment>,
    pending_fragment: Option<PendingFragment>,
    container_load: Option<ContainerLoad>,
    boundary_load: bool,
    lookup: bool,
    complete: bool,
    incomplete_inline: bool,
    label_bytes: usize,
    definition_bytes: usize,
    reference_scan: usize,
    reference_round_changed: bool,
    budget_proven: bool,
    operand_probe: bool,
    pending_inline: bool,
    reference_finished: bool,
    inline_validation: usize,
}
impl MarkupQuery {
    pub fn new(window: &LogicalWindow, index: Arc<MarkupIndex>) -> Result<Self> {
        if window.text().len() > NATIVE_WINDOW_BYTES {
            return Err(Error::Invalid("markup native window bound"));
        }
        let start = window.start();
        let end = start.checked_add(window.local_summary())?;
        Self::from_range(window.snapshot().clone(), index, start, end, true)
    }
    fn from_range(
        snapshot: LogicalSnapshot,
        index: Arc<MarkupIndex>,
        start: TextSummary,
        end: TextSummary,
        visit_window: bool,
    ) -> Result<Self> {
        if snapshot.id() != index.source.id || snapshot.summary() != index.source.summary {
            return Err(Error::Stale);
        }
        start.validate()?;
        end.validate()?;
        if start.bytes > end.bytes
            || end.bytes > snapshot.summary().bytes
            || start.utf16 > end.utf16
            || end.utf16 > snapshot.summary().utf16
        {
            return Err(Error::Invalid("markup actual query extent"));
        }
        let stack = if visit_window {
            index
                .root
                .as_ref()
                .map_or_else(Vec::new, |root| vec![(root.clone(), TextSummary::EMPTY)])
        } else {
            Vec::new()
        };
        let budget_proven = index.definitions_complete
            && index.root.as_ref().is_none_or(|root| {
                root.reference_slots
                    .checked_mul(root.max_definition_cost)
                    .is_some_and(|upper| upper <= index.source.summary.bytes.max(100_000))
            });
        Ok(Self {
            snapshot,
            index,
            window: start.bytes..end.bytes,
            window_start: start,
            window_end: end,
            stack,
            segments: VecDeque::new(),
            fragments: Vec::new(),
            inline_styles: Vec::new(),
            inline_media: Vec::new(),
            inline_headings: Vec::new(),
            inline_scans: VecDeque::new(),
            inline_fragments: VecDeque::new(),
            inline_fragment_bytes: 0,
            last_inline_fragment_end: 0,
            fragment_text_bytes: 0,
            references: Vec::new(),
            reference_heads: Box::new([NO_REFERENCE; REFERENCE_BUCKETS]),
            reference_probes: 0,
            max_reference_probes: 0,
            reference_payload_bytes: 0,
            dependency_capacity_bytes: 0,
            definition_stack: Vec::new(),
            candidate: None,
            pending_fragment: None,
            container_load: None,
            boundary_load: false,
            lookup: false,
            complete: false,
            incomplete_inline: false,
            label_bytes: 0,
            definition_bytes: 0,
            reference_scan: 0,
            reference_round_changed: false,
            budget_proven,
            operand_probe: false,
            pending_inline: false,
            reference_finished: false,
            inline_validation: 0,
        })
    }
    // Internal reference discovery only, never an authenticated native window
    // or a display-ready completed grammar claim. Its source String moves
    // from the existing paragraph buffer and is released during disk lookup.
    fn inline_operand(
        snapshot: &LogicalSnapshot,
        index: Arc<MarkupIndex>,
        start: TextSummary,
        text: String,
    ) -> Result<Self> {
        if text.is_empty() || text.len() > PROBE_BYTES || !index.definitions_complete {
            return Err(Error::Invalid(
                "markup inline reference operand bound/search",
            ));
        }
        let end = start.checked_add(TextSummary::of(&text))?;
        let mut value = Self::from_range(snapshot.clone(), index, start, end, false)?;
        value.operand_probe = true;
        value.fragment_text_bytes = text.len();
        value.fragments.push(MarkupFragment {
            start,
            text,
            code: None,
            parsed: true,
            containers: BlockCarry::default(),
            reference_independent: None,
            reference_indices: Vec::new(),
            inline_ready: false,
            inline_only: true,
        });
        Ok(value)
    }
    fn copied_source_bytes(&self) -> usize {
        self.fragment_text_bytes
            + self
                .pending_fragment
                .as_ref()
                .map_or(0, |value| value.text.len())
    }
    pub fn progress(&self) -> MarkupQueryProgress {
        MarkupQueryProgress {
            complete: self.complete,
            buffered_bytes: self.fragment_text_bytes
                + self.label_bytes
                + self.definition_bytes
                + self
                    .pending_fragment
                    .as_ref()
                    .map_or(0, |value| value.text.len()),
            incomplete_inline: self.incomplete_inline,
            unique_references: self.references.len(),
            reference_probes: self.reference_probes,
            max_reference_probes: self.max_reference_probes,
            retained_reference_bytes: self.retained_reference_bytes(),
        }
    }
    fn retained_reference_bytes(&self) -> usize {
        std::mem::size_of::<[u16; REFERENCE_BUCKETS]>()
            + self.references.capacity() * std::mem::size_of::<NeededReference>()
            + self.reference_payload_bytes
            + self.dependency_capacity_bytes
    }
    fn wanted(&self, labels: Labels) -> bool {
        self.references
            .iter()
            .any(|value| value.value.is_none() && !value.searched && labels.contains(value.hash))
    }
    fn collect_references(
        &mut self,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<ReferenceProgress> {
        use pulldown_cmark::{BrokenLink, Parser};
        let mut refused = false;
        let scan = self.reference_scan;
        if self
            .fragments
            .get(scan)
            .is_some_and(|value| value.parsed && value.reference_independent != Some(true))
        {
            // Hold only actual immutable selected values outside the mutable
            // membership Vec. New labels may reallocate that Vec safely; URL/
            // title bytes remain in these shared immutable parsed definitions.
            let prior_indices = self.fragments[scan].reference_indices.clone();
            let selected = prior_indices
                .iter()
                .filter_map(|&index| {
                    self.references
                        .get(usize::from(index))
                        .and_then(|value| value.value.clone())
                })
                .collect::<Vec<_>>();
            let mut definitions = RefDefs::default();
            for value in &selected {
                definitions.insert_parsed(value.borrowed());
            }
            let fragment = &mut self.fragments[scan];
            let mut indices = std::mem::take(&mut fragment.reference_indices);
            let old_dependency_bytes = indices.capacity() * std::mem::size_of::<u16>();
            self.dependency_capacity_bytes -= old_dependency_bytes;
            let before = self.references.len();
            let mut accessed = false;
            let mut known_but_not_selected = false;
            {
                let references = &mut self.references;
                let heads = &mut *self.reference_heads;
                let bytes = &mut self.label_bytes;
                let payload = &mut self.reference_payload_bytes;
                let probes = &mut self.reference_probes;
                let maximum = &mut self.max_reference_probes;
                let mut collect = |link: BrokenLink<'_>| {
                    accessed = true;
                    let label = link.reference.as_ref();
                    let hash = reference_label_hash(label);
                    let found =
                        match find_reference(references, heads, hash, label, probes, maximum) {
                            Ok(value) => value,
                            Err(_) => {
                                refused = true;
                                return None;
                            }
                        };
                    let index = if let Some(index) = found {
                        index
                    } else {
                        if references.len() >= 8192
                            || bytes
                                .checked_add(label.len())
                                .is_none_or(|value| value > PROBE_BYTES * 4)
                        {
                            refused = true;
                            return None;
                        }
                        let index = references.len();
                        let bucket = reference_bucket(hash);
                        let label = label.to_owned();
                        *bytes += label.len();
                        *payload += label.capacity();
                        references.push(NeededReference {
                            label,
                            hash,
                            value: None,
                            searched: false,
                            next: heads[bucket],
                        });
                        heads[bucket] = index as u16;
                        index
                    };
                    if references[index].value.is_some()
                        && prior_indices.binary_search(&(index as u16)).is_err()
                    {
                        known_but_not_selected = true;
                    }
                    if indices.len() == PROBE_BYTES {
                        refused = true;
                        return None;
                    }
                    indices.push(index as u16);
                    None
                };
                let parser = if fragment.inline_only {
                    Parser::new_with_broken_link_callback_for_inline(
                        &fragment.text,
                        self.index.mode.options(),
                        Some(&mut collect),
                    )
                    .ok_or(Error::Invalid("markup inline reference parser bound"))?
                } else {
                    Parser::new_with_broken_link_callback_and_containers(
                        &fragment.text,
                        self.index.mode.options(),
                        Some(&mut collect),
                        &fragment.containers,
                    )
                };
                let mut parser = parser
                    .with_reference_definitions(definitions)
                    .with_reference_fuel(usize::MAX)
                    .into_offset_iter();
                loop {
                    if parser
                        .next_with_check(cancelled)
                        .map_err(|_| Error::Cancelled)?
                        .is_none()
                    {
                        break;
                    }
                }
            }
            indices.sort_unstable();
            indices.dedup();
            self.dependency_capacity_bytes += indices.capacity() * std::mem::size_of::<u16>();
            fragment.reference_indices = indices;
            fragment.reference_independent =
                Some(fragment.reference_independent.unwrap_or(true) && !accessed);
            self.reference_round_changed |=
                self.references.len() != before || known_but_not_selected;
        }
        if refused {
            self.incomplete_inline = true;
            self.complete = true;
            return Ok(ReferenceProgress::Finished);
        }
        self.reference_scan = self
            .reference_scan
            .checked_add(1)
            .ok_or(Error::Invalid("markup reference scan cursor"))?;
        if self.reference_scan < self.fragments.len() {
            return Ok(ReferenceProgress::Scanning);
        }
        self.reference_scan = 0;
        Ok(if std::mem::take(&mut self.reference_round_changed) {
            ReferenceProgress::Lookup
        } else {
            ReferenceProgress::Finished
        })
    }
    fn start_lookup(&mut self) {
        self.stack = self
            .index
            .root
            .as_ref()
            .map_or_else(Vec::new, |root| vec![(root.clone(), TextSummary::EMPTY)]);
        self.lookup = true;
        if self.operand_probe {
            // The immutable source can supply this <=32KiB operand again.
            // Do not retain it alongside a copied definition candidate.
            for fragment in &mut self.fragments {
                fragment.text = String::new();
            }
            self.fragment_text_bytes = 0;
        }
    }
    fn validate_next_inline<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        // Ordinary blocks already completed their actual reference rounds.
        // Skip a bounded batch of those descriptors, rather than adding an
        // extra host turn per unrelated block to every existing query.
        for _ in 0..128 {
            let Some(fragment) = self.fragments.get(self.inline_validation) else {
                self.complete = true;
                return Ok(());
            };
            self.inline_validation = self
                .inline_validation
                .checked_add(1)
                .ok_or(Error::Invalid("markup inline validation cursor"))?;
            if self.operand_probe
                || !fragment.inline_only
                || fragment.reference_independent == Some(true)
            {
                continue;
            }
            if !self.budget_proven {
                self.incomplete_inline = true;
                self.complete = true;
                return Ok(());
            }
            let mut definitions = RefDefs::default();
            for &index in &fragment.reference_indices {
                let value = self
                    .references
                    .get(usize::from(index))
                    .ok_or(Error::Invalid("markup inline selected reference"))?;
                if let Some(value) = &value.value {
                    definitions.insert_parsed(value.borrowed());
                }
            }
            let after = fragment
                .start
                .bytes
                .checked_add(fragment.text.len() as u64)
                .ok_or(Error::Invalid("markup reference follower source extent"))?;
            let following = if after < self.snapshot.summary().bytes {
                let end = after
                    .checked_add(1)
                    .ok_or(Error::Invalid("markup reference follower end"))?;
                Some(
                    *engine
                        .logical_read_range(&self.snapshot, after..end, cancelled)?
                        .first()
                        .ok_or(Error::Invalid("markup reference follower source missing"))?,
                )
            } else {
                None
            };
            let proved = pulldown_cmark::paged::probe_inline_link_with_definitions(
                &fragment.text,
                self.index.mode.options(),
                definitions,
                true,
                following,
                cancelled,
            )
            .map_err(inline::inline_error)?;
            if proved.is_none_or(|value| value.end() != fragment.text.len()) {
                self.incomplete_inline = true;
                self.complete = true;
            }
            // At most one actual parser/source read per step.
            return Ok(());
        }
        Ok(())
    }
    fn finish_fragment(&mut self, value: PendingFragment, containers: BlockCarry) -> Result<()> {
        if value.definition {
            if TextSummary::of(&value.text) != value.source.segment.summary {
                return Err(Error::Invalid("markup definition source summary"));
            }
            let probe =
                probe_continuing_blocks(&value.text, self.index.mode.options(), true, &containers)
                    .ok_or(Error::Invalid("markup candidate first pass"))?;
            if probe.incomplete() {
                self.incomplete_inline = true;
                self.complete = true;
                return Ok(());
            }
            for definition in probe.references() {
                let matched = find_reference(
                    &self.references,
                    &self.reference_heads,
                    definition.label_hash(),
                    definition.label(),
                    &mut self.reference_probes,
                    &mut self.max_reference_probes,
                );
                let index = match matched {
                    Ok(Some(index)) => index,
                    Ok(None) => continue,
                    Err(_) => {
                        self.incomplete_inline = true;
                        self.complete = true;
                        return Ok(());
                    }
                };
                let needed = &mut self.references[index];
                if needed.value.is_none() {
                    let count = definition.label().len()
                        + definition.definition().dest.len()
                        + definition
                            .definition()
                            .title
                            .as_ref()
                            .map_or(0, |title| title.len());
                    if self
                        .definition_bytes
                        .checked_add(count)
                        .is_none_or(|value| value > PROBE_BYTES * 4)
                    {
                        self.incomplete_inline = true;
                        self.complete = true;
                        return Ok(());
                    }
                    self.definition_bytes += count;
                    let value = Arc::new(definition.clone());
                    self.reference_payload_bytes += 2 * std::mem::size_of::<usize>()
                        + std::mem::size_of::<ParsedReference<'static>>()
                        + value.owned_payload_bytes();
                    needed.value = Some(value);
                }
            }
        } else {
            self.fragment_text_bytes = self
                .fragment_text_bytes
                .checked_add(value.text.len())
                .ok_or(Error::Invalid("markup fragment byte count"))?;
            self.fragments.push(MarkupFragment {
                start: value.start,
                text: value.text,
                code: value.code,
                parsed: value.source.segment.parsed,
                containers,
                reference_independent: None,
                reference_indices: Vec::new(),
                inline_ready: false,
                inline_only: false,
            });
        }
        Ok(())
    }
    fn begin_fragment<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        source: QuerySegment,
        definition: bool,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        let end = source.before.checked_add(source.segment.summary)?;
        self.pending_inline |= source.segment.pending_inline;
        self.incomplete_inline |= source.segment.pending_inline;
        if let Some(value) = &source.segment.inline {
            if definition {
                return Err(Error::Invalid(
                    "markup inline paragraph cannot define references",
                ));
            }
            self.inline_scans.push_back(InlineScan::new(
                value,
                source.before,
                source.segment.summary,
                &self.window,
            )?);
            if let Some(level) = value.heading {
                self.inline_headings
                    .push((source.before.utf16..end.utf16, level));
            }
        }
        let (first, last) = if definition || source.segment.parsed {
            (source.before.bytes, end.bytes)
        } else {
            (
                source.before.bytes.max(self.window.start),
                end.bytes.min(self.window.end),
            )
        };
        if first >= last {
            return Ok(());
        }
        let bytes = engine.logical_read_range(&self.snapshot, first..last, cancelled)?;
        let text =
            String::from_utf8(bytes).map_err(|_| Error::Invalid("markup query fragment UTF8"))?;
        let start = engine.logical_byte_position(&self.snapshot, first)?.point();
        let code = source
            .segment
            .code
            .map(|(begin, end)| {
                let a = (source.before.bytes + u64::from(begin)).max(first);
                let b = (source.before.bytes + u64::from(end)).min(last);
                (a - start.bytes) as usize..b.saturating_sub(start.bytes) as usize
            })
            .filter(|range| range.start < range.end);
        let containers = match &source.segment.incoming {
            Carry::Containers(value) => Some(ContainerLoad::new(value.clone())?),
            _ => None,
        };
        let value = PendingFragment {
            source,
            start,
            text,
            code,
            definition,
        };
        if let Some(load) = containers {
            self.pending_fragment = Some(value);
            self.container_load = Some(load);
        } else if !definition
            && value.source.segment.parsed
            && value.source.segment.incoming == Carry::Root
            && value.source.segment.outgoing == Carry::Root
        {
            self.pending_fragment = Some(value);
            self.boundary_load = true;
        } else {
            self.finish_fragment(value, BlockCarry::default())?;
        }
        Ok(())
    }
    fn finish_root_fragments(
        &mut self,
        value: PendingFragment,
        bitmap: &[u8],
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        let segment = &value.source.segment;
        if TextSummary::of(&value.text) != segment.summary || value.start != value.source.before {
            return Err(Error::Invalid("markup root fragment source summary"));
        }
        let base = usize::try_from(segment.boundary_base)
            .map_err(|_| Error::Invalid("markup root boundary base"))?;
        let is_boundary = |at: usize| -> Result<bool> {
            let bit = base
                .checked_add(at)
                .ok_or(Error::Invalid("markup root boundary address"))?;
            Ok(*bitmap
                .get(45 + bit / 8)
                .ok_or(Error::Invalid("markup root boundary bitmap"))?
                & (1u8 << (bit % 8))
                != 0)
        };
        if !is_boundary(0)? {
            return Err(Error::Invalid("markup missing fragment root boundary"));
        }
        let mut first = 0;
        let mut start = value.start;
        for last in 1..=value.text.len() {
            if last % 128 == 0 {
                check_cancel(cancelled)?;
            }
            if last != value.text.len() && !is_boundary(last)? {
                continue;
            }
            if !value.text.is_char_boundary(last) {
                return Err(Error::Invalid("markup non-scalar root boundary"));
            }
            let text = &value.text[first..last];
            let end = start.checked_add(TextSummary::of(text))?;
            if start.bytes < self.window.end && end.bytes > self.window.start {
                self.fragment_text_bytes = self
                    .fragment_text_bytes
                    .checked_add(text.len())
                    .ok_or(Error::Invalid("markup fragment byte count"))?;
                self.fragments.push(MarkupFragment {
                    start,
                    text: text.into(),
                    code: None,
                    parsed: true,
                    containers: BlockCarry::default(),
                    reference_independent: None,
                    reference_indices: Vec::new(),
                    inline_ready: false,
                    inline_only: false,
                });
            }
            start = end;
            first = last;
        }
        if start != value.source.before.checked_add(segment.summary)? {
            return Err(Error::Invalid("markup split root summary"));
        }
        Ok(())
    }
    pub fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<MarkupQueryProgress> {
        check_cancel(cancelled)?;
        if self.complete {
            return Ok(self.progress());
        }
        if self.reference_finished {
            self.validate_next_inline(engine, cancelled)?;
            return Ok(self.progress());
        }
        if self.operand_probe
            && !self.lookup
            && self
                .fragments
                .first()
                .is_some_and(|value| value.text.is_empty())
        {
            let bytes =
                engine.logical_read_range(&self.snapshot, self.window.clone(), cancelled)?;
            let text = String::from_utf8(bytes)
                .map_err(|_| Error::Invalid("markup inline reference reload UTF8"))?;
            if self.window_start.checked_add(TextSummary::of(&text))? != self.window_end {
                return Err(Error::Invalid("markup inline reference reload summary"));
            }
            self.fragment_text_bytes = text.len();
            self.fragments[0].text = text;
            return Ok(self.progress());
        }
        if let Some((first, last)) = self.inline_fragments.pop_front() {
            let bytes = last
                .bytes
                .checked_sub(first.bytes)
                .filter(|bytes| *bytes > 0 && *bytes <= PROBE_BYTES as u64)
                .ok_or(Error::Invalid("markup queried inline subtree extent"))?;
            if first.bytes < self.last_inline_fragment_end
                || first.bytes >= self.window.end
                || last.bytes <= self.window.start
            {
                return Err(Error::Invalid("markup inline subtree source order/window"));
            }
            let count = usize::try_from(bytes)
                .map_err(|_| Error::Invalid("markup inline subtree address space"))?;
            let charge = self
                .inline_fragment_bytes
                .checked_add(count)
                .filter(|value| *value <= 2 * PROBE_BYTES + NATIVE_WINDOW_BYTES)
                .ok_or(Error::Invalid("markup copied inline subtree budget"))?;
            let text = String::from_utf8(engine.logical_read_range(
                &self.snapshot,
                first.bytes..last.bytes,
                cancelled,
            )?)
            .map_err(|_| Error::Invalid("markup inline subtree UTF8"))?;
            let start = engine
                .logical_byte_position(&self.snapshot, first.bytes)?
                .point();
            let summary = TextSummary::of(&text);
            if start.utf16 != first.utf16 || start.checked_add(summary)?.utf16 != last.utf16 {
                return Err(Error::Invalid("markup inline subtree source counters"));
            }
            let proved = pulldown_cmark::paged::probe_inline_link(
                &text,
                self.index.mode.options(),
                cancelled,
            )
            .map_err(|error| match error {
                pulldown_cmark::paged::InlineRunError::Cancelled => Error::Cancelled,
                pulldown_cmark::paged::InlineRunError::Invalid(value) => Error::Invalid(value),
            })?;
            let independent = proved.is_some_and(|value| value.end() == text.len());

            self.inline_fragment_bytes = charge;
            self.last_inline_fragment_end = last.bytes;
            self.fragment_text_bytes = self
                .fragment_text_bytes
                .checked_add(count)
                .ok_or(Error::Invalid("markup inline subtree retained bytes"))?;
            self.fragments.push(MarkupFragment {
                start,
                text,
                code: None,
                parsed: true,
                containers: BlockCarry::default(),
                reference_independent: independent.then_some(true),
                reference_indices: Vec::new(),
                inline_ready: false,
                inline_only: true,
            });
            return Ok(self.progress());
        }
        if let Some(scan) = self.inline_scans.front_mut() {
            if scan.step(
                engine,
                self.snapshot.origin(),
                self.index.mode,
                &mut self.inline_styles,
                &mut self.inline_media,
                &mut self.inline_fragments,
            )? {
                self.inline_scans.pop_front();
            }
            return Ok(self.progress());
        }
        if self.boundary_load {
            let fragment = self
                .pending_fragment
                .take()
                .ok_or(Error::Invalid("markup pending root fragment"))?;
            // PROBE_BYTES is smaller than TEXT_PAGE_BYTES, so the source-bound
            // bitmap fits one derived page even after a path-copy segment split.
            let bits = engine.boundary_bits(
                self.snapshot.origin(),
                self.index.mode,
                &fragment.source.segment,
                0,
            )?;
            self.boundary_load = false;
            self.finish_root_fragments(fragment, &bits, cancelled)?;
            return Ok(self.progress());
        }
        if let Some(load) = &mut self.container_load {
            if load.step(engine, self.snapshot.origin(), self.index.mode)? {
                let containers = self
                    .container_load
                    .take()
                    .ok_or(Error::Invalid("markup query container load"))?
                    .finish()?;
                let fragment = self
                    .pending_fragment
                    .take()
                    .ok_or(Error::Invalid("markup query pending fragment"))?;
                self.finish_fragment(fragment, containers)?;
            }
            return Ok(self.progress());
        }
        if let Some(candidate) = self.candidate.take() {
            self.begin_fragment(engine, candidate, true, cancelled)?;
            return Ok(self.progress());
        }
        if let Some(scan) = self.definition_stack.pop() {
            validate_definition_ref(&scan.root)?;
            let node =
                engine.read_mark_page(self.snapshot.origin(), self.index.mode, &scan.root.page)?;
            match node {
                MarkNode::Definitions(values)
                    if scan.root.height == 0
                        && !values.is_empty()
                        && values.len() <= MARK_FANOUT =>
                {
                    let mut labels = Labels::default();
                    let mut max_cost = 0;
                    let mut last_end = 0;
                    let mut relevant = false;
                    for value in &values {
                        if value.start < last_end
                            || value.start >= value.end
                            || value.end > scan.segment.boundary_extent
                            || value.cost > 2 * PROBE_BYTES as u64
                        {
                            return Err(Error::Invalid("markup definition candidate range/order"));
                        }
                        last_end = value.end;
                        labels.add(value.hash);
                        max_cost = max_cost.max(value.cost);
                        if value.start >= scan.segment.definition_base
                            && u64::from(value.end - scan.segment.definition_base)
                                <= scan.segment.summary.bytes
                        {
                            relevant |= self.references.iter().any(|needed| {
                                needed.value.is_none()
                                    && !needed.searched
                                    && needed.hash == value.hash
                            });
                        }
                    }
                    if values.len() as u64 != scan.root.count
                        || labels != scan.root.labels
                        || max_cost != scan.root.max_cost
                    {
                        return Err(Error::Invalid("markup definition leaf aggregate"));
                    }
                    if relevant {
                        self.candidate = Some(QuerySegment {
                            before: scan.before,
                            segment: scan.segment,
                        });
                    }
                }
                MarkNode::DefinitionBranch(values)
                    if scan.root.height > 0
                        && !values.is_empty()
                        && values.len() <= MARK_FANOUT =>
                {
                    let mut count = 0u64;
                    let mut labels = Labels::default();
                    let mut max_cost = 0;
                    for value in &values {
                        validate_definition_ref(value)?;
                        if value.height.checked_add(1) != Some(scan.root.height) {
                            return Err(Error::Invalid("markup definition branch height"));
                        }
                        count = count
                            .checked_add(value.count)
                            .ok_or(Error::Invalid("markup definition branch count"))?;
                        labels = labels.union(value.labels);
                        max_cost = max_cost.max(value.max_cost);
                    }
                    if count != scan.root.count
                        || labels != scan.root.labels
                        || max_cost != scan.root.max_cost
                    {
                        return Err(Error::Invalid("markup definition branch aggregate"));
                    }
                    for root in values.into_iter().rev() {
                        if self.wanted(root.labels) {
                            self.definition_stack.push(DefinitionScan {
                                root,
                                before: scan.before,
                                segment: scan.segment.clone(),
                            });
                        }
                    }
                }
                _ => return Err(Error::Invalid("markup definition page kind")),
            }
            return Ok(self.progress());
        }
        if let Some(segment) = self.segments.pop_front() {
            if self.lookup {
                if let Some(root) = &segment.segment.definitions
                    && self.wanted(root.labels)
                {
                    self.definition_stack.push(DefinitionScan {
                        root: root.clone(),
                        before: segment.before,
                        segment: segment.segment,
                    });
                }
            } else {
                self.begin_fragment(engine, segment, false, cancelled)?;
            }
            return Ok(self.progress());
        }
        if let Some((root, before)) = self.stack.pop() {
            if self.lookup && !self.wanted(root.labels) {
                return Ok(self.progress());
            }
            let node = engine.mark_node(self.snapshot.origin(), self.index.mode, &root)?;
            match node {
                MarkNode::Branch(values) => {
                    let mut at = before;
                    let mut children = Vec::with_capacity(MARK_FANOUT);
                    for value in values {
                        let end = at.checked_add(value.summary)?;
                        if (self.lookup && self.wanted(value.labels))
                            || (!self.lookup
                                && at.bytes < self.window.end
                                && end.bytes > self.window.start)
                        {
                            children.push((value, at));
                        }
                        at = end;
                    }
                    self.stack.extend(children.into_iter().rev());
                }
                MarkNode::Segments(values) => {
                    let mut at = before;
                    for segment in values {
                        let end = at.checked_add(segment.summary)?;
                        if (self.lookup && self.wanted(segment.labels()))
                            || (!self.lookup
                                && at.bytes < self.window.end
                                && end.bytes > self.window.start)
                        {
                            self.segments.push_back(QuerySegment {
                                before: at,
                                segment,
                            });
                        }
                        at = end;
                    }
                }
                _ => return Err(Error::Invalid("markup query node")),
            }
            return Ok(self.progress());
        }
        if self.lookup {
            for value in &mut self.references {
                value.searched = true;
            }
            self.lookup = false;
            if self.operand_probe {
                return Ok(self.progress());
            }
        }
        match self.collect_references(cancelled)? {
            ReferenceProgress::Scanning => {}
            ReferenceProgress::Lookup => self.start_lookup(),
            ReferenceProgress::Finished => {
                // Only a complete global search proves missing definitions absent.
                // Prefix lookup cannot invent the whole-source expansion counter.
                self.budget_proven |= self.index.definitions_complete
                    && self.references.iter().all(|value| value.value.is_none());
                self.incomplete_inline |= !self.budget_proven
                    && self
                        .fragments
                        .iter()
                        .any(|value| value.parsed && value.reference_independent != Some(true));
                self.reference_finished = true;
            }
        }
        Ok(self.progress())
    }
    pub fn finish(mut self) -> Result<MarkupContext> {
        if !self.complete {
            return Err(Error::Invalid("markup query has not joined"));
        }
        let proof = self.budget_proven && !self.incomplete_inline;
        for fragment in &mut self.fragments {
            fragment.inline_ready =
                fragment.parsed && (fragment.reference_independent == Some(true) || proof);
        }
        let covered = self.window.end <= self.index.indexed_summary().bytes;
        let inline_ready = self
            .fragments
            .iter()
            .all(|value| !value.parsed || value.inline_ready);
        Ok(MarkupContext {
            source_id: self.snapshot.id(),
            mode: self.index.mode,
            window: self.window,
            window_start: self.window_start,
            window_end: self.window_end,
            fragments: self.fragments,
            inline_styles: self.inline_styles,
            inline_media: self.inline_media,
            inline_headings: self.inline_headings,
            references: self.references,
            reference_budget_proven: covered && inline_ready && !self.pending_inline,
            complete_blocks: covered && !self.operand_probe && !self.pending_inline,
        })
    }
}
