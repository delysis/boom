use super::*;
use bloom_text::{
    FileStorage, LogicalSnapshot, LogicalSource, MarkupIndex, MarkupIndexBuilder, MarkupMode,
    MarkupQuery, PageKind, PageLocator, PageProvider, PageRef, TextEngine,
};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

type TestResult = Result<(), Box<dyn std::error::Error>>;
type DestinationResult = Result<Option<(usize, std::ops::Range<u64>)>, Box<dyn std::error::Error>>;
fn destination_in_pieces(text: &str, quantum: usize) -> DestinationResult {
    use pulldown_cmark::paged::{DestinationStatus, LinkDestinationStream, PROBE_BYTES};
    assert!((4..=PROBE_BYTES).contains(&quantum));
    let mut scanner = LinkDestinationStream::new(32);
    let mut at = 0usize;
    loop {
        let mut end = (at + quantum).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let step = scanner.feed(&text[at..end], end == text.len(), &mut || false)?;
        assert!(step.consumed <= end - at);
        assert_eq!(scanner.retained_text_bytes(), 0);
        at += step.consumed;
        match step.status {
            DestinationStatus::Pending => {
                assert_eq!(at, end);
                assert!(end < text.len());
            }
            DestinationStatus::Matched => {
                return Ok(Some((
                    at,
                    scanner.raw_range().expect("matched raw destination"),
                )));
            }
            DestinationStatus::Rejected => return Ok(None),
        }
    }
}

#[test]
fn shared_raw_destination_chunks_preserve_actual_pinned_link_choices_and_endpoints() -> TestResult {
    let cases = [
        ("target) after", Some((6, 0..6))),
        ("<target> rest", Some((8, 1..7))),
        ("(a(b)c)) after", Some((7, 0..7))),
        (r"a\)b) after", Some((4, 0..4))),
        (r"<a\>b>after", Some((6, 1..5))),
        ("é🙂) after", Some((6, 0..6))),
        ("<a\nb>", None),
        ("<a<b>", None),
        ("<unclosed", None),
        ("a(b c)", None),
        ("a(b", None),
        ("a\\\nb", Some((2, 0..2))),
        ("", Some((0, 0..0))),
    ];
    for (raw, expected) in cases {
        for quantum in [4, 5, 7, pulldown_cmark::paged::PROBE_BYTES] {
            assert_eq!(
                destination_in_pieces(raw, quantum)?,
                expected,
                "raw={raw:?}, quantum={quantum}"
            );
        }
    }
    for (text, expected) in [
        ("[body](target)", Some(("target", ""))),
        ("[body](<a b> 'title')", Some(("a b", "title"))),
        (r"[body](a\)b)", Some(("a)b", ""))),
        (r"[body](<a\>b>)", Some(("a>b", ""))),
        ("[body](é🙂 \"title\")", Some(("é🙂", "title"))),
        ("[body](<a\nb>)", None),
        ("[body](a(b c))", None),
    ] {
        let links: Vec<_> = Parser::new(text)
            .into_offset_iter()
            .filter_map(|(event, range)| {
                if let Event::Start(Tag::Link {
                    dest_url, title, ..
                }) = event
                {
                    Some((dest_url.to_string(), title.to_string(), range))
                } else {
                    None
                }
            })
            .collect();
        if let Some((destination, title)) = expected {
            assert_eq!(
                links,
                vec![(destination.to_string(), title.to_string(), 0..text.len())]
            );
        } else {
            assert!(links.is_empty(), "actual parser must reject {text:?}");
        }
    }
    Ok(())
}

#[test]
fn actual_raw_destination_parenthesis_and_pointy_control_rules_remain_pinned() -> TestResult {
    let accepted = format!("{}é🙂{}) rest", "(".repeat(33), ")".repeat(33));
    let result =
        destination_in_pieces(&accepted, 4)?.expect("pinned check-before-increment admits depth33");
    assert_eq!(result.0, accepted.len() - ") rest".len());
    assert_eq!(result.1, 0..result.0 as u64);
    let refused = format!("{}x{})", "(".repeat(34), ")".repeat(34));
    assert!(destination_in_pieces(&refused, 5)?.is_none());
    let pointy = "<a\u{0}b\t\u{b}\u{c}🙂> trailing";
    let result =
        destination_in_pieces(pointy, 4)?.expect("only CR/LF/< reject the pinned angle production");
    assert_eq!(
        result.0,
        pointy.find("> trailing").expect("real closing delimiter") + 1
    );
    assert_eq!(result.1, 1..(result.0 - 1) as u64);
    assert!(destination_in_pieces("<a\rb>", 4)?.is_none());
    assert!(destination_in_pieces("<a\\\rb>", 4)?.is_none());
    assert_eq!(
        destination_in_pieces("bare\\", 4)?,
        Some((5, 0..5)),
        "a genuine EOF leaves a final unescaped slash literal"
    );
    Ok(())
}

#[test]
fn actual_multimegabyte_raw_destination_has_no_text_archive_and_requires_true_end_or_delimiter()
-> TestResult {
    use pulldown_cmark::paged::{
        DestinationStatus, InlineRunError, LinkDestinationStream, PROBE_BYTES,
    };
    let body = "é🙂".repeat(530_000);
    assert!(body.len() > 3 * 1024 * 1024);
    let raw = format!("<{body}>");
    let mut scanner = LinkDestinationStream::new(32);
    assert!(std::mem::size_of_val(&scanner) <= 128);
    let mut at = 0usize;
    let mut turns = 0usize;
    while at < raw.len() {
        let mut end = (at + PROBE_BYTES).min(raw.len());
        while !raw.is_char_boundary(end) {
            end -= 1;
        }
        let step = scanner.feed(&raw[at..end], false, &mut || false)?;
        assert_eq!(step.consumed, end - at);
        assert_eq!(scanner.retained_text_bytes(), 0);
        at = end;
        turns += 1;
        assert_eq!(
            step.status,
            if end == raw.len() {
                DestinationStatus::Matched
            } else {
                DestinationStatus::Pending
            }
        );
    }
    assert!(turns > 96);
    assert_eq!(scanner.raw_range(), Some(1..(raw.len() - 1) as u64));
    assert!(
        scanner.feed("", true, &mut || false).is_err(),
        "a consumed destination cannot be resumed"
    );
    // Test-only full pinned parser: this reaches the actual ordinary
    // scan_inline_link -> scan_link_dest caller over many real quanta.
    // The public2MiB Core entry limit and paged producer bounds stay intact.
    let document = format!("[body]({raw})");
    let mut links = 0usize;
    for (event, range) in Parser::new(&document).into_offset_iter() {
        if let Event::Start(Tag::Link {
            dest_url, title, ..
        }) = event
        {
            assert_eq!(dest_url.as_ref(), body.as_str());
            assert!(title.is_empty());
            assert_eq!(range, 0..document.len());
            links += 1;
        }
    }
    assert_eq!(links, 1);
    let mut bare = LinkDestinationStream::new(32);
    assert_eq!(
        bare.feed("target", false, &mut || false)?.status,
        DestinationStatus::Pending
    );
    assert!(
        bare.raw_range().is_none(),
        "a copied source edge cannot fabricate a bare destination endpoint"
    );
    assert_eq!(
        bare.feed("", true, &mut || false)?.status,
        DestinationStatus::Matched
    );
    assert_eq!(bare.raw_range(), Some(0..6));
    let mut cancelled = LinkDestinationStream::new(32);
    assert_eq!(
        cancelled.feed("<pending", false, &mut || false)?.status,
        DestinationStatus::Pending
    );
    let mut checks = 0usize;
    assert_eq!(
        cancelled.feed(&"x".repeat(PROBE_BYTES), false, &mut || {
            checks += 1;
            checks == 7
        }),
        Err(InlineRunError::Cancelled)
    );
    assert!(checks <= 7);
    assert!(cancelled.raw_range().is_none());
    assert!(cancelled.feed(">", true, &mut || false).is_err());
    Ok(())
}

type Row = (Uuid, Uuid, PageKind, Vec<u8>);
#[derive(Default)]
struct Rows {
    pages: BTreeMap<u64, Row>,
    text_reads: usize,
    text_read_pages: BTreeSet<u64>,
    carry_writes: usize,
    inline_reads: usize,
    opener_writes: usize,
    inline_style_writes: usize,
    code_reads: usize,
    code_writes: usize,
    index_write_bytes: usize,
}
#[derive(Clone)]
struct Pages {
    id: Uuid,
    rows: Arc<Mutex<Rows>>,
}
impl Pages {
    fn new() -> Self {
        Self {
            id: Uuid::new_v4(),
            rows: Arc::new(Mutex::new(Rows::default())),
        }
    }
}
impl PageProvider for Pages {
    fn read(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        page: &PageRef,
        bound: usize,
    ) -> bloom_text::Result<Vec<u8>> {
        let mut rows = self.rows.lock().expect("test rows");
        let row = rows
            .pages
            .get(&page.locator.offset)
            .ok_or(bloom_text::Error::Invalid("test missing page"))?;
        if page.locator.store_id != self.id
            || row.0 != owner
            || row.1 != document
            || row.2 != kind
            || row.3.len() > bound
        {
            return Err(bloom_text::Error::Invalid("test page binding"));
        }
        let bytes = row.3.clone();
        if kind == PageKind::Text {
            rows.text_reads += 1;
            rows.text_read_pages.insert(page.locator.offset);
        }
        if kind == PageKind::Index
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
        {
            if value["node"]["kind"].as_str() == Some("inline_openers") {
                rows.inline_reads += 1;
            }
            if matches!(
                value["node"]["kind"].as_str(),
                Some("code_runs" | "code_branch")
            ) {
                rows.code_reads += 1;
            }
        }
        Ok(bytes)
    }
    fn write_new(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        bytes: &[u8],
    ) -> bloom_text::Result<PageLocator> {
        let mut rows = self.rows.lock().expect("test rows");
        let offset = (rows.pages.len() as u64)
            .checked_mul(65_600)
            .ok_or(bloom_text::Error::Invalid("test offset"))?;
        if kind == PageKind::Index {
            rows.index_write_bytes = rows
                .index_write_bytes
                .checked_add(bytes.len())
                .expect("fixture derived bytes");
            if let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) {
                if matches!(
                    value["node"]["kind"].as_str(),
                    Some("containers" | "container_branch")
                ) {
                    rows.carry_writes += 1;
                }
                match value["node"]["kind"].as_str() {
                    Some("inline_openers") => rows.opener_writes += 1,
                    Some("inline_styles" | "inline_branch") => rows.inline_style_writes += 1,
                    Some("code_runs" | "code_branch") => rows.code_writes += 1,
                    _ => (),
                }
            }
        }
        rows.pages
            .insert(offset, (owner, document, kind, bytes.to_vec()));
        Ok(PageLocator {
            storage: FileStorage::V1,
            store_id: self.id,
            offset,
            bytes: u32::try_from(bytes.len())
                .map_err(|_| bloom_text::Error::Invalid("test page size"))?,
        })
    }
}
fn source(
    text: &str,
) -> Result<(TextEngine<Pages>, LogicalSource, Pages), Box<dyn std::error::Error>> {
    let pages = Pages::new();
    let mut engine = TextEngine::with_cache_budget(pages.clone(), 0);
    let imported = engine.import_utf8(
        Uuid::new_v4(),
        Uuid::new_v4(),
        &mut text.as_bytes(),
        &mut || false,
    )?;
    let source = LogicalSource::new(imported.document.revision().clone())?;
    Ok((engine, source, pages))
}
fn index(
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    mode: MarkupMode,
) -> Result<(Arc<MarkupIndex>, bloom_text::MarkupProgress), Box<dyn std::error::Error>> {
    let mut build = MarkupIndexBuilder::new(engine, snapshot.clone(), mode)?;
    let mut progress = build.progress();
    for _ in 0..4096 {
        if progress.complete {
            return Ok((build.finish()?, progress));
        }
        progress = build.step(engine, &mut || false)?;
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
    }
    panic!(
        "bounded fixture indexing did not finish: mode={mode:?}, source_bytes={}, indexed_bytes={}, buffered_bytes={}, reused_bytes={}, incomplete={}",
        snapshot.summary().bytes,
        progress.indexed_bytes,
        progress.buffered_bytes,
        progress.reused_bytes,
        progress.incomplete_block
    )
}
fn assert_logical_source_bytes(
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    expected: &str,
) -> TestResult {
    assert_eq!(snapshot.summary().bytes, expected.len() as u64);
    let mut at = 0usize;
    while at < expected.len() {
        let mut end = (at + 64 * 1024).min(expected.len());
        while !expected.is_char_boundary(end) {
            end -= 1;
        }
        assert!(at < end);
        let actual = engine.logical_read_range(snapshot, at as u64..end as u64, &mut || false)?;
        assert_eq!(
            actual.as_slice(),
            &expected.as_bytes()[at..end],
            "exact source bytes {at}..{end}"
        );
        at = end;
    }
    assert_eq!(at, expected.len());
    Ok(())
}
fn context_with_progress(
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    index: Arc<MarkupIndex>,
    anchor: u64,
    budget: usize,
) -> Result<
    (
        bloom_text::MarkupContext,
        bloom_text::MarkupQueryProgress,
        usize,
    ),
    Box<dyn std::error::Error>,
> {
    let window = engine.logical_window(snapshot, anchor, budget, &mut || false)?;
    let mut query = MarkupQuery::new(&window, index)?;
    let mut retained_peak = 0;
    for _ in 0..8192 {
        let progress = query.step(engine, &mut || false)?;
        retained_peak = retained_peak.max(progress.retained_reference_bytes);
        assert!(progress.buffered_bytes <= 10 * pulldown_cmark::paged::PROBE_BYTES + 24 * 1024);
        if progress.complete {
            return Ok((query.finish()?, progress, retained_peak));
        }
    }
    panic!("bounded fixture query did not finish")
}
fn context(
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    index: Arc<MarkupIndex>,
    anchor: u64,
    budget: usize,
) -> Result<bloom_text::MarkupContext, Box<dyn std::error::Error>> {
    Ok(context_with_progress(engine, snapshot, index, anchor, budget)?.0)
}
fn coverage(spans: Vec<Span>) -> Vec<(&'static str, u8, usize, usize)> {
    let mut spans: Vec<_> = spans
        .into_iter()
        .filter(|span| span.length != 0 && span.kind != "literal")
        .map(|span| {
            (
                span.kind,
                span.level,
                span.location,
                span.location + span.length,
            )
        })
        .collect();
    spans.sort_unstable();
    let mut result: Vec<(&'static str, u8, usize, usize)> = Vec::new();
    for span in spans {
        if let Some(last) = result.last_mut()
            && (last.0, last.1) == (span.0, span.1)
            && span.2 <= last.3
        {
            last.3 = last.3.max(span.3);
        } else {
            result.push(span);
        }
    }
    result
}
fn clipped(spans: &[Span], first: usize, last: usize) -> Vec<Span> {
    spans
        .iter()
        .filter_map(|span| {
            let a = span.location.max(first);
            let b = (span.location + span.length).min(last);
            (a < b).then_some(Span {
                kind: span.kind,
                level: span.level,
                location: a - first,
                length: b.saturating_sub(a),
            })
        })
        .collect()
}
fn assert_oracle(
    text: &str,
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    anchor: u64,
    budget: usize,
) -> TestResult {
    let (style, _) = index(engine, snapshot, MarkupMode::Style)?;
    let (media, _) = index(engine, snapshot, MarkupMode::Media)?;
    assert!(style.complete() && media.complete());
    let style = context(engine, snapshot, style, anchor, budget)?;
    let media = context(engine, snapshot, media, anchor, budget)?;
    assert!(style.complete_blocks && style.reference_budget_proven);
    assert!(media.complete_blocks && media.reference_budget_proven);
    let first = usize::try_from(style.window_start.utf16)?;
    let last = usize::try_from(style.window_end.utf16)?;
    assert_eq!(
        coverage(paged_spans(&style)?),
        coverage(clipped(&spans(text)?, first, last))
    );
    let expected: Vec<_> = media_spans(text)?
        .into_iter()
        .filter_map(|span| {
            (span.location >= first && span.location + span.length <= last).then_some(MediaSpan {
                id: span.id,
                location: span.location.saturating_sub(first),
                length: span.length,
            })
        })
        .collect();
    assert_eq!(paged_media_spans(&media)?, expected);
    Ok(())
}

// Test-only large-source differential: the independent full pinned parser is
// intentionally allowed a complete fixture String. Public legacy entry limits
// and the paged producer's input/page bounds are unchanged.
fn assert_large_pinned_parser_oracle(
    text: &str,
    engine: &mut TextEngine<Pages>,
    snapshot: &LogicalSnapshot,
    anchor: u64,
    budget: usize,
) -> TestResult {
    let (style, _) = index(engine, snapshot, MarkupMode::Style)?;
    let (media, _) = index(engine, snapshot, MarkupMode::Media)?;
    assert!(style.complete() && media.complete());
    let style = context(engine, snapshot, style, anchor, budget)?;
    let media = context(engine, snapshot, media, anchor, budget)?;
    assert!(style.complete_blocks && style.reference_budget_proven);
    assert!(media.complete_blocks && media.reference_budget_proven);
    let first = usize::try_from(style.window_start.utf16)?;
    let last = usize::try_from(style.window_end.utf16)?;
    assert_eq!(
        coverage(paged_spans(&style)?),
        coverage(clipped(
            &spans_from_parser(text, Parser::new_ext(text, MarkupMode::Style.options()))?,
            first,
            last
        ))
    );
    let expected: Vec<_> = media_from_parser(text, Parser::new(text))?
        .into_iter()
        .filter_map(|span| {
            (span.location >= first && span.location + span.length <= last).then_some(MediaSpan {
                id: span.id,
                location: span.location.saturating_sub(first),
                length: span.length,
            })
        })
        .collect();
    assert_eq!(paged_media_spans(&media)?, expected);
    Ok(())
}

#[test]
fn paged_windows_match_existing_parser_at_every_unicode_scalar_boundary() -> TestResult {
    let text = concat!(
        "# Café 🙂\r\n\r\n**strong *inner*** ~~strike~~ `**literal**`\r\n\r\n",
        "> quote **bold**\r\n> - [x] list\r\n\r\n",
        "left | right\r\n--- | ---\r\n🙂 | text\r\n\r\n",
        "<div>\r\n**html literal**\r\n</div>\r\n\r\n",
        "[file][遠 方]\r\n\r\n[遠 方]: boom-attachment:884646c1-14b4-490d-be8c-8953af793315 \"title\"\r\n",
    );
    let (mut engine, mut source, _) = source(text)?;
    let snapshot = source.capture_for_publication()?;
    let mut anchor = 0;
    for character in text.chars() {
        assert_oracle(text, &mut engine, &snapshot, anchor, 29)?;
        anchor += character.len_utf16() as u64;
    }
    assert_oracle(text, &mut engine, &snapshot, anchor, 29)
}

#[test]
fn remote_fence_and_first_normalized_definition_override_local_duplicates() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let later = "adfcd7f6-e0c9-4d06-a75c-f64794d7760b";
    let prefix = format!("[CaSé label]: boom-attachment:{id}\n\n");
    let mut text = prefix + &"plain paragraph\n\n".repeat(4000);
    text.push_str("``` rust\r\n");
    text.push_str(&format!("# false [x](boom-attachment:{later}) **false**\r\n").repeat(3000));
    text.push_str("   ````  \r\n\n");
    let target = text.len();
    text.push_str(&format!(
        "[real][casé\tlabel]\n\n[casé label]: boom-attachment:{later}\n\n# real\n"
    ));
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let inside = text.find("# false").expect("literal source");
    assert_oracle(
        &text,
        &mut engine,
        &snapshot,
        text[..inside].encode_utf16().count() as u64,
        512,
    )?;
    assert_oracle(
        &text,
        &mut engine,
        &snapshot,
        text[..target].encode_utf16().count() as u64,
        512,
    )?;
    let (media, _) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    let view = context(
        &mut engine,
        &snapshot,
        media,
        text[..target].encode_utf16().count() as u64,
        512,
    )?;
    assert_eq!(
        paged_media_spans(&view)?
            .first()
            .map(|span| span.id.to_string()),
        Some(id.into())
    );
    Ok(())
}

