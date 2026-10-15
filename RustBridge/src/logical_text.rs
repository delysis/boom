//! Retained native values. Only materialize uses the existing writer EngineSlot.
//! Source edits/Undo do not take that slot, encode trees or invoke callbacks.
use super::*;
use bloom_text::{
    LogicalPosition, LogicalSnapshot, LogicalSource, LogicalWindow, LogicalWindowSeed, TextSummary,
};
use std::ptr;

pub struct BloomLogicalSource {
    value: Mutex<LogicalSource>,
}
pub struct BloomLogicalSnapshot {
    value: LogicalSnapshot,
}
pub struct BloomLogicalWindow {
    value: LogicalWindow,
}
pub struct BloomLogicalWindowSeed {
    value: LogicalWindowSeed,
}
pub struct BloomLogicalPosition {
    value: LogicalPosition,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct BloomLogicalPoint {
    pub bytes: u64,
    pub utf16: u64,
    pub lf_count: u64,
}
impl From<TextSummary> for BloomLogicalPoint {
    fn from(value: TextSummary) -> Self {
        Self {
            bytes: value.bytes,
            utf16: value.utf16,
            lf_count: value.lf_count,
        }
    }
}
#[repr(C)]
pub struct BloomLogicalSnapshotInfo {
    pub root_id: [u8; 16],
    pub owner_id: [u8; 16],
    pub document_id: [u8; 16],
    pub summary: BloomLogicalPoint,
}
#[repr(C)]
pub struct BloomLogicalWindowInfo {
    pub root_id: [u8; 16],
    pub window_id: [u8; 16],
    pub start: BloomLogicalPoint,
    pub summary: BloomLogicalPoint,
    pub text: *const u8,
    pub text_length: usize,
}

#[repr(C)]
pub struct BloomLogicalSeedInfo {
    pub start: BloomLogicalPoint,
    pub summary: BloomLogicalPoint,
}
fn failed(error: Error) -> Value {
    super::error(
        match error {
            Error::Stale => "stale",
            Error::Cancelled => "cancelled",
            Error::Invalid(_) => "invalid",
            Error::Storage(_) | Error::Io(_) => "storage_failed",
        },
        &error.to_string(),
    )
}
unsafe fn call(
    error_output: *mut BoomAttachmentBuffer,
    body: impl FnOnce() -> bloom_text::Result<()>,
) -> i32 {
    if error_output.is_null() {
        return 1;
    }
    // SAFETY: caller lends this ordinary output struct for the call.
    unsafe {
        *error_output = BoomAttachmentBuffer {
            data: ptr::null_mut(),
            length: 0,
        };
    }
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => 0,
        outcome => {
            let error = match outcome {
                Ok(Err(error)) => failed(error),
                _ => super::error("engine_panic", "Native source failed."),
            };
            // SAFETY: output struct remains borrowed; caller frees its owned buffer.
            unsafe {
                *error_output = owned_reply(&error);
            }
            1
        }
    }
}
unsafe fn text<'a>(bytes: *const u8, length: usize) -> bloom_text::Result<&'a str> {
    if length == 0 {
        return Ok("");
    }
    if bytes.is_null() || length > isize::MAX as usize {
        return Err(Error::Invalid("native text buffer"));
    }
    // SAFETY: caller lends these readable bytes through the enclosing call.
    std::str::from_utf8(unsafe { slice::from_raw_parts(bytes, length) })
        .map_err(|_| Error::Invalid("native text UTF8"))
}

