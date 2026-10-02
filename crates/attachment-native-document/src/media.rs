use attachment_native_types::{BlobValidationGrade, DetectedFormat, MediaMetadata};
use image::codecs::{gif::GifDecoder, webp::WebPDecoder};
use image::{AnimationDecoder as _, ImageDecoder as _, ImageFormat, ImageReader, Limits};
use std::io::Cursor;

#[derive(Debug)]
pub(crate) struct MediaProbe {
    pub metadata: MediaMetadata,
    pub grade: BlobValidationGrade,
    pub method: &'static str,
}

pub(crate) fn probe_media(
    format: DetectedFormat,
    bytes: &[u8],
    max_image_pixels: u64,
) -> Result<MediaProbe, &'static str> {
    let metadata = match format {
        DetectedFormat::Png
        | DetectedFormat::Jpeg
        | DetectedFormat::Gif
        | DetectedFormat::Webp
        | DetectedFormat::Bmp
        | DetectedFormat::Tiff
        | DetectedFormat::Heif
        | DetectedFormat::Avif => probe_raster(bytes, max_image_pixels),
        DetectedFormat::Wav => probe_wav(bytes),
        DetectedFormat::Aiff => probe_aiff(bytes),
        DetectedFormat::Caf => probe_caf(bytes),
        DetectedFormat::Flac => probe_flac(bytes),
        DetectedFormat::Mp3 => probe_mp3(bytes),
        DetectedFormat::OggAudio | DetectedFormat::OggVideo => probe_ogg(bytes),
        DetectedFormat::M4a | DetectedFormat::Mp4 | DetectedFormat::QuickTime => {
            probe_iso_bmff(bytes)
        }
        DetectedFormat::Matroska | DetectedFormat::Webm => probe_ebml(bytes),
        DetectedFormat::Avi => probe_avi(bytes),
        _ => Err("No structural media probe is available for this detected format."),
    }?;
    if matches!(
        format,
        DetectedFormat::Png
            | DetectedFormat::Jpeg
            | DetectedFormat::Gif
            | DetectedFormat::Webp
            | DetectedFormat::Wav
    ) {
        if format == DetectedFormat::Wav {
            decode_wav(bytes)?;
        } else if matches!(format, DetectedFormat::Gif | DetectedFormat::Webp) {
            decode_animation(format, bytes, max_image_pixels, &metadata)?;
        } else {
            decode_static_raster(format, bytes, max_image_pixels, &metadata)?;
        }
        return Ok(MediaProbe {
            metadata,
            grade: BlobValidationGrade::PayloadDecoded,
            method: if format == DetectedFormat::Wav {
                "bounded complete WAV sample decode"
            } else {
                "bounded complete raster decode"
            },
        });
    }
    Ok(MediaProbe {
        metadata,
        grade: BlobValidationGrade::HeaderOrStructureOnly,
        method: "bounded header or container-structure probe",
    })
}

fn decode_animation(
    format: DetectedFormat,
    bytes: &[u8],
    max_image_pixels: u64,
    metadata: &MediaMetadata,
) -> Result<(), &'static str> {
    const MAX_DECODE_BYTES: u64 = 128 * 1024 * 1024;
    let mut limits = Limits::default();
    limits.max_image_width = metadata.width;
    limits.max_image_height = metadata.height;
    limits.max_alloc = Some(max_image_pixels.saturating_mul(16).min(MAX_DECODE_BYTES));
    let frames = match format {
        DetectedFormat::Gif => {
            if bytes.last() != Some(&0x3b) {
                return Err("The GIF trailer is missing or has trailing data.");
            }
            let mut decoder = GifDecoder::new(Cursor::new(bytes))
                .map_err(|_| "The GIF payload failed bounded decoding.")?;
            decoder
                .set_limits(limits)
                .map_err(|_| "The GIF exceeds its decode budget.")?;
            decoder.into_frames()
        }
        DetectedFormat::Webp => {
            let declared = bytes
                .get(4..8)
                .and_then(|slice| <[u8; 4]>::try_from(slice).ok())
                .map(u32::from_le_bytes)
                .ok_or("The WebP length is missing.")?;
            if u64::from(declared) + 8 != bytes.len() as u64 {
                return Err("The WebP payload length is inconsistent.");
            }
            let mut decoder = WebPDecoder::new(Cursor::new(bytes))
                .map_err(|_| "The WebP payload failed bounded decoding.")?;
            decoder
                .set_limits(limits.clone())
                .map_err(|_| "The WebP exceeds its decode budget.")?;
            if !decoder.has_animation() {
                let mut reader = ImageReader::with_format(Cursor::new(bytes), ImageFormat::WebP);
                reader.limits(limits);
                let decoded = reader
                    .decode()
                    .map_err(|_| "The WebP payload failed bounded decoding.")?;
                return if Some(decoded.width()) == metadata.width
                    && Some(decoded.height()) == metadata.height
                {
                    Ok(())
                } else {
                    Err("The WebP dimensions disagree with its structural probe.")
                };
            }
            decoder.into_frames()
        }
        _ => return Err("No animation decoder is configured for this format."),
    };
    let mut count = 0_u32;
    let mut decoded_bytes = 0_u64;
    for frame in frames {
        count += 1;
        if count > 120 {
            return Err("The animation exceeds its 120-frame decode budget.");
        }
        let frame = frame.map_err(|_| "An animation frame failed bounded decoding.")?;
        if Some(frame.buffer().width()) != metadata.width
            || Some(frame.buffer().height()) != metadata.height
        {
            return Err("Animation dimensions disagree with the structural probe.");
        }
        decoded_bytes = decoded_bytes.saturating_add(frame.buffer().as_raw().len() as u64);
        if decoded_bytes > MAX_DECODE_BYTES {
            return Err("The animation exceeds its aggregate decode budget.");
        }
    }
    if count == 0 {
        return Err("The animation contains no decoded frames.");
    }
    Ok(())
}