#[test]
fn forward_definition_requires_global_search_and_ignores_fenced_fake_definition() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let text = format!(
        "[first][遠方]\n\n```\n[遠方]: boom-attachment:adfcd7f6-e0c9-4d06-a75c-f64794d7760b\n```\n\n{}[遠方]: boom-attachment:{id}\n",
        "plain\n\n".repeat(12_000)
    );
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    assert_oracle(&text, &mut engine, &snapshot, 0, 64)?;
    let (media, _) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    let view = context(&mut engine, &snapshot, media, 0, 64)?;
    assert_eq!(
        paged_media_spans(&view)?
            .first()
            .map(|span| span.id.to_string()),
        Some(id.into())
    );
    Ok(())
}

#[test]
fn one_word_edit_reuses_immutable_far_pages_and_undo_reuses_exact_index() -> TestResult {
    let mut text = "ordinary short prose\n\n".repeat(45_000);
    let (mut engine, mut source, pages) = source(&text)?;
    let before = source.capture_for_publication()?;
    let (original, _) = index(&mut engine, &before, MarkupMode::Style)?;
    let at = text.len() / 2;
    let view = engine.logical_window(&before, at as u64, 16_384, &mut || false)?;
    let local = usize::try_from(at as u64 - view.start().bytes)?;
    source.replace_window(&view, local..local, "**edit🙂**")?;
    text.insert_str(at, "**edit🙂**");
    let after = source.capture_for_publication()?;
    pages.rows.lock().expect("test rows").text_reads = 0;
    let (edited, progress) = index(&mut engine, &after, MarkupMode::Style)?;
    assert!(edited.complete());
    assert!(
        progress.reused_bytes
            > after.summary().bytes - 3 * pulldown_cmark::paged::PROBE_BYTES as u64
    );
    assert!(pages.rows.lock().expect("test rows").text_reads < 64);
    assert_oracle(&text, &mut engine, &after, at as u64, 512)?;
    source.restore(&before)?;
    let reads = engine.stats().page_reads;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&original, &restored));
    assert_eq!(engine.stats().page_reads, reads);
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn changed_remote_definition_reprojects_actual_window_and_old_context_cannot_rebind() -> TestResult
{
    let old_id = "884646c1-14b4-490d-be8c-8953af793315";
    let new_id = "adfcd7f6-e0c9-4d06-a75c-f64794d7760b";
    let mut text = format!(
        "[x]: boom-attachment:{old_id}\n\n{}[visible][x]\n",
        "plain\n\n".repeat(10_000)
    );
    let (mut engine, mut source, _) = source(&text)?;
    let before = source.capture_for_publication()?;
    let (original, _) = index(&mut engine, &before, MarkupMode::Media)?;
    let first = text.find(old_id).expect("actual definition");
    let view = engine.logical_window(&before, first as u64, 512, &mut || false)?;
    let local = first - usize::try_from(view.start().bytes)?;
    source.replace_window(&view, local..local + old_id.len(), new_id)?;
    text.replace_range(first..first + old_id.len(), new_id);
    let after = source.capture_for_publication()?;
    let (updated, _) = index(&mut engine, &after, MarkupMode::Media)?;
    let tail = context(&mut engine, &after, updated, after.summary().utf16, 128)?;
    assert_eq!(
        paged_media_spans(&tail)?
            .first()
            .map(|span| span.id.to_string()),
        Some(new_id.into())
    );
    let new_window = engine.logical_window(&after, after.summary().utf16, 128, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&new_window, original),
        Err(bloom_text::Error::Stale)
    ));
    assert_oracle(&text, &mut engine, &after, after.summary().utf16, 128)
}

#[test]
fn corrupt_derived_page_refuses_without_changing_source_and_cancel_does_not_adopt() -> TestResult {
    let text = "# heading\n\n**text**\n";
    let (mut engine, mut source, pages) = source(text)?;
    let snapshot = source.capture_for_publication()?;
    let (index, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    let window = engine.logical_window(&snapshot, 0, 128, &mut || false)?;
    for row in pages.rows.lock().expect("test rows").pages.values_mut() {
        if row.2 == PageKind::Index && row.3.windows(6).any(|bytes| bytes == b"\"mode\"") {
            row.3[0] ^= 1;
        }
    }
    let mut query = MarkupQuery::new(&window, index)?;
    assert!(query.step(&mut engine, &mut || false).is_err());
    assert!(source.capture().same(&snapshot));
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Media)?;
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    assert!(source.capture().same(&snapshot));
    assert_eq!(
        engine
            .logical_window(&snapshot, 0, 128, &mut || false)?
            .text(),
        text
    );
    Ok(())
}

