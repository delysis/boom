mod support;

use attachment_native_inspect::{Inspector, ProvidedAttachment};
use attachment_native_types::{
    BudgetLimits, Coverage, DetectedFormat, DetectionConfidence, DetectionEvidence, EdgeOutcome,
    InspectionPolicy, ObjectStatus,
};
use support::{email_with_misleading_png_attachment, gzip_bytes, nested_email, zip_bytes};

fn inspect(
    name: &str,
    declared_media_type: Option<&str>,
    bytes: Vec<u8>,
) -> attachment_native_types::AttachmentBundle {
    Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            name,
            declared_media_type.map(str::to_string),
            bytes,
        ))
        .expect("adversarial inspection should return a typed graph")
}

fn tar_bytes(name: &str, bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::new();
    {
        let mut builder = tar::Builder::new(&mut output);
        let mut header = tar::Header::new_gnu();
        header.set_mode(0o600);
        header.set_size(u64::try_from(bytes.len()).expect("fixture length should fit"));
        header.set_cksum();
        builder
            .append_data(&mut header, name, bytes)
            .expect("fixture TAR entry should append");
        builder.finish().expect("fixture TAR should finish");
    }
    output
}

#[test]
fn nested_rfc822_attachments_reenter_the_same_inspection_queue() {
    let bundle = inspect("outer.eml", Some("message/rfc822"), nested_email());
    let formats = bundle
        .graph
        .objects
        .iter()
        .filter_map(|object| object.detection.selected)
        .collect::<Vec<_>>();

    assert_eq!(
        formats
            .iter()
            .filter(|format| **format == DetectedFormat::Email)
            .count(),
        2
    );
    assert_eq!(
        formats
            .iter()
            .filter(|format| **format == DetectedFormat::PlainText)
            .count(),
        1
    );
    assert_eq!(bundle.graph.edges.len(), 2);
    assert_eq!(bundle.graph.usage.entries, 2);
    assert_eq!(bundle.graph.usage.deepest_object, 2);
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
}

#[test]
fn nested_rfc822_attachments_share_the_global_entry_budget() {
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_entries: 1,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy should be valid")
        .inspect(ProvidedAttachment::from_bytes(
            "outer.eml",
            Some("message/rfc822".to_string()),
            nested_email(),
        ))
        .expect("nested email inspection should return a typed graph");

    assert_eq!(bundle.graph.objects.len(), 1);
    assert!(bundle.graph.edges.is_empty());
    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_part_limit_exceeded")
    );
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
}

#[test]
fn cumulative_derived_byte_budget_is_not_reset_for_nested_archives() {
    let leaf = b"the nested leaf must not receive a fresh budget";
    let inner = zip_bytes(&[("leaf.txt", leaf)]);
    let outer = zip_bytes(&[("inner.zip", &inner)]);
    let inner_len = u64::try_from(inner.len()).expect("fixture length should fit");
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_total_derived_bytes: inner_len + 3,
            max_object_bytes: inner_len + 3,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };

    let bundle = Inspector::new(policy)
        .expect("fixture policy should be valid")
        .inspect(ProvidedAttachment::from_bytes("outer.zip", None, outer))
        .expect("nested archive inspection should return a typed graph");

    assert_eq!(bundle.graph.objects.len(), 2);
    assert_eq!(bundle.graph.edges.len(), 2);
    assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    assert_eq!(bundle.graph.edges[1].outcome, EdgeOutcome::BudgetExceeded);
    assert_eq!(bundle.graph.usage.total_derived_bytes, inner_len + 3);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "derived_stream_limit_exceeded")
    );
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
}

#[test]
fn zip_object_limit_rejection_retains_one_contract_valid_edge() {
    let archive = zip_bytes(&[("child.txt", b"child")]);
    let root_len = u64::try_from(archive.len()).expect("fixture length should fit");
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_objects: 1,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };

    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "one-object.zip",
            None,
            archive,
        ))
        .expect("object rejection should remain a contract-valid typed graph");

    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.blobs.len(), 1);
    assert_eq!(bundle.graph.usage.objects, 1);
    assert_eq!(bundle.graph.usage.retained_bytes, root_len);
    assert_eq!(bundle.graph.edges.len(), 1);
    assert_eq!(bundle.graph.usage.edges, 1);
    assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::BudgetExceeded);
    assert!(bundle.graph.edges[0].child.is_none());
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "object_count_exceeded")
    );
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    bundle
        .validate()
        .expect("rejected child accounting must satisfy the public contract");
}