/// # Safety
/// All nonnull values are actual retained handles from these functions, and
/// output pointers refer to writable structs. Source calls are Main-owned;
/// snapshots/windows can be retained across read workers. No handle may be
/// released until its borrower returns. Errors use boom_attachment_free.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_create(
    bytes: *const u8,
    length: usize,
    output: *mut *mut BloomLogicalSource,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() || length == 0 || length > 16 * 1024 {
                return Err(Error::Invalid("native revision bound"));
            }
            let revision: Revision = serde_json::from_str(text(bytes, length)?)
                .map_err(|_| Error::Invalid("native revision"))?;
            let value = LogicalSource::new(revision)?;
            *output = Box::into_raw(Box::new(BloomLogicalSource {
                value: Mutex::new(value),
            }));
            Ok(())
        })
    }
}
/// # Safety
/// Consume the actual source exactly once after every source borrower joined.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_free(source: *mut BloomLogicalSource) {
    if !source.is_null() {
        unsafe {
            drop(Box::from_raw(source));
        }
    }
}
/// # Safety
/// Source/output/error obey the retained-handle contract above.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_capture(
    source: *const BloomLogicalSource,
    freeze_for_publication: u8,
    output: *mut *const BloomLogicalSnapshot,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let source = source.as_ref().ok_or(Error::Invalid("native source"))?;
            if output.is_null() {
                return Err(Error::Invalid("native snapshot output"));
            }
            let mut source = source
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("reentered native source"))?;
            let value = if freeze_for_publication != 0 {
                source.capture_for_publication()?
            } else {
                source.capture()
            };
            *output = Arc::into_raw(Arc::new(BloomLogicalSnapshot { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Borrow the actual same-owner source and immutable snapshot through return.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_restore(
    source: *const BloomLogicalSource,
    snapshot: *const BloomLogicalSnapshot,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let source = source.as_ref().ok_or(Error::Invalid("native source"))?;
            let snapshot = snapshot.as_ref().ok_or(Error::Invalid("native snapshot"))?;
            source
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("reentered native source"))?
                .restore(&snapshot.value)
        })
    }
}
/// # Safety
/// All values are preflighted by the exclusive synchronous Main consumer.
/// There are no other source borrowers. It is an internal invariant failure
/// to call this with a foreign source; user input never selects raw handles.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_install_prepared(
    source: *const BloomLogicalSource,
    snapshot: *const BloomLogicalSnapshot,
) {
    let source = unsafe { source.as_ref() }.expect("actual native source");
    let snapshot = unsafe { snapshot.as_ref() }.expect("actual prepared snapshot");
    source
        .value
        .try_lock()
        .expect("exclusive Main logical adoption")
        .install_prepared(&snapshot.value);
}
/// # Safety
/// Actual source and its factory-validated file window JSON are lent through
/// this one opening call. No host or file access occurs here.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_opening_window(
    source: *const BloomLogicalSource,
    bytes: *const u8,
    length: usize,
    output: *mut *const BloomLogicalWindow,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Opening {
        revision: Revision,
        byte_start: u64,
        utf16_start: u64,
        lf_start: u64,
        text: String,
    }
    unsafe {
        call(error, || {
            if output.is_null() || length > 128 * 1024 {
                return Err(Error::Invalid("native opening window bound"));
            }
            let source = source.as_ref().ok_or(Error::Invalid("native source"))?;
            let opening: Opening = serde_json::from_str(text(bytes, length)?)
                .map_err(|_| Error::Invalid("native opening window"))?;
            let source = source
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("reentered native opening"))?;
            let value = LogicalWindow::opening(
                &source.capture(),
                &opening.revision,
                TextSummary {
                    bytes: opening.byte_start,
                    utf16: opening.utf16_start,
                    lf_count: opening.lf_start,
                },
                opening.text,
            )?;
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual retained window/output; the seed retains bounded text and root but
/// no scalar table. Native focus is admitted through that existing table.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_seed(
    window: *const BloomLogicalWindow,
    focus_utf16: u64,
    output: *mut *const BloomLogicalWindowSeed,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null() {
                return Err(Error::Invalid("native seed output"));
            }
            let value = window.value.seed(focus_utf16)?;
            *output = Arc::into_raw(Arc::new(BloomLogicalWindowSeed { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual retained seed/output; all preparation occurs before SDK advancement.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_seed_window(
    seed: *const BloomLogicalWindowSeed,
    output: *mut *const BloomLogicalWindow,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let seed = seed.as_ref().ok_or(Error::Invalid("native seed"))?;
            if output.is_null() {
                return Err(Error::Invalid("native seed window output"));
            }
            let value = LogicalWindow::from_seed(&seed.value)?;
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual retained seed and writable bounded metadata output.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_seed_info(
    seed: *const BloomLogicalWindowSeed,
    output: *mut BloomLogicalSeedInfo,
) -> i32 {
    unsafe {
        let (Some(seed), Some(output)) = (seed.as_ref(), output.as_mut()) else {
            return 1;
        };
        *output = BloomLogicalSeedInfo {
            start: seed.value.start().into(),
            summary: seed.value.summary().into(),
        };
    }
    0
}
/// # Safety
/// Consume one actual seed reference after every borrower returns.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_seed_free(seed: *const BloomLogicalWindowSeed) {
    if !seed.is_null() {
        unsafe {
            Arc::decrement_strong_count(seed);
        }
    }
}
/// # Safety
/// Borrow actual source/window and UTF8 insertion. Outputs are writable. This
/// function does not call a host, perform I/O or acquire the writer EngineSlot.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_replace(
    source: *const BloomLogicalSource,
    window: *const BloomLogicalWindow,
    byte_start: usize,
    byte_end: usize,
    insertion: *const u8,
    insertion_length: usize,
    output: *mut *const BloomLogicalWindow,
    cursor: *mut BloomLogicalPoint,
    changed: *mut u8,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let source = source.as_ref().ok_or(Error::Invalid("native source"))?;
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null()
                || cursor.is_null()
                || changed.is_null()
                || insertion_length > bloom_text::WINDOW_BYTES
            {
                return Err(Error::Invalid("native edit output"));
            }
            let inserted = text(insertion, insertion_length)?;
            let result = source
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("reentered native source"))?
                .replace_window(&window.value, byte_start..byte_end, inserted)?;
            *cursor = result.cursor.point().into();
            *changed = u8::from(result.changed);
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow {
                value: result.window,
            }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual source/current window and bounded UTF8 input. This prepares an
/// immutable candidate without advancing the source; consume is separate.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_prepare_replacement(
    source: *const BloomLogicalSource,
    window: *const BloomLogicalWindow,
    first_utf16: u64,
    last_utf16: u64,
    insertion: *const u8,
    insertion_length: usize,
    output: *mut *const BloomLogicalWindow,
    cursor: *mut BloomLogicalPoint,
    changed: *mut u8,
    resident: *mut u8,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    // SAFETY: same borrowed handles/output contract; absent retained positions
    // preserve the existing exact-window/start/end path.
    unsafe {
        bloom_logical_source_prepare_replacement_with_positions(
            source,
            window,
            first_utf16,
            last_utf16,
            ptr::null(),
            ptr::null(),
            insertion,
            insertion_length,
            output,
            cursor,
            changed,
            resident,
            error,
        )
    }
}
/// # Safety
/// Same actual source/window/output contract, plus optional retained positions
/// created by bloom_logical_window_position_proof. Their root/offset must match.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_source_prepare_replacement_with_positions(
    source: *const BloomLogicalSource,
    window: *const BloomLogicalWindow,
    first_utf16: u64,
    last_utf16: u64,
    first_position: *const BloomLogicalPosition,
    last_position: *const BloomLogicalPosition,
    insertion: *const u8,
    insertion_length: usize,
    output: *mut *const BloomLogicalWindow,
    cursor: *mut BloomLogicalPoint,
    changed: *mut u8,
    resident: *mut u8,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let source = source.as_ref().ok_or(Error::Invalid("native source"))?;
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null()
                || cursor.is_null()
                || changed.is_null()
                || resident.is_null()
                || insertion_length > bloom_text::WINDOW_BYTES
            {
                return Err(Error::Invalid("native candidate output"));
            }
            *output = ptr::null();
            *resident = 0;
            let result = source
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("reentered native source"))?
                .prepare_replacement_with_positions(
                    &window.value,
                    first_utf16,
                    last_utf16,
                    text(insertion, insertion_length)?,
                    first_position.as_ref().map(|position| &position.value),
                    last_position.as_ref().map(|position| &position.value),
                )?;
            if let Some(result) = result {
                *resident = 1;
                *changed = u8::from(result.changed);
                *cursor = result.cursor.point().into();
                *output = Arc::into_raw(Arc::new(BloomLogicalWindow {
                    value: result.window,
                }));
            }
            Ok(())
        })
    }
}
/// # Safety
/// Borrow the actual window; output is an owned retained bounded window.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_trim(
    window: *const BloomLogicalWindow,
    local_focus_utf16: u64,
    maximum_bytes: usize,
    output: *mut *const BloomLogicalWindow,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null() {
                return Err(Error::Invalid("native trim output"));
            }
            let value = window.value.trimmed(local_focus_utf16, maximum_bytes)?;
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual retained pointer and writable metadata output; text remains borrowed
/// only while the immutable window is retained. No cache or String is cloned.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_info(
    window: *const BloomLogicalWindow,
    output: *mut BloomLogicalWindowInfo,
) -> i32 {
    unsafe {
        let (Some(window), Some(output)) = (window.as_ref(), output.as_mut()) else {
            return 1;
        };
        *output = BloomLogicalWindowInfo {
            root_id: *window.value.snapshot().id().as_bytes(),
            window_id: *window.value.id().as_bytes(),
            start: window.value.start().into(),
            summary: window.value.local_summary().into(),
            text: window.value.text().as_ptr(),
            text_length: window.value.text().len(),
        };
    }
    0
}
/// # Safety
/// Actual retained window; requested position is local UTF16. Half-surrogates
/// are rejected using the window's already prepared scalar table.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_position(
    window: *const BloomLogicalWindow,
    local_utf16: u64,
    output: *mut BloomLogicalPoint,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null() {
                return Err(Error::Invalid("native position output"));
            }
            *output = window.value.position(local_utf16)?.point().into();
            Ok(())
        })
    }
}
/// # Safety
/// Actual retained window, scalar-valid local UTF16 and writable outputs. The
/// retained result owns only its exact snapshot/summary, not a window/table.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_position_proof(
    window: *const BloomLogicalWindow,
    local_utf16: u64,
    output: *mut *const BloomLogicalPosition,
    point: *mut BloomLogicalPoint,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let window = window.as_ref().ok_or(Error::Invalid("native window"))?;
            if output.is_null() || point.is_null() {
                return Err(Error::Invalid("native retained position output"));
            }
            *output = ptr::null();
            let value = window.value.position(local_utf16)?;
            *point = value.point().into();
            *output = Arc::into_raw(Arc::new(BloomLogicalPosition { value }));
            Ok(())
        })
    }
}
/// # Safety
/// Consume one actual position reference only after every borrower returned.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_position_free(position: *const BloomLogicalPosition) {
    if !position.is_null() {
        unsafe {
            Arc::decrement_strong_count(position);
        }
    }
}
/// # Safety
/// Actual retained window and writable output. Returned snapshot is retained.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_snapshot(
    window: *const BloomLogicalWindow,
    output: *mut *const BloomLogicalSnapshot,
) -> i32 {
    unsafe {
        let (Some(window), Some(output)) = (window.as_ref(), output.as_mut()) else {
            return 1;
        };
        *output = Arc::into_raw(Arc::new(BloomLogicalSnapshot {
            value: window.value.snapshot().clone(),
        }));
    }
    0
}
/// # Safety
/// Borrow actual retained snapshot and writable info output.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_snapshot_info(
    snapshot: *const BloomLogicalSnapshot,
    output: *mut BloomLogicalSnapshotInfo,
) -> i32 {
    unsafe {
        let (Some(snapshot), Some(output)) = (snapshot.as_ref(), output.as_mut()) else {
            return 1;
        };
        *output = BloomLogicalSnapshotInfo {
            root_id: *snapshot.value.id().as_bytes(),
            owner_id: *snapshot.value.origin().owner_id.as_bytes(),
            document_id: *snapshot.value.origin().document_id.as_bytes(),
            summary: snapshot.value.summary().into(),
        };
    }
    0
}
/// # Safety
/// Increment an actual live snapshot reference; never retain after final free.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_snapshot_retain(snapshot: *const BloomLogicalSnapshot) {
    if !snapshot.is_null() {
        unsafe {
            Arc::increment_strong_count(snapshot);
        }
    }
}
/// # Safety
/// Consume one actual snapshot reference after its borrowers have returned.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_snapshot_free(snapshot: *const BloomLogicalSnapshot) {
    if !snapshot.is_null() {
        unsafe {
            Arc::decrement_strong_count(snapshot);
        }
    }
}
/// # Safety
/// Increment an actual live window reference; never retain after final free.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_retain(window: *const BloomLogicalWindow) {
    if !window.is_null() {
        unsafe {
            Arc::increment_strong_count(window);
        }
    }
}
/// # Safety
/// Consume one actual window reference after its borrowers have returned.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_window_free(window: *const BloomLogicalWindow) {
    if !window.is_null() {
        unsafe {
            Arc::decrement_strong_count(window);
        }
    }
}

