use attachment_native_inspect::{Inspector, ProvidedAttachment};
use attachment_native_types::{Coverage, IssueClass};
use std::io::{Cursor, Write};
use zip::write::SimpleFileOptions;

fn archive() -> Vec<u8> {
    let mut output = Cursor::new(Vec::new());
    let mut writer = zip::ZipWriter::new(&mut output);
    for name in ["first.txt", "second.txt"] {
        writer
            .start_file(name, SimpleFileOptions::default())
            .expect("fixture member starts");
        writer
            .write_all(name.as_bytes())
            .expect("fixture member bytes");
    }
    writer.finish().expect("fixture ZIP finishes");
    output.into_inner()
}

#[test]
fn understated_directory_count_must_not_report_complete_coverage() {
    let mut bytes = archive();
    let end = bytes.len() - 22;
    assert_eq!(&bytes[end..end + 4], b"PK\x05\x06");
    bytes[end + 8..end + 10].copy_from_slice(&1_u16.to_le_bytes());
    bytes[end + 10..end + 12].copy_from_slice(&1_u16.to_le_bytes());
    let parser = zip::ZipArchive::new(Cursor::new(&bytes))
        .expect("locked parser accepts understated fixture");
    assert_eq!(
        parser.len(),
        1,
        "The locked parser honors the understated count"
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "understated.zip",
            None,
            bytes,
        ))
        .expect("malformed input produces a retained graph");
    println!(
        "coverage={:?} objects={} entries={} issues={:?}",
        bundle.graph.coverage,
        bundle.graph.objects.len(),
        bundle.graph.usage.entries,
        bundle.graph.issues
    );
    assert!(
        matches!(bundle.graph.coverage, Coverage::Partial { .. }),
        "A directory with omitted entries cannot claim complete coverage"
    );
}

#[test]
fn ordinary_directory_keeps_both_captured_members() {
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "ordinary.zip",
            None,
            archive(),
        ))
        .expect("ordinary input produces a retained graph");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);
    assert_eq!(bundle.graph.objects.len(), 3);
}

#[test]
fn understated_directory_size_cannot_borrow_the_unbounded_parser_domain() {
    let mut bytes = archive();
    let end = bytes.len() - 22;
    bytes[end + 12..end + 16].copy_from_slice(&0_u32.to_le_bytes());
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("locked parser ignores directory size")
            .len(),
        2
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes("size.zip", None, bytes))
        .expect("inspection retains malformed input");
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    assert_eq!(bundle.graph.objects.len(), 1);
    assert_eq!(bundle.graph.usage.entries, 0);
}

#[test]
fn a_later_end_record_inside_the_archive_comment_cannot_change_members() {
    let mut bytes = archive();
    let end = bytes.len() - 22;
    let mut comment = vec![0_u8; 22];
    comment[..4].copy_from_slice(b"PK\x05\x06");
    comment.extend_from_slice(b"Public comment tail <3 forever");
    bytes[end + 20..end + 22].copy_from_slice(&(comment.len() as u16).to_le_bytes());
    bytes.extend_from_slice(&comment);
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("locked parser accepts the comment footer")
            .len(),
        0
    );
    let original = bytes.clone();
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes("comment.zip", None, bytes))
        .expect("inspection retains ordinary members");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);
    assert!(
        bundle
            .blobs
            .values()
            .any(|bytes| bytes.as_ref() == original)
    );
}

#[test]
fn two_exact_end_footers_report_ambiguity_without_discarding_original_bytes() {
    let mut bytes = archive();
    let end = bytes.len() - 22;
    let tail = b"Public ambiguous comment tail";
    let mut comment = vec![0_u8; 22];
    comment[..4].copy_from_slice(b"PK\x05\x06");
    comment[20..22].copy_from_slice(&(tail.len() as u16).to_le_bytes());
    comment.extend_from_slice(tail);
    bytes[end + 20..end + 22].copy_from_slice(&(comment.len() as u16).to_le_bytes());
    bytes.extend_from_slice(&comment);
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("stock parser chooses the embedded exact-end footer")
            .len(),
        0
    );
    let original = bytes.clone();
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes("ambiguous.zip", None, bytes))
        .expect("ambiguous input produces a retained graph");
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    assert!(bundle.graph.issues.iter().any(|issue| {
        issue.code == "zip_end_record_ambiguous" && issue.class == IssueClass::Integrity
    }));
    assert_eq!(bundle.graph.usage.entries, 0);
    assert_eq!(bundle.graph.objects.len(), 1);
    assert!(
        bundle
            .blobs
            .values()
            .any(|bytes| bytes.as_ref() == original)
    );
}