#[test]
fn bounded_inline_media_completes_while_large_reference_and_dense_fuel_stay_explicitly_incomplete()
-> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let text = format!(
        "# known\n\n{}[late](boom-attachment:{id})",
        "x".repeat(3 * pulldown_cmark::paged::PROBE_BYTES)
    );
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (completed, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    assert!(completed.complete() && !progress.incomplete_block);
    let view = context(
        &mut engine,
        &snapshot,
        completed,
        snapshot.summary().utf16,
        256,
    )?;
    let actual = paged_media_spans(&view)?;
    assert_eq!(actual.len(), 1);
    assert_eq!(actual[0].id.to_string(), id);
    assert_oracle(&text, &mut engine, &snapshot, snapshot.summary().utf16, 256)?;
    // The old ordinary inline node above is now covered. Keep the original
    // incomplete-source oracle on an actually unresolved reference production;
    // no fake empty global definition map or raised fuel limit can satisfy it.
    let text = format!(
        "# known\n\n{}[late][remote]\n\n[remote]: boom-attachment:{id}\n",
        "x".repeat(3 * pulldown_cmark::paged::PROBE_BYTES)
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (partial, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    assert!(progress.incomplete_block && !partial.complete());
    let view = context(
        &mut engine,
        &snapshot,
        partial,
        snapshot.summary().utf16,
        256,
    )?;
    assert!(!view.complete_blocks);
    assert!(paged_media_spans(&view)?.is_empty());
    let text = format!(
        "{}\n\n[x]: https://example.com/{}\n",
        "[x] ".repeat(4000),
        "a".repeat(2000)
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (index, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(index.complete());
    let view = context(&mut engine, &snapshot, index, 0, 128)?;
    assert!(!view.reference_budget_proven);
    assert!(paged_spans(&view)?.is_empty());
    Ok(())
}

#[test]
fn fragment_events_borrow_global_destination_and_title_and_honor_cancellation() -> TestResult {
    use pulldown_cmark::{CowStr, Event, Parser, Tag};
    let destination = format!("https://example.com/{}", "é".repeat(1000));
    let title = "🙂 title".repeat(100);
    let definitions_source = format!("[x]: {destination} \"{title}\"\n");
    let definitions =
        pulldown_cmark::paged::probe_blocks(&definitions_source, Options::empty(), true)
            .expect("actual bounded first pass")
            .into_references();
    let original = definitions
        .get("x")
        .expect("actual parsed global definition");
    let text = "[x] [x] **text**";
    let parser = Parser::new(text).with_reference_definitions(definitions.borrowed());
    let mut links = 0;
    for event in parser {
        if let Event::Start(Tag::Link {
            dest_url, title, ..
        }) = event
        {
            assert!(matches!(&dest_url, CowStr::Borrowed(_)));
            assert_eq!(dest_url.as_bytes(), destination.as_bytes());
            assert_eq!(dest_url.as_ptr(), original.dest.as_ptr());
            assert_eq!(
                title.as_ptr(),
                original
                    .title
                    .as_ref()
                    .expect("actual parsed title")
                    .as_ptr()
            );
            links += 1;
        }
    }
    assert_eq!(links, 2);
    let parser = Parser::new_ext(text, MarkupMode::Style.options())
        .with_reference_definitions(definitions.borrowed());
    let mut checks = 0;
    assert!(
        spans_from_parser_cancelled(
            text,
            parser,
            &mut || {
                checks += 1;
                checks == 3
            },
            false
        )
        .is_err()
    );
    assert_eq!(checks, 3);
    assert_eq!(
        definitions
            .get("x")
            .expect("retained actual definition")
            .dest
            .as_bytes(),
        destination.as_bytes()
    );
    Ok(())
}

#[test]
fn long_quote_list_resumes_actual_container_spine_and_matches_whole_parser() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let mut text = format!("> [x]: boom-attachment:{id}\n> \n");
    for item in 0..2400 {
        text.push_str(&format!("> - **item {item}** [x]\n>   Plain continuation preserves café 🙂 and these authored words intact.\n> \n"));
    }
    text.push_str("\n# Outside [x]\n");
    assert!(text.len() > 6 * pulldown_cmark::paged::PROBE_BYTES);
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (style, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(style.complete() && !progress.incomplete_block);
    assert_eq!(progress.indexed_bytes, snapshot.summary().bytes);
    for anchor in [
        0,
        15_900,
        32_700,
        65_500,
        snapshot.summary().utf16 - 64,
        snapshot.summary().utf16,
    ] {
        assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
    }
    Ok(())
}

#[test]
fn changed_child_in_long_container_reuses_far_pages_and_undo_restores_exact_index() -> TestResult {
    let mut text = String::new();
    for item in 0..4000 {
        text.push_str(&format!("> - **item {item}**\n>   A bounded child has café 🙂 plus its original continuation.\n> \n"));
    }
    text.push_str("\nOutside.\n");
    let (mut engine, mut source, pages) = source(&text)?;
    let before = source.capture_for_publication()?;
    let (original, _) = index(&mut engine, &before, MarkupMode::Style)?;
    assert!(original.complete());
    let byte = text.find("item 3900").expect("actual distant child");
    let point = text[..byte].encode_utf16().count() as u64;
    let window = engine.logical_window(&before, point, 512, &mut || false)?;
    let local = byte - usize::try_from(window.start().bytes)?;
    source.replace_window(&window, local..local + 4, "edited")?;
    text.replace_range(byte..byte + 4, "edited");
    let after = source.capture_for_publication()?;
    pages.rows.lock().expect("test rows").text_reads = 0;
    let (updated, progress) = index(&mut engine, &after, MarkupMode::Style)?;
    assert!(updated.complete());
    assert!(
        progress.reused_bytes
            > after.summary().bytes - 4 * pulldown_cmark::paged::PROBE_BYTES as u64
    );
    assert!(pages.rows.lock().expect("test rows").text_reads < 128);
    assert_oracle(&text, &mut engine, &after, point, 512)?;
    source.restore(&before)?;
    let reads = engine.stats().page_reads;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &original));
    assert_eq!(engine.stats().page_reads, reads);
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn malformed_container_state_and_corrupt_carry_page_cannot_prove_a_window() -> TestResult {
    use pulldown_cmark::paged::BlockCarry;
    assert!(BlockCarry::from_checkpoint(&[[2, 2, 0, 0]], false, false).is_none());
    assert!(BlockCarry::from_checkpoint(&[[1, 1, 46, u64::MAX]], false, false).is_none());
    assert!(
        BlockCarry::from_checkpoint(&[[1, 1, 45, 0], [2, u64::MAX, 0, 0]], false, false).is_none()
    );
    let text = format!(
        "{}\nOutside.\n",
        "> - **item**\n>   original continuation with café 🙂 kept unchanged.\n> \n".repeat(1800)
    );
    let (mut engine, mut source, pages) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (index, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(index.complete());
    let mut damaged = false;
    let marker = b"\"kind\":\"containers\"";
    for row in pages.rows.lock().expect("test rows").pages.values_mut() {
        if row.2 == PageKind::Index && row.3.windows(marker.len()).any(|bytes| bytes == marker) {
            row.3[0] ^= 1;
            damaged = true;
        }
    }
    assert!(
        damaged,
        "The actual producer must have written a paged container carry."
    );
    let window = engine.logical_window(&snapshot, 65_500, 128, &mut || false)?;
    let mut query = MarkupQuery::new(&window, index)?;
    let mut refused = false;
    for _ in 0..8192 {
        match query.step(&mut engine, &mut || false) {
            Err(_) => {
                refused = true;
                break;
            }
            Ok(value) if value.complete => break,
            Ok(_) => (),
        }
    }
    assert!(refused);
    assert!(source.capture().same(&snapshot));
    let unchanged = engine.logical_window(&snapshot, 0, 128, &mut || false)?;
    assert_eq!(unchanged.start().bytes, 0);
    assert_eq!(
        unchanged.text(),
        &text[..usize::try_from(unchanged.local_summary().bytes)?]
    );
    Ok(())
}

#[test]
fn continuing_root_probe_keeps_actual_internal_restart_points_and_small_edit_reuse() -> TestResult {
    use pulldown_cmark::paged::{BlockCarry, probe_blocks, probe_continuing_blocks};
    let text =
        "first **paragraph**\n\n[x]: /original\n\nsecond *paragraph*\n\n> quoted\n\noutside\n\n";
    let original =
        probe_blocks(text, MarkupMode::Style.options(), true).expect("actual root first pass");
    let continued = probe_continuing_blocks(
        text,
        MarkupMode::Style.options(),
        true,
        &BlockCarry::default(),
    )
    .expect("same grammar with root carry");
    assert_eq!(continued.root_checkpoints(), original.root_checkpoints());
    for block in original.blocks() {
        assert!(continued.root_checkpoints().contains(&block.input_start));
    }
    assert!(
        continued
            .root_checkpoints()
            .contains(&text.find("[x]:").expect("real definition"))
    );
    let row = "ordinary **paragraph**\n\n";
    let mut text = row.repeat(6000);
    let at = 4500 * row.len() + 3;
    let (mut engine, mut source, _) = self::source(&text)?;
    let before = source.capture_for_publication()?;
    let (old, _) = index(&mut engine, &before, MarkupMode::Style)?;
    assert!(old.complete());
    let window = engine.logical_window(&before, at as u64, 512, &mut || false)?;
    let local = at - usize::try_from(window.start().bytes)?;
    source.replace_window(&window, local..local + 1, "X")?;
    text.replace_range(at..at + 1, "X");
    let after = source.capture_for_publication()?;
    let build = MarkupIndexBuilder::new(&mut engine, after.clone(), MarkupMode::Style)?;
    // The completed paragraph immediately before this edit is still a proved
    // restart. A segment-edge fallback could reread up to 32KiB here.
    assert!(build.progress().indexed_bytes >= (at - 2 * row.len()) as u64);
    drop(build);
    let (updated, progress) = index(&mut engine, &after, MarkupMode::Style)?;
    assert!(updated.complete());
    assert!(
        progress.reused_bytes
            > after.summary().bytes - 2 * pulldown_cmark::paged::PROBE_BYTES as u64
    );
    assert_oracle(&text, &mut engine, &after, at as u64, 512)
}

#[test]
fn deep_container_write_yields_each_page_and_cancelled_carry_never_adopts() -> TestResult {
    let markers = "> ".repeat(130);
    let mut text = String::new();
    for item in 0..300 {
        text.push_str(&format!("{markers}**child {item} café 🙂**\n{markers}\n"));
    }
    text.push_str("\nOutside.\n");
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let mut entered = false;
    for _ in 0..64 {
        let before = pages.rows.lock().expect("test rows").carry_writes;
        let progress = build.step(&mut engine, &mut || false)?;
        let after = pages.rows.lock().expect("test rows").carry_writes;
        assert!(after - before <= 1, "one real carry page per host turn");
        if after > before {
            assert!(!progress.complete);
            entered = true;
            break;
        }
    }
    assert!(entered, "actual deep carry entered its file-page writer");
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    drop(build);
    assert!(source.capture().same(&snapshot));
    let first = engine.logical_window(&snapshot, 0, 512, &mut || false)?;
    assert_eq!(
        first.text(),
        &text[..usize::try_from(first.local_summary().bytes)?]
    );
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let baseline = pages.rows.lock().expect("test rows").carry_writes;
    for _ in 0..4096 {
        if build.progress().complete {
            break;
        }
        let before = pages.rows.lock().expect("test rows").carry_writes;
        build.step(&mut engine, &mut || false)?;
        assert!(pages.rows.lock().expect("test rows").carry_writes - before <= 1);
    }
    assert!(build.progress().complete && !build.progress().incomplete_block);
    assert!(pages.rows.lock().expect("test rows").carry_writes - baseline >= 3);
    let index = build.finish()?;
    assert!(index.complete());
    assert_oracle(&text, &mut engine, &snapshot, 0, 512)?;
    assert_oracle(&text, &mut engine, &snapshot, snapshot.summary().utf16, 512)
}

#[test]
fn checked_reference_walk_cancels_inside_one_event_and_never_emits_partial_ast() -> TestResult {
    use pulldown_cmark::{BrokenLink, Event, Parser, Tag};
    use std::cell::Cell;
    let text = format!("prefix {} suffix", "[missing] ".repeat(512));
    let attempts = Cell::new(0usize);
    let mut broken = |_: BrokenLink<'_>| {
        attempts.set(attempts.get() + 1);
        None
    };
    let mut parser =
        Parser::new_with_broken_link_callback(&text, Options::empty(), Some(&mut broken))
            .into_offset_iter();
    assert!(matches!(
        parser.next_with_check(&mut || false)?,
        Some((Event::Start(Tag::Paragraph), _))
    ));
    assert!(matches!(
        parser.next_with_check(&mut || false)?,
        Some((Event::Text(_), _))
    ));
    let mut checks = 0;
    let refused = parser.next_with_check(&mut || {
        checks += 1;
        checks == 13
    });
    assert!(matches!(refused, Err(pulldown_cmark::paged::Cancelled)));
    assert_eq!(checks, 13);
    assert!(
        attempts.get() > 0 && attempts.get() < 512,
        "actual callbacks stopped inside the inline walk"
    );
    assert!(
        parser.next().is_none(),
        "a cancelled derived AST must never become successful partial output"
    );
    assert!(matches!(
        parser.next_with_check(&mut || false),
        Err(pulldown_cmark::paged::Cancelled)
    ));
    Ok(())
}

#[test]
fn checked_unmatched_code_scan_cancels_inside_delimiter_search() -> TestResult {
    use pulldown_cmark::{Event, Parser, Tag};
    let text = format!("prefix ``{} tail", "x *y* ".repeat(600));
    let mut parser = Parser::new(&text).into_offset_iter();
    assert!(matches!(
        parser.next_with_check(&mut || false)?,
        Some((Event::Start(Tag::Paragraph), _))
    ));
    assert!(matches!(
        parser.next_with_check(&mut || false)?,
        Some((Event::Text(_), _))
    ));
    let mut checks = 0;
    assert!(matches!(
        parser.next_with_check(&mut || {
            checks += 1;
            checks == 9
        }),
        Err(pulldown_cmark::paged::Cancelled)
    ));
    assert_eq!(checks, 9);
    assert!(parser.next().is_none());
    assert!(media_spans(&text)?.is_empty());
    assert!(spans(&text)?.iter().any(|span| span.kind == "emphasis"));
    Ok(())
}

#[test]
fn unfinished_paragraph_run_stream_preserves_pinned_flanks_and_exact_unicode_points() -> TestResult
{
    use pulldown_cmark::paged::{BlockCarry, InlineToken, begin_unfinished_paragraph};
    let text = "paragraph word_foo_ 🙂 **é** _🦊_ café~~x~~ end";
    let seed = begin_unfinished_paragraph(
        &text[..10],
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual first pass entered an unfinished paragraph");
    assert_eq!(seed.start(), 0);
    let mut stream = seed.run_stream();
    let mut tokens = Vec::new();
    let mut byte = 0;
    for value in text.chars() {
        let end = byte + value.len_utf8();
        let step = stream.feed(&text[byte..end], end == text.len(), &mut || false)?;
        assert_eq!(step.consumed, value.len_utf8());
        assert!(step.stopped.is_none());
        tokens.extend(step.tokens);
        byte = end;
        assert_eq!(stream.point().bytes, byte as u64);
        assert_eq!(
            stream.point().utf16,
            text[..byte].encode_utf16().count() as u64
        );
    }
    let end = stream.feed("", true, &mut || false)?;
    assert!(end.complete);
    tokens.extend(end.tokens);
    let mut actual = Vec::new();
    for token in tokens {
        if let InlineToken::Delimiter {
            start,
            end,
            character,
            count,
            can_open,
            can_close,
        } = token
        {
            assert_eq!(end.bytes - start.bytes, count);
            assert_eq!(end.utf16 - start.utf16, count);
            assert!(
                text[usize::try_from(start.bytes)?..usize::try_from(end.bytes)?]
                    .bytes()
                    .all(|byte| byte == character)
            );
            assert_eq!(
                start.utf16,
                text[..usize::try_from(start.bytes)?].encode_utf16().count() as u64
            );
            actual.push((character, count, can_open, can_close));
        }
    }
    // Includes the unmatched closing underscore in word_foo_, and the pinned
    // intraword two-tilde rule. Neighbors were actual scalars across every cut.
    assert_eq!(
        actual,
        vec![
            (b'_', 1, false, true),
            (b'*', 2, true, false),
            (b'*', 2, false, true),
            (b'_', 1, true, false),
            (b'_', 1, false, true),
            (b'~', 2, true, true),
            (b'~', 2, false, true),
        ]
    );
    let styled = spans(text)?;
    assert_eq!(
        styled.iter().filter(|span| span.kind == "strong").count(),
        1
    );
    assert_eq!(
        styled.iter().filter(|span| span.kind == "emphasis").count(),
        1
    );
    assert_eq!(
        styled.iter().filter(|span| span.kind == "strike").count(),
        1
    );
    Ok(())
}

#[test]
fn unfinished_paragraph_run_stream_bounds_long_run_and_yields_token_pages() -> TestResult {
    use pulldown_cmark::paged::{BlockCarry, InlineToken, PROBE_BYTES, begin_unfinished_paragraph};
    let prefix = "paragraph 🙂 ";
    let seed =
        begin_unfinished_paragraph(prefix, MarkupMode::Style.options(), &BlockCarry::default())
            .expect("actual paragraph seed");
    let mut stream = seed.run_stream();
    let step = stream.feed(prefix, false, &mut || false)?;
    assert_eq!(step.consumed, prefix.len());
    let chunk = "*".repeat(PROBE_BYTES);
    let mut tokens = Vec::new();
    for _ in 0..4 {
        let step = stream.feed(&chunk, false, &mut || false)?;
        assert_eq!(step.consumed, PROBE_BYTES);
        assert!(!step.complete && step.stopped.is_none());
        tokens.extend(step.tokens);
        assert_eq!(stream.retained_text_bytes(), 0);
        assert!(std::mem::size_of_val(&stream) < 512);
    }
    let step = stream.feed("x", true, &mut || false)?;
    assert!(step.complete);
    tokens.extend(step.tokens);
    assert_eq!(
        stream.point().bytes,
        prefix.len() as u64 + 4 * PROBE_BYTES as u64 + 1
    );
    assert_eq!(
        stream.point().utf16,
        prefix.encode_utf16().count() as u64 + 4 * PROBE_BYTES as u64 + 1
    );
    assert_eq!(
        tokens
            .iter()
            .filter_map(
                |token| if let InlineToken::Delimiter { count, .. } = token {
                    Some(*count)
                } else {
                    None
                }
            )
            .collect::<Vec<_>>(),
        vec![4 * PROBE_BYTES as u64]
    );
    let text = format!("paragraph {}end", "*a* ".repeat(2000));
    let mut stream = seed.run_stream();
    let mut consumed = 0;
    let mut entered_pages = 0;
    while consumed < text.len() {
        let step = stream.feed(&text[consumed..], true, &mut || false)?;
        assert!(step.tokens.len() <= 128 && step.consumed > 0);
        assert!(step.stopped.is_none());
        consumed += step.consumed;
        entered_pages += 1;
    }
    let end = stream.feed("", true, &mut || false)?;
    assert!(end.complete && end.tokens.len() <= 128);
    assert!(entered_pages > 1);
    assert_eq!(stream.point().bytes, text.len() as u64);
    Ok(())
}

#[test]
fn unfinished_paragraph_run_stream_does_not_claim_other_inline_or_block_completion() -> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, InlineRunError, InlineStop, PROBE_BYTES, begin_unfinished_paragraph,
    };
    let seed = begin_unfinished_paragraph(
        "paragraph ",
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual paragraph seed");
    for (text, kind, at) in [
        ("paragraph [x]", InlineStop::OtherInlinePass, 10),
        ("paragraph `x`", InlineStop::OtherInlinePass, 10),
        ("paragraph\nnext", InlineStop::ParagraphBoundary, 9),
    ] {
        let mut stream = seed.run_stream();
        let step = stream.feed(text, true, &mut || false)?;
        assert_eq!(step.stopped, Some(kind));
        assert!(!step.complete);
        assert_eq!(step.consumed, at);
        assert_eq!(stream.point().bytes, at as u64);
    }
    let mut stream = seed.run_stream();
    assert!(
        stream
            .feed("paragraph \\[x]", true, &mut || false)?
            .complete
    );
    let mut stream = seed.run_stream();
    let mut checks = 0;
    assert!(matches!(
        stream.feed(&"x".repeat(PROBE_BYTES), false, &mut || {
            checks += 1;
            checks == 4
        }),
        Err(InlineRunError::Cancelled)
    ));
    assert_eq!(checks, 4);
    assert!(matches!(
        stream.feed("", true, &mut || false),
        Err(InlineRunError::Invalid(_))
    ));
    Ok(())
}

#[test]
fn grouped_emphasis_candidate_matches_actual_pinned_style_and_unicode_ranges() -> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, InlineStyleKind, InlineToken, OpenDelimiter, begin_unfinished_paragraph,
        prepare_delimiter_match,
    };
    for text in [
        "paragraph ***é🙂***",
        "paragraph *****é🙂**",
        "paragraph ~~é🙂~~",
        "paragraph ~é🙂~",
    ] {
        let seed = begin_unfinished_paragraph(
            &text[..10],
            MarkupMode::Style.options(),
            &BlockCarry::default(),
        )
        .expect("actual paragraph input");
        let mut stream = seed.run_stream();
        let mut tokens = stream.feed(text, true, &mut || false)?.tokens;
        tokens.extend(stream.feed("", true, &mut || false)?.tokens);
        let delimiters: Vec<_> = tokens
            .into_iter()
            .filter(|token| matches!(token, InlineToken::Delimiter { .. }))
            .collect();
        assert_eq!(delimiters.len(), 2);
        let open = OpenDelimiter::from_token(delimiters[0])?;
        let InlineToken::Delimiter { count, .. } = delimiters[1] else {
            unreachable!();
        };
        let plan =
            prepare_delimiter_match(open, delimiters[1], count, MarkupMode::Style.options())?
                .expect("actual chosen pair");
        assert!(plan.styles.len() <= 4);
        let actual = plan
            .styles
            .into_iter()
            .map(|span| Span {
                kind: match span.kind {
                    InlineStyleKind::Strong => "strong",
                    InlineStyleKind::Emphasis => "emphasis",
                    InlineStyleKind::Strike => "strike",
                    InlineStyleKind::Syntax => "syntax",
                    InlineStyleKind::Code => "code",
                    InlineStyleKind::Link => "link",
                },
                location: usize::try_from(span.start.utf16).expect("fixture extent"),
                length: usize::try_from(span.end.utf16 - span.start.utf16).expect("fixture extent"),
                level: 0,
            })
            .collect();
        assert_eq!(coverage(actual), coverage(spans(text)?));
        assert_eq!(
            plan.opener.map(|value| value.remaining()),
            (text.contains("*****")).then_some(3)
        );
    }
    Ok(())
}

#[test]
fn grouped_emphasis_candidate_bounds_huge_match_and_rejects_corrupt_or_rule_three_pairs()
-> TestResult {
    use pulldown_cmark::paged::{
        InlinePoint, InlineRunError, InlineToken, OpenDelimiter, prepare_delimiter_match,
    };
    let count = 128 * 1024u64;
    let start = InlinePoint { bytes: 0, utf16: 0 };
    let end = InlinePoint {
        bytes: count,
        utf16: count,
    };
    let open = OpenDelimiter::from_token(InlineToken::Delimiter {
        start,
        end,
        character: b'*',
        count,
        can_open: true,
        can_close: false,
    })?;
    let closing = InlineToken::Delimiter {
        start: InlinePoint {
            bytes: count + 8,
            utf16: count + 5,
        },
        end: InlinePoint {
            bytes: 2 * count + 8,
            utf16: 2 * count + 5,
        },
        character: b'*',
        count,
        can_open: false,
        can_close: true,
    };
    let plan = prepare_delimiter_match(open, closing, count, MarkupMode::Style.options())?
        .expect("large actual pair data");
    assert_eq!(plan.consumed_closing, count);
    assert!(plan.opener.is_none());
    assert_eq!(
        plan.styles.len(),
        3,
        "one trait union and actual two syntax ranges, not O(run length) items"
    );
    assert!(matches!(
        OpenDelimiter::from_checkpoint([u64::MAX, 0, 1, 1, u64::from(b'*'), 0, 0]),
        Err(InlineRunError::Invalid(_))
    ));
    assert!(matches!(
        OpenDelimiter::from_checkpoint([0, 0, 2, 1, u64::from(b'*'), 0, 0]),
        Err(InlineRunError::Invalid(_))
    ));
    let open = OpenDelimiter::from_token(InlineToken::Delimiter {
        start,
        end: InlinePoint { bytes: 2, utf16: 2 },
        character: b'*',
        count: 2,
        can_open: true,
        can_close: true,
    })?;
    let closing = InlineToken::Delimiter {
        start: InlinePoint { bytes: 4, utf16: 4 },
        end: InlinePoint { bytes: 5, utf16: 5 },
        character: b'*',
        count: 1,
        can_open: true,
        can_close: true,
    };
    assert!(prepare_delimiter_match(open, closing, 1, MarkupMode::Style.options())?.is_none());
    // Original run length, rather than the leftover count, governs matching.
    let partial = OpenDelimiter::from_checkpoint([0, 0, 1, 3, u64::from(b'*'), 1, 0])?;
    assert!(prepare_delimiter_match(partial, closing, 1, MarkupMode::Style.options())?.is_some());
    assert!(matches!(
        prepare_delimiter_match(open, closing, 0, MarkupMode::Style.options()),
        Err(InlineRunError::Invalid(_))
    ));
    Ok(())
}

#[test]
fn completed_heading_styles_from_captured_prefix_with_actual_large_tail_unread() -> TestResult {
    let heading = "# **Café 🙂**\n\n";
    let text = format!(
        "{heading}```\n{}\n```\n",
        "ordinary untouched tail\n".repeat(190_000)
    );
    assert!(text.len() > 4 * 1024 * 1024);
    let (mut engine, mut source, pages) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let first_page = pages
        .rows
        .lock()
        .expect("rows")
        .pages
        .iter()
        .find_map(|(offset, row)| (row.2 == PageKind::Text).then_some(*offset))
        .expect("actual first text page");
    {
        let mut rows = pages.rows.lock().expect("rows");
        rows.text_reads = 0;
        rows.text_read_pages.clear();
    }
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let progress = build.step(&mut engine, &mut || false)?;
    assert!(!progress.complete && progress.indexed_bytes < snapshot.summary().bytes / 2);
    let prefix = build.captured_index();
    assert!(!prefix.complete(), "local proof is not global EOF");
    let view = context(&mut engine, &snapshot, prefix, 0, heading.len())?;
    assert!(view.complete_blocks && view.reference_budget_proven);
    assert_eq!(
        coverage(paged_spans(&view)?),
        coverage(clipped(
            &spans(heading)?,
            0,
            usize::try_from(view.window_end.utf16)?
        ))
    );
    // Independently enter the pinned whole-source parser, not the prefix index:
    // the first actual block and strong event retain the same source ranges.
    let mut whole = Parser::new_ext(&text, MarkupMode::Style.options()).into_offset_iter();
    assert!(matches!(
        whole.next(),
        Some((Event::Start(Tag::Heading { .. }), _))
    ));
    assert!(
        matches!(whole.next(), Some((Event::Start(Tag::Strong), range)) if &text[range.clone()] == "**Café 🙂**")
    );
    let rows = pages.rows.lock().expect("rows");
    assert_eq!(
        rows.text_read_pages,
        BTreeSet::from([first_page]),
        "the actual distant source pages remain unread"
    );
    drop(rows);
    // Stopping this cold operation keeps only a real proved prefix. A same-
    // source replacement query resumes it rather than scanning from root0.
    drop(build);
    let resumed = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    assert_eq!(resumed.progress().indexed_bytes, progress.indexed_bytes);
    assert_eq!(resumed.progress().reused_bytes, progress.indexed_bytes);
    Ok(())
}

#[test]
fn partial_absence_or_known_definition_never_forges_global_reference_fuel() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    for known_first in [false, true] {
        let definition = if known_first {
            format!("[remote]: boom-attachment:{id}\n\n")
        } else {
            String::new()
        };
        let head = format!("{definition}# **Ready 🙂**\n\n# [wait][remote]\n\n");
        let text = format!(
            "{head}```\n{}\n```\n[remote]: boom-attachment:{id}\n",
            "unread tail\n".repeat(390_000)
        );
        let (mut engine, mut source, pages) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
        let progress = build.step(&mut engine, &mut || false)?;
        assert!(!progress.complete);
        let view = context(
            &mut engine,
            &snapshot,
            build.captured_index(),
            0,
            head.len(),
        )?;
        assert!(view.complete_blocks);
        assert!(!view.reference_budget_proven);
        let actual = paged_spans(&view)?;
        let ready_start = definition.encode_utf16().count();
        let wait_start = ready_start + "# **Ready 🙂**\n\n".encode_utf16().count();
        assert!(
            actual
                .iter()
                .any(|span| span.kind == "heading" && span.location == ready_start)
        );
        assert!(
            !actual.iter().any(|span| span.location >= wait_start),
            "unsearched absence and unknown whole-source fuel stay literal"
        );
        assert!(pages.rows.lock().expect("rows").text_read_pages.len() <= 1);
        // Even a proven earlier first definition cannot invent global fuel.
        assert_eq!(view.definitions().iter().next().is_none(), !known_first);
    }
    Ok(())
}

