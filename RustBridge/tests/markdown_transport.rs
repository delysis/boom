use boom_attachment_ffi::{
    bloom_core_request, bloom_markdown_media_spans, bloom_markdown_spans, boom_attachment_free,
    BoomAttachmentBuffer,
};
use serde_json::{json, Value};
use std::{ptr, slice};

type Parser = unsafe extern "C" fn(*const u8, usize) -> BoomAttachmentBuffer;
const MIB: usize = 1024 * 1024;

fn reply(buffer: BoomAttachmentBuffer) -> Value {
    // SAFETY: each caller passes a fresh result; borrow it until the one free below.
    unsafe {
        let decoded = serde_json::from_slice(slice::from_raw_parts(buffer.data, buffer.length));
        boom_attachment_free(buffer);
        decoded.expect("bounded JSON result")
    }
}

fn raw(parse: Parser, bytes: &[u8]) -> Value {
    // SAFETY: even malformed UTF-8 remains a live immutable byte slice for this call.
    reply(unsafe { parse(bytes.as_ptr(), bytes.len()) })
}

fn legacy(op: &str, text: &str) -> Value {
    let bytes = serde_json::to_vec(&json!({"op": op, "text": text})).expect("request");
    // SAFETY: the serialized request remains live for this synchronous call.
    reply(unsafe { bloom_core_request(bytes.as_ptr(), bytes.len()) })
}

#[test]
fn borrowed_text_preserves_both_existing_parser_results_and_unicode_offsets() {
    let id = "884646c1-14b4-490d-be8c-8953af793315";
    let reference = format!("[Attachment: café\\]🙂.png](boom-attachment:{id})");
    let fixtures = [
        String::new(),
        "Café Cafe\u{301} 👩🏽‍💻 plain prose\n\0\"\\".into(),
        format!("👩‍💻 **bold *emphasis*** `literal`\n# Title\n{reference}\n`{reference}`"),
        format!("[public][r]\n\n[r]: boom-attachment:{id}\n\n```\n{reference}\n```"),
    ];
    for (op, parse) in [
        ("markdown_spans", bloom_markdown_spans as Parser),
        ("media_spans", bloom_markdown_media_spans as Parser),
    ] {
        for text in &fixtures {
            assert_eq!(raw(parse, text.as_bytes()), legacy(op, text), "{op}");
        }
    }
}

#[test]
fn exact_document_limit_and_parser_refusals_match_json_transport() {
    for (op, parse) in [
        ("markdown_spans", bloom_markdown_spans as Parser),
        ("media_spans", bloom_markdown_media_spans as Parser),
    ] {
        let mut text = "é".repeat(MIB);
        let admitted = raw(parse, text.as_bytes());
        assert_eq!(admitted["value"], json!([]));
        assert_eq!(admitted, legacy(op, &text));
        text.push('x');
        let denied = raw(parse, text.as_bytes());
        assert_eq!(denied["error"]["code"], "invalid");
        assert_eq!(denied, legacy(op, &text));
    }
    let excessive = "**x** ".repeat(7_000);
    let result = raw(bloom_markdown_spans, excessive.as_bytes());
    assert_eq!(result["error"]["code"], "invalid");
    assert_eq!(result, legacy("markdown_spans", &excessive));
}

#[test]
fn empty_null_and_invalid_utf8_are_bounded_and_owned() {
    for parse in [
        bloom_markdown_spans as Parser,
        bloom_markdown_media_spans as Parser,
    ] {
        // SAFETY: empty null input is allowed; invalid nonempty/oversized input
        // is refused before a slice is formed. Every reply is freed by reply().
        assert_eq!(reply(unsafe { parse(ptr::null(), 0) })["value"], json!([]));
        for length in [1, 16 * MIB + 1] {
            assert_eq!(
                reply(unsafe { parse(ptr::null(), length) })["error"]["code"],
                "input_limit"
            );
        }
        assert_eq!(
            raw(parse, &[0xf0, 0x28, 0x8c, 0xbc])["error"]["code"],
            "request_invalid"
        );
    }
}