#[test]
fn a_backward_search_window_at_header_plus_four_is_not_a_directory_pass() {
    let mut output = Cursor::new(Vec::new());
    let mut writer = zip::ZipWriter::new(&mut output);
    // 46 fixed bytes + 960 name bytes = 1006 directory bytes. With a 22-byte
    // footer, zip's initial 1024-byte window begins four bytes into this header.
    let name = "n".repeat(960);
    writer
        .start_file(&name, SimpleFileOptions::default())
        .expect("long-name fixture starts");
    writer
        .write_all(b"public bytes")
        .expect("long-name fixture writes");
    writer.finish().expect("long-name fixture finishes");
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "long-name.zip",
            None,
            output.into_inner(),
        ))
        .expect("inspection retains long-name input");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 1);
}

fn zip64(mut bytes: Vec<u8>, extension: &[u8]) -> Vec<u8> {
    let end = bytes.len() - 22;
    let count = u16::from_le_bytes([bytes[end + 10], bytes[end + 11]]);
    let size = u32::from_le_bytes(
        bytes[end + 12..end + 16]
            .try_into()
            .expect("fixed size field"),
    );
    let offset = u32::from_le_bytes(
        bytes[end + 16..end + 20]
            .try_into()
            .expect("fixed offset field"),
    );
    let mut record = Vec::new();
    record.extend_from_slice(b"PK\x06\x06");
    record.extend_from_slice(&(44 + extension.len() as u64).to_le_bytes());
    record.extend_from_slice(&45_u16.to_le_bytes());
    record.extend_from_slice(&45_u16.to_le_bytes());
    record.extend_from_slice(&0_u32.to_le_bytes());
    record.extend_from_slice(&0_u32.to_le_bytes());
    record.extend_from_slice(&u64::from(count).to_le_bytes());
    record.extend_from_slice(&u64::from(count).to_le_bytes());
    record.extend_from_slice(&u64::from(size).to_le_bytes());
    record.extend_from_slice(&u64::from(offset).to_le_bytes());
    record.extend_from_slice(extension);
    record.extend_from_slice(b"PK\x06\x07");
    record.extend_from_slice(&0_u32.to_le_bytes());
    record.extend_from_slice(&(end as u64).to_le_bytes());
    record.extend_from_slice(&1_u32.to_le_bytes());
    bytes[end + 8..end + 12].fill(0xff);
    bytes[end + 12..end + 20].fill(0xff);
    bytes.splice(end..end, record);
    bytes
}

#[test]
fn zip64_members_and_extensible_metadata_have_separate_bounded_admission() {
    let bytes = zip64(archive(), &[0_u8; 256]);
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("ZIP64 fixture parses")
            .len(),
        2
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "ordinary64.zip",
            None,
            bytes.clone(),
        ))
        .expect("inspection retains ZIP64 members");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);
    let policy = attachment_native_types::InspectionPolicy {
        limits: attachment_native_types::BudgetLimits {
            max_container_metadata_bytes: 200,
            ..attachment_native_types::BudgetLimits::default()
        },
        ..attachment_native_types::InspectionPolicy::default()
    };
    let limited = Inspector::new(policy)
        .expect("metadata-bound policy")
        .inspect(ProvidedAttachment::from_bytes("bounded64.zip", None, bytes))
        .expect("bounded inspection returns a graph");
    assert!(
        limited
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "container_metadata_limit_exceeded")
    );
    assert_eq!(limited.graph.usage.entries, 0);
    assert_eq!(limited.graph.objects.len(), 1);
}

