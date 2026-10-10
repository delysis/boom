//! Allocation-free ZIP end-record preflight.
//!
//! `zip::ZipArchive` necessarily materializes the complete central directory
//! before callers can inspect `len()`. An attacker-controlled file count or
//! central-directory size therefore has to be rejected from the fixed-size
//! end records first. This parser does not establish archive integrity; the
//! maintained `zip` crate remains authoritative after these allocation gates.

use std::cell::Cell;
use std::io::{self, Cursor, Read, Seek, SeekFrom};

const EOCD_SIGNATURE: &[u8; 4] = b"PK\x05\x06";
const ZIP64_EOCD_SIGNATURE: &[u8; 4] = b"PK\x06\x06";
const ZIP64_LOCATOR_SIGNATURE: &[u8; 4] = b"PK\x06\x07";
const EOCD_MIN_BYTES: usize = 22;
const MAX_ZIP_COMMENT_BYTES: usize = u16::MAX as usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ZipDirectorySummary {
    pub(crate) entries: u64,
    pub(crate) metadata_bytes: u64,
    directory_end: usize,
    relative_directory_start: u64,
    eocd: usize,
    extensible_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ZipPreflightError {
    EndRecordMissing,
    EndRecordAmbiguous,
    EndRecordTruncated,
    MultiDiskUnsupported,
    Zip64LocatorMissing,
    Zip64RecordInvalid,
    DirectoryOutOfBounds,
    DirectoryEntryCountMismatch,
}

pub(crate) fn preflight(bytes: &[u8]) -> Result<ZipDirectorySummary, ZipPreflightError> {
    let eocd = find_eocd(bytes)?;
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
            directory_end: eocd,
            relative_directory_start: u64::from(directory_offset),
            eocd,
            extensible_bytes: 0,
        }
    };
    let directory_bytes = usize::try_from(summary.metadata_bytes)
        .map_err(|_| ZipPreflightError::DirectoryOutOfBounds)?;
    if directory_bytes > summary.directory_end {
        return Err(ZipPreflightError::DirectoryOutOfBounds);
    }
    Ok(summary)
}

fn find_eocd(bytes: &[u8]) -> Result<usize, ZipPreflightError> {
    if bytes.len() < EOCD_MIN_BYTES {
        return Err(ZipPreflightError::EndRecordMissing);
    }
    let earliest = bytes
        .len()
        .saturating_sub(EOCD_MIN_BYTES.saturating_add(MAX_ZIP_COMMENT_BYTES));
    let latest = bytes.len().saturating_sub(EOCD_MIN_BYTES);
    let mut candidates = (earliest..=latest).rev().filter(|offset| {
        bytes.get(*offset..offset.saturating_add(4)) == Some(EOCD_SIGNATURE.as_slice())
            && read_u16_le(bytes, offset.saturating_add(20)).is_some_and(|comment_bytes| {
                offset
                    .checked_add(EOCD_MIN_BYTES)
                    .and_then(|end| end.checked_add(usize::from(comment_bytes)))
                    == Some(bytes.len())
            })
    });
    let candidate = candidates
        .next()
        .ok_or(ZipPreflightError::EndRecordMissing)?;
    // Two exact-end footer framings can describe different archives. Their
    // intended identity cannot be inferred from signatures in comment bytes;
    // retain the original input and report partial coverage instead of picking
    // an interpretation that could omit members. Search remains bounded to
    // the format's 65535-byte comment window and allocates no candidate list.
    if candidates.next().is_some() {
        return Err(ZipPreflightError::EndRecordAmbiguous);
    }
    Ok(candidate)
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
    let relative_record_offset =
        read_u64_le(bytes, locator + 8).ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    let disks = read_u32_le(bytes, locator + 16).ok_or(ZipPreflightError::Zip64LocatorMissing)?;
    if eocd_disk != 0 || disks != 1 {
        return Err(ZipPreflightError::MultiDiskUnsupported);
    }
    // Match zip 8.6's selector: try the locator's literal target first, then
    // search forward for a prefixed archive. A reverse search could substitute
    // a nested record in the extensible data for an already-valid outer record.
    // Only a record whose declared extent ends at this locator is eligible.
    let earliest = usize::try_from(relative_record_offset)
        .map_err(|_| ZipPreflightError::Zip64RecordInvalid)?;
    let zip64_offset = (earliest..locator)
        .find(|position| {
            bytes.get(*position..position.saturating_add(4))
                == Some(ZIP64_EOCD_SIGNATURE.as_slice())
                && read_u64_le(bytes, position.saturating_add(4))
                    .filter(|size| *size >= 44)
                    .and_then(|size| usize::try_from(size).ok())
                    .and_then(|size| position.checked_add(size)?.checked_add(12))
                    == Some(locator)
                && read_u32_le(bytes, position.saturating_add(20)) == Some(eocd_disk)
                && read_u64_le(bytes, position.saturating_add(32))
                    .zip(read_u64_le(bytes, position.saturating_add(48)))
                    .is_some_and(|(entries, offset)| {
                        entries.saturating_mul(46).saturating_add(offset) <= *position as u64
                    })
        })
        .ok_or(ZipPreflightError::Zip64RecordInvalid)?;
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
    let directory_offset =
        read_u64_le(bytes, zip64_offset + 48).ok_or(ZipPreflightError::Zip64RecordInvalid)?;
    if disk != 0 || directory_disk != 0 || entries_on_disk != entries {
        return Err(ZipPreflightError::MultiDiskUnsupported);
    }
    let summary = ZipDirectorySummary {
        entries,
        metadata_bytes,
        directory_end: zip64_offset,
        relative_directory_start: directory_offset,
        eocd: eocd_offset,
        extensible_bytes: record_payload - 44,
    };
    let archive_offset = u64::try_from(zip64_offset)
        .map_err(|_| ZipPreflightError::DirectoryOutOfBounds)?
        .checked_sub(relative_record_offset)
        .ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
    if summary.archive_offset()? != archive_offset {
        return Err(ZipPreflightError::Zip64RecordInvalid);
    }
    Ok(summary)
}

