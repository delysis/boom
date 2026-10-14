//! The native editor's immutable logical source, separate from file publication.
//!
//! A newly opened GiB document is one file span. Edits path-copy the same
//! bounded-fanout split/join shape used by the file tree, with shared insertion
//! blocks instead of writing index pages. Only a prepared bounded window can
//! supply edit endpoints; the input path has no PageProvider or engine mutex.
//! Snapshots are ordinary Arc values, not entries in a second handle registry.
use super::*;
use std::sync::{Mutex, OnceLock};

pub const NATIVE_WINDOW_BYTES: usize = 24 * 1024;

pub(super) fn difference(end: TextSummary, start: TextSummary) -> Result<TextSummary> {
    let value = TextSummary {
        bytes: end
            .bytes
            .checked_sub(start.bytes)
            .ok_or(Error::Invalid("logical byte order"))?,
        utf16: end
            .utf16
            .checked_sub(start.utf16)
            .ok_or(Error::Invalid("logical UTF16 order"))?,
        lf_count: end
            .lf_count
            .checked_sub(start.lf_count)
            .ok_or(Error::Invalid("logical LF order"))?,
    };
    value.validate()?;
    Ok(value)
}

enum InsertBytes {
    // Only Main's current tail is mutable. No worker receives it.
    Mutable(Vec<u8>),
    Frozen(Arc<[u8]>),
    Released,
}
#[derive(Clone)]
struct InsertFile {
    page: PageRef,
    start: u32,
    bytes: u32,
}
struct InsertState {
    bytes: InsertBytes,
    summary: TextSummary,
    candidate: Option<InsertFile>,
}
struct InsertBlock(Mutex<InsertState>);
impl InsertBlock {
    fn fresh() -> Self {
        // Tiny coalesced saves must not reserve 64KiB per character.
        Self(Mutex::new(InsertState {
            bytes: InsertBytes::Mutable(Vec::new()),
            summary: TextSummary::EMPTY,
            candidate: None,
        }))
    }
    fn freeze(&self) -> Result<()> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| Error::Invalid("logical block lock"))?;
        let old = std::mem::replace(&mut state.bytes, InsertBytes::Released);
        state.bytes = match old {
            InsertBytes::Mutable(bytes) => InsertBytes::Frozen(bytes.into()),
            other => other,
        };
        Ok(())
    }
    fn range<S: PageProvider>(
        &self,
        engine: &mut TextEngine<S>,
        origin: &Revision,
        range: Range<usize>,
    ) -> Result<Arc<[u8]>> {
        let state = self
            .0
            .lock()
            .map_err(|_| Error::Invalid("logical block lock"))?;
        if let InsertBytes::Frozen(bytes) = &state.bytes {
            let bytes = Arc::clone(bytes);
            drop(state);
            return Ok(Arc::from(
                bytes
                    .get(range)
                    .ok_or(Error::Invalid("logical insertion range"))?,
            ));
        }
        let file = state.candidate.clone().ok_or(Error::Invalid(
            "logical worker handoff must freeze its tail",
        ))?;
        drop(state);
        if range.end > file.bytes as usize {
            return Err(Error::Invalid("logical insertion range"));
        }
        let page = engine.page(origin, PageKind::Text, &file.page)?;
        let start = (file.start as usize)
            .checked_add(range.start)
            .ok_or(Error::Invalid("logical insertion start"))?;
        let end = (file.start as usize)
            .checked_add(range.end)
            .ok_or(Error::Invalid("logical insertion end"))?;
        Ok(Arc::from(
            page.get(start..end)
                .ok_or(Error::Invalid("logical insertion backing"))?,
        ))
    }
    fn release_synced_bytes(&self) -> Result<()> {
        let mut state = self
            .0
            .lock()
            .map_err(|_| Error::Invalid("logical block lock"))?;
        if state.candidate.is_some() && matches!(state.bytes, InsertBytes::Frozen(_)) {
            state.bytes = InsertBytes::Released;
        }
        Ok(())
    }
}

/// Pack this leaf's frozen blocks into ordinary <=64KiB text frames. A frame
/// may back several small tails. No block lock spans allocation/page I/O and
/// no worker locks the current mutable tail. There is one existing writer.
fn pack_insertions<S: PageProvider>(
    engine: &mut TextEngine<S>,
    origin: &Revision,
    spans: &[Span],
    cancelled: &mut impl FnMut() -> bool,
) -> Result<()> {
    let mut bytes = Vec::with_capacity(TEXT_PAGE_BYTES);
    let mut pending: Vec<(Arc<InsertBlock>, u32, u32)> = Vec::with_capacity(FANOUT);
    fn flush<S: PageProvider>(
        engine: &mut TextEngine<S>,
        origin: &Revision,
        bytes: &mut Vec<u8>,
        pending: &mut Vec<(Arc<InsertBlock>, u32, u32)>,
    ) -> Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let page = engine.write_page(origin, PageKind::Text, bytes)?;
        for (block, start, count) in pending.drain(..) {
            block
                .0
                .lock()
                .map_err(|_| Error::Invalid("logical block lock"))?
                .candidate = Some(InsertFile {
                page: page.clone(),
                start,
                bytes: count,
            });
        }
        bytes.clear();
        Ok(())
    }
    for span in spans {
        check_cancel(cancelled)?;
        let Backing::Insert(block) = &span.backing else {
            continue;
        };
        if pending.iter().any(|(old, _, _)| Arc::ptr_eq(old, block)) {
            continue;
        }
        let state = block
            .0
            .lock()
            .map_err(|_| Error::Invalid("logical block lock"))?;
        if state.candidate.is_some() {
            continue;
        }
        let InsertBytes::Frozen(frozen) = &state.bytes else {
            return Err(Error::Invalid("logical publication must freeze its tail"));
        };
        let frozen = Arc::clone(frozen);
        drop(state);
        if frozen.len() > TEXT_PAGE_BYTES {
            return Err(Error::Invalid("logical insertion block bound"));
        }
        if bytes
            .len()
            .checked_add(frozen.len())
            .is_none_or(|size| size > TEXT_PAGE_BYTES)
        {
            flush(engine, origin, &mut bytes, &mut pending)?;
        }
        let start =
            u32::try_from(bytes.len()).map_err(|_| Error::Invalid("logical packed start"))?;
        let count =
            u32::try_from(frozen.len()).map_err(|_| Error::Invalid("logical packed length"))?;
        bytes.extend_from_slice(&frozen);
        pending.push((Arc::clone(block), start, count));
    }
    flush(engine, origin, &mut bytes, &mut pending)
}

#[derive(Clone)]
enum Backing {
    File(Arc<Revision>),
    Insert(Arc<InsertBlock>),
}
impl Backing {
    fn same(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::File(a), Self::File(b)) => Arc::ptr_eq(a, b),
            (Self::Insert(a), Self::Insert(b)) => Arc::ptr_eq(a, b),
            _ => false,
        }
    }
}
#[derive(Clone)]
struct Span {
    backing: Backing,
    // Exact origin within that immutable backing, not a file locator.
    start: TextSummary,
    summary: TextSummary,
}
impl Span {
    fn split(&self, at: TextSummary) -> Result<(Self, Self)> {
        let after = difference(self.summary, at)?;
        if at.bytes == 0 || after.bytes == 0 {
            return Err(Error::Invalid("empty logical split"));
        }
        Ok((
            Self {
                summary: at,
                ..self.clone()
            },
            Self {
                backing: self.backing.clone(),
                start: self.start.checked_add(at)?,
                summary: after,
            },
        ))
    }
}

pub(super) type Link = Arc<SequenceNode>;
enum Items {
    Leaf(Vec<Span>),
    Branch(Vec<Link>),
}
pub(super) struct SequenceNode {
    items: Items,
    height: u8,
    summary: TextSummary,
    // The existing writer may cache a complete immutable file candidate. It
    // cannot mutate logical content or advance the native head.
    file_candidate: OnceLock<TreeRef>,
    synced_insertions: OnceLock<()>,
}
impl SequenceNode {
    fn leaf(spans: Vec<Span>) -> Result<Option<Link>> {
        if spans.is_empty() {
            return Ok(None);
        }
        let mut compact: Vec<Span> = Vec::with_capacity(spans.len());
        for span in spans {
            if span.summary.bytes == 0 {
                return Err(Error::Invalid("empty logical span"));
            }
            if let Some(last) = compact.last_mut()
                && last.backing.same(&span.backing)
                && last.start.checked_add(last.summary)? == span.start
            {
                last.summary = last.summary.checked_add(span.summary)?;
            } else {
                compact.push(span);
            }
        }
        if compact.len() > FANOUT {
            return Err(Error::Invalid("logical leaf fanout"));
        }
        let summary = compact
            .iter()
            .try_fold(TextSummary::EMPTY, |a, b| a.checked_add(b.summary))?;
        Ok(Some(Arc::new(Self {
            items: Items::Leaf(compact),
            height: 0,
            summary,
            file_candidate: OnceLock::new(),
            synced_insertions: OnceLock::new(),
        })))
    }
    fn branch(children: Vec<Link>, height: u8) -> Result<Option<Link>> {
        if children.is_empty() {
            return Ok(None);
        }
        if height == 0
            || height > MAX_HEIGHT
            || children.len() > FANOUT
            || children
                .iter()
                .any(|child| child.height.checked_add(1) != Some(height))
        {
            return Err(Error::Invalid(if height > MAX_HEIGHT {
                "logical branch height"
            } else if children.len() > FANOUT {
                "logical branch fanout"
            } else {
                "logical branch child height"
            }));
        }
        let summary = children
            .iter()
            .try_fold(TextSummary::EMPTY, |a, b| a.checked_add(b.summary))?;
        Ok(Some(Arc::new(Self {
            items: Items::Branch(children),
            height,
            summary,
            file_candidate: OnceLock::new(),
            synced_insertions: OnceLock::new(),
        })))
    }
}

