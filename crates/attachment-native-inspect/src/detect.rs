use attachment_native_types::{
    DetectedFormat, Detection, DetectionConfidence, DetectionEvidence, DetectionMismatch,
    FormatCandidate,
};
use std::path::Path;

pub(crate) fn detect(name: &str, declared_media_type: Option<&str>, bytes: &[u8]) -> Detection {
    let extension_hint = extension_hint(name);
    let extension_format = extension_hint.as_deref().and_then(format_from_extension);
    let declared_format = declared_media_type.and_then(format_from_media_type);
    let mut candidates = Vec::new();

    signature_candidates(bytes, &mut candidates);
    if bytes.starts_with(b"From ")
        && bytes
            .iter()
            .position(|byte| *byte == b'\n')
            .is_some_and(|index| looks_like_email_bytes(&bytes[index + 1..]))
    {
        push_candidate(
            &mut candidates,
            DetectedFormat::Mbox,
            DetectionConfidence::ParserConfirmed,
            DetectionEvidence::ParserStructure,
            0,
        );
    }
    if let Some(kind) = infer::get(bytes)
        && let Some(format) = format_from_media_type(kind.mime_type())
    {
        push_candidate(
            &mut candidates,
            format,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
    text_candidates(bytes, extension_format, &mut candidates);
    // RFC messages may carry an explicitly declared legacy charset in an
    // eight-bit body. Header recognition must not require UTF-8 for that body.
    if std::str::from_utf8(bytes).is_err() && looks_like_email_bytes(bytes) {
        push_candidate(
            &mut candidates,
            DetectedFormat::Email,
            DetectionConfidence::Probable,
            DetectionEvidence::TextSyntax,
            0,
        );
    }
    if let Some(format) = declared_format {
        push_candidate(
            &mut candidates,
            format,
            DetectionConfidence::HintOnly,
            DetectionEvidence::DeclaredMediaType,
            0,
        );
    }
    if let Some(format) = extension_format {
        push_candidate(
            &mut candidates,
            format,
            DetectionConfidence::HintOnly,
            DetectionEvidence::FileExtension,
            0,
        );
    }

    candidates.sort_by_key(|candidate| {
        (
            confidence_rank(candidate.confidence),
            candidate.offset,
            candidate.format,
        )
    });

    let selected = candidates
        .iter()
        .find(|candidate| candidate.confidence != DetectionConfidence::HintOnly)
        .map(|candidate| candidate.format)
        .or({
            if bytes.is_empty() {
                Some(DetectedFormat::PlainText)
            } else {
                Some(DetectedFormat::UnknownBinary)
            }
        });

    let mismatch = selected.and_then(|detected| {
        let hinted = extension_format.or(declared_format)?;
        (!formats_compatible(hinted, detected)).then(|| DetectionMismatch {
            hint: hinted.canonical_media_type().to_string(),
            detected: detected.canonical_media_type().to_string(),
        })
    });

    Detection {
        selected,
        candidates,
        extension_hint,
        declared_media_type: declared_media_type.map(str::to_string),
        mismatch,
    }
}

pub(crate) fn classify_zip_members<'a>(
    names: impl Iterator<Item = &'a str>,
    extension_hint: Option<&str>,
) -> DetectedFormat {
    let mut has_content_types = false;
    let mut has_word_document = false;
    let mut has_presentation = false;
    let mut has_workbook = false;
    let mut has_epub_mimetype = false;
    let mut has_odf_content = false;
    let mut has_odf_manifest = false;
    let mut has_iwork_index = false;
    for name in names {
        let portable = name.replace('\\', "/");
        has_content_types |= portable == "[Content_Types].xml";
        has_word_document |= portable == "word/document.xml";
        has_presentation |= portable == "ppt/presentation.xml";
        has_workbook |= portable == "xl/workbook.xml";
        has_epub_mimetype |= portable == "META-INF/container.xml";
        has_odf_content |= portable == "content.xml";
        has_odf_manifest |= portable == "META-INF/manifest.xml";
        has_iwork_index |= portable.starts_with("Index/") && portable.ends_with(".iwa");
    }
    if has_content_types && has_word_document {
        DetectedFormat::Docx
    } else if has_content_types && has_presentation {
        DetectedFormat::Pptx
    } else if has_content_types && has_workbook {
        DetectedFormat::Xlsx
    } else if has_epub_mimetype {
        DetectedFormat::Epub
    } else if has_odf_content && has_odf_manifest {
        match extension_hint {
            Some("odt") => DetectedFormat::OpenDocumentText,
            Some("ods") => DetectedFormat::OpenDocumentSpreadsheet,
            Some("odp") => DetectedFormat::OpenDocumentPresentation,
            _ => DetectedFormat::Zip,
        }
    } else if has_iwork_index {
        match extension_hint {
            Some("pages") => DetectedFormat::IWorkPages,
            Some("numbers") => DetectedFormat::IWorkNumbers,
            Some("key") | Some("keynote") => DetectedFormat::IWorkKeynote,
            _ => DetectedFormat::Zip,
        }
    } else {
        DetectedFormat::Zip
    }
}

fn signature_candidates(bytes: &[u8], candidates: &mut Vec<FormatCandidate>) {
    let signatures: &[(&[u8], DetectedFormat)] = &[
        (b"%PDF-", DetectedFormat::Pdf),
        (b"PK\x03\x04", DetectedFormat::Zip),
        (b"PK\x05\x06", DetectedFormat::Zip),
        (b"PK\x07\x08", DetectedFormat::Zip),
        (b"\x1f\x8b", DetectedFormat::Gzip),
        (b"BZh", DetectedFormat::Bzip2),
        (b"\xfd7zXZ\x00", DetectedFormat::Xz),
        (b"\x28\xb5\x2f\xfd", DetectedFormat::Zstd),
        (b"7z\xbc\xaf\x27\x1c", DetectedFormat::SevenZip),
        (b"Rar!\x1a\x07\x00", DetectedFormat::Rar),
        (b"Rar!\x1a\x07\x01\x00", DetectedFormat::Rar),
        (
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1",
            DetectedFormat::OleCompound,
        ),
        (b"{\\rtf", DetectedFormat::RichText),
        (b"\x89PNG\r\n\x1a\n", DetectedFormat::Png),
        (b"\xff\xd8\xff", DetectedFormat::Jpeg),
        (b"GIF87a", DetectedFormat::Gif),
        (b"GIF89a", DetectedFormat::Gif),
        (b"BM", DetectedFormat::Bmp),
        (b"II*\x00", DetectedFormat::Tiff),
        (b"MM\x00*", DetectedFormat::Tiff),
        (b"fLaC", DetectedFormat::Flac),
        (b"ID3", DetectedFormat::Mp3),
        (b"OggS", DetectedFormat::Ogg),
        (b"caff", DetectedFormat::Caf),
        (b"RIFF", DetectedFormat::Wav),
        (b"\x7fELF", DetectedFormat::Executable),
        (b"MZ", DetectedFormat::Executable),
    ];
    for (signature, format) in signatures {
        if bytes.starts_with(signature) {
            let format = if *format == DetectedFormat::Wav {
                if bytes.get(8..12) == Some(b"WAVE") {
                    DetectedFormat::Wav
                } else if bytes.get(8..12) == Some(b"AVI ") {
                    DetectedFormat::Avi
                } else {
                    continue;
                }
            } else {
                *format
            };
            push_candidate(
                candidates,
                format,
                DetectionConfidence::StrongSignature,
                DetectionEvidence::MagicBytes,
                0,
            );
        }
    }
    if bytes.starts_with(b"FORM") && matches!(bytes.get(8..12), Some(b"AIFF" | b"AIFC")) {
        push_candidate(
            candidates,
            DetectedFormat::Aiff,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
    if bytes.starts_with(b"OggS") {
        let format = classify_ogg_stream(bytes);
        push_candidate(
            candidates,
            format,
            DetectionConfidence::ParserConfirmed,
            DetectionEvidence::ParserStructure,
            0,
        );
    }
    if looks_like_mp3_frame(bytes) {
        push_candidate(
            candidates,
            DetectedFormat::Mp3,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
    if bytes.get(257..262) == Some(b"ustar") {
        push_candidate(
            candidates,
            DetectedFormat::Tar,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            257,
        );
    }
    if bytes.get(0..4) == Some(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        push_candidate(
            candidates,
            DetectedFormat::Webp,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
    if bytes.get(0..4) == Some(b"\x1aE\xdf\xa3") {
        let prefix = &bytes[..bytes.len().min(4_096)];
        let format = if find_bytes(prefix, b"webm") {
            DetectedFormat::Webm
        } else {
            DetectedFormat::Matroska
        };
        push_candidate(
            candidates,
            format,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
    if bytes.get(4..8) == Some(b"ftyp") {
        let brand = bytes.get(8..12).unwrap_or_default();
        let format = if matches!(
            brand,
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"mif1" | b"msf1"
        ) {
            DetectedFormat::Heif
        } else if matches!(brand, b"avif" | b"avis") {
            DetectedFormat::Avif
        } else if matches!(brand, b"M4A " | b"M4B ") {
            DetectedFormat::M4a
        } else if matches!(brand, b"qt  ") {
            DetectedFormat::QuickTime
        } else {
            DetectedFormat::Mp4
        };
        push_candidate(
            candidates,
            format,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            4,
        );
    }
    if matches!(
        bytes.get(0..4),
        Some(b"\xfe\xed\xfa\xce")
            | Some(b"\xce\xfa\xed\xfe")
            | Some(b"\xfe\xed\xfa\xcf")
            | Some(b"\xcf\xfa\xed\xfe")
            | Some(b"\xca\xfe\xba\xbe")
    ) {
        push_candidate(
            candidates,
            DetectedFormat::Executable,
            DetectionConfidence::StrongSignature,
            DetectionEvidence::MagicBytes,
            0,
        );
    }
}

fn text_candidates(
    bytes: &[u8],
    extension: Option<DetectedFormat>,
    candidates: &mut Vec<FormatCandidate>,
) {
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    let Ok(text) = std::str::from_utf8(bytes) else {
        return;
    };
    if text.chars().any(|character| character == '\0') {
        return;
    }
    let trimmed = text.trim_start();
    let lower_prefix = trimmed
        .chars()
        .take(512)
        .collect::<String>()
        .to_ascii_lowercase();
    let format = if trimmed.starts_with("WEBVTT") {
        DetectedFormat::WebVtt
    } else if looks_like_subrip(text) && matches!(extension, Some(DetectedFormat::SubRip)) {
        DetectedFormat::SubRip
    } else if lower_prefix.starts_with("<!doctype html")
        || lower_prefix.starts_with("<html")
        || lower_prefix.contains("<body")
    {
        DetectedFormat::Html
    } else if lower_prefix.starts_with("<svg") {
        DetectedFormat::Svg
    } else if lower_prefix.starts_with("<?xml") {
        DetectedFormat::Xml
    } else if text.starts_with("From ")
        && text
            .split_once('\n')
            .is_some_and(|(_, rest)| looks_like_email(rest))
    {
        DetectedFormat::Mbox
    } else if looks_like_email(text) {
        DetectedFormat::Email
    } else if matches!(extension, Some(DetectedFormat::JupyterNotebook))
        && lower_prefix.contains("\"nbformat\"")
        && lower_prefix.contains("\"cells\"")
    {
        DetectedFormat::JupyterNotebook
    } else if (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']'))
    {
        DetectedFormat::Json
    } else if matches!(extension, Some(DetectedFormat::Markdown)) {
        DetectedFormat::Markdown
    } else if matches!(extension, Some(DetectedFormat::WebVtt)) {
        DetectedFormat::WebVtt
    } else if matches!(extension, Some(DetectedFormat::SubRip)) {
        DetectedFormat::SubRip
    } else if matches!(extension, Some(DetectedFormat::Csv)) {
        DetectedFormat::Csv
    } else if matches!(extension, Some(DetectedFormat::Tsv)) {
        DetectedFormat::Tsv
    } else {
        DetectedFormat::PlainText
    };
    push_candidate(
        candidates,
        format,
        DetectionConfidence::Probable,
        DetectionEvidence::TextSyntax,
        0,
    );
}

fn looks_like_email(text: &str) -> bool {
    let mut has_header = false;
    for line in text.lines().take(64) {
        if line.is_empty() {
            return has_header;
        }
        has_header |= ["from:", "to:", "subject:", "date:", "mime-version:"]
            .iter()
            .any(|prefix| line.to_ascii_lowercase().starts_with(prefix));
    }
    false
}

fn looks_like_subrip(text: &str) -> bool {
    let mut lines = text.lines().map(str::trim).filter(|line| !line.is_empty());
    lines
        .next()
        .is_some_and(|line| line.bytes().all(|byte| byte.is_ascii_digit()))
        && lines.next().is_some_and(|line| {
            let Some((start, end)) = line.split_once("-->") else {
                return false;
            };
            start.contains(':') && start.contains(',') && end.contains(':') && end.contains(',')
        })
}

fn looks_like_mp3_frame(bytes: &[u8]) -> bool {
    let Some(header) = bytes.get(..4) else {
        return false;
    };
    let header = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    let version = (header >> 19) & 0x3;
    let layer = (header >> 17) & 0x3;
    let bitrate = (header >> 12) & 0xf;
    let sample_rate = (header >> 10) & 0x3;
    header & 0xffe0_0000 == 0xffe0_0000
        && version != 1
        && layer != 0
        && bitrate != 0
        && bitrate != 0xf
        && sample_rate != 0x3
}

fn classify_ogg_stream(bytes: &[u8]) -> DetectedFormat {
    if bytes.len() < 27 || bytes.get(4) != Some(&0) {
        return DetectedFormat::Ogg;
    }
    let segment_count = usize::from(bytes[26]);
    let payload_start = 27_usize.saturating_add(segment_count);
    let Some(payload) = bytes.get(payload_start..) else {
        return DetectedFormat::Ogg;
    };
    if payload.starts_with(b"OpusHead")
        || payload.starts_with(b"\x01vorbis")
        || payload.starts_with(b"Speex   ")
        || payload.starts_with(b"fLaC")
    {
        DetectedFormat::OggAudio
    } else if payload.starts_with(b"\x80theora") {
        DetectedFormat::OggVideo
    } else {
        DetectedFormat::Ogg
    }
}

fn extension_hint(name: &str) -> Option<String> {
    let lower = name.to_ascii_lowercase();
    for compound in ["tar.gz", "tar.bz2", "tar.xz"] {
        if lower.ends_with(compound) {
            return Some(compound.to_string());
        }
    }
    Path::new(&lower)
        .extension()
        .and_then(|extension| extension.to_str())
        .filter(|extension| !extension.is_empty())
        .map(str::to_string)
}

fn format_from_extension(extension: &str) -> Option<DetectedFormat> {
    Some(
        match extension
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str()
        {
            "txt" | "log" | "rst" | "yaml" | "yml" | "toml" | "ini" | "cfg" | "conf" | "tex"
            | "bib" | "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "rs" | "go" | "py"
            | "rb" | "php" | "swift" | "kt" | "kts" | "java" | "scala" | "sh" | "bash" | "zsh"
            | "fish" | "ps1" | "sql" | "js" | "jsx" | "ts" | "tsx" | "css" | "scss" | "less"
            | "properties" | "env" => DetectedFormat::PlainText,
            "md" | "markdown" => DetectedFormat::Markdown,
            "rtf" => DetectedFormat::RichText,
            "vtt" => DetectedFormat::WebVtt,
            "srt" => DetectedFormat::SubRip,
            "json" => DetectedFormat::Json,
            "csv" => DetectedFormat::Csv,
            "tsv" => DetectedFormat::Tsv,
            "html" | "htm" => DetectedFormat::Html,
            "xml" => DetectedFormat::Xml,
            "svg" => DetectedFormat::Svg,
            "ipynb" => DetectedFormat::JupyterNotebook,
            "pdf" => DetectedFormat::Pdf,
            "docx" => DetectedFormat::Docx,
            "pptx" => DetectedFormat::Pptx,
            "xlsx" => DetectedFormat::Xlsx,
            "epub" => DetectedFormat::Epub,
            "odt" => DetectedFormat::OpenDocumentText,
            "ods" => DetectedFormat::OpenDocumentSpreadsheet,
            "odp" => DetectedFormat::OpenDocumentPresentation,
            "pages" => DetectedFormat::IWorkPages,
            "numbers" => DetectedFormat::IWorkNumbers,
            "key" | "keynote" => DetectedFormat::IWorkKeynote,
            "doc" | "xls" | "ppt" | "msg" => DetectedFormat::OleCompound,
            "eml" => DetectedFormat::Email,
            "mbox" => DetectedFormat::Mbox,
            "zip" => DetectedFormat::Zip,
            "tar" => DetectedFormat::Tar,
            "gz" | "gzip" | "tgz" | "tar.gz" => DetectedFormat::Gzip,
            "bz2" | "tbz2" | "tar.bz2" => DetectedFormat::Bzip2,
            "xz" | "txz" | "tar.xz" => DetectedFormat::Xz,
            "zst" | "zstd" => DetectedFormat::Zstd,
            "7z" => DetectedFormat::SevenZip,
            "rar" => DetectedFormat::Rar,
            "png" => DetectedFormat::Png,
            "jpg" | "jpeg" => DetectedFormat::Jpeg,
            "gif" => DetectedFormat::Gif,
            "webp" => DetectedFormat::Webp,
            "bmp" => DetectedFormat::Bmp,
            "tif" | "tiff" => DetectedFormat::Tiff,
            "heif" | "heic" => DetectedFormat::Heif,
            "avif" => DetectedFormat::Avif,
            "wav" => DetectedFormat::Wav,
            "aif" | "aiff" | "aifc" => DetectedFormat::Aiff,
            "caf" => DetectedFormat::Caf,
            "flac" => DetectedFormat::Flac,
            "mp3" => DetectedFormat::Mp3,
            "ogg" => DetectedFormat::Ogg,
            "oga" | "opus" => DetectedFormat::OggAudio,
            "ogv" => DetectedFormat::OggVideo,
            "m4a" | "m4b" => DetectedFormat::M4a,
            "mp4" | "m4v" => DetectedFormat::Mp4,
            "mov" => DetectedFormat::QuickTime,
            "mkv" => DetectedFormat::Matroska,
            "webm" => DetectedFormat::Webm,
            "avi" => DetectedFormat::Avi,
            "exe" | "dll" | "elf" | "dylib" | "so" => DetectedFormat::Executable,
            _ => return None,
        },
    )
}

fn format_from_media_type(media_type: &str) -> Option<DetectedFormat> {
    Some(
        match media_type
            .split(';')
            .next()?
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "text/plain" => DetectedFormat::PlainText,
            "text/markdown" => DetectedFormat::Markdown,
            "application/rtf" | "text/rtf" => DetectedFormat::RichText,
            "text/vtt" => DetectedFormat::WebVtt,
            "application/x-subrip" => DetectedFormat::SubRip,
            "application/json" => DetectedFormat::Json,
            "text/csv" => DetectedFormat::Csv,
            "text/tab-separated-values" => DetectedFormat::Tsv,
            "text/html" => DetectedFormat::Html,
            "application/xml" | "text/xml" => DetectedFormat::Xml,
            "image/svg+xml" => DetectedFormat::Svg,
            "application/x-ipynb+json" => DetectedFormat::JupyterNotebook,
            "application/pdf" => DetectedFormat::Pdf,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => {
                DetectedFormat::Docx
            }
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" => {
                DetectedFormat::Pptx
            }
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => {
                DetectedFormat::Xlsx
            }
            "application/epub+zip" => DetectedFormat::Epub,
            "application/vnd.oasis.opendocument.text" => DetectedFormat::OpenDocumentText,
            "application/vnd.oasis.opendocument.spreadsheet" => {
                DetectedFormat::OpenDocumentSpreadsheet
            }
            "application/vnd.oasis.opendocument.presentation" => {
                DetectedFormat::OpenDocumentPresentation
            }
            "application/vnd.apple.pages" => DetectedFormat::IWorkPages,
            "application/vnd.apple.numbers" => DetectedFormat::IWorkNumbers,
            "application/vnd.apple.keynote" => DetectedFormat::IWorkKeynote,
            "application/x-ole-storage"
            | "application/msword"
            | "application/vnd.ms-excel"
            | "application/vnd.ms-powerpoint" => DetectedFormat::OleCompound,
            "message/rfc822" => DetectedFormat::Email,
            "application/mbox" => DetectedFormat::Mbox,
            "application/zip" => DetectedFormat::Zip,
            "application/x-tar" => DetectedFormat::Tar,
            "application/gzip" => DetectedFormat::Gzip,
            "application/x-bzip2" => DetectedFormat::Bzip2,
            "application/x-xz" => DetectedFormat::Xz,
            "application/zstd" => DetectedFormat::Zstd,
            "application/x-7z-compressed" => DetectedFormat::SevenZip,
            "application/vnd.rar" | "application/x-rar-compressed" => DetectedFormat::Rar,
            "image/png" => DetectedFormat::Png,
            "image/jpeg" => DetectedFormat::Jpeg,
            "image/gif" => DetectedFormat::Gif,
            "image/webp" => DetectedFormat::Webp,
            "image/bmp" => DetectedFormat::Bmp,
            "image/tiff" => DetectedFormat::Tiff,
            "image/heif" | "image/heic" => DetectedFormat::Heif,
            "image/avif" => DetectedFormat::Avif,
            "audio/wav" | "audio/x-wav" => DetectedFormat::Wav,
            "audio/aiff" | "audio/x-aiff" => DetectedFormat::Aiff,
            "audio/x-caf" => DetectedFormat::Caf,
            "audio/flac" => DetectedFormat::Flac,
            "audio/mpeg" => DetectedFormat::Mp3,
            "application/ogg" => DetectedFormat::Ogg,
            "audio/ogg" | "audio/opus" => DetectedFormat::OggAudio,
            "video/ogg" => DetectedFormat::OggVideo,
            "audio/mp4" | "audio/x-m4a" => DetectedFormat::M4a,
            "video/mp4" => DetectedFormat::Mp4,
            "video/quicktime" => DetectedFormat::QuickTime,
            "video/x-matroska" => DetectedFormat::Matroska,
            "video/webm" => DetectedFormat::Webm,
            "video/x-msvideo" => DetectedFormat::Avi,
            "application/octet-stream" => DetectedFormat::UnknownBinary,
            _ => return None,
        },
    )
}

fn push_candidate(
    candidates: &mut Vec<FormatCandidate>,
    format: DetectedFormat,
    confidence: DetectionConfidence,
    evidence: DetectionEvidence,
    offset: u64,
) {
    if candidates.iter().any(|candidate| {
        candidate.format == format
            && candidate.confidence == confidence
            && candidate.evidence == evidence
            && candidate.offset == offset
    }) {
        return;
    }
    candidates.push(FormatCandidate {
        format,
        confidence,
        evidence,
        offset,
    });
}

const fn confidence_rank(confidence: DetectionConfidence) -> u8 {
    match confidence {
        DetectionConfidence::ParserConfirmed => 0,
        DetectionConfidence::StrongSignature => 1,
        DetectionConfidence::Probable => 2,
        DetectionConfidence::HintOnly => 3,
    }
}

fn formats_compatible(hint: DetectedFormat, detected: DetectedFormat) -> bool {
    hint == detected
        || matches!(
            (hint, detected),
            (DetectedFormat::PlainText, DetectedFormat::Markdown)
                | (DetectedFormat::PlainText, DetectedFormat::Csv)
                | (DetectedFormat::PlainText, DetectedFormat::Tsv)
                | (DetectedFormat::Json, DetectedFormat::JupyterNotebook)
                | (DetectedFormat::Zip, DetectedFormat::Docx)
                | (DetectedFormat::Zip, DetectedFormat::Pptx)
                | (DetectedFormat::Zip, DetectedFormat::Xlsx)
                | (DetectedFormat::Zip, DetectedFormat::Epub)
                | (DetectedFormat::Zip, DetectedFormat::OpenDocumentText)
                | (DetectedFormat::Zip, DetectedFormat::OpenDocumentSpreadsheet)
                | (
                    DetectedFormat::Zip,
                    DetectedFormat::OpenDocumentPresentation
                )
                | (DetectedFormat::Zip, DetectedFormat::IWorkPages)
                | (DetectedFormat::Zip, DetectedFormat::IWorkNumbers)
                | (DetectedFormat::Zip, DetectedFormat::IWorkKeynote)
                | (DetectedFormat::Ogg, DetectedFormat::OggAudio)
                | (DetectedFormat::Ogg, DetectedFormat::OggVideo)
                | (DetectedFormat::Mp4, DetectedFormat::M4a)
        )
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

pub(crate) fn looks_like_email_bytes(bytes: &[u8]) -> bool {
    let prefix = &bytes[..bytes.len().min(8192)];
    looks_like_email(&String::from_utf8_lossy(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_override_a_lying_extension() {
        let detection = detect(
            "portrait.txt",
            Some("text/plain"),
            b"\x89PNG\r\n\x1a\nfixture",
        );
        assert_eq!(detection.selected, Some(DetectedFormat::Png));
        assert!(detection.mismatch.is_some());
    }

    #[test]
    fn text_subtypes_remain_structural_hints() {
        let detection = detect("notes.md", None, b"# Heading\n\nBody");
        assert_eq!(detection.selected, Some(DetectedFormat::Markdown));
    }

    #[test]
    fn zip_family_is_refined_by_member_structure() {
        let format = classify_zip_members(
            ["[Content_Types].xml", "word/document.xml"].into_iter(),
            None,
        );
        assert_eq!(format, DetectedFormat::Docx);
    }

    #[test]
    fn ambiguous_container_media_is_not_promoted_to_the_wrong_family() {
        let unknown = detect(
            "clip.ogg",
            None,
            b"OggS\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        );
        assert_eq!(unknown.selected, Some(DetectedFormat::Ogg));

        let mut opus = vec![0_u8; 28];
        opus[..4].copy_from_slice(b"OggS");
        opus[26] = 1;
        opus[27] = 8;
        opus.extend_from_slice(b"OpusHead");
        let audio = detect("clip.ogg", None, &opus);
        assert_eq!(audio.selected, Some(DetectedFormat::OggAudio));
    }

    #[test]
    fn open_document_requires_container_structure_and_a_matching_hint() {
        let format = classify_zip_members(
            ["content.xml", "styles.xml", "META-INF/manifest.xml"].into_iter(),
            Some("odt"),
        );
        assert_eq!(format, DetectedFormat::OpenDocumentText);
        let ambiguous = classify_zip_members(
            ["content.xml", "styles.xml", "META-INF/manifest.xml"].into_iter(),
            None,
        );
        assert_eq!(ambiguous, DetectedFormat::Zip);
    }

    #[test]
    fn java_macho_prefix_is_not_claimed_as_one_certain_format() {
        let detection = detect("ambiguous.bin", None, b"\xca\xfe\xba\xbefixture");
        assert_eq!(detection.selected, Some(DetectedFormat::Executable));
    }
}
