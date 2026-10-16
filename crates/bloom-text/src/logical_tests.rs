use super::*;

fn entire(engine: &mut TextEngine<MemoryPages>, snapshot: &LogicalSnapshot) -> Result<String> {
    if snapshot.summary().bytes > NATIVE_WINDOW_BYTES as u64 {
        return Err(Error::Invalid("small oracle bound"));
    }
    Ok(engine
        .logical_window(snapshot, 0, NATIVE_WINDOW_BYTES, &mut || false)?
        .text()
        .to_owned())
}

#[test]
fn native_window_edits_have_no_provider_calls_and_old_snapshot_stays_exact() -> Result<()> {
    let (mut engine, document) = small("alpha é🙂\r\n終 omega")?;
    let revision = document.revision().clone();
    let mut source = LogicalSource::new(revision)?;
    let before = source.capture();
    let window = engine.logical_window(&before, 0, 16_384, &mut || false)?;
    let reads = engine.stats().page_reads;
    let writes = engine.stats().page_writes;
    let edit = source.replace_window(&window, 6..12, "ê🌱")?;
    assert!(edit.changed);
    assert_eq!(edit.window.text(), "alpha ê🌱\r\n終 omega");
    assert_eq!(engine.stats().page_reads, reads);
    assert_eq!(engine.stats().page_writes, writes);
    assert_eq!(entire(&mut engine, &before)?, "alpha é🙂\r\n終 omega");
    assert_eq!(
        entire(&mut engine, &source.capture_for_publication()?)?,
        edit.window.text()
    );
    Ok(())
}

#[test]
fn delayed_publication_does_not_exhaust_typing_or_window() -> Result<()> {
    let (mut engine, document) = small("left\nright")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let mut window = engine.logical_window(&source.capture(), 5, 16_384, &mut || false)?;
    let mut focus = 5u64;
    let mut captured = None;
    let reads = engine.stats().page_reads;
    let writes = engine.stats().page_writes;
    for index in 0..1200 {
        let local = usize::try_from(focus - window.start().bytes)
            .map_err(|_| Error::Invalid("test local point"))?;
        let edit = source.replace_window(&window, local..local, &"x".repeat(512))?;
        focus = edit.cursor.point().bytes;
        window = edit.window.trimmed(
            edit.cursor.point().utf16 - edit.window.start().utf16,
            16_384,
        )?;
        assert!(window.text().len() <= 16_384);
        if index == 20 {
            captured = Some(source.capture_for_publication()?);
        }
    }
    assert_eq!(engine.stats().page_reads, reads);
    assert_eq!(engine.stats().page_writes, writes);
    assert_eq!(source.capture().summary().bytes, 10 + 1200 * 512);
    let held = captured.ok_or(Error::Invalid("test capture"))?;
    assert_eq!(held.summary().bytes, 10 + 21 * 512);
    let persisted = engine.materialize_logical(&held, &mut || false)?;
    assert_eq!(persisted.summary(), held.summary());
    assert_eq!(source.capture().summary().bytes, 10 + 1200 * 512);
    // A late durable checkpoint cannot alter the current native source/arena.
    assert!(!held.same(&source.capture()));
    let handed = source.capture_for_publication()?;
    let tail = engine.logical_window(&handed, handed.summary().utf16, 16_384, &mut || false)?;
    assert!(tail.text().ends_with("right"));
    Ok(())
}

#[test]
fn exact_unchanged_primitive_retains_root_and_scalar_refusal_is_atomic() -> Result<()> {
    let (mut engine, document) = small("é🙂tail")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let before = source.capture();
    let window = engine.logical_window(&before, 0, 16_384, &mut || false)?;
    assert!(!source.replace_window(&window, 0..2, "é")?.changed);
    assert!(before.same(&source.capture()));
    assert!(source.replace_window(&window, 3..6, "x").is_err());
    assert!(before.same(&source.capture()));
    assert!(source.replace_window(&window, 20..20, "e").is_err());
    assert!(before.same(&source.capture()));
    assert!(window.position(2).is_err()); // middle of the supplementary scalar
    Ok(())
}