#[test]
fn cancelled_index_prefix_reuses_shared_source_then_rechecks_edited_boundary() -> TestResult {
    let text = format!(
        "# **Ready**\n\n{}",
        "plain completed paragraph\n\n".repeat(6000)
    );
    let (mut engine, mut source, _) = source(&text)?;
    let before = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, before.clone(), MarkupMode::Style)?;
    let progress = build.step(&mut engine, &mut || false)?;
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    let old_index = build.captured_index();
    drop(build);
    let same = MarkupIndexBuilder::new(&mut engine, before.clone(), MarkupMode::Style)?;
    assert_eq!(same.progress().indexed_bytes, progress.indexed_bytes);
    drop(same);
    let at = progress.indexed_bytes - 4;
    let window = engine.logical_window(&before, at, 128, &mut || false)?;
    let local = usize::try_from(at - window.start().bytes)?;
    source.replace_window(&window, local..local + 1, "X")?;
    let after = source.capture_for_publication()?;
    let rebuild = MarkupIndexBuilder::new(&mut engine, after.clone(), MarkupMode::Style)?;
    assert!(rebuild.progress().reused_bytes > 0 && rebuild.progress().indexed_bytes < at);
    assert!(before.id() != after.id());
    let after_window = engine.logical_window(&after, 0, 64, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&after_window, old_index),
        Err(bloom_text::Error::Stale)
    ));
    Ok(())
}

#[test]
fn actual_label_refusal_keeps_later_unscanned_reference_block_unproved() -> TestResult {
    let labels = |range: std::ops::Range<usize>| {
        let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyz";
        range
            .map(|value| {
                format!(
                    "[{}{}{}] ",
                    char::from(alphabet[value / 1296]),
                    char::from(alphabet[(value / 36) % 36]),
                    char::from(alphabet[value % 36])
                )
            })
            .collect::<String>()
            + "\n\n"
    };
    let first = labels(0..5000);
    let second = labels(5000..9000);
    let later = "# [after]\n\n[after]: boom-attachment:884646c1-14b4-490d-be8c-8953af793315\n";
    let text = format!("{first}{second}{later}");
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete());
    let (view, progress, _) = context_with_progress(
        &mut engine,
        &snapshot,
        indexed,
        (first.len() + 6_000) as u64,
        24 * 1024,
    )?;
    assert!(
        view.window_start.bytes < first.len() as u64,
        "the actual window overlaps the first complete block"
    );
    assert!(
        view.window_end.bytes > (first.len() + second.len() + "# [after]\n".len()) as u64,
        "the same actual window also contains the later reference-bearing heading"
    );
    assert_eq!(
        progress.unique_references, 8192,
        "the actual discovery reaches the unchanged label admission bound"
    );
    assert!(view.complete_blocks && !view.reference_budget_proven);
    // Both long complete blocks overlap the actual bounded window. Discovery
    // hits the real8192-label admission while scanning the second block, before
    // the later reference-bearing heading is visited. No seeded/fake proof or
    // lowered production cap is used.
    let later_fragment = view
        .fragments
        .iter()
        .find(|value| value.text.starts_with("# [after]"))
        .expect("actual later complete root block is in the bounded window");
    assert!(
        !later_fragment.inline_ready,
        "unvisited is unknown, never independent=true"
    );
    assert!(
        !paged_spans(&view)?
            .iter()
            .any(|value| value.kind == "heading")
    );
    assert!(
        view.definitions().iter().next().is_none(),
        "the refused pass did not pretend to complete definition lookup"
    );
    assert!(
        spans(&text)?.iter().any(|value| value.kind == "link"),
        "ordinary full parser really resolves that later link"
    );
    Ok(())
}

#[test]
fn actual_unicode_reference_membership_and_per_block_definitions_match_pinned_parser() -> TestResult
{
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let text = format!(
        "# [K] [K] [k]\n\n# [A B] [a\tb]\n\n[k]: boom-attachment:{id}\n[a b]: boom-attachment:{id}\n"
    );
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    let (view, progress, retained_peak) =
        context_with_progress(&mut engine, &snapshot, indexed, 0, text.len())?;
    assert!(view.reference_budget_proven);
    assert_eq!(
        progress.unique_references, 2,
        "pinned Unicode folding and whitespace-normalized parser labels, not raw string equality"
    );
    assert!(progress.max_reference_probes <= 64);
    assert!((2048 * 2..32 * 1024).contains(&retained_peak));
    for fragment in view
        .fragments
        .iter()
        .filter(|value| value.text.starts_with('#'))
    {
        assert_eq!(
            view.definitions_for(fragment)?.iter().count(),
            1,
            "actual block dependencies do not import unrelated defs"
        );
    }
    assert_eq!(coverage(paged_spans(&view)?), coverage(spans(&text)?));
    assert_oracle(&text, &mut engine, &snapshot, 0, text.len())
}

#[test]
fn many_independent_blocks_do_not_rebuild_a_remote_title_for_each_discovery_or_projection()
-> TestResult {
    let heading = "# Ready\n\n";
    let text = format!(
        "{}[remote]\n\n[remote]: boom-attachment:884646c1-14b4-490d-be8c-8953af793315 \"{}\"\n",
        heading.repeat(1200),
        "long actual title 🙂 ".repeat(400)
    );
    assert!(text.len() < 32 * 1024);
    let (mut engine, mut source, _) = source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    let (view, progress, retained_peak) =
        context_with_progress(&mut engine, &snapshot, indexed, 0, text.len())?;
    assert!(view.reference_budget_proven);
    assert_eq!(progress.unique_references, 1);
    assert!(
        progress.reference_probes < 16,
        "actual membership work is not headings times the global reference set"
    );
    assert!(retained_peak < 64 * 1024);
    let mut headings = 0;
    for fragment in view
        .fragments
        .iter()
        .filter(|value| value.text.starts_with('#'))
    {
        headings += 1;
        assert!(view.definitions_for(fragment)?.iter().next().is_none());
    }
    assert_eq!(headings, 1200);
    assert_eq!(coverage(paged_spans(&view)?), coverage(spans(&text)?));
    Ok(())
}

#[test]
fn long_single_line_paragraph_executes_paged_openers_and_matches_actual_full_parser() -> TestResult
{
    let text = format!(
        "paragraph {}{}{}",
        "*a ".repeat(90),
        "literal café 🙂 ".repeat(10_000),
        " x*".repeat(90)
    );
    assert!(text.len() > 4 * pulldown_cmark::paged::PROBE_BYTES);
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let mut finished = false;
    for _ in 0..4096 {
        let reads = pages.rows.lock().expect("rows").inline_reads;
        let progress = build.step(&mut engine, &mut || false)?;
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
        assert!(
            pages.rows.lock().expect("rows").inline_reads - reads <= 1,
            "one actual opener page at most before yielding the existing worker lane"
        );
        if progress.complete {
            assert!(!progress.incomplete_block);
            finished = true;
            break;
        }
    }
    assert!(finished);
    let indexed = build.finish()?;
    assert!(indexed.complete());
    assert!(
        pages.rows.lock().expect("rows").opener_writes >= 2,
        "the real sequence exceeded resident opener storage"
    );
    for anchor in [
        0,
        32_768,
        65_537,
        snapshot.summary().utf16 - 48,
        snapshot.summary().utf16,
    ] {
        let view = context(&mut engine, &snapshot, Arc::clone(&indexed), anchor, 512)?;
        assert!(view.complete_blocks && view.reference_budget_proven);
        let first = usize::try_from(view.window_start.utf16)?;
        let last = usize::try_from(view.window_end.utf16)?;
        assert_eq!(
            coverage(paged_spans(&view)?),
            coverage(clipped(&spans(&text)?, first, last))
        );
        assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
    }
    assert!(source.capture().same(&snapshot));
    Ok(())
}

#[test]
fn actual_grouped_long_runs_write_bounded_annotations_then_edit_and_undo_reprove() -> TestResult {
    // A closing run after whitespace cannot close in the actual pinned
    // grammar. Keep a real nonspace right flank so this tests a chosen pair.
    let text = format!(
        "paragraph {}{}x{}",
        "*".repeat(4096),
        "é🙂 body ".repeat(10_000),
        "*".repeat(4096)
    );
    assert!(
        spans(&text)?.iter().any(|span| span.kind == "strong"),
        "the independent full parser must actually choose the intended nested pair"
    );
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    assert_eq!(
        pages.rows.lock().expect("rows").inline_style_writes,
        1,
        "actual nested delimiter events share their native trait/syntax unions"
    );
    assert_eq!(
        pages.rows.lock().expect("rows").opener_writes,
        0,
        "one long source run is one grouped opener, not one item per character"
    );
    for anchor in [0, 16_000, snapshot.summary().utf16 - 48] {
        let view = context(&mut engine, &snapshot, Arc::clone(&indexed), anchor, 256)?;
        let first = usize::try_from(view.window_start.utf16)?;
        let last = usize::try_from(view.window_end.utf16)?;
        assert_eq!(
            coverage(paged_spans(&view)?),
            coverage(clipped(&spans(&text)?, first, last))
        );
    }
    let window = engine.logical_window(&snapshot, 20_000, 256, &mut || false)?;
    let local = window
        .text()
        .find("body")
        .expect("actual bounded middle text");
    source.replace_window(&window, local..local + 4, "changed")?;
    let mut changed = text.clone();
    let first = usize::try_from(window.start().bytes)? + local;
    changed.replace_range(first..first + 4, "changed");
    let after = source.capture_for_publication()?;
    assert!(!after.same(&snapshot));
    assert_oracle(&changed, &mut engine, &after, 20_000, 256)?;
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &indexed));
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn cancelled_long_opener_work_and_corrupt_annotations_never_change_or_prove_other_source()
-> TestResult {
    let text = format!(
        "paragraph {}{}{}",
        "*a ".repeat(100),
        "plain café 🙂 ".repeat(8000),
        " x*".repeat(100)
    );
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    for _ in 0..4096 {
        let progress = build.step(&mut engine, &mut || false)?;
        assert!(!progress.complete);
        if pages.rows.lock().expect("rows").opener_writes >= 2 {
            break;
        }
    }
    assert!(pages.rows.lock().expect("rows").opener_writes >= 2);
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    drop(build);
    assert!(source.capture().same(&snapshot));
    let (indexed, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete());
    let mut corrupted = false;
    for row in pages.rows.lock().expect("rows").pages.values_mut() {
        if row.2 == PageKind::Index
            && row
                .3
                .windows(b"\"inline_styles\"".len())
                .any(|value| value == b"\"inline_styles\"")
        {
            row.3[0] ^= 1;
            corrupted = true;
        }
    }
    assert!(
        corrupted,
        "the actual completed producer wrote annotation pages"
    );
    let window = engine.logical_window(&snapshot, 50_000, 256, &mut || false)?;
    let mut query = MarkupQuery::new(&window, indexed)?;
    let mut refused = false;
    for _ in 0..8192 {
        match query.step(&mut engine, &mut || false) {
            Err(_) => {
                refused = true;
                break;
            }
            Ok(value) if value.complete => break,
            Ok(_) => (),
        }
    }
    assert!(refused);
    assert!(source.capture().same(&snapshot));
    assert_eq!(
        engine
            .logical_window(&snapshot, 50_000, 256, &mut || false)?
            .text(),
        window.text()
    );
    Ok(())
}

#[test]
fn long_mixed_delimiter_classes_preserve_actual_pinned_precedence_and_scalar_edges() -> TestResult {
    // Separate opening/closing flanks force real searches across multiple
    // pages. Mismatched classes and run lengths must be discarded/skipped by
    // the same lower-bound/rule-of-three decisions as the full parser.
    let mut text = format!(
        "paragraph {}{}{}",
        "*a _b ~~c ~d ".repeat(40),
        "plain café 🙂 ".repeat(4000),
        " w~ z~~ y_ x*".repeat(40)
    );
    text.push_str(" a***b**c* foo_bar_baz ~~x~y~~ \\*literal* &ast;*source* ");
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    for anchor in [
        0,
        127,
        32_767,
        snapshot.summary().utf16 - 150,
        snapshot.summary().utf16,
    ] {
        assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
    }
    // A different complete source may not borrow these derived annotations.
    let window = engine.logical_window(&snapshot, 100, 256, &mut || false)?;
    source.replace_window(&window, 0..0, "changed ")?;
    let after = source.capture_for_publication()?;
    let after_window = engine.logical_window(&after, 100, 256, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&after_window, indexed),
        Err(bloom_text::Error::Stale)
    ));
    Ok(())
}

#[test]
fn long_multiline_paragraphs_use_actual_followers_and_match_full_lf_crlf_cr_grammar() -> TestResult
{
    for ending in ["\n", "\r\n", "\r"] {
        let mut text = format!("paragraph **first{ending}");
        for line in 0..1000 {
            text.push_str(&format!("  continued café 🙂 line {line} authored words across this original source line and its real continuation{ending}"));
        }
        text.push_str(&format!("last**{ending}{ending}# Outside *real*{ending}"));
        assert!(text.len() > 2 * pulldown_cmark::paged::PROBE_BYTES);
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(indexed.complete() && !progress.incomplete_block);
        for anchor in [
            0,
            32_768,
            snapshot.summary().utf16 - 60,
            snapshot.summary().utf16,
        ] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        assert!(source.capture().same(&snapshot));
    }
    Ok(())
}

