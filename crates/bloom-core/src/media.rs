//! Admission before native audio/video decoding. No paths or resolver authority.
use crate::{Error, require};
use serde::Serialize;

const MAX_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaContainer {
    Mp4,
    Wav,
    Aiff,
    Flac,
    Mp3,
    Aac,
    Ogg,
}

fn u32(bytes: &[u8]) -> Result<u32, Error> {
    let b = bytes
        .get(..4)
        .ok_or_else(|| Error("Truncated media atom.".into()))?;
    Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

#[derive(Default)]
struct Movie {
    atoms: usize,
    references: usize,
}

impl Movie {
    fn scan(&mut self, mut bytes: &[u8], depth: usize) -> Result<(), Error> {
        require(depth <= 12, "Media atom nesting exceeds its limit.")?;
        while !bytes.is_empty() {
            self.atoms += 1;
            require(self.atoms <= 50_000, "Media atom count exceeds its limit.")?;
            require(bytes.len() >= 8, "Truncated media atom header.")?;
            let short = u32(bytes)?;
            let (size, header) = match short {
                0 => (bytes.len() as u64, 8),
                1 => {
                    require(bytes.len() >= 16, "Truncated extended media atom.")?;
                    (
                        (u64::from(u32(&bytes[8..])?) << 32) | u64::from(u32(&bytes[12..])?),
                        16,
                    )
                }
                n => (u64::from(n), 8),
            };
            require(
                size >= header as u64 && size <= bytes.len() as u64,
                "Media atom exceeds its containing bytes.",
            )?;
            let size =
                usize::try_from(size).map_err(|_| Error("Media atom size overflow.".into()))?;
            let payload = &bytes[header..size];
            match &bytes[4..8] {
                b"dref" => self.references(payload)?,
                b"rmra" | b"rmda" | b"rdrf" | b"cmov" | b"url " | b"urn " | b"alis" => {
                    return Err(Error("Reference movies, compressed movie metadata and external media references are forbidden.".into()));
                }
                b"moov" | b"trak" | b"mdia" | b"minf" | b"dinf" | b"stbl" | b"edts" | b"mvex"
                | b"udta" => self.scan(payload, depth + 1)?,
                b"meta" => {
                    require(u32(payload)? == 0, "Unsupported media metadata version.")?;
                    self.scan(&payload[4..], depth + 1)?;
                }
                _ => {}
            }
            bytes = &bytes[size..];
        }
        Ok(())
    }

    fn references(&mut self, bytes: &[u8]) -> Result<(), Error> {
        require(bytes.len() >= 8, "Truncated media data references.")?;
        require(
            u32(bytes)? == 0,
            "Unsupported media data-reference version.",
        )?;
        let count = u32(&bytes[4..])? as usize;
        require(
            (1..=256).contains(&count),
            "Invalid media data-reference count.",
        )?;
        require(
            bytes.len() == 8 + count * 12,
            "External or malformed media data references are forbidden.",
        )?;
        for entry in bytes[8..].chunks_exact(12) {
            require(
                u32(entry)? == 12 && &entry[4..8] == b"url " && u32(&entry[8..])? == 1,
                "External media references are forbidden.",
            )?;
        }
        self.references += count;
        Ok(())
    }
}

fn mpeg_audio(bytes: &[u8]) -> bool {
    bytes.len() >= 4
        && bytes[0] == 0xff
        && bytes[1] & 0xe0 == 0xe0
        && (bytes[1] >> 3) & 3 != 1
        && (bytes[1] >> 1) & 3 != 0
        && !matches!(bytes[2] >> 4, 0 | 15)
        && (bytes[2] >> 2) & 3 != 3
}

fn mp3(bytes: &[u8]) -> bool {
    if !bytes.starts_with(b"ID3") {
        return mpeg_audio(bytes);
    }
    if bytes.len() < 10
        || !(2..=4).contains(&bytes[3])
        || bytes[6..10].iter().any(|b| b & 0x80 != 0)
    {
        return false;
    }
    let size = bytes[6..10]
        .iter()
        .fold(0_usize, |size, b| (size << 7) | usize::from(*b));
    let footer = if bytes[3] == 4 && bytes[5] & 0x10 != 0 {
        10
    } else {
        0
    };
    bytes.get(10 + size + footer..).is_some_and(mpeg_audio)
}

pub fn admit_media(bytes: &[u8]) -> Result<MediaContainer, Error> {
    require(
        !bytes.is_empty() && bytes.len() <= MAX_BYTES,
        "Native media must be nonempty and at most 64 MiB.",
    )?;
    let kind = if bytes.get(4..8) == Some(b"ftyp") {
        let mut movie = Movie::default();
        movie.scan(bytes, 0)?;
        require(
            movie.references > 0,
            "Movie has no validated local media references.",
        )?;
        MediaContainer::Mp4
    } else if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WAVE" {
        MediaContainer::Wav
    } else if bytes.len() >= 12
        && bytes.starts_with(b"FORM")
        && matches!(&bytes[8..12], b"AIFF" | b"AIFC")
    {
        MediaContainer::Aiff
    } else if bytes.starts_with(b"fLaC") {
        MediaContainer::Flac
    } else if bytes.starts_with(b"OggS") {
        MediaContainer::Ogg
    } else if mp3(bytes) {
        MediaContainer::Mp3
    } else if bytes.len() >= 7 && bytes[0] == 0xff && bytes[1] & 0xf6 == 0xf0 {
        MediaContainer::Aac
    } else {
        return Err(Error("Only recognized local audio or self-contained MP4 media can be decoded. Playlists and reference movies are forbidden.".into()));
    };
    Ok(kind)
}