fn decode_wav(bytes: &[u8]) -> Result<(), &'static str> {
    let mut reader = hound::WavReader::new(Cursor::new(bytes))
        .map_err(|_| "The complete WAV payload failed bounded decoding.")?;
    match reader.spec().sample_format {
        hound::SampleFormat::Float => {
            for sample in reader.samples::<f32>() {
                let value =
                    sample.map_err(|_| "The complete WAV payload failed bounded decoding.")?;
                if !value.is_finite() {
                    return Err("The WAV payload contains a non-finite sample.");
                }
            }
        }
        hound::SampleFormat::Int => {
            for sample in reader.samples::<i32>() {
                sample.map_err(|_| "The complete WAV payload failed bounded decoding.")?;
            }
        }
    }
    Ok(())
}

fn decode_static_raster(
    format: DetectedFormat,
    bytes: &[u8],
    max_image_pixels: u64,
    metadata: &MediaMetadata,
) -> Result<(), &'static str> {
    let image_format = match format {
        DetectedFormat::Png => {
            validate_png_framing(bytes)?;
            ImageFormat::Png
        }
        DetectedFormat::Jpeg => {
            validate_jpeg_framing(bytes)?;
            ImageFormat::Jpeg
        }
        _ => return Err("No complete raster decoder is configured for this format."),
    };
    let max_alloc = max_image_pixels
        .checked_mul(16)
        .ok_or("The raster decode allocation limit overflowed.")?;
    let mut reader = ImageReader::with_format(Cursor::new(bytes), image_format);
    let mut limits = Limits::default();
    limits.max_image_width = metadata.width;
    limits.max_image_height = metadata.height;
    limits.max_alloc = Some(max_alloc);
    reader.limits(limits);
    let decoded = reader
        .decode()
        .map_err(|_| "The complete raster payload failed bounded decoding.")?;
    if Some(decoded.width()) != metadata.width || Some(decoded.height()) != metadata.height {
        return Err("The raster decoder dimensions disagree with the structural probe.");
    }
    Ok(())
}

fn validate_png_framing(bytes: &[u8]) -> Result<(), &'static str> {
    const SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

    if !bytes.starts_with(SIGNATURE) {
        return Err("The PNG signature is invalid.");
    }

    let mut offset = SIGNATURE.len();
    let mut chunk_index = 0_usize;
    let mut saw_idat = false;
    let mut idat_ended = false;
    while offset < bytes.len() {
        let header_end = offset
            .checked_add(8)
            .ok_or("A PNG chunk header offset overflowed.")?;
        if header_end > bytes.len() {
            return Err("A PNG chunk header is truncated.");
        }
        let data_len = read_u32_be(bytes, offset)
            .and_then(|value| usize::try_from(value).ok())
            .ok_or("A PNG chunk length is invalid.")?;
        let kind = bytes
            .get(offset + 4..header_end)
            .ok_or("A PNG chunk type is truncated.")?;
        if !kind.iter().all(u8::is_ascii_alphabetic) {
            return Err("A PNG chunk type contains invalid bytes.");
        }
        let data_end = header_end
            .checked_add(data_len)
            .ok_or("A PNG chunk length overflowed.")?;
        let chunk_end = data_end
            .checked_add(4)
            .ok_or("A PNG chunk boundary overflowed.")?;
        if chunk_end > bytes.len() {
            return Err("A PNG chunk extends beyond the retained object.");
        }
        let data = &bytes[header_end..data_end];
        let declared_crc = read_u32_be(bytes, data_end).ok_or("A PNG chunk CRC is truncated.")?;
        if png_crc32(kind, data) != declared_crc {
            return Err("A PNG chunk failed its CRC integrity check.");
        }

        if chunk_index == 0 && kind != b"IHDR" {
            return Err("The PNG does not begin with an IHDR chunk.");
        }
        if chunk_index != 0 && kind == b"IHDR" {
            return Err("The PNG contains more than one IHDR chunk.");
        }
        if kind == b"IDAT" {
            if idat_ended {
                return Err("The PNG contains a non-consecutive IDAT sequence.");
            }
            saw_idat = true;
        } else if saw_idat {
            idat_ended = true;
        }

        if kind == b"IEND" {
            if !data.is_empty() {
                return Err("The PNG IEND chunk is not empty.");
            }
            if !saw_idat {
                return Err("The PNG reaches IEND before any image data.");
            }
            if chunk_end != bytes.len() {
                return Err("The PNG contains bytes after its terminal IEND chunk.");
            }
            return Ok(());
        }

        offset = chunk_end;
        chunk_index = chunk_index.saturating_add(1);
    }
    Err("The PNG has no terminal IEND chunk.")
}