#[test]
fn tar_name_rejection_does_not_charge_an_unrepresented_edge() {
    let archive = tar_bytes("long-name.txt", b"content");
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_name_bytes: 1,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };

    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "tiny-name-limit.tar",
            None,
            archive,
        ))
        .expect("name rejection should remain a contract-valid typed graph");

    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.graph.usage.objects, 1);
    assert!(bundle.graph.edges.is_empty());
    assert_eq!(bundle.graph.usage.edges, 0);
    assert_eq!(bundle.graph.usage.entries, 1);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "archive_name_limit_exceeded")
    );
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    bundle
        .validate()
        .expect("rejected name accounting must satisfy the public contract");
}

#[test]
fn exhausting_one_zip_member_blocks_every_later_sibling_decoder() {
    let archive = zip_bytes(&[("a.bin", b"four"), ("b.bin", b"more")]);
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_total_derived_bytes: 4,
            max_object_bytes: 4,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "siblings.zip",
            None,
            archive,
        ))
        .expect("budget rejection should remain a typed graph");

    assert_eq!(bundle.graph.usage.total_derived_bytes, 4);
    assert_eq!(bundle.graph.objects.len(), 2);
    assert_eq!(bundle.graph.edges.len(), 2);
    assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    assert_eq!(bundle.graph.edges[1].outcome, EdgeOutcome::BudgetExceeded);
}

#[test]
fn exhausted_budget_prevents_a_queued_nested_decoder_from_opening() {
    let nested = gzip_bytes(b"this payload must never be decoded");
    let allowance = u64::try_from(nested.len()).expect("fixture length");
    let archive = zip_bytes(&[("nested.gz", &nested)]);
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_total_derived_bytes: allowance,
            max_object_bytes: allowance,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("queued.zip", None, archive))
        .expect("queue exhaustion should remain a typed graph");

    assert_eq!(bundle.graph.usage.total_derived_bytes, allowance);
    assert_eq!(bundle.graph.objects.len(), 2);
    assert_eq!(bundle.graph.edges.len(), 1);
    assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    assert!(matches!(
        &bundle.graph.objects[1].status,
        ObjectStatus::Partial { reasons }
            if reasons.iter().any(|reason| reason == "total_derived_bytes_exceeded")
    ));
}

#[test]
fn over_wide_mime_is_blocked_before_mail_parser_materialization() {
    let message = br#"MIME-Version: 1.0
Content-Type: multipart/mixed; boundary=x

--x
Content-Disposition: attachment; filename=a.txt

a
--x
Content-Disposition: attachment; filename=b.txt

b
--x
Content-Disposition: attachment; filename=c.txt

c
"#;
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_entries: 2,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "wide.eml",
            Some("message/rfc822".to_string()),
            message,
        ))
        .expect("preflight should return a typed graph");

    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(bundle.graph.edges.is_empty());
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_part_limit_exceeded")
    );
    assert!(
        !bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "email_structure_invalid")
    );
}

#[test]
fn mime_header_metadata_is_blocked_before_mail_parser_materialization() {
    let message = b"Subject: deliberately-too-wide\r\n\r\nbody";
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_container_metadata_bytes: 8,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "metadata.eml",
            Some("message/rfc822".to_string()),
            message,
        ))
        .expect("preflight should return a typed graph");

    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "mime_metadata_limit_exceeded")
    );
}

#[test]
fn pdf_object_width_is_blocked_before_lopdf_materialization() {
    let bytes = b"%PDF-1.7\n1 0 obj\n2 0 obj\n3 0 obj\n4 0 obj\n";
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_objects: 4,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("wide.pdf", None, bytes))
        .expect("preflight should return a typed graph");

    assert_eq!(bundle.graph.usage.objects, 1);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "pdf_object_limit_exceeded")
    );
    assert!(
        !bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "pdf_structure_invalid")
    );
}

