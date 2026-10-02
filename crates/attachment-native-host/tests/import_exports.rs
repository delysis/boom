use attachment_native_host::{AttachmentHost, AttachmentHostConfig, ProvidedAttachment};
use attachment_native_types::{ArtifactPayload, Coverage, DetectedFormat, TransformKind};

fn inspect(name: &str, bytes: &[u8]) -> attachment_native_host::CanonicalizedAttachment {
    AttachmentHost::new(AttachmentHostConfig::default())
        .expect("host")
        .inspect_and_canonicalize(ProvidedAttachment::from_bytes(name, None, bytes))
        .expect("inspect")
}
fn text(result: &attachment_native_host::CanonicalizedAttachment) -> String {
    result
        .bundle
        .artifacts
        .iter()
        .filter_map(|artifact| match &artifact.payload {
            ArtifactPayload::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

const MBOX: &[u8] = b"From a@example.com Sat Jan 01 00:00:00 2022\nFrom: A <a@example.com>\nSubject: First\nMessage-ID: <first@example.com>\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nCaf=C3=A9\n>From quoted body\nFrom b@example.com Sun Jan 02 00:00:00 2022\nFrom: B <b@example.com>\nSubject: Second\nMessage-ID: <second@example.com>\n\nSecond message body\n";

#[test]
fn mailbox_preserves_message_boundaries_mime_and_source_graph() {
    let result = inspect("mail.mbox", MBOX);
    assert_eq!(
        result.bundle.graph.objects[0].detection.selected,
        Some(DetectedFormat::Mbox)
    );
    assert_eq!(
        result
            .bundle
            .graph
            .edges
            .iter()
            .filter(|edge| edge.transform.kind == TransformKind::MailboxMessage)
            .count(),
        2
    );
    let body = text(&result);
    assert!(body.contains("Café"), "{body}");
    assert!(body.contains("From quoted body"));
    assert!(body.contains("Second message body"));
    assert!(body.contains("first@example.com"));
    assert!(body.contains("second@example.com"));
    assert!(result.receipt.complete_coverage);
    result.bundle.validate().expect("valid graph");
}

#[test]
fn mailbox_limits_refuse_unrepresentative_prefixes() {
    let mut config = AttachmentHostConfig::default();
    config.inspection.limits.max_entries = 1;
    let result = AttachmentHost::new(config)
        .expect("host")
        .inspect_and_canonicalize(ProvidedAttachment::from_bytes("mail.mbox", None, MBOX))
        .expect("inspection report");
    assert!(!result.receipt.complete_coverage);
    assert!(text(&result).is_empty());
}

#[test]
fn claude_export_preserves_roles_short_messages_and_nontext_metadata() {
    let result = inspect("conversations.json", br#"[{"uuid":"c1","name":"A conversation","chat_messages":[{"uuid":"m1","sender":"human","content":[{"type":"text","text":"Hi"}]},{"uuid":"m2","sender":"assistant","content":[{"type":"text","text":"Hello"},{"type":"tool_use","name":"untrusted","input":{"command":"do not run"}}]}]}]"#);
    let body = text(&result);
    assert!(body.contains("## human"));
    assert!(body.contains("## assistant"));
    assert!(body.contains("Hi"));
    assert!(body.contains("do not run"));
    assert!(result.receipt.complete_coverage);
    assert!(
        !result.receipt.model_invoked
            && !result.receipt.process_used
            && !result.receipt.network_used
    );
}

#[test]
fn slack_export_keeps_short_posts_thread_ids_and_files_without_fetching() {
    let result = inspect("team/2026-09-14.json", br#"[{"type":"message","user":"U1","ts":"123.000001","thread_ts":"122.000001","text":"OK","files":[{"url_private":"https://example.invalid/private"}]}]"#);
    let body = text(&result);
    assert!(body.contains("OK"));
    assert!(body.contains("thread_ts"));
    assert!(body.contains("123.000001"));
    assert!(body.contains("url_private"));
    assert!(!result.receipt.network_used);
}

#[test]
fn malformed_conversations_are_not_clean_empty_successes() {
    let result = inspect(
        "conversations.json",
        br#"[{"chat_messages":[{"sender":"assistant"}]}]"#,
    );
    assert!(!result.receipt.complete_coverage);
    assert!(text(&result).is_empty());
}

#[test]
fn rtf_decodes_unicode_groups_and_escaped_braces() {
    let result = inspect("proposal.rtf", br"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0 HiddenFont;}}Caf\'e9 \u-10179?\u-8704?\par Text \{literal\}.}");
    let body = text(&result);
    assert!(body.contains("Café 😀"), "{body}");
    assert!(body.contains("{literal}"));
    assert!(!body.contains("HiddenFont"));
    assert!(result.receipt.complete_coverage);
}

#[test]
fn rtf_does_not_execute_objects_or_fabricate_truncated_text() {
    let result = inspect("embedded.rtf", br"{\rtf1 Safe {\object forbidden} text}");
    assert!(!text(&result).contains("forbidden"));
    assert!(matches!(
        result.bundle.graph.coverage,
        Coverage::Partial { .. }
    ));
    let malformed = inspect("broken.rtf", br"{\rtf1 unfinished");
    assert!(!malformed.receipt.complete_coverage);
    assert!(text(&malformed).is_empty());
}

#[test]
fn structured_export_output_limit_is_utf8_safe_and_explicit() {
    let mut config = AttachmentHostConfig::default();
    config.inspection.limits.max_text_bytes = 45;
    let result = AttachmentHost::new(config)
        .expect("host")
        .inspect_and_canonicalize(ProvidedAttachment::from_bytes(
            "messages.json",
            None,
            "[{\"type\":\"message\",\"ts\":\"1.0\",\"text\":\"éééééééééééééééééééééééééééé\"}]"
                .as_bytes(),
        ))
        .expect("inspection");
    assert!(!result.receipt.complete_coverage);
    assert!(text(&result).len() <= 45);
    result.bundle.validate().expect("bounded segments");
}

#[test]
fn linkedin_notes_and_csv_fields_remain_distinct() {
    let result = inspect("Connections.csv", b"Notes:\nThis export contains connection information.\n\nFirst Name,Last Name,Company,Position,Connected On,URL\nAda,Lovelace,Example,Writer,2026-09-14,https://example.invalid/ada\n");
    let body = text(&result);
    assert!(body.starts_with("| First Name | Last Name |"), "{body}");
    assert!(body.contains("https://example.invalid/ada"));
    assert!(!body.contains("This export contains"));
    let post = inspect(
        "Shares.csv",
        b"Date,ShareCommentary,URL\n2026-09-14,A short post,https://example.invalid/post\n",
    );
    assert!(text(&post).contains("| A short post | https://example.invalid/post |"));
}

#[test]
fn mailbox_accepts_declared_legacy_charset_without_lossy_source_conversion() {
    let result = inspect("mail.mbox", b"From a@example.com Sat Jan 01 00:00:00 2022\nFrom: a@example.com\nSubject: Legacy\nX-Gmail-Labels: Research,Inbox\nContent-Type: text/plain; charset=iso-8859-1\n\nCaf\xe9\n");
    let body = text(&result);
    assert!(body.contains("Café"), "{body}");
    assert!(body.contains("Research,Inbox"), "{body}");
    assert!(result.receipt.complete_coverage);
}