fn png_crc32(kind: &[u8], data: &[u8]) -> u32 {
    const TABLE: [u32; 256] = {
        let mut table = [0_u32; 256];
        let mut index = 0_usize;
        let mut byte = 0_u32;
        while index < table.len() {
            let mut value = byte;
            let mut bit = 0;
            while bit < 8 {
                let mask = 0_u32.wrapping_sub(value & 1);
                value = (value >> 1) ^ (0xedb8_8320 & mask);
                bit += 1;
            }
            table[index] = value;
            index += 1;
            byte += 1;
        }
        table
    };

    let mut value = u32::MAX;
    for byte in kind.iter().chain(data) {
        let table_index = usize::from((value ^ u32::from(*byte)).to_le_bytes()[0]);
        value = (value >> 8) ^ TABLE[table_index];
    }
    !value
}

fn validate_jpeg_framing(bytes: &[u8]) -> Result<(), &'static str> {
    const MARKER_PREFIX: u8 = 0xff;
    const SOI: u8 = 0xd8;
    const EOI: u8 = 0xd9;
    const SOS: u8 = 0xda;

    if !bytes.starts_with(&[MARKER_PREFIX, SOI]) {
        return Err("The JPEG start-of-image marker is invalid.");
    }

    let mut offset = 2_usize;
    let mut saw_scan = false;
    loop {
        let (marker, after_marker) = jpeg_marker(bytes, offset)?;
        offset = after_marker;
        match marker {
            EOI => {
                if !saw_scan {
                    return Err("The JPEG reaches EOI before any image scan.");
                }
                if offset != bytes.len() {
                    return Err("The JPEG contains bytes after its terminal EOI marker.");
                }
                return Ok(());
            }
            SOI => return Err("The JPEG contains an unexpected nested SOI marker."),
            0x00 | 0x01 | 0xd0..=0xd7 => {
                return Err("The JPEG contains a standalone marker outside entropy-coded data.");
            }
            _ => {}
        }

        let length_end = offset
            .checked_add(2)
            .ok_or("A JPEG segment length offset overflowed.")?;
        let segment_len = bytes
            .get(offset..length_end)
            .and_then(|value| value.try_into().ok())
            .map(u16::from_be_bytes)
            .map(usize::from)
            .ok_or("A JPEG segment length is truncated.")?;
        if segment_len < 2 {
            return Err("A JPEG segment declares an invalid length.");
        }
        let segment_end = offset
            .checked_add(segment_len)
            .ok_or("A JPEG segment length overflowed.")?;
        if segment_end > bytes.len() {
            return Err("A JPEG segment extends beyond the retained object.");
        }
        offset = segment_end;
        if marker == SOS {
            saw_scan = true;
            offset = jpeg_scan_end(bytes, offset)?;
        }
    }
}

fn jpeg_marker(bytes: &[u8], offset: usize) -> Result<(u8, usize), &'static str> {
    if bytes.get(offset) != Some(&0xff) {
        return Err("The JPEG contains unframed bytes between marker segments.");
    }
    let mut marker_offset = offset;
    while bytes.get(marker_offset) == Some(&0xff) {
        marker_offset = marker_offset
            .checked_add(1)
            .ok_or("A JPEG marker offset overflowed.")?;
    }
    let marker = *bytes
        .get(marker_offset)
        .ok_or("The JPEG ends inside a marker prefix.")?;
    if marker == 0x00 {
        return Err("The JPEG contains a stuffed byte outside entropy-coded data.");
    }
    let after_marker = marker_offset
        .checked_add(1)
        .ok_or("A JPEG marker offset overflowed.")?;
    Ok((marker, after_marker))
}

fn jpeg_scan_end(bytes: &[u8], mut offset: usize) -> Result<usize, &'static str> {
    while offset < bytes.len() {
        if bytes[offset] != 0xff {
            offset = offset
                .checked_add(1)
                .ok_or("A JPEG scan offset overflowed.")?;
            continue;
        }

        let marker_start = offset;
        offset = offset
            .checked_add(1)
            .ok_or("A JPEG scan offset overflowed.")?;
        while bytes.get(offset) == Some(&0xff) {
            offset = offset
                .checked_add(1)
                .ok_or("A JPEG marker offset overflowed.")?;
        }
        let marker = *bytes
            .get(offset)
            .ok_or("The JPEG ends inside entropy-coded marker data.")?;
        match marker {
            0x00 | 0x01 | 0xd0..=0xd7 => {
                offset = offset
                    .checked_add(1)
                    .ok_or("A JPEG scan offset overflowed.")?;
            }
            _ => return Ok(marker_start),
        }
    }
    Err("The JPEG entropy-coded data has no terminal marker.")
}

