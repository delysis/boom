//! Disk-paged text operations with bounded resident source and index data.
//!
//! The host owns authenticated immutable page I/O and durable root publication.
//! These synchronous operations belong on its storage executor, never the UI
//! thread. A revision identifies a paged tree; it is not a whole-text SHA256.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::io::{Cursor, Read, Write};
use std::mem::size_of;
use std::ops::Range;
use std::sync::Arc;
use uuid::Uuid;

mod bulk;
pub use bulk::{BULK_OPERATION_COUNT, BULK_STEP_WORK, BulkProgress};

pub const TEXT_PAGE_BYTES: usize = 64 * 1024;
pub const INDEX_PAGE_BYTES: usize = 16 * 1024;
pub const WINDOW_BYTES: usize = 128 * 1024;
pub const CACHE_BYTES: usize = 8 * 1024 * 1024;
pub const FANOUT: usize = 32;
const CACHE_ENTRIES: usize = 512;
const MAX_HEIGHT: u8 = 12;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Text storage: {0}")]
    Storage(String),
    #[error("Invalid paged text: {0}")]
    Invalid(&'static str),
    #[error("The document changed since this operation was captured.")]
    Stale,
    #[error("The text operation was cancelled.")]
    Cancelled,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TextSummary {
    pub bytes: u64,
    pub utf16: u64,
    pub lf_count: u64,
}
impl TextSummary {
    pub const EMPTY: Self = Self {
        bytes: 0,
        utf16: 0,
        lf_count: 0,
    };
    fn of(text: &str) -> Self {
        Self {
            bytes: text.len() as u64,
            utf16: text.encode_utf16().count() as u64,
            lf_count: text.bytes().filter(|b| *b == b'\n').count() as u64,
        }
    }
    fn checked_add(self, other: Self) -> Result<Self> {
        let add = |a: u64, b: u64| a.checked_add(b).ok_or(Error::Invalid("summary overflow"));
        Ok(Self {
            bytes: add(self.bytes, other.bytes)?,
            utf16: add(self.utf16, other.utf16)?,
            lf_count: add(self.lf_count, other.lf_count)?,
        })
    }
    fn validate(self) -> Result<()> {
        if self.utf16 > self.bytes
            || self.lf_count > self.utf16
            || (self.bytes != 0 && self.utf16 == 0)
        {
            return Err(Error::Invalid("inconsistent text summary"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PageKind {
    Text,
    Index,
}
impl PageKind {
    pub fn maximum_bytes(self) -> usize {
        match self {
            Self::Text => TEXT_PAGE_BYTES,
            Self::Index => INDEX_PAGE_BYTES,
        }
    }
}

/// One explicit new storage identity. A UUID database object is never a
/// physical file offset or SQLite rowid. Unknown/mixed fields fail closed.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum SQLiteStorage {
    #[serde(rename = "sqlite_v1")]
    V1,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PageLocator {
    pub storage: SQLiteStorage,
    pub store_id: Uuid,
    pub record_id: Uuid,
    pub ciphertext_bytes: u32,
}
impl PageLocator {
    pub fn record_id(&self) -> Uuid { self.record_id }
    pub fn ciphertext_bytes(&self) -> u32 { self.ciphertext_bytes }
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PageRef {
    pub locator: PageLocator,
    pub digest: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TreeRef {
    pub page: PageRef,
    pub summary: TextSummary,
    pub height: u8,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Revision {
    pub schema: u8,
    pub owner_id: Uuid,
    pub document_id: Uuid,
    #[serde(deserialize_with = "deserialize_root")]
    pub root: Option<TreeRef>,
}
// A null root is an explicit empty document. An omitted root is a malformed
// revision, not permission to silently replace a document with an empty one.
fn deserialize_root<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<TreeRef>, D::Error> {
    Option::deserialize(deserializer)
}
impl Revision {
    pub fn summary(&self) -> TextSummary {
        self.root
            .as_ref()
            .map_or(TextSummary::EMPTY, |root| root.summary)
    }
    fn validate(&self) -> Result<()> {
        if self.schema != 1 || self.owner_id.is_nil() || self.document_id.is_nil() {
            return Err(Error::Invalid("revision owner or schema"));
        }
        if let Some(root) = &self.root {
            validate_ref(root)?;
            if root.summary.bytes == 0 {
                return Err(Error::Invalid("empty root page"));
            }
        }
        Ok(())
    }
}

/// Only an opened and checked revision can become an active document.
pub struct Document {
    revision: Revision,
}
impl Document {
    pub fn revision(&self) -> &Revision {
        &self.revision
    }
    pub fn summary(&self) -> TextSummary {
        self.revision.summary()
    }
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub revision: Revision,
    pub window_id: Uuid,
    pub byte_start: u64,
    pub utf16_start: u64,
    /// Number of LF bytes preceding this window, not a CR-normalized count.
    pub lf_start: u64,
    pub text: String,
}
pub struct Imported {
    pub document: Document,
    pub whole_text_sha256: String,
}
#[derive(Clone, Copy, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheStats {
    pub charged_bytes: usize,
    pub entries: usize,
    pub page_reads: u64,
    pub read_bytes: u64,
    pub page_writes: u64,
    pub cache_hits: u64,
}

/// The existing Vault implements this interface on its storage executor.
///
/// Every record must be immutable and AEAD-bound to owner, document, storage
/// incarnation, record ID, kind and size.
/// Enforce maximum_bytes before allocating
/// a read buffer. No keys, filesystem paths or authentication flags cross here.
/// A write returns a candidate locator in the host's held transaction. The host
/// publishes a durable root only after page work and the actual COMMIT join.
pub trait PageProvider {
    fn read(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        page: &PageRef,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>>;
    fn write_new(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        bytes: &[u8],
    ) -> Result<PageLocator>;
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Piece {
    chunk: PageRef,
    start: u32,
    end: u32,
    summary: TextSummary,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", content = "items", rename_all = "snake_case")]
enum Node {
    Leaf(Vec<Piece>),
    Branch(Vec<TreeRef>),
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IndexPage {
    schema: u8,
    owner_id: Uuid,
    document_id: Uuid,
    node: Node,
}
impl Node {
    fn summary(&self) -> Result<TextSummary> {
        match self {
            Self::Leaf(pieces) => pieces.iter().try_fold(TextSummary::EMPTY, |total, piece| {
                total.checked_add(piece.summary)
            }),
            Self::Branch(children) => children
                .iter()
                .try_fold(TextSummary::EMPTY, |total, child| {
                    total.checked_add(child.summary)
                }),
        }
    }
    fn validate(&self, height: u8) -> Result<()> {
        match self {
            Self::Leaf(pieces) => {
                if height != 0 || pieces.is_empty() || pieces.len() > FANOUT {
                    return Err(Error::Invalid("leaf shape"));
                }
                for piece in pieces {
                    validate_page(&piece.chunk, PageKind::Text)?;
                    piece.summary.validate()?;
                    if piece.start >= piece.end
                        || piece.end as usize > TEXT_PAGE_BYTES
                        || piece.summary.bytes != u64::from(piece.end - piece.start)
                    {
                        return Err(Error::Invalid("piece bounds"));
                    }
                }
            }
            Self::Branch(children) => {
                if height == 0 || children.is_empty() || children.len() > FANOUT {
                    return Err(Error::Invalid("branch shape"));
                }
                for child in children {
                    validate_ref(child)?;
                    if child.height.checked_add(1) != Some(height) {
                        return Err(Error::Invalid("unbalanced tree"));
                    }
                }
            }
        }
        self.summary()?.validate()
    }
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn validate_page(page: &PageRef, kind: PageKind) -> Result<()> {
    let p = &page.locator;
    let invalid_address = p.store_id.is_nil() || p.record_id.is_nil()
        || p.ciphertext_bytes < 28
        || p.ciphertext_bytes as usize > kind.maximum_bytes() + 28;
    if invalid_address || page.digest.len() != 64
        || !page.digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(Error::Invalid("page locator or digest"));
    }
    Ok(())
}
fn validate_ref(node: &TreeRef) -> Result<()> {
    if node.height > MAX_HEIGHT {
        return Err(Error::Invalid("tree height limit"));
    }
    node.summary.validate()?;
    validate_page(&node.page, PageKind::Index)
}
fn check_cancel(cancelled: &mut impl FnMut() -> bool) -> Result<()> {
    if cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}

struct CachedPage {
    owner: Uuid,
    document: Uuid,
    kind: PageKind,
    page: PageRef,
    bytes: Arc<[u8]>,
}
/// Share one engine/cache across the host's active document sessions. Opening
/// documents does not allocate another cache, read all leaves, or retain roots.
pub struct TextEngine<S> {
    provider: S,
    cache: VecDeque<CachedPage>,
    cache_budget: usize,
    stats: CacheStats,
    bulk: bulk::Registry,
}
impl<S: PageProvider> TextEngine<S> {
    pub fn new(provider: S) -> Self {
        Self::with_cache_budget(provider, CACHE_BYTES)
    }
    pub fn with_cache_budget(provider: S, bytes: usize) -> Self {
        Self {
            provider,
            cache: VecDeque::with_capacity(CACHE_ENTRIES),
            cache_budget: bytes.min(CACHE_BYTES),
            stats: CacheStats::default(),
            bulk: bulk::Registry::default(),
        }
    }
    pub fn stats(&self) -> CacheStats {
        CacheStats {
            entries: self.cache.len(),
            ..self.stats
        }
    }
    /// The host calls this only after the actual SQL operation returns and its
    /// rollback/uncertain COMMIT has fenced further source admission. This is
    /// cache cleanup, never evidence that publication did not happen. Existing
    /// cumulative IO counters remain intact; bulk producers are joined separately.
    pub fn discard_page_cache_after_rollback(&mut self) {
        self.cache.clear();
        self.stats.charged_bytes = 0;
    }
    pub fn into_provider(self) -> S {
        self.provider
    }
    pub fn open(&mut self, revision: Revision) -> Result<Document> {
        revision.validate()?;
        if let Some(root) = &revision.root {
            self.node(&revision, root)?;
        }
        Ok(Document { revision })
    }
    fn page(&mut self, revision: &Revision, kind: PageKind, page: &PageRef) -> Result<Arc<[u8]>> {
        validate_page(page, kind)?;
        if let Some(index) = self.cache.iter().position(|entry| {
            entry.owner == revision.owner_id
                && entry.document == revision.document_id
                && entry.kind == kind
                && entry.page == *page
        }) {
            let entry = self
                .cache
                .remove(index)
                .ok_or(Error::Invalid("cache position"))?;
            let bytes = Arc::clone(&entry.bytes);
            self.cache.push_back(entry);
            self.stats.cache_hits = self.stats.cache_hits.saturating_add(1);
            return Ok(bytes);
        }
        let bytes = self.provider.read(
            revision.owner_id,
            revision.document_id,
            kind,
            page,
            kind.maximum_bytes(),
        )?;
        if bytes.len() > kind.maximum_bytes() || digest(&bytes) != page.digest {
            return Err(Error::Invalid("page size or digest"));
        }
        // Immutable text pages are validated once per verified cache load.
        // Reusing many tiny pieces must not rescan the entire 64 KiB chunk.
        if kind == PageKind::Text {
            std::str::from_utf8(&bytes).map_err(|_| Error::Invalid("text page UTF8"))?;
        }
        self.stats.page_reads = self.stats.page_reads.saturating_add(1);
        self.stats.read_bytes = self.stats.read_bytes.saturating_add(bytes.len() as u64);
        let bytes: Arc<[u8]> = bytes.into();
        // Charge retained payload and its metadata. Fixed queue capacity and
        // transient one-page decode/return buffers are separate constant bounds.
        let charge = bytes.len() + size_of::<CachedPage>() + page.digest.len() + 32;
        if charge <= self.cache_budget {
            while self.stats.charged_bytes + charge > self.cache_budget
                || self.cache.len() >= CACHE_ENTRIES
            {
                let Some(old) = self.cache.pop_front() else {
                    break;
                };
                self.stats.charged_bytes -=
                    old.bytes.len() + size_of::<CachedPage>() + old.page.digest.len() + 32;
            }
            self.cache.push_back(CachedPage {
                owner: revision.owner_id,
                document: revision.document_id,
                kind,
                page: page.clone(),
                bytes: Arc::clone(&bytes),
            });
            self.stats.charged_bytes += charge;
        }
        Ok(bytes)
    }
    fn write_page(&mut self, revision: &Revision, kind: PageKind, bytes: &[u8]) -> Result<PageRef> {
        if bytes.len() > kind.maximum_bytes() {
            return Err(Error::Invalid("page write bound"));
        }
        let locator =
            self.provider
                .write_new(revision.owner_id, revision.document_id, kind, bytes)?;
        let page = PageRef {
            locator,
            digest: digest(bytes),
        };
        validate_page(&page, kind)?;
        self.stats.page_writes = self.stats.page_writes.saturating_add(1);
        Ok(page)
    }
    fn node(&mut self, revision: &Revision, node: &TreeRef) -> Result<Node> {
        validate_ref(node)?;
        let bytes = self.page(revision, PageKind::Index, &node.page)?;
        let page: IndexPage =
            serde_json::from_slice(&bytes).map_err(|_| Error::Invalid("index encoding"))?;
        if page.schema != 1
            || page.owner_id != revision.owner_id
            || page.document_id != revision.document_id
        {
            return Err(Error::Invalid("index owner or schema"));
        }
        page.node.validate(node.height)?;
        if page.node.summary()? != node.summary {
            return Err(Error::Invalid("index summary"));
        }
        Ok(page.node)
    }
    fn write_node(&mut self, revision: &Revision, node: Node, height: u8) -> Result<TreeRef> {
        if height > MAX_HEIGHT {
            return Err(Error::Invalid("tree height limit"));
        }
        node.validate(height)?;
        let summary = node.summary()?;
        let bytes = serde_json::to_vec(&IndexPage {
            schema: 1,
            owner_id: revision.owner_id,
            document_id: revision.document_id,
            node,
        })
        .map_err(|_| Error::Invalid("index encoding"))?;
        Ok(TreeRef {
            page: self.write_page(revision, PageKind::Index, &bytes)?,
            summary,
            height,
        })
    }
}

impl<S: PageProvider> TextEngine<S> {
    fn leaf(&mut self, revision: &Revision, pieces: Vec<Piece>) -> Result<Option<TreeRef>> {
        if pieces.is_empty() {
            return Ok(None);
        }
        let mut compacted: Vec<Piece> = Vec::with_capacity(pieces.len());
        for piece in pieces {
            if let Some(last) = compacted.last_mut()
                && last.chunk == piece.chunk
                && last.end == piece.start
            {
                last.end = piece.end;
                last.summary = last.summary.checked_add(piece.summary)?;
            } else {
                compacted.push(piece);
            }
        }
        self.write_node(revision, Node::Leaf(compacted), 0)
            .map(Some)
    }
    fn branch(
        &mut self,
        revision: &Revision,
        children: Vec<TreeRef>,
        height: u8,
    ) -> Result<Option<TreeRef>> {
        if children.is_empty() {
            return Ok(None);
        }
        self.write_node(revision, Node::Branch(children), height)
            .map(Some)
    }
    fn piece_text(&mut self, revision: &Revision, piece: &Piece) -> Result<Arc<[u8]>> {
        let bytes = self.page(revision, PageKind::Text, &piece.chunk)?;
        let part = bytes
            .get(piece.start as usize..piece.end as usize)
            .ok_or(Error::Invalid("piece character boundary"))?;
        let text =
            std::str::from_utf8(part).map_err(|_| Error::Invalid("piece character boundary"))?;
        if TextSummary::of(text) != piece.summary {
            return Err(Error::Invalid("piece text summary"));
        }
        Ok(bytes)
    }
    fn split(
        &mut self,
        revision: &Revision,
        tree: &TreeRef,
        at: u64,
    ) -> Result<(Option<TreeRef>, Option<TreeRef>)> {
        if at > tree.summary.bytes {
            return Err(Error::Invalid("split outside tree"));
        }
        if at == 0 {
            return Ok((None, Some(tree.clone())));
        }
        if at == tree.summary.bytes {
            return Ok((Some(tree.clone()), None));
        }
        match self.node(revision, tree)? {
            Node::Leaf(pieces) => {
                let mut left = Vec::with_capacity(FANOUT);
                let mut right = Vec::with_capacity(FANOUT);
                let mut position = 0;
                for piece in pieces {
                    let end = position + piece.summary.bytes;
                    if end <= at {
                        left.push(piece);
                    } else if position >= at {
                        right.push(piece);
                    } else {
                        let bytes = self.piece_text(revision, &piece)?;
                        let source = std::str::from_utf8(&bytes)
                            .map_err(|_| Error::Invalid("text page UTF8"))?;
                        let middle = piece.start
                            + u32::try_from(at - position)
                                .map_err(|_| Error::Invalid("piece split offset"))?;
                        let before = source
                            .get(piece.start as usize..middle as usize)
                            .ok_or(Error::Invalid("split inside UTF8 scalar"))?;
                        let after = source
                            .get(middle as usize..piece.end as usize)
                            .ok_or(Error::Invalid("split inside UTF8 scalar"))?;
                        left.push(Piece {
                            chunk: piece.chunk.clone(),
                            start: piece.start,
                            end: middle,
                            summary: TextSummary::of(before),
                        });
                        right.push(Piece {
                            chunk: piece.chunk,
                            start: middle,
                            end: piece.end,
                            summary: TextSummary::of(after),
                        });
                    }
                    position = end;
                }
                Ok((self.leaf(revision, left)?, self.leaf(revision, right)?))
            }
            Node::Branch(children) => {
                let mut left = Vec::with_capacity(FANOUT);
                let mut right = Vec::with_capacity(FANOUT);
                let mut position = 0;
                for child in children {
                    let end = position + child.summary.bytes;
                    if end <= at {
                        left.push(child);
                    } else if position >= at {
                        right.push(child);
                    } else {
                        let (before, after) = self.split(revision, &child, at - position)?;
                        if let Some(before) = before {
                            left.push(before);
                        }
                        if let Some(after) = after {
                            right.push(after);
                        }
                    }
                    position = end;
                }
                // Preserve this level during recursion. Only the finished root
                // is collapsed; its parent must never acquire mixed heights.
                Ok((
                    self.branch(revision, left, tree.height)?,
                    self.branch(revision, right, tree.height)?,
                ))
            }
        }
    }
    fn pack_leaves(&mut self, revision: &Revision, mut pieces: Vec<Piece>) -> Result<Vec<TreeRef>> {
        let mut result = Vec::with_capacity(2);
        if pieces.len() > FANOUT {
            let suffix = pieces.split_off(pieces.len() / 2);
            if let Some(left) = self.leaf(revision, pieces)? {
                result.push(left);
            }
            if let Some(right) = self.leaf(revision, suffix)? {
                result.push(right);
            }
        } else if let Some(root) = self.leaf(revision, pieces)? {
            result.push(root);
        }
        Ok(result)
    }
    fn pack_branches(
        &mut self,
        revision: &Revision,
        mut children: Vec<TreeRef>,
        height: u8,
    ) -> Result<Vec<TreeRef>> {
        let mut result = Vec::with_capacity(2);
        if children.len() > FANOUT {
            let suffix = children.split_off(children.len() / 2);
            if let Some(left) = self.branch(revision, children, height)? {
                result.push(left);
            }
            if let Some(right) = self.branch(revision, suffix, height)? {
                result.push(right);
            }
        } else if let Some(root) = self.branch(revision, children, height)? {
            result.push(root);
        }
        Ok(result)
    }
    // Return one or two roots at max(left.height, right.height); the caller
    // packs any overflow into its own level. No untouched subtree is loaded.
    fn join_level(
        &mut self,
        revision: &Revision,
        left: TreeRef,
        right: TreeRef,
    ) -> Result<Vec<TreeRef>> {
        if left.height == right.height {
            match (self.node(revision, &left)?, self.node(revision, &right)?) {
                (Node::Leaf(mut a), Node::Leaf(b)) => {
                    a.extend(b);
                    self.pack_leaves(revision, a)
                }
                (Node::Branch(mut a), Node::Branch(b)) => {
                    a.extend(b);
                    self.pack_branches(revision, a, left.height)
                }
                _ => Err(Error::Invalid("join height")),
            }
        } else if left.height > right.height {
            let Node::Branch(mut children) = self.node(revision, &left)? else {
                return Err(Error::Invalid("join branch"));
            };
            let edge = children.pop().ok_or(Error::Invalid("empty join branch"))?;
            children.extend(self.join_level(revision, edge, right)?);
            self.pack_branches(revision, children, left.height)
        } else {
            let Node::Branch(mut children) = self.node(revision, &right)? else {
                return Err(Error::Invalid("join branch"));
            };
            let edge = children.remove(0);
            let mut joined = self.join_level(revision, left, edge)?;
            joined.append(&mut children);
            self.pack_branches(revision, joined, right.height)
        }
    }
    fn join(
        &mut self,
        revision: &Revision,
        left: Option<TreeRef>,
        right: Option<TreeRef>,
    ) -> Result<Option<TreeRef>> {
        match (left, right) {
            (None, root) | (root, None) => Ok(root),
            (Some(left), Some(right)) => {
                let mut roots = self.join_level(revision, left, right)?;
                if roots.len() == 1 {
                    return Ok(roots.pop());
                }
                let height = roots
                    .first()
                    .ok_or(Error::Invalid("empty join"))?
                    .height
                    .checked_add(1)
                    .ok_or(Error::Invalid("tree height overflow"))?;
                self.branch(revision, roots, height)
            }
        }
    }
    fn collapse_root(
        &mut self,
        revision: &Revision,
        mut root: Option<TreeRef>,
    ) -> Result<Option<TreeRef>> {
        while let Some(current) = &root {
            if current.height == 0 {
                break;
            }
            let Node::Branch(mut children) = self.node(revision, current)? else {
                return Err(Error::Invalid("root height"));
            };
            if children.len() != 1 {
                break;
            }
            root = children.pop();
        }
        Ok(root)
    }
    fn prefix_summary(
        &mut self,
        revision: &Revision,
        tree: &TreeRef,
        at: u64,
    ) -> Result<TextSummary> {
        if at > tree.summary.bytes {
            return Err(Error::Invalid("prefix outside tree"));
        }
        if at == tree.summary.bytes {
            return Ok(tree.summary);
        }
        let mut total = TextSummary::EMPTY;
        match self.node(revision, tree)? {
            Node::Leaf(pieces) => {
                for piece in pieces {
                    let end = total.bytes + piece.summary.bytes;
                    if end <= at {
                        total = total.checked_add(piece.summary)?;
                    } else {
                        let bytes = self.piece_text(revision, &piece)?;
                        let start = piece.start as usize;
                        let end = start
                            + usize::try_from(at - total.bytes)
                                .map_err(|_| Error::Invalid("prefix offset"))?;
                        let text = std::str::from_utf8(&bytes)
                            .map_err(|_| Error::Invalid("text page UTF8"))?
                            .get(start..end)
                            .ok_or(Error::Invalid("prefix inside UTF8 scalar"))?;
                        return total.checked_add(TextSummary::of(text));
                    }
                }
            }
            Node::Branch(children) => {
                for child in children {
                    let end = total.bytes + child.summary.bytes;
                    if end <= at {
                        total = total.checked_add(child.summary)?;
                    } else {
                        return total.checked_add(self.prefix_summary(
                            revision,
                            &child,
                            at - total.bytes,
                        )?);
                    }
                }
            }
        }
        Ok(total)
    }
    fn visit(
        &mut self,
        revision: &Revision,
        tree: &TreeRef,
        range: Range<u64>,
        visitor: &mut impl FnMut(&[u8]) -> Result<()>,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        check_cancel(cancelled)?;
        if range.start >= range.end {
            return Ok(());
        }
        if range.end > tree.summary.bytes {
            return Err(Error::Invalid("read outside tree"));
        }
        let mut position = 0;
        match self.node(revision, tree)? {
            Node::Leaf(pieces) => {
                for piece in pieces {
                    let end = position + piece.summary.bytes;
                    if end > range.start && position < range.end {
                        check_cancel(cancelled)?;
                        let bytes = self.piece_text(revision, &piece)?;
                        let start =
                            piece.start as usize + (range.start.saturating_sub(position)) as usize;
                        let stop = piece.start as usize + (range.end.min(end) - position) as usize;
                        visitor(
                            bytes
                                .get(start..stop)
                                .ok_or(Error::Invalid("read piece bounds"))?,
                        )?;
                    }
                    position = end;
                }
            }
            Node::Branch(children) => {
                for child in children {
                    let end = position + child.summary.bytes;
                    if end > range.start && position < range.end {
                        self.visit(
                            revision,
                            &child,
                            range.start.saturating_sub(position)..range.end.min(end) - position,
                            visitor,
                            cancelled,
                        )?;
                    }
                    position = end;
                }
            }
        }
        Ok(())
    }
    fn read_range(&mut self, revision: &Revision, range: Range<u64>) -> Result<Vec<u8>> {
        let length = range
            .end
            .checked_sub(range.start)
            .ok_or(Error::Invalid("reversed range"))?;
        if length > WINDOW_BYTES as u64 || range.end > revision.summary().bytes {
            return Err(Error::Invalid("bounded range"));
        }
        let mut bytes = Vec::with_capacity(length as usize);
        if let Some(root) = &revision.root {
            self.visit(
                revision,
                root,
                range,
                &mut |part| {
                    bytes.extend_from_slice(part);
                    Ok(())
                },
                &mut || false,
            )?;
        }
        if bytes.len() as u64 != length {
            return Err(Error::Invalid("incomplete range"));
        }
        Ok(bytes)
    }
    /// start is an exact UTF8 scalar boundary. The end is trimmed by at most
    /// three bytes to a scalar boundary; neither byte content nor line endings
    /// are normalized. Grapheme/wrap continuation belongs to the native window.
    pub fn window(
        &mut self,
        document: &Document,
        expected: &Revision,
        start: u64,
        budget: usize,
    ) -> Result<Window> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        if budget == 0 || budget > WINDOW_BYTES || start > document.summary().bytes {
            return Err(Error::Invalid("window budget or start"));
        }
        let prefix = match &expected.root {
            Some(root) => self.prefix_summary(expected, root, start)?,
            None => TextSummary::EMPTY,
        };
        let end = start
            .saturating_add(budget as u64)
            .min(document.summary().bytes);
        let mut bytes = self.read_range(expected, start..end)?;
        if let Err(error) = std::str::from_utf8(&bytes) {
            if error.error_len().is_some() {
                return Err(Error::Invalid("window UTF8"));
            }
            bytes.truncate(error.valid_up_to());
        }
        if bytes.is_empty() && start < document.summary().bytes {
            return Err(Error::Invalid("window too small for a UTF8 scalar"));
        }
        let text = String::from_utf8(bytes).map_err(|_| Error::Invalid("window UTF8"))?;
        Ok(Window {
            revision: expected.clone(),
            window_id: Uuid::new_v4(),
            byte_start: start,
            utf16_start: prefix.utf16,
            lf_start: prefix.lf_count,
            text,
        })
    }
    /// The host owns permission and current-root CAS. Bounded captured edits
    /// must also pass exact old bytes; large explicit user deletions can rely
    /// on the complete expected root without materializing the deleted text.
    pub fn splice(
        &mut self,
        document: &mut Document,
        expected: &Revision,
        range: Range<u64>,
        exact_old: Option<&[u8]>,
        inserted: &str,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Revision> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        check_cancel(cancelled)?;
        if range.start > range.end
            || range.end > document.summary().bytes
            || inserted.len() > WINDOW_BYTES
        {
            return Err(Error::Invalid("edit bounds"));
        }
        if let Some(old) = exact_old
            && self.read_range(expected, range.clone())? != old
        {
            return Err(Error::Stale);
        }
        // Check both scalar boundaries, including a huge deletion that never
        // loads the intervening subtrees.
        if let Some(root) = &expected.root {
            self.prefix_summary(expected, root, range.start)?;
            self.prefix_summary(expected, root, range.end)?;
        }
        let (left, tail) = match &expected.root {
            Some(root) => self.split(expected, root, range.start)?,
            None => (None, None),
        };
        let right = match tail {
            Some(root) => self.split(expected, &root, range.end - range.start)?.1,
            None => None,
        };
        let inserted_root = self.build_text(expected, inserted.as_bytes(), cancelled)?;
        let prefix = self.join(expected, left, inserted_root)?;
        let joined = self.join(expected, prefix, right)?;
        let root = self.collapse_root(expected, joined)?;
        check_cancel(cancelled)?;
        let after = Revision {
            root,
            ..expected.clone()
        };
        after.validate()?;
        document.revision = after.clone();
        Ok(after)
    }
    /// Undo/redo checks ownership and the expected current revision, then opens
    /// only the retained root. The host retains history on disk, not this engine.
    pub fn checkout(
        &mut self,
        document: &mut Document,
        expected: &Revision,
        retained: Revision,
    ) -> Result<()> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        if retained.owner_id != expected.owner_id || retained.document_id != expected.document_id {
            return Err(Error::Invalid("history owner"));
        }
        *document = self.open(retained)?;
        Ok(())
    }
    pub fn export(
        &mut self,
        document: &Document,
        expected: &Revision,
        writer: &mut impl Write,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<()> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        check_cancel(cancelled)?;
        if let Some(root) = &expected.root {
            self.visit(
                expected,
                root,
                0..root.summary.bytes,
                &mut |part| {
                    writer.write_all(part)?;
                    Ok(())
                },
                cancelled,
            )?;
        }
        Ok(())
    }
    /// A real full-text digest requires every exact byte. It is intentionally
    /// a separate streaming background operation, never a computed revision.
    pub fn whole_text_sha256(
        &mut self,
        document: &Document,
        expected: &Revision,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<String> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        let mut hash = Sha256::new();
        check_cancel(cancelled)?;
        if let Some(root) = &expected.root {
            self.visit(
                expected,
                root,
                0..root.summary.bytes,
                &mut |part| {
                    hash.update(part);
                    Ok(())
                },
                cancelled,
            )?;
        }
        Ok(format!("{:x}", hash.finalize()))
    }
}

impl<S: PageProvider> TextEngine<S> {
    fn frontier_push(
        &mut self,
        revision: &Revision,
        levels: &mut [Vec<TreeRef>],
        mut level: usize,
        mut root: TreeRef,
    ) -> Result<()> {
        loop {
            let slot = levels
                .get_mut(level)
                .ok_or(Error::Invalid("import tree height"))?;
            slot.push(root);
            if slot.len() < FANOUT {
                return Ok(());
            }
            let children = std::mem::take(slot);
            root = self.write_node(
                revision,
                Node::Branch(children),
                u8::try_from(level + 1).map_err(|_| Error::Invalid("import tree height"))?,
            )?;
            level += 1;
        }
    }
    fn import_root(
        &mut self,
        revision: &Revision,
        reader: &mut impl Read,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<(Option<TreeRef>, String)> {
        // Fixed frontier, fixed UTF8 buffer. No list of all pages or line starts
        // is accumulated, even while importing a very large single line.
        let mut levels: Vec<Vec<TreeRef>> = (0..=MAX_HEIGHT)
            .map(|_| Vec::with_capacity(FANOUT))
            .collect();
        let mut pieces = Vec::with_capacity(FANOUT);
        let mut buffer = vec![0_u8; TEXT_PAGE_BYTES];
        let mut used = 0;
        let mut eof = false;
        let mut hash = Sha256::new();
        loop {
            check_cancel(cancelled)?;
            while !eof && used < buffer.len() {
                check_cancel(cancelled)?;
                match reader.read(&mut buffer[used..]) {
                    Ok(0) => eof = true,
                    Ok(n) => used += n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(Error::Io(e)),
                }
            }
            if used == 0 {
                break;
            }
            let valid = match std::str::from_utf8(&buffer[..used]) {
                Ok(_) => used,
                Err(e) if !eof && e.error_len().is_none() => e.valid_up_to(),
                Err(_) => return Err(Error::Invalid("import UTF8")),
            };
            if valid == 0 {
                return Err(Error::Invalid("incomplete UTF8 scalar"));
            }
            let text =
                std::str::from_utf8(&buffer[..valid]).map_err(|_| Error::Invalid("import UTF8"))?;
            let summary = TextSummary::of(text);
            hash.update(text.as_bytes());
            let chunk = self.write_page(revision, PageKind::Text, text.as_bytes())?;
            pieces.push(Piece {
                chunk,
                start: 0,
                end: valid as u32,
                summary,
            });
            if pieces.len() == FANOUT {
                let leaf = self.write_node(revision, Node::Leaf(std::mem::take(&mut pieces)), 0)?;
                self.frontier_push(revision, &mut levels, 0, leaf)?;
                pieces = Vec::with_capacity(FANOUT);
            }
            buffer.copy_within(valid..used, 0);
            used -= valid;
        }
        if !pieces.is_empty() {
            let leaf = self.write_node(revision, Node::Leaf(pieces), 0)?;
            self.frontier_push(revision, &mut levels, 0, leaf)?;
        }
        let mut root = None;
        for (level, slot) in levels.into_iter().enumerate().rev() {
            check_cancel(cancelled)?;
            let tree = if slot.len() == 1 {
                slot.into_iter().next()
            } else if slot.is_empty() {
                None
            } else {
                self.branch(revision, slot, (level + 1) as u8)?
            };
            root = self.join(revision, root, tree)?;
        }
        let root = self.collapse_root(revision, root)?;
        check_cancel(cancelled)?;
        Ok((root, format!("{:x}", hash.finalize())))
    }
    fn build_text(
        &mut self,
        revision: &Revision,
        bytes: &[u8],
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Option<TreeRef>> {
        self.import_root(revision, &mut Cursor::new(bytes), cancelled)
            .map(|(root, _)| root)
    }
    /// Streaming validation/encryption writes complete before the returned
    /// document can be published. Cancellation never returns a partial revision;
    /// the host retains or reclaims its unpublished encrypted staging records.
    pub fn import_utf8(
        &mut self,
        owner: Uuid,
        document: Uuid,
        reader: &mut impl Read,
        cancelled: &mut impl FnMut() -> bool,
    ) -> Result<Imported> {
        let mut revision = Revision {
            schema: 1,
            owner_id: owner,
            document_id: document,
            root: None,
        };
        revision.validate()?;
        let (root, whole_text_sha256) = self.import_root(&revision, reader, cancelled)?;
        revision.root = root;
        revision.validate()?;
        Ok(Imported {
            document: Document { revision },
            whole_text_sha256,
        })
    }
    /// Resolve a generated navigation coordinate to its actual prefix counts.
    /// Only a half-surrogate may round by one UTF16 unit; all other failures
    /// remain errors. This visits tree summaries and at most two bounded pieces.
    /// It does not certify a grapheme/word boundary or a complete paragraph.
    pub fn scalar_position(
        &mut self,
        document: &Document,
        expected: &Revision,
        offset: u64,
        forward: bool,
    ) -> Result<TextSummary> {
        let at = match self.byte_at_utf16(document, expected, offset) {
            Ok(at) => at,
            Err(Error::Invalid("half-surrogate offset")) => {
                let rounded = if forward {
                    offset.checked_add(1).ok_or(Error::Invalid("position overflow"))?
                } else {
                    offset.checked_sub(1).ok_or(Error::Invalid("position underflow"))?
                };
                self.byte_at_utf16(document, expected, rounded)?
            }
            Err(error) => return Err(error),
        };
        match &expected.root {
            Some(root) => self.prefix_summary(expected, root, at),
            None => Ok(TextSummary::EMPTY),
        }
    }

    /// Resolve an absolute UTF16 position by summaries plus at most one text
    /// page. Half-surrogate offsets are rejected, never rounded or normalized.
    pub fn byte_at_utf16(
        &mut self,
        document: &Document,
        expected: &Revision,
        offset: u64,
    ) -> Result<u64> {
        if expected != document.revision() {
            return Err(Error::Stale);
        }
        if offset > document.summary().utf16 {
            return Err(Error::Invalid("UTF16 offset"));
        }
        if offset == document.summary().utf16 {
            return Ok(document.summary().bytes);
        }
        let Some(mut tree) = expected.root.clone() else {
            return Ok(0);
        };
        let mut utf16 = offset;
        let mut bytes_before = 0;
        loop {
            match self.node(expected, &tree)? {
                Node::Branch(children) => {
                    let mut next = None;
                    for child in children {
                        if utf16 < child.summary.utf16 {
                            next = Some(child);
                            break;
                        }
                        utf16 -= child.summary.utf16;
                        bytes_before += child.summary.bytes;
                    }
                    tree = next.ok_or(Error::Invalid("UTF16 branch summary"))?;
                }
                Node::Leaf(pieces) => {
                    for piece in pieces {
                        if utf16 < piece.summary.utf16 {
                            let bytes = self.piece_text(expected, &piece)?;
                            let text = std::str::from_utf8(&bytes)
                                .map_err(|_| Error::Invalid("text page UTF8"))?
                                .get(piece.start as usize..piece.end as usize)
                                .ok_or(Error::Invalid("piece bounds"))?;
                            let mut units = 0;
                            for (at, character) in text.char_indices() {
                                if units == utf16 {
                                    return Ok(bytes_before + at as u64);
                                }
                                units += character.len_utf16() as u64;
                                if units > utf16 {
                                    return Err(Error::Invalid("half-surrogate offset"));
                                }
                            }
                            return Err(Error::Invalid("UTF16 piece summary"));
                        }
                        utf16 -= piece.summary.utf16;
                        bytes_before += piece.summary.bytes;
                    }
                    return Err(Error::Invalid("UTF16 leaf summary"));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
