//! NPE-005: the admitted MIME lexer domain, with small fixed attachments.
use attachment_native_inspect::{Inspector, ProvidedAttachment};
use attachment_native_types::{AttachmentBundle, BudgetLimits, Coverage, InspectionPolicy};
use mail_parser::MessageParser;

fn multipart(boundary: &str, prefix: &str) -> Vec<u8> {
    format!(
        "From: sender@example.test\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"{boundary}\"\r\n\r\n{prefix}--{boundary}\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=a.txt\r\n\r\none\r\n--{boundary}\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=b.txt\r\n\r\ntwo\r\n--{boundary}--\r\n"
    )
    .into_bytes()
}

fn inspect(bytes: &[u8], parts: u32) -> AttachmentBundle {
    inspect_with_limits(
        bytes,
        BudgetLimits {
            max_entries: parts,
            max_edges: parts,
            ..BudgetLimits::default()
        },
    )
}

fn inspect_with_limits(bytes: &[u8], limits: BudgetLimits) -> AttachmentBundle {
    Inspector::new(InspectionPolicy {
        limits,
        ..InspectionPolicy::default()
    })
    .expect("bounded fixture policy")
    .inspect(ProvidedAttachment::from_bytes(
        "fixture.eml",
        Some("message/rfc822".into()),
        bytes,
    ))
    .expect("typed inspection result")
}

#[test]
fn declared_boundary_semantics_block_width_before_the_full_parser() {
    let mut early = true;
    for (boundary, prefix) in [
        ("a b", ""),
        (" lead", ""),
        ("tail--", ""),
        ("control\u{1}", ""),
        ("inline", "Authored prefix "),
    ] {
        let bytes = multipart(boundary, prefix);
        let parsed = MessageParser::default()
            .parse(&bytes)
            .expect("actual dependency accepts fixture");
        assert_eq!(parsed.attachment_count(), 2, "{boundary:?}");
        let contents: Vec<_> = parsed
            .attachments()
            .map(|part| part.contents().to_vec())
            .collect();
        assert_eq!(contents, [b"one".to_vec(), b"two".to_vec()]);
        let admitted = inspect(&bytes, 2);
        assert_eq!(admitted.graph.coverage, Coverage::Complete, "{boundary:?}");
        assert_eq!(admitted.graph.edges.len(), 2);
        let blocked = inspect(&bytes, 1);
        let codes: Vec<_> = blocked
            .graph
            .issues
            .iter()
            .map(|issue| issue.code.as_str())
            .collect();
        eprintln!(
            "NPE-005 boundary={boundary:?} prefix={prefix:?} bytes={} codes={codes:?}",
            bytes.len()
        );
        early &= codes.contains(&"mime_part_limit_exceeded");
        assert_eq!(blocked.graph.objects.len(), 1);
        assert!(blocked.graph.edges.is_empty());
        assert_eq!(blocked.graph.usage.entries, 0);
        assert_eq!(blocked.graph.usage.total_derived_bytes, 0);
    }
    assert!(
        early,
        "all real-lexer width admissions must precede full parser materialization"
    );
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::new();
    for chunk in bytes.chunks(3) {
        let word = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for (shift, present) in [
            (18, true),
            (12, true),
            (6, chunk.len() > 1),
            (0, chunk.len() > 2),
        ] {
            encoded.push(if present {
                char::from(TABLE[((word >> shift) & 63) as usize])
            } else {
                '='
            });
        }
    }
    encoded
}

fn encoded_message(inner: &[u8], quoted_printable: bool) -> Vec<u8> {
    let encoding = if quoted_printable {
        "quoted-printable"
    } else {
        "base64"
    };
    let body = if quoted_printable {
        inner
            .iter()
            .map(|byte| format!("={byte:02X}"))
            .collect::<String>()
    } else {
        base64(inner)
    };
    format!("From: sender@example.test\r\nContent-Type: message/rfc822\r\nContent-Transfer-Encoding: {encoding}\r\n\r\n{body}").into_bytes()
}

#[test]
fn encoded_nested_messages_share_admissions_and_preserve_contents() {
    let inner = multipart("inside a", "");
    for quoted_printable in [false, true] {
        let bytes = encoded_message(&inner, quoted_printable);
        let parsed = MessageParser::default()
            .parse(&bytes)
            .expect("actual encoded nested message");
        assert_eq!(parsed.attachment_count(), 1);
        let child = parsed
            .attachments()
            .next()
            .expect("captured nested message");
        assert_eq!(child.contents(), inner);
        assert_eq!(
            child
                .message()
                .expect("decoded nested tree")
                .attachment_count(),
            2
        );
        let admitted = inspect(&bytes, 8);
        assert_eq!(admitted.graph.coverage, Coverage::Complete);
        assert_eq!(admitted.graph.edges.len(), 3);
        let blocked = inspect(&bytes, 2);
        assert!(
            blocked
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "mime_part_limit_exceeded")
        );
        assert_eq!(blocked.graph.objects.len(), 1);
        assert!(blocked.graph.edges.is_empty());
        assert_eq!(blocked.graph.usage.total_derived_bytes, 0);
    }
}