fn split(tree: &Link, at: TextSummary) -> Result<(Option<Link>, Option<Link>)> {
    if at.bytes == 0 {
        if at != TextSummary::EMPTY {
            return Err(Error::Invalid("logical start summary"));
        }
        return Ok((None, Some(Arc::clone(tree))));
    }
    if at.bytes == tree.summary.bytes {
        if at != tree.summary {
            return Err(Error::Invalid("logical end summary"));
        }
        return Ok((Some(Arc::clone(tree)), None));
    }
    difference(tree.summary, at)?;
    let mut before = TextSummary::EMPTY;
    match &tree.items {
        Items::Leaf(spans) => {
            let mut left = Vec::with_capacity(FANOUT);
            let mut right = Vec::with_capacity(FANOUT);
            for span in spans {
                let end = before.checked_add(span.summary)?;
                if end.bytes <= at.bytes {
                    left.push(span.clone());
                } else if before.bytes >= at.bytes {
                    right.push(span.clone());
                } else {
                    let (a, b) = span.split(difference(at, before)?)?;
                    left.push(a);
                    right.push(b);
                }
                before = end;
            }
            Ok((SequenceNode::leaf(left)?, SequenceNode::leaf(right)?))
        }
        Items::Branch(children) => {
            let mut left = Vec::with_capacity(FANOUT);
            let mut right = Vec::with_capacity(FANOUT);
            for child in children {
                let end = before.checked_add(child.summary)?;
                if end.bytes <= at.bytes {
                    left.push(Arc::clone(child));
                } else if before.bytes >= at.bytes {
                    right.push(Arc::clone(child));
                } else {
                    let (a, b) = split(child, difference(at, before)?)?;
                    if let Some(a) = a {
                        left.push(a);
                    }
                    if let Some(b) = b {
                        right.push(b);
                    }
                }
                before = end;
            }
            Ok((
                SequenceNode::branch(left, tree.height)?,
                SequenceNode::branch(right, tree.height)?,
            ))
        }
    }
}
fn pack_spans(mut spans: Vec<Span>) -> Result<Vec<Link>> {
    let mut roots = Vec::with_capacity(2);
    if spans.len() > FANOUT {
        let right = spans.split_off(spans.len() / 2);
        if let Some(root) = SequenceNode::leaf(spans)? {
            roots.push(root);
        }
        if let Some(root) = SequenceNode::leaf(right)? {
            roots.push(root);
        }
    } else if let Some(root) = SequenceNode::leaf(spans)? {
        roots.push(root);
    }
    Ok(roots)
}
fn pack_children(mut children: Vec<Link>, height: u8) -> Result<Vec<Link>> {
    let mut roots = Vec::with_capacity(2);
    if children.len() > FANOUT {
        let right = children.split_off(children.len() / 2);
        if let Some(root) = SequenceNode::branch(children, height)? {
            roots.push(root);
        }
        if let Some(root) = SequenceNode::branch(right, height)? {
            roots.push(root);
        }
    } else if let Some(root) = SequenceNode::branch(children, height)? {
        roots.push(root);
    }
    Ok(roots)
}
fn join_level(left: Link, right: Link) -> Result<Vec<Link>> {
    if left.height == right.height {
        match (&left.items, &right.items) {
            (Items::Leaf(a), Items::Leaf(b)) => {
                let mut spans = a.clone();
                spans.extend(b.iter().cloned());
                pack_spans(spans)
            }
            (Items::Branch(a), Items::Branch(b)) => {
                let mut children = a.clone();
                children.extend(b.iter().cloned());
                pack_children(children, left.height)
            }
            _ => Err(Error::Invalid("logical join shape")),
        }
    } else if left.height > right.height {
        let Items::Branch(items) = &left.items else {
            return Err(Error::Invalid("logical join left"));
        };
        let mut children = items.clone();
        let edge = children.pop().ok_or(Error::Invalid("empty logical join"))?;
        children.extend(join_level(edge, right)?);
        pack_children(children, left.height)
    } else {
        let Items::Branch(items) = &right.items else {
            return Err(Error::Invalid("logical join right"));
        };
        let mut children = items.clone();
        let edge = children.remove(0);
        let mut roots = join_level(left, edge)?;
        roots.append(&mut children);
        pack_children(roots, right.height)
    }
}
fn join(left: Option<Link>, right: Option<Link>) -> Result<Option<Link>> {
    // Split keeps heights inside a parent. At the top-level seam, collapse
    // unary split roots before joining or repeated edits grow empty levels.
    match (collapse(left), collapse(right)) {
        (None, root) | (root, None) => Ok(root),
        (Some(a), Some(b)) => {
            let mut roots = join_level(a, b)?;
            if roots.len() == 1 {
                return Ok(roots.pop());
            }
            let height = roots[0]
                .height
                .checked_add(1)
                .ok_or(Error::Invalid("logical height overflow"))?;
            SequenceNode::branch(roots, height)
        }
    }
}
fn collapse(mut root: Option<Link>) -> Option<Link> {
    while let Some(current) = &root {
        let Items::Branch(children) = &current.items else {
            break;
        };
        if children.len() != 1 {
            break;
        }
        root = Some(Arc::clone(&children[0]));
    }
    root
}

struct Snapshot {
    id: Uuid,
    origin: Arc<Revision>,
    root: Option<Link>,
    // Two small derived index handles, not another source/Undo timeline.
    // Main only shares the Arc when editing; it never locks this memo.
    markup_memo: Arc<crate::markup::MarkupMemo>,
    markup: [OnceLock<Arc<crate::markup::MarkupIndex>>; 2],
}
#[derive(Clone)]
pub struct LogicalSnapshot(Arc<Snapshot>);
impl LogicalSnapshot {
    pub fn from_revision(revision: Revision) -> Result<Self> {
        revision.validate()?;
        let origin = Arc::new(revision);
        let root = if origin.summary().bytes == 0 {
            None
        } else {
            SequenceNode::leaf(vec![Span {
                backing: Backing::File(Arc::clone(&origin)),
                start: TextSummary::EMPTY,
                summary: origin.summary(),
            }])?
        };
        Ok(Self(Arc::new(Snapshot {
            id: Uuid::new_v4(),
            origin,
            root,
            markup_memo: Arc::new(crate::markup::MarkupMemo::default()),
            markup: [OnceLock::new(), OnceLock::new()],
        })))
    }
    pub fn id(&self) -> Uuid {
        self.0.id
    }
    pub fn origin(&self) -> &Revision {
        &self.0.origin
    }
    pub fn summary(&self) -> TextSummary {
        self.0
            .root
            .as_ref()
            .map_or(TextSummary::EMPTY, |root| root.summary)
    }
    pub fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
    #[cfg(test)]
    pub(super) fn resident_spans(&self) -> usize {
        fn count(node: &Link) -> usize {
            match &node.items {
                Items::Leaf(spans) => spans.len(),
                Items::Branch(children) => children.iter().map(count).sum(),
            }
        }
        self.0.root.as_ref().map_or(0, count)
    }
    fn after(&self, root: Option<Link>) -> Self {
        Self(Arc::new(Snapshot {
            id: Uuid::new_v4(),
            origin: Arc::clone(&self.0.origin),
            root: collapse(root),
            markup_memo: Arc::clone(&self.0.markup_memo),
            markup: [OnceLock::new(), OnceLock::new()],
        }))
    }

