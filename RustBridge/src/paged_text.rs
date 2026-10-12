//! One bounded page cache behind opaque integer handles. The native storage
//! executor owns callback contexts, permission, current-root CAS and durability.
//! This is deliberately not an operation in the model-facing core request.
use crate::{encoding, error, BoomAttachmentBuffer};
use bloom_text::{Error, PageKind, PageLocator, PageProvider, PageRef, Revision, TextEngine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::io::{self, Read, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, TryLockError};
use uuid::Uuid;

const REQUEST_BYTES: usize = 2 * 1024 * 1024;
const REPLY_BYTES: usize = 1024 * 1024;
const CALLBACK_JSON_BYTES: usize = 4096;
// All document sessions share this engine and its 8 MiB cache. Creating a new
// document does not create an engine/cache or retain a resident history map.
const ENGINE_COUNT: usize = 1;

type PageRead =
    unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut u8, usize, *mut usize) -> i32;
type PageWrite = unsafe extern "C" fn(
    *mut c_void,
    *const u8,
    usize,
    *const u8,
    usize,
    *mut u8,
    usize,
    *mut usize,
) -> i32;
type StreamRead = unsafe extern "C" fn(*mut c_void, *mut u8, usize, *mut usize) -> i32;
type StreamWrite = unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut usize) -> i32;
type Cancelled = unsafe extern "C" fn(*mut c_void) -> u8;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct BloomTextHost {
    pub schema: u32,
    pub context: *mut c_void,
    pub read_page: Option<PageRead>,
    pub write_page: Option<PageWrite>,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct BloomTextOperation {
    pub context: *mut c_void,
    pub read_stream: Option<StreamRead>,
    pub write_stream: Option<StreamWrite>,
    pub is_cancelled: Option<Cancelled>,
}

// The integer is the embedding's opaque context, never dereferenced by Rust.
// Callbacks are serialized by EngineSlot; the embedding permits thread migration
// on its dedicated storage executor and retains this context until close joins.
struct CallbackPages {
    context: usize,
    read: PageRead,
    write: PageWrite,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadPage<'a> {
    owner_id: Uuid,
    document_id: Uuid,
    kind: PageKind,
    page: &'a PageRef,
    maximum_bytes: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WritePage {
    owner_id: Uuid,
    document_id: Uuid,
    kind: PageKind,
}
fn callback_json(value: &impl Serialize) -> bloom_text::Result<Vec<u8>> {
    encoding::encode(value, CALLBACK_JSON_BYTES)
        .map_err(|_| Error::Invalid("page callback encoding"))
}
impl PageProvider for CallbackPages {
    fn read(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        page: &PageRef,
        maximum_bytes: usize,
    ) -> bloom_text::Result<Vec<u8>> {
        if maximum_bytes > kind.maximum_bytes() {
            return Err(Error::Invalid("page callback read bound"));
        }
        let request = callback_json(&ReadPage {
            owner_id: owner,
            document_id: document,
            kind,
            page,
            maximum_bytes,
        })?;
        let mut bytes = vec![0; maximum_bytes];
        let mut written = 0;
        // SAFETY: the embedding retains the context/function until close joins;
        // buffers are live for this callback and cannot be retained by the host.
        let status = unsafe {
            (self.read)(
                self.context as *mut c_void,
                request.as_ptr(),
                request.len(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut written,
            )
        };
        if status != 0 || written > maximum_bytes {
            return Err(Error::Storage(
                "Authenticated page read was rejected.".into(),
            ));
        }
        bytes.truncate(written);
        Ok(bytes)
    }
    fn write_new(
        &mut self,
        owner: Uuid,
        document: Uuid,
        kind: PageKind,
        bytes: &[u8],
    ) -> bloom_text::Result<PageLocator> {
        if bytes.len() > kind.maximum_bytes() {
            return Err(Error::Invalid("page callback write bound"));
        }
        let request = callback_json(&WritePage {
            owner_id: owner,
            document_id: document,
            kind,
        })?;
        let mut reply = [0; CALLBACK_JSON_BYTES];
        let mut written = 0;
        // SAFETY: the embedding's context is live; all buffers are bounded and
        // borrowed until return. The reply is an immutable locator, not a key.
        let status = unsafe {
            (self.write)(
                self.context as *mut c_void,
                request.as_ptr(),
                request.len(),
                bytes.as_ptr(),
                bytes.len(),
                reply.as_mut_ptr(),
                reply.len(),
                &mut written,
            )
        };
        if status != 0 || written == 0 || written > reply.len() {
            return Err(Error::Storage(
                "Authenticated page write was rejected.".into(),
            ));
        }
        let locator: PageLocator = serde_json::from_slice(&reply[..written])
            .map_err(|_| Error::Invalid("page callback locator"))?;
        Ok(locator)
    }
}

type EngineSlot = Arc<Mutex<Option<TextEngine<CallbackPages>>>>;
static ENGINES: OnceLock<Mutex<BTreeMap<u64, EngineSlot>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
fn engines() -> &'static Mutex<BTreeMap<u64, EngineSlot>> {
    ENGINES.get_or_init(Mutex::default)
}

/// # Safety
/// Host callbacks must obey boom_attachment.h, be usable from the serialized
/// storage executor and retain their context until bloom_text_close returns 1.
/// They must not unwind, retain borrowed pointers or reenter a live operation.
#[no_mangle]
pub unsafe extern "C" fn bloom_text_create(host: BloomTextHost) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(read), Some(write)) = (host.read_page, host.write_page) else {
            return 0;
        };
        if host.schema != 2 {
            return 0;
        }
        let Ok(mut slots) = engines().lock() else {
            return 0;
        };
        if slots.len() >= ENGINE_COUNT {
            return 0;
        }
        let Ok(handle) = NEXT_HANDLE.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| {
            next.checked_add(1)
        }) else {
            return 0;
        };
        slots.insert(
            handle,
            Arc::new(Mutex::new(Some(TextEngine::new(CallbackPages {
                context: host.context as usize,
                read,
                write,
            })))),
        );
        handle
    }))
    .unwrap_or(0)
}

