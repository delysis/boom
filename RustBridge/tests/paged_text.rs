use boom_attachment_ffi::{
    bloom_text_close, bloom_text_create, bloom_text_request, boom_attachment_free, BloomTextHost,
    BloomTextOperation,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::{ptr, slice};
use uuid::Uuid;

// Small public callback fixture only; native encrypted SQL controls are
// separate. Plaintext UUID-indexed objects do not qualify SQL durability.
struct Host {
    owner: Uuid,
    document: Uuid,
    store: Uuid,
    pages: BTreeMap<Uuid, Vec<u8>>,
    input: Vec<u8>,
    cursor: usize,
    output: Vec<u8>,
    handle: u64,
    check_reentry: bool,
    reentry_checked: bool,
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
    // SAFETY: fixture retains Host until all callbacks/close have joined.
    let host = unsafe { &mut *context.cast::<Host>() };
    let Some(value) = (unsafe { metadata(data, length) }) else {
        return -1;
    };
    if !admit(host, &value) || host.reject_read {
        return -1;
    }
    let Some(id) = value["page"]["locator"]["recordId"]
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())
    else {
        return -1;
    };
    if value["page"]["locator"]["storage"] != "sqlite_v1"
        || value["page"]["locator"]["storeId"].as_str() != Some(host.store.to_string().as_str()) {
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
    let id = Uuid::new_v4();
    let locator = json!({"storage":"sqlite_v1","storeId":host.store,"recordId":id,
        "ciphertextBytes":plaintext_length + 28});
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
        reject_read: false,
        cancelled: false,
        read_calls: 0,
        write_calls: 0,
        read_variant: 0,
        write_variant: 0,
    });
    let context = (&mut *host as *mut Host).cast();
    let callbacks = BloomTextHost {
        schema: 2,
        context,
        read_page: Some(read_page),
        write_page: Some(write_page),
    };
    // Legacy/unknown hosts must refuse before any callback or valid engine.
    // If a defect opens a handle, join it before asserting to retain context safety.
    for schema in [0, 1, 3] {
        // SAFETY: this public context remains owned through any actual close.
        let refused = unsafe { bloom_text_create(BloomTextHost { schema, ..callbacks }) };
        if refused != 0 {
            let joined = bloom_text_close(refused);
            if joined != 1 {
                // A failed actual join cannot free the still-borrowed context.
                // Preserve this public fixture until the isolated test process exits.
                let _ = Box::leak(host);
                panic!("Unexpected host did not join; public callback context retained");
            }
        }
        assert_eq!(refused, 0, "Only the single SQL host format is admitted");
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