    pub(super) fn markup_source(&self) -> MarkupSource {
        MarkupSource {
            id: self.id(),
            root: self.0.root.clone(),
            summary: self.summary(),
        }
    }
    pub fn markup_index(
        &self,
        mode: crate::markup::MarkupMode,
    ) -> Option<Arc<crate::markup::MarkupIndex>> {
        self.0.markup[mode.slot()].get().cloned()
    }
    pub(super) fn previous_markup(
        &self,
        mode: crate::markup::MarkupMode,
    ) -> Result<Option<Arc<crate::markup::MarkupIndex>>> {
        self.0.markup_memo.latest(mode)
    }
    pub(super) fn progressed_markup(&self, value: Arc<crate::markup::MarkupIndex>) -> Result<()> {
        if value.source.id != self.id() || value.source.summary != self.summary() {
            return Err(Error::Stale);
        }
        // Only a completed index enters the exact-snapshot OnceLock. A cold
        // cancelled worker may leave its proved prefix in the same two-slot
        // convergence memo, without claiming that the tail was examined.
        self.0.markup_memo.completed(value)
    }
    pub(super) fn completed_markup(&self, value: Arc<crate::markup::MarkupIndex>) -> Result<()> {
        if value.source.id != self.id() || value.source.summary != self.summary() {
            return Err(Error::Stale);
        }
        let mode = value.mode;
        let _ = self.0.markup[mode.slot()].set(Arc::clone(&value));
        self.0.markup_memo.completed(value)
    }
}

/// Only the derived index retains this immutable shape for convergence. There
/// is no source mutation, scalar scan or I/O while comparing shared pieces.
pub(super) struct MarkupSource {
    pub id: Uuid,
    root: Option<Link>,
    pub summary: TextSummary,
}
impl MarkupSource {
    pub fn common_edges(&self, other: &LogicalSnapshot) -> Result<(TextSummary, TextSummary)> {
        #[derive(Clone)]
        enum Part<'a> {
            Node(&'a SequenceNode),
            Piece(Span),
        }
        impl Part<'_> {
            fn summary(&self) -> TextSummary {
                match self {
                    Self::Node(node) => node.summary,
                    Self::Piece(span) => span.summary,
                }
            }
        }
        fn frontier(root: &Option<Link>) -> Vec<Part<'_>> {
            root.as_ref()
                .map_or_else(Vec::new, |node| vec![Part::Node(node.as_ref())])
        }
        fn expand<'a>(parts: &mut Vec<Part<'a>>, reverse: bool) {
            let Some(Part::Node(node)) = parts.pop() else {
                unreachable!("node frontier");
            };
            match &node.items {
                Items::Leaf(spans) => {
                    if reverse {
                        parts.extend(spans.iter().cloned().map(Part::Piece));
                    } else {
                        parts.extend(spans.iter().rev().cloned().map(Part::Piece));
                    }
                }
                Items::Branch(children) => {
                    if reverse {
                        parts.extend(children.iter().map(|node| Part::Node(node.as_ref())));
                    } else {
                        parts.extend(children.iter().rev().map(|node| Part::Node(node.as_ref())));
                    }
                }
            }
        }
        let compare = |reverse: bool, bound: TextSummary| -> Result<TextSummary> {
            let mut a = frontier(&self.root);
            let mut b = frontier(&other.0.root);
            let mut common = TextSummary::EMPTY;
            while let (Some(left), Some(right)) = (a.last().cloned(), b.last().cloned()) {
                let remaining = difference(bound, common)?;
                if remaining.bytes == 0 {
                    break;
                }
                match (&left, &right) {
                    (Part::Node(x), Part::Node(y)) if std::ptr::eq(*x, *y) => {
                        if x.summary.bytes >= remaining.bytes {
                            common = bound;
                            break;
                        }
                        common = common.checked_add(x.summary)?;
                        a.pop();
                        b.pop();
                        continue;
                    }
                    (Part::Node(_), Part::Node(_)) => {
                        // Descend the larger unmatched interval first. Shared
                        // children survive path copying and are skipped whole,
                        // even when an edit changed the opposite tree's height.
                        let x = left.summary().bytes;
                        let y = right.summary().bytes;
                        if x >= y {
                            expand(&mut a, reverse);
                        }
                        if y >= x {
                            expand(&mut b, reverse);
                        }
                        continue;
                    }
                    (Part::Node(_), _) => {
                        expand(&mut a, reverse);
                        continue;
                    }
                    (_, Part::Node(_)) => {
                        expand(&mut b, reverse);
                        continue;
                    }
                    _ => {}
                }
                let (Part::Piece(mut x), Part::Piece(mut y)) = (left, right) else {
                    unreachable!("piece frontier");
                };
                let same_backing = match (&x.backing, &y.backing) {
                    (Backing::File(a), Backing::File(b)) => a == b,
                    (Backing::Insert(a), Backing::Insert(b)) => Arc::ptr_eq(a, b),
                    _ => false,
                };
                let edge_x = if reverse {
                    x.start.checked_add(x.summary)?
                } else {
                    x.start
                };
                let edge_y = if reverse {
                    y.start.checked_add(y.summary)?
                } else {
                    y.start
                };
                if !same_backing || edge_x != edge_y {
                    break;
                }
                let take = if x.summary.bytes <= y.summary.bytes {
                    x.summary
                } else {
                    y.summary
                };
                if take.bytes >= remaining.bytes {
                    common = bound;
                    break;
                }
                take.validate()?;
                common = common.checked_add(take)?;
                let x_done = x.summary == take;
                let y_done = y.summary == take;
                if !x_done {
                    x.summary = difference(x.summary, take)?;
                    if !reverse {
                        x.start = x.start.checked_add(take)?;
                    }
                }
                if !y_done {
                    y.summary = difference(y.summary, take)?;
                    if !reverse {
                        y.start = y.start.checked_add(take)?;
                    }
                }
                if x_done {
                    a.pop();
                } else {
                    *a.last_mut().expect("piece frontier") = Part::Piece(x);
                }
                if y_done {
                    b.pop();
                } else {
                    *b.last_mut().expect("piece frontier") = Part::Piece(y);
                }
            }
            Ok(common)
        };
        let shorter = if self.summary.bytes <= other.summary().bytes {
            self.summary
        } else {
            other.summary()
        };
        let prefix = compare(false, shorter)?;
        let suffix = compare(true, difference(shorter, prefix)?)?;
        Ok((prefix, suffix))
    }
}

/// Only actual immutable reads or a bounded native window can construct this.
/// A caller-supplied summary cannot stand in for a scalar endpoint proof.
#[derive(Clone)]
pub struct LogicalPosition {
    snapshot: LogicalSnapshot,
    point: TextSummary,
}
impl LogicalPosition {
    pub(super) fn at(snapshot: LogicalSnapshot, point: TextSummary) -> Self {
        Self { snapshot, point }
    }

    pub fn snapshot(&self) -> &LogicalSnapshot {
        &self.snapshot
    }
    pub fn point(&self) -> TextSummary {
        self.point
    }
}