#[test]
fn root_swaps_restore_real_text_and_old_arena_never_edits_new_head() -> Result<()> {
    let (mut engine, document) = small("one\ntwo")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let before = source.capture();
    let first = engine.logical_window(&before, 0, 16_384, &mut || false)?;
    let after = source.replace_window(&first, 4..7, "three🙂")?.window;
    let redo = source.capture_for_publication()?;
    source.restore(&before)?;
    assert_eq!(
        entire(&mut engine, &source.capture_for_publication()?)?,
        "one\ntwo"
    );
    assert!(source.replace_window(&after, 0..3, "bad").is_err());
    assert!(before.same(&source.capture()));
    source.restore(&redo)?;
    assert_eq!(
        entire(&mut engine, &source.capture_for_publication()?)?,
        "one\nthree🙂"
    );
    assert_eq!(after.position(11)?.point().utf16, 11);
    Ok(())
}

#[test]
fn real_file_materialization_matches_many_window_changes_and_shares_prior_candidates() -> Result<()>
{
    let (mut engine, document) = small(&"aé🙂\n".repeat(3000))?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let mut oracle = "aé🙂\n".repeat(3000);
    for index in 0..600 {
        let target = (index * 19) % (oracle.encode_utf16().count() + 1);
        let handed = source.capture_for_publication()?;
        let point = engine.logical_position(&handed, target as u64, true)?;
        let mut window =
            engine.logical_window(&handed, point.point().utf16, 16_384, &mut || false)?;
        let local = usize::try_from(point.point().bytes - window.start().bytes)
            .map_err(|_| Error::Invalid("test local edit"))?;
        let text = if index % 2 == 0 { "🌱" } else { "z\n" };
        oracle.insert_str(point.point().bytes as usize, text);
        let edit = source.replace_window(&window, local..local, text)?;
        window = edit.window.trimmed(
            edit.cursor.point().utf16 - edit.window.start().utf16,
            16_384,
        )?;
        assert!(window.text().len() <= 16_384);
    }
    let captured = source.capture_for_publication()?;
    let revision = engine.materialize_logical(&captured, &mut || false)?;
    let loaded = engine.open(revision.clone())?;
    assert_eq!(contents(&mut engine, &loaded)?, oracle);
    let written = engine.stats().page_writes;
    assert_eq!(
        engine.materialize_logical(&captured, &mut || false)?,
        revision
    );
    assert_eq!(engine.stats().page_writes, written);
    Ok(())
}

#[test]
fn captured_snapshot_read_isolated_from_later_append_and_global_delete() -> Result<()> {
    let (mut engine, document) = small("headé🙂\ntail")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let window = engine.logical_window(&source.capture(), 0, 16_384, &mut || false)?;
    let edit = source.replace_window(&window, 4..4, "first")?;
    let captured = source.capture(); // tail is deliberately still appendable
    source.replace_window(&edit.window, 9..9, "second")?;
    let _handoff = source.capture_for_publication()?;
    assert_eq!(entire(&mut engine, &captured)?, "headfirsté🙂\ntail");
    let live = source.capture();
    let start = engine.logical_position(&live, 0, false)?;
    let end = engine.logical_position(&live, live.summary().utf16, false)?;
    source.replace_positions(&start, &end, "")?;
    assert_eq!(source.capture().summary(), TextSummary::EMPTY);
    assert_eq!(entire(&mut engine, &source.capture_for_publication()?)?, "");
    assert_eq!(entire(&mut engine, &captured)?, "headfirsté🙂\ntail");
    Ok(())
}