fn probe_aiff(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 12 || &bytes[..4] != b"FORM" || !matches!(&bytes[8..12], b"AIFF" | b"AIFC") {
        return Err("The AIFF FORM header is invalid.");
    }
    let declared = read_u32_be(bytes, 4)
        .and_then(|size| usize::try_from(size).ok())
        .and_then(|size| size.checked_add(8))
        .ok_or("The AIFF FORM size is invalid.")?;
    if declared > bytes.len() {
        return Err("The AIFF FORM size exceeds the retained object length.");
    }
    let mut offset = 12_usize;
    let mut channels = None;
    let mut saw_sound = false;
    while offset.checked_add(8).is_some_and(|end| end <= declared) {
        let id = &bytes[offset..offset + 4];
        let size = read_u32_be(bytes, offset + 4)
            .and_then(|size| usize::try_from(size).ok())
            .ok_or("An AIFF chunk size is invalid.")?;
        let body = offset
            .checked_add(8)
            .ok_or("An AIFF chunk offset overflowed.")?;
        let end = body
            .checked_add(size)
            .ok_or("An AIFF chunk size overflowed.")?;
        if end > declared {
            return Err("An AIFF chunk extends beyond the declared FORM boundary.");
        }
        if id == b"COMM" && size >= 18 {
            channels = bytes
                .get(body..body + 2)
                .and_then(|value| value.try_into().ok())
                .map(u16::from_be_bytes)
                .filter(|value| *value > 0);
        } else if id == b"SSND" && size > 8 {
            saw_sound = true;
        }
        offset = end.saturating_add(size & 1);
    }
    if channels.is_none() || !saw_sound {
        return Err("The AIFF container lacks a valid common or sound-data chunk.");
    }
    Ok(MediaMetadata {
        channels,
        ..MediaMetadata::default()
    })
}

fn probe_caf(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 12 || &bytes[..4] != b"caff" || bytes[4..6] != [0, 1] {
        return Err("The Core Audio Format header is invalid.");
    }
    let mut offset = 8_usize;
    let mut saw_description = false;
    let mut saw_data = false;
    while offset.checked_add(12).is_some_and(|end| end <= bytes.len()) {
        let kind = &bytes[offset..offset + 4];
        let size = u64::from_be_bytes(
            bytes[offset + 4..offset + 12]
                .try_into()
                .map_err(|_| "A CAF chunk size is invalid.")?,
        );
        let size = usize::try_from(size).map_err(|_| "A CAF chunk is too large.")?;
        let body = offset
            .checked_add(12)
            .ok_or("A CAF chunk offset overflowed.")?;
        let end = body
            .checked_add(size)
            .ok_or("A CAF chunk size overflowed.")?;
        if end > bytes.len() {
            return Err("A CAF chunk extends beyond the retained object.");
        }
        saw_description |= kind == b"desc" && size >= 32;
        saw_data |= kind == b"data" && size > 4;
        offset = end;
    }
    if !saw_description || !saw_data {
        return Err("The CAF container lacks a valid description or audio-data chunk.");
    }
    Ok(MediaMetadata::default())
}

fn probe_raster(bytes: &[u8], max_image_pixels: u64) -> Result<MediaMetadata, &'static str> {
    let size = imagesize::blob_size(bytes).map_err(
        |_| "The raster signature is present, but its image header is malformed or unsupported.",
    )?;
    if size.width == 0 || size.height == 0 {
        return Err("The raster image reports a zero width or height.");
    }
    let width = u32::try_from(size.width).map_err(|_| "The raster width is too large.")?;
    let height = u32::try_from(size.height).map_err(|_| "The raster height is too large.")?;
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or("The raster pixel count overflowed safely representable limits.")?;
    if pixels > max_image_pixels {
        return Err("The raster image exceeds the configured decoded-pixel limit.");
    }
    Ok(MediaMetadata {
        width: Some(width),
        height: Some(height),
        ..MediaMetadata::default()
    })
}

