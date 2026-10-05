//! In-process C boundary for the existing, authority-free attachment host.
//! Unsafe code is confined to borrowed C slices and returning/freeing one Box<[u8]>.
//! No filesystem paths, network handles, model handles or subprocess APIs exist here.
use attachment_native_host::{AttachmentHost, AttachmentHostConfig, ProvidedAttachment};
use attachment_native_types::{PreparedPart, TargetCapabilities};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice, str,
};

const MAX_INPUT: usize = 64 * 1024 * 1024;
const MAX_OUTPUT: usize = 8 * 1024 * 1024;

#[repr(C)]
pub struct BoomAttachmentBuffer {
    pub data: *mut u8,
    pub length: usize,
}

fn error(code: &str, message: &str) -> Value {
    json!({"schema":1,"ok":false,"error":{"code":code,"message":message}})
}
fn process(name: &str, bytes: &[u8]) -> Value {
    if name.is_empty() || name.len() > 1024 || name.chars().any(char::is_control) {
        return error("name_invalid", "Attachment display name is invalid.");
    }
    if bytes.is_empty() || bytes.len() > MAX_INPUT {
        return error(
            "input_limit",
            "Choose a non-empty attachment of at most 64 MiB.",
        );
    }
    let host = match AttachmentHost::new(AttachmentHostConfig::default()) {
        Ok(host) => host,
        Err(e) => return error(&e.code, &e.safe_message),
    };
    // Text is the ONLY automatically admitted modality. Native image/audio/video
    // descriptions are a separate explicit user action, with lossy-source receipts.
    let target = TargetCapabilities {
        target_id: "boom-gemma4-text-context".into(),
        fingerprint: "boom-gemma4-text-context:v1".into(),
        accepted_media_types: Default::default(),
        accepted_media_families: Default::default(),
        max_media_objects: 1,
        max_media_bytes: 67_108_864,
        max_text_bytes: 262_144,
        supports_markdown: true,
        supports_native_pdf: false,
        supports_native_video: false,
    };
    match host.process(
        ProvidedAttachment::from_bytes(name, None, bytes.to_vec()),
        &target,
    ) {
        Ok(prepared) => {
            let texts: Vec<&str> = prepared
                .plan
                .parts
                .iter()
                .filter_map(|part| match part {
                    PreparedPart::UntrustedText { text, .. } => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            json!({"schema":1,"ok":true,"root":prepared.bundle.graph.root.0,"input_sha256":format!("{:x}", Sha256::digest(bytes)),
                "texts":texts,"receipt":prepared.receipt,"plan":prepared.plan,
                "graph":prepared.bundle.graph,"error":null})
        }
        Err(e) => error(&e.code, &e.safe_message),
    }
}
fn owned(value: Value) -> BoomAttachmentBuffer {
    let mut bytes =
        serde_json::to_vec(&value).unwrap_or_else(|_| b"{\"schema\":1,\"ok\":false}".to_vec());
    if bytes.len() > MAX_OUTPUT {
        bytes = b"{\"schema\":1,\"ok\":false,\"error\":{\"code\":\"output_limit\",\"message\":\"Attachment receipt exceeds 8 MiB; no context admitted.\"}}".to_vec();
    }
    let boxed = bytes.into_boxed_slice();
    let length = boxed.len();
    BoomAttachmentBuffer {
        data: Box::into_raw(boxed) as *mut u8,
        length,
    }
}

/// # Safety
/// For nonzero lengths, pointers must address readable immutable buffers of the
/// supplied lengths for this call. The embedding Swift Data.withUnsafeBytes owns them.
/// The returned buffer must be released exactly once with boom_attachment_free.
#[no_mangle]
pub unsafe extern "C" fn bloom_core_request(
    data: *const u8,
    length: usize,
) -> BoomAttachmentBuffer {
    if data.is_null() || length == 0 || length > 16 * 1024 * 1024 {
        return owned(error("input_limit", "Product request exceeds 16 MiB."));
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller provides a live immutable buffer for this call only.
        let bytes = unsafe { slice::from_raw_parts(data, length) };
        match serde_json::from_slice::<bloom_core::Request>(bytes) {
            Ok(request) => match bloom_core::execute(request) {
                Ok(value) => json!({"schema":1,"ok":true,"value":value}),
                Err(e) => error("invalid", &e.to_string()),
            },
            Err(_) => error("request_invalid", "Malformed product request."),
        }
    }));
    owned(outcome.unwrap_or_else(|_| error("core_panic", "Product request failed.")))
}