impl ZipDirectorySummary {
    pub(crate) fn allocation_metadata_bytes(self) -> u64 {
        self.metadata_bytes.saturating_add(self.extensible_bytes)
    }
    fn start(self) -> Result<usize, ZipPreflightError> {
        self.directory_end
            .checked_sub(
                usize::try_from(self.metadata_bytes)
                    .map_err(|_| ZipPreflightError::DirectoryOutOfBounds)?,
            )
            .ok_or(ZipPreflightError::DirectoryOutOfBounds)
    }

    pub(crate) fn archive_offset(self) -> Result<u64, ZipPreflightError> {
        u64::try_from(self.start()?)
            .map_err(|_| ZipPreflightError::DirectoryOutOfBounds)?
            .checked_sub(self.relative_directory_start)
            .ok_or(ZipPreflightError::DirectoryOutOfBounds)
    }
}

/// Validate the fixed record extents after the declared allocation gates pass.
/// No names, extras, comments or per-entry metadata are materialized here.
pub(crate) fn validate_directory(
    bytes: &[u8],
    summary: ZipDirectorySummary,
) -> Result<(), ZipPreflightError> {
    let mut position = summary.start()?;
    let mut count = 0_u64;
    summary.archive_offset()?;
    while position < summary.directory_end {
        // A digital signature may follow the file headers, and is not a member.
        if bytes.get(position..position.saturating_add(4)) == Some(b"PK\x05\x05") {
            let length =
                read_u16_le(bytes, position + 4).ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
            position = position
                .checked_add(6 + usize::from(length))
                .ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
            if position != summary.directory_end {
                return Err(ZipPreflightError::DirectoryOutOfBounds);
            }
            break;
        }
        if bytes.get(position..position.saturating_add(4)) != Some(b"PK\x01\x02")
            || position.saturating_add(46) > summary.directory_end
        {
            return Err(ZipPreflightError::DirectoryOutOfBounds);
        }
        let name =
            read_u16_le(bytes, position + 28).ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
        let extra =
            read_u16_le(bytes, position + 30).ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
        let comment =
            read_u16_le(bytes, position + 32).ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
        position = position
            .checked_add(46 + usize::from(name) + usize::from(extra) + usize::from(comment))
            .filter(|end| *end <= summary.directory_end)
            .ok_or(ZipPreflightError::DirectoryOutOfBounds)?;
        count += 1;
        if count > summary.entries {
            return Err(ZipPreflightError::DirectoryEntryCountMismatch);
        }
    }
    if count != summary.entries {
        return Err(ZipPreflightError::DirectoryEntryCountMismatch);
    }
    Ok(())
}

/// zip 8.6 retries earlier end records after a malformed directory. During
/// metadata construction it may read this one admitted directory sequentially,
/// but cannot seek elsewhere after beginning its first fixed file header.
/// Ordinary local member reads are enabled only after construction succeeds.
pub(crate) struct AdmittedZipCursor<'a> {
    cursor: Cursor<&'a [u8]>,
    start: u64,
    end: u64,
    eocd: u64,
    parsing: bool,
    signature_probed: bool,
    header_armed: bool,
    members_enabled: &'a Cell<bool>,
}

impl<'a> AdmittedZipCursor<'a> {
    pub(crate) fn new(
        bytes: &'a [u8],
        summary: ZipDirectorySummary,
        members_enabled: &'a Cell<bool>,
    ) -> Result<Self, ZipPreflightError> {
        Ok(Self {
            cursor: Cursor::new(bytes),
            start: summary.start()? as u64,
            end: summary.directory_end as u64,
            eocd: summary.eocd as u64,
            parsing: false,
            signature_probed: false,
            header_armed: false,
            members_enabled,
        })
    }
}