#[test]
fn actual_large_source_keeps_far_file_spans_without_native_provider_access() -> Result<()> {
    let pattern = "a🙂\n".as_bytes().to_vec();
    let bytes = (48 * TEXT_PAGE_BYTES / pattern.len() * pattern.len()) as u64;
    let mut engine = TextEngine::with_cache_budget(MemoryPages::new(), 96 * 1024);
    let imported = engine.import_utf8(
        Uuid::new_v4(),
        Uuid::new_v4(),
        &mut Repeated {
            pattern: pattern.clone(),
            position: 0,
            remaining: bytes,
        },
        &mut || false,
    )?;
    let before = engine.stats();
    let mut source = LogicalSource::new(imported.document.revision().clone())?;
    assert_eq!(source.capture().summary().bytes, bytes);
    assert_eq!(engine.stats().page_reads, before.page_reads);
    assert_eq!(engine.stats().page_writes, before.page_writes);
    let old = source.capture();
    let position = engine.logical_position(&old, old.summary().utf16 / 2, true)?;
    let window = engine.logical_window(&old, position.point().utf16, 16_384, &mut || false)?;
    let local = usize::try_from(position.point().bytes - window.start().bytes)
        .map_err(|_| Error::Invalid("test large local point"))?;
    let ready = engine.stats();
    source.replace_window(&window, local..local, "é終")?;
    assert_eq!(engine.stats().page_reads, ready.page_reads);
    assert_eq!(engine.stats().page_writes, ready.page_writes);
    let handed = source.capture_for_publication()?;
    let tail = engine.logical_window(&handed, handed.summary().utf16, 16_384, &mut || false)?;
    assert!(tail.text().ends_with("a🙂\n"));
    source.restore(&old)?;
    let captured = source.capture_for_publication()?;
    let persisted = engine.materialize_logical(&captured, &mut || false)?;
    let document = engine.open(persisted.clone())?;
    let mut output = PatternOutput {
        pattern,
        position: 0,
        hash: Sha256::new(),
    };
    engine.export(&document, &persisted, &mut output, &mut || false)?;
    assert_eq!(output.position, bytes);
    Ok(())
}

#[test]
fn four_byte_window_at_two_supplementary_scalars_is_nonempty_and_contains_focus() -> Result<()> {
    let (mut engine, document) = small("🙂🌱")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let window = engine.logical_window(&source.capture(), 0, 16_384, &mut || false)?;
    let trimmed = window.trimmed(2, 4)?;
    assert_eq!(trimmed.text().len(), 4);
    assert_eq!(trimmed.text(), "🌱");
    assert_eq!(trimmed.position(0)?.point().utf16, 2);
    let at = trimmed.position(0)?;
    let before = source.capture();
    source.replace_positions(&at, &at, "")?;
    assert!(source.capture().same(&before));
    Ok(())
}

#[test]
fn eof_trim_rounds_inward_and_keeps_supplementary_prefix_focus() -> Result<()> {
    let text = format!("🙂{}", "x".repeat(16_381));
    let (mut engine, document) = small(&text)?;
    let source = LogicalSource::new(document.revision().clone())?;
    let window = engine.logical_window(&source.capture(), 0, NATIVE_WINDOW_BYTES, &mut || false)?;
    let trimmed = window.trimmed(window.local_summary().utf16, 16_384)?;
    assert_eq!(trimmed.start().bytes, 4);
    assert_eq!(trimmed.text(), "x".repeat(16_381));
    assert_eq!(
        trimmed.position(trimmed.local_summary().utf16)?.point(),
        source.capture().summary()
    );
    let tiny = engine.logical_window(
        &source.capture(),
        source.capture().summary().utf16,
        4,
        &mut || false,
    )?;
    assert!(!tiny.text().is_empty());
    Ok(())
}

