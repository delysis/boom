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
    Caf,
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

fn caf_sections(bytes: &[u8]) -> Option<(&[u8], &[u8])> {
    if !bytes.starts_with(b"caff\x00\x01\x00\x00") {
        return None;
    }
    let mut cursor = 8_usize;
    let mut description = None;
    let mut data = None;
    let mut chunks = 0;
    while cursor < bytes.len() {
        chunks += 1;
        let header = bytes.get(cursor..cursor + 12)?;
        if chunks > 4096 {
            return None;
        }
        let Ok(size) = <[u8; 8]>::try_from(&header[4..12]) else {
            return None;
        };
        let size = i64::from_be_bytes(size);
        let count = if size == -1 && &header[..4] == b"data" {
            bytes.len() - cursor - 12
        } else if let Ok(count) = usize::try_from(size) {
            count
        } else {
            return None;
        };
        let end = cursor
            .checked_add(12)
            .and_then(|start| start.checked_add(count))?;
        let payload = bytes.get(cursor + 12..end)?;
        match &header[..4] {
            b"desc" => {
                if payload.len() != 32 || description.is_some() {
                    return None;
                }
                let Ok(rate) = <[u8; 8]>::try_from(&payload[..8]) else {
                    return None;
                };
                let rate = f64::from_be_bytes(rate);
                if !rate.is_finite() || !(8000.0..=384000.0).contains(&rate) {
                    return None;
                }
                description = Some(payload);
            }
            b"data" => {
                if payload.len() <= 4 || data.is_some() {
                    return None;
                }
                data = Some(&payload[4..]);
            }
            _ => {}
        }
        cursor = end;
    }
    description.zip(data)
}

/// Repackage signed/float LPCM without decoding or changing sample values.
/// CAF has its own flags: bit 0 is float and bit 1 is little endian, unlike
/// AudioStreamBasicDescription. No file or resolver is involved.
/// https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html
pub fn caf_wave(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    require(bytes.len() <= MAX_BYTES, "CAF exceeds its input bound.")?;
    let (description, samples) =
        caf_sections(bytes).ok_or_else(|| Error("Invalid CAF structure.".into()))?;
    require(
        &description[8..12] == b"lpcm",
        "Only local linear PCM CAF is supported.",
    )?;
    let flags = u32(&description[12..])?;
    let packet_bytes = u32(&description[16..])?;
    let packet_frames = u32(&description[20..])?;
    let channels = u32(&description[24..])?;
    let bits = u32(&description[28..])?;
    require(
        flags & !3 == 0 && (1..=8).contains(&channels) && packet_frames == 1,
        "Unsupported CAF sample geometry.",
    )?;
    let float = flags & 1 != 0;
    require(
        if float {
            [32, 64].contains(&bits)
        } else {
            [16, 24, 32].contains(&bits)
        },
        "Unsupported CAF sample width.",
    )?;
    let width = bits as usize / 8;
    let block = channels * bits / 8;
    require(
        packet_bytes == block && samples.len() % block as usize == 0,
        "CAF samples are not complete frames.",
    )?;
    let rate = f64::from_be_bytes(
        description[..8]
            .try_into()
            .map_err(|_| Error("Invalid CAF rate.".into()))?,
    );
    require(rate.fract() == 0.0, "CAF rate is not integral.")?;
    let rate = rate as u32;
    let mut pcm = samples.to_vec();
    if flags & 2 == 0 {
        for sample in pcm.chunks_exact_mut(width) {
            sample.reverse();
        }
    }
    if float {
        require(
            pcm.chunks_exact(width).all(|sample| {
                if bits == 32 {
                    <[u8; 4]>::try_from(sample)
                        .is_ok_and(|value| f32::from_le_bytes(value).is_finite())
                } else {
                    <[u8; 8]>::try_from(sample)
                        .is_ok_and(|value| f64::from_le_bytes(value).is_finite())
                }
            }),
            "CAF contains nonfinite samples.",
        )?;
    }
    let padded = pcm.len() + pcm.len() % 2;
    let mut wav = Vec::with_capacity(44 + padded);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36_u32 + padded as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&(if float { 3_u16 } else { 1_u16 }).to_le_bytes());
    wav.extend_from_slice(&(channels as u16).to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * block).to_le_bytes());
    wav.extend_from_slice(&(block as u16).to_le_bytes());
    wav.extend_from_slice(&(bits as u16).to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(&pcm);
    if padded != pcm.len() {
        wav.push(0);
    }
    Ok(wav)
}

pub fn admit_media(bytes: &[u8]) -> Result<MediaContainer, Error> {
    require(
        !bytes.is_empty() && bytes.len() <= MAX_BYTES,
        "Native media must be nonempty and at most 64 MiB.",
    )?;
    let kind = if caf_sections(bytes).is_some() {
        MediaContainer::Caf
    } else if bytes.get(4..8) == Some(b"ftyp") {
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
    fn caf_repack_preserves_pcm_and_rejects_truncated_or_false_geometry() {
        let original = include_bytes!("../../../App/Tests/BoomTests/Fixtures/Attachments/tone.caf");
        let (_, samples) = caf_sections(original).expect("CAF sections");
        let wave = caf_wave(original).expect("wave");
        assert_eq!(&wave[44..], samples);
        assert_eq!(admit_media(&wave).expect("admitted"), MediaContainer::Wav);
        for end in [0, 7, 19, original.len() - 1] {
            assert!(caf_wave(&original[..end]).is_err());
        }
        let mut false_geometry = original.to_vec();
        false_geometry[44..48].copy_from_slice(&0_u32.to_be_bytes());
        assert!(caf_wave(&false_geometry).is_err());
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