/// This is not a durable Window or Revision. Its text is a bounded copied view
/// of an exact logical snapshot, and its scalar table is prepared once.
#[derive(Clone)]
pub struct LogicalWindow {
    snapshot: LogicalSnapshot,
    id: Uuid,
    start: TextSummary,
    text: Arc<str>,
    scalars: Arc<[LocalScalar]>,
}
// Window counters are local. This replaces Working's duplicate table; global
// endpoints remain u64. Normal 24KiB ASCII uses 288KiB rather than 576KiB.
#[derive(Clone, Copy)]
struct LocalScalar {
    bytes: u32,
    utf16: u32,
    lf_count: u32,
}
impl LocalScalar {
    fn of(point: TextSummary) -> Result<Self> {
        Ok(Self {
            bytes: u32::try_from(point.bytes).map_err(|_| Error::Invalid("native byte extent"))?,
            utf16: u32::try_from(point.utf16).map_err(|_| Error::Invalid("native UTF16 extent"))?,
            lf_count: u32::try_from(point.lf_count)
                .map_err(|_| Error::Invalid("native LF extent"))?,
        })
    }
    fn point(self) -> TextSummary {
        TextSummary {
            bytes: u64::from(self.bytes),
            utf16: u64::from(self.utf16),
            lf_count: u64::from(self.lf_count),
        }
    }
}
impl LogicalWindow {
    fn new(snapshot: LogicalSnapshot, start: TextSummary, text: String) -> Result<Self> {
        if text.len() > NATIVE_WINDOW_BYTES {
            return Err(Error::Invalid("logical window bound"));
        }
        Self::prepared(snapshot, start, text)
    }
    fn prepared(snapshot: LogicalSnapshot, start: TextSummary, text: String) -> Result<Self> {
        let mut scalars = Vec::with_capacity(text.len() + 1);
        let mut point = TextSummary::EMPTY;
        scalars.push(LocalScalar::of(point)?);
        for scalar in text.chars() {
            point = point.checked_add(TextSummary {
                bytes: scalar.len_utf8() as u64,
                utf16: scalar.len_utf16() as u64,
                lf_count: u64::from(scalar == '\n'),
            })?;
            scalars.push(LocalScalar::of(point)?);
        }
        difference(snapshot.summary(), start.checked_add(point)?)?;
        Ok(Self {
            snapshot,
            id: Uuid::new_v4(),
            start,
            text: text.into(),
            scalars: scalars.into(),
        })
    }
    pub fn id(&self) -> Uuid {
        self.id
    }
    pub fn snapshot(&self) -> &LogicalSnapshot {
        &self.snapshot
    }
    pub fn start(&self) -> TextSummary {
        self.start
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    /// Factory's actual bounded file read is lent once at opening. This is a
    /// resident projection, not a path for caller-created logical summaries.
    pub fn opening(
        snapshot: &LogicalSnapshot,
        revision: &Revision,
        start: TextSummary,
        text: String,
    ) -> Result<Self> {
        if snapshot.origin() != revision || snapshot.summary() != revision.summary() {
            return Err(Error::Stale);
        }
        Self::new(snapshot.clone(), start, text)
    }
    pub fn seed(&self, local_focus_utf16: u64) -> Result<LogicalWindowSeed> {
        let window = self.trimmed(local_focus_utf16, NATIVE_WINDOW_BYTES)?;
        Ok(LogicalWindowSeed {
            summary: window.local_summary(),
            snapshot: window.snapshot,
            start: window.start,
            text: window.text,
        })
    }
    pub fn from_seed(seed: &LogicalWindowSeed) -> Result<Self> {
        Self::new(seed.snapshot.clone(), seed.start, seed.text.to_string())
    }
    pub fn position(&self, local_utf16: u64) -> Result<LogicalPosition> {
        let at = self
            .scalars
            .binary_search_by_key(&local_utf16, |point| u64::from(point.utf16))
            .map_err(|_| Error::Invalid("logical selection inside surrogate"))?;
        Ok(LogicalPosition {
            snapshot: self.snapshot.clone(),
            point: self.start.checked_add(self.scalars[at].point())?,
        })
    }
    fn local_byte(&self, byte: usize) -> Result<TextSummary> {
        let byte = u64::try_from(byte).map_err(|_| Error::Invalid("logical byte conversion"))?;
        let at = self
            .scalars
            .binary_search_by_key(&byte, |point| u64::from(point.bytes))
            .map_err(|_| Error::Invalid("logical edit inside scalar"))?;
        Ok(self.scalars[at].point())
    }
    pub fn local_summary(&self) -> TextSummary {
        self.scalars
            .last()
            .map_or(TextSummary::EMPTY, |point| point.point())
    }
    fn edited(
        &self,
        snapshot: LogicalSnapshot,
        range: Range<usize>,
        inserted: &str,
    ) -> Result<Self> {
        let start = self.local_byte(range.start)?;
        let end = self.local_byte(range.end)?;
        let first = self
            .scalars
            .binary_search_by_key(&start.bytes, |point| u64::from(point.bytes))
            .map_err(|_| Error::Invalid("native scalar start"))?;
        let last = self
            .scalars
            .binary_search_by_key(&end.bytes, |point| u64::from(point.bytes))
            .map_err(|_| Error::Invalid("native scalar end"))?;
        let length = self
            .text
            .len()
            .checked_sub(range.len())
            .and_then(|length| length.checked_add(inserted.len()))
            .ok_or(Error::Invalid("native extent overflow"))?;
        let mut text = String::with_capacity(length);
        text.push_str(&self.text[..range.start]);
        text.push_str(inserted);
        text.push_str(&self.text[range.end..]);
        let mut points = self.scalars[..=first].to_vec();
        let mut point = start;
        for scalar in inserted.chars() {
            point = point.checked_add(TextSummary {
                bytes: scalar.len_utf8() as u64,
                utf16: scalar.len_utf16() as u64,
                lf_count: u64::from(scalar == '\n'),
            })?;
            points.push(LocalScalar::of(point)?);
        }
        for old in &self.scalars[last + 1..] {
            points.push(LocalScalar::of(
                point.checked_add(difference(old.point(), end)?)?,
            )?);
        }
        let local = points
            .last()
            .map_or(TextSummary::EMPTY, |point| point.point());
        difference(snapshot.summary(), self.start.checked_add(local)?)?;
        // Input is already a native String. A physical command may temporarily
        // exceed its display target; only outer Cocoa completion trims it.
        Ok(Self {
            snapshot,
            id: Uuid::new_v4(),
            start: self.start,
            text: text.into(),
            scalars: points.into(),
        })
    }
    pub fn trimmed(&self, focus_utf16: u64, budget: usize) -> Result<Self> {
        if !(4..=NATIVE_WINDOW_BYTES).contains(&budget) {
            return Err(Error::Invalid("logical trim budget"));
        }
        let focus = self.position(focus_utf16)?;
        if self.text.len() <= budget {
            return Ok(self.clone());
        }
        let local = difference(focus.point, self.start)?;
        let focus =
            usize::try_from(local.bytes).map_err(|_| Error::Invalid("native trim focus"))?;
        let mut start = focus
            .saturating_sub(budget / 2)
            .min(self.text.len().saturating_sub(budget));
        while !self.text.is_char_boundary(start) {
            start += 1;
        }
        let mut end = start.saturating_add(budget).min(self.text.len());
        while !self.text.is_char_boundary(end) {
            end -= 1;
        }
        if end == start || focus < start || focus > end {
            return Err(Error::Invalid("native trim scalar extent"));
        }
        let before = self.local_byte(start)?;
        let first = self
            .scalars
            .binary_search_by_key(&before.bytes, |point| u64::from(point.bytes))
            .map_err(|_| Error::Invalid("native trim start"))?;
        let last = self
            .scalars
            .binary_search_by_key(&(end as u64), |point| u64::from(point.bytes))
            .map_err(|_| Error::Invalid("native trim end"))?;
        let points = self.scalars[first..=last]
            .iter()
            .map(|point| LocalScalar::of(difference(point.point(), before)?))
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            snapshot: self.snapshot.clone(),
            id: Uuid::new_v4(),
            start: self.start.checked_add(before)?,
            text: Arc::from(&self.text[start..end]),
            scalars: points.into(),
        })
    }
}

/// Compact history display preparation. No scalar table is retained per SDK
/// entry. Its <=24KiB text shares the ordinary immutable window string.
#[derive(Clone)]
pub struct LogicalWindowSeed {
    snapshot: LogicalSnapshot,
    start: TextSummary,
    summary: TextSummary,
    text: Arc<str>,
}
impl LogicalWindowSeed {
    pub fn snapshot(&self) -> &LogicalSnapshot {
        &self.snapshot
    }
    pub fn start(&self) -> TextSummary {
        self.start
    }
    pub fn summary(&self) -> TextSummary {
        self.summary
    }
}