pub fn admit_duration(seconds: f64, automatic_audio: bool) -> Result<(), Error> {
    require(
        seconds.is_finite() && seconds > 0.0 && seconds <= 7200.0,
        "Media duration must be finite, positive and at most two hours.",
    )?;
    require(
        !automatic_audio || seconds <= 120.0,
        "Long recording. Use the attachment's Transcribe action for the full recording on device.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn atom(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut result = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        result.extend(kind);
        result.extend(payload);
        result
    }
    fn reference(kind: &[u8; 4], flags: u32) -> Vec<u8> {
        atom(kind, &flags.to_be_bytes())
    }
    fn movie(entry: &[u8], count: u32, extra: &[u8]) -> Vec<u8> {
        let mut refs = vec![0; 4];
        refs.extend(count.to_be_bytes());
        refs.extend(entry);
        let track = atom(
            b"trak",
            &atom(
                b"mdia",
                &atom(b"minf", &atom(b"dinf", &atom(b"dref", &refs))),
            ),
        );
        let mut body = track;
        body.extend(extra);
        let mut movie = atom(b"ftyp", b"isom\0\0\0\0");
        movie.extend(atom(b"moov", &body));
        movie
    }
    fn local() -> Vec<u8> {
        movie(&reference(b"url ", 1), 1, &[])
    }

    #[test]
    fn local_reference_and_borrowed_slice_are_admitted() {
        assert_eq!(
            admit_media(&local()).expect("local movie"),
            MediaContainer::Mp4
        );
        let mut prefixed = vec![255];
        prefixed.extend(local());
        assert_eq!(
            admit_media(&prefixed[1..]).expect("borrowed movie"),
            MediaContainer::Mp4
        );
    }
    #[test]
    fn external_urls_aliases_and_urns_are_rejected() {
        for entry in [
            reference(b"url ", 0),
            reference(b"urn ", 1),
            reference(b"alis", 1),
        ] {
            assert!(admit_media(&movie(&entry, 1, &[])).is_err());
        }
    }
    #[test]
    fn counts_versions_and_trailing_payload_cannot_hide_references() {
        for count in [0, 2, 257] {
            assert!(admit_media(&movie(&reference(b"url ", 1), count, &[])).is_err());
        }
        let mut reference = reference(b"url ", 1);
        reference.push(0);
        assert!(admit_media(&movie(&reference, 1, &[])).is_err());
        let mut refs = vec![0, 0, 0, 1];
        refs.extend(1_u32.to_be_bytes());
        refs.extend(reference);
        let mut bytes = local();
        bytes.extend(atom(b"dref", &refs));
        assert!(admit_media(&bytes).is_err());
    }
    #[test]
    fn reference_movies_and_compressed_metadata_cannot_hide_beside_local_tracks() {
        for kind in [b"rmra", b"rmda", b"rdrf", b"cmov"] {
            assert!(
                admit_media(&movie(
                    &reference(b"url ", 1),
                    1,
                    &atom(kind, b"https://example.invalid/movie")
                ))
                .is_err()
            );
        }
        let extra = atom(
            b"udta",
            &atom(b"meta", &[vec![0; 4], atom(b"rmra", b"external")].concat()),
        );
        assert!(admit_media(&movie(&reference(b"url ", 1), 1, &extra)).is_err());
    }
    #[test]
    fn size_overflow_truncation_and_excessive_nesting_are_rejected() {
        let mut huge = local();
        huge.extend(1_u32.to_be_bytes());
        huge.extend(b"moov");
        huge.extend(u64::MAX.to_be_bytes());
        assert!(admit_media(&huge).is_err());
        let mut nested = atom(
            b"dref",
            &[
                vec![0; 4],
                1_u32.to_be_bytes().to_vec(),
                reference(b"url ", 1),
            ]
            .concat(),
        );
        for _ in 0..15 {
            nested = atom(b"moov", &nested);
        }
        let mut bytes = atom(b"ftyp", b"isom\0\0\0\0");
        bytes.extend(nested);
        assert!(admit_media(&bytes).is_err());
        assert!(admit_media(&atom(b"ftyp", b"isom")).is_err());
        let bytes = local();
        for end in 0..bytes.len() {
            assert!(admit_media(&bytes[..end]).is_err(), "prefix {end}");
        }
    }
    #[test]
    fn missing_references_and_disguised_playlists_are_rejected() {
        for bytes in [
            b"#EXTM3U\nhttps://example.invalid/movie".as_slice(),
            b"https://example.invalid/a.mp4",
            b"",
            b"ID3https://example.invalid/movie",
        ] {
            assert!(admit_media(bytes).is_err());
        }
        assert!(admit_media(&atom(b"ftyp", b"isom\0\0\0\0")).is_err());
    }
    #[test]
    fn plain_audio_is_selected_by_bytes_not_filename() {
        for (bytes, kind) in [
            (b"RIFF\0\0\0\0WAVE".as_slice(), MediaContainer::Wav),
            (b"FORM\0\0\0\0AIFF", MediaContainer::Aiff),
            (b"FORM\0\0\0\0AIFC", MediaContainer::Aiff),
            (b"fLaC", MediaContainer::Flac),
            (b"OggS", MediaContainer::Ogg),
            (&[0xff, 0xfb, 0x90, 0], MediaContainer::Mp3),
            (&[0xff, 0xf1, 0x50, 0x80, 0, 0, 0], MediaContainer::Aac),
        ] {
            assert_eq!(admit_media(bytes).expect("local audio header"), kind);
        }
        let mut tagged = b"ID3\x04\0\0\0\0\0\0".to_vec();
        tagged.extend([0xff, 0xfb, 0x90, 0]);
        assert_eq!(
            admit_media(&tagged).expect("tagged MP3"),
            MediaContainer::Mp3
        );
        tagged[6] = 0xff;
        assert!(admit_media(&tagged).is_err());
    }
    #[test]
    fn captured_audio_limits_distinguish_import_from_explicit_transcription() {
        for seconds in [f64::NAN, f64::INFINITY, -1.0, 0.0, 7200.001] {
            assert!(admit_duration(seconds, false).is_err());
        }
        assert!(admit_duration(120.0, true).is_ok());
        assert!(admit_duration(120.001, true).is_err());
        assert!(admit_duration(7200.0, false).is_ok());
    }
}