#[test]
fn malformed_admitted_header_cannot_fall_back_to_an_earlier_empty_footer() {
    let mut output = Cursor::new(Vec::new());
    let mut writer = zip::ZipWriter::new(&mut output);
    writer
        .start_file(
            "embedded.bin",
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
        )
        .expect("fallback fixture starts");
    let mut embedded = [0_u8; 22];
    embedded[..4].copy_from_slice(b"PK\x05\x06");
    writer.write_all(&embedded).expect("embedded footer writes");
    writer.finish().expect("fallback fixture finishes");
    let mut bytes = output.into_inner();
    let end = bytes.len() - 22;
    let directory = u32::from_le_bytes(
        bytes[end + 16..end + 20]
            .try_into()
            .expect("directory offset"),
    ) as usize;
    // AES method with no AES extra field is valid framing but a semantic
    // metadata failure. The locked parser retries the earlier payload footer.
    bytes[directory + 10..directory + 12].copy_from_slice(&99_u16.to_le_bytes());
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("stock fallback reaches embedded footer")
            .len(),
        0
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes("fallback.zip", None, bytes))
        .expect("inspection retains a malformed directory");
    assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "zip_structure_invalid")
    );
    assert_eq!(bundle.graph.usage.entries, 0);
    assert_eq!(bundle.graph.objects.len(), 1);
}

#[test]
fn genuine_empty_directory_remains_complete() {
    let mut output = Cursor::new(Vec::new());
    zip::ZipWriter::new(&mut output)
        .finish()
        .expect("empty ZIP finishes");
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "empty.zip",
            None,
            output.into_inner(),
        ))
        .expect("empty ZIP inspection");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 0);
}

#[test]
fn a_zip64_record_inside_extensible_data_cannot_replace_the_valid_locator_target() {
    let ordinary = archive();
    let original_record = ordinary.len() - 22;
    let mut extension = vec![0_u8; 56];
    extension[..4].copy_from_slice(b"PK\x06\x06");
    extension[4..12].copy_from_slice(&44_u64.to_le_bytes());
    extension[12..14].copy_from_slice(&45_u16.to_le_bytes());
    extension[14..16].copy_from_slice(&45_u16.to_le_bytes());
    // The nested empty record ends at the same locator and can fabricate a
    // prefix of 56 bytes. The declared locator already identifies the valid outer record.
    extension[48..56].copy_from_slice(&(original_record as u64).to_le_bytes());
    let bytes = zip64(ordinary, &extension);
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&bytes))
            .expect("stock parser keeps the literal locator target")
            .len(),
        2
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "extension64.zip",
            None,
            bytes,
        ))
        .expect("inspection retains ZIP64 members");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);

    // Inspector recognizes the ZIP family from its opening signature. This
    // public prefix exercises archive-relative offsets inside that family.
    let mut prefixed = b"PK\x03\x04 Public ZIP64 archive prefix".to_vec();
    prefixed.extend_from_slice(&zip64(archive(), &extension));
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "prefixed-extension64.zip",
            None,
            prefixed,
        ))
        .expect("inspection retains prefixed ZIP64 members");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);
}

#[test]
fn an_ineligible_prefix_record_does_not_replace_the_real_zip64_directory() {
    let ordinary = zip64(archive(), &[]);
    let locator = ordinary.len() - 22 - 20;
    let relative = u64::from_le_bytes(
        ordinary[locator + 8..locator + 16]
            .try_into()
            .expect("locator offset"),
    ) as usize;
    let mut prefix = vec![0_u8; 1024];
    prefix[..4].copy_from_slice(b"PK\x03\x04");
    let physical_locator = prefix.len() + locator;
    prefix[relative..relative + 4].copy_from_slice(b"PK\x06\x06");
    prefix[relative + 4..relative + 12]
        .copy_from_slice(&((physical_locator - relative - 12) as u64).to_le_bytes());
    prefix[relative + 12..relative + 14].copy_from_slice(&45_u16.to_le_bytes());
    prefix[relative + 14..relative + 16].copy_from_slice(&45_u16.to_le_bytes());
    // Its framing ends at the real locator, but this fixed fake record has
    // a different directory disk. The maintained reader continues forward.
    prefix[relative + 20..relative + 24].copy_from_slice(&1_u32.to_le_bytes());
    prefix.extend_from_slice(&ordinary);
    assert_eq!(
        zip::ZipArchive::new(Cursor::new(&prefix))
            .expect("stock parser skips the ineligible prefix record")
            .len(),
        2
    );
    let bundle = Inspector::default()
        .inspect(ProvidedAttachment::from_bytes("prefix64.zip", None, prefix))
        .expect("inspection retains the actual ZIP64 directory");
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.usage.entries, 2);
}