/// One Main-owned source head and append tail. There is deliberately no Undo
/// stack here: the existing native group entries retain these snapshots.
pub struct LogicalSource {
    head: LogicalSnapshot,
    tail: Option<Arc<InsertBlock>>,
}
pub struct LogicalEdit {
    pub changed: bool,
    pub window: LogicalWindow,
    pub cursor: LogicalPosition,
}
impl LogicalSource {
    pub fn new(revision: Revision) -> Result<Self> {
        Ok(Self {
            head: LogicalSnapshot::from_revision(revision)?,
            tail: None,
        })
    }
    /// One unpublished candidate, never a second native source authority.
    pub fn preparing(snapshot: LogicalSnapshot) -> Self {
        Self {
            head: snapshot,
            tail: None,
        }
    }
    pub fn capture(&self) -> LogicalSnapshot {
        self.head.clone()
    }
    /// Seal/detach once at a real worker handoff, not per key or Undo group.
    /// Workers only see immutable blocks; subsequent input gets a new tail.
    pub fn capture_for_publication(&mut self) -> Result<LogicalSnapshot> {
        if let Some(tail) = self.tail.take() {
            tail.freeze()?;
        }
        Ok(self.capture())
    }
    /// Only after the Main consumer has admitted exact owner/head and fenced
    /// its actual synchronous adoption. This performs no allocation or I/O.
    pub fn install_prepared(&mut self, snapshot: &LogicalSnapshot) {
        assert_eq!(snapshot.origin().owner_id, self.head.origin().owner_id);
        assert_eq!(
            snapshot.origin().document_id,
            self.head.origin().document_id
        );
        self.head = snapshot.clone();
    }
    pub fn restore(&mut self, snapshot: &LogicalSnapshot) -> Result<()> {
        if snapshot.origin().owner_id != self.head.origin().owner_id
            || snapshot.origin().document_id != self.head.origin().document_id
        {
            return Err(Error::Invalid("logical restore ownership"));
        }
        self.head = snapshot.clone();
        Ok(())
    }
    fn inserted(&mut self, text: &str) -> Result<Option<Link>> {
        let mut remaining = text;
        let mut root = None;
        while !remaining.is_empty() {
            let block = self
                .tail
                .get_or_insert_with(|| Arc::new(InsertBlock::fresh()))
                .clone();
            let mut state = block
                .0
                .lock()
                .map_err(|_| Error::Invalid("logical append lock"))?;
            let prefix = state.summary;
            let InsertBytes::Mutable(bytes) = &mut state.bytes else {
                return Err(Error::Invalid("logical append backing"));
            };
            let capacity = TEXT_PAGE_BYTES - bytes.len();
            let mut count = capacity.min(remaining.len());
            while count != 0 && !remaining.is_char_boundary(count) {
                count -= 1;
            }
            if count == 0 {
                drop(state);
                block.freeze()?;
                self.tail = None;
                continue;
            }
            let part = &remaining[..count];
            let summary = TextSummary::of(part);
            bytes.extend_from_slice(part.as_bytes());
            let full = bytes.len() == TEXT_PAGE_BYTES;
            state.summary = prefix.checked_add(summary)?;
            drop(state);
            if full {
                block.freeze()?;
            }
            let leaf = SequenceNode::leaf(vec![Span {
                backing: Backing::Insert(block),
                start: prefix,
                summary,
            }])?;
            root = join(root, leaf)?;
            if full {
                self.tail = None;
            }
            remaining = &remaining[count..];
        }
        Ok(root)
    }
    fn replacement(
        &mut self,
        start: &LogicalPosition,
        end: &LogicalPosition,
        text: &str,
    ) -> Result<LogicalPosition> {
        if !self.head.same(&start.snapshot) || !self.head.same(&end.snapshot) {
            return Err(Error::Stale);
        }
        difference(end.point, start.point)?;
        let (left, rest) = match &self.head.0.root {
            Some(root) => split(root, start.point)?,
            None if start.point == TextSummary::EMPTY && end.point == TextSummary::EMPTY => {
                (None, None)
            }
            None => return Err(Error::Invalid("logical edit of empty source")),
        };
        let right = match rest {
            Some(rest) => split(&rest, difference(end.point, start.point)?)?.1,
            None => None,
        };
        let inserted = self.inserted(text)?;
        let root = join(join(left, inserted)?, right)?;
        let cursor = start.point.checked_add(TextSummary::of(text))?;
        Ok(LogicalPosition {
            snapshot: self.head.after(root),
            point: cursor,
        })
    }
    pub(super) fn replace_file_positions(
        &mut self,
        start: &LogicalPosition,
        end: &LogicalPosition,
        revision: Revision,
    ) -> Result<LogicalPosition> {
        if !self.head.same(&start.snapshot) || !self.head.same(&end.snapshot) {
            return Err(Error::Stale);
        }
        if revision.owner_id != self.head.origin().owner_id
            || revision.document_id != self.head.origin().document_id
        {
            return Err(Error::Invalid("logical imported owner"));
        }
        let removed = difference(end.point, start.point)?;
        if removed.bytes == 0 && revision.summary().bytes == 0 {
            return Ok(start.clone());
        }
        let (left, tail) = match &self.head.0.root {
            Some(root) => split(root, start.point)?,
            None => (None, None),
        };
        let right = match tail {
            Some(tail) => split(&tail, removed)?.1,
            None => None,
        };
        let summary = revision.summary();
        let inserted = if summary.bytes == 0 {
            None
        } else {
            SequenceNode::leaf(vec![Span {
                backing: Backing::File(Arc::new(revision)),
                start: TextSummary::EMPTY,
                summary,
            }])?
        };
        let root = join(join(left, inserted)?, right)?;
        self.head = self.head.after(root);
        Ok(LogicalPosition {
            snapshot: self.capture(),
            point: start.point.checked_add(summary)?,
        })
    }
    pub fn replace_positions(
        &mut self,
        start: &LogicalPosition,
        end: &LogicalPosition,
        text: &str,
    ) -> Result<LogicalPosition> {
        if !self.head.same(&start.snapshot) || !self.head.same(&end.snapshot) {
            return Err(Error::Stale);
        }
        if start.point == end.point && text.is_empty() {
            return Ok(start.clone());
        }
        let cursor = self.replacement(start, end, text)?;
        self.head = cursor.snapshot.clone();
        Ok(cursor)
    }
    /// Known endpoints are actual window scalar proofs or the immutable
    /// snapshot's exact start/end. A distant endpoint needs a worker read.
    pub fn prepare_resident_replacement(
        &mut self,
        window: &LogicalWindow,
        first: u64,
        last: u64,
        text: &str,
    ) -> Result<Option<LogicalEdit>> {
        if !self.head.same(window.snapshot()) {
            return Err(Error::Stale);
        }
        if text.len() > WINDOW_BYTES || first > last || last > self.head.summary().utf16 {
            return Err(Error::Invalid("logical replacement envelope"));
        }
        let known = |offset: u64| -> Result<Option<LogicalPosition>> {
            let point = if offset == 0 {
                TextSummary::EMPTY
            } else if offset == self.head.summary().utf16 {
                self.head.summary()
            } else if offset >= window.start.utf16
                && offset <= window.start.checked_add(window.local_summary())?.utf16
            {
                return window.position(offset - window.start.utf16).map(Some);
            } else {
                return Ok(None);
            };
            Ok(Some(LogicalPosition {
                snapshot: self.capture(),
                point,
            }))
        };
        let (Some(start), Some(end)) = (known(first)?, known(last)?) else {
            return Ok(None);
        };
        if first == last && text.is_empty() {
            return Ok(Some(LogicalEdit {
                changed: false,
                window: window.clone(),
                cursor: start,
            }));
        }
        if start.point.bytes >= window.start.bytes
            && end.point.bytes <= window.start.checked_add(window.local_summary())?.bytes
        {
            let a = usize::try_from(start.point.bytes - window.start.bytes)
                .map_err(|_| Error::Invalid("logical resident start"))?;
            let b = usize::try_from(end.point.bytes - window.start.bytes)
                .map_err(|_| Error::Invalid("logical resident end"))?;
            if window.text.get(a..b) == Some(text) {
                return Ok(Some(LogicalEdit {
                    changed: false,
                    window: window.clone(),
                    cursor: end,
                }));
            }
        }
        let prefix = if start.point.bytes >= window.start.bytes
            && start.point.bytes <= window.start.checked_add(window.local_summary())?.bytes
        {
            &window.text[..usize::try_from(start.point.bytes - window.start.bytes)
                .map_err(|_| Error::Invalid("logical resident prefix"))?]
        } else {
            ""
        };
        let suffix = if end.point.bytes >= window.start.bytes
            && end.point.bytes <= window.start.checked_add(window.local_summary())?.bytes
        {
            &window.text[usize::try_from(end.point.bytes - window.start.bytes)
                .map_err(|_| Error::Invalid("logical resident suffix"))?..]
        } else {
            ""
        };
        // A structural prepare seals the existing tail for shared snapshots,
        // but never changes its logical head. Build/own new bytes in a local
        // unpublished candidate; failed/stale stage leaves Main unchanged.
        let before = self.capture_for_publication()?;
        let mut candidate = Self::preparing(before);
        let cursor = candidate.replace_positions(&start, &end, text)?;
        let _frozen = candidate.capture_for_publication()?;
        let display_start = difference(start.point, TextSummary::of(prefix))?;
        let mut display = String::with_capacity(prefix.len() + text.len() + suffix.len());
        display.push_str(prefix);
        display.push_str(text);
        display.push_str(suffix);
        let focus = cursor.point.utf16 - display_start.utf16;
        let window = LogicalWindow::prepared(cursor.snapshot.clone(), display_start, display)?
            .trimmed(focus, 16 * 1024)?;
        Ok(Some(LogicalEdit {
            changed: true,
            window,
            cursor,
        }))
    }
    pub fn replace_window(
        &mut self,
        window: &LogicalWindow,
        range: Range<usize>,
        text: &str,
    ) -> Result<LogicalEdit> {
        if !self.head.same(window.snapshot()) {
            return Err(Error::Stale);
        }
        if text.len() > WINDOW_BYTES {
            return Err(Error::Invalid(
                "native insertion requires streamed dispatch",
            ));
        }
        let old = window
            .text
            .get(range.clone())
            .ok_or(Error::Invalid("logical native range"))?;
        let local_start = window.local_byte(range.start)?;
        let local_end = window.local_byte(range.end)?;
        if old == text {
            return Ok(LogicalEdit {
                changed: false,
                window: window.clone(),
                cursor: LogicalPosition {
                    snapshot: self.capture(),
                    point: window.start.checked_add(local_end)?,
                },
            });
        }
        let start = LogicalPosition {
            snapshot: self.capture(),
            point: window.start.checked_add(local_start)?,
        };
        let end = LogicalPosition {
            snapshot: self.capture(),
            point: window.start.checked_add(local_end)?,
        };
        let cursor = self.replacement(&start, &end, text)?;
        let window = window.edited(cursor.snapshot.clone(), range, text)?;
        self.head = cursor.snapshot.clone();
        Ok(LogicalEdit {
            changed: true,
            window,
            cursor,
        })
    }
}