#[test]
fn cheap_group_captures_share_one_tail_and_save_packs_actual_used_bytes() -> Result<()> {
    let (mut engine, document) = small("old")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let mut window = engine.logical_window(&source.capture(), 3, 16_384, &mut || false)?;
    let mut undo = Vec::new();
    let reads = engine.stats().page_reads;
    let writes = engine.stats().page_writes;
    for _ in 0..100 {
        undo.push(source.capture()); // SDK roots, no tail freezing/page writes
        let at = window.text().len();
        window = source.replace_window(&window, at..at, "x")?.window;
    }
    assert_eq!(engine.stats().page_reads, reads);
    assert_eq!(engine.stats().page_writes, writes);
    let handed = source.capture_for_publication()?;
    let after = engine.materialize_logical(&handed, &mut || false)?;
    assert!(engine.stats().page_writes - writes < 8); // one insertion frame/run
    assert_eq!(after.summary().bytes, 103);
    let oldest = engine.materialize_logical(&undo[0], &mut || false)?;
    assert_eq!(oldest.summary().bytes, 3);
    let twentieth = engine.materialize_logical(&undo[20], &mut || false)?;
    assert_eq!(twentieth.summary().bytes, 23);
    handed.release_synced_insertions()?;
    assert_eq!(
        entire(&mut engine, &handed)?,
        format!("old{}", "x".repeat(100))
    );
    assert_eq!(
        entire(&mut engine, &undo[20])?,
        format!("old{}", "x".repeat(20))
    );
    Ok(())
}

#[test]
fn resident_global_replacement_and_seed_have_no_file_reader_side_effects() -> Result<()> {
    let (mut engine, document) = small(&"a🙂\n".repeat(10_000))?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let before = source.capture();
    let window = engine.logical_window(&before, 0, 16_384, &mut || false)?;
    let stats = engine.stats();
    let edit = source
        .prepare_resident_replacement(&window, 0, before.summary().utf16, "é🌱")?
        .ok_or(Error::Invalid(
            "actual start/end endpoints must be resident",
        ))?;
    assert!(before.same(&source.capture())); // prepare cannot advance Main
    assert_eq!(edit.window.text(), "é🌱");
    assert_eq!(engine.stats().page_reads, stats.page_reads);
    assert_eq!(engine.stats().page_writes, stats.page_writes);
    let seed = edit.window.seed(edit.window.local_summary().utf16)?;
    assert_eq!(
        seed.start().utf16 + seed.summary().utf16,
        edit.cursor.point().utf16
    );
    let restored = LogicalWindow::from_seed(&seed)?;
    source.install_prepared(restored.snapshot());
    assert_eq!(source.capture().summary(), TextSummary::of("é🌱"));
    Ok(())
}

#[test]
fn retained_cross_window_positions_prepare_without_provider_calls_and_reject_changed_roots()
-> Result<()> {
    let text = "aé🙂\n".repeat(400_000); // >3MiB, differing byte/UTF16/LF counters
    let (mut engine, document) = small(&text)?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let before = source.capture();
    let first = 100_002;
    let last = 1_900_004;
    let first_window = engine.logical_window(&before, first, 16_384, &mut || false)?;
    let last_window = engine.logical_window(&before, last, 16_384, &mut || false)?;
    let start = first_window.position(first - first_window.start().utf16)?;
    let end = last_window.position(last - last_window.start().utf16)?;
    assert!(
        first_window
            .position(first + 1 - first_window.start().utf16)
            .is_err()
    );
    assert_eq!(start.point().lf_count, 20_000);
    assert_eq!(end.point().lf_count, 380_000);
    drop(first_window);
    drop(last_window); // retained positions do not need either String/table
    let mounted = engine.logical_window(&before, 1_000_000, 16_384, &mut || false)?;
    assert!(start.point().utf16 < mounted.start().utf16);
    assert!(end.point().utf16 > mounted.start().utf16 + mounted.local_summary().utf16);
    assert!(
        source
            .prepare_resident_replacement(&mounted, first, last, "Ω🌱\n")?
            .is_none()
    );
    assert!(
        source
            .prepare_replacement_with_positions(&mounted, first, last, "Ω🌱\n", Some(&start), None)?
            .is_none()
    );
    let stats = engine.stats();
    let candidate = source
        .prepare_replacement_with_positions(
            &mounted,
            first,
            last,
            "Ω🌱\n",
            Some(&start),
            Some(&end),
        )?
        .ok_or(Error::Invalid("actual retained endpoints did not prepare"))?;
    assert_eq!(engine.stats().page_reads, stats.page_reads);
    assert_eq!(engine.stats().page_writes, stats.page_writes);
    assert!(
        source.capture().same(&before),
        "preparation cannot consume a native source"
    );
    assert_eq!(candidate.window.text(), "Ω🌱\n");
    assert_eq!(candidate.window.start(), start.point());
    assert_eq!(
        candidate.cursor.point(),
        start.point().checked_add(TextSummary::of("Ω🌱\n"))?
    );
    assert!(
        matches!(
            source.prepare_replacement_with_positions(
                &mounted,
                first + 1,
                last,
                "x",
                Some(&start),
                Some(&end),
            ),
            Err(Error::Stale)
        ),
        "a caller offset cannot relabel a retained proof"
    );
    assert!(source.capture().same(&before));
    let expected = format!(
        "{}Ω🌱\n{}",
        &text[..start.point().bytes as usize],
        &text[end.point().bytes as usize..]
    );
    source.install_prepared(candidate.window.snapshot());
    let installed = source.capture();
    assert_eq!(installed.summary(), TextSummary::of(&expected));
    assert!(
        matches!(
            source.prepare_replacement_with_positions(
                &candidate.window,
                first,
                first,
                "x",
                Some(&start),
                Some(&start),
            ),
            Err(Error::Stale)
        ),
        "equal coordinates on a later root are not the old proof"
    );
    assert!(source.capture().same(&installed));
    assert_source(&mut engine, &before, &text)?;
    assert_source(&mut engine, &installed, &expected)?;
    let revision = engine.materialize_logical(&source.capture_for_publication()?, &mut || false)?;
    let reopened = engine.open(revision)?;
    assert_eq!(contents(&mut engine, &reopened)?, expected);
    source.install_prepared(&before); // exact retained Undo root
    assert_source(&mut engine, &source.capture(), &text)?;
    Ok(())
}