impl Read for AdmittedZipCursor<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        let position = self.cursor.position();
        if !self.members_enabled.get() {
            // The signature finder reads four bytes then rewinds. The fixed
            // central header starts immediately afterward on the actual pass.
            if self.header_armed
                || (self.signature_probed && self.cursor.position() == self.start.saturating_add(4))
            {
                self.parsing = true;
            }
            if self.parsing
                && (self.cursor.position() < self.start
                    || self.cursor.position().saturating_add(output.len() as u64) > self.end)
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "ZIP directory read left its admitted extent",
                ));
            }
        }
        let probing = !self.members_enabled.get()
            && !self.parsing
            && self.cursor.position() == self.start
            && output.len() == 4;
        let length = if self.members_enabled.get() {
            output.len()
        } else {
            output
                .len()
                .min(self.eocd.saturating_add(22).saturating_sub(position) as usize)
        };
        let count = self.cursor.read(&mut output[..length])?;
        if !self.members_enabled.get() {
            // Archive comments are not consumed by Inspector. Hide them only
            // from metadata search so an embedded later footer cannot override
            // the exact end record admitted by preflight. Original input stays intact.
            for byte in [self.eocd + 20, self.eocd + 21] {
                if byte >= position && byte - position < count as u64 {
                    output[(byte - position) as usize] = 0;
                }
            }
        }
        if probing && count == 4 && output == b"PK\x01\x02" {
            self.signature_probed = true;
        }
        Ok(count)
    }
}

impl Seek for AdmittedZipCursor<'_> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let position = if !self.members_enabled.get() {
            if let SeekFrom::End(delta) = position {
                let target = i128::from(self.eocd + 22) + i128::from(delta);
                SeekFrom::Start(u64::try_from(target).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "Invalid ZIP metadata seek")
                })?)
            } else {
                position
            }
        } else {
            position
        };
        if self.parsing && !self.members_enabled.get() {
            let unchanged = match position {
                SeekFrom::Start(value) => value == self.cursor.position(),
                SeekFrom::Current(value) => value == 0,
                SeekFrom::End(_) => false,
            };
            if !unchanged {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "ZIP metadata fallback is outside the admitted directory",
                ));
            }
        }
        if self.signature_probed && !self.parsing && position == SeekFrom::Start(self.start) {
            self.header_armed = true;
        }
        self.cursor.seek(position)
    }
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

    fn admitted_member(bytes: &[u8]) -> Vec<u8> {
        let summary = preflight(bytes).expect("fixture footer admits");
        validate_directory(bytes, summary).expect("fixture directory admits");
        let members = Cell::new(false);
        let cursor =
            AdmittedZipCursor::new(bytes, summary, &members).expect("fixture cursor admits");
        let config = zip::read::Config {
            archive_offset: zip::read::ArchiveOffset::Known(
                summary.archive_offset().expect("fixture archive offset"),
            ),
        };
        let mut archive = zip::ZipArchive::with_config(config, cursor)
            .expect("maintained parser accepts admitted metadata");
        members.set(true);
        let mut content = Vec::new();
        archive
            .by_index(0)
            .expect("first original member")
            .read_to_end(&mut content)
            .expect("member content");
        content
    }

    #[test]
    fn admitted_reader_preserves_a_prefix_and_clips_comment_reads_consistently() {
        let mut output = Cursor::new(Vec::new());
        let mut writer = zip::ZipWriter::new(&mut output);
        writer
            .start_file("public.txt", SimpleFileOptions::default())
            .expect("fixture entry");
        writer
            .write_all(b"Original captured member bytes")
            .expect("fixture content");
        writer
            .set_raw_comment(vec![b'c'; 4096].into_boxed_slice())
            .expect("fixture archive comment");
        writer.finish().expect("fixture completes");
        let ordinary = output.into_inner();
        let mut prefixed = b"Public archive prefix".to_vec();
        prefixed.extend_from_slice(&ordinary);
        assert_eq!(
            admitted_member(&prefixed),
            b"Original captured member bytes"
        );
        let summary = preflight(&ordinary).expect("comment footer");
        let members = Cell::new(false);
        let mut cursor =
            AdmittedZipCursor::new(&ordinary, summary, &members).expect("comment cursor");
        assert_eq!(
            cursor.seek(SeekFrom::End(0)).expect("virtual end"),
            summary.eocd as u64 + 22
        );
        cursor
            .seek(SeekFrom::Start(summary.eocd as u64 + 20))
            .expect("comment field");
        let mut byte = [1];
        cursor
            .read_exact(&mut byte)
            .expect("first clipped length byte");
        assert_eq!(byte, [0]);
        cursor
            .read_exact(&mut byte)
            .expect("second clipped length byte");
        assert_eq!(byte, [0]);
        assert_eq!(cursor.read(&mut byte).expect("virtual EOF"), 0);
        members.set(true);
        cursor
            .seek(SeekFrom::Start(summary.eocd as u64 + 20))
            .expect("original comment length");
        let mut length = [0; 2];
        cursor
            .read_exact(&mut length)
            .expect("original length bytes");
        assert_eq!(u16::from_le_bytes(length), 4096);
    }

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