#[test]
fn actual_long_setext_and_heavy_table_interrupt_preserve_full_parser_style_and_tail() -> TestResult
{
    for (opening, following) in [
        ("#notATX ", "  ===\n"),
        ("paragraph ", "---\n"),
        (
            "paragraph ",
            "| left | right |\n|---|---|\n| one | **two** |\n",
        ),
    ] {
        let text = format!(
            "{opening}**{}**\n{following}\n# Outside\n",
            "café 🙂 authored body ".repeat(1800)
        );
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(indexed.complete() && !progress.incomplete_block);
        for anchor in [
            0,
            20_000,
            snapshot.summary().utf16 - 80,
            snapshot.summary().utf16,
        ] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        let tail = context(
            &mut engine,
            &snapshot,
            indexed,
            snapshot.summary().utf16,
            256,
        )?;
        assert!(
            paged_spans(&tail)?
                .iter()
                .any(|value| value.kind == "heading")
        );
    }
    Ok(())
}

#[test]
fn pinned_paragraph_follower_requires_real_table_line_and_source_bound_resume() -> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, InlineStop, ParagraphFollowing, begin_unfinished_paragraph,
    };
    let seed = begin_unfinished_paragraph(
        "paragraph *text",
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual first-pass paragraph seed");
    assert_eq!(
        seed.following_line("| a | b |\n", false),
        Some(ParagraphFollowing::NeedMore)
    );
    assert_eq!(
        seed.following_line("| a | b |\n|---|---|\n", false),
        Some(ParagraphFollowing::End)
    );
    assert_eq!(
        seed.following_line("  ---", false),
        Some(ParagraphFollowing::NeedMore)
    );
    assert!(matches!(
        seed.following_line("  ---\n", false),
        Some(ParagraphFollowing::Setext { level: 2, .. })
    ));
    assert_eq!(
        seed.following_line("  ordinary\n", false),
        Some(ParagraphFollowing::Continue { skip: 2 })
    );
    let mut stream = seed.run_stream();
    let before = stream.feed("paragraph *é🙂\n", false, &mut || false)?;
    assert_eq!(before.stopped, Some(InlineStop::ParagraphBoundary));
    let point = stream.point();
    assert!(stream.continue_line("invented", "").is_err());
    assert_eq!(
        stream.point(),
        point,
        "invalid handoff cannot partially advance the captured source counters"
    );
    stream.continue_line("\n", "  ")?;
    let after = stream.feed("body*", true, &mut || false)?;
    assert!(after.complete);
    let actual = "paragraph *é🙂\n  body*";
    assert_eq!(stream.point().bytes, actual.len() as u64);
    assert_eq!(stream.point().utf16, actual.encode_utf16().count() as u64);
    let full = "paragraph\n| a | b |\n|---|---|\n";
    assert!(
        spans(full)?.iter().any(|value| value.kind == "table"),
        "the same actual pinned parser interrupts this source"
    );
    Ok(())
}

#[test]
fn code_run_survey_and_chosen_pair_match_actual_pinned_unicode_escape_ranges() -> TestResult {
    use pulldown_cmark::paged::{BlockCarry, begin_unfinished_paragraph, prepare_code_pair};
    use pulldown_cmark::{Event, Parser};
    for text in [
        "paragraph `é🙂` tail",
        "paragraph \\``é🙂` tail",
        "paragraph `é\\` tail",
        "paragraph ``é ` 🙂`` tail",
        "paragraph \\\\`é🙂` tail",
    ] {
        let seed = begin_unfinished_paragraph(
            "paragraph ",
            MarkupMode::Style.options(),
            &BlockCarry::default(),
        )
        .expect("actual unfinished first-pass paragraph");
        let mut stream = seed.code_run_stream();
        let surveyed = stream.feed(text, true, &mut || false)?;
        assert!(surveyed.complete);
        let open = surveyed.runs[0];
        let close = surveyed
            .runs
            .iter()
            .copied()
            .skip(1)
            .find(|run| open.opening_count().expect("valid actual run") == run.count)
            .expect(
                "actual nearest compatible closer in this source with no earlier HTML/link pass",
            );
        let prepared = prepare_code_pair(open, close)?.expect("actual compatible pair");
        let expected: Vec<_> = Parser::new(text)
            .into_offset_iter()
            .filter_map(|(event, range)| matches!(event, Event::Code(_)).then_some(range))
            .collect();
        assert_eq!(expected.len(), 1);
        assert_eq!(prepared.start.bytes, expected[0].start as u64);
        assert_eq!(prepared.end.bytes, expected[0].end as u64);
        assert_eq!(
            prepared.start.utf16,
            text[..expected[0].start].encode_utf16().count() as u64
        );
        assert_eq!(
            prepared.end.utf16,
            text[..expected[0].end].encode_utf16().count() as u64
        );
        assert!(
            text[usize::try_from(prepared.start.bytes)?
                ..usize::try_from(prepared.opening_end.bytes)?]
                .bytes()
                .all(|byte| byte == b'`')
        );
        assert!(
            text[usize::try_from(prepared.closing_start.bytes)?
                ..usize::try_from(prepared.end.bytes)?]
                .bytes()
                .all(|byte| byte == b'`')
        );
    }
    Ok(())
}

#[test]
fn code_survey_keeps_huge_runs_grouped_and_yields_without_resident_body_or_lost_runs() -> TestResult
{
    use pulldown_cmark::paged::{BlockCarry, PROBE_BYTES, begin_unfinished_paragraph};
    let text = format!(
        "paragraph {}é🙂{}",
        "`".repeat(3 * PROBE_BYTES),
        "`".repeat(3 * PROBE_BYTES)
    );
    let seed = begin_unfinished_paragraph(
        "paragraph ",
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual unfinished paragraph");
    let mut stream = seed.code_run_stream();
    let mut at = 0;
    let mut runs = Vec::new();
    for _ in 0..64 {
        let mut end = (at + PROBE_BYTES).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let value = stream.feed(&text[at..end], end == text.len(), &mut || false)?;
        assert!(value.runs.len() <= 128);
        assert_eq!(stream.retained_text_bytes(), 0);
        at += value.consumed;
        runs.extend(value.runs);
        if value.complete {
            break;
        }
    }
    assert_eq!(at, text.len());
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].count, (3 * PROBE_BYTES) as u64);
    assert_eq!(runs[1].count, runs[0].count);
    assert_eq!(stream.point().utf16, text.encode_utf16().count() as u64);
    let repeated = format!("paragraph {}", "`x ".repeat(1000));
    let mut stream = seed.code_run_stream();
    let mut at = 0;
    let mut count = 0;
    let mut turns = 0;
    while at < repeated.len() {
        let value = stream.feed(&repeated[at..], true, &mut || false)?;
        assert!(value.runs.len() <= 128);
        assert!(value.consumed > 0);
        at += value.consumed;
        count += value.runs.len();
        turns += 1;
    }
    count += stream.feed("", true, &mut || false)?.runs.len();
    assert_eq!(count, 1000);
    assert!(turns > 1);
    Ok(())
}

#[test]
fn code_survey_cancel_and_corrupt_counts_cannot_create_a_pair_or_resume_failed_work() -> TestResult
{
    use pulldown_cmark::paged::{BlockCarry, CodeRun, InlineRunError, begin_unfinished_paragraph};
    assert!(CodeRun::from_checkpoint([0, 0, 0, 0, 0, 1]).is_err());
    assert!(CodeRun::from_checkpoint([u64::MAX, 0, 0, 1, 1, 0]).is_err());
    assert!(CodeRun::from_checkpoint([0, 0, 1, 1, 1, 2]).is_err());
    let seed = begin_unfinished_paragraph(
        "paragraph ",
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual first-pass paragraph");
    let mut stream = seed.code_run_stream();
    let input = "plain ".repeat(4000);
    let mut checks = 0;
    assert!(matches!(
        stream.feed(&input, false, &mut || {
            checks += 1;
            checks == 3
        }),
        Err(InlineRunError::Cancelled)
    ));
    assert!(stream.feed("", true, &mut || false).is_err());
    Ok(())
}

#[test]
fn actual_long_code_spans_mask_emphasis_links_and_html_then_match_full_parser() -> TestResult {
    // The production source stays paged; the complete String here is the
    // independent existing-parser oracle, not a producer input API.
    let text = format!(
        "paragraph **before** ``{} `{} tail **after**",
        "café 🙂 *not emphasis* [not a link] <not-html> ".repeat(8000),
        "continued ordinary body ".repeat(4000)
    );
    // The one-tick run cannot close the two-tick opener. A later actual
    // two-tick run closes it, so intervening inline syntax is all code.
    let text = text.replacen(" tail **after**", "`` tail **after**", 1);
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    assert!(pages.rows.lock().expect("rows").code_writes > 0);
    for anchor in [
        0,
        32_767,
        80_001,
        snapshot.summary().utf16 - 60,
        snapshot.summary().utf16,
    ] {
        assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
    }
    let middle = context(&mut engine, &snapshot, indexed, 80_001, 512)?;
    let actual = paged_spans(&middle)?;
    assert!(actual.iter().any(|value| value.kind == "code"));
    assert!(
        !actual
            .iter()
            .any(|value| matches!(value.kind, "strong" | "emphasis" | "link" | "literal"))
    );
    assert!(source.capture().same(&snapshot));
    Ok(())
}

#[test]
fn code_run_length_index_chooses_nearest_actual_closer_and_yields_each_real_page() -> TestResult {
    // More than one leaf, deliberately unsorted lengths/source positions,
    // escaped opening prefixes, escaped closers, and multiline continuations.
    let mut text = String::from("paragraph **before** ");
    for count in (1..=40).rev() {
        let ticks = "`".repeat(count);
        text.push_str(&format!("{ticks}é🙂 *raw* {ticks} "));
    }
    text.push_str(&"ordinary authored body ".repeat(1800));
    text.push_str(" \\``escaped opener` `escaped close\\` **after**\n  ``continued\r\n  *raw* é🙂``\n\n# Outside\n");
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let mut done = false;
    for _ in 0..16_384 {
        let before = {
            let rows = pages.rows.lock().expect("rows");
            (rows.code_reads, rows.code_writes)
        };
        let progress = build.step(&mut engine, &mut || false)?;
        let after = {
            let rows = pages.rows.lock().expect("rows");
            (rows.code_reads, rows.code_writes)
        };
        assert!(
            after.0 - before.0 <= 1 && after.1 - before.1 <= 1,
            "the real run-index body yields between page reads/writes"
        );
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
        if progress.complete {
            assert!(!progress.incomplete_block);
            done = true;
            break;
        }
    }
    assert!(done);
    let indexed = build.finish()?;
    assert!(indexed.complete());
    {
        let rows = pages.rows.lock().expect("rows");
        assert!(
            rows.code_reads > 4 && rows.code_writes > 4,
            "real sorted runs exceeded one resident leaf"
        );
        assert!(
            rows.index_write_bytes > 0,
            "derived append bytes are real writes, never claimed reclaimed by Arc drop"
        );
    }
    for anchor in [0, 255, 1000, 16_383, snapshot.summary().utf16 - 100] {
        assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    }
    Ok(())
}

#[test]
fn actual_large_code_body_is_bounded_and_edit_undo_reuses_exact_completed_source() -> TestResult {
    // Keep the same >3MiB code body and internal delimiter density. On a
    // real closer deletion, the unsupported link is exposed before spending
    // >4096 fixture turns resolving 240,000 newly unmasked emphasis pairs.
    let text = format!(
        "paragraph **before** `[inside code]{}` **after**",
        "é🙂 *body* ".repeat(240_000)
    );
    assert!(text.len() > 3 * 1024 * 1024);
    assert!(
        spans(&text).is_err() && media_spans(&text).is_err(),
        "public2MiB entry limits are preserved"
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    for anchor in [
        0,
        65_535,
        snapshot.summary().utf16 / 2,
        snapshot.summary().utf16 - 48,
    ] {
        assert_large_pinned_parser_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    }
    // Removing the true closer exposes an earlier link pass; it must not
    // borrow the old source's completed code/emphasis annotations.
    let near = engine.logical_window(&snapshot, snapshot.summary().utf16, 256, &mut || false)?;
    let close = near
        .text()
        .rfind('`')
        .expect("actual closing tick in the retained tail");
    source.replace_window(&near, close..close + 1, "")?;
    let changed = source.capture_for_publication()?;
    let (unknown, progress) = index(&mut engine, &changed, MarkupMode::Style)?;
    assert!(!unknown.complete() && progress.incomplete_block);
    let changed_window = engine.logical_window(&changed, 100, 256, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&changed_window, Arc::clone(&indexed)),
        Err(bloom_text::Error::Stale)
    ));
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &indexed));
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn actual_code_index_cancellation_and_corruption_do_not_grant_inline_or_source_authority()
-> TestResult {
    let mut text = String::from("paragraph ");
    for count in 1..=48 {
        let ticks = "`".repeat(count);
        text.push_str(&format!("{ticks}é🙂{ticks} "));
    }
    text.push_str(&"body with actual immutable Unicode 🙂 ".repeat(1800));
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    for _ in 0..16_384 {
        let progress = build.step(&mut engine, &mut || false)?;
        assert!(!progress.complete);
        if pages.rows.lock().expect("rows").code_writes >= 4 {
            break;
        }
    }
    assert!(pages.rows.lock().expect("rows").code_writes >= 4);
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    drop(build);
    assert!(source.capture().same(&snapshot));
    let mut next = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let initial = pages.rows.lock().expect("rows").code_writes;
    for _ in 0..16_384 {
        let progress = next.step(&mut engine, &mut || false)?;
        assert!(!progress.complete);
        if pages.rows.lock().expect("rows").code_writes >= initial + 4 {
            break;
        }
    }
    let mut corrupted = 0;
    for row in pages.rows.lock().expect("rows").pages.values_mut() {
        if row.2 == PageKind::Index
            && row
                .3
                .windows(b"\"code_runs\"".len())
                .any(|bytes| bytes == b"\"code_runs\"")
        {
            row.3[0] ^= 1;
            corrupted += 1;
        }
    }
    assert!(corrupted > 0);
    let mut refused = false;
    for _ in 0..16_384 {
        match next.step(&mut engine, &mut || false) {
            Err(_) => {
                refused = true;
                break;
            }
            Ok(progress) if progress.complete => break,
            Ok(_) => (),
        }
    }
    assert!(refused);
    assert!(source.capture().same(&snapshot));
    let head = engine.logical_window(&snapshot, 0, 128, &mut || false)?;
    let end = head.text().len();
    assert_eq!(
        head.text(),
        text.get(..end).expect("actual scalar-complete head")
    );
    // An earlier actual link/HTML opener remains unsupported in this slice;
    // later code-looking bytes cannot incorrectly override that precedence.
    let earlier = format!(
        "paragraph [not yet supported] `{} ` tail",
        "plain 🙂 ".repeat(5000)
    );
    let (mut other, mut other_source, _) = self::source(&earlier)?;
    let captured = other_source.capture_for_publication()?;
    let (unknown, progress) = index(&mut other, &captured, MarkupMode::Style)?;
    assert!(!unknown.complete() && progress.incomplete_block);
    let view = context(&mut other, &captured, unknown, 100, 256)?;
    assert!(view.inline_styles.is_empty());
    Ok(())
}

#[test]
fn shared_angle_recognizers_preserve_pinned_uri_email_tag_and_special_endpoints() -> TestResult {
    use pulldown_cmark::paged::{AngleGuard, AngleKind, AngleStatus, AngleStream};
    use pulldown_cmark::{Event, LinkType, Parser, Tag};
    let cases = [
        ("<http:x>", Some(AngleKind::Uri)),
        ("<ab:>", Some(AngleKind::Uri)),
        ("<x:y>", None),
        ("<ab:é🙂*source*>", Some(AngleKind::Uri)),
        ("<http:a b>", None),
        ("<a@b>", Some(AngleKind::Email)),
        ("<a.b+z@host.test>", Some(AngleKind::Email)),
        ("<a@-b>", None),
        ("<a@b->", None),
        ("<foo>", Some(AngleKind::Html)),
        ("</foo >", Some(AngleKind::Html)),
        ("</foo\n>", None),
        ("<foo a='é🙂'>", Some(AngleKind::Html)),
        ("<foo\n a='b'>", Some(AngleKind::Html)),
        ("<foo a=one\ttwo>", Some(AngleKind::Html)),
        ("<foo a=one two>", Some(AngleKind::Html)),
        ("<foo a='unterminated>", None),
        ("<foo / >", None),
        ("<!-->", Some(AngleKind::Html)),
        ("<!--->", Some(AngleKind::Html)),
        ("<!--a->", None),
        ("<!--a-->", Some(AngleKind::Html)),
        ("<!ABC é🙂>", Some(AngleKind::Html)),
        ("<?a?>", Some(AngleKind::Html)),
        ("<?a>", None),
        // Preserve the actual pinned scanner, including its first-bracket-run
        // behavior. This is an explicit oracle, not a CommonMark spec rewrite.
        ("<![CDATA[a]>", Some(AngleKind::Html)),
        ("<![CDATA[a]x]]>", None),
    ];
    for (raw, expected) in cases {
        for split in raw
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(raw.len()))
        {
            let mut scanner = AngleStream::new(0, AngleGuard::default());
            let first = scanner.feed(&raw[..split], split == raw.len(), &mut || false)?;
            assert!(first.consumed <= split && raw.is_char_boundary(first.consumed));
            let result = if first.status == AngleStatus::Pending {
                let tail = scanner.feed(&raw[split..], true, &mut || false)?;
                if matches!(tail.status, AngleStatus::Matched(_)) {
                    assert_eq!(split + tail.consumed, raw.len());
                }
                tail.status
            } else {
                if matches!(first.status, AngleStatus::Matched(_)) {
                    assert_eq!(first.consumed, raw.len());
                }
                first.status
            };
            assert_eq!(
                result,
                expected.map_or(AngleStatus::Rejected, AngleStatus::Matched),
                "actual bytes {raw:?}, split={split}"
            );
            assert!(scanner.retained_text_bytes() <= 52);
        }
        let prefix = "paragraph ";
        let text = format!("{prefix}{raw} tail");
        let events: Vec<_> = Parser::new(&text)
            .into_offset_iter()
            .filter_map(|(event, range)| match event {
                Event::InlineHtml(_) => Some((AngleKind::Html, range)),
                Event::Start(Tag::Link { link_type, .. }) => Some((
                    if link_type == LinkType::Email {
                        AngleKind::Email
                    } else {
                        AngleKind::Uri
                    },
                    range,
                )),
                _ => None,
            })
            .collect();
        assert_eq!(
            events.len(),
            usize::from(expected.is_some()),
            "ordinary parser must preserve fixed expected semantics for {raw:?}"
        );
        if let Some((kind, range)) = events.first() {
            assert_eq!(Some(*kind), expected);
            assert_eq!(range.clone(), prefix.len()..prefix.len() + raw.len());
        }
    }
    Ok(())
}