/// # Safety
/// For nonzero lengths, pointers must address readable immutable buffers of the
/// supplied lengths for this call. The embedding Swift Data.withUnsafeBytes owns them.
/// The returned buffer must be released exactly once with boom_attachment_free.
#[no_mangle]
pub unsafe extern "C" fn bloom_media_admit(data: *const u8, length: usize) -> BoomAttachmentBuffer {
    if data.is_null() || length == 0 || length > MAX_INPUT {
        return owned(error(
            "input_limit",
            "Native media must be nonempty and at most 64 MiB.",
        ));
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller provides a live immutable byte buffer only for this call.
        let bytes = unsafe { slice::from_raw_parts(data, length) };
        match bloom_core::admit_media(bytes) {
            Ok(kind) => json!({"schema":1,"ok":true,"value":kind}),
            Err(e) => error("media_denied", &e.to_string()),
        }
    }));
    owned(outcome.unwrap_or_else(|_| error("media_panic", "Media admission failed.")))
}

/// # Safety
/// For nonzero lengths, pointers must address readable immutable buffers of the
/// supplied lengths for this call. The embedding Swift Data.withUnsafeBytes owns them.
/// The returned buffer must be released exactly once with boom_attachment_free.
#[no_mangle]
pub unsafe extern "C" fn boom_attachment_inspect(
    name: *const u8,
    name_length: usize,
    data: *const u8,
    length: usize,
) -> BoomAttachmentBuffer {
    if name.is_null()
        || data.is_null()
        || name_length == 0
        || name_length > 1024
        || length == 0
        || length > MAX_INPUT
    {
        return owned(error(
            "input_invalid",
            "Invalid borrowed attachment buffer or size.",
        ));
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller upholds the documented borrowed-buffer lifetime/length contract.
        let (name_bytes, bytes) = unsafe {
            (
                slice::from_raw_parts(name, name_length),
                slice::from_raw_parts(data, length),
            )
        };
        match str::from_utf8(name_bytes) {
            Ok(name) => process(name, bytes),
            Err(_) => error("name_utf8", "Attachment name must be UTF-8."),
        }
    }));
    owned(outcome.unwrap_or_else(|_| {
        error(
            "host_panic",
            "Attachment processing failed; no context admitted.",
        )
    }))
}

/// # Safety
/// `buffer` must be an as-yet-unfreed value returned by boom_attachment_inspect.
#[no_mangle]
pub unsafe extern "C" fn boom_attachment_free(buffer: BoomAttachmentBuffer) {
    if !buffer.data.is_null() {
        // SAFETY: data/length originate from Box<[u8]> in owned(), with matching allocator.
        unsafe {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(
                buffer.data,
                buffer.length,
            )));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn text_reuses_real_host() {
        let v = process("note.md", b"# One\n\nTwo");
        assert_eq!(v["ok"], true);
        assert_eq!(v["receipt"]["network_used"], false);
        assert_eq!(v["receipt"]["process_used"], false);
        assert!(v["texts"].as_array().is_some_and(|a| !a.is_empty()));
    }
    #[test]
    fn hostile_names_rejected() {
        assert_eq!(process("a\0b", b"data")["ok"], false);
    }
    #[test]
    fn empty_input_rejected() {
        assert_eq!(process("a", b"")["ok"], false);
    }
    #[test]
    fn null_ffi_is_typed_error_and_frees() {
        // SAFETY: null inputs are explicitly validated before borrowed slices are formed.
        unsafe {
            let b = boom_attachment_inspect(ptr::null(), 0, ptr::null(), 0);
            let v: Value = serde_json::from_slice(slice::from_raw_parts(b.data, b.length)).unwrap();
            assert_eq!(v["ok"], false);
            boom_attachment_free(b);
        }
    }
    #[test]
    fn media_bytes_cross_the_bounded_boundary_without_json_encoding() {
        let bytes = b"RIFF\0\0\0\0WAVE";
        // SAFETY: bytes outlive the call; every returned owned buffer is freed once.
        unsafe {
            let buffer = bloom_media_admit(bytes.as_ptr(), bytes.len());
            let value: Value =
                serde_json::from_slice(slice::from_raw_parts(buffer.data, buffer.length)).unwrap();
            assert_eq!(value["value"], "wav");
            boom_attachment_free(buffer);
            for (data, length) in [(ptr::null(), 1), (bytes.as_ptr(), MAX_INPUT + 1)] {
                let buffer = bloom_media_admit(data, length);
                let value: Value =
                    serde_json::from_slice(slice::from_raw_parts(buffer.data, buffer.length))
                        .unwrap();
                assert_eq!(value["ok"], false);
                assert_eq!(value["error"]["code"], "input_limit");
                boom_attachment_free(buffer);
            }
        }
    }
}
