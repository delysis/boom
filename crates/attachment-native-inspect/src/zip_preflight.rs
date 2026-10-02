//! Allocation-free ZIP end-record preflight.
//!
//! `zip::ZipArchive` necessarily materializes the complete central directory
//! before callers can inspect `len()`. An attacker-controlled file count or
//! central-directory size therefore has to be rejected from the fixed-size
//! end records first. This parser does not establish archive integrity; the
//! maintained `zip` crate remains authoritative after these allocation gates.

const EOCD_SIGNATURE: &[u8; 4] = b"PK\x05\x06";
const ZIP64_EOCD_SIGNATURE: &[u8; 4] = b"PK\x06\x06";
const ZIP64_LOCATOR_SIGNATURE: &[u8; 4] = b"PK\x06\x07";
const EOCD_MIN_BYTES: usize = 22;
const MAX_ZIP_COMMENT_BYTES: usize = u16::MAX as usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ZipDirectorySummary {
    pub(crate) entries: u64,
    pub(crate) metadata_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ZipPreflightError {
    EndRecordMissing,
    EndRecordTruncated,
    MultiDiskUnsupported,
    Zip64LocatorMissing,
    Zip64RecordInvalid,
    DirectoryOutOfBounds,
}

pub(crate) fn preflight(bytes: &[u8]) -> Result<ZipDirectorySummary, ZipPreflightError> {
    let eocd = find_eocd(bytes).ok_or(ZipPreflightError::EndRecordMissing)?;
    let disk = read_u16_le(bytes, eocd + 4).ok_or(ZipPreflightError::EndRecordTruncated)?;
    let directory_disk =
        read_u16_le(bytes, eocd + 6).ok_or(ZipPreflightError::EndRecordTruncated)?;
    let entries_on_disk =
        read_u16_le(bytes, eocd + 8).ok_or(ZipPreflightError::EndRecordTruncated)?;
    let entries = read_u16_le(bytes, eocd + 10).ok_or(ZipPreflightError::EndRecordTruncated)?;
    let directory_bytes =
        read_u32_le(bytes, eocd + 12).ok_or(ZipPreflightError::EndRecordTruncated)?;
    let directory_offset =
        read_u32_le(bytes, eocd + 16).ok_or(ZipPreflightError::EndRecordTruncated)?;
    if disk != 0 || directory_disk != 0 || entries_on_disk != entries {
        return Err(ZipPreflightError::MultiDiskUnsupported);
    }

    let uses_zip64 =
        entries == u16::MAX || directory_bytes == u32::MAX || directory_offset == u32::MAX;
    let summary = if uses_zip64 {
        zip64_summary(bytes, eocd)?
    } else {
        ZipDirectorySummary {
            entries: u64::from(entries),
            metadata_bytes: u64::from(directory_bytes),
        }
    };
    let directory_bytes = usize::try_from(summary.metadata_bytes)
        .map_err(|_| ZipPreflightError::DirectoryOutOfBounds)?;
    if directory_bytes > eocd {
        return Err(ZipPreflightError::DirectoryOutOfBounds);
    }
    Ok(summary)
}

fn find_eocd(bytes: &[u8]) -> Option<usize> {
    if bytes.len() < EOCD_MIN_BYTES {
        return None;
    }
    let earliest = bytes
        .len()
        .saturating_sub(EOCD_MIN_BYTES.saturating_add(MAX_ZIP_COMMENT_BYTES));
    let latest = bytes.len().saturating_sub(EOCD_MIN_BYTES);
    (earliest..=latest).rev().find(|offset| {
        bytes.get(*offset..offset.saturating_add(4)) == Some(EOCD_SIGNATURE.as_slice())
            && read_u16_le(bytes, offset.saturating_add(20)).is_some_and(|comment_bytes| {
                offset
                    .checked_add(EOCD_MIN_BYTES)
                    .and_then(|end| end.checked_add(usize::from(comment_bytes)))
                    == Some(bytes.len())
            })
    })
}

fn zip64_summary(
    bytes: &[u8],
    eocd_offset: usize,
) -> Result<ZipDirectorySummary, ZipPreflightError> {
    let locator = eocd_offset
        .checked_sub(20)
        .ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    if bytes.get(locator..locator + 4) != Some(ZIP64_LOCATOR_SIGNATURE.as_slice()) {
        return Err(ZipPreflightError::Zip64LocatorMissing);
    }
    let eocd_disk =
        read_u32_le(bytes, locator + 4).ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    let zip64_offset = read_u64_le(bytes, locator + 8)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    let disks = read_u32_le(bytes, locator + 16).ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    if eocd_disk != 0 || disks != 1 {
        return Err(ZipPreflightError::MultiDiskUnsupported);
    }
    if bytes.get(zip64_offset..zip64_offset.saturating_add(4))
        != Some(ZIP64_EOCD_SIGNATURE.as_slice())
    {
        return Err(ZipPreflightError::Zip64RecordInvalid);
    }
    let record_payload =
        read_u64_le(bytes, zip64_offset + 4).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    if record_payload < 44 {
        return Err(ZipPreflightError::Zip64RecordInvalid);
    }
    let disk =
        read_u32_le(bytes, zip64_offset + 16).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    let directory_disk =
        read_u32_le(bytes, zip64_offset + 20).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    let entries_on_disk =
        read_u64_le(bytes, zip64_offset + 24).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    let entries =
        read_u64_le(bytes, zip64_offset + 32).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    let metadata_bytes =
        read_u64_le(bytes, zip64_offset + 40).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    let _directory_offset =
        read_u64_le(bytes, zip64_offset + 48).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    if disk != 0 || directory_disk != 0 || entries_on_disk != entries {
        return Err(ZipPreflightError::MultiDiskUnsupported);
    }
    Ok(ZipDirectorySummary {
        entries,
        metadata_bytes,
    })
}

fn read_u16_le(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(offset..offset.checked_add(2)?)?.try_into().ok()?,
    ))
}