fn probe_wav(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("The WAV RIFF header is invalid.");
    }
    let declared = read_u32_le(bytes, 4)
        .and_then(|size| usize::try_from(size).ok())
        .and_then(|size| size.checked_add(8))
        .ok_or("The WAV RIFF size is invalid.")?;
    if declared > bytes.len() {
        return Err("The WAV RIFF size exceeds the retained object length.");
    }
    let mut offset = 12_usize;
    let mut channels = None;
    let mut sample_rate = None;
    let mut data_bytes = None;
    let mut bits_per_sample = None;
    while offset.checked_add(8).is_some_and(|end| end <= declared) {
        let id = &bytes[offset..offset + 4];
        let size = read_u32_le(bytes, offset + 4)
            .and_then(|size| usize::try_from(size).ok())
            .ok_or("A WAV chunk size is invalid.")?;
        let body = offset
            .checked_add(8)
            .ok_or("A WAV chunk offset overflowed.")?;
        let end = body
            .checked_add(size)
            .ok_or("A WAV chunk size overflowed.")?;
        if end > declared {
            return Err("A WAV chunk extends beyond the declared RIFF boundary.");
        }
        if id == b"fmt " && size >= 16 {
            channels = read_u16_le(bytes, body);
            sample_rate = read_u32_le(bytes, body + 4);
            bits_per_sample = read_u16_le(bytes, body + 14);
        } else if id == b"data" {
            data_bytes = u64::try_from(size).ok();
        }
        offset = end.saturating_add(size & 1);
    }
    let channels = channels
        .filter(|value| *value > 0)
        .ok_or("The WAV format chunk is missing or invalid.")?;
    let sample_rate = sample_rate
        .filter(|value| *value > 0)
        .ok_or("The WAV sample rate is missing or invalid.")?;
    let data_bytes = data_bytes
        .filter(|bytes| *bytes > 0)
        .ok_or("The WAV has no non-empty data chunk.")?;
    let duration_ms = Some(data_bytes).and_then(|bytes| {
        let bits = u64::from(bits_per_sample?);
        let denominator = u64::from(sample_rate)
            .checked_mul(u64::from(channels))?
            .checked_mul(bits)?;
        bytes
            .checked_mul(8)?
            .checked_mul(1_000)?
            .checked_div(denominator)
    });
    Ok(MediaMetadata {
        duration_ms,
        channels: Some(channels),
        sample_rate_hz: Some(sample_rate),
        ..MediaMetadata::default()
    })
}

fn probe_flac(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 42 || !bytes.starts_with(b"fLaC") {
        return Err("The FLAC stream header is incomplete.");
    }
    let block_type = bytes[4] & 0x7f;
    let block_len =
        (usize::from(bytes[5]) << 16) | (usize::from(bytes[6]) << 8) | usize::from(bytes[7]);
    if block_type != 0 || block_len < 34 || 8_usize.saturating_add(block_len) > bytes.len() {
        return Err("The FLAC STREAMINFO metadata block is missing or invalid.");
    }
    let packed = u64::from_be_bytes([
        0, 0, bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23],
    ]);
    let sample_rate = u32::try_from((packed >> 44) & 0x000f_ffff).ok();
    let channels = u16::try_from(((packed >> 41) & 0x7) + 1).ok();
    let total_samples = packed & 0x0000_000f_ffff_ffff;
    let sample_rate = sample_rate
        .filter(|value| *value > 0)
        .ok_or("The FLAC sample rate is invalid.")?;
    let channels = channels
        .filter(|value| *value > 0)
        .ok_or("The FLAC channel count is invalid.")?;
    let mut offset = 4_usize;
    loop {
        if offset.checked_add(4).is_none_or(|end| end > bytes.len()) {
            return Err("The FLAC metadata chain is truncated.");
        }
        let header = bytes[offset];
        let size = (usize::from(bytes[offset + 1]) << 16)
            | (usize::from(bytes[offset + 2]) << 8)
            | usize::from(bytes[offset + 3]);
        offset = offset
            .checked_add(4)
            .and_then(|value| value.checked_add(size))
            .ok_or("The FLAC metadata size overflowed.")?;
        if offset > bytes.len() {
            return Err("The FLAC metadata block is truncated.");
        }
        if header & 0x80 != 0 {
            break;
        }
    }
    if offset.checked_add(2).is_none_or(|end| end > bytes.len())
        || bytes[offset] != 0xff
        || bytes[offset + 1] & 0xfc != 0xf8
    {
        return Err("The FLAC container has no recognizable audio frame after metadata.");
    }
    Ok(MediaMetadata {
        duration_ms: total_samples
            .checked_mul(1_000)
            .and_then(|value| value.checked_div(u64::from(sample_rate))),
        channels: Some(channels),
        sample_rate_hz: Some(sample_rate),
        ..MediaMetadata::default()
    })
}