#[test]
fn abandoned_structural_prepare_keeps_head_and_later_input_then_installed_candidate_saves()
-> Result<()> {
    let (mut engine, document) = small("head🙂tail")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let initial = engine.logical_window(&source.capture(), 0, 16_384, &mut || false)?;
    let live = source.replace_window(&initial, 4..4, "unsaved")?.window;
    let before = source.capture();
    let failed_stage = source
        .prepare_resident_replacement(&live, 0, before.summary().utf16, "candidateé")?
        .ok_or(Error::Invalid("known full extent"))?;
    assert!(source.capture().same(&before));
    assert_eq!(entire(&mut engine, &before)?, "headunsaved🙂tail");
    drop(failed_stage); // cancellation/mount preflight refusal, no consume
    let changed = source.replace_window(&live, 11..11, "later")?.window;
    let current = source.capture();
    let ready = source
        .prepare_resident_replacement(&changed, 0, current.summary().utf16, "installed🌱")?
        .ok_or(Error::Invalid("known current full extent"))?;
    assert!(current.same(&source.capture()));
    source.install_prepared(ready.window.snapshot());
    let saved = source.capture_for_publication()?;
    let persisted = engine.materialize_logical(&saved, &mut || false)?;
    let opened = engine.open(persisted)?;
    assert_eq!(contents(&mut engine, &opened)?, "installed🌱");
    assert_eq!(entire(&mut engine, &current)?, "headunsavedlater🙂tail");
    Ok(())
}

fn assert_source(
    engine: &mut TextEngine<MemoryPages>,
    snapshot: &LogicalSnapshot,
    expected: &str,
) -> Result<()> {
    assert_eq!(snapshot.summary().bytes, expected.len() as u64);
    let mut at = 0_u64;
    while at < snapshot.summary().bytes {
        let end = (at + TEXT_PAGE_BYTES as u64).min(snapshot.summary().bytes);
        let bytes = engine.logical_read_range(snapshot, at..end, &mut || false)?;
        assert_eq!(bytes, expected.as_bytes()[at as usize..end as usize]);
        at = end;
    }
    Ok(())
}

fn command(
    engine: &mut TextEngine<MemoryPages>,
    snapshot: LogicalSnapshot,
    request: crate::logical_commands::LogicalCommandRequest,
) -> Result<crate::logical_commands::LogicalCommandResult> {
    let mut command =
        crate::logical_commands::LogicalCommand::new(engine, snapshot, request, &mut || false)?;
    for _ in 0..1_000_000 {
        let progress = command.step(engine, &mut || false)?;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES * 2);
        if progress.complete {
            return command.finish();
        }
    }
    Err(Error::Invalid("logical test command did not finish"))
}

