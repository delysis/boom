//! Accurate source paragraph boundaries. LF/hash counts keep their old meaning.
use super::*;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ParagraphSummary {
    pub breaks: u64,
    pub paragraphs: u64,
    pub starts_lf: bool,
    pub ends_cr: bool,
}
impl ParagraphSummary {
    pub(crate) fn of(text: &str) -> Self {
        let mut breaks = 0;
        let mut paragraphs = 0;
        let mut previous_cr = false;
        for ch in text.chars() {
            if separator(ch) && !(ch == '\n' && previous_cr) {
                breaks += 1;
                if separates(ch, false) {
                    paragraphs += 1;
                }
            }
            previous_cr = ch == '\r';
        }
        Self {
            breaks,
            paragraphs,
            starts_lf: text.starts_with('\n'),
            ends_cr: text.ends_with('\r'),
        }
    }
    pub(crate) fn validate(self, text: TextSummary) -> Result<()> {
        if self.breaks < text.lf_count
            || self.paragraphs < text.lf_count
            || self.breaks > text.utf16
            || self.paragraphs > self.breaks
            || (self.starts_lf && text.lf_count == 0)
            || (self.ends_cr && self.breaks == 0)
            || (text.bytes == 0 && self != Self::default())
        {
            return Err(Error::Invalid("paragraph summary"));
        }
        Ok(())
    }
    fn count(self, include_line_endings: bool) -> u64 {
        if include_line_endings {
            self.breaks
        } else {
            self.paragraphs
        }
    }
    pub(crate) fn add(self, right: Self, left_bytes: u64, right_bytes: u64) -> Result<Self> {
        if left_bytes == 0 {
            return Ok(right);
        }
        if right_bytes == 0 {
            return Ok(self);
        }
        let count = self
            .breaks
            .checked_add(right.breaks)
            .and_then(|n| n.checked_sub(u64::from(self.ends_cr && right.starts_lf)))
            .ok_or(Error::Invalid("paragraph count overflow"))?;
        let paragraphs = self
            .paragraphs
            .checked_add(right.paragraphs)
            .and_then(|n| n.checked_sub(u64::from(self.ends_cr && right.starts_lf)))
            .ok_or(Error::Invalid("paragraph count overflow"))?;
        Ok(Self {
            breaks: count,
            paragraphs,
            starts_lf: self.starts_lf,
            ends_cr: right.ends_cr,
        })
    }
}
pub(super) fn separator(ch: char) -> bool {
    matches!(ch, '\r' | '\n' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
fn separates(ch: char, include_line_endings: bool) -> bool {
    separator(ch) && (include_line_endings || !matches!(ch, '\u{85}' | '\u{2028}'))
}
pub(super) fn scalar(ch: char) -> TextSummary {
    TextSummary {
        bytes: ch.len_utf8() as u64,
        utf16: ch.len_utf16() as u64,
        lf_count: u64::from(ch == '\n'),
    }
}
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphBounds {
    pub start: TextSummary,
    pub content_end: TextSummary,
    pub end: TextSummary,
    pub terminated: bool,
    pub lf_terminated: bool,
}
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ParagraphProgress {
    pub complete: bool,
    pub result: Option<ParagraphBounds>,
    pub buffered_bytes: usize,
    pub examined_bytes: u64,
}

impl Node {
    pub(super) fn paragraphs(&self) -> Result<Option<ParagraphSummary>> {
        let mut total = ParagraphSummary::default();
        let mut bytes = 0_u64;
        match self {
            Self::Leaf(pieces) => {
                for piece in pieces {
                    let Some(part) = piece.paragraphs else {
                        return Ok(None);
                    };
                    total = total.add(part, bytes, piece.summary.bytes)?;
                    bytes = bytes
                        .checked_add(piece.summary.bytes)
                        .ok_or(Error::Invalid("paragraph extent"))?;
                }
            }
            Self::Branch(children) => {
                for child in children {
                    let Some(part) = child.paragraphs else {
                        return Ok(None);
                    };
                    total = total.add(part, bytes, child.summary.bytes)?;
                    bytes = bytes
                        .checked_add(child.summary.bytes)
                        .ok_or(Error::Invalid("paragraph extent"))?;
                }
            }
        }
        Ok(Some(total))
    }
}
impl<S: PageProvider> TextEngine<S> {
    fn paragraph_prefix(
        &mut self,
        revision: &Revision,
        tree: &TreeRef,
        at: u64,
    ) -> Result<Option<ParagraphSummary>> {
        if at == 0 {
            return Ok(Some(ParagraphSummary::default()));
        }
        if at > tree.summary.bytes {
            return Err(Error::Invalid("paragraph prefix extent"));
        }
        if at == tree.summary.bytes && tree.paragraphs.is_some() {
            return Ok(tree.paragraphs);
        }
        let node = self.node(revision, tree)?;
        if at == tree.summary.bytes {
            return node.paragraphs();
        }
        let mut total = ParagraphSummary::default();
        let mut bytes = 0_u64;
        match node {
            Node::Branch(children) => {
                for child in children {
                    let remaining = at - bytes;
                    let n = remaining.min(child.summary.bytes);
                    let Some(part) = self.paragraph_prefix(revision, &child, n)? else {
                        return Ok(None);
                    };
                    total = total.add(part, bytes, n)?;
                    bytes += n;
                    if bytes == at {
                        return Ok(Some(total));
                    }
                }
            }
            Node::Leaf(pieces) => {
                for piece in pieces {
                    let n = (at - bytes).min(piece.summary.bytes);
                    let part = if n == piece.summary.bytes {
                        let Some(part) = piece.paragraphs else {
                            return Ok(None);
                        };
                        part
                    } else {
                        let data = self.piece_text(revision, &piece)?;
                        let start = usize::try_from(piece.start)
                            .map_err(|_| Error::Invalid("paragraph start usize"))?;
                        let end = start
                            .checked_add(
                                usize::try_from(n)
                                    .map_err(|_| Error::Invalid("paragraph prefix usize"))?,
                            )
                            .ok_or(Error::Invalid("paragraph prefix overflow"))?;
                        let text = std::str::from_utf8(
                            data.get(start..end)
                                .ok_or(Error::Invalid("paragraph piece range"))?,
                        )
                        .map_err(|_| Error::Invalid("paragraph inside scalar"))?;
                        ParagraphSummary::of(text)
                    };
                    total = total.add(part, bytes, n)?;
                    bytes += n;
                    if bytes == at {
                        return Ok(Some(total));
                    }
                }
            }
        }
        Err(Error::Invalid("paragraph prefix summary"))
    }
    fn paragraph_separator(
        &mut self,
        revision: &Revision,
        mut ordinal: u64,
        include_line_endings: bool,
    ) -> Result<(TextSummary, TextSummary, bool)> {
        let mut tree = revision
            .root
            .clone()
            .ok_or(Error::Invalid("paragraph in empty source"))?;
        let mut before = TextSummary::EMPTY;
        let mut previous_cr = false;
        loop {
            match self.node(revision, &tree)? {
                Node::Branch(children) => {
                    let mut next = None;
                    for child in children {
                        let part = child
                            .paragraphs
                            .ok_or(Error::Invalid("paragraph aggregate absent"))?;
                        let count = part
                            .count(include_line_endings)
                            .checked_sub(u64::from(previous_cr && part.starts_lf))
                            .ok_or(Error::Invalid("paragraph CRLF count"))?;
                        if ordinal < count {
                            next = Some(child);
                            break;
                        }
                        ordinal -= count;
                        before = before.checked_add(child.summary)?;
                        previous_cr = part.ends_cr;
                    }
                    tree = next.ok_or(Error::Invalid("paragraph branch ordinal"))?;
                }
                Node::Leaf(pieces) => {
                    for piece in pieces {
                        let part = piece
                            .paragraphs
                            .ok_or(Error::Invalid("paragraph aggregate absent"))?;
                        let count = part
                            .count(include_line_endings)
                            .checked_sub(u64::from(previous_cr && part.starts_lf))
                            .ok_or(Error::Invalid("paragraph CRLF count"))?;
                        if ordinal >= count {
                            ordinal -= count;
                            before = before.checked_add(piece.summary)?;
                            previous_cr = part.ends_cr;
                            continue;
                        }
                        let data = self.piece_text(revision, &piece)?;
                        let text = std::str::from_utf8(
                            data.get(
                                usize::try_from(piece.start)
                                    .map_err(|_| Error::Invalid("paragraph usize"))?
                                    ..usize::try_from(piece.end)
                                        .map_err(|_| Error::Invalid("paragraph usize"))?,
                            )
                            .ok_or(Error::Invalid("paragraph range"))?,
                        )
                        .map_err(|_| Error::Invalid("paragraph UTF8"))?;
                        let mut point = before;
                        for ch in text.chars() {
                            if separates(ch, include_line_endings) && !(ch == '\n' && previous_cr) {
                                if ordinal == 0 {
                                    let mut end = point.checked_add(scalar(ch))?;
                                    let mut lf = ch == '\n';
                                    if ch == '\r' && end.bytes < revision.summary().bytes {
                                        let next = self.source_piece(revision, end.bytes)?;
                                        let local = usize::try_from(end.bytes - next.before.bytes)
                                            .map_err(|_| Error::Invalid("CRLF usize"))?;
                                        if next
                                            .text()?
                                            .get(local..)
                                            .is_some_and(|t| t.starts_with('\n'))
                                        {
                                            end = end.checked_add(TextSummary::of("\n"))?;
                                            lf = true;
                                        }
                                    }
                                    return Ok((point, end, lf));
                                }
                                ordinal -= 1;
                            }
                            previous_cr = ch == '\r';
                            point = point.checked_add(scalar(ch))?;
                        }
                        return Err(Error::Invalid("paragraph text aggregate"));
                    }
                    return Err(Error::Invalid("paragraph leaf ordinal"));
                }
            }
        }
    }
    pub(super) fn paragraph_bounds_fast(
        &mut self,
        revision: &Revision,
        origin: TextSummary,
        include_line_endings: bool,
    ) -> Result<Option<ParagraphBounds>> {
        let Some(root) = &revision.root else {
            return Ok(Some(ParagraphBounds {
                start: TextSummary::EMPTY,
                content_end: TextSummary::EMPTY,
                end: TextSummary::EMPTY,
                terminated: false,
                lf_terminated: false,
            }));
        };
        // The public host may omit the optional root aggregate. The actual
        // authenticated root node still carries its children's aggregates.
        let Some(total) = self.node(revision, root)?.paragraphs()? else {
            return Ok(None);
        };
        let Some(prefix) = self.paragraph_prefix(revision, root, origin.bytes)? else {
            return Ok(None);
        };
        let mut completed = prefix.count(include_line_endings);
        if prefix.ends_cr && origin.bytes < revision.summary().bytes {
            let next = self.source_piece(revision, origin.bytes)?;
            let local = usize::try_from(origin.bytes - next.before.bytes)
                .map_err(|_| Error::Invalid("CRLF usize"))?;
            if next
                .text()?
                .get(local..)
                .is_some_and(|s| s.starts_with('\n'))
            {
                completed = completed
                    .checked_sub(1)
                    .ok_or(Error::Invalid("CRLF prefix count"))?;
            }
        }
        let start = if completed == 0 {
            TextSummary::EMPTY
        } else {
            self.paragraph_separator(revision, completed - 1, include_line_endings)?
                .1
        };
        if completed == total.count(include_line_endings) {
            return Ok(Some(ParagraphBounds {
                start,
                content_end: revision.summary(),
                end: revision.summary(),
                terminated: false,
                lf_terminated: false,
            }));
        }
        let (content_end, end, lf_terminated) =
            self.paragraph_separator(revision, completed, include_line_endings)?;
        Ok(Some(ParagraphBounds {
            start,
            content_end,
            end,
            terminated: true,
            lf_terminated,
        }))
    }
}

pub(super) struct ParagraphState {
    pub(super) revision: Revision,
    logical: Option<LogicalSnapshot>,
    origin: TextSummary,
    include_line_endings: bool,
    at: TextSummary,
    start: TextSummary,
    pending_cr: Option<TextSummary>,
    piece: Option<SourcePiece>,
    pub(super) ready: Option<ParagraphBounds>,
    examined: u64,
}
impl ParagraphState {
    pub(super) fn new<S: PageProvider>(
        engine: &mut TextEngine<S>,
        revision: Revision,
        utf16: u64,
        include_line_endings: bool,
    ) -> Result<Self> {
        let doc = engine.open(revision)?;
        let revision = doc.revision.clone();
        let byte = engine.byte_at_utf16(&doc, &revision, utf16)?;
        let origin = engine.byte_position(&doc, &revision, byte)?;
        let ready = engine.paragraph_bounds_fast(&revision, origin, include_line_endings)?;
        let at = if ready.is_some() {
            origin
        } else {
            engine.line_bounds(&doc, &revision, utf16)?.start
        };
        Ok(Self {
            logical: None,
            revision,
            origin,
            include_line_endings,
            at,
            start: at,
            pending_cr: None,
            piece: None,
            ready,
            examined: 0,
        })
    }
    pub(super) fn logical<S: PageProvider>(
        engine: &mut TextEngine<S>,
        snapshot: LogicalSnapshot,
        utf16: u64,
        include_line_endings: bool,
    ) -> Result<Self> {
        let origin = engine.logical_position(&snapshot, utf16, false)?.point();
        let ready = engine.logical_paragraph_fast(&snapshot, origin, include_line_endings)?;
        let at = if ready.is_some() {
            origin
        } else {
            engine.logical_lf_line_start(&snapshot, origin)?
        };
        Ok(Self {
            revision: snapshot.origin().clone(),
            logical: Some(snapshot),
            origin,
            include_line_endings,
            at,
            start: at,
            pending_cr: None,
            piece: None,
            ready,
            examined: 0,
        })
    }
    pub(super) fn progress(&self) -> ParagraphProgress {
        ParagraphProgress {
            complete: self.ready.is_some(),
            result: self.ready,
            buffered_bytes: self.piece.as_ref().map_or(0, |p| p.bytes.len()),
            examined_bytes: self.examined,
        }
    }
    fn found(&mut self, content_end: TextSummary, end: TextSummary, lf: bool) {
        if self.origin.bytes < end.bytes {
            self.ready = Some(ParagraphBounds {
                start: self.start,
                content_end,
                end,
                terminated: true,
                lf_terminated: lf,
            });
        } else {
            self.start = end;
        }
    }
    pub(super) fn step<S: PageProvider>(
        &mut self,
        engine: &mut TextEngine<S>,
    ) -> Result<ParagraphProgress> {
        if self.ready.is_some() {
            return Ok(self.progress());
        }
        if self.at.bytes
            == self
                .logical
                .as_ref()
                .map_or_else(|| self.revision.summary(), LogicalSnapshot::summary)
                .bytes
        {
            if let Some(cr) = self.pending_cr.take() {
                self.found(cr, self.at, false);
            }
            if self.ready.is_none() {
                self.ready = Some(ParagraphBounds {
                    start: self.start,
                    content_end: self.at,
                    end: self.at,
                    terminated: false,
                    lf_terminated: false,
                });
            }
        } else if self.piece.is_none() {
            self.piece = Some(if let Some(logical) = &self.logical {
                engine.logical_source_piece(logical, self.at.bytes)?
            } else {
                engine.source_piece(&self.revision, self.at.bytes)?
            });
        } else {
            let piece = self
                .piece
                .take()
                .ok_or(Error::Invalid("paragraph piece lost"))?;
            let local = usize::try_from(self.at.bytes - piece.before.bytes)
                .map_err(|_| Error::Invalid("paragraph cursor usize"))?;
            let text = piece
                .text()?
                .get(local..)
                .ok_or(Error::Invalid("paragraph scalar origin"))?;
            self.examined = self
                .examined
                .checked_add(
                    u64::try_from(text.len()).map_err(|_| Error::Invalid("paragraph bytes u64"))?,
                )
                .ok_or(Error::Invalid("paragraph examined overflow"))?;
            for ch in text.chars() {
                if let Some(cr) = self.pending_cr.take() {
                    if ch == '\n' {
                        self.at = self.at.checked_add(scalar(ch))?;
                        self.found(cr, self.at, true);
                        if self.ready.is_some() {
                            break;
                        } else {
                            continue;
                        }
                    }
                    self.found(cr, self.at, false);
                    if self.ready.is_some() {
                        break;
                    }
                }
                let before = self.at;
                self.at = self.at.checked_add(scalar(ch))?;
                if ch == '\r' {
                    self.pending_cr = Some(before);
                } else if separates(ch, self.include_line_endings) {
                    self.found(before, self.at, ch == '\n');
                }
                if self.ready.is_some() {
                    break;
                }
            }
        }
        Ok(self.progress())
    }
}