fn probe_mp3(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    let mut offset = 0_usize;
    if bytes.starts_with(b"ID3") {
        if bytes.len() < 10 || bytes[6..10].iter().any(|byte| byte & 0x80 != 0) {
            return Err("The MP3 ID3 header is invalid.");
        }
        let size = (usize::from(bytes[6]) << 21)
            | (usize::from(bytes[7]) << 14)
            | (usize::from(bytes[8]) << 7)
            | usize::from(bytes[9]);
        offset = 10_usize
            .checked_add(size)
            .ok_or("The MP3 ID3 size overflowed.")?;
    }
    if offset.checked_add(4).is_none_or(|end| end > bytes.len()) {
        return Err("The MP3 contains no complete audio frame header.");
    }
    let header = u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ]);
    let layer = (header >> 17) & 0x3;
    let bitrate_index = usize::try_from((header >> 12) & 0xf).unwrap_or(15);
    if header & 0xffe0_0000 != 0xffe0_0000
        || (header >> 19) & 0x3 == 1
        || layer == 0
        || bitrate_index == 0
        || bitrate_index == 0xf
        || (header >> 10) & 0x3 == 0x3
    {
        return Err("The MP3 audio frame header is invalid.");
    }
    let version = (header >> 19) & 0x3;
    let sample_index = usize::try_from((header >> 10) & 0x3).unwrap_or(3);
    let rates = match version {
        3 => [44_100, 48_000, 32_000, 0],
        2 => [22_050, 24_000, 16_000, 0],
        _ => [11_025, 12_000, 8_000, 0],
    };
    let sample_rate = rates[sample_index];
    if sample_rate == 0 {
        return Err("The MP3 sample-rate index is invalid.");
    }
    let bitrate_kbps = mp3_bitrate_kbps(version, layer, bitrate_index)
        .ok_or("The MP3 bitrate index is invalid.")?;
    let padding = usize::try_from((header >> 9) & 1).unwrap_or(0);
    let bitrate = usize::try_from(bitrate_kbps)
        .ok()
        .and_then(|value| value.checked_mul(1_000))
        .ok_or("The MP3 bitrate overflowed.")?;
    let rate = usize::try_from(sample_rate).map_err(|_| "The MP3 sample rate is invalid.")?;
    let frame_len = if layer == 3 {
        bitrate
            .checked_mul(12)
            .and_then(|value| value.checked_div(rate))
            .and_then(|value| value.checked_add(padding))
            .and_then(|value| value.checked_mul(4))
    } else {
        let coefficient = if version == 3 || layer == 2 { 144 } else { 72 };
        bitrate
            .checked_mul(coefficient)
            .and_then(|value| value.checked_div(rate))
            .and_then(|value| value.checked_add(padding))
    }
    .ok_or("The MP3 frame size overflowed.")?;
    if frame_len < 4
        || offset
            .checked_add(frame_len)
            .is_none_or(|end| end > bytes.len())
    {
        return Err("The MP3 audio frame is truncated.");
    }
    let channel_mode = (header >> 6) & 0x3;
    Ok(MediaMetadata {
        channels: Some(if channel_mode == 3 { 1 } else { 2 }),
        sample_rate_hz: Some(sample_rate),
        ..MediaMetadata::default()
    })
}

fn probe_ogg(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 27 || !bytes.starts_with(b"OggS") || bytes[4] != 0 {
        return Err("The Ogg page header is invalid.");
    }
    let segments = usize::from(bytes[26]);
    let table_end = 27_usize
        .checked_add(segments)
        .ok_or("The Ogg segment table overflowed.")?;
    if table_end > bytes.len() {
        return Err("The Ogg segment table is truncated.");
    }
    let payload = bytes[27..table_end]
        .iter()
        .try_fold(0_usize, |total, value| {
            total.checked_add(usize::from(*value))
        })
        .ok_or("The Ogg page size overflowed.")?;
    if table_end
        .checked_add(payload)
        .is_none_or(|end| end > bytes.len())
    {
        return Err("The Ogg page payload is truncated.");
    }
    Ok(MediaMetadata::default())
}

fn probe_iso_bmff(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 16 || &bytes[4..8] != b"ftyp" {
        return Err("The ISO base-media file type box is invalid.");
    }
    let mut offset = 0_usize;
    let mut saw_ftyp = false;
    let mut saw_media_box = false;
    while offset.checked_add(8).is_some_and(|end| end <= bytes.len()) {
        let size32 = read_u32_be(bytes, offset).ok_or("An ISO media box size is invalid.")?;
        let kind = &bytes[offset + 4..offset + 8];
        let (size, header_len) = if size32 == 1 {
            if offset.checked_add(16).is_none_or(|end| end > bytes.len()) {
                return Err("An extended ISO media box header is truncated.");
            }
            let size = u64::from_be_bytes(
                bytes[offset + 8..offset + 16]
                    .try_into()
                    .map_err(|_| "An extended ISO media size is invalid.")?,
            );
            (
                usize::try_from(size).map_err(|_| "An ISO media box is too large.")?,
                16,
            )
        } else if size32 == 0 {
            (bytes.len().saturating_sub(offset), 8)
        } else {
            (
                usize::try_from(size32).map_err(|_| "An ISO media box is too large.")?,
                8,
            )
        };
        if size < header_len || offset.checked_add(size).is_none_or(|end| end > bytes.len()) {
            return Err("An ISO media box extends beyond the retained object.");
        }
        saw_ftyp |= kind == b"ftyp";
        saw_media_box |= matches!(kind, b"moov" | b"mdat");
        offset = offset.saturating_add(size);
        if size == 0 {
            break;
        }
    }
    if !saw_ftyp || !saw_media_box {
        return Err("The ISO media container has no recognizable movie or media-data box.");
    }
    Ok(MediaMetadata::default())
}

fn probe_ebml(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 8 || !bytes.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        return Err("The EBML header is invalid.");
    }
    if !bytes
        .windows(4)
        .any(|window| window == [0x18, 0x53, 0x80, 0x67])
    {
        return Err("The Matroska/WebM segment element is missing.");
    }
    Ok(MediaMetadata::default())
}