#[test]
fn logical_worker_queries_and_candidates_never_write_or_advance_main() -> Result<()> {
    use crate::logical_commands::{
        LogicalCommandRequest as Request, LogicalCommandResult as Reply, LogicalTextEdit,
    };
    let (mut engine, document) = small("a🙂\r\nsecond\u{2028}third\u{2029}tail")?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let opening = engine.logical_window(&source.capture(), 0, 16_384, &mut || false)?;
    let edited = source.replace_window(&opening, 1..1, "é")?;
    let snapshot = source.capture_for_publication()?;
    let writes = engine.stats().page_writes;
    let point = engine.logical_byte_position(&snapshot, 3)?.point();
    assert_eq!(point.utf16, 2);
    assert!(engine.logical_byte_position(&snapshot, 4).is_err());
    let Reply::Point(next) = command(
        &mut engine,
        snapshot.clone(),
        Request::Grapheme {
            at: 2,
            forward: true,
        },
    )?
    else {
        return Err(Error::Invalid("logical grapheme test result"));
    };
    assert_eq!(next.utf16, 4);
    let Reply::Paragraph(bounds) = command(
        &mut engine,
        snapshot.clone(),
        Request::Paragraph {
            at: 2,
            include_line_endings: true,
        },
    )?
    else {
        return Err(Error::Invalid("logical paragraph test result"));
    };
    assert_eq!(bounds.start, TextSummary::EMPTY);
    assert_eq!(bounds.content_end.utf16, 4);
    assert_eq!(bounds.end.utf16, 6);
    let Reply::Edit { edit, selection } = command(
        &mut engine,
        snapshot.clone(),
        Request::Edits {
            edits: vec![LogicalTextEdit {
                start: 1,
                end: 3,
                old_text: "é".into(),
                new_text: "🌱".into(),
            }],
            selection: None,
        },
    )?
    else {
        return Err(Error::Invalid("logical candidate test result"));
    };
    assert!(source.capture().same(&snapshot));
    assert_eq!(selection.start, 3);
    assert_eq!(
        entire(&mut engine, edit.window.snapshot())?,
        "a🌱🙂\r\nsecond\u{2028}third\u{2029}tail"
    );
    assert_eq!(engine.stats().page_writes, writes);
    assert_eq!(edited.cursor.point().utf16, 2);
    Ok(())
}

#[test]
fn logical_wrapping_keeps_distant_selection_and_toggles_both_native_forms() -> Result<()> {
    use crate::logical_commands::{
        LogicalCommandRequest as Request, LogicalCommandResult as Reply, LogicalSelection,
    };
    let text = "🙂word\n".repeat(100_000); // >1MiB control, bounded real page IO
    let (mut engine, document) = small(&text)?;
    let source = LogicalSource::new(document.revision().clone())?.capture();
    let selected = LogicalSelection {
        start: 0,
        length: source.summary().utf16,
        focus_at_end: true,
    };
    let writes = engine.stats().page_writes;
    let Reply::Edit {
        edit: wrapped,
        selection,
    } = command(
        &mut engine,
        source.clone(),
        Request::Wrapping {
            selection: selected,
            prefix: "**".into(),
            suffix: "**".into(),
            toggles: true,
        },
    )?
    else {
        return Err(Error::Invalid("logical wrap result"));
    };
    assert_eq!(selection.start, 2);
    assert_eq!(selection.length, selected.length);
    assert!(wrapped.window.start().utf16 > 0); // real focus is at distant end
    let Reply::Edit {
        edit: outside,
        selection: restored,
    } = command(
        &mut engine,
        wrapped.window.snapshot().clone(),
        Request::Wrapping {
            selection,
            prefix: "**".into(),
            suffix: "**".into(),
            toggles: true,
        },
    )?
    else {
        return Err(Error::Invalid("logical outside unwrap result"));
    };
    assert_eq!(restored.start, 0);
    assert_eq!(restored.length, selected.length);
    assert_source(&mut engine, outside.window.snapshot(), &text)?;
    let whole = LogicalSelection {
        start: 0,
        length: wrapped.window.snapshot().summary().utf16,
        focus_at_end: false,
    };
    let Reply::Edit {
        edit: inside,
        selection: restored,
    } = command(
        &mut engine,
        wrapped.window.snapshot().clone(),
        Request::Wrapping {
            selection: whole,
            prefix: "**".into(),
            suffix: "**".into(),
            toggles: true,
        },
    )?
    else {
        return Err(Error::Invalid("logical inside unwrap result"));
    };
    assert_eq!(restored.start, 0);
    assert_eq!(restored.length, selected.length);
    assert_source(&mut engine, inside.window.snapshot(), &text)?;
    assert_eq!(engine.stats().page_writes, writes);
    Ok(())
}

