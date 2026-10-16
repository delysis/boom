use super::*;
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom};
use std::path::PathBuf;
use unicode_segmentation::UnicodeSegmentation;

#[path = "logical_tests.rs"]
mod logical_controls;

struct Row {
    owner: Uuid,
    document: Uuid,
    kind: PageKind,
    bytes: Vec<u8>,
}
// Bounded in-memory page provider for structural controls.
struct MemoryPages {
    store: Uuid,
    rows: BTreeMap<u64, Row>,
}
impl MemoryPages {
    fn new() -> Self {
        Self {
            store: Uuid::new_v4(),
            rows: BTreeMap::new(),
        }
    }
}
impl PageProvider for MemoryPages {
    fn read(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        page: &PageRef,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>> {
        let row = self
            .rows
            .get(&page.locator.offset)
            .ok_or(Error::Storage("missing test page".into()))?;
        if page.locator.store_id != self.store
            || row.owner != owner
            || row.document != document
            || row.kind != kind
            || row.bytes.len() > maximum_bytes
        {
            return Err(Error::Storage("test page binding".into()));
        }
        Ok(row.bytes.clone())
    }
    fn write_new(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        bytes: &[u8],
    ) -> Result<PageLocator> {
        let offset = self.rows.len() as u64 * (TEXT_PAGE_BYTES as u64 + 64);
        let locator = PageLocator {
            storage: FileStorage::V1,
            store_id: self.store,
            offset,
            bytes: bytes.len() as u32,
        };
        self.rows.insert(
            offset,
            Row {
                owner,
                document,
                kind,
                bytes: bytes.to_vec(),
            },
        );
        Ok(locator)
    }
}
fn small(text: &str) -> Result<(TextEngine<MemoryPages>, Document)> {
    let mut engine = TextEngine::with_cache_budget(MemoryPages::new(), 128 * 1024);
    let imported = engine.import_utf8(
        Uuid::new_v4(),
        Uuid::new_v4(),
        &mut Cursor::new(text),
        &mut || false,
    )?;
    assert_eq!(imported.whole_text_sha256, digest(text.as_bytes()));
    Ok((engine, imported.document))
}
fn contents<S: PageProvider>(engine: &mut TextEngine<S>, document: &Document) -> Result<String> {
    let mut bytes = Vec::new();
    engine.export(document, document.revision(), &mut bytes, &mut || false)?;
    String::from_utf8(bytes).map_err(|_| Error::Invalid("test export UTF8"))
}

struct SteppedReader<'a> {
    bytes: &'a [u8],
    at: usize,
    calls: usize,
}
impl Read for SteppedReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        let limit = [1, 2, 3, 4096][self.calls % 4];
        self.calls += 1;
        let count = (self.bytes.len() - self.at).min(output.len()).min(limit);
        output[..count].copy_from_slice(&self.bytes[self.at..self.at + count]);
        self.at += count;
        Ok(count)
    }
}
struct SteppedWriter {
    bytes: Vec<u8>,
    calls: usize,
}
impl Write for SteppedWriter {
    fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
        self.calls += 1;
        let count = input.len().min(317);
        self.bytes.extend_from_slice(&input[..count]);
        Ok(count)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
struct CountingReader<R> {
    reader: R,
    calls: usize,
}
impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        self.calls += 1;
        self.reader.read(output)
    }
}
struct RejectedStream {
    failure: Option<std::io::ErrorKind>,
    calls: usize,
}
impl Read for RejectedStream {
    fn read(&mut self, _output: &mut [u8]) -> std::io::Result<usize> {
        self.calls += 1;
        Err(std::io::Error::new(
            self.failure.unwrap_or(std::io::ErrorKind::Other),
            "Public read fixture rejected",
        ))
    }
}
impl Write for RejectedStream {
    fn write(&mut self, _input: &[u8]) -> std::io::Result<usize> {
        self.calls += 1;
        match self.failure {
            Some(kind) => Err(std::io::Error::new(kind, "Public write fixture rejected")),
            None => Ok(0),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn exact_neutral_replacements_preserve_root_and_byte_positions_reject_partial_scalars() -> Result<()>
{
    let text = "a🙂e\u{301}é\r\n";
    let (mut engine, mut document) = small(text)?;
    let original = document.revision().clone();
    let writes = engine.stats().page_writes;
    assert_eq!(
        engine.splice(
            &mut document,
            &original,
            1..5,
            Some("🙂".as_bytes()),
            "🙂",
            &mut || false
        )?,
        original
    );
    assert_eq!(
        engine.splice(&mut document, &original, 1..5, None, "🙂", &mut || false)?,
        original
    );
    assert_eq!(engine.stats().page_writes, writes);
    for offset in 0..=text.len() {
        let result = engine.byte_position(&document, &original, offset as u64);
        if text.is_char_boundary(offset) {
            assert_eq!(result?, TextSummary::of(&text[..offset]));
        } else {
            assert!(result.is_err(), "partial scalar at {offset}");
        }
    }
    assert!(matches!(
        engine.splice(
            &mut document,
            &original,
            1..5,
            Some(b"wrong"),
            "🙂",
            &mut || false
        ),
        Err(Error::Stale)
    ));
    assert_eq!(document.revision(), &original);
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn explicit_large_user_replacement_visits_only_boundary_paths_and_keeps_original_root() -> Result<()>
{
    let pattern = "a🙂\n".as_bytes().to_vec();
    let size = ((48 * TEXT_PAGE_BYTES) / pattern.len() * pattern.len()) as u64;
    let mut engine = TextEngine::with_cache_budget(MemoryPages::new(), 96 * 1024);
    let original = engine
        .import_utf8(
            Uuid::new_v4(),
            Uuid::new_v4(),
            &mut Repeated {
                pattern: pattern.clone(),
                position: 0,
                remaining: size,
            },
            &mut || false,
        )?
        .document;
    let revision = original.revision().clone();
    let mut edited = engine.open(revision.clone())?;
    let reads = engine.stats().page_reads;
    let changed = engine.splice(
        &mut edited,
        &revision,
        pattern.len() as u64..size - pattern.len() as u64,
        None,
        "Xé",
        &mut || false,
    )?;
    assert!(
        engine.stats().page_reads - reads < 24,
        "large replacement must not scan deleted text"
    );
    assert_eq!(contents(&mut engine, &edited)?, "a🙂\nXéa🙂\n");
    assert_eq!(
        engine.byte_position(&edited, &changed, 9)?,
        TextSummary::of("a🙂\nXé")
    );
    engine.checkout(&mut edited, &changed, revision.clone())?;
    assert_eq!(edited.summary().bytes, size);
    assert_eq!(
        engine
            .window(&edited, &revision, size - pattern.len() as u64, 16)?
            .text
            .as_bytes(),
        pattern
    );
    assert!(engine.stats().charged_bytes <= 96 * 1024);
    Ok(())
}

#[test]
fn stepped_import_finalizes_multiple_leaves_before_constant_work_finish() -> Result<()> {
    // A small input that crosses a leaf boundary. It is generated and
    // checked as a stream, without an additional whole-source string buffer.
    let size = (FANOUT * TEXT_PAGE_BYTES + 17) as u64;
    let pattern = b"abc".to_vec();
    let mut reader = CountingReader {
        reader: Repeated {
            pattern: pattern.clone(),
            position: 0,
            remaining: size,
        },
        calls: 0,
    };
    let mut engine = TextEngine::new(MemoryPages::new());
    let owner = Uuid::new_v4();
    let doc = Uuid::new_v4();
    let id = engine.import_begin(owner, doc, size)?;
    let mut complete = false;
    let mut finalization_steps = 0;
    for _ in 0..100 {
        let calls = reader.calls;
        let before = engine.stats();
        let progress = engine.import_step(owner, doc, id, &mut reader, &mut || false)?;
        assert!(reader.calls - calls <= 1);
        assert!(engine.stats().page_writes - before.page_writes <= u64::from(MAX_HEIGHT) + 2);
        if reader.calls == calls {
            finalization_steps += 1;
        }
        if progress.complete {
            complete = true;
            break;
        }
    }
    assert!(complete);
    assert_eq!(
        reader.calls,
        size.div_ceil(TEXT_PAGE_BYTES as u64) as usize + 1,
        "Final EOF must be read even at the exact extent"
    );
    assert!(
        finalization_steps >= 2,
        "A ready result includes the final leaf and branch, not unfinished work"
    );
    let before = engine.stats();
    let calls = reader.calls;
    assert!(
        engine
            .import_step(owner, doc, id, &mut reader, &mut || false)?
            .complete
    );
    assert_eq!(reader.calls, calls);
    let imported = engine.import_finish(owner, doc, id, &mut || false)?;
    let after = engine.stats();
    assert_eq!(
        (after.page_reads, after.page_writes, after.cache_hits),
        (before.page_reads, before.page_writes, before.cache_hits),
        "Ready step and finish perform no page I/O"
    );
    assert_eq!(
        imported
            .document
            .revision()
            .root
            .as_ref()
            .map(|root| root.height),
        Some(1)
    );
    assert_eq!(imported.document.summary().bytes, size);
    let mut checked = PatternOutput {
        pattern,
        position: 0,
        hash: Sha256::new(),
    };
    let revision = imported.document.revision().clone();
    let export = engine.export_begin(revision.clone())?;
    let mut exported = false;
    for _ in 0..200 {
        if engine
            .stream_step(&revision, export, Some(&mut checked), &mut || false)?
            .complete
        {
            exported = true;
            break;
        }
    }
    assert!(exported);
    assert_eq!(checked.position, size);
    let expected = format!("{:x}", checked.hash.finalize());
    assert_eq!(imported.whole_text_sha256, expected);
    assert_eq!(
        engine.stream_finish(&revision, export, &mut || false)?,
        expected
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn bulk_io_failure_zero_write_and_cancellation_discard_owned_state() -> Result<()> {
    let (mut engine, document) = small("abc")?;
    let revision = document.revision().clone();
    let import = engine.import_begin(revision.owner_id, revision.document_id, 3)?;
    let mut rejected = RejectedStream {
        failure: Some(std::io::ErrorKind::BrokenPipe),
        calls: 0,
    };
    assert!(matches!(
        engine.import_step(
            revision.owner_id,
            revision.document_id,
            import,
            &mut rejected,
            &mut || false
        ),
        Err(Error::Io(_))
    ));
    assert_eq!(rejected.calls, 1);
    assert!(matches!(
        engine.import_finish(revision.owner_id, revision.document_id, import, &mut || {
            false
        }),
        Err(Error::Stale)
    ));
    for failure in [Some(std::io::ErrorKind::BrokenPipe), None] {
        let export = engine.export_begin(revision.clone())?;
        let mut writer = RejectedStream { failure, calls: 0 };
        assert!(matches!(
            engine.stream_step(&revision, export, Some(&mut writer), &mut || false),
            Err(Error::Io(_))
        ));
        assert_eq!(writer.calls, 1);
        assert!(matches!(
            engine.stream_finish(&revision, export, &mut || false),
            Err(Error::Stale)
        ));
        assert!(engine.bulk_abort(revision.owner_id, revision.document_id, export)?);
    }
    let missing_writer = engine.export_begin(revision.clone())?;
    assert!(
        engine
            .stream_step(&revision, missing_writer, None, &mut || false)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    let hash = engine.hash_begin(revision.clone())?;
    assert!(matches!(
        engine.stream_step(&revision, hash, None, &mut || true),
        Err(Error::Cancelled)
    ));
    assert!(matches!(
        engine.stream_finish(&revision, hash, &mut || false),
        Err(Error::Stale)
    ));
    // The final result is consumed on cancellation too; no ready root leaks
    // through a cancelled finish, and a subsequent abort is a joined no-op.
    let empty = engine.import_begin(revision.owner_id, revision.document_id, 0)?;
    let mut complete = false;
    for _ in 0..10 {
        if engine
            .import_step(
                revision.owner_id,
                revision.document_id,
                empty,
                &mut Cursor::new([]),
                &mut || false,
            )?
            .complete
        {
            complete = true;
            break;
        }
    }
    assert!(complete);
    assert!(matches!(
        engine.import_finish(revision.owner_id, revision.document_id, empty, &mut || true),
        Err(Error::Cancelled)
    ));
    assert!(engine.bulk_abort(revision.owner_id, revision.document_id, empty)?);
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn stepped_import_yields_for_other_document_edits_and_coalesces_short_reads() -> Result<()> {
    let (mut engine, mut other) = small("alpha")?;
    let owner = Uuid::new_v4();
    let document = Uuid::new_v4();
    let source = "Cafe\u{301} é 🙂\r\n".repeat(10_000);
    let id = engine.import_begin(owner, document, source.len() as u64)?;
    let mut reader = SteppedReader {
        bytes: source.as_bytes(),
        at: 0,
        calls: 0,
    };
    let mut previous = BulkProgress {
        processed_bytes: 0,
        validated_bytes: 0,
        complete: false,
    };
    for turn in 0..1000 {
        let calls = reader.calls;
        let writes = engine.stats().page_writes;
        let progress = engine.import_step(owner, document, id, &mut reader, &mut || false)?;
        assert!(
            reader.calls - calls <= 1,
            "Each step borrows at most one read callback"
        );
        assert!(engine.stats().page_writes - writes <= u64::from(MAX_HEIGHT) + 2);
        assert!(progress.processed_bytes >= previous.processed_bytes);
        assert!(progress.processed_bytes - previous.processed_bytes <= TEXT_PAGE_BYTES as u64);
        assert!(progress.validated_bytes >= previous.validated_bytes);
        assert!(progress.validated_bytes <= progress.processed_bytes);
        assert!(progress.processed_bytes - progress.validated_bytes <= 3);
        let expected = other.revision().clone();
        let (old, new) = if turn % 2 == 0 {
            (b"a".as_slice(), "b")
        } else {
            (b"b".as_slice(), "a")
        };
        engine.splice(&mut other, &expected, 0..1, Some(old), new, &mut || false)?;
        let rendered = engine.window(&other, other.revision(), 0, WINDOW_BYTES)?;
        assert_eq!(rendered.text.as_bytes()[0], new.as_bytes()[0]);
        previous = progress;
        if progress.complete {
            break;
        }
    }
    assert!(previous.complete);
    assert_eq!(previous.processed_bytes, source.len() as u64);
    let imported = engine.import_finish(owner, document, id, &mut || false)?;
    assert_eq!(imported.whole_text_sha256, digest(source.as_bytes()));
    assert_eq!(contents(&mut engine, &imported.document)?, source);
    let pages: Vec<_> = engine
        .provider
        .rows
        .values()
        .filter(|row| row.document == document && row.kind == PageKind::Text)
        .collect();
    assert_eq!(
        pages.iter().map(|row| row.bytes.len()).sum::<usize>(),
        source.len()
    );
    assert!(
        pages
            .iter()
            .filter(|row| row.bytes.len() < TEXT_PAGE_BYTES - 3)
            .count()
            <= 1,
        "Short reads must not create tiny text records"
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    assert!(engine.stats().charged_bytes <= CACHE_BYTES);
    Ok(())
}

#[test]
fn bulk_budget_foreign_tokens_cancellation_and_eof_failures_release_exact_session() -> Result<()> {
    let mut engine = TextEngine::new(MemoryPages::new());
    let owner = Uuid::new_v4();
    let doc = Uuid::new_v4();
    let first = engine.import_begin(owner, doc, 0)?;
    let second_doc = Uuid::new_v4();
    let second = engine.import_begin(owner, second_doc, 3)?;
    assert!(engine.import_begin(owner, Uuid::new_v4(), 0).is_err());
    assert!(
        engine
            .import_step(
                Uuid::new_v4(),
                doc,
                first,
                &mut Cursor::new([]),
                &mut || false
            )
            .is_err()
    );
    assert!(engine.bulk_abort(owner, second_doc, first).is_err());
    assert_eq!(engine.active_bulk_operations(), 2);
    assert!(matches!(
        engine.import_step(owner, doc, first, &mut Cursor::new([]), &mut || true),
        Err(Error::Cancelled)
    ));
    assert_eq!(engine.active_bulk_operations(), 1);
    assert!(engine.bulk_abort(owner, doc, first)?);
    let mut short = Cursor::new(b"ab");
    assert!(
        !engine
            .import_step(owner, second_doc, second, &mut short, &mut || false)?
            .complete
    );
    assert!(matches!(
        engine.import_step(owner, second_doc, second, &mut short, &mut || false),
        Err(Error::Stale)
    ));
    assert!(matches!(
        engine.import_finish(owner, second_doc, second, &mut || false),
        Err(Error::Stale)
    ));
    let oversized = engine.import_begin(owner, doc, 0)?;
    assert!(matches!(
        engine.import_step(owner, doc, oversized, &mut Cursor::new(b"x"), &mut || false),
        Err(Error::Stale)
    ));
    let incomplete = engine.import_begin(owner, doc, 2)?;
    let mut unicode = Cursor::new([0xf0, 0x9f]);
    let progress = engine.import_step(owner, doc, incomplete, &mut unicode, &mut || false)?;
    assert_eq!(progress.validated_bytes, 0);
    assert!(
        engine
            .import_step(owner, doc, incomplete, &mut unicode, &mut || false)
            .is_err()
    );
    let premature = engine.import_begin(owner, doc, 1)?;
    assert!(
        engine
            .import_finish(owner, doc, premature, &mut || false)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    assert!(engine.bulk_abort(owner, doc, premature)?);
    // A malformed late suffix leaves its already-written staging
    // records to host GC, but never returns an editable/publishable revision.
    let mut bytes = vec![b'a'; TEXT_PAGE_BYTES];
    bytes.push(0xff);
    let bad = engine.import_begin(owner, doc, bytes.len() as u64)?;
    let mut input = Cursor::new(bytes);
    engine.import_step(owner, doc, bad, &mut input, &mut || false)?;
    assert!(
        engine
            .import_step(owner, doc, bad, &mut input, &mut || false)
            .is_err()
    );
    assert!(
        engine
            .provider
            .rows
            .values()
            .any(|row| row.document == doc && row.kind == PageKind::Text)
    );
    assert!(matches!(
        engine.import_finish(owner, doc, bad, &mut || false),
        Err(Error::Stale)
    ));
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn stepped_hash_export_short_writes_keep_the_captured_revision_during_edits() -> Result<()> {
    let text = "a".to_string() + &"Cafe\u{301} é 🙂\r\n".repeat(10_000);
    let (mut engine, mut document) = small(&text)?;
    let captured = document.revision().clone();
    let hash = engine.hash_begin(captured.clone())?;
    let export = engine.export_begin(captured.clone())?;
    engine.splice(&mut document, &captured, 0..1, Some(b"a"), "b", &mut || {
        false
    })?;
    assert!(matches!(
        engine.stream_step(document.revision(), hash, None, &mut || false),
        Err(Error::Stale)
    ));
    assert!(
        engine
            .bulk_abort(Uuid::new_v4(), captured.document_id, export)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 2);
    let mut writer = SteppedWriter {
        bytes: Vec::new(),
        calls: 0,
    };
    let mut hash_result = None;
    let mut exported = false;
    let mut previous = 0;
    for _ in 0..2000 {
        if hash_result.is_none()
            && engine
                .stream_step(&captured, hash, None, &mut || false)?
                .complete
        {
            hash_result = Some(engine.stream_finish(&captured, hash, &mut || false)?);
        }
        let calls = writer.calls;
        let progress = engine.stream_step(&captured, export, Some(&mut writer), &mut || false)?;
        assert!(writer.calls - calls <= 1);
        assert_eq!(progress.processed_bytes, writer.bytes.len() as u64);
        assert_eq!(progress.validated_bytes, progress.processed_bytes);
        assert!(progress.processed_bytes - previous <= TEXT_PAGE_BYTES as u64);
        previous = progress.processed_bytes;
        if progress.complete {
            exported = true;
            break;
        }
    }
    assert!(exported);
    assert_eq!(writer.bytes, text.as_bytes());
    assert_eq!(hash_result, Some(digest(text.as_bytes())));
    assert_eq!(
        engine.stream_finish(&captured, export, &mut || false)?,
        digest(text.as_bytes())
    );
    assert_eq!(
        engine.window(&document, document.revision(), 0, 1)?.text,
        "b"
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    assert!(engine.bulk_abort(captured.owner_id, captured.document_id, export)?);
    Ok(())
}

#[test]
fn tiny_piece_stream_yields_on_tree_work_before_filling_its_byte_budget() -> Result<()> {
    let mut engine = TextEngine::new(MemoryPages::new());
    let mut revision = Revision {
        schema: 1,
        owner_id: Uuid::new_v4(),
        document_id: Uuid::new_v4(),
        root: None,
    };
    let chunk = engine.write_page(&revision, PageKind::Text, &vec![b'a'; TEXT_PAGE_BYTES])?;
    let piece = Piece {
        chunk,
        start: 0,
        end: 1,
        summary: TextSummary::of("a"),
        paragraphs: None,
    };
    let mut leaves = Vec::new();
    for _ in 0..FANOUT {
        leaves.push(engine.write_node(&revision, Node::Leaf(vec![piece.clone(); FANOUT]), 0)?);
    }
    revision.root = Some(engine.write_node(&revision, Node::Branch(leaves), 1)?);
    let id = engine.hash_begin(revision.clone())?;
    let mut progress = BulkProgress {
        processed_bytes: 0,
        validated_bytes: 0,
        complete: false,
    };
    for step in 0..2000 {
        let before = engine.stats();
        progress = engine.stream_step(&revision, id, None, &mut || false)?;
        let after = engine.stats();
        assert!(
            after.page_reads + after.cache_hits - before.page_reads - before.cache_hits
                <= BULK_STEP_WORK as u64
        );
        if step == 0 {
            assert!(!progress.complete);
            assert!(progress.processed_bytes < revision.summary().bytes);
        }
        if progress.complete {
            break;
        }
    }
    assert!(progress.complete);
    assert_eq!(progress.processed_bytes, (FANOUT * FANOUT) as u64);
    assert_eq!(
        engine.stream_finish(&revision, id, &mut || false)?,
        digest(&vec![b'a'; FANOUT * FANOUT])
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn unicode_positions_windows_and_line_endings_remain_exact() -> Result<()> {
    let text = "Cafe\u{301}\r\nCafé 🙂 👩🏽‍💻\n\n終\0";
    let (mut engine, document) = small(text)?;
    assert_eq!(document.summary(), TextSummary::of(text));
    let window = engine.window(&document, document.revision(), 0, WINDOW_BYTES)?;
    assert_eq!(window.text.as_bytes(), text.as_bytes());
    for byte in text
        .char_indices()
        .map(|(at, _)| at)
        .chain(std::iter::once(text.len()))
    {
        let units = text[..byte].encode_utf16().count() as u64;
        assert_eq!(
            engine.byte_at_utf16(&document, document.revision(), units)?,
            byte as u64
        );
        if byte < text.len() {
            let window =
                engine.window(&document, document.revision(), byte as u64, WINDOW_BYTES)?;
            assert_eq!(window.utf16_start, units);
            assert_eq!(
                window.lf_start,
                text[..byte].bytes().filter(|b| *b == b'\n').count() as u64
            );
            assert_eq!(window.text.as_bytes(), &text.as_bytes()[byte..]);
        }
    }
    let emoji = text.find('🙂').ok_or(Error::Invalid("test emoji"))?;
    let half = text[..emoji].encode_utf16().count() as u64 + 1;
    assert!(matches!(
        engine.byte_at_utf16(&document, document.revision(), half),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        engine.window(&document, document.revision(), emoji as u64 + 1, 20),
        Err(Error::Invalid(_))
    ));
    assert_eq!(
        contents(&mut engine, &document)?.as_bytes(),
        text.as_bytes()
    );
    Ok(())
}

#[test]
fn edits_and_retained_roots_match_a_small_string_oracle() -> Result<()> {
    let (mut engine, mut document) = small("Cafe\u{301} 🙂\r\n")?;
    let original = document.revision().clone();
    let original_text = contents(&mut engine, &document)?;
    let mut oracle = original_text.clone();
    let insertions = ["a", "\n", "\r\n", "é", "e\u{301}", "🙂", "👩🏽‍💻", ""];
    let mut state = 42_u64;
    for turn in 0..160 {
        let boundaries: Vec<_> = oracle
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(oracle.len()))
            .collect();
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let a = boundaries[(state as usize) % boundaries.len()];
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let b = boundaries[(state as usize) % boundaries.len()];
        let start = a.min(b);
        let end = a.max(b);
        let revision = document.revision().clone();
        let inserted = insertions[turn % insertions.len()];
        engine.splice(
            &mut document,
            &revision,
            start as u64..end as u64,
            Some(&oracle.as_bytes()[start..end]),
            inserted,
            &mut || false,
        )?;
        oracle.replace_range(start..end, inserted);
        assert_eq!(
            contents(&mut engine, &document)?.as_bytes(),
            oracle.as_bytes()
        );
        assert_eq!(document.summary(), TextSummary::of(&oracle));
        assert_eq!(
            engine.whole_text_sha256(&document, document.revision(), &mut || false)?,
            digest(oracle.as_bytes())
        );
        assert!(engine.stats().charged_bytes <= 128 * 1024);
    }
    let last = document.revision().clone();
    engine.checkout(&mut document, &last, original)?;
    assert_eq!(
        contents(&mut engine, &document)?.as_bytes(),
        original_text.as_bytes()
    );
    let undo = document.revision().clone();
    engine.checkout(&mut document, &undo, last)?;
    assert_eq!(
        contents(&mut engine, &document)?.as_bytes(),
        oracle.as_bytes()
    );
    Ok(())
}

#[test]
fn stale_wrong_bytes_cancel_and_half_scalar_do_not_publish_edits() -> Result<()> {
    let (mut engine, mut document) = small("Café 🙂")?;
    let before = document.revision().clone();
    assert!(matches!(
        engine.splice(&mut document, &before, 0..1, Some(b"x"), "z", &mut || false),
        Err(Error::Stale)
    ));
    assert!(matches!(
        engine.splice(&mut document, &before, 0..0, Some(b""), "x", &mut || true),
        Err(Error::Cancelled)
    ));
    assert!(matches!(
        engine.splice(&mut document, &before, 4..4, None, "x", &mut || false),
        Err(Error::Invalid(_))
    ));
    assert_eq!(document.revision(), &before);
    engine.splice(&mut document, &before, 0..1, Some(b"C"), "K", &mut || false)?;
    assert!(matches!(
        engine.window(&document, &before, 0, 20),
        Err(Error::Stale)
    ));
    assert!(matches!(
        engine.splice(&mut document, &before, 0..0, None, "x", &mut || false),
        Err(Error::Stale)
    ));
    let current = document.revision().clone();
    let mut foreign = current.clone();
    foreign.document_id = Uuid::new_v4();
    assert!(matches!(
        engine.checkout(&mut document, &current, foreign),
        Err(Error::Invalid(_))
    ));
    assert_eq!(document.revision(), &current);
    Ok(())
}

#[test]
fn chunk_edges_and_unequal_tree_joins_preserve_the_text() -> Result<()> {
    let mut text = "a".repeat(TEXT_PAGE_BYTES - 1);
    text.push_str("🙂\r\n");
    text.push_str(&"b".repeat(TEXT_PAGE_BYTES * (FANOUT + 3)));
    let (mut engine, mut document) = small(&text)?;
    let original = document.revision().clone();
    assert!(
        document
            .revision()
            .root
            .as_ref()
            .is_some_and(|root| root.height >= 1)
    );
    for turn in 0..5 {
        let start = match turn {
            0 => 0,
            1 => TEXT_PAGE_BYTES - 1,
            2 => TEXT_PAGE_BYTES + 5,
            3 => text.len() - 1,
            _ => text.len(),
        };
        assert!(
            text.is_char_boundary(start),
            "The oracle must select a current scalar boundary"
        );
        let before = document.revision().clone();
        engine.splice(
            &mut document,
            &before,
            start as u64..start as u64,
            Some(b""),
            "終",
            &mut || false,
        )?;
        text.insert(start, '終');
        assert_eq!(
            contents(&mut engine, &document)?.as_bytes(),
            text.as_bytes()
        );
    }
    let cut_end = text
        .char_indices()
        .next_back()
        .ok_or(Error::Invalid("test final scalar"))?
        .0;
    assert!(text.is_char_boundary(3) && text.is_char_boundary(cut_end));
    let before = document.revision().clone();
    engine.splice(
        &mut document,
        &before,
        3..cut_end as u64,
        None,
        "",
        &mut || false,
    )?;
    text.replace_range(3..cut_end, "");
    assert_eq!(
        contents(&mut engine, &document)?.as_bytes(),
        text.as_bytes()
    );
    let current = document.revision().clone();
    engine.checkout(&mut document, &current, original)?;
    assert_eq!(
        document.summary().bytes,
        (TEXT_PAGE_BYTES * (FANOUT + 4) + 5) as u64
    );
    Ok(())
}

#[test]
fn missing_corrupt_cross_owner_pages_and_invalid_object_identities_fail_closed() -> Result<()> {
    let (mut engine, document) = small("a public fixture")?;
    let root = document
        .revision()
        .root
        .clone()
        .ok_or(Error::Invalid("test root"))?;
    let mut bad_owner = document.revision().clone();
    bad_owner.owner_id = Uuid::new_v4();
    assert!(matches!(engine.open(bad_owner), Err(Error::Storage(_))));
    let mut bad_identity = document.revision().clone();
    let bad_root = bad_identity
        .root
        .as_mut()
        .ok_or(Error::Invalid("test root"))?;
    bad_root.page.locator.store_id = Uuid::nil();
    assert!(matches!(engine.open(bad_identity), Err(Error::Invalid(_))));
    engine.cache.clear();
    engine.stats.charged_bytes = 0;
    let row = engine
        .provider
        .rows
        .get_mut(&root.page.locator.offset)
        .ok_or(Error::Invalid("test page"))?;
    row.bytes.pop();
    assert!(matches!(
        engine.open(document.revision().clone()),
        Err(Error::Invalid(_))
    ));
    engine.provider.rows.remove(&root.page.locator.offset);
    assert!(matches!(
        engine.open(document.revision().clone()),
        Err(Error::Storage(_))
    ));
    Ok(())
}

#[test]
fn incomplete_utf8_import_and_cancellation_do_not_return_partial_documents() -> Result<()> {
    let mut engine = TextEngine::new(MemoryPages::new());
    assert!(matches!(
        engine.import_utf8(
            Uuid::new_v4(),
            Uuid::new_v4(),
            &mut Cursor::new([b'a', 0xf0, 0x9f]),
            &mut || false
        ),
        Err(Error::Invalid(_))
    ));
    let mut calls = 0;
    assert!(matches!(
        engine.import_utf8(
            Uuid::new_v4(),
            Uuid::new_v4(),
            &mut Cursor::new(vec![b'a'; TEXT_PAGE_BYTES * 4]),
            &mut || {
                calls += 1;
                calls >= 5
            }
        ),
        Err(Error::Cancelled)
    ));
    Ok(())
}

#[test]
fn revision_wire_requires_explicit_root_and_rejects_malformed_empty_roots() -> Result<()> {
    let empty = Revision {
        schema: 1,
        owner_id: Uuid::new_v4(),
        document_id: Uuid::new_v4(),
        root: None,
    };
    let wire =
        serde_json::to_value(&empty).map_err(|_| Error::Invalid("test revision encoding"))?;
    assert_eq!(wire.get("root"), Some(&serde_json::Value::Null));
    let roundtrip: Revision = serde_json::from_value(wire.clone())
        .map_err(|_| Error::Invalid("test revision decoding"))?;
    assert_eq!(roundtrip, empty);
    let mut engine = TextEngine::new(MemoryPages::new());
    let document = engine.open(roundtrip)?;
    assert_eq!(document.summary(), TextSummary::EMPTY);
    assert!(
        engine
            .window(&document, document.revision(), 0, 1)?
            .text
            .is_empty()
    );

    let mut missing = wire.clone();
    missing
        .as_object_mut()
        .ok_or(Error::Invalid("test revision object"))?
        .remove("root");
    assert!(serde_json::from_value::<Revision>(missing).is_err());
    for value in [
        serde_json::json!({}),
        serde_json::json!([]),
        serde_json::json!(""),
    ] {
        let mut malformed = wire.clone();
        malformed["root"] = value;
        assert!(serde_json::from_value::<Revision>(malformed).is_err());
    }
    let (mut engine, document) = small("a")?;
    let mut empty_root = document.revision().clone();
    empty_root
        .root
        .as_mut()
        .ok_or(Error::Invalid("test root"))?
        .summary = TextSummary::EMPTY;
    assert!(matches!(
        engine.open(empty_root),
        Err(Error::Invalid("empty root page"))
    ));
    let mut zero_units = document.revision().clone();
    zero_units
        .root
        .as_mut()
        .ok_or(Error::Invalid("test root"))?
        .summary
        .utf16 = 0;
    assert!(matches!(
        engine.open(zero_units),
        Err(Error::Invalid("inconsistent text summary"))
    ));
    Ok(())
}

#[test]
fn diagnostic_counter_saturation_preserves_operations_and_exact_cache_charges() -> Result<()> {
    let (mut engine, mut document) = small("abc")?;
    engine.stats.page_reads = u64::MAX;
    engine.stats.read_bytes = u64::MAX;
    engine.stats.page_writes = u64::MAX;
    engine.stats.cache_hits = u64::MAX;
    assert_eq!(
        engine.window(&document, document.revision(), 0, 20)?.text,
        "abc"
    );
    let before = document.revision().clone();
    engine.splice(&mut document, &before, 3..3, Some(b""), "終", &mut || {
        false
    })?;
    assert_eq!(
        contents(&mut engine, &document)?.as_bytes(),
        "abc終".as_bytes()
    );
    let stats = engine.stats();
    assert_eq!(
        (
            stats.page_reads,
            stats.read_bytes,
            stats.page_writes,
            stats.cache_hits
        ),
        (u64::MAX, u64::MAX, u64::MAX, u64::MAX)
    );
    let exact_charge: usize = engine
        .cache
        .iter()
        .map(|page| page.bytes.len() + size_of::<CachedPage>() + page.page.digest.len() + 32)
        .sum();
    assert_eq!(stats.charged_bytes, exact_charge);
    assert!(stats.charged_bytes > 0 && stats.charged_bytes <= 128 * 1024);
    Ok(())
}

// Public structural fixture only: plaintext records exercise tree disk paging.
// Physical offsets stay private to this fixture; the exported locator is an
// immutable object ID. The <=131,072-entry fixture index is additional fixture
// memory, not part of the engine cache budget or native memory evidence.
// Failed files remain at their public path; successful isolated fixtures may
// delete only after all assertions. Native publication is checked separately.
struct DiskPages {
    file: Option<File>,
    path: PathBuf,
    store: Uuid,
    next: u64,
    successful: bool,
}
impl DiskPages {
    fn new() -> Result<Self> {
        let path =
            std::env::temp_dir().join(format!("bloom-public-pager-{}.fixture", Uuid::new_v4()));
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)?;
        Ok(Self {
            file: Some(file),
            path,
            store: Uuid::new_v4(),
            next: 0,
            successful: false,
        })
    }
}
impl Drop for DiskPages {
    fn drop(&mut self) {
        drop(self.file.take());
        if self.successful {
            if let Err(error) = std::fs::remove_file(&self.path) {
                eprintln!(
                    "Public pager fixture cleanup failed: {error}; retained at {}",
                    self.path.display()
                );
            }
        } else {
            eprintln!(
                "Failed public pager fixture retained at {}",
                self.path.display()
            );
        }
    }
}
impl PageProvider for DiskPages {
    fn read(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        page: &PageRef,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>> {
        if page.locator.store_id != self.store {
            return Err(Error::Storage("test object store".into()));
        }
        let offset = page.locator.offset;
        let file = self
            .file
            .as_mut()
            .ok_or(Error::Invalid("test file closed"))?;
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0_u8; 64];
        file.read_exact(&mut header)?;
        let length = u32::from_le_bytes(
            header[49..53]
                .try_into()
                .map_err(|_| Error::Invalid("test length"))?,
        ) as usize;
        if header[..16] != owner.as_bytes()[..]
            || header[16..32] != document.as_bytes()[..]
            || header[48] != if kind == PageKind::Text { 0 } else { 1 }
            || length > maximum_bytes
            || page.locator.bytes as usize != length
        {
            return Err(Error::Storage("test frame binding".into()));
        }
        let mut bytes = vec![0; length];
        file.read_exact(&mut bytes)?;
        Ok(bytes)
    }
    fn write_new(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        bytes: &[u8],
    ) -> Result<PageLocator> {
        let offset = self.next;
        let locator = PageLocator {
            storage: FileStorage::V1,
            store_id: self.store,
            offset,
            bytes: bytes.len() as u32,
        };
        let next = offset
            .checked_add(bytes.len() as u64 + 64)
            .ok_or(Error::Invalid("public disk fixture extent"))?;
        let mut header = [0_u8; 64];
        header[..16].copy_from_slice(owner.as_bytes());
        header[16..32].copy_from_slice(document.as_bytes());
        header[48] = if kind == PageKind::Text { 0 } else { 1 };
        header[49..53].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
        let file = self
            .file
            .as_mut()
            .ok_or(Error::Invalid("test file closed"))?;
        file.seek(SeekFrom::Start(self.next))?;
        file.write_all(&header)?;
        file.write_all(bytes)?;
        self.next = next;
        Ok(locator)
    }
}
struct Repeated {
    pattern: Vec<u8>,
    position: u64,
    remaining: u64,
}
impl Read for Repeated {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        let n = self.remaining.min(bytes.len() as u64) as usize;
        for (i, byte) in bytes[..n].iter_mut().enumerate() {
            *byte = self.pattern[((self.position + i as u64) % self.pattern.len() as u64) as usize];
        }
        self.position += n as u64;
        self.remaining -= n as u64;
        Ok(n)
    }
}
struct PatternOutput {
    pattern: Vec<u8>,
    position: u64,
    hash: Sha256,
}
impl Write for PatternOutput {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        for (i, byte) in bytes.iter().enumerate() {
            if *byte
                != self.pattern[((self.position + i as u64) % self.pattern.len() as u64) as usize]
            {
                return Err(std::io::Error::other("streamed fixture bytes differ"));
            }
        }
        self.position += bytes.len() as u64;
        self.hash.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
#[ignore = "Explicit real 1 GiB disk fixture; run after shared native capture joins"]
fn real_gib_single_line_import_seek_export_and_huge_delete_use_bounded_cache() -> Result<()> {
    let mut pattern = "Cafe\u{301} 🙂 終 ".as_bytes().to_vec();
    pattern.resize(32, b'a');
    let size = 1_u64 << 30;
    let mut reader = Repeated {
        pattern: pattern.clone(),
        position: 0,
        remaining: size,
    };
    let mut engine = TextEngine::new(DiskPages::new()?);
    let imported =
        engine.import_utf8(Uuid::new_v4(), Uuid::new_v4(), &mut reader, &mut || false)?;
    let mut document = imported.document;
    assert_eq!(document.summary().bytes, size);
    assert_eq!(document.summary().lf_count, 0);
    assert!(engine.stats().charged_bytes <= CACHE_BYTES);
    let original = document.revision().clone();
    let reads = engine.stats().page_reads;
    let window = engine.window(
        &document,
        &original,
        size - WINDOW_BYTES as u64,
        WINDOW_BYTES,
    )?;
    assert_eq!(window.text.len(), WINDOW_BYTES);
    assert!(
        engine.stats().page_reads - reads < 16,
        "Seek must not read the whole tree or source"
    );
    let mut output = PatternOutput {
        pattern,
        position: 0,
        hash: Sha256::new(),
    };
    engine.export(&document, &original, &mut output, &mut || false)?;
    assert_eq!(output.position, size);
    assert_eq!(
        format!("{:x}", output.hash.finalize()),
        imported.whole_text_sha256
    );
    let reads = engine.stats().page_reads;
    engine.splice(
        &mut document,
        &original,
        TEXT_PAGE_BYTES as u64..size - TEXT_PAGE_BYTES as u64,
        None,
        "",
        &mut || false,
    )?;
    assert_eq!(document.summary().bytes, 2 * TEXT_PAGE_BYTES as u64);
    assert!(
        engine.stats().page_reads - reads < 32,
        "Large deletion must skip untouched subtrees"
    );
    assert!(engine.stats().charged_bytes <= CACHE_BYTES);
    let after = document.revision().clone();
    engine.checkout(&mut document, &after, original)?;
    assert_eq!(document.summary().bytes, size);
    eprintln!(
        "Real GiB pager fixture complete: cache={} bytes, entries={}, page_reads={}",
        engine.stats().charged_bytes,
        engine.stats().entries,
        engine.stats().page_reads
    );
    engine.provider.successful = true;
    Ok(())
}

// Wire and extent controls before provider IO.
#[test]
fn file_page_locator_rejects_mixed_missing_and_unknown_fields() -> Result<()> {
    let store = Uuid::new_v4();
    let valid = serde_json::json!({"storage":"file_v1","storeId":store,"offset":0,"bytes":16});
    let locator: PageLocator =
        serde_json::from_value(valid.clone()).map_err(|_| Error::Invalid("locator fixture"))?;
    assert_eq!(locator.store_id, store);
    assert_eq!(locator.offset, 0);
    assert_eq!(
        serde_json::to_value(locator).map_err(|_| Error::Invalid("locator encoding"))?,
        valid
    );
    let mut mixed = valid.clone();
    mixed["recordId"] = serde_json::json!(Uuid::new_v4());
    let mut unknown_marker = valid.clone();
    unknown_marker["storage"] = serde_json::json!("sqlite_v1");
    let mut missing = valid.clone();
    missing
        .as_object_mut()
        .ok_or(Error::Invalid("object fixture"))?
        .remove("storeId");
    for malformed in [mixed, unknown_marker, missing] {
        assert!(serde_json::from_value::<PageLocator>(malformed).is_err());
    }
    Ok(())
}
#[test]
fn file_page_extent_and_store_substitution_fail_before_source_admission() -> Result<()> {
    let (mut engine, document) = small("public file identity")?;
    let original = document.revision().clone();
    let root = original.root.clone().ok_or(Error::Invalid("file root"))?;
    for (store_id, offset, bytes) in [
        (
            Uuid::nil(),
            root.page.locator.offset,
            root.page.locator.bytes,
        ),
        (
            root.page.locator.store_id,
            u64::MAX,
            root.page.locator.bytes,
        ),
        (
            root.page.locator.store_id,
            root.page.locator.offset,
            INDEX_PAGE_BYTES as u32 + 1,
        ),
    ] {
        let mut altered = original.clone();
        let page = &mut altered
            .root
            .as_mut()
            .ok_or(Error::Invalid("file root"))?
            .page;
        page.locator.store_id = store_id;
        page.locator.offset = offset;
        page.locator.bytes = bytes;
        assert!(matches!(engine.open(altered), Err(Error::Invalid(_))));
    }
    let mut foreign = original.clone();
    foreign
        .root
        .as_mut()
        .ok_or(Error::Invalid("file root"))?
        .page
        .locator
        .store_id = Uuid::new_v4();
    assert!(matches!(engine.open(foreign), Err(Error::Storage(_))));
    assert_eq!(contents(&mut engine, &document)?, "public file identity");
    Ok(())
}

#[test]
fn prefix_windows_end_at_every_exact_unicode_caret_with_bounded_origins() -> Result<()> {
    let source = "head\n".repeat(1000) + "é🙂中e\u{301} tail";
    let (mut engine, document) = small(&source)?;
    let revision = document.revision().clone();
    let mut caret = 0u64;
    for (byte, scalar) in source.char_indices() {
        let window = engine.prefix_window(&document, &revision, caret, 64)?;
        assert!(window.text.len() <= 64);
        assert_eq!(window.byte_start + window.text.len() as u64, byte as u64);
        assert_eq!(
            window.utf16_start + window.text.encode_utf16().count() as u64,
            caret
        );
        assert!(source[..byte].ends_with(&window.text));
        if scalar.len_utf16() == 2 {
            assert!(matches!(
                engine.prefix_window(&document, &revision, caret + 1, 64),
                Err(Error::Invalid(_))
            ));
        }
        caret += scalar.len_utf16() as u64;
    }
    let tail = engine.prefix_window(&document, &revision, caret, 64)?;
    assert_eq!(
        tail.byte_start + tail.text.len() as u64,
        source.len() as u64
    );
    Ok(())
}

#[test]
fn cold_page_children_exposes_only_bounded_authenticated_direct_refs() -> Result<()> {
    let source = "x".repeat(TEXT_PAGE_BYTES * (FANOUT + 1));
    let (mut engine, document) = small(&source)?;
    let writes = engine.stats().page_writes;
    let revision = document.revision().clone();
    let mut stack = vec![revision.root.clone().ok_or(Error::Invalid("test root"))?];
    let mut chunks = BTreeMap::new();
    while let Some(node) = stack.pop() {
        let refs = engine.page_children(&revision, &node)?;
        assert!(refs.children.len() <= FANOUT && refs.text_pages.len() <= FANOUT);
        if node.height == 0 {
            assert!(refs.children.is_empty());
            assert!(!refs.text_pages.is_empty());
        } else {
            assert!(refs.text_pages.is_empty());
            assert!(!refs.children.is_empty());
            assert!(
                refs.children
                    .iter()
                    .all(|child| child.height + 1 == node.height)
            );
        }
        for page in refs.text_pages {
            let bytes = &engine.provider.rows[&page.locator.offset].bytes;
            assert_eq!(page.digest, digest(bytes));
            assert_eq!(bytes.len(), page.locator.bytes as usize);
            chunks.insert(page.locator.offset, bytes.len());
        }
        stack.extend(refs.children);
    }
    assert_eq!(chunks.len(), FANOUT + 1);
    assert_eq!(chunks.values().sum::<usize>(), source.len());
    assert_eq!(engine.stats().page_writes, writes);
    assert_eq!(contents(&mut engine, &document)?, source);
    Ok(())
}

#[test]
fn cold_page_children_refuses_digest_owner_height_and_summary_corruption() -> Result<()> {
    let mut engine = TextEngine::with_cache_budget(MemoryPages::new(), 0);
    let imported = engine.import_utf8(
        Uuid::new_v4(),
        Uuid::new_v4(),
        &mut Cursor::new("real cold reference"),
        &mut || false,
    )?;
    let revision = imported.document.revision().clone();
    let root = revision.root.clone().ok_or(Error::Invalid("test root"))?;
    let mut bad = root.clone();
    bad.page.digest = "0".repeat(64);
    assert!(engine.page_children(&revision, &bad).is_err());
    bad = root.clone();
    bad.height = 1;
    assert!(engine.page_children(&revision, &bad).is_err());
    bad = root.clone();
    bad.summary.bytes += 1;
    bad.summary.utf16 += 1;
    assert!(engine.page_children(&revision, &bad).is_err());
    let mut foreign = revision.clone();
    foreign.document_id = Uuid::new_v4();
    assert!(engine.page_children(&foreign, &root).is_err());
    let row = engine
        .provider
        .rows
        .get_mut(&root.page.locator.offset)
        .ok_or(Error::Invalid("test page"))?;
    row.bytes[0] ^= 1;
    assert!(engine.page_children(&revision, &root).is_err());
    Ok(())
}

fn sought(
    engine: &mut TextEngine<MemoryPages>,
    revision: &Revision,
    caret: u64,
    forward: bool,
) -> Result<(TextSummary, usize, u64)> {
    let id = engine.grapheme_seek_begin(revision.clone(), caret, forward)?;
    for turns in 1..=10_000 {
        let before = engine.stats();
        let progress = engine.grapheme_seek_step(revision, id, &mut || false)?;
        let after = engine.stats();
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        assert!(after.page_reads - before.page_reads <= u64::from(MAX_HEIGHT) + 2);
        assert!(
            after.read_bytes - before.read_bytes
                <= (TEXT_PAGE_BYTES + INDEX_PAGE_BYTES * (usize::from(MAX_HEIGHT) + 1)) as u64
        );
        assert_eq!(after.page_writes, before.page_writes);
        if progress.complete {
            let point = engine.grapheme_seek_finish(revision, id, &mut || false)?;
            assert_eq!(Some(point), progress.result);
            return Ok((point, turns, progress.examined_bytes));
        }
    }
    Err(Error::Invalid("test seek did not complete"))
}

#[test]
fn source_line_bounds_match_lf_crlf_oracle_at_every_scalar() -> Result<()> {
    for text in [
        "",
        "\n",
        "\r\n",
        "a\nb\n",
        "🙂\r\né",
        "\r\n\r\n\n",
        "a\rb\u{0085}c\u{2028}d\u{2029}e",
    ] {
        let (mut engine, document) = small(text)?;
        let revision = document.revision().clone();
        for byte in text
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(text.len()))
        {
            let caret = TextSummary::of(&text[..byte]);
            let start = text.as_bytes()[..byte]
                .iter()
                .rposition(|b| *b == b'\n')
                .map_or(0, |at| at + 1);
            let ending = text.as_bytes()[byte..]
                .iter()
                .position(|b| *b == b'\n')
                .map(|at| byte + at);
            let mut content = ending.unwrap_or(text.len());
            if ending.is_some() && content > start && text.as_bytes()[content - 1] == b'\r' {
                content -= 1;
            }
            let end = ending.map_or(text.len(), |at| at + 1);
            let actual = engine.line_bounds(&document, &revision, caret.utf16)?;
            assert_eq!(
                actual,
                LineBounds {
                    start: TextSummary::of(&text[..start]),
                    content_end: TextSummary::of(&text[..content]),
                    end: TextSummary::of(&text[..end]),
                    lf_terminated: ending.is_some()
                },
                "caret {byte} in {text:?}"
            );
        }
    }
    Ok(())
}

#[test]
fn source_line_bounds_skip_a_large_line_and_resolve_crlf_across_pages() -> Result<()> {
    // CR is the final byte of the first page; LF is in the following page.
    let mut text = "a".repeat(TEXT_PAGE_BYTES - 1);
    text.push_str("\r\n");
    text.push_str(&"b".repeat(TEXT_PAGE_BYTES * (FANOUT + 1)));
    text.push_str("\r\ntail");
    let (mut engine, document) = small(&text)?;
    engine.cache.clear();
    engine.stats.charged_bytes = 0;
    engine.cache_budget = 0;
    let revision = document.revision().clone();
    let before = engine.stats();
    let middle = (TEXT_PAGE_BYTES * 20) as u64;
    let actual = engine.line_bounds(&document, &revision, middle)?;
    let start = TEXT_PAGE_BYTES + 1;
    let content = start + TEXT_PAGE_BYTES * (FANOUT + 1);
    assert_eq!(actual.start, TextSummary::of(&text[..start]));
    assert_eq!(actual.content_end, TextSummary::of(&text[..content]));
    assert_eq!(actual.end, TextSummary::of(&text[..content + 2]));
    assert!(actual.lf_terminated);
    let after = engine.stats();
    assert!(
        after.read_bytes - before.read_bytes
            < (10 * TEXT_PAGE_BYTES + 20 * INDEX_PAGE_BYTES) as u64
    );
    assert_eq!(after.page_writes, before.page_writes);
    let first = engine.line_bounds(&document, &revision, 1)?;
    assert_eq!(first.content_end.bytes, (TEXT_PAGE_BYTES - 1) as u64);
    assert_eq!(first.end.bytes, (TEXT_PAGE_BYTES + 1) as u64);
    assert_eq!(contents(&mut engine, &document)?, text);
    Ok(())
}

#[test]
fn grapheme_seek_matches_extended_oracle_for_scalar_origins_and_endpoints() -> Result<()> {
    for text in [
        "",
        "a",
        "e\u{301}x",
        "\r\n",
        "🇬🇧🇺🇸🇫",
        "👩\u{200d}👩\u{200d}👧\u{200d}👦!",
        "क्\u{200d}ष!",
        "\u{600}abc",
    ] {
        let (mut engine, document) = small(text)?;
        let revision = document.revision().clone();
        let breaks: Vec<_> = text
            .grapheme_indices(true)
            .map(|(at, _)| at)
            .chain(std::iter::once(text.len()))
            .collect();
        for byte in text
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(text.len()))
        {
            let caret = TextSummary::of(&text[..byte]);
            for forward in [false, true] {
                let expected = if forward {
                    breaks
                        .iter()
                        .copied()
                        .find(|at| *at > byte)
                        .unwrap_or(text.len())
                } else {
                    breaks
                        .iter()
                        .copied()
                        .rev()
                        .find(|at| *at < byte)
                        .unwrap_or(0)
                };
                let (point, _, _) = sought(&mut engine, &revision, caret.utf16, forward)?;
                assert_eq!(
                    point,
                    TextSummary::of(&text[..expected]),
                    "{text:?}, byte {byte}, forward {forward}"
                );
                assert_eq!(engine.active_bulk_operations(), 0);
            }
        }
    }
    Ok(())
}

#[test]
fn grapheme_seek_resolves_nfd_zwj_and_ri_parity_across_real_page_edges() -> Result<()> {
    let samples = vec![
        "a".repeat(TEXT_PAGE_BYTES - 1) + "e\u{301}\u{301}!",
        "a".repeat(TEXT_PAGE_BYTES - 4) + "👩\u{200d}👩\u{200d}👧!",
        "x".to_owned() + &"🇬".repeat(TEXT_PAGE_BYTES / 2 + 3) + "!",
    ];
    for text in samples {
        let (mut engine, document) = small(&text)?;
        let revision = document.revision().clone();
        let breaks: Vec<_> = text
            .grapheme_indices(true)
            .map(|(at, _)| at)
            .chain(std::iter::once(text.len()))
            .collect();
        let near = text
            .char_indices()
            .map(|(at, _)| at)
            .filter(|at| {
                (*at >= TEXT_PAGE_BYTES - 12 && *at <= TEXT_PAGE_BYTES + 28)
                    || *at >= text.len() - 24
            })
            .chain(std::iter::once(text.len()));
        for byte in near {
            let caret = TextSummary::of(&text[..byte]);
            for forward in [false, true] {
                let expected = if forward {
                    breaks
                        .iter()
                        .copied()
                        .find(|at| *at > byte)
                        .unwrap_or(text.len())
                } else {
                    breaks
                        .iter()
                        .copied()
                        .rev()
                        .find(|at| *at < byte)
                        .unwrap_or(0)
                };
                let (point, _, _) = sought(&mut engine, &revision, caret.utf16, forward)?;
                assert_eq!(
                    point,
                    TextSummary::of(&text[..expected]),
                    "byte {byte}, forward {forward}"
                );
            }
        }
    }
    Ok(())
}

#[test]
fn long_grapheme_seek_yields_bounded_steps_and_keeps_old_root_during_edit() -> Result<()> {
    let text = "e".to_owned() + &"\u{301}".repeat(TEXT_PAGE_BYTES * 2) + "\nnext";
    let (mut engine, mut document) = small(&text)?;
    let captured = document.revision().clone();
    let id = engine.grapheme_seek_begin(captured.clone(), 0, true)?;
    assert!(
        !engine
            .grapheme_seek_step(&captured, id, &mut || false)?
            .complete
    );
    let old_end = captured.summary().bytes;
    let newer = engine.splice(
        &mut document,
        &captured,
        old_end..old_end,
        Some(b""),
        "later",
        &mut || false,
    )?;
    assert!(matches!(
        engine.grapheme_seek_step(&newer, id, &mut || false),
        Err(Error::Stale)
    ));
    assert_eq!(engine.active_bulk_operations(), 1);
    let mut turns = 1;
    loop {
        let before = engine.stats();
        let progress = engine.grapheme_seek_step(&captured, id, &mut || false)?;
        turns += 1;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        assert!(engine.stats().page_reads - before.page_reads <= u64::from(MAX_HEIGHT) + 2);
        if progress.complete {
            let boundary = engine.grapheme_seek_finish(&captured, id, &mut || false)?;
            assert_eq!(boundary, TextSummary::of(&text[..text.len() - 5]));
            break;
        }
        assert!(turns < 100);
    }
    assert!(turns > 8);
    assert_eq!(document.revision(), &newer);
    assert_eq!(contents(&mut engine, &document)?, text + "later");
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn grapheme_seek_tiny_pieces_fetch_only_one_source_piece_per_step() -> Result<()> {
    let (mut engine, mut document) = small("e")?;
    for _ in 0..100 {
        let prior = document.revision().clone();
        let end = prior.summary().bytes;
        engine.splice(
            &mut document,
            &prior,
            end..end,
            Some(b""),
            "\u{301}",
            &mut || false,
        )?;
    }
    engine.cache.clear();
    engine.stats.charged_bytes = 0;
    engine.cache_budget = 0;
    let captured = document.revision().clone();
    let (point, turns, _) = sought(&mut engine, &captured, 0, true)?;
    assert_eq!(point, captured.summary());
    assert!(
        turns >= 200,
        "Tiny pieces must yield; no assembled range fetch"
    );
    Ok(())
}

#[test]
fn grapheme_seek_scope_budget_abort_and_cancellation_preserve_other_operations() -> Result<()> {
    let (mut engine, document) = small("🙂e\u{301}")?;
    let revision = document.revision().clone();
    assert!(
        engine
            .grapheme_seek_begin(revision.clone(), 1, true)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    let first = engine.grapheme_seek_begin(revision.clone(), 0, true)?;
    let second = engine.grapheme_seek_begin(revision.clone(), 2, true)?;
    assert!(
        engine
            .grapheme_seek_begin(revision.clone(), 0, false)
            .is_err()
    );
    assert!(
        engine
            .stream_step(&revision, first, None, &mut || false)
            .is_err()
    );
    assert!(matches!(
        engine.grapheme_seek_step(&revision, Uuid::new_v4(), &mut || false),
        Err(Error::Stale)
    ));
    let mut foreign = revision.clone();
    foreign.document_id = Uuid::new_v4();
    assert!(
        engine
            .grapheme_seek_step(&foreign, first, &mut || false)
            .is_err()
    );
    assert!(
        engine
            .bulk_abort(foreign.owner_id, foreign.document_id, first)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 2);
    assert!(matches!(
        engine.grapheme_seek_step(&revision, first, &mut || true),
        Err(Error::Cancelled)
    ));
    assert_eq!(engine.active_bulk_operations(), 1);
    assert!(engine.bulk_abort(revision.owner_id, revision.document_id, first)?);
    assert!(engine.bulk_abort(revision.owner_id, revision.document_id, second)?);
    assert_eq!(engine.active_bulk_operations(), 0);
    let complete = engine.grapheme_seek_begin(revision.clone(), revision.summary().utf16, true)?;
    assert!(matches!(
        engine.grapheme_seek_finish(&revision, complete, &mut || true),
        Err(Error::Cancelled)
    ));
    assert_eq!(engine.active_bulk_operations(), 0);
    Ok(())
}

#[test]
fn grapheme_seek_authenticated_read_failure_discards_only_its_admitted_state() -> Result<()> {
    let (mut engine, document) = small("e\u{301}!")?;
    engine.cache.clear();
    engine.stats.charged_bytes = 0;
    engine.cache_budget = 0;
    let revision = document.revision().clone();
    let id = engine.grapheme_seek_begin(revision.clone(), 0, true)?;
    let mut corrupt = false;
    for row in engine.provider.rows.values_mut() {
        if row.kind == PageKind::Text {
            row.bytes[0] ^= 1;
            corrupt = true;
            break;
        }
    }
    assert!(corrupt);
    assert!(
        engine
            .grapheme_seek_step(&revision, id, &mut || false)
            .is_err()
    );
    assert_eq!(engine.active_bulk_operations(), 0);
    assert!(engine.bulk_abort(revision.owner_id, revision.document_id, id)?);
    Ok(())
}

fn paragraph_oracle(text: &str, byte: usize, include_lines: bool) -> ParagraphBounds {
    let mut breaks = Vec::new();
    let mut iter = text.char_indices().peekable();
    while let Some((at, ch)) = iter.next() {
        let delim = matches!(ch, '\r' | '\n' | '\u{2029}')
            || (include_lines && matches!(ch, '\u{85}' | '\u{2028}'));
        if !delim {
            continue;
        }
        let mut end = at + ch.len_utf8();
        let mut lf = ch == '\n';
        if ch == '\r'
            && iter.peek().is_some_and(|(_, next)| *next == '\n')
            && let Some((next, _)) = iter.next()
        {
            end = next + 1;
            lf = true;
        }
        breaks.push((at, end, lf));
    }
    let start = breaks
        .iter()
        .rev()
        .find(|(_, end, _)| *end <= byte)
        .map_or(0, |(_, end, _)| *end);
    let next = breaks.iter().find(|(_, end, _)| *end > byte);
    let (content, end, lf) = next.copied().unwrap_or((text.len(), text.len(), false));
    ParagraphBounds {
        start: TextSummary::of(&text[..start]),
        content_end: TextSummary::of(&text[..content]),
        end: TextSummary::of(&text[..end]),
        terminated: next.is_some(),
        lf_terminated: lf,
    }
}
fn paragraph_sought(
    engine: &mut TextEngine<MemoryPages>,
    revision: &Revision,
    at: u64,
    lines: bool,
) -> Result<(ParagraphBounds, usize)> {
    let writes = engine.stats().page_writes;
    let id = engine.paragraph_bounds_begin(revision.clone(), at, lines)?;
    let mut turns = 0;
    let mut examined = 0;
    loop {
        let progress = engine.paragraph_bounds_step(revision, id, &mut || false)?;
        turns += 1;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        assert!(
            progress.examined_bytes >= examined
                && progress.examined_bytes - examined <= TEXT_PAGE_BYTES as u64
        );
        examined = progress.examined_bytes;
        if progress.complete {
            let result = engine.paragraph_bounds_finish(revision, id, &mut || false)?;
            assert_eq!(Some(result), progress.result);
            assert_eq!(engine.stats().page_writes, writes);
            return Ok((result, turns));
        }
        assert!(turns < 1000);
    }
}
#[test]
fn source_paragraph_bounds_match_apple_line_and_paragraph_separators_at_every_scalar() -> Result<()>
{
    for text in [
        "",
        "a\rb\n",
        "a\r\nb\r",
        "\r\n\n",
        "🙂e\u{301}\u{85}n\u{2028}l\u{2029}p",
        "a\r\r\nb",
    ] {
        let (mut engine, doc) = small(text)?;
        let original = doc.revision().clone();
        let mut public = original.clone();
        if let Some(root) = &mut public.root {
            root.paragraphs = None;
        }
        for (at, _) in text
            .char_indices()
            .chain(std::iter::once((text.len(), '\0')))
        {
            for lines in [true, false] {
                let (actual, _) = paragraph_sought(
                    &mut engine,
                    &public,
                    TextSummary::of(&text[..at]).utf16,
                    lines,
                )?;
                assert_eq!(
                    actual,
                    paragraph_oracle(text, at, lines),
                    "byte{at}, lines{lines}, {text:?}"
                );
            }
        }
        assert_eq!(doc.revision(), &original);
        assert_eq!(contents(&mut engine, &doc)?, text);
    }
    Ok(())
}
#[test]
fn paragraph_aggregate_composes_crlf_across_pages_and_piece_edits_without_changing_lf_counts()
-> Result<()> {
    let text = "a".repeat(TEXT_PAGE_BYTES - 1) + "\r\n\u{85}\u{2028}\u{2029}tail";
    let (mut engine, mut doc) = small(&text)?;
    let rev = doc.revision().clone();
    let stat = rev
        .root
        .as_ref()
        .and_then(|r| r.paragraphs)
        .ok_or(Error::Invalid("test paragraph aggregate"))?;
    assert_eq!(stat.breaks, 4);
    assert_eq!(stat.paragraphs, 2);
    assert_eq!(rev.summary().lf_count, 1);
    for at in [
        TEXT_PAGE_BYTES - 1,
        TEXT_PAGE_BYTES,
        TEXT_PAGE_BYTES + 1,
        text.len(),
    ] {
        for lines in [true, false] {
            let (actual, _) =
                paragraph_sought(&mut engine, &rev, TextSummary::of(&text[..at]).utf16, lines)?;
            assert_eq!(actual, paragraph_oracle(&text, at, lines));
        }
    }
    let end = rev.summary().bytes;
    let edited = engine.splice(&mut doc, &rev, end..end, Some(b""), "\r", &mut || false)?;
    let end = edited.summary().bytes;
    let final_rev = engine.splice(&mut doc, &edited, end..end, Some(b""), "\nnew", &mut || {
        false
    })?;
    let changed = text + "\r\nnew";
    let (actual, _) = paragraph_sought(&mut engine, &final_rev, final_rev.summary().utf16, true)?;
    assert_eq!(actual, paragraph_oracle(&changed, changed.len(), true));
    assert_eq!(final_rev.summary().lf_count, 2);
    assert_eq!(contents(&mut engine, &doc)?, changed);
    Ok(())
}
fn unknown_paragraph_aggregate(
    engine: &mut TextEngine<MemoryPages>,
    revision: &Revision,
    tree: &TreeRef,
) -> Result<TreeRef> {
    let mut node = engine.node(revision, tree)?;
    match &mut node {
        Node::Leaf(pieces) => {
            for piece in pieces {
                piece.paragraphs = None;
            }
        }
        Node::Branch(children) => {
            for child in children {
                *child = unknown_paragraph_aggregate(engine, revision, child)?;
            }
        }
    }
    engine.write_node(revision, node, tree.height)
}
#[test]
fn absent_paragraph_aggregate_yields_for_a_real_edit_and_preserves_captured_unknown_revision()
-> Result<()> {
    let text = "x".repeat(TEXT_PAGE_BYTES * 3) + "\u{2028}e\r\nlast";
    let (mut engine, mut doc) = small(&text)?;
    let original = doc.revision().clone();
    let old_tree = original.root.as_ref().ok_or(Error::Invalid("test root"))?;
    let mut unknown = original.clone();
    unknown.root = Some(unknown_paragraph_aggregate(
        &mut engine,
        &original,
        old_tree,
    )?);
    assert!(
        unknown
            .root
            .as_ref()
            .is_some_and(|r| r.paragraphs.is_none())
    );
    let caret = (TEXT_PAGE_BYTES * 3 - 1) as u64;
    let id = engine.paragraph_bounds_begin(unknown.clone(), caret, true)?;
    assert!(
        !engine
            .paragraph_bounds_step(&unknown, id, &mut || false)?
            .complete
    );
    let end = original.summary().bytes;
    let new = engine.splice(
        &mut doc,
        &original,
        end..end,
        Some(b""),
        "later",
        &mut || false,
    )?;
    assert!(matches!(
        engine.paragraph_bounds_step(&new, id, &mut || false),
        Err(Error::Stale)
    ));
    let mut turns = 0;
    loop {
        let progress = engine.paragraph_bounds_step(&unknown, id, &mut || false)?;
        turns += 1;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        if progress.complete {
            let actual = engine.paragraph_bounds_finish(&unknown, id, &mut || false)?;
            assert_eq!(actual, paragraph_oracle(&text, caret as usize, true));
            break;
        }
        assert!(turns < 100);
    }
    assert!(turns >= 5);
    assert_eq!(doc.revision(), &new);
    assert_eq!(contents(&mut engine, &doc)?, text + "later");
    Ok(())
}
#[test]
fn paragraph_aggregate_refuses_mismatch_and_wrong_operation_keeps_its_actual_slot() -> Result<()> {
    let (mut engine, doc) = small("a\r\nb\u{2028}c")?;
    let rev = doc.revision().clone();
    let mut wrong = rev.clone();
    wrong
        .root
        .as_mut()
        .and_then(|r| r.paragraphs.as_mut())
        .ok_or(Error::Invalid("test stats"))?
        .breaks += 1;
    assert!(engine.open(wrong).is_err());
    let id = engine.paragraph_bounds_begin(rev.clone(), 1, true)?;
    assert!(engine.grapheme_seek_step(&rev, id, &mut || false).is_err());
    assert_eq!(engine.active_bulk_operations(), 1);
    assert!(matches!(
        engine.paragraph_bounds_step(&rev, id, &mut || true),
        Err(Error::Cancelled)
    ));
    assert_eq!(engine.active_bulk_operations(), 0);
    assert!(engine.bulk_abort(rev.owner_id, rev.document_id, id)?);
    Ok(())
}

#[test]
fn paragraph_aggregate_cannot_hide_authenticated_lf_counts_in_child_or_piece() -> Result<()> {
    let (mut engine, doc) = small("\nline\n")?;
    let revision = doc.revision().clone();
    let root = revision.root.as_ref().ok_or(Error::Invalid("test root"))?;
    for paragraphs in [
        ParagraphSummary {
            breaks: 0,
            paragraphs: 0,
            starts_lf: false,
            ends_cr: false,
        },
        ParagraphSummary {
            breaks: 2,
            paragraphs: 0,
            starts_lf: false,
            ends_cr: false,
        },
    ] {
        for branch in [false, true] {
            let node = if branch {
                let mut child = root.clone();
                child.paragraphs = Some(paragraphs);
                Node::Branch(vec![child])
            } else {
                let Node::Leaf(mut pieces) = engine.node(&revision, root)? else {
                    return Err(Error::Invalid("test leaf"));
                };
                pieces[0].paragraphs = Some(paragraphs);
                Node::Leaf(pieces)
            };
            // A real checksum-valid encoded node still cannot use a forged
            // child aggregate to skip LF text. No legitimate root is replaced.
            let bytes = serde_json::to_vec(&IndexPage {
                schema: 1,
                owner_id: revision.owner_id,
                document_id: revision.document_id,
                node,
            })
            .map_err(|_| Error::Invalid("test node encode"))?;
            let page = engine.write_page(&revision, PageKind::Index, &bytes)?;
            let mut forged = revision.clone();
            forged.root = Some(TreeRef {
                page,
                summary: root.summary,
                height: u8::from(branch),
                paragraphs: None,
            });
            assert!(engine.open(forged.clone()).is_err());
            assert!(engine.paragraph_bounds_begin(forged, 1, true).is_err());
            assert_eq!(engine.active_bulk_operations(), 0);
        }
    }
    assert_eq!(contents(&mut engine, &doc)?, "\nline\n");
    Ok(())
}

#[test]
fn paragraph_metadata_many_tiny_piece_edits_stay_bounded_and_keep_original_source() -> Result<()> {
    let (mut engine, mut doc) = small("start")?;
    let original = doc.revision().clone();
    let mut text = "start".to_owned();
    for turn in 0..(FANOUT * FANOUT + 1) {
        let marker = match turn % 5 {
            0 => "\r",
            1 => "\n",
            2 => "\u{85}",
            3 => "\u{2028}",
            _ => "\u{2029}",
        };
        let before = doc.revision().clone();
        let at = before.summary().bytes;
        engine.splice(&mut doc, &before, at..at, Some(b""), marker, &mut || false)?;
        text.push_str(marker);
    }
    let rev = doc.revision().clone();
    assert!(rev.root.as_ref().is_some_and(|r| r.height >= 2));
    for row in engine
        .provider
        .rows
        .values()
        .filter(|r| r.kind == PageKind::Index)
    {
        assert!(row.bytes.len() <= INDEX_PAGE_BYTES);
    }
    for byte in [0, 5, text.len() - 3, text.len()] {
        for lines in [true, false] {
            let (actual, _) = paragraph_sought(
                &mut engine,
                &rev,
                TextSummary::of(&text[..byte]).utf16,
                lines,
            )?;
            assert_eq!(actual, paragraph_oracle(&text, byte, lines));
        }
    }
    assert_eq!(contents(&mut engine, &doc)?, text);
    let old = engine.open(original)?;
    assert_eq!(contents(&mut engine, &old)?, "start");
    Ok(())
}
#[test]
fn paragraph_metadata_maximum_encoded_index_shape_fits_the_existing_page_cap() -> Result<()> {
    let (mut engine, doc) = small("real envelope source")?;
    let reference = doc
        .revision()
        .root
        .as_ref()
        .ok_or(Error::Invalid("test root"))?;
    // Encoder upper envelope only: maximum field widths, not a claimed source.
    let mut wire = serde_json::to_value(reference).map_err(|_| Error::Invalid("test wire"))?;
    wire["summary"] = serde_json::json!({"bytes":u64::MAX,"utf16":u64::MAX,"lfCount":u64::MAX});
    wire["paragraphs"] = serde_json::json!({"breaks":u64::MAX,"paragraphs":u64::MAX,"startsLf":false,"endsCr":false});
    wire["page"]["locator"]["offset"] = serde_json::json!(i64::MAX - 65536 - 12);
    wire["page"]["locator"]["bytes"] = serde_json::json!(16384);
    wire["height"] = serde_json::json!(11);
    let outer = serde_json::json!({"schema":1,"ownerId":doc.revision().owner_id,"documentId":doc.revision().document_id,
        "node":{"kind":"branch","items":vec![wire;FANOUT]}});
    let bytes = serde_json::to_vec(&outer).map_err(|_| Error::Invalid("test envelope"))?;
    assert_eq!(bytes.len(), 14_068);
    assert!(bytes.len() <= INDEX_PAGE_BYTES);
    assert_eq!(contents(&mut engine, &doc)?, "real envelope source");
    Ok(())
}

fn prefix_oracle(
    text: &str,
    start: usize,
    end: usize,
    prefix: &str,
) -> (String, usize, usize, bool) {
    let first = paragraph_oracle(text, start, true).start.bytes as usize;
    let last = if end > start {
        text.char_indices()
            .rev()
            .find(|(at, _)| *at < end)
            .map_or(0, |(at, _)| at)
    } else {
        end
    };
    let limit = paragraph_oracle(text, last, true).end.bytes as usize;
    let mut lines = Vec::new();
    let mut at = first;
    while at < limit {
        let bounds = paragraph_oracle(text, at, true);
        let stop = (bounds.end.bytes as usize).min(limit);
        assert!(stop > at);
        lines.push(&text[at..stop]);
        at = stop;
    }
    let removing = !lines.is_empty() && lines.iter().all(|line| line.starts_with(prefix));
    let mut changed = String::new();
    for line in lines {
        if removing {
            changed.push_str(&line[prefix.len()..]);
        } else {
            changed.push_str(prefix);
            changed.push_str(line);
        }
    }
    let after_len = changed.encode_utf16().count();
    let output = text[..first].to_owned() + &changed + &text[limit..];
    (
        output,
        text[..first].encode_utf16().count(),
        after_len,
        removing,
    )
}
fn prefixed(
    engine: &mut TextEngine<MemoryPages>,
    revision: &Revision,
    start: u64,
    end: u64,
    prefix: &str,
) -> Result<(LinePrefixResult, usize)> {
    let id = engine.line_prefix_begin(revision.clone(), start, end, prefix.to_owned())?;
    let mut turns = 0;
    let mut processed = 0;
    let mut examined = 0;
    loop {
        let progress = engine.line_prefix_step(revision, id, &mut || false)?;
        turns += 1;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        assert!(progress.processed_bytes >= processed);
        processed = progress.processed_bytes;
        assert!(
            progress.examined_bytes >= examined
                && progress.examined_bytes - examined <= TEXT_PAGE_BYTES as u64
        );
        examined = progress.examined_bytes;
        if progress.complete {
            return Ok((
                engine.line_prefix_finish(revision, id, &mut || false)?,
                turns,
            ));
        }
        assert!(turns < 100_000);
    }
}
#[test]
fn bounded_line_prefix_matches_toggle_selection_and_mixed_separator_oracle() -> Result<()> {
    for text in [
        "",
        "a",
        "a\n",
        "a\r\nb\rc\u{85}d\u{2028}e\u{2029}",
        "> old\nbare\n",
        "> one\n> two\n",
        "🙂 e\u{301}\n🙂 second",
    ] {
        let boundaries: Vec<_> = text
            .char_indices()
            .map(|(at, _)| at)
            .chain(std::iter::once(text.len()))
            .collect();
        for &(start, end) in &[
            (0, text.len()),
            (text.len(), text.len()),
            (boundaries[boundaries.len() / 2], text.len()),
        ] {
            for prefix in ["> ", "🙂 "] {
                let (mut engine, doc) = small(text)?;
                let source = doc.revision().clone();
                let (result, _) = prefixed(
                    &mut engine,
                    &source,
                    TextSummary::of(&text[..start]).utf16,
                    TextSummary::of(&text[..end]).utf16,
                    prefix,
                )?;
                let (expected, at, length, removing) = prefix_oracle(text, start, end, prefix);
                let after = engine.open(result.revision.clone())?;
                assert_eq!(
                    contents(&mut engine, &after)?,
                    expected,
                    "{text:?}/{start}..{end}/{prefix:?}"
                );
                assert_eq!(result.utf16_start, at as u64);
                assert_eq!(result.utf16_length, length as u64);
                assert_eq!(result.removing, removing);
                assert_eq!(result.changed, expected.as_bytes() != text.as_bytes());
                assert_eq!(
                    result.revision.summary().lf_count,
                    source.summary().lf_count
                );
                assert_eq!(doc.revision(), &source);
                assert_eq!(contents(&mut engine, &doc)?, text);
                assert_eq!(engine.active_bulk_operations(), 0);
            }
        }
    }
    Ok(())
}
#[test]
fn prefix_end_at_next_line_start_and_trailing_empty_caret_do_not_format_the_next_line() -> Result<()>
{
    let text = "first\nsecond\nthird\n";
    let (mut engine, doc) = small(text)?;
    let source = doc.revision().clone();
    let (result, _) = prefixed(&mut engine, &source, 2, 6, "## ")?;
    let after = engine.open(result.revision.clone())?;
    assert_eq!(contents(&mut engine, &after)?, "## first\nsecond\nthird\n");
    assert_eq!(result.utf16_start, 0);
    assert_eq!(result.utf16_length, 9);
    let writes = engine.stats().page_writes;
    let (neutral, _) = prefixed(
        &mut engine,
        &source,
        source.summary().utf16,
        source.summary().utf16,
        "## ",
    )?;
    assert!(!neutral.changed);
    assert_eq!(neutral.revision, source);
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}
#[test]
fn prefix_thousands_of_lines_yields_builds_indexes_and_reuses_one_marker_page() -> Result<()> {
    let text = "line\n".repeat(4096);
    let (mut engine, doc) = small(&text)?;
    let source = doc.revision().clone();
    let text_pages = engine
        .provider
        .rows
        .values()
        .filter(|r| r.kind == PageKind::Text)
        .count();
    let (result, turns) = prefixed(&mut engine, &source, 0, source.summary().utf16, "- ")?;
    assert!(turns > 100);
    assert_eq!(
        engine
            .provider
            .rows
            .values()
            .filter(|r| r.kind == PageKind::Text)
            .count(),
        text_pages + 1
    );
    let after = engine.open(result.revision.clone())?;
    assert_eq!(contents(&mut engine, &after)?, "- line\n".repeat(4096));
    let (removed, _) = prefixed(
        &mut engine,
        &result.revision,
        0,
        result.revision.summary().utf16,
        "- ",
    )?;
    assert!(removed.removing);
    let restored = engine.open(removed.revision)?;
    assert_eq!(contents(&mut engine, &restored)?, text);
    assert_eq!(doc.revision(), &source);
    assert_eq!(contents(&mut engine, &doc)?, text);
    assert!(
        engine
            .provider
            .rows
            .values()
            .filter(|r| r.kind == PageKind::Index)
            .all(|r| r.bytes.len() <= INDEX_PAGE_BYTES)
    );
    Ok(())
}
#[test]
fn prefix_a_large_single_line_shares_source_subtrees_without_copying_its_payload() -> Result<()> {
    let text = "x".repeat(TEXT_PAGE_BYTES * (FANOUT + 3));
    let (mut engine, doc) = small(&text)?;
    let source = doc.revision().clone();
    let before = engine.stats();
    let text_pages = engine
        .provider
        .rows
        .values()
        .filter(|r| r.kind == PageKind::Text)
        .count();
    let (result, turns) = prefixed(&mut engine, &source, 0, source.summary().utf16, "## ")?;
    assert!(turns < 30);
    assert!(engine.stats().page_reads - before.page_reads < 20);
    assert_eq!(
        engine
            .provider
            .rows
            .values()
            .filter(|r| r.kind == PageKind::Text)
            .count(),
        text_pages + 1
    );
    let after = engine.open(result.revision)?;
    assert_eq!(contents(&mut engine, &after)?, "## ".to_owned() + &text);
    assert_eq!(doc.revision(), &source);
    assert_eq!(contents(&mut engine, &doc)?, text);
    Ok(())
}
#[test]
fn prefix_wrong_scope_and_actual_cancelled_builder_preserve_current_and_other_jobs() -> Result<()> {
    let text = "line\r\n".repeat(256);
    let (mut engine, mut doc) = small(&text)?;
    let source = doc.revision().clone();
    for invalid in ["", "\n", "a\u{2028}b"] {
        assert!(
            engine
                .line_prefix_begin(
                    source.clone(),
                    0,
                    source.summary().utf16,
                    invalid.to_owned()
                )
                .is_err()
        );
    }
    let id =
        engine.line_prefix_begin(source.clone(), 0, source.summary().utf16, "> ".to_owned())?;
    let other = engine.hash_begin(source.clone())?;
    assert!(
        engine
            .grapheme_seek_step(&source, id, &mut || false)
            .is_err()
    );
    let end = source.summary().bytes;
    let newer = engine.splice(&mut doc, &source, end..end, Some(b""), "later", &mut || {
        false
    })?;
    assert!(matches!(
        engine.line_prefix_step(&newer, id, &mut || false),
        Err(Error::Stale)
    ));
    let writes = engine.stats().page_writes;
    for _ in 0..30 {
        let _ = engine.line_prefix_step(&source, id, &mut || false)?;
        if engine.stats().page_writes > writes {
            break;
        }
    }
    assert!(
        engine.stats().page_writes > writes,
        "Actual candidate pages were appended before cancellation"
    );
    assert!(matches!(
        engine.line_prefix_step(&source, id, &mut || true),
        Err(Error::Cancelled)
    ));
    assert_eq!(engine.active_bulk_operations(), 1);
    assert!(engine.bulk_abort(source.owner_id, source.document_id, id)?);
    assert!(engine.bulk_abort(source.owner_id, source.document_id, other)?);
    assert_eq!(engine.active_bulk_operations(), 0);
    assert_eq!(doc.revision(), &newer);
    assert_eq!(contents(&mut engine, &doc)?, text + "later");
    Ok(())
}

#[test]
fn imported_tree_replacement_keeps_unaffected_source_and_reads_only_join_paths() -> Result<()> {
    let owner = Uuid::new_v4();
    let id = Uuid::new_v4();
    let mut engine = TextEngine::with_cache_budget(MemoryPages::new(), 96 * 1024);
    let original = engine
        .import_utf8(owner, id, &mut "left🙂end".as_bytes(), &mut || false)?
        .document;
    let before = original.revision().clone();
    let pattern = "e\u{301}🙂\n".as_bytes().to_vec();
    let bytes = (48 * TEXT_PAGE_BYTES / pattern.len() * pattern.len()) as u64;
    let imported = engine
        .import_utf8(
            owner,
            id,
            &mut Repeated {
                pattern: pattern.clone(),
                position: 0,
                remaining: bytes,
            },
            &mut || false,
        )?
        .document;
    let insertion = imported.revision().clone();
    let mut edited = engine.open(before.clone())?;
    let reads = engine.stats().read_bytes;
    let result = engine.replace_user_tree(&mut edited, &before, 4..8, &insertion, &mut || false)?;
    assert!(
        engine.stats().read_bytes - reads < 8 * TEXT_PAGE_BYTES as u64,
        "Composition must not read the inserted multi-megabyte body"
    );
    assert_eq!(result.summary().bytes, 7 + bytes);
    let start = engine.window(&edited, &result, 0, 4 + pattern.len())?;
    assert_eq!(
        start.text,
        format!(
            "left{}",
            std::str::from_utf8(&pattern).expect("The fixed Unicode pattern is UTF-8")
        )
    );
    let end = engine.window(&edited, &result, 4 + bytes, 4)?;
    assert_eq!(end.text, "end");
    assert_eq!(contents(&mut engine, &original)?, "left🙂end");
    let unchanged = edited.revision().clone();
    assert!(
        engine
            .replace_user_tree(&mut edited, &unchanged, 0..0, &insertion, &mut || true)
            .is_err()
    );
    assert_eq!(edited.revision(), &unchanged);
    let mut cancellation_checks = 0;
    assert!(
        engine
            .replace_user_tree(&mut edited, &unchanged, 0..1, &insertion, &mut || {
                cancellation_checks += 1;
                cancellation_checks == 2
            })
            .is_err(),
        "Cancellation after the real split must not replace the accepted root"
    );
    assert_eq!(cancellation_checks, 2);
    assert_eq!(edited.revision(), &unchanged);
    assert!(engine.stats().charged_bytes <= 96 * 1024);
    let foreign = engine
        .import_utf8(owner, Uuid::new_v4(), &mut "x".as_bytes(), &mut || false)?
        .document;
    assert!(
        engine
            .replace_user_tree(
                &mut edited,
                &unchanged,
                0..0,
                foreign.revision(),
                &mut || false
            )
            .is_err()
    );
    assert_eq!(edited.revision(), &unchanged);
    assert!(
        engine
            .replace_user_tree(&mut edited, &unchanged, 5..6, &insertion, &mut || false)
            .is_err(),
        "A start inside a multibyte scalar is not an admitted source range"
    );
    assert_eq!(edited.revision(), &unchanged);
    Ok(())
}