fn probe_avi(bytes: &[u8]) -> Result<MediaMetadata, &'static str> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"AVI " {
        return Err("The AVI RIFF header is invalid.");
    }
    let declared = read_u32_le(bytes, 4)
        .and_then(|size| usize::try_from(size).ok())
        .and_then(|size| size.checked_add(8))
        .ok_or("The AVI RIFF size is invalid.")?;
    if declared > bytes.len() {
        return Err("The AVI RIFF size exceeds the retained object length.");
    }
    if !bytes[..declared].windows(4).any(|window| window == b"movi") {
        return Err("The AVI container has no media-data list.");
    }
    Ok(MediaMetadata::default())
}

fn mp3_bitrate_kbps(version: u32, layer: u32, index: usize) -> Option<u32> {
    const MPEG1_LAYER1: [u32; 16] = [
        0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0,
    ];
    const MPEG1_LAYER2: [u32; 16] = [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0,
    ];
    const MPEG1_LAYER3: [u32; 16] = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    ];
    const MPEG2_LAYER1: [u32; 16] = [
        0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0,
    ];
    const MPEG2_LAYER23: [u32; 16] = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    ];
    let table = match (version, layer) {
        (3, 3) => &MPEG1_LAYER1,
        (3, 2) => &MPEG1_LAYER2,
        (3, 1) => &MPEG1_LAYER3,
        (_, 3) => &MPEG2_LAYER1,
        (_, 2 | 1) => &MPEG2_LAYER23,
        _ => return None,
    };
    table.get(index).copied().filter(|value| *value > 0)
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