impl<S: PageProvider> TextEngine<S> {
    pub fn logical_position(
        &mut self,
        snapshot: &LogicalSnapshot,
        utf16: u64,
        round_surrogate: bool,
    ) -> Result<LogicalPosition> {
        if utf16 > snapshot.summary().utf16 {
            return Err(Error::Invalid("logical global position"));
        }
        fn seek<S: PageProvider>(
            engine: &mut TextEngine<S>,
            tree: &Link,
            utf16: u64,
            prefix: TextSummary,
            origin: &Revision,
            round: bool,
        ) -> Result<TextSummary> {
            let mut before = TextSummary::EMPTY;
            match &tree.items {
                Items::Branch(children) => {
                    for child in children {
                        let end = before.checked_add(child.summary)?;
                        if utf16 < end.utf16 {
                            return seek(
                                engine,
                                child,
                                utf16 - before.utf16,
                                prefix.checked_add(before)?,
                                origin,
                                round,
                            );
                        }
                        before = end;
                    }
                }
                Items::Leaf(spans) => {
                    for span in spans {
                        let end = before.checked_add(span.summary)?;
                        if utf16 < end.utf16 {
                            let at = utf16 - before.utf16;
                            let local = match &span.backing {
                                Backing::File(revision) => {
                                    let document = Document {
                                        revision: revision.as_ref().clone(),
                                    };
                                    let offset = span
                                        .start
                                        .utf16
                                        .checked_add(at)
                                        .ok_or(Error::Invalid("logical file UTF16 overflow"))?;
                                    let point = if round {
                                        engine.scalar_position(&document, revision, offset, true)?
                                    } else {
                                        let byte =
                                            engine.byte_at_utf16(&document, revision, offset)?;
                                        match &revision.root {
                                            Some(root) => {
                                                engine.prefix_summary(revision, root, byte)?
                                            }
                                            None => TextSummary::EMPTY,
                                        }
                                    };
                                    difference(point, span.start)?
                                }
                                Backing::Insert(block) => {
                                    let begin = usize::try_from(span.start.bytes)
                                        .map_err(|_| Error::Invalid("logical block start"))?;
                                    let end = usize::try_from(
                                        span.start
                                            .bytes
                                            .checked_add(span.summary.bytes)
                                            .ok_or(Error::Invalid("logical block end"))?,
                                    )
                                    .map_err(|_| Error::Invalid("logical block end"))?;
                                    let bytes = block.range(engine, origin, begin..end)?;
                                    let text = std::str::from_utf8(&bytes)
                                        .map_err(|_| Error::Invalid("logical block UTF8"))?;
                                    let mut total = TextSummary::EMPTY;
                                    for scalar in text.chars() {
                                        if total.utf16 >= at {
                                            break;
                                        }
                                        let next = total.checked_add(TextSummary {
                                            bytes: scalar.len_utf8() as u64,
                                            utf16: scalar.len_utf16() as u64,
                                            lf_count: u64::from(scalar == '\n'),
                                        })?;
                                        if next.utf16 > at && !round {
                                            return Err(Error::Invalid(
                                                "logical position inside surrogate",
                                            ));
                                        }
                                        total = next;
                                    }
                                    total
                                }
                            };
                            difference(span.summary, local)?;
                            return prefix.checked_add(before)?.checked_add(local);
                        }
                        before = end;
                    }
                }
            }
            if before.utf16 != utf16 {
                return Err(Error::Invalid("logical incomplete position"));
            }
            prefix.checked_add(before)
        }
        let point = match &snapshot.0.root {
            Some(root) => seek(
                self,
                root,
                utf16,
                TextSummary::EMPTY,
                snapshot.origin(),
                round_surrogate,
            )?,
            None => TextSummary::EMPTY,
        };
        Ok(LogicalPosition {
            snapshot: snapshot.clone(),
            point,
        })
    }
    fn logical_span(snapshot: &LogicalSnapshot, at: u64) -> Result<(Span, TextSummary)> {
        if at >= snapshot.summary().bytes {
            return Err(Error::Invalid("logical span outside source"));
        }
        let mut node = snapshot
            .0
            .root
            .clone()
            .ok_or(Error::Invalid("logical empty span"))?;
        let mut before = TextSummary::EMPTY;
        loop {
            match &node.items {
                Items::Branch(children) => {
                    let mut found = None;
                    for child in children {
                        let end = before.checked_add(child.summary)?;
                        if at < end.bytes {
                            found = Some(Arc::clone(child));
                            break;
                        }
                        before = end;
                    }
                    node = found.ok_or(Error::Invalid("logical span branch"))?;
                }
                Items::Leaf(spans) => {
                    for span in spans {
                        let end = before.checked_add(span.summary)?;
                        if at < end.bytes {
                            return Ok((span.clone(), before));
                        }
                        before = end;
                    }
                    return Err(Error::Invalid("logical span leaf"));
                }
            }
        }
    }
    /// Locate the existing <=64KiB backing piece, clipped at a logical span.
    /// Algorithms share that piece and never copy a cluster or whole source.
    pub(super) fn logical_source_piece(
        &mut self,
        snapshot: &LogicalSnapshot,
        at: u64,
    ) -> Result<SourcePiece> {
        let (span, before) = Self::logical_span(snapshot, at)?;
        match &span.backing {
            Backing::File(revision) => {
                let source_at = span
                    .start
                    .bytes
                    .checked_add(at - before.bytes)
                    .ok_or(Error::Invalid("logical piece offset"))?;
                let piece = self.source_piece(revision, source_at)?;
                let source_begin = span.start.bytes.max(piece.before.bytes);
                let source_end = span
                    .start
                    .bytes
                    .checked_add(span.summary.bytes)
                    .ok_or(Error::Invalid("logical piece end"))?
                    .min(
                        piece
                            .before
                            .bytes
                            .checked_add(piece.text()?.len() as u64)
                            .ok_or(Error::Invalid("logical backing end"))?,
                    );
                // Both possible clipping starts already have exact prefix
                // summaries. Do not rescan up to64KiB of a backing page for
                // every short span/line in a logical prefix transform.
                let point = if source_begin == span.start.bytes {
                    span.start
                } else {
                    piece.before
                };
                let local_begin = usize::try_from(source_begin - piece.before.bytes)
                    .map_err(|_| Error::Invalid("logical piece begin"))?;
                let local_end = usize::try_from(source_end - piece.before.bytes)
                    .map_err(|_| Error::Invalid("logical piece end"))?;
                let start = piece
                    .start
                    .checked_add(local_begin)
                    .ok_or(Error::Invalid("logical piece slice"))?;
                let end = piece
                    .start
                    .checked_add(local_end)
                    .ok_or(Error::Invalid("logical piece slice"))?;
                Ok(SourcePiece {
                    before: before.checked_add(difference(point, span.start)?)?,
                    bytes: piece.bytes,
                    start,
                    end,
                })
            }
            Backing::Insert(block) => {
                let first = usize::try_from(span.start.bytes)
                    .map_err(|_| Error::Invalid("logical insertion first"))?;
                let last = usize::try_from(
                    span.start
                        .bytes
                        .checked_add(span.summary.bytes)
                        .ok_or(Error::Invalid("logical insertion last"))?,
                )
                .map_err(|_| Error::Invalid("logical insertion last"))?;
                let bytes = block.range(self, snapshot.origin(), first..last)?;
                let end = bytes.len();
                Ok(SourcePiece {
                    before,
                    bytes,
                    start: 0,
                    end,
                })
            }
        }
    }
    pub fn logical_byte_position(
        &mut self,
        snapshot: &LogicalSnapshot,
        byte: u64,
    ) -> Result<LogicalPosition> {
        if byte > snapshot.summary().bytes {
            return Err(Error::Invalid("logical byte outside source"));
        }
        let point = if byte == snapshot.summary().bytes {
            snapshot.summary()
        } else {
            self.logical_source_piece(snapshot, byte)?.position(byte)?
        };
        Ok(LogicalPosition {
            snapshot: snapshot.clone(),
            point,
        })
    }
    pub(super) fn logical_lf_line_start(
        &mut self,
        snapshot: &LogicalSnapshot,
        origin: TextSummary,
    ) -> Result<TextSummary> {
        if origin.lf_count == 0 {
            return Ok(TextSummary::EMPTY);
        }
        let mut ordinal = origin.lf_count - 1;
        let mut node = snapshot
            .0
            .root
            .clone()
            .ok_or(Error::Invalid("logical LF root"))?;
        let mut before = TextSummary::EMPTY;
        loop {
            match &node.items {
                Items::Branch(children) => {
                    let mut found = None;
                    for child in children {
                        if ordinal < child.summary.lf_count {
                            found = Some(Arc::clone(child));
                            break;
                        }
                        ordinal -= child.summary.lf_count;
                        before = before.checked_add(child.summary)?;
                    }
                    node = found.ok_or(Error::Invalid("logical LF branch"))?;
                }
                Items::Leaf(spans) => {
                    for span in spans {
                        if ordinal >= span.summary.lf_count {
                            ordinal -= span.summary.lf_count;
                            before = before.checked_add(span.summary)?;
                            continue;
                        }
                        let at = match &span.backing {
                            Backing::File(revision) => difference(
                                self.lf_position(
                                    revision,
                                    span.start
                                        .lf_count
                                        .checked_add(ordinal)
                                        .ok_or(Error::Invalid("logical LF ordinal"))?,
                                )?,
                                span.start,
                            )?,
                            Backing::Insert(_) => {
                                let piece = self.logical_source_piece(snapshot, before.bytes)?;
                                let mut at = TextSummary::EMPTY;
                                let mut found = None;
                                for ch in piece.text()?.chars() {
                                    if ch == '\n' {
                                        if ordinal == 0 {
                                            found = Some(at);
                                            break;
                                        }
                                        ordinal -= 1;
                                    }
                                    at = at.checked_add(paragraph::scalar(ch))?;
                                }
                                found.ok_or(Error::Invalid("logical LF insertion"))?
                            }
                        };
                        return before.checked_add(at)?.checked_add(TextSummary::of("\n"));
                    }
                    return Err(Error::Invalid("logical LF leaf"));
                }
            }
        }
    }
    /// An untouched file paragraph can use its authenticated aggregate. A
    /// paragraph crossing an edited span falls back to the SAME bounded
    /// paragraph continuation, starting at the nearest preceding LF.
    pub(super) fn logical_paragraph_fast(
        &mut self,
        snapshot: &LogicalSnapshot,
        origin: TextSummary,
        include_line_endings: bool,
    ) -> Result<Option<ParagraphBounds>> {
        if snapshot.summary().bytes == 0 {
            return Ok(Some(ParagraphBounds {
                start: TextSummary::EMPTY,
                content_end: TextSummary::EMPTY,
                end: TextSummary::EMPTY,
                terminated: false,
                lf_terminated: false,
            }));
        }
        let (span, before) =
            Self::logical_span(snapshot, origin.bytes.min(snapshot.summary().bytes - 1))?;
        let Backing::File(revision) = &span.backing else {
            return Ok(None);
        };
        let file_origin = span.start.checked_add(difference(origin, before)?)?;
        let Some(bounds) =
            self.paragraph_bounds_fast(revision, file_origin, include_line_endings)?
        else {
            return Ok(None);
        };
        let span_end = span.start.checked_add(span.summary)?;
        let logical_end = before.checked_add(span.summary)?;
        if bounds.start.bytes < span.start.bytes
            || bounds.end.bytes > span_end.bytes
            || (bounds.start.bytes == span.start.bytes && before.bytes != 0)
            || (bounds.end.bytes == span_end.bytes && logical_end.bytes != snapshot.summary().bytes)
        {
            return Ok(None);
        }
        Ok(Some(ParagraphBounds {
            start: before.checked_add(difference(bounds.start, span.start)?)?,
            content_end: before.checked_add(difference(bounds.content_end, span.start)?)?,
            end: before.checked_add(difference(bounds.end, span.start)?)?,
            terminated: bounds.terminated,
            lf_terminated: bounds.lf_terminated,
        }))
    }
    pub fn logical_window(
        &mut self,
        snapshot: &LogicalSnapshot,
        utf16_anchor: u64,
        budget: usize,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LogicalWindow> {
        if !(4..=NATIVE_WINDOW_BYTES).contains(&budget) || utf16_anchor > snapshot.summary().utf16 {
            return Err(Error::Invalid("logical read budget"));
        }
        check_cancel(cancelled)?;
        let mut start = self
            .logical_position(
                snapshot,
                utf16_anchor.saturating_sub((budget / 4) as u64),
                true,
            )?
            .point;
        if start.bytes == snapshot.summary().bytes && start.bytes != 0 {
            start = self
                .logical_position(snapshot, utf16_anchor.saturating_sub(2), true)?
                .point;
        }
        let end = start
            .bytes
            .saturating_add(budget as u64)
            .min(snapshot.summary().bytes);
        let mut bytes = self.logical_read_range(snapshot, start.bytes..end, cancelled)?;
        if let Err(error) = std::str::from_utf8(&bytes) {
            if error.error_len().is_some() {
                return Err(Error::Invalid("logical window UTF8"));
            }
            bytes.truncate(error.valid_up_to());
        }
        check_cancel(cancelled)?;
        LogicalWindow::new(
            snapshot.clone(),
            start,
            String::from_utf8(bytes).map_err(|_| Error::Invalid("logical window UTF8"))?,
        )
    }
    pub fn logical_read_range(
        &mut self,
        snapshot: &LogicalSnapshot,
        range: Range<u64>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Vec<u8>> {
        if range.start > range.end
            || range.end > snapshot.summary().bytes
            || range.end - range.start > WINDOW_BYTES as u64
        {
            return Err(Error::Invalid("logical range read bound"));
        }
        let count = usize::try_from(range.end - range.start)
            .map_err(|_| Error::Invalid("logical range extent"))?;
        let mut bytes = Vec::with_capacity(count);
        fn read<S: PageProvider>(
            engine: &mut TextEngine<S>,
            tree: &Link,
            range: Range<u64>,
            origin: &Revision,
            output: &mut Vec<u8>,
            cancelled: &mut impl FnMut() -> bool,
        ) -> Result<()> {
            check_cancel(cancelled)?;
            let mut before = 0u64;
            match &tree.items {
                Items::Branch(children) => {
                    for child in children {
                        let end = before
                            .checked_add(child.summary.bytes)
                            .ok_or(Error::Invalid("logical read overflow"))?;
                        if end > range.start && before < range.end {
                            read(
                                engine,
                                child,
                                range.start.saturating_sub(before)..range.end.min(end) - before,
                                origin,
                                output,
                                cancelled,
                            )?;
                        }
                        before = end;
                    }
                }
                Items::Leaf(spans) => {
                    for span in spans {
                        let end = before
                            .checked_add(span.summary.bytes)
                            .ok_or(Error::Invalid("logical read overflow"))?;
                        if end > range.start && before < range.end {
                            let a = span
                                .start
                                .bytes
                                .checked_add(range.start.saturating_sub(before))
                                .ok_or(Error::Invalid("logical read start"))?;
                            let b = span
                                .start
                                .bytes
                                .checked_add(range.end.min(end) - before)
                                .ok_or(Error::Invalid("logical read end"))?;
                            match &span.backing {
                                Backing::File(revision) => {
                                    output.extend_from_slice(&engine.read_range(revision, a..b)?)
                                }
                                Backing::Insert(block) => {
                                    let a = usize::try_from(a)
                                        .map_err(|_| Error::Invalid("logical block read start"))?;
                                    let b = usize::try_from(b)
                                        .map_err(|_| Error::Invalid("logical block read end"))?;
                                    let bytes = block.range(engine, origin, a..b)?;
                                    output.extend_from_slice(&bytes);
                                }
                            }
                        }
                        before = end;
                    }
                }
            }
            Ok(())
        }
        if let Some(root) = &snapshot.0.root {
            read(self, root, range, snapshot.origin(), &mut bytes, cancelled)?;
        }
        if bytes.len() != count {
            return Err(Error::Invalid("logical range incomplete"));
        }
        Ok(bytes)
    }
    /// Worker-only candidate. Its exact endpoints come from the captured
    /// logical tree; it neither changes Main nor publishes a file root.
    pub fn prepare_logical_replacement(
        &mut self,
        snapshot: &LogicalSnapshot,
        first: u64,
        last: u64,
        inserted: &str,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<LogicalEdit> {
        if first > last || last > snapshot.summary().utf16 || inserted.len() > WINDOW_BYTES {
            return Err(Error::Invalid("logical candidate envelope"));
        }
        check_cancel(cancelled)?;
        let start = self.logical_position(snapshot, first, false)?;
        let end = self.logical_position(snapshot, last, false)?;
        let removed = difference(end.point, start.point)?;
        if removed.bytes == inserted.len() as u64 {
            let old =
                self.logical_read_range(snapshot, start.point.bytes..end.point.bytes, cancelled)?;
            if old == inserted.as_bytes() {
                let window = self.logical_window(snapshot, last, 16 * 1024, cancelled)?;
                return Ok(LogicalEdit {
                    changed: false,
                    window,
                    cursor: end,
                });
            }
        }
        let mut candidate = LogicalSource::preparing(snapshot.clone());
        let cursor = candidate.replace_positions(&start, &end, inserted)?;
        let root = candidate.capture_for_publication()?;
        let window = self.logical_window(&root, cursor.point.utf16, 16 * 1024, cancelled)?;
        Ok(LogicalEdit {
            changed: true,
            window,
            cursor,
        })
    }
    /// Share actual original text-piece references for a small file span.
    /// This avoids splitting/writing a full original path for each line of a
    /// prefix transform. Only one bounded piece vector/text page is resident.
    fn append_logical_file_span(
        &mut self,
        origin: &Revision,
        revision: &Revision,
        tree: &TreeRef,
        range: Range<u64>,
        pieces: &mut Vec<Piece>,
        output: &mut Option<TreeRef>,
    ) -> Result<()> {
        match self.node(revision, tree)? {
            Node::Branch(children) => {
                let mut before = 0_u64;
                for child in children {
                    let end = before
                        .checked_add(child.summary.bytes)
                        .ok_or(Error::Invalid("logical file slice branch"))?;
                    if before < range.end && end > range.start {
                        self.append_logical_file_span(
                            origin,
                            revision,
                            &child,
                            range.start.saturating_sub(before)..range.end.min(end) - before,
                            pieces,
                            output,
                        )?;
                    }
                    before = end;
                }
            }
            Node::Leaf(children) => {
                let mut before = 0_u64;
                for mut piece in children {
                    let end = before
                        .checked_add(piece.summary.bytes)
                        .ok_or(Error::Invalid("logical file slice leaf"))?;
                    if before < range.end && end > range.start {
                        let first = range.start.saturating_sub(before);
                        let last = range.end.min(end) - before;
                        if first != 0 || last != piece.summary.bytes {
                            let bytes = self.piece_text(revision, &piece)?;
                            let a = usize::try_from(
                                u64::from(piece.start)
                                    .checked_add(first)
                                    .ok_or(Error::Invalid("logical clipped start"))?,
                            )
                            .map_err(|_| Error::Invalid("logical clipped start"))?;
                            let b = usize::try_from(
                                u64::from(piece.start)
                                    .checked_add(last)
                                    .ok_or(Error::Invalid("logical clipped end"))?,
                            )
                            .map_err(|_| Error::Invalid("logical clipped end"))?;
                            let text = std::str::from_utf8(
                                bytes
                                    .get(a..b)
                                    .ok_or(Error::Invalid("logical clipped piece"))?,
                            )
                            .map_err(|_| Error::Invalid("logical clipped scalar"))?;
                            piece.start = u32::try_from(a)
                                .map_err(|_| Error::Invalid("logical clipped u32"))?;
                            piece.end = u32::try_from(b)
                                .map_err(|_| Error::Invalid("logical clipped u32"))?;
                            piece.summary = TextSummary::of(text);
                            piece.paragraphs = Some(ParagraphSummary::of(text));
                        }
                        pieces.push(piece);
                        if pieces.len() == FANOUT {
                            let part = self.leaf(origin, std::mem::take(pieces))?;
                            *output = self.join(origin, output.take(), part)?;
                        }
                    }
                    before = end;
                }
            }
        }
        Ok(())
    }
    /// Materialize a captured immutable snapshot on the existing writer only.
    /// Untouched file ranges and cached complete candidates retain their tree
    /// roots; no source String, flat edit array or whole file is assembled.
    pub fn materialize_logical(
        &mut self,
        snapshot: &LogicalSnapshot,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Revision> {
        fn materialize<S: PageProvider>(
            engine: &mut TextEngine<S>,
            node: &Link,
            origin: &Revision,
            cancelled: &mut impl FnMut() -> bool,
        ) -> Result<Option<TreeRef>> {
            check_cancel(cancelled)?;
            if let Some(candidate) = node.file_candidate.get() {
                return Ok(Some(candidate.clone()));
            }
            let mut result = None;
            match &node.items {
                Items::Branch(children) => {
                    for child in children {
                        let part = materialize(engine, child, origin, cancelled)?;
                        result = engine.join(origin, result, part)?;
                    }
                }
                Items::Leaf(spans) => {
                    pack_insertions(engine, origin, spans, cancelled)?;
                    let mut inserted = Vec::with_capacity(FANOUT);
                    for span in spans {
                        check_cancel(cancelled)?;
                        let part = match &span.backing {
                            Backing::File(revision) => {
                                if span.summary.bytes <= TEXT_PAGE_BYTES as u64 {
                                    let root = revision
                                        .root
                                        .as_ref()
                                        .ok_or(Error::Invalid("logical file span root"))?;
                                    let end = span
                                        .start
                                        .bytes
                                        .checked_add(span.summary.bytes)
                                        .ok_or(Error::Invalid("logical file span end"))?;
                                    engine.append_logical_file_span(
                                        origin,
                                        revision,
                                        root,
                                        span.start.bytes..end,
                                        &mut inserted,
                                        &mut result,
                                    )?;
                                    continue;
                                }
                                if !inserted.is_empty() {
                                    let part =
                                        engine.leaf(origin, std::mem::take(&mut inserted))?;
                                    result = engine.join(origin, result, part)?;
                                }
                                let mut part = revision.root.clone();
                                if let Some(root) = part {
                                    part = engine.split(revision, &root, span.start.bytes)?.1;
                                }
                                if let Some(root) = part {
                                    part = engine.split(revision, &root, span.summary.bytes)?.0;
                                }
                                part
                            }
                            Backing::Insert(block) => {
                                let file = block
                                    .0
                                    .lock()
                                    .map_err(|_| Error::Invalid("logical block lock"))?
                                    .candidate
                                    .clone()
                                    .ok_or(Error::Invalid("logical packed block missing"))?;
                                let start = file
                                    .start
                                    .checked_add(
                                        u32::try_from(span.start.bytes)
                                            .map_err(|_| Error::Invalid("logical piece start"))?,
                                    )
                                    .ok_or(Error::Invalid("logical piece start"))?;
                                let end = start
                                    .checked_add(
                                        u32::try_from(span.summary.bytes)
                                            .map_err(|_| Error::Invalid("logical piece end"))?,
                                    )
                                    .ok_or(Error::Invalid("logical piece end"))?;
                                let payload = engine.page(origin, PageKind::Text, &file.page)?;
                                let text = std::str::from_utf8(
                                    payload
                                        .get(start as usize..end as usize)
                                        .ok_or(Error::Invalid("logical packed piece"))?,
                                )
                                .map_err(|_| Error::Invalid("logical packed UTF8"))?;
                                inserted.push(Piece {
                                    chunk: file.page,
                                    start,
                                    end,
                                    summary: span.summary,
                                    paragraphs: Some(ParagraphSummary::of(text)),
                                });
                                if inserted.len() == FANOUT {
                                    let part =
                                        engine.leaf(origin, std::mem::take(&mut inserted))?;
                                    result = engine.join(origin, result, part)?;
                                }

                                continue;
                            }
                        };
                        if part
                            .as_ref()
                            .map_or(TextSummary::EMPTY, |root| root.summary)
                            != span.summary
                        {
                            return Err(Error::Invalid("logical persisted span summary"));
                        }
                        result = engine.join(origin, result, part)?;
                    }
                    if !inserted.is_empty() {
                        let part = engine.leaf(origin, inserted)?;
                        result = engine.join(origin, result, part)?;
                    }
                }
            }
            result = engine.collapse_root(origin, result)?;
            if result
                .as_ref()
                .map_or(TextSummary::EMPTY, |root| root.summary)
                != node.summary
            {
                return Err(Error::Invalid("logical materialization summary"));
            }
            if let Some(candidate) = &result {
                let _ = node.file_candidate.set(candidate.clone());
            }
            Ok(result)
        }
        let mut revision = snapshot.origin().clone();
        revision.root = match &snapshot.0.root {
            Some(root) => materialize(self, root, &revision, cancelled)?,
            None => None,
        };
        revision.validate()?;
        Ok(revision)
    }
}

impl LogicalSnapshot {
    /// Call on the writer only AFTER the actual page-file sync succeeded.
    /// This frees insertion memory, not input/history custody or a native ACK.
    /// Failure to publish the root keeps the same logical source and error.
    pub fn release_synced_insertions(&self) -> Result<()> {
        fn release(node: &Link) -> Result<()> {
            if node.synced_insertions.get().is_some() {
                return Ok(());
            }
            match &node.items {
                Items::Branch(children) => {
                    for child in children {
                        release(child)?;
                    }
                }
                Items::Leaf(spans) => {
                    for span in spans {
                        if let Backing::Insert(block) = &span.backing {
                            block.release_synced_bytes()?;
                        }
                    }
                }
            }
            let _ = node.synced_insertions.set(());
            Ok(())
        }
        if let Some(root) = &self.0.root {
            release(root)?;
        }
        Ok(())
    }
}
