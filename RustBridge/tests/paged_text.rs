use boom_attachment_ffi::{
    bloom_text_close, bloom_text_create, bloom_text_read_window, bloom_text_request,
    boom_attachment_free, BloomTextHost, BloomTextOperation,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::{ptr, slice};
use uuid::Uuid;

// Small public callback fixture for bounded plain page addresses.
struct Host {
    owner: Uuid,
    document: Uuid,
    store: Uuid,
    pages: BTreeMap<u64, Vec<u8>>,
    input: Vec<u8>,
    cursor: usize,
    output: Vec<u8>,
    handle: u64,
    check_reentry: bool,
    reentry_checked: bool,
    immutable_reentry: Option<Value>,
    immutable_reentry_checked: bool,
    reject_read: bool,
    cancelled: bool,
    read_calls: usize,
    write_calls: usize,
    read_variant: u8,
    write_variant: u8,
}

fn response(handle: u64, value: Value, operation: BloomTextOperation) -> Value {
    let bytes = serde_json::to_vec(&value).expect("small public JSON");
    // SAFETY: buffers/context are live through this synchronous call. The
    // returned allocation is decoded before exactly-once free.
    unsafe {
        let buffer = bloom_text_request(handle, bytes.as_ptr(), bytes.len(), operation);
        assert!(!buffer.data.is_null());
        assert!(buffer.length <= 1024 * 1024);
        let parsed = serde_json::from_slice(slice::from_raw_parts(buffer.data, buffer.length));
        boom_attachment_free(buffer);
        parsed.expect("bounded JSON reply")
    }
}
unsafe fn metadata(data: *const u8, length: usize) -> Option<Value> {
    if data.is_null() || length == 0 || length > 4096 {
        return None;
    }
    // SAFETY: callback borrows the embedding's bounded readable metadata.
    serde_json::from_slice(unsafe { slice::from_raw_parts(data, length) }).ok()
}
fn admit(host: &Host, value: &Value) -> bool {
    value["ownerId"].as_str() == Some(host.owner.to_string().as_str())
        && value["documentId"].as_str() == Some(host.document.to_string().as_str())
        && matches!(value["kind"].as_str(), Some("text" | "index"))
}
unsafe extern "C" fn read_page(
    context: *mut c_void,
    data: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: the public writer fixture stays live through joined callbacks.
    let host = unsafe { &mut *context.cast::<Host>() };
    if let Some(revision) = host.immutable_reentry.take() {
        // The actual registered writer EngineSlot is locked at this callback.
        // The one-shot reader borrows only immutable fixture pages, never
        // recursively takes that writer lock or obtains another engine slot.
        let reply = immutable_response(host, &revision, 0, 16_384);
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["value"]["revision"], revision);
        host.immutable_reentry_checked = true;
    }
    // SAFETY: no mutation occurs during this nested immutable callback borrow.
    unsafe { immutable_page_read(context, data, length, output, capacity, written) }
}
unsafe extern "C" fn immutable_page_read(
    context: *mut c_void,
    data: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: this synchronous callback only reads the borrowed public pages.
    let host = unsafe { &*context.cast::<Host>() };
    let Some(value) = (unsafe { metadata(data, length) }) else {
        return -1;
    };
    if !admit(host, &value) || host.reject_read {
        return -1;
    }
    let Some(id) = value["page"]["locator"]["offset"].as_u64() else {
        return -1;
    };
    if value["page"]["locator"]["storage"] != "file_v1"
        || value["page"]["locator"]["storeId"].as_str() != Some(host.store.to_string().as_str())
    {
        return -1;
    }
    let Some(bytes) = host.pages.get(&id) else {
        return -1;
    };
    if bytes.len() > capacity {
        return -1;
    }
    // SAFETY: output/written are the live writable buffers supplied by Rust.
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        *written = bytes.len();
    }
    0
}
unsafe extern "C" fn write_page(
    context: *mut c_void,
    data: *const u8,
    length: usize,
    plaintext: *const u8,
    plaintext_length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: Host and borrowed buffers are live for this callback only.
    let host = unsafe { &mut *context.cast::<Host>() };
    let Some(value) = (unsafe { metadata(data, length) }) else {
        return -1;
    };
    if !admit(host, &value) || plaintext_length > 65_536 {
        return -1;
    }
    if host.check_reentry && !host.reentry_checked {
        // A callback cannot close/free its context or deadlock a nested call.
        let closed = bloom_text_close(host.handle);
        let nested = response(
            host.handle,
            json!({"op":"stats"}),
            BloomTextOperation::default(),
        );
        host.reentry_checked = closed == 0 && nested["error"]["code"] == "engine_busy";
        if !host.reentry_checked {
            return -1;
        }
    }
    let id = host.pages.len() as u64 * 65_548;
    let locator = json!({"storage":"file_v1","storeId":host.store,"offset":id,
        "bytes":plaintext_length});
    let Ok(bytes) = serde_json::to_vec(&locator) else {
        return -1;
    };
    if bytes.len() > capacity {
        return -1;
    }
    // SAFETY: plaintext/output/written lengths come from bounded engine buffers.
    unsafe {
        host.pages.insert(
            id,
            slice::from_raw_parts(plaintext, plaintext_length).to_vec(),
        );
        ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
        *written = bytes.len();
    }
    0
}
unsafe extern "C" fn read_stream(
    context: *mut c_void,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: the fixture's Host and bounded callback buffers remain live.
    let host = unsafe { &mut *context.cast::<Host>() };
    if capacity > 65_536 {
        return -1;
    }
    host.read_calls += 1;
    host.read_variant = 1;
    // Deliberate short reads split multi-byte scalars without corrupting import.
    let count = (host.input.len() - host.cursor).min(capacity).min(3);
    unsafe {
        ptr::copy_nonoverlapping(host.input.as_ptr().add(host.cursor), output, count);
        *written = count;
    }
    host.cursor += count;
    0
}
unsafe extern "C" fn write_stream(
    context: *mut c_void,
    bytes: *const u8,
    length: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: the callback consumes borrowed bytes before it returns.
    let host = unsafe { &mut *context.cast::<Host>() };
    if length > 65_536 {
        return -1;
    }
    host.write_calls += 1;
    host.write_variant = 1;
    let count = length.min(2);
    unsafe {
        host.output
            .extend_from_slice(slice::from_raw_parts(bytes, count));
        *written = count;
    }
    0
}
unsafe extern "C" fn cancelled(context: *mut c_void) -> u8 {
    // SAFETY: the flag lives in this operation's retained public fixture.
    unsafe { (*context.cast::<Host>()).cancelled as u8 }
}