#[test]
fn actual_long_html_and_autolinks_exclude_their_interiors_before_code_and_emphasis() -> TestResult {
    let text = format!(
        "paragraph **before** <widget title='{}'> visible **strong** </widget> <https:{}> <a.b+z@host.test> <!--{}--> <?{}?> <![CDATA[{}]]> `actual code` **after**\n\n# Outside\n",
        "é🙂 *not emphasis* [not a link] `not code` ".repeat(1800),
        "é🙂_*not_emphasis*".repeat(2000),
        "authored é🙂 *not emphasis* `not code` ".repeat(1800),
        "directive é🙂 **not strong** ".repeat(1800),
        "CDATA é🙂 *not emphasis* ".repeat(1800)
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    for anchor in [
        0,
        32_767,
        65_535,
        snapshot.summary().utf16 / 2,
        snapshot.summary().utf16 - 80,
    ] {
        assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    }
    let middle = context(&mut engine, &snapshot, indexed, 32_767, 384)?;
    assert!(
        paged_spans(&middle)?.is_empty(),
        "actual quoted HTML attributes are opaque, rather than emphasis/code source"
    );
    assert!(source.capture().same(&snapshot));
    Ok(())
}

#[test]
fn actual_multimegabyte_angle_body_uses_bounded_state_and_large_pinned_parser_oracle() -> TestResult
{
    use pulldown_cmark::paged::{AngleGuard, AngleKind, AngleStatus, AngleStream};
    let uri = format!("<https:`not_code`{}`tail`>", "é🙂uri".repeat(400_000));
    assert!(uri.len() > 3 * 1024 * 1024);
    let mut scanner = AngleStream::new(0, AngleGuard::default());
    let mut at = 0;
    let mut turns = 0;
    while at < uri.len() {
        let mut end = (at + pulldown_cmark::paged::PROBE_BYTES).min(uri.len());
        while !uri.is_char_boundary(end) {
            end -= 1;
        }
        let result = scanner.feed(&uri[at..end], end == uri.len(), &mut || false)?;
        assert!(scanner.retained_text_bytes() <= 52);
        assert_eq!(result.consumed, end - at);
        at = end;
        turns += 1;
        assert_eq!(
            result.status,
            if end == uri.len() {
                AngleStatus::Matched(AngleKind::Uri)
            } else {
                AngleStatus::Pending
            }
        );
    }
    assert!(turns > 96);
    assert!(scanner.attachment_candidate().is_none());
    let text = format!("paragraph **before** {uri} **after**");
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    assert_eq!(
        pages.rows.lock().expect("rows").code_writes,
        0,
        "scope discovery must not build a code archive for ticks hidden in a URL/HTML candidate"
    );
    for anchor in [
        0,
        65_535,
        snapshot.summary().utf16 / 2,
        snapshot.summary().utf16 - 48,
    ] {
        assert_large_pinned_parser_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    }
    Ok(())
}

#[test]
fn actual_long_autolink_media_keeps_exact_original_ranges_source_and_undo_identity() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let local = format!("<boom-attachment:{id}>");
    let text = format!(
        "paragraph {}{local} café 🙂 <a@b> **after**",
        "authored Unicode é🙂 body ".repeat(3000)
    );
    let target = text.find(&local).expect("actual local URI");
    let anchor = text[..target].encode_utf16().count() as u64;
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    let view = context(&mut engine, &snapshot, Arc::clone(&indexed), anchor, 256)?;
    let actual = paged_media_spans(&view)?;
    assert_eq!(actual.len(), 1);
    assert_eq!(actual[0].id.to_string(), id);
    assert_eq!(actual[0].location as u64 + view.window_start.utf16, anchor);
    assert_eq!(actual[0].length, local.encode_utf16().count());
    // A public projection value is not a source authority; malformed caller
    // metadata must fail rather than underflow, while the actual index stays.
    let mut malformed = context(&mut engine, &snapshot, Arc::clone(&indexed), anchor, 256)?;
    let first = malformed.inline_media[0].1;
    malformed.inline_media[0].2 = first;
    assert!(paged_media_spans(&malformed).is_err());
    for at in [
        anchor.saturating_sub(16),
        anchor,
        anchor + 20,
        snapshot.summary().utf16,
    ] {
        assert_oracle(&text, &mut engine, &snapshot, at, 192)?;
    }
    let window = engine.logical_window(&snapshot, anchor, 256, &mut || false)?;
    let relative = window.text().find(id).expect("actual bounded target UUID");
    source.replace_window(&window, relative..relative + 36, "not-a-local-identity")?;
    let changed = source.capture_for_publication()?;
    let changed_window = engine.logical_window(&changed, anchor, 256, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&changed_window, Arc::clone(&indexed)),
        Err(bloom_text::Error::Stale)
    ));
    let (after, progress) = index(&mut engine, &changed, MarkupMode::Media)?;
    assert!(after.complete() && !progress.incomplete_block);
    assert!(paged_media_spans(&context(&mut engine, &changed, after, anchor, 256)?)?.is_empty());
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Media)?;
    assert!(Arc::ptr_eq(&restored, &indexed));
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn cancelled_or_unclosed_angle_lookahead_never_changes_source_or_fakes_paragraph_eof() -> TestResult
{
    use pulldown_cmark::paged::{AngleGuard, AngleKind, AngleStatus, AngleStream, InlineRunError};
    let mut stream = AngleStream::new(0, AngleGuard::default());
    assert_eq!(
        stream.feed("<tag title='é🙂", false, &mut || false)?.status,
        AngleStatus::Pending
    );
    let mut checks = 0;
    assert!(matches!(
        stream.feed(&"plain ".repeat(4000), false, &mut || {
            checks += 1;
            checks == 4
        }),
        Err(InlineRunError::Cancelled)
    ));
    assert!(
        stream.feed("'>", true, &mut || false).is_err(),
        "actual cancelled scanner is terminal"
    );
    let mut overflow = AngleStream::new(u64::MAX, AngleGuard::default());
    assert!(overflow.feed("<", false, &mut || false).is_err());
    let mut split = AngleStream::new(0, AngleGuard::default());
    assert_eq!(
        split.feed("<tag a='é🙂", false, &mut || false)?.status,
        AngleStatus::Pending
    );
    assert_eq!(
        split.feed("'>", true, &mut || false)?.status,
        AngleStatus::Matched(AngleKind::Html)
    );
    // The same opening tag cannot consume across a real blank-line paragraph
    // boundary to acquire a later quote/terminator. Full parser differential
    // also checks the literal failed-lookahead replay and restored emphasis.
    for text in [
        format!(
            "paragraph <tag title='{}\n\nclose'> **after**\n",
            "ordinary é🙂 source ".repeat(3000)
        ),
        format!(
            "paragraph <!-- {} **after**",
            "ordinary é🙂 source ".repeat(3000)
        ),
    ] {
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(indexed.complete() && !progress.incomplete_block);
        for anchor in [0, 32_767, snapshot.summary().utf16 - 64] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        assert!(source.capture().same(&snapshot));
    }
    let seed = pulldown_cmark::paged::begin_unfinished_paragraph(
        "paragraph ",
        MarkupMode::Style.options(),
        &pulldown_cmark::paged::BlockCarry::default(),
    )
    .expect("actual root paragraph");
    let mut literal = seed.run_stream();
    assert_eq!(
        literal.feed("paragraph !", false, &mut || false)?.stopped,
        None
    );
    assert!(literal.feed(" ordinary!", true, &mut || false)?.complete);
    let mut image = seed.run_stream();
    assert_eq!(
        image.feed("paragraph !", false, &mut || false)?.stopped,
        None
    );
    assert_eq!(
        image
            .feed("[still unsupported image]", true, &mut || false)?
            .stopped,
        Some(pulldown_cmark::paged::InlineStop::OtherInlinePass)
    );
    Ok(())
}

#[test]
fn actual_html_block_carry_uses_pinned_terminators_and_real_line_completion() -> TestResult {
    use pulldown_cmark::paged::{HtmlContinuation, probe_blocks};
    let cases = [
        (
            "<PRE>\n",
            "é🙂 **opaque** </PRE>\n**still opaque**\n</pre>\r**also opaque**\n# Outside\n",
        ),
        (
            "<style>\n",
            "é🙂 **opaque**</style> trailing `source`\n# Outside\n",
        ),
        ("<script>\n", "é🙂 **opaque**</script>\r\n# Outside\n"),
        (
            "<textarea>\n",
            "é🙂 **opaque**</textarea> trailing source\n# Outside\n",
        ),
        ("<!--\n", "é🙂 ---still comment--> **opaque**\n# Outside\n"),
        ("<?\n", "é🙂 ?not yet >\n?> **opaque**\n# Outside\n"),
        (
            "<![CDATA[\n",
            "é🙂 ]> **still opaque**\n]]> trailing source\n# Outside\n",
        ),
        ("<!DOCTYPE\n", "é🙂 > **opaque**\n# Outside\n"),
        ("<div>\n", "é🙂 **opaque**\n \t\r\n# Outside\n"),
        ("<widget a='x'>\n", "é🙂 **opaque**\n \t\n# Outside\n"),
    ];
    for (opening, tail) in cases {
        let probe = probe_blocks(opening, MarkupMode::Style.options(), false)
            .expect("actual root first pass");
        assert_eq!(probe.prefix_bytes(), 0);
        let (start, initial) = probe
            .open_html()
            .expect("actual HTML choice, not '<' guessing");
        assert_eq!(start, 0);
        let expected = tail.find("# Outside").expect("real following root");
        for split in tail
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(tail.len()))
        {
            let mut carry = initial.clone();
            let first = carry.consume(&tail[..split], false, &mut || false)?;
            assert!(tail.is_char_boundary(first.consumed));
            let consumed = if first.closed {
                first.consumed
            } else {
                let mut resumed = HtmlContinuation::from_checkpoint(carry.checkpoint())
                    .expect("actual derived checkpoint");
                // A last CR may have been deliberately retained until the
                // actual next byte decides whether it belongs to CRLF.
                let next = resumed.consume(&tail[first.consumed..], true, &mut || false)?;
                assert!(next.closed);
                first.consumed + next.consumed
            };
            assert_eq!(
                consumed, expected,
                "actual ending and complete line for {opening:?}, split={split}"
            );
        }
        let full = format!("{opening}{tail}");
        let parsed = spans(&full)?;
        assert_eq!(
            parsed.iter().filter(|span| span.kind == "heading").count(),
            1
        );
        assert!(
            parsed
                .iter()
                .all(|span| span.kind != "strong" && span.kind != "code")
        );
    }
    assert!(HtmlContinuation::from_checkpoint([9, 0, 0, 0]).is_none());
    assert!(HtmlContinuation::from_checkpoint([0, 1, 0, 0]).is_none());
    assert!(HtmlContinuation::from_checkpoint([1, 6, 0, 0]).is_none());
    assert!(HtmlContinuation::from_checkpoint([1, 0, 1, 1]).is_none());
    Ok(())
}

#[test]
fn actual_long_html_blocks_exclude_markdown_and_media_then_resume_root_grammar() -> TestResult {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let body = format!("authored é🙂 *not emphasis* `not code` [asset](boom-attachment:{id})\n")
        .repeat(1400);
    for (opening, ending) in [
        (
            "<SCRIPT>\n",
            "</SCRIPT>\n**still literal**\n</script> trailing **literal**\n",
        ),
        ("<!--\n", "--> trailing **literal**\n"),
        ("<![CDATA[\n", "]]> trailing **literal**\n"),
        ("<?\n", "?> trailing **literal**\n"),
        ("<!DOCTYPE\n", "> trailing **literal**\n"),
        ("<div>\n", " \t\r\n"),
        ("<widget a='x'>\n", " \t\n"),
    ] {
        let text = format!(
            "# Before\n\n{opening}{body}{ending}# Outside\n\noutside [asset](boom-attachment:{id})\n"
        );
        assert!(text.len() > 3 * pulldown_cmark::paged::PROBE_BYTES && text.len() < TEXT_LIMIT);
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (style, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(style.complete() && !progress.incomplete_block);
        let middle = context(&mut engine, &snapshot, Arc::clone(&style), 32_767, 512)?;
        assert!(middle.complete_blocks && middle.reference_budget_proven);
        assert!(
            paged_spans(&middle)?.is_empty(),
            "HTML literal cannot acquire Code/emphasis/reference styling"
        );
        for anchor in [
            0,
            32_767,
            snapshot.summary().utf16 / 2,
            snapshot.summary().utf16 - 64,
        ] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        let (media, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
        assert!(media.complete() && !progress.incomplete_block);
        assert!(
            paged_media_spans(&context(&mut engine, &snapshot, media, 32_767, 512)?)?.is_empty()
        );
        assert_logical_source_bytes(&mut engine, &snapshot, &text)?;
        assert!(source.capture().same(&snapshot));
    }
    for (opening, ending) in [
        ("<script ", "</script> **still literal**\n"),
        (
            "<script></script> ",
            "**still the SAME physical HTML line**\n",
        ),
        ("<div ", "\n\n"),
    ] {
        let text = format!(
            "{opening}{}{ending}# Outside\n",
            "é🙂 *not emphasis* `not code` ".repeat(4000)
        );
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (style, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(style.complete() && !progress.incomplete_block);
        for anchor in [0, 32_767, snapshot.summary().utf16 - 32] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        assert!(source.capture().same(&snapshot));
    }
    Ok(())
}

#[test]
fn actual_multimegabyte_html_block_has_no_line_buffer_and_edit_undo_keeps_exact_source()
-> TestResult {
    let body = "é🙂 *not emphasis* `not code` [not a link] ".repeat(90_000);
    let text = format!("<script {body}</script> **still HTML**\r\n# Outside\n");
    assert!(text.len() > 3 * 1024 * 1024);
    let closing = text.find("</script>").expect("actual chosen terminator");
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let mut progress = build.progress();
    let mut turns = 0;
    while !progress.complete && turns < 4096 {
        let before = progress.indexed_bytes;
        progress = build.step(&mut engine, &mut || false)?;
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
        assert!(progress.indexed_bytes - before <= pulldown_cmark::paged::PROBE_BYTES as u64);
        turns += 1;
    }
    assert!(progress.complete && !progress.incomplete_block && turns > 96);
    let indexed = build.finish()?;
    assert!(indexed.complete());
    let rows = pages.rows.lock().expect("rows");
    assert_eq!(rows.opener_writes, 0);
    assert_eq!(rows.inline_style_writes, 0);
    assert_eq!(rows.code_writes, 0);
    drop(rows);
    for anchor in [
        0,
        65_535,
        snapshot.summary().utf16 / 2,
        snapshot.summary().utf16 - 32,
    ] {
        assert_large_pinned_parser_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    }
    let at = text[..closing].encode_utf16().count() as u64;
    let window = engine.logical_window(&snapshot, at, 256, &mut || false)?;
    let local = window
        .text()
        .find("</script>")
        .expect("bounded genuine closing tag");
    source.replace_window(&window, local..local + 1, "!")?;
    let changed = source.capture_for_publication()?;
    let current = engine.logical_window(&changed, at, 256, &mut || false)?;
    assert!(matches!(
        MarkupQuery::new(&current, Arc::clone(&indexed)),
        Err(bloom_text::Error::Stale)
    ));
    let (after, progress) = index(&mut engine, &changed, MarkupMode::Style)?;
    assert!(after.complete() && !progress.incomplete_block);
    assert!(
        progress.reused_bytes >= closing.saturating_sub(pulldown_cmark::paged::PROBE_BYTES) as u64,
        "an edit at the actual closer preserves the proved immutable prefix"
    );
    assert!(
        paged_spans(&context(
            &mut engine,
            &changed,
            after,
            changed.summary().utf16,
            256
        )?)?
        .is_empty(),
        "a genuine missing terminator keeps the later heading inside HTML through real EOF"
    );
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &indexed));
    assert_eq!(engine.stats().page_writes, writes);
    assert_logical_source_bytes(&mut engine, &source.capture(), &text)?;
    Ok(())
}

#[test]
fn actual_html_carry_cancellation_and_unresolved_type7_do_not_grant_projection() -> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, InlineRunError, begin_unfinished_html, begin_unfinished_paragraph, probe_blocks,
    };
    let first =
        probe_blocks("<!--\n", MarkupMode::Style.options(), false).expect("actual HTML block");
    let (_, mut carry) = first.open_html().expect("actual chosen comment ending");
    let mut checks = 0;
    assert!(matches!(
        carry.consume(&"é🙂 plain source ".repeat(1000), false, &mut || {
            checks += 1;
            checks == 4
        }),
        Err(InlineRunError::Cancelled)
    ));
    assert!(
        carry.consume("-->\n", true, &mut || false).is_err(),
        "cancelled continuation is terminal"
    );
    let text = format!(
        "<!--\n{}\n-->\n# Outside\n",
        "é🙂 *literal* source\n".repeat(4000)
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    assert!(!build.step(&mut engine, &mut || false)?.complete);
    assert!(matches!(
        build.step(&mut engine, &mut || true),
        Err(bloom_text::Error::Cancelled)
    ));
    assert!(source.capture().same(&snapshot));
    assert_oracle(&text, &mut engine, &snapshot, 32_767, 384)?;

    // Its eventual real first line proves type7, but a 32KiB prefix inside
    // the opening quote has not yet proved HTML7 OR an ordinary paragraph.
    // That bounded prefix stays unproved until the actual resumable opening
    // pass reads the later decision; no fake EOF can publish it first.
    let prefix = format!("<widget title='{}", "é🙂 source ".repeat(3000));
    let mut end = pulldown_cmark::paged::PROBE_BYTES;
    while !prefix.is_char_boundary(end) {
        end -= 1;
    }
    let bounded = &prefix[..end];
    assert!(
        begin_unfinished_html(bounded, MarkupMode::Style.options(), &BlockCarry::default())
            .is_none()
    );
    assert!(
        begin_unfinished_paragraph(bounded, MarkupMode::Style.options(), &BlockCarry::default())
            .is_none()
    );
    let unresolved = format!(
        "{prefix}'>\n**literal HTML** [asset](boom-attachment:884646c1-14b4-490d-be8c-8953af793315)\n\n# Outside\n"
    );
    assert!(
        pulldown_cmark::Parser::new(&unresolved).any(|event| matches!(
            event,
            pulldown_cmark::Event::Start(pulldown_cmark::Tag::HtmlBlock)
        ))
    );
    let (mut other_engine, mut other_source, _) = self::source(&unresolved)?;
    let captured = other_source.capture_for_publication()?;
    let mut pending =
        MarkupIndexBuilder::new(&mut other_engine, captured.clone(), MarkupMode::Style)?;
    let mut progress = pending.step(&mut other_engine, &mut || false)?;
    assert!(!progress.complete && !progress.incomplete_block && progress.indexed_bytes == 0);
    let unknown = pending.captured_index();
    assert!(!unknown.complete());
    let projection = context(&mut other_engine, &captured, unknown, 32_767, 384)?;
    assert!(!projection.complete_blocks && !projection.reference_budget_proven);
    assert!(paged_spans(&projection)?.is_empty());
    for _ in 0..4096 {
        if progress.complete {
            break;
        }
        progress = pending.step(&mut other_engine, &mut || false)?;
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
    }
    assert!(progress.complete && !progress.incomplete_block);
    assert!(pending.finish()?.complete());
    assert_oracle(&unresolved, &mut other_engine, &captured, 32_767, 384)?;
    assert!(other_source.capture().same(&captured));
    Ok(())
}

