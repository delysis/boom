use attachment_native_types::AttachmentError;
use lopdf::{Dictionary, Document, Object, ObjectId as PdfObjectId, Stream};
use std::collections::BTreeSet;

const PDF_SCAN_CHECKPOINT_INTERVAL: usize = 1_024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum ActiveContent {
    JavaScript,
    LaunchAction,
    RichMedia,
}

impl ActiveContent {
    pub(crate) const fn issue(self) -> (&'static str, &'static str) {
        match self {
            Self::JavaScript => (
                "pdf_javascript_detected",
                "The PDF declares JavaScript. It was reported but never executed.",
            ),
            Self::LaunchAction => (
                "pdf_launch_action_detected",
                "The PDF declares a launch action. It was reported but never executed.",
            ),
            Self::RichMedia => (
                "pdf_rich_media_detected",
                "The PDF declares rich-media content. It was reported but never activated.",
            ),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EmbeddedFile {
    pub(crate) raw_name: Vec<u8>,
    pub(crate) stream_id: Option<PdfObjectId>,
    pub(crate) owner_id: Option<PdfObjectId>,
}

#[derive(Debug, Default)]
pub(crate) struct Scan {
    pub(crate) embedded_files: Vec<EmbeddedFile>,
    pub(crate) active_content: BTreeSet<ActiveContent>,
}

#[derive(Debug)]
pub(crate) enum ScanError {
    Deadline(AttachmentError),
    NodeLimit,
}

pub(crate) fn declared_stream_size(document: &Document, stream: &Stream) -> Option<u64> {
    let params = stream.dict.get(b"Params").ok()?;
    let (_, params) = document.dereference(params).ok()?;
    let size = params.as_dict().ok()?.get(b"Size").ok()?.as_i64().ok()?;
    u64::try_from(size).ok()
}

pub(crate) fn declared_stream_media_type(stream: &Stream) -> Option<String> {
    let name = stream.dict.get(b"Subtype").ok()?.as_name().ok()?;
    let decoded = decode_pdf_name(name);
    let media_type = String::from_utf8(decoded).ok()?;
    media_type.contains('/').then_some(media_type)
}

/// Walk indirect objects and inline dictionaries without following references.
/// Every referenced object is already present in `Document::objects`, so this
/// visits the complete loaded structure while making reference cycles inert.
pub(crate) fn scan_document(
    document: &Document,
    max_nodes: usize,
    mut check_deadline: impl FnMut() -> Result<(), AttachmentError>,
) -> Result<Scan, ScanError> {
    let mut scan = Scan::default();
    let mut stack = Vec::with_capacity(document.objects.len());
    for (object_id, object) in document.objects.iter().rev() {
        stack.push((Some(*object_id), object));
    }

    let mut visited_nodes = 0_usize;
    while let Some((owner_id, object)) = stack.pop() {
        visited_nodes = visited_nodes.checked_add(1).ok_or(ScanError::NodeLimit)?;
        if visited_nodes > max_nodes {
            return Err(ScanError::NodeLimit);
        }
        if visited_nodes.is_multiple_of(PDF_SCAN_CHECKPOINT_INTERVAL) {
            check_deadline().map_err(ScanError::Deadline)?;
        }

        match object {
            Object::Array(values) => push_inline_values(&mut stack, owner_id, values.iter()),
            Object::Dictionary(dictionary) => {
                inspect_dictionary(document, dictionary, owner_id, &mut scan);
                push_inline_values(
                    &mut stack,
                    owner_id,
                    dictionary.iter().map(|(_, value)| value),
                );
            }
            Object::Stream(stream) => {
                inspect_dictionary(document, &stream.dict, owner_id, &mut scan);
                push_inline_values(
                    &mut stack,
                    owner_id,
                    stream.dict.iter().map(|(_, value)| value),
                );
            }
            Object::Null
            | Object::Boolean(_)
            | Object::Integer(_)
            | Object::Real(_)
            | Object::Name(_)
            | Object::String(_, _)
            | Object::Reference(_) => {}
        }
    }

    scan.embedded_files.sort_by(|left, right| {
        left.raw_name
            .cmp(&right.raw_name)
            .then(left.owner_id.cmp(&right.owner_id))
            .then(left.stream_id.cmp(&right.stream_id))
    });
    Ok(scan)
}

fn push_inline_values<'a>(
    stack: &mut Vec<(Option<PdfObjectId>, &'a Object)>,
    owner_id: Option<PdfObjectId>,
    values: impl DoubleEndedIterator<Item = &'a Object>,
) {
    for value in values.rev() {
        if !matches!(value, Object::Reference(_)) {
            stack.push((owner_id, value));
        }
    }
}

fn inspect_dictionary(
    document: &Document,
    dictionary: &Dictionary,
    owner_id: Option<PdfObjectId>,
    scan: &mut Scan,
) {
    detect_active_content(dictionary, &mut scan.active_content);
    if dictionary.get(b"EF").is_ok() {
        let streams = embedded_streams(document, dictionary);
        if streams.is_empty() {
            let index = scan.embedded_files.len();
            scan.embedded_files.push(EmbeddedFile {
                raw_name: file_spec_name(document, dictionary, owner_id, index, None),
                stream_id: None,
                owner_id,
            });
        } else {
            for (key, stream_id) in streams {
                let index = scan.embedded_files.len();
                scan.embedded_files.push(EmbeddedFile {
                    raw_name: file_spec_name(document, dictionary, owner_id, index, Some(key)),
                    stream_id,
                    owner_id,
                });
            }
        }
    }
}

fn detect_active_content(dictionary: &Dictionary, active: &mut BTreeSet<ActiveContent>) {
    for (key, value) in dictionary.iter() {
        match key.as_slice() {
            b"JS" | b"JavaScript" => {
                active.insert(ActiveContent::JavaScript);
            }
            b"Launch" => {
                active.insert(ActiveContent::LaunchAction);
            }
            b"RichMedia" | b"RichMediaContent" | b"RichMediaSettings" => {
                active.insert(ActiveContent::RichMedia);
            }
            b"S" | b"Subtype" => {
                if let Object::Name(name) = value {
                    match name.as_slice() {
                        b"JavaScript" => {
                            active.insert(ActiveContent::JavaScript);
                        }
                        b"Launch" => {
                            active.insert(ActiveContent::LaunchAction);
                        }
                        b"RichMedia" => {
                            active.insert(ActiveContent::RichMedia);
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
}

fn file_spec_name(
    document: &Document,
    dictionary: &Dictionary,
    owner_id: Option<PdfObjectId>,
    index: usize,
    preferred_key: Option<&[u8]>,
) -> Vec<u8> {
    let keys = [b"UF".as_slice(), b"F", b"DOS", b"Mac", b"Unix"];
    for key in preferred_key.into_iter().chain(keys) {
        let Some(value) = dictionary
            .get(key)
            .ok()
            .and_then(|value| document.dereference(value).ok())
            .map(|(_, value)| value)
        else {
            continue;
        };
        match value {
            Object::String(bytes, _) | Object::Name(bytes) => return decode_pdf_text(bytes),
            _ => {}
        }
    }

    owner_id.map_or_else(
        || format!("pdf-embedded-inline-{index}.bin").into_bytes(),
        |(object, generation)| format!("pdf-embedded-{object}-{generation}.bin").into_bytes(),
    )
}

fn embedded_streams(
    document: &Document,
    file_spec: &Dictionary,
) -> Vec<(&'static [u8], Option<PdfObjectId>)> {
    const KEYS: [&[u8]; 5] = [b"UF", b"F", b"DOS", b"Mac", b"Unix"];
    let Some(ef_dictionary) = file_spec
        .get(b"EF")
        .ok()
        .and_then(|value| document.dereference(value).ok())
        .and_then(|(_, value)| value.as_dict().ok())
    else {
        return Vec::new();
    };

    let mut seen = BTreeSet::new();
    let mut streams = Vec::new();
    for key in KEYS {
        let Ok(value) = ef_dictionary.get(key) else {
            continue;
        };
        let Ok((object_id, object)) = document.dereference(value) else {
            streams.push((key, None));
            continue;
        };
        let stream_id = matches!(object, Object::Stream(_))
            .then_some(object_id)
            .flatten();
        if stream_id.is_none_or(|id| seen.insert(id)) {
            streams.push((key, stream_id));
        }
    }
    streams
}

fn decode_pdf_text(bytes: &[u8]) -> Vec<u8> {
    if let Some(body) = bytes.strip_prefix(&[0xfe, 0xff]) {
        return decode_utf16(body, u16::from_be_bytes);
    }
    if let Some(body) = bytes.strip_prefix(&[0xff, 0xfe]) {
        return decode_utf16(body, u16::from_le_bytes);
    }
    String::from_utf8_lossy(bytes).into_owned().into_bytes()
}

fn decode_utf16(body: &[u8], decode: fn([u8; 2]) -> u16) -> Vec<u8> {
    let units = body
        .chunks_exact(2)
        .map(|pair| decode([pair[0], pair[1]]))
        .collect::<Vec<_>>();
    String::from_utf16_lossy(&units).into_bytes()
}

fn decode_pdf_name(name: &[u8]) -> Vec<u8> {
    let mut decoded = Vec::with_capacity(name.len());
    let mut index = 0_usize;
    while index < name.len() {
        if name[index] == b'#'
            && let Some(pair) = name.get(index.saturating_add(1)..index.saturating_add(3))
            && let Ok(hex) = std::str::from_utf8(pair)
            && let Ok(byte) = u8::from_str_radix(hex, 16)
        {
            decoded.push(byte);
            index = index.saturating_add(3);
            continue;
        }
        decoded.push(name[index]);
        index = index.saturating_add(1);
    }
    decoded
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::{Object, dictionary};

    #[test]
    fn active_action_names_are_detected_without_interpreting_payloads() {
        let mut active = BTreeSet::new();
        detect_active_content(
            &dictionary! {
                "S" => Object::Name(b"JavaScript".to_vec()),
                "JS" => Object::String(b"app.alert(1)".to_vec(), lopdf::StringFormat::Literal),
                "RichMediaContent" => Object::Null,
            },
            &mut active,
        );
        assert!(active.contains(&ActiveContent::JavaScript));
        assert!(active.contains(&ActiveContent::RichMedia));
        assert!(!active.contains(&ActiveContent::LaunchAction));
    }

    #[test]
    fn utf16_file_names_become_portable_utf8_metadata() {
        let name = decode_pdf_text(&[0xfe, 0xff, 0x00, b'a', 0x00, b'.', 0x00, b't']);
        assert_eq!(name, b"a.t");
    }

    #[test]
    fn pdf_name_hex_escapes_decode_for_media_types() {
        assert_eq!(decode_pdf_name(b"application#2Fzip"), b"application/zip");
    }
}