unsafe extern "C" fn alternate_read(
    context: *mut c_void,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: this call borrows the same live public fixture and buffers.
    let status = unsafe { read_stream(context, output, capacity, written) };
    unsafe {
        (*context.cast::<Host>()).read_variant = 2;
    }
    status
}
unsafe extern "C" fn alternate_write(
    context: *mut c_void,
    bytes: *const u8,
    length: usize,
    written: *mut usize,
) -> i32 {
    // SAFETY: callback consumes the current request's borrowed buffers only.
    let status = unsafe { write_stream(context, bytes, length, written) };
    unsafe {
        (*context.cast::<Host>()).write_variant = 2;
    }
    status
}
fn current_operation(host: &mut Host, alternate: bool) -> BloomTextOperation {
    BloomTextOperation {
        context: (host as *mut Host).cast(),
        read_stream: Some(if alternate {
            alternate_read
        } else {
            read_stream
        }),
        write_stream: Some(if alternate {
            alternate_write
        } else {
            write_stream
        }),
        is_cancelled: Some(cancelled),
    }
}
fn immutable_response(host: &Host, revision: &Value, offset: u64, budget: usize) -> Value {
    let bytes = serde_json::to_vec(revision).expect("small immutable revision");
    let context = (host as *const Host).cast_mut().cast();
    let callbacks = BloomTextHost {
        schema: 3,
        context,
        read_page: Some(immutable_page_read),
        write_page: None,
    };
    let operation = BloomTextOperation {
        context,
        is_cancelled: Some(cancelled),
        ..Default::default()
    };
    // SAFETY: all borrowed pages/input/flag are immutable until synchronous
    // return; this provider cannot write or retain a page/context pointer.
    unsafe {
        let buffer = bloom_text_read_window(
            callbacks,
            bytes.as_ptr(),
            bytes.len(),
            offset,
            budget,
            operation,
        );
        assert!(!buffer.data.is_null());
        assert!(buffer.length <= 131_072);
        let parsed = serde_json::from_slice(slice::from_raw_parts(buffer.data, buffer.length));
        boom_attachment_free(buffer);
        parsed.expect("bounded immutable JSON reply")
    }
}
fn immutable_window_controls(host: &mut Host, revision: &Value, source: &str) {
    let old_pages = host.pages.len();
    let window = immutable_response(host, revision, 0, 16_384);
    assert_eq!(window["ok"], true, "{window}");
    assert_eq!(window["value"]["text"], source);
    let (byte, scalar) = source
        .char_indices()
        .find(|(_, c)| c.len_utf16() == 2)
        .expect("public emoji");
    let units = source[..byte].encode_utf16().count();
    let half = immutable_response(host, revision, units as u64 + 1, 16_384);
    assert_eq!(half["value"]["byteStart"], byte as u64);
    assert_eq!(half["value"]["utf16Start"], units as u64);
    assert!(source[byte..].starts_with(scalar));
    let eof = immutable_response(host, revision, source.encode_utf16().count() as u64, 16_384);
    assert_eq!(eof["value"]["text"], "");
    assert_eq!(immutable_response(host, revision, 0, 16_385)["ok"], false);
    host.cancelled = true;
    assert_eq!(
        immutable_response(host, revision, 0, 16_384)["error"]["code"],
        "cancelled"
    );
    host.cancelled = false;
    host.reject_read = true;
    assert_eq!(
        immutable_response(host, revision, 0, 16_384)["error"]["code"],
        "storage_failed"
    );
    host.reject_read = false;
    assert_eq!(
        host.pages.len(),
        old_pages,
        "read-only ABI appends no pages"
    );
    // An additional actual bounded immutable index frame forces a writer
    // callback even though its usual tiny source remains in the writer cache.
    let offset = revision["root"]["page"]["locator"]["offset"]
        .as_u64()
        .expect("root offset");
    let index = host.pages.get(&offset).expect("actual index frame").clone();
    assert!(index.len() <= 16_384);
    let next = u64::try_from(host.pages.len())
        .expect("small public page count")
        .checked_mul(65_548)
        .expect("small fixture address");
    host.pages.insert(next, index);
    let mut uncached = revision.clone();
    uncached["root"]["page"]["locator"]["offset"] = json!(next);
    host.immutable_reentry = Some(uncached.clone());
    let operation = current_operation(host, false);
    let during_writer = response(
        host.handle,
        json!({"op":"window","revision":uncached,"byteStart":0,"maximumBytes":16_384}),
        operation,
    );
    assert_eq!(during_writer["value"]["text"], source);
    assert!(
        host.immutable_reentry_checked,
        "actual writer callback entered while immutable read completed"
    );
}