#[test]
fn actual_type7_opening_stream_chooses_pinned_html_or_its_same_root_paragraph_fallback()
-> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, HtmlBlockWork, HtmlOpeningChoice, HtmlOpeningStatus, InlineRunError,
        begin_unfinished_html_work,
    };
    let plain = "ordinary é🙂 source ".repeat(4000);
    let spaces = " ".repeat(70_000);
    let cases = [
        (
            format!("<widget title='{plain}'>\n**opaque**\n\n# Outside\n"),
            true,
        ),
        (
            format!("</widget{spaces}>\n**opaque**\n\n# Outside\n"),
            true,
        ),
        (format!("<widget>{spaces}\n**opaque**\n\n# Outside\n"), true),
        (format!("<widget title='{plain}'>"), true),
        (format!("<widget>{spaces}é **paragraph**\n"), false),
        (
            format!("<widget title='{plain}\ncontinued'> **paragraph**\n"),
            false,
        ),
        (
            format!("<widget title='{plain} **unclosed paragraph**"),
            false,
        ),
    ];
    for (text, expected_html) in cases {
        let mut end = pulldown_cmark::paged::PROBE_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let work = begin_unfinished_html_work(
            &text[..end],
            MarkupMode::Style.options(),
            &BlockCarry::default(),
        )
        .expect("actual first pass admitted a pending type7 choice");
        let HtmlBlockWork::Opening(mut opening) = work else {
            panic!("an unfinished actual line must not be a fixed choice");
        };
        assert_eq!(opening.scanned_bytes(), end as u64);
        let mut turns = 0;
        loop {
            let at = usize::try_from(opening.scanned_bytes())?;
            let mut last = (at + pulldown_cmark::paged::PROBE_BYTES).min(text.len());
            while !text.is_char_boundary(last) {
                last -= 1;
            }
            let step = opening.consume(&text[at..last], last == text.len(), &mut || false)?;
            assert!(text[at..last].is_char_boundary(step.consumed));
            assert_eq!(opening.scanned_bytes(), (at + step.consumed) as u64);
            turns += 1;
            if step.status == HtmlOpeningStatus::Pending {
                assert_eq!(step.consumed, last - at);
                continue;
            }
            assert_eq!(step.status == HtmlOpeningStatus::Html, expected_html);
            match opening.finish()? {
                HtmlOpeningChoice::Html(_) => assert!(expected_html),
                HtmlOpeningChoice::Paragraph(seed) => {
                    assert!(!expected_html);
                    assert_eq!(seed.start(), 0);
                    assert!(seed.containers().is_root());
                }
            }
            break;
        }
        assert!(turns > 0);
        assert_eq!(
            pulldown_cmark::Parser::new(&text).any(|event| matches!(
                event,
                pulldown_cmark::Event::Start(pulldown_cmark::Tag::HtmlBlock)
            )),
            expected_html,
            "the real pinned full first pass, not a supplied expected status, owns this choice"
        );
    }
    let text = format!("<widget title='{plain}'>\n");
    let mut end = pulldown_cmark::paged::PROBE_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let HtmlBlockWork::Opening(mut cancelled) = begin_unfinished_html_work(
        &text[..end],
        MarkupMode::Style.options(),
        &BlockCarry::default(),
    )
    .expect("actual pending opening") else {
        panic!("pending");
    };
    let mut checks = 0;
    let mut cancellation_end = end + 1024;
    while !text.is_char_boundary(cancellation_end) {
        cancellation_end -= 1;
    }
    assert!(matches!(
        cancelled.consume(&text[end..cancellation_end], false, &mut || {
            checks += 1;
            checks == 3
        }),
        Err(InlineRunError::Cancelled)
    ));
    assert!(cancelled.consume("'>\n", true, &mut || false).is_err());
    assert!(cancelled.finish().is_err());
    Ok(())
}

#[test]
fn actual_long_type7_openings_and_rejected_real_line_choices_match_the_full_parser() -> TestResult {
    let plain = "ordinary é🙂 source ".repeat(4000);
    let spaces = " ".repeat(70_000);
    for (case, text) in [
        (
            "preceding-root",
            format!("# Before\n\n<widget title='{plain}'>\n**opaque** `opaque`\n\n# Outside\n"),
        ),
        (
            "closing-tag",
            format!("</widget{spaces}>\n**opaque**\n\n# Outside\n"),
        ),
        (
            "blank-after-tag",
            format!("<widget>{spaces}\n**opaque**\n\n# Outside\n"),
        ),
        ("actual-eof", format!("<widget title='{plain}'>")),
        (
            "nonblank-fallback",
            format!("<widget>{spaces}é **paragraph** `real code`\n\n# Outside\n"),
        ),
        (
            "multiline-fallback",
            format!("<widget title='{plain}\ncontinued'> **paragraph**\n\n# Outside\n"),
        ),
        (
            "unclosed-fallback",
            format!("<widget title='{plain} **unclosed paragraph**"),
        ),
    ] {
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (style, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(
            style.complete() && !progress.incomplete_block,
            "case={case}, indexed_bytes={}, buffered_bytes={}, incomplete={}",
            progress.indexed_bytes,
            progress.buffered_bytes,
            progress.incomplete_block
        );
        for anchor in [
            0,
            32_767,
            snapshot.summary().utf16 / 2,
            snapshot.summary().utf16.saturating_sub(32),
        ] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        if !text.contains('\n') && text.ends_with('>') {
            let end =
                engine.logical_window(&snapshot, snapshot.summary().utf16, 256, &mut || false)?;
            let caret = end.text().len();
            source.replace_window(&end, caret..caret, " é **after EOF**")?;
            let appended = source.capture_for_publication()?;
            let (after, progress) = index(&mut engine, &appended, MarkupMode::Style)?;
            assert!(
                after.complete() && !progress.incomplete_block && progress.reused_bytes == 0,
                "a real appended nonblank invalidates the old distant EOF-only type7 choice"
            );
            assert_oracle(
                &format!("{text} é **after EOF**"),
                &mut engine,
                &appended,
                appended.summary().utf16,
                384,
            )?;
            source.restore(&snapshot)?;
            let writes = engine.stats().page_writes;
            let (restored, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
            assert!(Arc::ptr_eq(&restored, &style));
            assert_eq!(engine.stats().page_writes, writes);
        }
        assert!(source.capture().same(&snapshot));
    }
    Ok(())
}

#[test]
fn actual_distant_type7_decision_edit_invalidates_early_literal_proof_and_undo_reuses_source()
-> TestResult {
    let text = format!(
        "<widget>{}\n**literal HTML**\n\n# Outside\n",
        " ".repeat(3 * 1024 * 1024 + 32)
    );
    let decision = text
        .find('\n')
        .expect("actual distant opening-line decision");
    let (mut engine, mut source, pages) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let baseline_writes = pages.rows.lock().expect("rows").index_write_bytes;
    let mut build = MarkupIndexBuilder::new(&mut engine, snapshot.clone(), MarkupMode::Style)?;
    let mut progress = build.progress();
    let mut pending_turns = 0;
    while progress.indexed_bytes == 0 && pending_turns < 4096 {
        progress = build.step(&mut engine, &mut || false)?;
        assert!(!progress.complete && !progress.incomplete_block);
        assert!(progress.buffered_bytes <= pulldown_cmark::paged::PROBE_BYTES);
        if progress.indexed_bytes == 0 {
            assert_eq!(
                pages.rows.lock().expect("rows").index_write_bytes,
                baseline_writes,
                "pending opening proof owns no speculative tree/archive or literal pages"
            );
        }
        pending_turns += 1;
    }
    assert!(
        pending_turns > 96
            && progress.indexed_bytes > 0
            && progress.indexed_bytes < decision as u64
    );
    let prefix = build.captured_index();
    assert!(!prefix.complete());
    assert!(context(&mut engine, &snapshot, prefix, 128, 128)?.complete_blocks);
    // The real producer is between calls, with no entered callback/IO. Drop
    // that old immutable operation before simulating the new source request.
    drop(build);
    let mut changed_text = text.clone();
    changed_text.replace_range(decision..decision + 1, "X **now paragraph** ordinary ");
    let window = engine.logical_window(&snapshot, decision as u64, 256, &mut || false)?;
    let local = window
        .text()
        .find('\n')
        .expect("actual line decision in bounded window");
    source.replace_window(&window, local..local + 1, "X **now paragraph** ordinary ")?;
    let changed = source.capture_for_publication()?;
    let (after, progress) = index(&mut engine, &changed, MarkupMode::Style)?;
    assert!(
        after.complete() && !progress.incomplete_block && progress.reused_bytes == 0,
        "a partial literal prefix cannot outlive an edit to its distant actual classification dependency"
    );
    let near = context(&mut engine, &changed, after, decision as u64, 256)?;
    assert!(paged_spans(&near)?.iter().any(|span| span.kind == "strong"));
    for anchor in [0, decision as u64, changed.summary().utf16] {
        assert_large_pinned_parser_oracle(&changed_text, &mut engine, &changed, anchor, 384)?;
    }
    source.restore(&snapshot)?;
    let (full_original, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(full_original.complete() && !progress.incomplete_block);
    assert_large_pinned_parser_oracle(&text, &mut engine, &snapshot, decision as u64, 384)?;
    // The completed-index path has the SAME dependency obligation, not just
    // the partial-prefix branch tested above.
    let current = engine.logical_window(&snapshot, decision as u64, 256, &mut || false)?;
    let local = current.text().find('\n').expect("same actual decision");
    source.replace_window(&current, local..local + 1, "X **now paragraph** ordinary ")?;
    let again = source.capture_for_publication()?;
    let (reproved, progress) = index(&mut engine, &again, MarkupMode::Style)?;
    assert!(reproved.complete() && !progress.incomplete_block && progress.reused_bytes == 0);
    assert_large_pinned_parser_oracle(&changed_text, &mut engine, &again, decision as u64, 384)?;
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &full_original));
    assert_eq!(engine.stats().page_writes, writes);
    let mut at = 0;
    while at < text.len() {
        let mut end = (at + 64 * 1024).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        assert_eq!(
            engine
                .logical_read_range(&source.capture(), at as u64..end as u64, &mut || false)?
                .as_slice(),
            &text.as_bytes()[at..end]
        );
        at = end;
    }
    assert!(source.capture().same(&snapshot));
    Ok(())
}

#[test]
fn actual_completed_root_blank_lines_release_long_html_without_inventing_page_eof() -> TestResult {
    use pulldown_cmark::paged::completed_root_blank_prefix;
    for (text, expected) in [
        ("\n \t\r\n<widget", Some(5)),
        ("\rX", Some(1)),
        (" \t\r\n<widget", Some(4)),
        ("\n \t", Some(1)),
        (" \t", None),
        (" \t\r", None),
        ("\r", None),
        ("    <widget>", None),
        ("> \n", None),
        ("\n#", Some(1)),
    ] {
        assert_eq!(
            completed_root_blank_prefix(text),
            expected,
            "real source={text:?}"
        );
    }
    for blank in ["\n", "\r\n", " \t\r\n", "\n \t\n"] {
        let text = format!(
            "# Before\n{blank}<widget title='{}'>\n**opaque** `opaque`\n\n# Outside\n",
            "ordinary é🙂 source ".repeat(4000)
        );
        assert!(text.len() > 2 * pulldown_cmark::paged::PROBE_BYTES);
        let blocks: Vec<_> = Parser::new_ext(&text, MarkupMode::Style.options())
            .filter_map(|event| match event {
                Event::Start(Tag::HtmlBlock) => Some("html"),
                Event::Start(Tag::Heading { .. }) => Some("heading"),
                _ => None,
            })
            .collect();
        assert_eq!(
            blocks,
            vec!["heading", "html", "heading"],
            "actual pinned grammar, blank={blank:?}"
        );
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (style, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(
            style.complete() && !progress.incomplete_block,
            "blank={blank:?}"
        );
        for anchor in [0, 32_767, snapshot.summary().utf16.saturating_sub(32)] {
            assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
        }
        assert_logical_source_bytes(&mut engine, &snapshot, &text)?;
        assert!(source.capture().same(&snapshot));
    }
    Ok(())
}

#[test]
fn actual_indented_type7_root_retains_source_spaces_through_pending_choice_and_paragraph_fallback()
-> TestResult {
    use pulldown_cmark::paged::{
        BlockCarry, HtmlBlockWork, PROBE_BYTES, begin_unfinished_html_work,
    };
    let body = "authored é🙂 *opaque* `opaque` ".repeat(2400);
    for spaces in 0..=3 {
        for (ending, html) in [
            ("\n**literal HTML**\n\n# Outside\n", true),
            ("é **real paragraph** `real code`\n\n# Outside\n", false),
        ] {
            let text = format!("{}<widget title='{body}'>{ending}", " ".repeat(spaces));
            let mut edge = PROBE_BYTES;
            while !text.is_char_boundary(edge) {
                edge -= 1;
            }
            let work = begin_unfinished_html_work(
                &text[..edge],
                MarkupMode::Style.options(),
                &BlockCarry::default(),
            )
            .expect("the actual indented root has one still pending type7 choice");
            let HtmlBlockWork::Opening(opening) = work else {
                panic!("an unfinished quoted tag cannot be a fixed HTML choice");
            };
            assert_eq!(
                opening.scanned_bytes(),
                edge as u64,
                "initial source counters include actual indentation rather than losing it at the tag slice"
            );
            assert_eq!(
                Parser::new(&text).any(|event| matches!(event, Event::Start(Tag::HtmlBlock))),
                html,
                "actual full parser is the root classification precondition"
            );
            let (mut engine, mut source, _) = self::source(&text)?;
            let snapshot = source.capture_for_publication()?;
            let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
            assert!(indexed.complete() && !progress.incomplete_block);
            for anchor in [
                0,
                32_767,
                snapshot.summary().utf16 / 2,
                snapshot.summary().utf16 - 32,
            ] {
                assert_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
            }
            let mut first_bytes = 64;
            while !text.is_char_boundary(first_bytes) {
                first_bytes -= 1;
            }
            assert_eq!(
                engine
                    .logical_read_range(&snapshot, 0..first_bytes as u64, &mut || false)?
                    .as_slice(),
                &text.as_bytes()[..first_bytes]
            );
            assert!(source.capture().same(&snapshot));
        }
    }
    let code = format!("    <widget title='{body}'>\n");
    let mut edge = PROBE_BYTES;
    while !code.is_char_boundary(edge) {
        edge -= 1;
    }
    assert!(
        begin_unfinished_html_work(
            &code[..edge],
            MarkupMode::Style.options(),
            &BlockCarry::default()
        )
        .is_none(),
        "four source spaces remain the real indented-code choice, never an HTML witness"
    );
    assert!(Parser::new(&code).any(|event| matches!(event, Event::Start(Tag::CodeBlock(_)))));
    let text = format!("   <widget>{}", " ".repeat(70_000));
    let (mut engine, mut source, _) = self::source(&text)?;
    let original = source.capture_for_publication()?;
    let (before, progress) = index(&mut engine, &original, MarkupMode::Style)?;
    assert!(before.complete() && !progress.incomplete_block);
    let end = engine.logical_window(&original, original.summary().utf16, 256, &mut || false)?;
    let at = end.text().len();
    source.replace_window(&end, at..at, "é **after actual EOF**")?;
    let appended = source.capture_for_publication()?;
    let (after, progress) = index(&mut engine, &appended, MarkupMode::Style)?;
    assert!(after.complete() && !progress.incomplete_block && progress.reused_bytes == 0);
    assert_oracle(
        &format!("{text}é **after actual EOF**"),
        &mut engine,
        &appended,
        appended.summary().utf16,
        384,
    )?;
    source.restore(&original)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &before));
    assert_eq!(engine.stats().page_writes, writes);
    assert!(source.capture().same(&original));
    Ok(())
}