fn read_u32_be(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_be_bytes(
        bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, RgbImage};

    fn encoded_image(format: ImageFormat) -> Result<Vec<u8>, image::ImageError> {
        let image = DynamicImage::ImageRgb8(RgbImage::from_pixel(2, 3, image::Rgb([7, 8, 9])));
        let mut bytes = Cursor::new(Vec::new());
        image.write_to(&mut bytes, format)?;
        Ok(bytes.into_inner())
    }

    #[test]
    fn common_web_images_require_complete_payload_decode() {
        for (format, detected) in [
            (ImageFormat::Gif, DetectedFormat::Gif),
            (ImageFormat::WebP, DetectedFormat::Webp),
        ] {
            let bytes = encoded_image(format).expect("encode image");
            let probe = probe_media(detected, &bytes, 1_000_000).expect("decode valid image");
            assert_eq!(probe.grade, BlobValidationGrade::PayloadDecoded);
            assert!(probe_media(detected, &bytes[..bytes.len() - 1], 1_000_000).is_err());
        }
        let mut bytes = Cursor::new(Vec::new());
        {
            let mut encoder = image::codecs::gif::GifEncoder::new(&mut bytes);
            for _ in 0..121 {
                encoder
                    .encode_frame(image::Frame::new(image::RgbaImage::new(1, 1)))
                    .expect("encode frame");
            }
        }
        assert!(probe_media(DetectedFormat::Gif, &bytes.into_inner(), 1_000_000).is_err());
    }

    #[test]
    fn signature_only_png_is_not_direct_ready() {
        let result = probe_media(DetectedFormat::Png, b"\x89PNG\r\n\x1a\n", 1_000_000);
        assert!(result.is_err());
    }

    #[test]
    fn fully_decoded_png_is_direct_grade_and_pixel_bounded() -> Result<(), image::ImageError> {
        let png = encoded_image(ImageFormat::Png)?;
        let probe = probe_media(DetectedFormat::Png, &png, 6);
        assert!(matches!(
            probe,
            Ok(MediaProbe {
                metadata: MediaMetadata {
                    width: Some(2),
                    height: Some(3),
                    ..
                },
                grade: BlobValidationGrade::PayloadDecoded,
                ..
            })
        ));
        assert!(probe_media(DetectedFormat::Png, &png, 5).is_err());
        Ok(())
    }

    #[test]
    fn png_and_jpeg_tail_corruption_cannot_reach_decoded_grade() -> Result<(), image::ImageError> {
        for (format, detected) in [
            (ImageFormat::Png, DetectedFormat::Png),
            (ImageFormat::Jpeg, DetectedFormat::Jpeg),
        ] {
            let mut bytes = encoded_image(format)?;
            bytes.push(0);
            assert!(probe_media(detected, &bytes, 1_000_000).is_err());
        }
        Ok(())
    }

    #[test]
    fn fully_decoded_jpeg_is_direct_grade() -> Result<(), image::ImageError> {
        let jpeg = encoded_image(ImageFormat::Jpeg)?;
        let probe = probe_media(DetectedFormat::Jpeg, &jpeg, 6);
        assert!(matches!(
            probe,
            Ok(MediaProbe {
                metadata: MediaMetadata {
                    width: Some(2),
                    height: Some(3),
                    ..
                },
                grade: BlobValidationGrade::PayloadDecoded,
                ..
            })
        ));
        Ok(())
    }

    #[test]
    fn duplicate_terminal_marker_cannot_hide_trailing_payload() -> Result<(), image::ImageError> {
        let mut png = encoded_image(ImageFormat::Png)?;
        png.extend_from_slice(b"attacker-controlled trailer");
        png.extend_from_slice(b"\0\0\0\0IEND\xaeB\x60\x82");
        assert!(probe_media(DetectedFormat::Png, &png, 1_000_000).is_err());

        let mut jpeg = encoded_image(ImageFormat::Jpeg)?;
        jpeg.extend_from_slice(b"attacker-controlled trailer");
        jpeg.extend_from_slice(&[0xff, 0xd9]);
        assert!(probe_media(DetectedFormat::Jpeg, &jpeg, 1_000_000).is_err());
        Ok(())
    }

    #[test]
    fn png_chunk_crc_is_verified() -> Result<(), image::ImageError> {
        let mut png = encoded_image(ImageFormat::Png)?;
        assert!(!png.is_empty());
        let last_byte = png.len() - 1;
        png[last_byte] ^= 1;
        assert!(matches!(
            validate_png_framing(&png),
            Err("A PNG chunk failed its CRC integrity check.")
        ));
        Ok(())
    }

    #[test]
    fn mp3_frame_header_without_a_complete_frame_is_not_ready() {
        assert!(probe_media(DetectedFormat::Mp3, &[0xff, 0xfb, 0x90, 0x64], 1).is_err());
    }

    #[test]
    fn truncated_wav_is_not_direct_ready() {
        let result = probe_media(
            DetectedFormat::Wav,
            b"RIFF\xff\xff\xff\xffWAVEfmt ",
            1_000_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn malformed_mp4_box_is_not_direct_ready() {
        let result = probe_media(
            DetectedFormat::Mp4,
            b"\0\0\0\x10ftypisom\0\0\0\x20mdat",
            1_000_000,
        );
        assert!(result.is_err());
    }

    #[test]
    fn harmless_trailing_corruption_never_promotes_audio_or_video_to_direct_grade() {
        let mut ogg = vec![0_u8; 27];
        ogg[..4].copy_from_slice(b"OggS");
        ogg.extend_from_slice(b"OggS\0");
        let mut mp4 = b"\0\0\0\x10ftypisom\0\0\0\0\0\0\0\x08mdat".to_vec();
        mp4.extend_from_slice(&[0, 0, 0]);
        let mut ebml = vec![
            0x1a, 0x45, 0xdf, 0xa3, 0x80, 0, 0, 0, 0x18, 0x53, 0x80, 0x67,
        ];
        ebml.extend_from_slice(&[0x1f, 0x43]);
        let mut mp3 = vec![0_u8; 417];
        mp3[..4].copy_from_slice(&[0xff, 0xfb, 0x90, 0x64]);
        mp3.extend_from_slice(&[0xff, 0xfb]);
        for probe in [
            probe_media(DetectedFormat::OggAudio, &ogg, 1),
            probe_media(DetectedFormat::Mp4, &mp4, 1),
            probe_media(DetectedFormat::Webm, &ebml, 1),
            probe_media(DetectedFormat::Mp3, &mp3, 1),
        ] {
            assert!(
                matches!(
                    &probe,
                    Ok(MediaProbe {
                        grade: BlobValidationGrade::HeaderOrStructureOnly,
                        ..
                    })
                ),
                "unexpected media probe result: {probe:?}"
            );
            assert!(probe.is_ok_and(|probe| !probe.grade.permits_direct_media()));
        }
    }

    #[test]
    fn aiff_requires_both_common_and_sound_chunks() {
        let mut aiff = Vec::new();
        aiff.extend_from_slice(b"FORM");
        aiff.extend_from_slice(&48_u32.to_be_bytes());
        aiff.extend_from_slice(b"AIFF");
        aiff.extend_from_slice(b"COMM");
        aiff.extend_from_slice(&18_u32.to_be_bytes());
        aiff.extend_from_slice(&2_u16.to_be_bytes());
        aiff.extend_from_slice(&[0_u8; 16]);
        aiff.extend_from_slice(b"SSND");
        aiff.extend_from_slice(&9_u32.to_be_bytes());
        aiff.extend_from_slice(&[0_u8; 9]);
        aiff.push(0);
        assert!(probe_media(DetectedFormat::Aiff, &aiff, 1).is_ok());
        aiff.truncate(38);
        assert!(probe_media(DetectedFormat::Aiff, &aiff, 1).is_err());
    }

    #[test]
    fn caf_requires_description_and_audio_data_chunks() {
        let mut caf = b"caff\0\x01\0\0".to_vec();
        caf.extend_from_slice(b"desc");
        caf.extend_from_slice(&32_u64.to_be_bytes());
        caf.extend_from_slice(&[0_u8; 32]);
        caf.extend_from_slice(b"data");
        caf.extend_from_slice(&5_u64.to_be_bytes());
        caf.extend_from_slice(&[0_u8; 5]);
        assert!(probe_media(DetectedFormat::Caf, &caf, 1).is_ok());
    }
}