/// # Safety
/// Host is read-only schema3. Its callbacks/cancellation/snapshot remain live
/// until return. The existing owner pins referenced file extents during read.
/// This creates no EngineSlot; its bounded cache dies before returning window.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_read_window(
    host: BloomTextHost,
    snapshot: *const BloomLogicalSnapshot,
    utf16_anchor: u64,
    maximum_bytes: usize,
    operation: BloomTextOperation,
    output: *mut *const BloomLogicalWindow,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let snapshot = snapshot.as_ref().ok_or(Error::Invalid("native snapshot"))?;
            if host.schema != 3 || host.write_page.is_some() || output.is_null() {
                return Err(Error::Invalid("native readonly host"));
            }
            let read = host.read_page.ok_or(Error::Invalid("native page reader"))?;
            let mut reader = TextEngine::with_cache_budget(
                CallbackPages {
                    context: host.context as usize,
                    read,
                    write: None,
                    cancellation: operation
                        .is_cancelled
                        .map(|callback| (operation.context as usize, callback)),
                },
                256 * 1024,
            );
            let value =
                reader.logical_window(&snapshot.value, utf16_anchor, maximum_bytes, &mut || {
                    operation
                        .is_cancelled
                        .is_some_and(|callback| callback(operation.context) != 0)
                })?;
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow { value }));
            Ok(())
        })
    }
}