fn read_u32_le(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?,
    ))
}

fn read_u64_le(bytes: &[u8], offset: usize) -> Option<u64> {
    Some(u64::from_le_bytes(
        bytes.get(offset..offset.checked_add(8)?)?.try_into().ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};
    use zip::write::SimpleFileOptions;

    #[test]
    fn ordinary_archive_summary_is_read_without_materializing_entries() {
        let mut output = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut output);
            writer
                .start_file("a.txt", SimpleFileOptions::default())
                .expect("fixture file");
            writer.write_all(b"a").expect("fixture bytes");
            writer
                .start_file("b.txt", SimpleFileOptions::default())
                .expect("fixture file");
            writer.write_all(b"b").expect("fixture bytes");
            writer.finish().expect("fixture archive");
        }
        let summary = preflight(&output.into_inner()).expect("valid ZIP preflight");
        assert_eq!(summary.entries, 2);
        assert!(summary.metadata_bytes > 0);
    }

    #[test]
    fn forged_entry_count_is_visible_before_the_zip_parser_runs() {
        let mut bytes = vec![0_u8; EOCD_MIN_BYTES];
        bytes[..4].copy_from_slice(EOCD_SIGNATURE);
        bytes[8..10].copy_from_slice(&u16::MAX.to_le_bytes());
        bytes[10..12].copy_from_slice(&u16::MAX.to_le_bytes());
        bytes[12..16].copy_from_slice(&u32::MAX.to_le_bytes());
        bytes[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(
            preflight(&bytes),
            Err(ZipPreflightError::Zip64LocatorMissing)
        );
    }

    #[test]
    fn end_record_comment_length_must_match_the_retained_bytes() {
        let mut bytes = vec![0_u8; EOCD_MIN_BYTES];
        bytes[..4].copy_from_slice(EOCD_SIGNATURE);
        bytes[20..22].copy_from_slice(&1_u16.to_le_bytes());
        assert_eq!(preflight(&bytes), Err(ZipPreflightError::EndRecordMissing));
    }
}