#[test]
fn unencoded_messages_and_digest_defaults_count_without_delimiters_between_headers() {
    let inner = multipart("inside a", "");
    let unencoded = format!(
        "From: sender@example.test\r\nContent-Type: message/rfc822\r\n\r\n{}",
        String::from_utf8_lossy(&inner)
    )
    .into_bytes();
    let digest = format!("From: sender@example.test\r\nContent-Type: multipart/digest; boundary=digest\r\n\r\n--digest\r\nContent-Disposition: attachment; filename=inner.eml\r\n\r\n{}\r\n--digest--\r\n", String::from_utf8_lossy(&inner)).into_bytes();
    for bytes in [unencoded, digest] {
        let parsed = MessageParser::default()
            .parse(&bytes)
            .expect("actual unencoded nested message");
        assert_eq!(parsed.attachment_count(), 1);
        assert!(
            parsed
                .attachments()
                .next()
                .expect("nested child")
                .message()
                .is_some()
        );
        let admitted = inspect(&bytes, 8);
        assert_eq!(admitted.graph.coverage, Coverage::Complete);
        assert_eq!(admitted.graph.edges.len(), 3);
        let blocked = inspect(&bytes, 2);
        assert!(
            blocked
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "mime_part_limit_exceeded")
        );
        assert_eq!(blocked.graph.objects.len(), 1);
        assert!(blocked.graph.edges.is_empty());
    }
}

#[test]
fn folded_quoted_continued_boundaries_preserve_native_attachment_admission() {
    let original = multipart("a b", "");
    let text = String::from_utf8(original).expect("small ASCII fixture");
    for declaration in [
        "Content-Type: multipart/mixed;\r\n boundary=\"a b\"",
        "Content-Type: multipart/mixed; boundary*0=\"a\"; boundary*1=\" b\"",
        "Content-Type: multipart/mixed; boundary=\"a b\"\r\nContent-Type: multipart/mixed; boundary=\"a b\"",
    ] {
        let bytes = text
            .replace(
                "Content-Type: multipart/mixed; boundary=\"a b\"",
                declaration,
            )
            .into_bytes();
        assert_eq!(
            MessageParser::default()
                .parse(&bytes)
                .expect("dependency header semantics")
                .attachment_count(),
            2
        );
        assert_eq!(inspect(&bytes, 2).graph.coverage, Coverage::Complete);
        let blocked = inspect(&bytes, 1);
        assert!(
            blocked
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "mime_part_limit_exceeded")
        );
    }
}

#[test]
fn cumulative_header_limit_accepts_exact_bytes_and_blocks_one_less() {
    let bytes = multipart("a b", "");
    let parsed = MessageParser::default()
        .parse(&bytes)
        .expect("independent full parser");
    let metadata: u64 = parsed
        .parts
        .iter()
        .map(|part| u64::from(part.offset_body - part.offset_header))
        .sum();
    let policy = |budget| BudgetLimits {
        max_container_metadata_bytes: budget,
        ..BudgetLimits::default()
    };
    assert_eq!(
        inspect_with_limits(&bytes, policy(metadata)).graph.coverage,
        Coverage::Complete
    );
    let blocked = inspect_with_limits(&bytes, policy(metadata - 1));
    assert!(
        blocked
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_metadata_limit_exceeded")
    );
    assert!(blocked.graph.edges.is_empty());
    assert_eq!(blocked.graph.usage.total_derived_bytes, 0);
}

#[test]
fn charset_expansion_is_admitted_before_eager_text_conversion() {
    let mut bytes =
        b"From: sender@example.test\r\nContent-Type: text/plain; charset=windows-1252\r\n\r\n"
            .to_vec();
    bytes.extend_from_slice(&[0x80; 128]);
    let parsed = MessageParser::default()
        .parse(&bytes)
        .expect("small charset positive control");
    assert_eq!(parsed.parts[0].contents(), "€".repeat(128).as_bytes());
    assert_eq!(inspect(&bytes, 8).graph.coverage, Coverage::Complete);
    let budget = bytes.len() as u64 + 8;
    assert!(budget < parsed.parts[0].contents().len() as u64);
    let blocked = inspect_with_limits(
        &bytes,
        BudgetLimits {
            max_object_bytes: budget,
            max_total_derived_bytes: budget,
            ..BudgetLimits::default()
        },
    );
    assert!(
        blocked
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_derived_budget_exceeded")
    );
    assert!(blocked.graph.edges.is_empty());
    assert_eq!(blocked.graph.usage.total_derived_bytes, 0);
}

#[test]
fn decoded_nested_source_respects_the_structured_parser_input_limit() {
    let inner = format!("Subject: small\r\n\r\n{}", "\n".repeat(128));
    let bytes = format!("From: sender@example.test\r\nContent-Type: message/rfc822\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n{inner}").into_bytes();
    let parsed = MessageParser::default()
        .parse(&bytes)
        .expect("normal QP newline normalization");
    let decoded = parsed
        .attachments()
        .next()
        .expect("nested contents")
        .contents();
    assert!(decoded.len() > bytes.len());
    assert_eq!(inspect(&bytes, 8).graph.coverage, Coverage::Complete);
    let blocked = inspect_with_limits(
        &bytes,
        BudgetLimits {
            max_parser_input_bytes: bytes.len() as u64,
            ..BudgetLimits::default()
        },
    );
    assert!(
        blocked
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "parser_input_limit_exceeded")
    );
    assert!(blocked.graph.edges.is_empty());
    assert_eq!(blocked.graph.usage.total_derived_bytes, 0);
}

#[test]
fn invalid_transfer_encoding_keeps_the_dependency_recovery_contents() {
    let original = multipart("a b", "");
    let bytes = String::from_utf8(original)
        .expect("small ASCII fixture")
        .replace(
            "filename=a.txt\r\n\r\none",
            "filename=a.txt\r\nContent-Transfer-Encoding: base64\r\n\r\nnot*base64",
        )
        .into_bytes();
    let parsed = MessageParser::default()
        .parse(&bytes)
        .expect("real malformed transfer recovery");
    let first = parsed.attachments().next().expect("recovered attachment");
    assert!(first.is_encoding_problem);
    assert_eq!(first.contents(), b"not*base64");
    assert_eq!(inspect(&bytes, 2).graph.coverage, Coverage::Complete);
    assert!(
        inspect(&bytes, 1)
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_part_limit_exceeded")
    );
}