fn import_steps(host: &mut Host) -> Value {
    let operation = current_operation(host, false);
    let begin = response(
        host.handle,
        json!({"op":"import_begin","ownerId":host.owner,
        "documentId":host.document,"expectedBytes":host.input.len() as u64}),
        operation,
    );
    assert_eq!(begin["ok"], true, "{begin}");
    let id = begin["value"].clone();
    let mut previous = 0;
    let mut complete = false;
    for step in 0..1000 {
        let calls = host.read_calls;
        let alternate = step % 2 != 0;
        let operation = current_operation(host, alternate);
        let result = response(
            host.handle,
            json!({"op":"import_step","ownerId":host.owner,
            "documentId":host.document,"operationId":id}),
            operation,
        );
        assert_eq!(result["ok"], true, "{result}");
        let progress = &result["value"];
        let processed = progress["processedBytes"]
            .as_u64()
            .expect("progress byte count");
        let validated = progress["validatedBytes"]
            .as_u64()
            .expect("validated byte count");
        assert!(processed >= previous && processed - previous <= 65_536);
        assert!(validated <= processed && processed - validated <= 3);
        assert!(host.read_calls - calls <= 1);
        if host.read_calls != calls {
            assert_eq!(
                host.read_variant,
                if alternate { 2 } else { 1 },
                "Only this request's callback is borrowed"
            );
        }
        previous = processed;
        if progress["complete"] == true {
            complete = true;
            break;
        }
    }
    assert!(complete);
    let operation = current_operation(host, false);
    let result = response(
        host.handle,
        json!({"op":"import_finish","ownerId":host.owner,
        "documentId":host.document,"operationId":id}),
        operation,
    );
    assert_eq!(result["ok"], true, "{result}");
    result
}
fn export_steps(host: &mut Host, revision: &Value) -> Value {
    let operation = current_operation(host, false);
    let begin = response(
        host.handle,
        json!({"op":"export_begin","revision":revision}),
        operation,
    );
    assert_eq!(begin["ok"], true, "{begin}");
    let id = begin["value"].clone();
    let mut complete = false;
    for step in 0..1000 {
        let calls = host.write_calls;
        let alternate = step % 2 != 0;
        let operation = current_operation(host, alternate);
        let result = response(
            host.handle,
            json!({"op":"stream_step","revision":revision,
            "operationId":id}),
            operation,
        );
        assert_eq!(result["ok"], true, "{result}");
        assert!(host.write_calls - calls <= 1);
        if host.write_calls != calls {
            assert_eq!(host.write_variant, if alternate { 2 } else { 1 });
        }
        assert_eq!(result["value"]["processedBytes"], host.output.len() as u64);
        if result["value"]["complete"] == true {
            complete = true;
            break;
        }
    }
    assert!(complete);
    let operation = current_operation(host, false);
    response(
        host.handle,
        json!({"op":"stream_finish","revision":revision,"operationId":id}),
        operation,
    )
}