#[test]
fn actual_bounded_inline_subtree_uses_pinned_image_exception_and_child_emphasis_scope() -> TestResult
{
    use pulldown_cmark::paged::probe_inline_link;
    for (node, image) in [
        ("[**é🙂** *inner*](https://unit.test/a(b)c 'title')", false),
        (
            "![outer [*inside*](https://inside.test)](https://image.test \"caption\")",
            true,
        ),
        (
            "[outer ![**alt**](https://image.test)](https://outer.test)",
            false,
        ),
        (
            "[multi\n  *line*](https://unit.test\n  'actual\n  title')",
            false,
        ),
        ("[]()", false),
        ("![]()", true),
    ] {
        let input = format!("{node} trailing [unknown]");
        let proof = probe_inline_link(&input, MarkupMode::Style.options(), &mut || false)?
            .expect("actual complete inline node, independent of the later reference");
        assert_eq!(proof.end(), node.len());
        assert_eq!(proof.is_image(), image);
        let wrapped = format!("prefix {node} suffix");
        let first = "prefix ".encode_utf16().count();
        let expected = clipped(
            &spans(&wrapped)?,
            first,
            first + node.encode_utf16().count(),
        );
        let parser = Parser::new_inline_fragment(node, MarkupMode::Style.options())
            .expect("bounded exact inline source");
        assert_eq!(
            coverage(spans_from_parser(node, parser)?),
            coverage(expected)
        );
    }
    let invalid = "[outer [inside](https://inside.test)](https://outer.test)";
    assert!(
        probe_inline_link(invalid, MarkupMode::Style.options(), &mut || false)?.is_none(),
        "an accepted inner Link disables the earlier outer Link; no outer subtree can be invented"
    );
    let links: Vec<_> = Parser::new(invalid)
        .into_offset_iter()
        .filter_map(|(event, range)| {
            matches!(event, Event::Start(Tag::Link { .. })).then_some(range)
        })
        .collect();
    assert_eq!(links.len(), 1);
    assert!(links[0].start > 0);
    Ok(())
}

#[test]
fn actual_long_paragraph_link_children_and_many_tiny_subtrees_match_the_full_parser() -> TestResult
{
    let text = format!(
        "ordinary {} **outer [*child*](https://unit.test/a(b)c 'title') after** ![outer [**inside**](https://inside.test)](https://image.test) [outer ![*alt*](https://image.test)](https://outer.test)\n\n# Outside\n",
        "authored é🙂 body ".repeat(5000)
    );
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let target = text.find("**outer").expect("actual outer delimiter");
    let anchor = text[..target].encode_utf16().count() as u64;
    for at in [0, 32_767, anchor, snapshot.summary().utf16] {
        assert_oracle(&text, &mut engine, &snapshot, at, 384)?;
    }
    let (indexed, _) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    let view = context(&mut engine, &snapshot, indexed, anchor, 384)?;
    assert!(
        view.fragments
            .iter()
            .any(|fragment| fragment.inline_only && fragment.inline_ready)
    );
    let rows = paged_spans(&view)?;
    assert!(rows.iter().any(|span| span.kind == "strong"));
    assert!(rows.iter().any(|span| span.kind == "emphasis"));
    assert!(rows.iter().any(|span| span.kind == "link"));
    assert!(source.capture().same(&snapshot));
    // A large paragraph with512 adjacent short links must use bounded small
    // prefix probes, not serialize/reparse its complete32KiB tail per link.
    // This is a functional work-shape control, not a timing acceptance claim.
    let tiny = format!(
        "{}{} tail",
        "plain Unicode é🙂 ".repeat(2400),
        "[x](u) ".repeat(512)
    );
    let (mut engine, mut source, _) = self::source(&tiny)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    let anchor = tiny[..tiny.find("[x]").expect("actual tiny link start")]
        .encode_utf16()
        .count() as u64;
    assert_oracle(
        &tiny,
        &mut engine,
        &snapshot,
        anchor,
        bloom_text::NATIVE_WINDOW_BYTES,
    )?;
    Ok(())
}

#[test]
fn actual_multimegabyte_inline_media_subtree_edit_and_logical_undo_keep_exact_source_and_ranges()
-> TestResult {
    let old = "884646c1-14b4-490d-be8c-8953af793315";
    let new = "adfcd7f6-e0c9-4d06-a75c-f64794d7760b";
    let inline = format!("![**original**](boom-attachment:{old} 'title')");
    let text = format!("{} {inline} **outside**", "authored é🙂 ".repeat(250_000));
    assert!(text.len() > 3 * 1024 * 1024);
    let target = text.find(&inline).expect("actual media syntax");
    let anchor = text[..target].encode_utf16().count() as u64;
    let (mut engine, mut source, _) = self::source(&text)?;
    let snapshot = source.capture_for_publication()?;
    let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
    assert!(indexed.complete() && !progress.incomplete_block);
    let view = context(&mut engine, &snapshot, Arc::clone(&indexed), anchor, 256)?;
    let media = paged_media_spans(&view)?;
    assert_eq!(media.len(), 1);
    assert_eq!(media[0].id.to_string(), old);
    assert_eq!(media[0].location as u64 + view.window_start.utf16, anchor);
    assert_eq!(media[0].length, inline.encode_utf16().count());
    assert_large_pinned_parser_oracle(&text, &mut engine, &snapshot, anchor, 384)?;
    let window = engine.logical_window(&snapshot, anchor, 256, &mut || false)?;
    let local = window
        .text()
        .find(old)
        .expect("actual original id in exact source window");
    source.replace_window(&window, local..local + old.len(), new)?;
    let edited = source.capture_for_publication()?;
    let (after, progress) = index(&mut engine, &edited, MarkupMode::Media)?;
    assert!(after.complete() && !progress.incomplete_block);
    let media = paged_media_spans(&context(&mut engine, &edited, after, anchor, 256)?)?;
    assert_eq!(media.len(), 1);
    assert_eq!(media[0].id.to_string(), new);
    assert_large_pinned_parser_oracle(
        &text.replacen(old, new, 1),
        &mut engine,
        &edited,
        anchor,
        384,
    )?;
    source.restore(&snapshot)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Media)?;
    assert!(Arc::ptr_eq(&restored, &indexed));
    assert_eq!(engine.stats().page_writes, writes);
    let mut at = 0;
    while at < text.len() {
        let mut end = (at + 64 * 1024).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        assert_eq!(
            engine
                .logical_read_range(&source.capture(), at as u64..end as u64, &mut || false)?
                .as_slice(),
            &text.as_bytes()[at..end]
        );
        at = end;
    }
    Ok(())
}

#[test]
fn actual_unproved_reference_code_or_outer_link_never_becomes_a_completed_inline_subtree()
-> TestResult {
    use pulldown_cmark::paged::{InlineRunError, probe_inline_link};
    for node in [
        "[outer [missing]](https://unit.test)",
        "![outer [missing]](https://image.test)",
        "[outer [inner](https://inner.test)](https://outer.test)",
        "[unclosed `code](https://unit.test)",
        "[unclosed <tag](https://unit.test)",
        "[title](https://unit.test 'unclosed)",
    ] {
        assert!(probe_inline_link(node, MarkupMode::Style.options(), &mut || false)?.is_none());
        let text = format!("{} {node} later `\n\n# Outside\n", "plain ".repeat(7000));
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(!indexed.complete() && progress.incomplete_block);
        let view = context(
            &mut engine,
            &snapshot,
            indexed,
            snapshot.summary().utf16 / 2,
            256,
        )?;
        assert!(!view.complete_blocks);
        assert!(!view.reference_budget_proven);
        assert!(paged_spans(&view)?.is_empty());
        let (media, progress) = index(&mut engine, &snapshot, MarkupMode::Media)?;
        assert!(!media.complete() && progress.incomplete_block);
        assert!(
            paged_media_spans(&context(
                &mut engine,
                &snapshot,
                media,
                snapshot.summary().utf16 / 2,
                256
            )?)?
            .is_empty()
        );
        assert!(source.capture().same(&snapshot));
    }
    assert!(matches!(
        probe_inline_link(
            "[**body**](https://unit.test)",
            MarkupMode::Style.options(),
            &mut || true
        ),
        Err(InlineRunError::Cancelled)
    ));
    Ok(())
}

#[test]
fn actual_closed_code_and_html_children_keep_pinned_inline_precedence() -> TestResult {
    use pulldown_cmark::paged::probe_inline_link;
    for (node, image) in [
        (
            "[body `code ](not-a-link)` **strong**](<https://unit.test/a>)",
            false,
        ),
        (
            "[body <i data-k='v'>é🙂</i> *inner*](https://unit.test)",
            false,
        ),
        (
            "![body <https://inside.test/a> `é🙂`](boom-attachment:884646c1-14b4-490d-be8c-8953af793315 'title')",
            true,
        ),
        (
            "![body <!-- actual comment --> **alt**](https://image.test)",
            true,
        ),
        (r"[escaped \`literal](https://unit.test)", false),
        (
            "[pointy destination](<https://unit.test/a> 'actual title')",
            false,
        ),
    ] {
        let input = format!("{node} unrelated unfinished ` and [missing]");
        let accepted = probe_inline_link(&input, MarkupMode::Style.options(), &mut || false)?
            .expect("closed actual higher-precedence children are independent of later failures");
        assert_eq!(accepted.end(), node.len());
        assert_eq!(accepted.is_image(), image);
        let expected = format!("prefix {node} suffix");
        let first = "prefix ".encode_utf16().count();
        let parser = Parser::new_inline_fragment(node, MarkupMode::Style.options())
            .expect("bounded actual inline operand");
        assert_eq!(
            coverage(spans_from_parser(node, parser)?),
            coverage(clipped(
                &spans(&expected)?,
                first,
                first + node.encode_utf16().count()
            ))
        );
        let text = format!(
            "{} {node} **outside**\n\n# Actual block\n",
            "authored é🙂 ".repeat(4000)
        );
        let anchor = text[..text.find(node).expect("actual node")]
            .encode_utf16()
            .count() as u64;
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
        assert!(source.capture().same(&snapshot));
    }
    let node = "[body `closed` <i>é🙂</i> **strong**](https://unit.test)";
    let text = format!("{} {node} tail", "plain ".repeat(7000));
    let anchor = text[..text.find(node).expect("real node")]
        .encode_utf16()
        .count() as u64;
    let (mut engine, mut source, _) = self::source(&text)?;
    let original = source.capture_for_publication()?;
    let (before, _) = index(&mut engine, &original, MarkupMode::Style)?;
    assert!(before.complete());
    let window = engine.logical_window(&original, anchor, 512, &mut || false)?;
    let closing = window.text().find("`closed`").expect("real child") + "`closed".len();
    source.replace_window(&window, closing..closing + 1, "")?;
    let changed = source.capture_for_publication()?;
    let (after, progress) = index(&mut engine, &changed, MarkupMode::Style)?;
    assert!(
        !after.complete() && progress.incomplete_block,
        "removing the real child closer cannot preserve its old accepted subtree"
    );
    source.restore(&original)?;
    let writes = engine.stats().page_writes;
    let (restored, _) = index(&mut engine, &source.capture(), MarkupMode::Style)?;
    assert!(Arc::ptr_eq(&restored, &before));
    assert_eq!(engine.stats().page_writes, writes);
    assert_oracle(&text, &mut engine, &source.capture(), anchor, 512)?;
    Ok(())
}

#[test]
fn actual_far_code_or_html_close_invalidates_the_local_apparent_link() -> TestResult {
    use pulldown_cmark::paged::{InlineRunError, probe_inline_link};
    for (prefix, tail) in [
        ("[unclosed `code](https://unit.test)", " later ` after"),
        (
            "[unclosed <i title='x](https://unit.test)",
            " later'> after",
        ),
    ] {
        let local_links = Parser::new_ext(prefix, MarkupMode::Style.options())
            .filter(|event| matches!(event, Event::Start(Tag::Link { .. })))
            .count();
        assert_eq!(
            local_links, 1,
            "the copied prefix genuinely appears to accept a Link"
        );
        let completed = format!("{prefix}{tail}");
        assert_eq!(
            Parser::new_ext(&completed, MarkupMode::Style.options())
                .filter(|event| matches!(event, Event::Start(Tag::Link { .. })))
                .count(),
            0,
            "the actual later higher-precedence close consumes the apparent bracket"
        );
        assert!(probe_inline_link(prefix, MarkupMode::Style.options(), &mut || false)?.is_none());
        assert!(
            probe_inline_link(&completed, MarkupMode::Style.options(), &mut || false)?.is_none()
        );
        let text = format!(
            "{} {completed}\n\n# Actual block\n",
            "plain é🙂 ".repeat(4000)
        );
        let (mut engine, mut source, _) = self::source(&text)?;
        let snapshot = source.capture_for_publication()?;
        let (indexed, progress) = index(&mut engine, &snapshot, MarkupMode::Style)?;
        assert!(!indexed.complete() && progress.incomplete_block);
        assert!(source.capture().same(&snapshot));
    }
    assert!(matches!(
        probe_inline_link(
            "[body `closed`](<https://unit.test>)",
            MarkupMode::Style.options(),
            &mut || true
        ),
        Err(InlineRunError::Cancelled)
    ));
    Ok(())
}

#[test]
fn actual_image_adjacency_never_crosses_a_physical_paragraph_continuation() -> TestResult {
    for ending in ["\n", "\r\n"] {
        for indentation in ["", " ", "   "] {
            let text = format!(
                "{} !{ending}{indentation}[**body é🙂**](https://unit.test) tail\n\n# Actual block\n",
                "plain ".repeat(7000)
            );
            let parsed: Vec<_> = Parser::new_ext(&text, MarkupMode::Style.options())
                .into_offset_iter()
                .filter_map(|(event, range)| match event {
                    Event::Start(Tag::Link { .. }) => Some((false, range)),
                    Event::Start(Tag::Image { .. }) => Some((true, range)),
                    _ => None,
                })
                .collect();
            assert_eq!(parsed.len(), 1);
            assert!(
                !parsed[0].0,
                "the actual first pass has no MaybeImage spanning a line ending"
            );
            assert_eq!(
                &text[parsed[0].1.clone()],
                "[**body é🙂**](https://unit.test)"
            );
            let anchor = text[..parsed[0].1.start].encode_utf16().count() as u64;
            let (mut engine, mut source, _) = self::source(&text)?;
            let snapshot = source.capture_for_publication()?;
            assert_oracle(&text, &mut engine, &snapshot, anchor, 512)?;
            assert!(source.capture().same(&snapshot));
        }
    }
    Ok(())
}