#[test]
fn pdf_xref_width_is_blocked_before_lopdf_materialization() {
    let bytes = b"%PDF-1.7\nxref\n0 1000000\n";
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_objects: 8,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("xref.pdf", None, bytes))
        .expect("preflight should return a typed graph");

    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "pdf_xref_object_limit_exceeded")
    );
    assert!(
        !bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "pdf_structure_invalid")
    );
}

#[test]
fn truncated_zip_and_gzip_are_explicit_malformed_outcomes() {
    let zip = inspect("truncated.zip", None, b"PK\x03\x04".to_vec());
    assert!(matches!(
        &zip.graph.objects[0].status,
        ObjectStatus::Malformed { code } if code == "zip_structure_invalid"
    ));
    assert!(
        zip.graph
            .issues
            .iter()
            .any(|issue| issue.code == "zip_structure_invalid")
    );
    assert!(matches!(zip.graph.coverage, Coverage::Partial { .. }));

    let mut truncated_gzip = gzip_bytes(b"integrity checked payload");
    truncated_gzip.truncate(10);
    let gzip = inspect("truncated.gz", None, truncated_gzip);
    assert_eq!(gzip.graph.edges.len(), 1);
    assert_eq!(gzip.graph.edges[0].outcome, EdgeOutcome::Malformed);
    assert!(
        gzip.graph
            .issues
            .iter()
            .any(|issue| issue.code == "gzip_decode_failed")
    );
    assert!(matches!(gzip.graph.coverage, Coverage::Partial { .. }));
}

#[test]
fn mime_part_metadata_is_preserved_as_evidence_but_cannot_override_bytes() {
    let bundle = inspect(
        "message.eml",
        Some("message/rfc822"),
        email_with_misleading_png_attachment(),
    );
    let attachment = bundle
        .graph
        .objects
        .iter()
        .find(|object| object.first_depth == 1)
        .expect("MIME attachment should be derived");

    assert_eq!(attachment.detection.selected, Some(DetectedFormat::Png));
    assert_eq!(
        attachment.detection.declared_media_type.as_deref(),
        Some("image/png")
    );
    assert!(attachment.detection.candidates.iter().any(|candidate| {
        candidate.format == DetectedFormat::Png
            && candidate.confidence == DetectionConfidence::StrongSignature
            && candidate.evidence == DetectionEvidence::MagicBytes
    }));
    assert!(attachment.detection.candidates.iter().any(|candidate| {
        candidate.format == DetectedFormat::Png
            && candidate.confidence == DetectionConfidence::HintOnly
            && candidate.evidence == DetectionEvidence::DeclaredMediaType
    }));
    assert!(attachment.detection.candidates.iter().any(|candidate| {
        candidate.format == DetectedFormat::PlainText
            && candidate.confidence == DetectionConfidence::HintOnly
            && candidate.evidence == DetectionEvidence::FileExtension
    }));
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "archive_member_type_mismatch")
    );
}

#[test]
fn ambiguous_zip_family_is_resolved_only_after_member_structure_is_parsed() {
    let zip = zip_bytes(&[
        ("[Content_Types].xml", b"<Types/>"),
        ("word/document.xml", b"<document/>"),
    ]);
    let bundle = inspect("document.zip", Some("application/zip"), zip);
    let detection = &bundle.graph.objects[0].detection;

    assert_eq!(detection.selected, Some(DetectedFormat::Docx));
    assert!(detection.candidates.iter().any(|candidate| {
        candidate.format == DetectedFormat::Docx
            && candidate.confidence == DetectionConfidence::ParserConfirmed
            && candidate.evidence == DetectionEvidence::ContainerMembers
    }));
    assert!(detection.candidates.iter().any(|candidate| {
        candidate.format == DetectedFormat::Zip
            && candidate.confidence == DetectionConfidence::StrongSignature
            && candidate.evidence == DetectionEvidence::MagicBytes
    }));
}