/// # Safety
/// Actual captured immutable source/readonly host. Coordinates are resolved
/// against its real tree; output is an unpublished candidate value only.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_prepare_replacement(
    host: BloomTextHost,
    snapshot: *const BloomLogicalSnapshot,
    first_utf16: u64,
    last_utf16: u64,
    insertion: *const u8,
    insertion_length: usize,
    operation: BloomTextOperation,
    output: *mut *const BloomLogicalWindow,
    cursor: *mut BloomLogicalPoint,
    changed: *mut u8,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let snapshot = snapshot.as_ref().ok_or(Error::Invalid("native snapshot"))?;
            if host.schema != 3
                || host.write_page.is_some()
                || output.is_null()
                || cursor.is_null()
                || changed.is_null()
                || insertion_length > bloom_text::WINDOW_BYTES
            {
                return Err(Error::Invalid("native readonly candidate host"));
            }
            let read = host
                .read_page
                .ok_or(Error::Invalid("native candidate page reader"))?;
            let mut reader = TextEngine::with_cache_budget(
                CallbackPages {
                    context: host.context as usize,
                    read,
                    write: None,
                    cancellation: operation
                        .is_cancelled
                        .map(|callback| (operation.context as usize, callback)),
                },
                256 * 1024,
            );
            let result = reader.prepare_logical_replacement(
                &snapshot.value,
                first_utf16,
                last_utf16,
                text(insertion, insertion_length)?,
                &mut || {
                    operation
                        .is_cancelled
                        .is_some_and(|callback| callback(operation.context) != 0)
                },
            )?;
            *cursor = result.cursor.point().into();
            *changed = u8::from(result.changed);
            *output = Arc::into_raw(Arc::new(BloomLogicalWindow {
                value: result.window,
            }));
            Ok(())
        })
    }
}
/// # Safety
/// Actual captured immutable source/readonly host and writable scalar output.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_read_position(
    host: BloomTextHost,
    snapshot: *const BloomLogicalSnapshot,
    utf16_offset: u64,
    rounding: u8,
    operation: BloomTextOperation,
    output: *mut BloomLogicalPoint,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let snapshot = snapshot.as_ref().ok_or(Error::Invalid("native snapshot"))?;
            if host.schema != 3 || host.write_page.is_some() || output.is_null() || rounding > 2 {
                return Err(Error::Invalid("native readonly position host"));
            }
            let read = host
                .read_page
                .ok_or(Error::Invalid("native position page reader"))?;
            let mut reader = TextEngine::with_cache_budget(
                CallbackPages {
                    context: host.context as usize,
                    read,
                    write: None,
                    cancellation: operation
                        .is_cancelled
                        .map(|callback| (operation.context as usize, callback)),
                },
                256 * 1024,
            );
            if operation
                .is_cancelled
                .is_some_and(|callback| callback(operation.context) != 0)
            {
                return Err(Error::Cancelled);
            }
            let mut point = reader
                .logical_position(&snapshot.value, utf16_offset, rounding != 0)?
                .point();
            if rounding == 1 && point.utf16 > utf16_offset {
                point = reader
                    .logical_position(
                        &snapshot.value,
                        utf16_offset
                            .checked_sub(1)
                            .ok_or(Error::Invalid("native rounding start"))?,
                        false,
                    )?
                    .point();
            }
            *output = point.into();
            Ok(())
        })
    }
}
/// # Safety
/// Actual captured immutable source/readonly host; the caller owns and frees
/// one <=128KiB output buffer. Byte endpoints may be used for streaming only.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_read_bytes(
    host: BloomTextHost,
    snapshot: *const BloomLogicalSnapshot,
    first: u64,
    last: u64,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let snapshot = snapshot.as_ref().ok_or(Error::Invalid("native snapshot"))?;
            if host.schema != 3 || host.write_page.is_some() || output.is_null() {
                return Err(Error::Invalid("native byte reader host"));
            }
            let read = host
                .read_page
                .ok_or(Error::Invalid("native byte page reader"))?;
            let mut reader = TextEngine::with_cache_budget(
                CallbackPages {
                    context: host.context as usize,
                    read,
                    write: None,
                    cancellation: operation
                        .is_cancelled
                        .map(|callback| (operation.context as usize, callback)),
                },
                256 * 1024,
            );
            let bytes = reader.logical_read_range(&snapshot.value, first..last, &mut || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| callback(operation.context) != 0)
            })?;
            *output = if bytes.is_empty() {
                BoomAttachmentBuffer {
                    data: ptr::null_mut(),
                    length: 0,
                }
            } else {
                let mut bytes = bytes.into_boxed_slice();
                let output = BoomAttachmentBuffer {
                    data: bytes.as_mut_ptr(),
                    length: bytes.len(),
                };
                std::mem::forget(bytes);
                output
            };
            Ok(())
        })
    }
}
/// # Safety
/// The actual writer executor/host context remains live. Snapshot was frozen
/// before yielding. Result is a candidate Revision, not durable or installed.
#[no_mangle]
pub unsafe extern "C" fn bloom_text_materialize_logical(
    handle: u64,
    snapshot: *const BloomLogicalSnapshot,
    operation: BloomTextOperation,
) -> BoomAttachmentBuffer {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let result = (|| -> bloom_text::Result<Value> {
            let snapshot = unsafe { snapshot.as_ref() }.ok_or(Error::Invalid("native snapshot"))?;
            let slot = engines()
                .lock()
                .map_err(|_| Error::Invalid("writer registry lock"))?
                .get(&handle)
                .cloned()
                .ok_or(Error::Invalid("writer closed"))?;
            let mut guard = slot.try_lock().map_err(|_| Error::Invalid("writer busy"))?;
            let engine = guard.as_mut().ok_or(Error::Invalid("writer closed"))?;
            let revision = engine.materialize_logical(&snapshot.value, &mut || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| unsafe { callback(operation.context) != 0 })
            })?;
            serde_json::to_value(revision).map_err(|_| Error::Invalid("native candidate encoding"))
        })();
        match result {
            Ok(value) => json!({"schema":1,"ok":true,"value":value}),
            Err(error) => failed(error),
        }
    }));
    owned_reply(
        &outcome.unwrap_or_else(|_| super::error("engine_panic", "Native materialization failed.")),
    )
}
/// # Safety
/// Borrow actual snapshot. Call only on existing writer AFTER actual data sync.
/// This frees RAM backing and proves neither root publication nor native ACK.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_release_synced_insertions(
    snapshot: *const BloomLogicalSnapshot,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            snapshot
                .as_ref()
                .ok_or(Error::Invalid("native snapshot"))?
                .value
                .release_synced_insertions()
        })
    }
}