fn fragment_seek_steps(host: &mut Host, original: &Value) {
    // The existing actual callback engine gets a cluster crossing its 64 KiB
    // page edge. This is source/ABI qualification, not AppKit installation.
    let text = "a".repeat(65_532) + "👩\u{200d}👩\r\nline";
    let operation = current_operation(host, false);
    let edited = response(
        host.handle,
        json!({"op":"splice", "revision":original,
        "byteStart":0, "byteEnd":0, "oldText":"", "newText":text}),
        operation,
    );
    assert_eq!(edited["ok"], true, "{edited}");
    let revision = edited["value"].clone();
    let bounds = response(
        host.handle,
        json!({"op":"line_bounds", "revision":revision,
        "utf16Offset":65_532}),
        operation,
    );
    assert_eq!(bounds["ok"], true, "{bounds}");
    assert_eq!(bounds["value"]["start"]["bytes"], 0);
    assert_eq!(bounds["value"]["contentEnd"]["bytes"], 65_543);
    assert_eq!(bounds["value"]["contentEnd"]["utf16"], 65_537);
    assert_eq!(bounds["value"]["end"]["bytes"], 65_545);
    assert_eq!(bounds["value"]["end"]["lfCount"], 1);
    assert_eq!(bounds["value"]["lfTerminated"], true);
    let begin = response(
        host.handle,
        json!({"op":"grapheme_seek_begin", "revision":revision,
        "utf16Offset":65_532, "forward":true}),
        operation,
    );
    assert_eq!(begin["ok"], true, "{begin}");
    let id = begin["value"].clone();
    assert_eq!(
        bloom_text_close(host.handle),
        0,
        "Real continuation still owns the engine"
    );
    assert_eq!(
        response(
            host.handle,
            json!({"op":"grapheme_seek_step", "revision":original,
        "operationId":id}),
            operation
        )["error"]["code"],
        "stale"
    );
    assert_eq!(
        response(
            host.handle,
            json!({"op":"grapheme_seek_step", "revision":revision,
        "operationId":id, "maximumBytes":65_536}),
            operation
        )["error"]["code"],
        "request_invalid"
    );
    let writes =
        response(host.handle, json!({"op":"stats"}), operation)["value"]["pageWrites"].clone();
    let mut complete = false;
    for step in 0..50 {
        // Callback pointers come from THIS call, not the begin operation.
        let operation = current_operation(host, step % 2 != 0);
        let progress = response(
            host.handle,
            json!({"op":"grapheme_seek_step", "revision":revision,
            "operationId":id}),
            operation,
        );
        assert_eq!(progress["ok"], true, "{progress}");
        assert!(
            progress["value"]["bufferedBytes"]
                .as_u64()
                .expect("buffer charge")
                <= 65_536
        );
        if progress["value"]["complete"] == true {
            complete = true;
            break;
        }
    }
    assert!(complete);
    let result = response(
        host.handle,
        json!({"op":"grapheme_seek_finish", "revision":revision,
        "operationId":id}),
        operation,
    );
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["value"]["bytes"], 65_543);
    assert_eq!(result["value"]["utf16"], 65_537);
    assert_eq!(result["value"]["lfCount"], 0);
    assert_eq!(
        response(host.handle, json!({"op":"stats"}), operation)["value"]["pageWrites"],
        writes
    );
    let cancelled_id = response(
        host.handle,
        json!({"op":"grapheme_seek_begin", "revision":revision,
        "utf16Offset":0, "forward":true}),
        operation,
    )["value"]
        .clone();
    host.cancelled = true;
    assert_eq!(
        response(
            host.handle,
            json!({"op":"grapheme_seek_step", "revision":revision,
        "operationId":cancelled_id}),
            operation
        )["error"]["code"],
        "cancelled"
    );
    host.cancelled = false;
    assert_eq!(
        response(host.handle, json!({"op":"stats"}), operation)["value"]["activeBulkOperations"],
        0
    );
    assert_eq!(
        response(
            host.handle,
            json!({"op":"bulk_abort", "ownerId":host.owner,
        "documentId":host.document, "operationId":cancelled_id}),
            operation
        )["value"],
        true
    );
}

