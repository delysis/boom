//! Allocation-free XZ metadata preflight.
//!
//! `lzma-rust2::XzReader` validates the stream but does not expose a caller
//! memory limit. An XZ block header controls the LZMA2 dictionary allocation,
//! so every real block is found by scanning the LZMA2 chunk framing before the
//! decoder is constructed. The footer/index is validated and cross-checked,
//! but never trusted to locate blocks: an attacker can rewrite those records.
//! Only a single XZ stream is accepted by the in-process lane; concatenated
//! streams remain an explicit unsupported outcome.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum XzPreflightClass {
    Malformed,
    Unsupported,
    Limit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct XzPreflightError {
    pub(crate) code: &'static str,
    pub(crate) class: XzPreflightClass,
    pub(crate) message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct XzSummary {
    pub(crate) blocks: u64,
    pub(crate) largest_dictionary_bytes: u64,
    pub(crate) index_bytes: u64,
}

const STREAM_HEADER_BYTES: usize = 12;
const STREAM_FOOTER_BYTES: usize = 12;
const LZMA2_FILTER_ID: u64 = 0x21;
const XZ_MAGIC: &[u8; 6] = b"\xFD7zXZ\0";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct BlockHeader {
    bytes: usize,
    dictionary_bytes: u64,
    declared_compressed_bytes: Option<u64>,
    declared_uncompressed_bytes: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct BlockSummary {
    next: usize,
    unpadded_bytes: u64,
    uncompressed_bytes: u64,
}

pub(crate) fn preflight_xz(
    bytes: &[u8],
    max_blocks: u64,
    max_index_bytes: u64,
    max_dictionary_bytes: u64,
) -> Result<XzSummary, XzPreflightError> {
    if bytes.len() < STREAM_HEADER_BYTES + STREAM_FOOTER_BYTES {
        return Err(malformed("xz_truncated", "The XZ stream is truncated."));
    }
    let check_bytes = validate_stream_header(bytes)?;
    let footer_start = bytes.len() - STREAM_FOOTER_BYTES;
    let footer = &bytes[footer_start..];
    if footer.get(10..12) != Some(b"YZ".as_slice()) {
        return Err(unsupported(
            "xz_multiple_streams_unsupported",
            "Concatenated XZ streams are not decoded in process.",
        ));
    }
    validate_crc32(
        &footer[4..10],
        &footer[..4],
        "xz_footer_crc_invalid",
        "The XZ stream footer CRC is invalid.",
    )?;
    if bytes.get(6..8) != footer.get(8..10) {
        return Err(malformed(
            "xz_stream_flags_mismatch",
            "The XZ stream header and footer flags disagree.",
        ));
    }

    let backward_size = u32::from_le_bytes([footer[4], footer[5], footer[6], footer[7]]);
    let index_size = u64::from(backward_size)
        .checked_add(1)
        .and_then(|value| value.checked_mul(4))
        .ok_or_else(|| malformed("xz_index_size_overflow", "The XZ index size overflows."))?;
    if index_size > max_index_bytes {
        return Err(limit(
            "xz_index_limit_exceeded",
            index_size,
            max_index_bytes,
            "XZ index bytes",
        ));
    }
    let index_size_usize = usize::try_from(index_size)
        .map_err(|_| malformed("xz_index_size_overflow", "The XZ index is too large."))?;
    let index_start = footer_start.checked_sub(index_size_usize).ok_or_else(|| {
        malformed(
            "xz_index_out_of_bounds",
            "The XZ footer points outside the attachment.",
        )
    })?;
    if index_start < STREAM_HEADER_BYTES || index_size_usize < 8 {
        return Err(malformed(
            "xz_index_out_of_bounds",
            "The XZ index overlaps the stream header.",
        ));
    }

    let index_crc_start = footer_start - 4;
    validate_crc32(
        &bytes[index_start..index_crc_start],
        &bytes[index_crc_start..footer_start],
        "xz_index_crc_invalid",
        "The XZ index CRC is invalid.",
    )?;

    // First walk the actual block stream without consulting the index. XZ
    // always terminates a filter chain in LZMA2, whose chunk framing gives us
    // exact compressed and uncompressed lengths without dictionary allocation.
    // This pass is the security boundary: every dictionary that XzReader could
    // instantiate is inspected here, including blocks omitted by a forged
    // index.
    let mut actual_start = STREAM_HEADER_BYTES;
    let mut actual_blocks = 0u64;
    let mut largest_dictionary_bytes = 0u64;
    while actual_start < index_start {
        if bytes.get(actual_start) == Some(&0) {
            return Err(layout_mismatch(bytes, actual_start, index_start));
        }
        actual_blocks = actual_blocks
            .checked_add(1)
            .ok_or_else(|| malformed("xz_block_count_overflow", "The XZ block count overflows."))?;
        if actual_blocks > max_blocks {
            return Err(limit(
                "xz_block_limit_exceeded",
                actual_blocks,
                max_blocks,
                "XZ blocks",
            ));
        }
        let (block, dictionary_bytes) =
            inspect_actual_block(bytes, actual_start, index_start, check_bytes)?;
        if dictionary_bytes > max_dictionary_bytes {
            return Err(limit(
                "xz_dictionary_limit_exceeded",
                dictionary_bytes,
                max_dictionary_bytes,
                "XZ dictionary bytes",
            ));
        }
        largest_dictionary_bytes = largest_dictionary_bytes.max(dictionary_bytes);
        actual_start = block.next;
    }
    if actual_start != index_start {
        return Err(layout_mismatch(bytes, actual_start, index_start));
    }

    // Now parse the independently CRC-protected index and compare every record
    // against a second actual-stream walk. No attacker-controlled index size is
    // ever used to advance between real block headers.
    let mut cursor = index_start;
    if bytes.get(cursor) != Some(&0) {
        return Err(malformed(
            "xz_index_marker_invalid",
            "The XZ index marker is invalid.",
        ));
    }
    cursor += 1;
    let record_count = parse_vli(bytes, &mut cursor, index_crc_start)?;
    if record_count > max_blocks {
        return Err(limit(
            "xz_block_limit_exceeded",
            record_count,
            max_blocks,
            "XZ blocks",
        ));
    }
    if record_count != actual_blocks {
        return Err(malformed(
            "xz_index_record_count_mismatch",
            format!(
                "The XZ index declares {record_count} blocks, but the stream contains {actual_blocks}."
            ),
        ));
    }

    let mut block_start = STREAM_HEADER_BYTES;
    for _ in 0..record_count {
        let unpadded_size = parse_vli(bytes, &mut cursor, index_crc_start)?;
        let uncompressed_size = parse_vli(bytes, &mut cursor, index_crc_start)?;
        if unpadded_size == 0 {
            return Err(malformed(
                "xz_block_size_invalid",
                "An XZ index record declares an empty block.",
            ));
        }
        let (actual, _) = inspect_actual_block(bytes, block_start, index_start, check_bytes)?;
        if unpadded_size != actual.unpadded_bytes || uncompressed_size != actual.uncompressed_bytes
        {
            return Err(malformed(
                "xz_index_record_mismatch",
                "An XZ index record disagrees with the corresponding real block.",
            ));
        }
        block_start = actual.next;
    }

    if block_start != index_start {
        return Err(layout_mismatch(bytes, block_start, index_start));
    }
    if bytes[cursor..index_crc_start].iter().any(|byte| *byte != 0) {
        return Err(malformed(
            "xz_index_padding_invalid",
            "The XZ index contains non-zero padding.",
        ));
    }

    Ok(XzSummary {
        blocks: record_count,
        largest_dictionary_bytes,
        index_bytes: index_size,
    })
}

fn inspect_block_header(
    bytes: &[u8],
    block_start: usize,
    block_limit: usize,
) -> Result<BlockHeader, XzPreflightError> {
    let size_byte = *bytes.get(block_start).ok_or_else(|| {
        malformed(
            "xz_block_header_truncated",
            "An XZ block header is truncated.",
        )
    })?;
    if size_byte == 0 {
        return Err(malformed(
            "xz_block_header_invalid",
            "An XZ block header has an invalid size byte.",
        ));
    }
    let header_size = usize::from(size_byte)
        .checked_add(1)
        .and_then(|value| value.checked_mul(4))
        .ok_or_else(|| {
            malformed(
                "xz_block_header_size_overflow",
                "An XZ block header size overflows.",
            )
        })?;
    let header_end = block_start.checked_add(header_size).ok_or_else(|| {
        malformed(
            "xz_block_header_size_overflow",
            "An XZ block header size overflows.",
        )
    })?;
    if header_end > block_limit {
        return Err(malformed(
            "xz_block_header_out_of_bounds",
            "An XZ block header overlaps the index.",
        ));
    }
    let header = bytes.get(block_start..header_end).ok_or_else(|| {
        malformed(
            "xz_block_header_truncated",
            "An XZ block header is truncated.",
        )
    })?;
    let data_end = header_size - 4;
    validate_crc32(
        &header[..data_end],
        &header[data_end..],
        "xz_block_header_crc_invalid",
        "An XZ block header CRC is invalid.",
    )?;
    let flags = header[1];
    if flags & 0x3c != 0 {
        return Err(malformed(
            "xz_block_flags_invalid",
            "An XZ block sets reserved flag bits.",
        ));
    }
    let filter_count = usize::from(flags & 0x03) + 1;
    let mut cursor = 2usize;
    let declared_compressed_bytes = (flags & 0x40 != 0)
        .then(|| parse_vli(header, &mut cursor, data_end))
        .transpose()?;
    let declared_uncompressed_bytes = (flags & 0x80 != 0)
        .then(|| parse_vli(header, &mut cursor, data_end))
        .transpose()?;

    let mut dictionary_bytes = None;
    for filter_index in 0..filter_count {
        let filter_id = parse_vli(header, &mut cursor, data_end)?;
        let properties_size = parse_vli(header, &mut cursor, data_end)?;
        let properties_size = usize::try_from(properties_size).map_err(|_| {
            malformed(
                "xz_filter_properties_overflow",
                "XZ filter properties are too large.",
            )
        })?;
        let properties_end = cursor.checked_add(properties_size).ok_or_else(|| {
            malformed(
                "xz_filter_properties_overflow",
                "XZ filter properties overflow the block header.",
            )
        })?;
        let properties = header.get(cursor..properties_end).ok_or_else(|| {
            malformed(
                "xz_filter_properties_truncated",
                "XZ filter properties are truncated.",
            )
        })?;
        cursor = properties_end;
        if filter_id == LZMA2_FILTER_ID {
            if filter_index + 1 != filter_count || properties.len() != 1 {
                return Err(malformed(
                    "xz_lzma2_filter_invalid",
                    "The terminating XZ LZMA2 filter is malformed.",
                ));
            }
            dictionary_bytes = Some(decode_lzma2_dictionary(properties[0])?);
        }
    }
    if header[cursor..data_end].iter().any(|byte| *byte != 0) {
        return Err(malformed(
            "xz_block_padding_invalid",
            "An XZ block header contains non-zero padding.",
        ));
    }
    let dictionary_bytes = dictionary_bytes.ok_or_else(|| {
        unsupported(
            "xz_filter_unsupported",
            "The XZ block does not terminate in an LZMA2 filter.",
        )
    })?;
    Ok(BlockHeader {
        bytes: header_size,
        dictionary_bytes,
        declared_compressed_bytes,
        declared_uncompressed_bytes,
    })
}

fn inspect_actual_block(
    bytes: &[u8],
    block_start: usize,
    index_start: usize,
    check_bytes: usize,
) -> Result<(BlockSummary, u64), XzPreflightError> {
    let header = inspect_block_header(bytes, block_start, index_start)?;
    let compressed_start = block_start.checked_add(header.bytes).ok_or_else(|| {
        malformed(
            "xz_block_size_overflow",
            "An XZ block offset overflows its container.",
        )
    })?;
    let (compressed_end, uncompressed_bytes) =
        scan_lzma2_chunks(bytes, compressed_start, index_start)?;
    let compressed_bytes = u64::try_from(compressed_end - compressed_start).map_err(|_| {
        malformed(
            "xz_block_size_overflow",
            "An XZ compressed block is too large for this platform.",
        )
    })?;
    if header
        .declared_compressed_bytes
        .is_some_and(|declared| declared != compressed_bytes)
    {
        return Err(malformed(
            "xz_block_compressed_size_mismatch",
            "An XZ block header declares the wrong compressed size.",
        ));
    }
    if header
        .declared_uncompressed_bytes
        .is_some_and(|declared| declared != uncompressed_bytes)
    {
        return Err(malformed(
            "xz_block_uncompressed_size_mismatch",
            "An XZ block header declares the wrong uncompressed size.",
        ));
    }

    let unpadded_bytes = u64::try_from(header.bytes)
        .ok()
        .and_then(|value| value.checked_add(compressed_bytes))
        .and_then(|value| value.checked_add(u64::try_from(check_bytes).ok()?))
        .ok_or_else(|| {
            malformed(
                "xz_block_size_overflow",
                "An XZ block size overflows its container.",
            )
        })?;
    let padding_bytes = usize::try_from((4 - (unpadded_bytes & 3)) & 3).map_err(|_| {
        malformed(
            "xz_block_padding_overflow",
            "An XZ block padding width cannot be represented safely.",
        )
    })?;
    let check_start = compressed_end
        .checked_add(padding_bytes)
        .ok_or_else(|| malformed("xz_block_size_overflow", "XZ block padding overflows."))?;
    let next = check_start
        .checked_add(check_bytes)
        .ok_or_else(|| malformed("xz_block_size_overflow", "XZ block check overflows."))?;
    if next > index_start {
        return Err(malformed(
            "xz_block_out_of_bounds",
            "An XZ block overlaps its index.",
        ));
    }
    if bytes[compressed_end..check_start]
        .iter()
        .any(|byte| *byte != 0)
    {
        return Err(malformed(
            "xz_block_padding_invalid",
            "An XZ block contains non-zero padding.",
        ));
    }
    Ok((
        BlockSummary {
            next,
            unpadded_bytes,
            uncompressed_bytes,
        },
        header.dictionary_bytes,
    ))
}

fn scan_lzma2_chunks(
    bytes: &[u8],
    start: usize,
    end: usize,
) -> Result<(usize, u64), XzPreflightError> {
    let mut cursor = start;
    let mut uncompressed_bytes = 0u64;
    let mut dictionary_initialized = false;
    let mut properties_initialized = false;
    loop {
        let control = take_byte(bytes, &mut cursor, end, "XZ LZMA2 control byte")?;
        match control {
            0x00 => return Ok((cursor, uncompressed_bytes)),
            0x01 | 0x02 => {
                if control == 0x01 {
                    dictionary_initialized = true;
                } else if !dictionary_initialized {
                    return Err(malformed(
                        "xz_lzma2_state_invalid",
                        "An XZ LZMA2 stream uses an uninitialized dictionary.",
                    ));
                }
                let chunk_bytes = u64::from(take_u16_be(bytes, &mut cursor, end)?) + 1;
                skip_bytes(bytes, &mut cursor, end, chunk_bytes, "XZ LZMA2 raw chunk")?;
                uncompressed_bytes =
                    uncompressed_bytes.checked_add(chunk_bytes).ok_or_else(|| {
                        malformed(
                            "xz_uncompressed_size_overflow",
                            "The XZ uncompressed size overflows.",
                        )
                    })?;
            }
            0x80..=0xff => {
                if control >= 0xe0 {
                    dictionary_initialized = true;
                } else if !dictionary_initialized {
                    return Err(malformed(
                        "xz_lzma2_state_invalid",
                        "An XZ LZMA2 stream uses an uninitialized dictionary.",
                    ));
                }
                let size_high = u64::from(control & 0x1f) << 16;
                let chunk_uncompressed =
                    size_high | u64::from(take_u16_be(bytes, &mut cursor, end)?);
                let chunk_uncompressed = chunk_uncompressed + 1;
                let chunk_compressed = u64::from(take_u16_be(bytes, &mut cursor, end)?) + 1;
                if control >= 0xc0 {
                    let property = take_byte(bytes, &mut cursor, end, "XZ LZMA properties")?;
                    if property > 224 {
                        return Err(malformed(
                            "xz_lzma_property_invalid",
                            "An XZ LZMA chunk has invalid lc/lp/pb properties.",
                        ));
                    }
                    properties_initialized = true;
                } else if !properties_initialized {
                    return Err(malformed(
                        "xz_lzma2_state_invalid",
                        "An XZ LZMA2 stream uses uninitialized LZMA properties.",
                    ));
                }
                skip_bytes(
                    bytes,
                    &mut cursor,
                    end,
                    chunk_compressed,
                    "XZ LZMA2 compressed chunk",
                )?;
                uncompressed_bytes = uncompressed_bytes
                    .checked_add(chunk_uncompressed)
                    .ok_or_else(|| {
                        malformed(
                            "xz_uncompressed_size_overflow",
                            "The XZ uncompressed size overflows.",
                        )
                    })?;
            }
            _ => {
                return Err(malformed(
                    "xz_lzma2_control_invalid",
                    "An XZ LZMA2 stream contains an invalid control byte.",
                ));
            }
        }
    }
}

fn validate_stream_header(bytes: &[u8]) -> Result<usize, XzPreflightError> {
    if bytes.get(..XZ_MAGIC.len()) != Some(XZ_MAGIC.as_slice()) {
        return Err(malformed(
            "xz_magic_invalid",
            "The XZ stream header magic is invalid.",
        ));
    }
    let flags = bytes.get(6..8).ok_or_else(|| {
        malformed(
            "xz_stream_flags_truncated",
            "The XZ stream flags are truncated.",
        )
    })?;
    if flags[0] != 0 || flags[1] & 0xf0 != 0 {
        return Err(malformed(
            "xz_stream_flags_invalid",
            "The XZ stream header sets reserved flag bits.",
        ));
    }
    validate_crc32(
        flags,
        bytes.get(8..12).ok_or_else(|| {
            malformed(
                "xz_stream_header_truncated",
                "The XZ stream header is truncated.",
            )
        })?,
        "xz_stream_header_crc_invalid",
        "The XZ stream header CRC is invalid.",
    )?;
    match flags[1] & 0x0f {
        0 => Ok(0),
        1 => Ok(4),
        4 => Ok(8),
        10 => Ok(32),
        _ => Err(unsupported(
            "xz_check_unsupported",
            "The XZ stream uses a reserved or unsupported integrity check.",
        )),
    }
}

fn take_byte(
    bytes: &[u8],
    cursor: &mut usize,
    end: usize,
    label: &str,
) -> Result<u8, XzPreflightError> {
    if *cursor >= end {
        return Err(malformed(
            "xz_lzma2_truncated",
            format!("The {label} is truncated."),
        ));
    }
    let byte = bytes[*cursor];
    *cursor += 1;
    Ok(byte)
}

fn take_u16_be(bytes: &[u8], cursor: &mut usize, end: usize) -> Result<u16, XzPreflightError> {
    let high = take_byte(bytes, cursor, end, "XZ LZMA2 chunk size")?;
    let low = take_byte(bytes, cursor, end, "XZ LZMA2 chunk size")?;
    Ok(u16::from_be_bytes([high, low]))
}

fn skip_bytes(
    bytes: &[u8],
    cursor: &mut usize,
    end: usize,
    count: u64,
    label: &str,
) -> Result<(), XzPreflightError> {
    let count = usize::try_from(count).map_err(|_| {
        malformed(
            "xz_lzma2_size_overflow",
            format!("The {label} is too large for this platform."),
        )
    })?;
    let next = cursor.checked_add(count).ok_or_else(|| {
        malformed(
            "xz_lzma2_size_overflow",
            format!("The {label} size overflows."),
        )
    })?;
    if next > end || bytes.get(*cursor..next).is_none() {
        return Err(malformed(
            "xz_lzma2_truncated",
            format!("The {label} is truncated."),
        ));
    }
    *cursor = next;
    Ok(())
}

fn validate_crc32(
    data: &[u8],
    encoded: &[u8],
    code: &'static str,
    message: &'static str,
) -> Result<(), XzPreflightError> {
    let encoded: [u8; 4] = encoded.try_into().map_err(|_| malformed(code, message))?;
    if crc32(data) != u32::from_le_bytes(encoded) {
        return Err(malformed(code, message));
    }
    Ok(())
}

fn crc32(bytes: &[u8]) -> u32 {
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

fn layout_mismatch(bytes: &[u8], actual_start: usize, expected_index: usize) -> XzPreflightError {
    let remaining = bytes
        .get(actual_start.min(bytes.len())..expected_index.min(bytes.len()))
        .unwrap_or_default();
    if remaining
        .windows(XZ_MAGIC.len())
        .any(|window| window == XZ_MAGIC)
    {
        unsupported(
            "xz_multiple_streams_unsupported",
            "Only one XZ stream is decoded in process; concatenated streams are rejected.",
        )
    } else {
        malformed(
            "xz_block_layout_mismatch",
            "The real XZ block sequence does not end at its declared index.",
        )
    }
}

fn decode_lzma2_dictionary(property: u8) -> Result<u64, XzPreflightError> {
    if property > 40 {
        return Err(malformed(
            "xz_lzma2_property_invalid",
            "The XZ LZMA2 dictionary property is invalid.",
        ));
    }
    if property == 40 {
        return Ok(u64::from(u32::MAX));
    }
    let base = 2u64 | u64::from(property & 1);
    let shift = u32::from(property / 2) + 11;
    base.checked_shl(shift).ok_or_else(|| {
        malformed(
            "xz_lzma2_property_invalid",
            "The XZ LZMA2 dictionary size overflows.",
        )
    })
}

fn parse_vli(bytes: &[u8], cursor: &mut usize, end: usize) -> Result<u64, XzPreflightError> {
    let mut value = 0u64;
    for index in 0..9u32 {
        if *cursor >= end {
            return Err(malformed(
                "xz_vli_truncated",
                "An XZ variable-length integer is truncated.",
            ));
        }
        let byte = bytes[*cursor];
        *cursor += 1;
        if index == 8 && byte > 0x7f {
            return Err(malformed(
                "xz_vli_overflow",
                "An XZ variable-length integer overflows 63 bits.",
            ));
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            if index > 0 && byte == 0 {
                return Err(malformed(
                    "xz_vli_noncanonical",
                    "An XZ variable-length integer is not minimally encoded.",
                ));
            }
            return Ok(value);
        }
    }
    Err(malformed(
        "xz_vli_overflow",
        "An XZ variable-length integer exceeds nine bytes.",
    ))
}

fn malformed(code: &'static str, message: impl Into<String>) -> XzPreflightError {
    XzPreflightError {
        code,
        class: XzPreflightClass::Malformed,
        message: message.into(),
    }
}

fn unsupported(code: &'static str, message: impl Into<String>) -> XzPreflightError {
    XzPreflightError {
        code,
        class: XzPreflightClass::Unsupported,
        message: message.into(),
    }
}

fn limit(code: &'static str, requested: u64, max: u64, label: &str) -> XzPreflightError {
    XzPreflightError {
        code,
        class: XzPreflightClass::Limit,
        message: format!("{label} requested {requested} bytes/items; the limit is {max}."),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        STREAM_FOOTER_BYTES, STREAM_HEADER_BYTES, XzPreflightClass, crc32, inspect_actual_block,
        parse_vli, preflight_xz,
    };

    const SMALL_XZ_HEX: &str = "fd377a585a000004e6d6b44604c01511210116000000000000000000b218dc5f01001068656c6c6f206174746163686d656e740a00000000751290264077006f000131116b926b8c1fb6f37d010000000004595a";
    const TWO_BLOCK_XZ_HEX: &str = "fd377a585a000004e6d6b44603c02b800121011600000000b64396fde0007f00235d00309b0a67248f45be2417c3033ca880b76f6c076e6a15def1c215ac6da6c6c8ced2c8000000b63799b41fe7c93903c02561210116000000000066edaa09e00060001d5d00371d01a4ba224d953df15c91befcad2b84059d043e6b3aefc672b4400000000000676f1901d1a7cb9000024380013d6100504d7e22b1c467fb020000000004595a";

    fn small_xz() -> Vec<u8> {
        hex::decode(SMALL_XZ_HEX).expect("fixture hex is valid")
    }

    fn two_block_xz() -> Vec<u8> {
        hex::decode(TWO_BLOCK_XZ_HEX).expect("fixture hex is valid")
    }

    fn index_bounds(bytes: &[u8]) -> (usize, usize, usize) {
        let footer_start = bytes.len() - STREAM_FOOTER_BYTES;
        let footer = &bytes[footer_start..];
        let backward_size = u32::from_le_bytes([footer[4], footer[5], footer[6], footer[7]]);
        let index_bytes = usize::try_from((u64::from(backward_size) + 1) * 4)
            .expect("fixture index fits in memory");
        (footer_start - index_bytes, footer_start - 4, footer_start)
    }

    fn rewrite_block_header_crc(bytes: &mut [u8], block_start: usize) {
        let header_bytes = (usize::from(bytes[block_start]) + 1) * 4;
        let crc_start = block_start + header_bytes - 4;
        let crc = crc32(&bytes[block_start..crc_start]).to_le_bytes();
        bytes[crc_start..crc_start + 4].copy_from_slice(&crc);
    }

    fn rewrite_index_crc(bytes: &mut [u8]) {
        let (index_start, crc_start, footer_start) = index_bounds(bytes);
        let crc = crc32(&bytes[index_start..crc_start]).to_le_bytes();
        bytes[crc_start..footer_start].copy_from_slice(&crc);
    }

    #[test]
    fn accepts_single_stream_with_bounded_dictionary() {
        let summary = preflight_xz(&small_xz(), 8, 1024, 64 * 1024 * 1024)
            .expect("fixture must pass preflight");
        assert_eq!(summary.blocks, 1);
        assert!(summary.largest_dictionary_bytes <= 64 * 1024 * 1024);

        let summary = preflight_xz(&two_block_xz(), 8, 1024, 64 * 1024 * 1024)
            .expect("multi-block fixture must pass the actual-stream walk");
        assert_eq!(summary.blocks, 2);
    }

    #[test]
    fn rejects_dictionary_before_decoder_allocation() {
        let mut bytes = small_xz();
        let property = bytes
            .windows(3)
            .position(|window| window == [0x21, 0x01, 0x16])
            .expect("fixture LZMA2 property")
            + 2;
        bytes[property] = 40;
        rewrite_block_header_crc(&mut bytes, STREAM_HEADER_BYTES);
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("huge dictionary must fail before decode");
        assert_eq!(error.class, XzPreflightClass::Limit);
        assert_eq!(error.code, "xz_dictionary_limit_exceeded");
    }

    #[test]
    fn forged_index_underreport_cannot_hide_a_later_large_dictionary() {
        let mut bytes = two_block_xz();
        let (index_start, index_crc_start, _) = index_bounds(&bytes);
        let (first, _) = inspect_actual_block(&bytes, STREAM_HEADER_BYTES, index_start, 8)
            .expect("first fixture block is structurally valid");
        let second_start = first.next;
        let second_header_bytes = (usize::from(bytes[second_start]) + 1) * 4;
        let property = bytes[second_start..second_start + second_header_bytes]
            .windows(3)
            .position(|window| window == [0x21, 0x01, 0x16])
            .expect("second fixture LZMA2 property")
            + second_start
            + 2;
        bytes[property] = 40;
        rewrite_block_header_crc(&mut bytes, second_start);

        // Forge a validly CRC-signed index that reports only the first block.
        // The old implementation stopped after this one record and would never
        // inspect the second real block header.
        let mut cursor = index_start + 1;
        assert_eq!(
            parse_vli(&bytes, &mut cursor, index_crc_start).expect("fixture record count"),
            2
        );
        let _ = parse_vli(&bytes, &mut cursor, index_crc_start).expect("first unpadded size");
        let _ = parse_vli(&bytes, &mut cursor, index_crc_start).expect("first decoded size");
        bytes[index_start + 1] = 1;
        bytes[cursor..index_crc_start].fill(0);
        rewrite_index_crc(&mut bytes);

        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("the actual second dictionary must be inspected before decode");
        assert_eq!(error.class, XzPreflightClass::Limit);
        assert_eq!(error.code, "xz_dictionary_limit_exceeded");
    }

    #[test]
    fn validates_header_footer_index_and_block_header_crcs() {
        let mut bytes = small_xz();
        bytes[8] ^= 1;
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("corrupt header CRC must fail closed");
        assert_eq!(error.code, "xz_stream_header_crc_invalid");

        let mut bytes = small_xz();
        let block_header_bytes = (usize::from(bytes[STREAM_HEADER_BYTES]) + 1) * 4;
        let block_header_crc = STREAM_HEADER_BYTES + block_header_bytes - 4;
        bytes[block_header_crc] ^= 1;
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("corrupt block-header CRC must fail closed");
        assert_eq!(error.code, "xz_block_header_crc_invalid");

        let mut bytes = small_xz();
        let (_, index_crc_start, _) = index_bounds(&bytes);
        bytes[index_crc_start] ^= 1;
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("corrupt index CRC must fail closed");
        assert_eq!(error.code, "xz_index_crc_invalid");

        let mut bytes = small_xz();
        let footer_start = bytes.len() - STREAM_FOOTER_BYTES;
        bytes[footer_start] ^= 1;
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("corrupt footer CRC must fail closed");
        assert_eq!(error.code, "xz_footer_crc_invalid");
    }

    #[test]
    fn rejects_concatenated_streams_explicitly() {
        let mut bytes = small_xz();
        bytes.extend_from_slice(&small_xz());
        let error = preflight_xz(&bytes, 8, 1024, 64 * 1024 * 1024)
            .expect_err("concatenated streams are outside the in-process lane");
        assert_eq!(error.class, XzPreflightClass::Unsupported);
        assert_eq!(error.code, "xz_multiple_streams_unsupported");
    }

    #[test]
    fn rejects_truncated_and_noncanonical_metadata() {
        let error = preflight_xz(&small_xz()[..18], 8, 1024, 64 * 1024 * 1024)
            .expect_err("truncated input must fail");
        assert_eq!(error.class, XzPreflightClass::Malformed);
    }
}