#[test]
fn forged_zip_count_is_rejected_before_central_directory_materialization() {
    let mut bytes = vec![0_u8; 22];
    bytes[..4].copy_from_slice(b"PK\x05\x06");
    bytes[8..10].copy_from_slice(&500_u16.to_le_bytes());
    bytes[10..12].copy_from_slice(&500_u16.to_le_bytes());
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_entries: 8,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("forged.zip", None, bytes))
        .expect("preflight returns a typed partial graph");
    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "archive_entry_limit_exceeded")
    );
}

#[test]
fn zip_directory_metadata_has_an_independent_preallocation_limit() {
    let bytes = zip_bytes(&[("long-name.txt", b"content")]);
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_container_metadata_bytes: 1,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("metadata.zip", None, bytes))
        .expect("metadata gate returns a typed partial graph");
    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "container_metadata_limit_exceeded")
    );
}

#[test]
fn xz_dictionary_is_bounded_before_the_decoder_is_constructed() {
    let mut bytes = hex::decode("fd377a585a000004e6d6b44604c01511210116000000000000000000b218dc5f01001068656c6c6f206174746163686d656e740a00000000751290264077006f000131116b926b8c1fb6f37d010000000004595a")
        .expect("fixture hex");
    let property = bytes
        .windows(3)
        .position(|window| window == [0x21, 0x01, 0x16])
        .expect("fixture LZMA2 property")
        + 2;
    bytes[property] = 40;
    let header_start = 12;
    let header_bytes = (usize::from(bytes[header_start]) + 1) * 4;
    let crc_start = header_start + header_bytes - 4;
    let crc = test_crc32(&bytes[header_start..crc_start]).to_le_bytes();
    bytes[crc_start..crc_start + 4].copy_from_slice(&crc);
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_decoder_window_bytes: 64 * 1024 * 1024,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "huge-dictionary.xz",
            None,
            bytes,
        ))
        .expect("dictionary limit returns a typed partial graph");

    assert_eq!(bundle.graph.usage.entries, 0);
    assert!(matches!(
        &bundle.graph.objects[0].status,
        ObjectStatus::Partial { reasons }
            if reasons.iter().any(|reason| reason == "xz_dictionary_limit_exceeded")
    ));
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "xz_dictionary_limit_exceeded")
    );
}

#[test]
fn xz_internal_blocks_do_not_double_charge_the_graph_entry_budget() {
    let bytes = hex::decode("fd377a585a000004e6d6b44604c01511210116000000000000000000b218dc5f01001068656c6c6f206174746163686d656e740a00000000751290264077006f000131116b926b8c1fb6f37d010000000004595a")
        .expect("fixture hex");
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_entries: 1,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes("one-entry.xz", None, bytes))
        .expect("one XZ payload consumes one graph entry");

    assert_eq!(bundle.graph.usage.entries, 1);
    assert_eq!(bundle.graph.objects.len(), 2);
    assert_eq!(bundle.graph.edges.len(), 1);
}

fn test_crc32(bytes: &[u8]) -> u32 {
    let mut value = u32::MAX;
    for byte in bytes {
        value ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(value & 1);
            value = (value >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !value
}

#[test]
fn zstd_window_is_bounded_independently_of_decoded_output() {
    // Valid Zstandard magic followed by a non-single-segment frame header and
    // a valid 1 MiB window descriptor. Decoder initialization must reject the
    // requested window before it allocates or reads a block.
    let bytes = vec![0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x50];
    let policy = InspectionPolicy {
        limits: BudgetLimits {
            max_decoder_window_bytes: 64 * 1024,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    };
    let bundle = Inspector::new(policy)
        .expect("fixture policy")
        .inspect(ProvidedAttachment::from_bytes(
            "huge-window.zst",
            None,
            bytes,
        ))
        .expect("window limit returns a typed partial graph");

    assert!(
        matches!(
            &bundle.graph.objects[0].status,
            ObjectStatus::Partial { reasons }
                if reasons.iter().any(|reason| reason == "zstd_window_limit_exceeded")
        ),
        "unexpected Zstandard status/issues: {:#?}",
        bundle.graph
    );
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "zstd_window_limit_exceeded")
    );
}
