use attachment_native_inspect::{Inspector, ProvidedAttachment};

// Actual valid stream preimage from xz_preflight.rs, not a substitute decoder.
const SMALL_XZ_HEX: &str = "fd377a585a000004e6d6b44604c01511210116000000000000000000b218dc5f01001068656c6c6f206174746163686d656e740a00000000751290264077006f000131116b926b8c1fb6f37d010000000004595a";

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

fn stream_with_properties_size(size: u8) -> Vec<u8> {
    let mut bytes = hex::decode(SMALL_XZ_HEX).expect("existing valid fixture");
    // One non-LZMA2 filter keeps unsupported-filter rejection reachable after
    // property parsing. The header remains 20 bytes with 16 data bytes.
    bytes[16] = 0x22;
    bytes[17] = size;
    let crc = crc32(&bytes[12..28]).to_le_bytes();
    bytes[28..32].copy_from_slice(&crc);
    bytes
}

fn inspect(bytes: Vec<u8>) -> attachment_native_types::AttachmentBundle {
    Inspector::default()
        .inspect(ProvidedAttachment::from_bytes(
            "synthetic.txt.xz",
            Some("application/x-xz".into()),
            bytes,
        ))
        .expect("malformed stream returns an explicit graph")
}

#[test]
fn filter_properties_cannot_consume_header_crc_bytes() {
    for size in [11, 14, 15] {
        let bundle = inspect(stream_with_properties_size(size));
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "xz_filter_properties_truncated" })
        );
        assert!(bundle.graph.edges.is_empty());
        assert_eq!(bundle.graph.objects.len(), 1);
        assert_eq!(bundle.graph.usage.total_derived_bytes, 0);
        assert!(matches!(
            bundle.graph.coverage,
            attachment_native_types::Coverage::Partial { .. }
        ));
    }
}

#[test]
fn properties_ending_at_data_boundary_reach_unsupported_filter_outcome() {
    let bundle = inspect(stream_with_properties_size(10));
    assert!(
        bundle
            .graph
            .issues
            .iter()
            .any(|issue| issue.code == "xz_filter_unsupported")
    );
}

#[test]
fn original_valid_stream_still_decodes() {
    let bundle = inspect(hex::decode(SMALL_XZ_HEX).expect("existing valid fixture"));
    assert_eq!(bundle.graph.edges.len(), 1);
    assert_eq!(bundle.graph.objects.len(), 2);
    assert!(
        bundle
            .blobs
            .values()
            .any(|bytes| bytes.as_ref() == b"hello attachment\n")
    );
}