fn paragraph_prefix_steps(host: &mut Host, original: &Value) {
    let operation = current_operation(host, false);
    let text = "a\r\nb\rc\u{85}d\u{2028}e\u{2029}";
    let after = response(
        host.handle,
        json!({"op":"replace_user_range", "revision":original,
        "byteStart":0, "byteEnd":original["root"]["summary"]["bytes"], "newText":text}),
        operation,
    );
    assert_eq!(after["ok"], true, "{after}");
    let revision = after["value"].clone();
    for lines in [true, false] {
        let begin = response(
            host.handle,
            json!({"op":"paragraph_bounds_begin", "revision":revision,
            "utf16Offset":6, "includeLineEndings":lines}),
            operation,
        );
        assert_eq!(begin["ok"], true, "{begin}");
        let id = begin["value"].clone();
        assert_eq!(bloom_text_close(host.handle), 0);
        let mut complete = false;
        for at in 0..50 {
            let operation = current_operation(host, at % 2 != 0);
            let next = response(
                host.handle,
                json!({"op":"paragraph_bounds_step", "revision":revision,
                "operationId":id}),
                operation,
            );
            assert_eq!(next["ok"], true, "{next}");
            assert!(next["value"]["bufferedBytes"].as_u64().unwrap() <= 65_536);
            if next["value"]["complete"] == true {
                complete = true;
                break;
            }
        }
        assert!(complete);
        let result = response(
            host.handle,
            json!({"op":"paragraph_bounds_finish", "revision":revision,
            "operationId":id}),
            operation,
        );
        assert_eq!(result["ok"], true, "{result}");
        assert_eq!(result["value"]["start"]["utf16"], 5);
        assert_eq!(result["value"]["end"]["utf16"], if lines { 7 } else { 11 });
    }
    let begin = response(
        host.handle,
        json!({"op":"line_prefix_begin", "revision":revision,
        "utf16Start":0, "utf16End":11, "prefix":"> "}),
        operation,
    );
    assert_eq!(begin["ok"], true, "{begin}");
    let id = begin["value"].clone();
    assert_eq!(bloom_text_close(host.handle), 0);
    assert_eq!(
        response(
            host.handle,
            json!({"op":"line_prefix_step", "revision":original,
        "operationId":id}),
            operation
        )["error"]["code"],
        "stale"
    );
    assert_eq!(
        response(
            host.handle,
            json!({"op":"stream_step", "revision":revision,
        "operationId":id}),
            operation
        )["ok"],
        false
    );
    assert_eq!(
        response(host.handle, json!({"op":"stats"}), operation)["value"]["activeBulkOperations"],
        1
    );
    let mut complete = false;
    for at in 0..500 {
        let operation = current_operation(host, at % 2 != 0);
        let next = response(
            host.handle,
            json!({"op":"line_prefix_step", "revision":revision,
            "operationId":id}),
            operation,
        );
        assert_eq!(next["ok"], true, "{next}");
        assert!(next["value"]["bufferedBytes"].as_u64().unwrap() <= 65_536);
        if next["value"]["complete"] == true {
            complete = true;
            break;
        }
    }
    assert!(complete);
    let finished = response(
        host.handle,
        json!({"op":"line_prefix_finish", "revision":revision,
        "operationId":id}),
        operation,
    );
    assert_eq!(finished["ok"], true, "{finished}");
    assert_eq!(finished["value"]["changed"], true);
    assert_eq!(finished["value"]["removing"], false);
    assert_eq!(finished["value"]["utf16Length"], 21);
    let new_revision = &finished["value"]["revision"];
    let window = response(
        host.handle,
        json!({"op":"window", "revision":new_revision,
        "byteStart":0, "maximumBytes":128}),
        operation,
    );
    assert_eq!(window["ok"], true, "{window}");
    assert_eq!(
        window["value"]["text"],
        "> a\r\n> b\r> c\u{85}> d\u{2028}> e\u{2029}"
    );
    let prior = response(
        host.handle,
        json!({"op":"window", "revision":revision,
        "byteStart":0, "maximumBytes":128}),
        operation,
    );
    assert_eq!(prior["value"]["text"], text);
    let cancelled = response(
        host.handle,
        json!({"op":"line_prefix_begin", "revision":revision,
        "utf16Start":0, "utf16End":11, "prefix":"- "}),
        operation,
    )["value"]
        .clone();
    host.cancelled = true;
    assert_eq!(
        response(
            host.handle,
            json!({"op":"line_prefix_step", "revision":revision,
        "operationId":cancelled}),
            operation
        )["error"]["code"],
        "cancelled"
    );
    host.cancelled = false;
    assert_eq!(
        response(
            host.handle,
            json!({"op":"bulk_abort", "ownerId":host.owner,
        "documentId":host.document, "operationId":cancelled}),
            operation
        )["value"],
        true
    );
    assert_eq!(
        response(host.handle, json!({"op":"stats"}), operation)["value"]["activeBulkOperations"],
        0
    );
}