/// Close succeeds only after all callbacks have joined. A racing request that
/// obtained the slot before close sees None and cannot touch a freed context.
/// Returns 0 for a busy/unknown handle; the host retains its context and retries.
#[no_mangle]
pub extern "C" fn bloom_text_close(handle: u64) -> u8 {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(mut slots) = engines().lock() else {
            return 0;
        };
        let Some(slot) = slots.get(&handle).cloned() else {
            return 0;
        };
        let mut engine = match slot.try_lock() {
            Ok(engine) => engine,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return 0,
        };
        *engine = None;
        slots.remove(&handle);
        1
    }))
    .unwrap_or(0)
}

struct StreamReader {
    context: usize,
    read: Option<StreamRead>,
}
impl Read for StreamReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        let capacity = bytes.len().min(bloom_text::TEXT_PAGE_BYTES);
        let mut written = 0;
        let read = self
            .read
            .ok_or_else(|| io::Error::other("Missing import stream."))?;
        // SAFETY: per-operation context and writable bytes are live until the
        // synchronous request returns. A zero-byte success is an explicit EOF.
        let status = unsafe {
            read(
                self.context as *mut c_void,
                bytes.as_mut_ptr(),
                capacity,
                &mut written,
            )
        };
        if status != 0 || written > capacity {
            return Err(io::Error::other("Text stream read was rejected."));
        }
        Ok(written)
    }
}
struct StreamWriter {
    context: usize,
    write: StreamWrite,
}
impl Write for StreamWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > bloom_text::TEXT_PAGE_BYTES {
            return Err(io::Error::other("Text stream write bound."));
        }
        let mut written = 0;
        // SAFETY: the operation context is retained and these bytes cannot be
        // retained after the callback. Each cooperative step preserves an
        // unwritten suffix and yields after this single short-write callback.
        let status = unsafe {
            (self.write)(
                self.context as *mut c_void,
                bytes.as_ptr(),
                bytes.len(),
                &mut written,
            )
        };
        if status != 0 || written > bytes.len() {
            return Err(io::Error::other("Text stream write was rejected."));
        }
        Ok(written)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(
    tag = "op",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Request {
    Open {
        revision: Revision,
    },
    Window {
        revision: Revision,
        byte_start: u64,
        maximum_bytes: usize,
    },
    Splice {
        revision: Revision,
        byte_start: u64,
        byte_end: u64,
        old_text: String,
        new_text: String,
    },
    DeleteUserRange {
        revision: Revision,
        byte_start: u64,
        byte_end: u64,
    },
    Checkout {
        revision: Revision,
        retained: Revision,
    },
    ImportBegin {
        owner_id: Uuid,
        document_id: Uuid,
        expected_bytes: u64,
    },
    ImportStep {
        owner_id: Uuid,
        document_id: Uuid,
        operation_id: Uuid,
    },
    ImportFinish {
        owner_id: Uuid,
        document_id: Uuid,
        operation_id: Uuid,
    },
    ExportBegin {
        revision: Revision,
    },
    HashBegin {
        revision: Revision,
    },
    StreamStep {
        revision: Revision,
        operation_id: Uuid,
    },
    StreamFinish {
        revision: Revision,
        operation_id: Uuid,
    },
    BulkAbort {
        owner_id: Uuid,
        document_id: Uuid,
        operation_id: Uuid,
    },
    Position {
        revision: Revision,
        utf16_offset: u64,
    },
    ScalarPosition {
        revision: Revision,
        utf16_offset: u64,
        forward: bool,
    },
    Stats,
    DiscardPageCacheAfterRollback,
}

fn execute(
    engine: &mut TextEngine<CallbackPages>,
    request: Request,
    operation: BloomTextOperation,
) -> bloom_text::Result<Value> {
    let mut cancelled = || {
        operation.is_cancelled.is_some_and(|callback| {
            // SAFETY: the embedding retains this operation's context until return;
            // cancellation is a nonblocking flag check and never reenters Rust.
            unsafe { callback(operation.context) != 0 }
        })
    };
    // A cancelled owned step/finish must discard its admitted session. Cleanup
    // remains callable after cancellation. No context survives this request.
    let owned_bulk = matches!(
        &request,
        Request::ImportStep { .. }
            | Request::ImportFinish { .. }
            | Request::StreamStep { .. }
            | Request::StreamFinish { .. }
            | Request::BulkAbort { .. }
            | Request::DiscardPageCacheAfterRollback
    );
    if !owned_bulk && cancelled() {
        return Err(Error::Cancelled);
    }
    match request {
        Request::ImportBegin {
            owner_id,
            document_id,
            expected_bytes,
        } => Ok(json!(engine.import_begin(
            owner_id,
            document_id,
            expected_bytes
        )?)),
        Request::ImportStep {
            owner_id,
            document_id,
            operation_id,
        } => {
            let mut reader = StreamReader {
                context: operation.context as usize,
                read: operation.read_stream,
            };
            Ok(json!(engine.import_step(
                owner_id,
                document_id,
                operation_id,
                &mut reader,
                &mut cancelled
            )?))
        }
        Request::ImportFinish {
            owner_id,
            document_id,
            operation_id,
        } => {
            let imported =
                engine.import_finish(owner_id, document_id, operation_id, &mut cancelled)?;
            Ok(
                json!({"revision": imported.document.revision(), "wholeTextSha256": imported.whole_text_sha256}),
            )
        }
        Request::Open { revision } => Ok(json!(engine.open(revision)?.revision())),
        Request::Window {
            revision,
            byte_start,
            maximum_bytes,
        } => {
            let document = engine.open(revision.clone())?;
            Ok(json!(engine.window(
                &document,
                &revision,
                byte_start,
                maximum_bytes
            )?))
        }
        Request::Splice {
            revision,
            byte_start,
            byte_end,
            old_text,
            new_text,
        } => {
            if old_text.len() > bloom_text::WINDOW_BYTES
                || new_text.len() > bloom_text::WINDOW_BYTES
            {
                return Err(Error::Invalid("captured edit exceeds its window bound"));
            }
            let mut document = engine.open(revision.clone())?;
            Ok(json!(engine.splice(
                &mut document,
                &revision,
                byte_start..byte_end,
                Some(old_text.as_bytes()),
                &new_text,
                &mut cancelled
            )?))
        }
        Request::DeleteUserRange {
            revision,
            byte_start,
            byte_end,
        } => {
            let mut document = engine.open(revision.clone())?;
            Ok(json!(engine.splice(
                &mut document,
                &revision,
                byte_start..byte_end,
                None,
                "",
                &mut cancelled
            )?))
        }
        Request::Checkout { revision, retained } => {
            let mut document = engine.open(revision.clone())?;
            engine.checkout(&mut document, &revision, retained)?;
            Ok(json!(document.revision()))
        }
        Request::ExportBegin { revision } => Ok(json!(engine.export_begin(revision)?)),
        Request::HashBegin { revision } => Ok(json!(engine.hash_begin(revision)?)),
        Request::StreamStep {
            revision,
            operation_id,
        } => {
            let mut writer = operation.write_stream.map(|write| StreamWriter {
                context: operation.context as usize,
                write,
            });
            let writer = writer.as_mut().map(|writer| writer as &mut dyn Write);
            Ok(json!(engine.stream_step(
                &revision,
                operation_id,
                writer,
                &mut cancelled
            )?))
        }
        Request::StreamFinish {
            revision,
            operation_id,
        } => Ok(json!(engine.stream_finish(
            &revision,
            operation_id,
            &mut cancelled
        )?)),
        Request::BulkAbort {
            owner_id,
            document_id,
            operation_id,
        } => Ok(json!(engine.bulk_abort(
            owner_id,
            document_id,
            operation_id
        )?)),
        Request::Position {
            revision,
            utf16_offset,
        } => {
            let document = engine.open(revision.clone())?;
            Ok(json!(engine.byte_at_utf16(
                &document,
                &revision,
                utf16_offset
            )?))
        }
        Request::ScalarPosition { revision, utf16_offset, forward } => {
            let document = engine.open(revision.clone())?;
            Ok(json!(engine.scalar_position(&document, &revision, utf16_offset, forward)?))
        }
        Request::DiscardPageCacheAfterRollback => {
            engine.discard_page_cache_after_rollback();
            Ok(json!(engine.stats()))
        }
        Request::Stats => {
            let mut value = json!(engine.stats());
            value["activeBulkOperations"] = json!(engine.active_bulk_operations());
            Ok(value)
        }
    }
}

fn owned_reply(value: &Value) -> BoomAttachmentBuffer {
    let bytes = encoding::encode(value, REPLY_BYTES).unwrap_or_else(|_|
        b"{\"schema\":1,\"ok\":false,\"error\":{\"code\":\"output_limit\",\"message\":\"Paged text reply exceeds its bound.\"}}".to_vec());
    let boxed = bytes.into_boxed_slice();
    let length = boxed.len();
    BoomAttachmentBuffer {
        data: Box::into_raw(boxed) as *mut u8,
        length,
    }
}

/// # Safety
/// Nonempty input is immutable and live for this call. Operation callbacks and
/// their context remain live until return; they cannot unwind or retain any
/// borrowed buffer. Page callbacks obey the create/close lifetime contract.
/// Free the returned buffer exactly once with boom_attachment_free.
#[no_mangle]
pub unsafe extern "C" fn bloom_text_request(
    handle: u64,
    data: *const u8,
    length: usize,
    operation: BloomTextOperation,
) -> BoomAttachmentBuffer {
    if data.is_null() || length == 0 || length > REQUEST_BYTES {
        return owned_reply(&error(
            "input_limit",
            "Paged text request exceeds its bound.",
        ));
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the embedding provides readable immutable bytes for this call.
        let bytes = unsafe { slice::from_raw_parts(data, length) };
        let request = match serde_json::from_slice(bytes) {
            Ok(request) => request,
            Err(_) => return error("request_invalid", "Malformed paged text request."),
        };
        let slot = match engines().lock() {
            Ok(slots) => slots.get(&handle).cloned(),
            Err(_) => return error("engine_failed", "Paged text registry failed."),
        };
        let Some(slot) = slot else {
            return error("engine_closed", "Paged text engine is closed.");
        };
        let mut guard = match slot.try_lock() {
            Ok(guard) => guard,
            Err(TryLockError::WouldBlock) => {
                return error("engine_busy", "A paged text operation is already running.");
            }
            Err(TryLockError::Poisoned(_)) => {
                return error("engine_failed", "Paged text engine failed.");
            }
        };
        let Some(engine) = guard.as_mut() else {
            return error("engine_closed", "Paged text engine is closed.");
        };
        match execute(engine, request, operation) {
            Ok(value) => json!({"schema": 1, "ok": true, "value": value}),
            Err(e) => {
                let code = match &e {
                    Error::Stale => "stale",
                    Error::Cancelled => "cancelled",
                    Error::Invalid(_) => "invalid",
                    Error::Storage(_) | Error::Io(_) => "storage_failed",
                };
                error(code, &e.to_string())
            }
        }
    }));
    owned_reply(&outcome.unwrap_or_else(|_| error("engine_panic", "Paged text operation failed.")))
}