pub struct BloomLogicalCommand {
    value: Mutex<Option<bloom_text::LogicalCommand>>,
}
fn read_engine(
    host: BloomTextHost,
    operation: BloomTextOperation,
) -> bloom_text::Result<TextEngine<CallbackPages>> {
    if host.schema != 3 || host.write_page.is_some() {
        return Err(Error::Invalid("logical command readonly host"));
    }
    let read = host
        .read_page
        .ok_or(Error::Invalid("logical command reader"))?;
    Ok(TextEngine::with_cache_budget(
        CallbackPages {
            context: host.context as usize,
            read,
            write: None,
            cancellation: operation
                .is_cancelled
                .map(|callback| (operation.context as usize, callback)),
        },
        256 * 1024,
    ))
}
/// # Safety
/// Snapshot/host/JSON are borrowed through return. The <=1MiB command contains
/// at most32 bounded explicit edits, or a constant-size structural command.
/// The returned continuation owns only algorithm state and immutable values.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_command_begin(
    host: BloomTextHost,
    snapshot: *const BloomLogicalSnapshot,
    json: *const u8,
    length: usize,
    operation: BloomTextOperation,
    output: *mut *mut BloomLogicalCommand,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() || length > 1024 * 1024 {
                return Err(Error::Invalid("logical command envelope"));
            }
            let snapshot = snapshot
                .as_ref()
                .ok_or(Error::Invalid("logical command snapshot"))?;
            let request = serde_json::from_str(text(json, length)?)
                .map_err(|_| Error::Invalid("logical command JSON"))?;
            let mut engine = read_engine(host, operation)?;
            let value = bloom_text::LogicalCommand::new(
                &mut engine,
                snapshot.value.clone(),
                request,
                &mut || {
                    operation
                        .is_cancelled
                        .is_some_and(|callback| callback(operation.context) != 0)
                },
            )?;
            *output = Box::into_raw(Box::new(BloomLogicalCommand {
                value: Mutex::new(Some(value)),
            }));
            Ok(())
        })
    }
}
/// # Safety
/// One entered reader borrows the actual command/host. At most one bounded
/// piece/context is fetched per query step, then this call releases its cache.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_command_step(
    host: BloomTextHost,
    command: *const BloomLogicalCommand,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let command = command.as_ref().ok_or(Error::Invalid("logical command"))?;
            if output.is_null() {
                return Err(Error::Invalid("logical command progress"));
            }
            let mut engine = read_engine(host, operation)?;
            let mut command = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("logical command reentry"))?;
            let command = command
                .as_mut()
                .ok_or(Error::Invalid("logical command consumed"))?;
            if command.requires_writes() {
                return Err(Error::Invalid("logical command requires writer step"));
            }
            let progress = command.step(&mut engine, &mut || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| callback(operation.context) != 0)
            })?;
            *output = owned_reply(
                &serde_json::to_value(progress)
                    .map_err(|_| Error::Invalid("logical command progress JSON"))?,
            );
            Ok(())
        })
    }
}
/// # Safety
/// The same existing writer executor lends its registered engine and the
/// actual entered command. Only bounded candidate appends occur: no root
/// publication, source adoption or sync. Caller joins this step before free.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_command_writer_step(
    handle: u64,
    command: *const BloomLogicalCommand,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let command = command.as_ref().ok_or(Error::Invalid("logical command"))?;
            if output.is_null() {
                return Err(Error::Invalid("logical command progress"));
            }
            let mut command = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("logical command reentry"))?;
            let command = command
                .as_mut()
                .ok_or(Error::Invalid("logical command consumed"))?;
            if !command.requires_writes() {
                return Err(Error::Invalid("logical command requires readonly step"));
            }
            let slot = engines()
                .lock()
                .map_err(|_| Error::Invalid("writer registry lock"))?
                .get(&handle)
                .cloned()
                .ok_or(Error::Invalid("writer closed"))?;
            let mut guard = slot.try_lock().map_err(|_| Error::Invalid("writer busy"))?;
            let engine = guard.as_mut().ok_or(Error::Invalid("writer closed"))?;
            let progress = command.step(engine, &mut || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| callback(operation.context) != 0)
            })?;
            *output = owned_reply(
                &serde_json::to_value(progress)
                    .map_err(|_| Error::Invalid("logical command progress JSON"))?,
            );
            Ok(())
        })
    }
}
/// # Safety
/// Finish after actual complete progress. Result JSON is <=4KiB; a candidate
/// window is an unpublished retained value. The handle remains for one free.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_command_finish(
    command: *const BloomLogicalCommand,
    window: *mut *const BloomLogicalWindow,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            let command = command.as_ref().ok_or(Error::Invalid("logical command"))?;
            if output.is_null() || window.is_null() {
                return Err(Error::Invalid("logical command finish output"));
            }
            let result = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("logical command reentry"))?
                .take()
                .ok_or(Error::Invalid("logical command consumed"))?
                .finish()?;
            let value = match result {
                bloom_text::LogicalCommandResult::Point(point) => {
                    json!({"kind":"point","point":point})
                }
                bloom_text::LogicalCommandResult::Paragraph(bounds) => {
                    json!({"kind":"paragraph","bounds":bounds})
                }
                bloom_text::LogicalCommandResult::Edit { edit, selection } => {
                    let value = json!({"kind":"edit","point":edit.cursor.point(),"selection":selection,"changed":edit.changed});
                    *window = Arc::into_raw(Arc::new(BloomLogicalWindow { value: edit.window }));
                    value
                }
            };
            *output = owned_reply(&value);
            Ok(())
        })
    }
}
/// # Safety
/// The last actual step/callback joined; this frees either a cancelled or a
/// consumed continuation and cannot adopt a source or publish a file.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_command_free(command: *mut BloomLogicalCommand) {
    if !command.is_null() {
        unsafe {
            drop(Box::from_raw(command));
        }
    }
}