#[test]
fn logical_prefix_steps_cover_crlf_cr_unicode_empty_lines_and_large_toggle() -> Result<()> {
    use crate::logical_commands::{
        LogicalCommandRequest as Request, LogicalCommandResult as Reply, LogicalSelection,
    };
    let text = "é🙂\r\n\rnext\u{85}line\u{2028}part\u{2029}last\n".repeat(90_000);
    let (mut engine, document) = small(&text)?;
    let source = LogicalSource::new(document.revision().clone())?.capture();
    let selected = LogicalSelection {
        start: 0,
        length: source.summary().utf16,
        focus_at_end: true,
    };
    let writes = engine.stats().page_writes;
    let Reply::Edit { edit, selection } = command(
        &mut engine,
        source.clone(),
        Request::LinePrefix {
            selection: selected,
            prefix: "> ".into(),
        },
    )?
    else {
        return Err(Error::Invalid("logical prefix result"));
    };
    assert_eq!(
        source.summary().lf_count,
        edit.window.snapshot().summary().lf_count
    );
    assert!(selection.length > selected.length);
    assert!(edit.window.local_summary().bytes <= 16_384);
    assert_eq!(edit.window.snapshot().resident_spans(), 1);
    let bytes = engine.logical_read_range(edit.window.snapshot(), 0..64, &mut || false)?;
    assert!(
        bytes.starts_with(
            "> é🙂\r\n> \r> next\u{85}> line\u{2028}> part\u{2029}> last\n".as_bytes()
        )
    );
    let Reply::Edit {
        edit: restored,
        selection: restored_selection,
    } = command(
        &mut engine,
        edit.window.snapshot().clone(),
        Request::LinePrefix {
            selection,
            prefix: "> ".into(),
        },
    )?
    else {
        return Err(Error::Invalid("logical toggle result"));
    };
    assert_eq!(restored_selection.length, selected.length);
    assert_source(&mut engine, restored.window.snapshot(), &text)?;
    assert_eq!(restored.window.snapshot().resident_spans(), 1);
    let appended = engine.stats().page_writes - writes;
    // Real packed candidate pages, not one resident/file piece for every line.
    assert!(appended > 0 && appended < 256);
    Ok(())
}