#[test]
fn callback_streams_preserve_unicode_exact_edits_and_joined_context_lifetime() {
    let source = "e\u{301} é 🧑\u{200d}💻\r\n\0 tail";
    let mut host = Box::new(Host {
        owner: Uuid::new_v4(),
        document: Uuid::new_v4(),
        store: Uuid::new_v4(),
        pages: BTreeMap::new(),
        input: source.as_bytes().to_vec(),
        cursor: 0,
        output: Vec::new(),
        handle: 0,
        check_reentry: true,
        reentry_checked: false,
        immutable_reentry: None,
        immutable_reentry_checked: false,
        reject_read: false,
        cancelled: false,
        read_calls: 0,
        write_calls: 0,
        read_variant: 0,
        write_variant: 0,
    });
    let context = (&mut *host as *mut Host).cast();
    let callbacks = BloomTextHost {
        schema: 3,
        context,
        read_page: Some(read_page),
        write_page: Some(write_page),
    };
    // Legacy/unknown hosts must refuse before any callback or valid engine.
    // If a defect opens a handle, join it before asserting to retain context safety.
    for schema in [0, 1, 2] {
        // SAFETY: this public context remains owned through any actual close.
        let refused = unsafe {
            bloom_text_create(BloomTextHost {
                schema,
                ..callbacks
            })
        };
        if refused != 0 {
            let joined = bloom_text_close(refused);
            if joined != 1 {
                // A failed actual join cannot free the still-borrowed context.
                // Preserve this public fixture until the isolated test process exits.
                let _ = Box::leak(host);
                panic!("Unexpected host did not join; public callback context retained");
            }
        }
        assert_eq!(refused, 0, "Only the plain file host format is admitted");
    }
    // SAFETY: the public fixture retains every callback/context until successful close.
    let handle = unsafe { bloom_text_create(callbacks) };
    assert_ne!(handle, 0);
    host.handle = handle;
    assert_eq!(
        unsafe { bloom_text_create(callbacks) },
        0,
        "one shared engine/cache"
    );
    let operation = BloomTextOperation {
        context,
        read_stream: Some(read_stream),
        write_stream: Some(write_stream),
        is_cancelled: Some(cancelled),
    };
    let imported = import_steps(&mut host);
    assert_eq!(imported["ok"], true, "{imported}");
    assert!(host.reentry_checked);
    let revision = imported["value"]["revision"].clone();
    immutable_window_controls(&mut host, &revision, source);
    let window = response(
        handle,
        json!({"op":"window","revision":revision,"byteStart":0,"maximumBytes":131072}),
        operation,
    );
    assert_eq!(window["value"]["text"], source);
    let position = response(
        handle,
        json!({"op":"position","revision":revision,"utf16Offset":2}),
        operation,
    );
    assert_eq!(position["value"], 3);
    let stale = response(
        handle,
        json!({"op":"splice","revision":revision,"byteStart":0,"byteEnd":3,
        "oldText":"é","newText":"ok"}),
        operation,
    );
    assert_eq!(
        stale["error"]["code"], "stale",
        "NFC cannot stand in for exact NFD bytes"
    );
    host.cancelled = true;
    assert_eq!(
        response(
            handle,
            json!({"op":"hash_begin","revision":revision}),
            operation
        )["error"]["code"],
        "cancelled"
    );
    host.cancelled = false;
    let edit = response(
        handle,
        json!({"op":"splice","revision":revision,"byteStart":0,"byteEnd":3,
        "oldText":"e\u{301}","newText":"Z"}),
        operation,
    );
    assert_eq!(edit["ok"], true, "{edit}");
    let after = edit["value"].clone();
    let neutral = response(
        handle,
        json!({"op":"replace_user_range","revision":after,
        "byteStart":0,"byteEnd":1,"newText":"Z"}),
        operation,
    );
    assert_eq!(
        neutral["value"], after,
        "identical user replacement must retain the source root"
    );
    assert_eq!(
        response(
            handle,
            json!({"op":"byte_position","revision":after,"byteStart":1}),
            operation
        )["value"]["utf16"],
        1
    );
    assert_eq!(export_steps(&mut host, &after)["ok"], true);
    assert_eq!(host.output, format!("Z{}", &source[3..]).as_bytes());
    assert_eq!(
        response(
            handle,
            json!({"op":"checkout","revision":after,"retained":revision}),
            operation
        )["value"],
        revision
    );
    let mut foreign = revision.clone();
    foreign["ownerId"] = json!(Uuid::new_v4());
    assert_eq!(
        response(
            handle,
            json!({"op":"checkout","revision":after,"retained":foreign}),
            operation
        )["ok"],
        false
    );
    let stats = response(handle, json!({"op":"stats"}), operation);
    assert!(
        stats["value"]["chargedBytes"]
            .as_u64()
            .expect("cache metric")
            <= 8 * 1024 * 1024
    );
    assert_eq!(stats["value"]["activeBulkOperations"], 0);
    for legacy in ["import", "export", "hash"] {
        let request = if legacy == "import" {
            json!({"op":legacy,"ownerId":host.owner,"documentId":host.document})
        } else {
            json!({"op":legacy,"revision":revision})
        };
        assert_eq!(
            response(handle, request, operation)["error"]["code"],
            "request_invalid"
        );
    }
    // Two whole lifetimes, not two calls: stale/foreign tokens cannot evict a
    // live owner. Cancellation drops only the admitted exact session.
    let first = response(
        handle,
        json!({"op":"hash_begin","revision":revision}),
        operation,
    )["value"]
        .clone();
    let second = response(
        handle,
        json!({"op":"export_begin","revision":revision}),
        operation,
    )["value"]
        .clone();
    assert_eq!(
        response(
            handle,
            json!({"op":"hash_begin","revision":revision}),
            operation
        )["ok"],
        false
    );
    assert_eq!(
        response(
            handle,
            json!({"op":"bulk_abort","ownerId":Uuid::new_v4(),
        "documentId":host.document,"operationId":first}),
            operation
        )["ok"],
        false
    );
    assert_eq!(
        response(handle, json!({"op":"stats"}), operation)["value"]["activeBulkOperations"],
        2
    );
    host.cancelled = true;
    assert_eq!(
        response(
            handle,
            json!({"op":"stream_step","revision":revision,
        "operationId":first}),
            operation
        )["error"]["code"],
        "cancelled"
    );
    assert_eq!(
        response(
            handle,
            json!({"op":"bulk_abort","ownerId":host.owner,
        "documentId":host.document,"operationId":first}),
            operation
        )["value"],
        true
    );
    host.cancelled = false;
    assert_eq!(
        response(
            handle,
            json!({"op":"stream_finish","revision":revision,
        "operationId":first}),
            operation
        )["error"]["code"],
        "stale"
    );
    assert_eq!(
        response(
            handle,
            json!({"op":"bulk_abort","ownerId":host.owner,
        "documentId":host.document,"operationId":second}),
            operation
        )["value"],
        true
    );
    host.cursor = 0;
    let mismatch = response(
        handle,
        json!({"op":"import_begin","ownerId":host.owner,
        "documentId":host.document,"expectedBytes":0}),
        operation,
    )["value"]
        .clone();
    assert_eq!(
        response(
            handle,
            json!({"op":"import_step","ownerId":host.owner,
        "documentId":host.document,"operationId":mismatch}),
            operation
        )["error"]["code"],
        "stale"
    );
    assert_eq!(
        response(handle, json!({"op":"stats"}), operation)["value"]["activeBulkOperations"],
        0
    );
    fragment_seek_steps(&mut host, &revision);
    paragraph_prefix_steps(&mut host, &revision);
    assert_eq!(bloom_text_close(handle), 1);
    assert_eq!(
        response(handle, json!({"op":"stats"}), operation)["error"]["code"],
        "engine_closed"
    );
    assert_eq!(bloom_text_close(handle), 0);
    // Fresh engine has no cache that could hide a rejected authenticated read.
    let fresh = unsafe { bloom_text_create(callbacks) };
    assert_ne!(fresh, 0);
    host.reject_read = true;
    assert_eq!(
        response(fresh, json!({"op":"open","revision":revision}), operation)["error"]["code"],
        "storage_failed"
    );
    assert_eq!(bloom_text_close(fresh), 1);
    // All callbacks have joined before Host and its public pages are released.
}