/// Derived context retains the same immutable source/window. It has no source
/// mutation, durable-root publication, or model authority. Writer steps append
/// index pages only; query steps borrow the independent immutable reader.
pub struct BloomLogicalMarkup {
    value: Mutex<Option<LogicalMarkup>>,
}
struct LogicalMarkup {
    window: LogicalWindow,
    mode: bloom_text::MarkupMode,
    builder: Option<bloom_text::MarkupIndexBuilder>,
    indexed: Option<std::sync::Arc<bloom_text::MarkupIndex>>,
    query: Option<bloom_text::MarkupQuery>,
    result: Option<bloom_text::MarkupContext>,
    // Nonterminal prefix query, including an exact memo hit before writer entry.
    queried_prefix: bool,
    tracked_reference_peak_bytes: usize,
    max_reference_count: usize,
    max_reference_probes: usize,
}
impl LogicalMarkup {
    fn progress(&self) -> Value {
        let bytes = self
            .builder
            .as_ref()
            .map_or(0, |builder| builder.progress().buffered_bytes)
            + self
                .query
                .as_ref()
                .map_or(0, |query| query.progress().buffered_bytes);
        json!({"complete":self.result.is_some(),"final":self.builder.is_none() && !self.queried_prefix && (self.query.is_some() || self.result.is_some()),
            "needsWriter":self.query.is_none() && self.result.is_none(),"bufferedBytes":bytes,
            "trackedReferencePeakBytes":self.tracked_reference_peak_bytes,"maxReferenceCount":self.max_reference_count,
            "maxReferenceProbes":self.max_reference_probes})
    }
    fn step_index(
        &mut self,
        engine: &mut TextEngine<CallbackPages>,
        operation: BloomTextOperation,
    ) -> bloom_text::Result<Value> {
        if self.query.is_some() || self.result.is_some() {
            return Err(Error::Invalid("markup requires readonly query"));
        }
        if self.builder.is_none() {
            if self.query.is_some() || self.result.is_some() {
                return Err(Error::Invalid("markup requires readonly query"));
            }
            self.builder = Some(bloom_text::MarkupIndexBuilder::new(
                engine,
                self.window.snapshot().clone(),
                self.mode,
            )?);
        }
        let builder = self
            .builder
            .as_mut()
            .ok_or(Error::Invalid("markup requires readonly query"))?;
        let progress = builder.step(engine, &mut || {
            operation
                .is_cancelled
                .is_some_and(|callback| unsafe { callback(operation.context) != 0 })
        })?;
        if progress.complete {
            let index = self
                .builder
                .take()
                .ok_or(Error::Invalid("markup producer consumed"))?
                .finish()?;
            self.query = Some(bloom_text::MarkupQuery::new(
                &self.window,
                std::sync::Arc::clone(&index),
            )?);
            self.indexed = Some(index);
            self.queried_prefix = false;
        } else if !self.queried_prefix
            && progress.indexed_bytes
                >= self
                    .window
                    .start()
                    .bytes
                    .checked_add(self.window.local_summary().bytes)
                    .ok_or(Error::Invalid("markup window endpoint"))?
        {
            // Keep this same entered builder. The copied prefix query does
            // not adopt source or pretend the distant tail was indexed.
            let index = self
                .builder
                .as_ref()
                .ok_or(Error::Invalid("markup prefix producer"))?
                .captured_index();
            self.query = Some(bloom_text::MarkupQuery::new(
                &self.window,
                std::sync::Arc::clone(&index),
            )?);
            self.indexed = Some(index);
            self.queried_prefix = true;
        }
        Ok(self.progress())
    }
    fn bind_window(&mut self, window: &LogicalWindow) -> bloom_text::Result<Value> {
        if window.snapshot().id() != self.window.snapshot().id()
            || window.snapshot().summary() != self.window.snapshot().summary()
        {
            return Err(Error::Stale);
        }
        if window.text().len() > bloom_text::NATIVE_WINDOW_BYTES {
            return Err(Error::Invalid("markup window budget"));
        }
        if window.id() == self.window.id() {
            return Ok(self.progress());
        }
        let end = window
            .start()
            .bytes
            .checked_add(window.local_summary().bytes)
            .ok_or(Error::Invalid("markup window endpoint"))?;
        let index = if let Some(builder) = &self.builder {
            (builder.progress().indexed_bytes >= end).then(|| builder.captured_index())
        } else {
            self.indexed.clone()
        };
        // Prepare the new exact query before changing this derived target.
        // No IO, source adoption, root publication, or builder restart occurs.
        let query = index
            .as_ref()
            .map(|index| bloom_text::MarkupQuery::new(window, std::sync::Arc::clone(index)))
            .transpose()?;
        let continues_index = self.builder.is_some() || self.queried_prefix;
        self.window = window.clone();
        self.query = query;
        self.result = None;
        self.queried_prefix = continues_index && self.query.is_some();
        self.indexed = index;
        Ok(self.progress())
    }
    fn step_query(
        &mut self,
        engine: &mut TextEngine<CallbackPages>,
        operation: BloomTextOperation,
    ) -> bloom_text::Result<Value> {
        if self.builder.is_some() && self.query.is_none() && self.result.is_none() {
            return Err(Error::Invalid("markup requires index writer"));
        }
        if let Some(query) = &mut self.query {
            let progress = query.step(engine, &mut || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| unsafe { callback(operation.context) != 0 })
            })?;
            self.tracked_reference_peak_bytes = self
                .tracked_reference_peak_bytes
                .max(progress.retained_reference_bytes);
            self.max_reference_count = self.max_reference_count.max(progress.unique_references);
            self.max_reference_probes =
                self.max_reference_probes.max(progress.max_reference_probes);
            if progress.complete {
                self.result = Some(
                    self.query
                        .take()
                        .ok_or(Error::Invalid("markup query consumed"))?
                        .finish()?,
                );
            }
        }
        Ok(self.progress())
    }
}
fn markup_writer<T>(
    handle: u64,
    body: impl FnOnce(&mut TextEngine<CallbackPages>) -> bloom_text::Result<T>,
) -> bloom_text::Result<T> {
    let slot = engines()
        .lock()
        .map_err(|_| Error::Invalid("writer registry lock"))?
        .get(&handle)
        .cloned()
        .ok_or(Error::Invalid("writer closed"))?;
    let mut guard = slot.try_lock().map_err(|_| Error::Invalid("writer busy"))?;
    body(guard.as_mut().ok_or(Error::Invalid("writer closed"))?)
}
/// # Safety
/// Window was frozen before the worker handoff. Construction only retains
/// immutable state; a cached index goes directly to readonly query steps.
/// Mode0=style, mode1=media.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_begin(
    window: *const BloomLogicalWindow,
    mode: u8,
    output: *mut *mut BloomLogicalMarkup,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() {
                return Err(Error::Invalid("markup output"));
            }
            *output = ptr::null_mut();
            let window = window.as_ref().ok_or(Error::Invalid("markup window"))?;
            let mode = match mode {
                0 => bloom_text::MarkupMode::Style,
                1 => bloom_text::MarkupMode::Media,
                _ => return Err(Error::Invalid("markup options")),
            };
            if window.value.text().len() > bloom_text::NATIVE_WINDOW_BYTES {
                return Err(Error::Invalid("markup window budget"));
            }
            let end = window
                .value
                .start()
                .bytes
                .checked_add(window.value.local_summary().bytes)
                .ok_or(Error::Invalid("markup window endpoint"))?;
            let indexed = window
                .value
                .snapshot()
                .captured_markup_prefix(mode)?
                .filter(|index| index.indexed_summary().bytes >= end);
            let queried_prefix = indexed.as_ref().is_some_and(|index| !index.complete());
            let query = indexed
                .as_ref()
                .map(|index| {
                    bloom_text::MarkupQuery::new(&window.value, std::sync::Arc::clone(index))
                })
                .transpose()?;
            *output = Box::into_raw(Box::new(BloomLogicalMarkup {
                value: Mutex::new(Some(LogicalMarkup {
                    window: window.value.clone(),
                    mode,
                    builder: None,
                    indexed,
                    query,
                    result: None,
                    // A cached partial query may prove this exact window. If
                    // not, the SAME command lazily resumes its existing builder.
                    queried_prefix,
                    tracked_reference_peak_bytes: 0,
                    max_reference_count: 0,
                    max_reference_probes: 0,
                })),
            }));
            Ok(())
        })
    }
}
/// # Safety
/// Only between joined quanta on this same operation. Both windows retain the
/// identical immutable logical source; an obsolete source is rejected. This
/// changes a derived read target, never the physical/native source owner.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_bind_window(
    command: *const BloomLogicalMarkup,
    window: *const BloomLogicalWindow,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() {
                return Err(Error::Invalid("markup bind progress"));
            }
            let command = command.as_ref().ok_or(Error::Invalid("markup command"))?;
            let window = window
                .as_ref()
                .ok_or(Error::Invalid("markup bind window"))?;
            let mut guard = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("markup reentry"))?;
            let command = guard.as_mut().ok_or(Error::Invalid("markup consumed"))?;
            *output = owned_reply(&command.bind_window(&window.value)?);
            Ok(())
        })
    }
}
/// # Safety
/// Join this bounded append step before free. The actual writer/operation
/// callbacks are borrowed only for the call, and no fsync occurs here.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_writer_step(
    handle: u64,
    command: *const BloomLogicalMarkup,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() {
                return Err(Error::Invalid("markup progress"));
            }
            let command = command.as_ref().ok_or(Error::Invalid("markup command"))?;
            let mut guard = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("markup reentry"))?;
            let command = guard.as_mut().ok_or(Error::Invalid("markup consumed"))?;
            let progress = markup_writer(handle, |engine| command.step_index(engine, operation))?;
            *output = owned_reply(&progress);
            Ok(())
        })
    }
}
/// # Safety
/// The actual readonly host is borrowed for one bounded query step. It cannot
/// publish or append pages and never acquires the writer EngineSlot.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_step(
    host: BloomTextHost,
    command: *const BloomLogicalMarkup,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() {
                return Err(Error::Invalid("markup progress"));
            }
            let command = command.as_ref().ok_or(Error::Invalid("markup command"))?;
            let mut guard = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("markup reentry"))?;
            let command = guard.as_mut().ok_or(Error::Invalid("markup consumed"))?;
            let mut reader = read_engine(host, operation)?;
            *output = owned_reply(&command.step_query(&mut reader, operation)?);
            Ok(())
        })
    }
}
/// # Safety
/// Finish only after actual complete progress. This returns bounded derived
/// arrays for the retained window. A prefix result consumes only the query;
/// the same command may resume indexing or join and free its proved prefix.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_finish(
    command: *const BloomLogicalMarkup,
    operation: BloomTextOperation,
    output: *mut BoomAttachmentBuffer,
    error: *mut BoomAttachmentBuffer,
) -> i32 {
    unsafe {
        call(error, || {
            if output.is_null() {
                return Err(Error::Invalid("markup projection"));
            }
            let command = command.as_ref().ok_or(Error::Invalid("markup command"))?;
            let mut guard = command
                .value
                .try_lock()
                .map_err(|_| Error::Invalid("markup reentry"))?;
            if guard.as_ref().is_none_or(|value| value.result.is_none()) {
                return Err(Error::Invalid("markup not complete"));
            }
            let command = guard.as_mut().ok_or(Error::Invalid("markup consumed"))?;
            let context = command
                .result
                .take()
                .ok_or(Error::Invalid("markup lost context"))?;
            let mut cancelled = || {
                operation
                    .is_cancelled
                    .is_some_and(|callback| callback(operation.context) != 0)
            };
            let markdown = if command.mode == bloom_text::MarkupMode::Style {
                bloom_core::paged_spans_with_cancel(&context, &mut cancelled).map_err(|error| {
                    if cancelled() {
                        Error::Cancelled
                    } else {
                        Error::Storage(error.to_string())
                    }
                })?
            } else {
                Vec::new()
            };
            let media = if command.mode == bloom_text::MarkupMode::Media {
                bloom_core::paged_media_spans_with_cancel(&context, &mut cancelled).map_err(
                    |error| {
                        if cancelled() {
                            Error::Cancelled
                        } else {
                            Error::Storage(error.to_string())
                        }
                    },
                )?
            } else {
                Vec::new()
            };
            let complete = context.complete_blocks && context.reference_budget_proven;
            let value = json!({"rootID":command.window.snapshot().id(),"windowID":command.window.id(),
            "start":command.window.start(),"summary":command.window.local_summary(),
            "complete":complete,"markdown":markdown,"media":media,
            "trackedReferencePeakBytes":command.tracked_reference_peak_bytes,
            "maxReferenceCount":command.max_reference_count,"maxReferenceProbes":command.max_reference_probes,
            "hasWikiMarker":complete && command.window.text().contains("[["),
            "hasAttachmentMarker":complete && command.window.text().contains("[Attachment: ")});
            let bytes =
                serde_json::to_vec(&value).map_err(|_| Error::Invalid("markup projection JSON"))?;
            if bytes.len() > 2 * 1024 * 1024 {
                return Err(Error::Invalid("markup projection reply bound"));
            }
            let mut bytes = bytes.into_boxed_slice();
            *output = BoomAttachmentBuffer {
                data: bytes.as_mut_ptr(),
                length: bytes.len(),
            };
            std::mem::forget(bytes);
            if command.builder.is_none() && !command.queried_prefix {
                guard.take();
            }
            Ok(())
        })
    }
}
/// # Safety
/// Only after every entered callback/step has joined. Frees derived state and
/// immutable values; it never discards native input or publishes a text root.
#[no_mangle]
pub unsafe extern "C" fn bloom_logical_markup_free(command: *mut BloomLogicalMarkup) {
    if !command.is_null() {
        unsafe {
            drop(Box::from_raw(command));
        }
    }
}