#[test]
fn logical_long_cluster_yields_and_cancellation_discards_only_candidate() -> Result<()> {
    use crate::logical_commands::{
        LogicalCommandRequest as Request, LogicalCommandResult as Reply,
    };
    let text = format!("x{}🌱", "\u{301}".repeat(TEXT_PAGE_BYTES * 2));
    let (mut engine, document) = small(&text)?;
    let source = LogicalSource::new(document.revision().clone())?.capture();
    let mut request = crate::logical_commands::LogicalCommand::new(
        &mut engine,
        source.clone(),
        Request::Grapheme {
            at: 0,
            forward: true,
        },
        &mut || false,
    )?;
    let mut steps = 0;
    loop {
        steps += 1;
        let progress = request.step(&mut engine, &mut || false)?;
        assert!(progress.buffered_bytes <= TEXT_PAGE_BYTES);
        if progress.complete {
            break;
        }
        let middle = engine.logical_position(&source, 1, false)?.point(); // real foreground work between bounded steps
        assert_eq!(middle.bytes, 1);
    }
    assert!(steps > 4);
    let Reply::Point(point) = request.finish()? else {
        return Err(Error::Invalid("logical cluster result"));
    };
    assert_eq!(point.utf16, 1 + (TEXT_PAGE_BYTES * 2) as u64);
    let mut cancelled = crate::logical_commands::LogicalCommand::new(
        &mut engine,
        source.clone(),
        Request::Grapheme {
            at: 0,
            forward: true,
        },
        &mut || false,
    )?;
    assert!(matches!(
        cancelled.step(&mut engine, &mut || true),
        Err(Error::Cancelled)
    ));
    drop(cancelled);
    assert_source(&mut engine, &source, &text)?;
    Ok(())
}

#[test]
fn prefix_cancel_after_real_candidate_appends_keeps_native_head_and_later_keys() -> Result<()> {
    use crate::logical_commands::{LogicalCommandRequest as Request, LogicalSelection};
    let text = "é🙂\r\nline\u{2028}".repeat(10_000);
    let (mut engine, document) = small(&text)?;
    let mut source = LogicalSource::new(document.revision().clone())?;
    let window = engine.logical_window(&source.capture(), 0, 16_384, &mut || false)?;
    let edited = source.replace_window(&window, 0..0, "unsaved")?.window;
    let captured = source.capture_for_publication()?;
    let writes = engine.stats().page_writes;
    let mut request = crate::logical_commands::LogicalCommand::new(
        &mut engine,
        captured.clone(),
        Request::LinePrefix {
            selection: LogicalSelection {
                start: 0,
                length: captured.summary().utf16,
                focus_at_end: true,
            },
            prefix: "> ".into(),
        },
        &mut || false,
    )?;
    for _ in 0..1000 {
        let progress = request.step(&mut engine, &mut || false)?;
        assert!(!progress.complete);
        if engine.stats().page_writes > writes {
            break;
        }
    }
    assert!(
        engine.stats().page_writes > writes,
        "actual bounded candidate frames have entered"
    );
    assert!(matches!(
        request.step(&mut engine, &mut || true),
        Err(Error::Cancelled)
    ));
    drop(request);
    assert!(source.capture().same(&captured));
    source.replace_window(&edited, 7..7, "later")?;
    assert_source(&mut engine, &captured, &format!("unsaved{text}"))?;
    assert_source(
        &mut engine,
        &source.capture_for_publication()?,
        &format!("unsavedlater{text}"),
    )?;
    Ok(())
}

#[test]
fn prefix_empty_final_paragraph_and_crlf_page_edge_preserve_native_lines() -> Result<()> {
    use crate::logical_commands::{
        LogicalCommandRequest as Request, LogicalCommandResult as Reply, LogicalSelection,
    };
    for text in [
        String::new(),
        "a\n".into(),
        format!("{}\r\nend", "a".repeat(TEXT_PAGE_BYTES - 3)),
    ] {
        let (mut engine, document) = small(&text)?;
        let source = LogicalSource::new(document.revision().clone())?.capture();
        let selection = LogicalSelection {
            start: if text.len() < 3 {
                source.summary().utf16
            } else {
                0
            },
            length: if text.len() < 3 {
                0
            } else {
                source.summary().utf16
            },
            focus_at_end: false,
        };
        let Reply::Edit { edit, .. } = command(
            &mut engine,
            source.clone(),
            Request::LinePrefix {
                selection,
                prefix: "> ".into(),
            },
        )?
        else {
            return Err(Error::Invalid("actual empty paragraph prefix"));
        };
        let expected = if text.len() < 3 {
            format!("{text}> ")
        } else {
            format!("> {}", text.replace("\r\n", "\r\n> "))
        };
        assert_source(&mut engine, edit.window.snapshot(), &expected)?;
        assert_source(&mut engine, &source, &text)?;
    }
    Ok(())
}
