//! Bounded MIME traversal using the locked parser's actual header and body lexer.
//!
//! This pass builds no Message tree. Header parsing is confined to a prefix
//! admitted against the remaining raw metadata budget. Transfer decoding is
//! admitted before calling the dependency; decoded message bodies share every
//! counter. Full eager parsing runs only after this complete traversal succeeds.
//! Conservative decoded-byte admission is not an allocator/RSS guarantee.
use mail_parser::{
    ContentType, GetHeader, Header, HeaderName, HeaderValue, Message, MessageParser, PartType,
    decoders::charsets::map::charset_decoder, parsers::MessageStream,
};

const ENCODED_MESSAGE_DEPTH: usize = 3; // mail-parser 0.11.9 MAX_NESTED_ENCODED

/// Message owns child Messages by value, so ordinary field Drop recurses.
/// Drain their parts iteratively on every caller return, without a new depth
/// refusal or changing the dependency's parsed contents and classifications.
pub(crate) struct MessageOwner<'a>(Message<'a>);

impl<'a> MessageOwner<'a> {
    pub(crate) fn new(message: Message<'a>) -> Self {
        Self(message)
    }
}

impl<'a> std::ops::Deref for MessageOwner<'a> {
    type Target = Message<'a>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl Drop for MessageOwner<'_> {
    fn drop(&mut self) {
        release_parts(&mut self.0);
    }
}

fn release_parts(message: &mut Message<'_>) -> usize {
    let mut pending = std::mem::take(&mut message.parts);
    let mut released = 0;
    while let Some(mut part) = pending.pop() {
        if let PartType::Message(mut child) = std::mem::take(&mut part.body) {
            pending.append(&mut child.parts);
            // child now has no recursive bodies. Its ordinary fields, and
            // this part's headers/non-message body, are released in this scope.
        }
        released += 1;
    }
    released
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct MimePreflight {
    pub(crate) parts: u32,
    pub(crate) metadata_bytes: u64,
    pub(crate) potential_derived_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct MimePreflightError {
    pub(crate) code: &'static str,
    pub(crate) message: &'static str,
}

fn error(code: &'static str, message: &'static str) -> MimePreflightError {
    MimePreflightError { code, message }
}

fn derived_overflow() -> MimePreflightError {
    error(
        "mime_derived_length_overflow",
        "Potential MIME decoded length cannot be represented safely.",
    )
}

fn length(bytes: &[u8]) -> Result<u64, MimePreflightError> {
    u64::try_from(bytes.len()).map_err(|_| derived_overflow())
}

struct Admission<F> {
    summary: MimePreflight,
    max_parts: u32,
    max_metadata: u64,
    max_derived: u64,
    max_parser_input: u64,
    check_deadline: F,
}

impl<F: FnMut() -> bool> Admission<F> {
    fn deadline(&mut self) -> Result<(), MimePreflightError> {
        if (self.check_deadline)() {
            Ok(())
        } else {
            Err(error(
                "attachment_deadline_exceeded",
                "Email inspection exceeded its configured deadline.",
            ))
        }
    }

    fn part_room(&self) -> Result<u32, MimePreflightError> {
        self.summary.parts.checked_add(1).filter(|next| *next <= self.max_parts).ok_or_else(|| {
            error("mime_part_limit_exceeded", "The email requires more structural MIME parts than the remaining global attachment budget. It was not parsed.")
        })
    }

    fn part(&mut self) -> Result<(), MimePreflightError> {
        self.summary.parts = self.part_room()?;
        Ok(())
    }

    fn temporary(&self, bytes: u64) -> Result<(), MimePreflightError> {
        let total = self
            .summary
            .potential_derived_bytes
            .checked_add(bytes)
            .ok_or_else(derived_overflow)?;
        if total <= self.max_derived {
            Ok(())
        } else {
            Err(error(
                "mime_derived_budget_exceeded",
                "The email's decoded MIME data can exceed the remaining cumulative derived-byte budget. It was not parsed.",
            ))
        }
    }

    fn materialized(&mut self, bytes: u64) -> Result<(), MimePreflightError> {
        self.temporary(bytes)?;
        self.summary.potential_derived_bytes += bytes;
        Ok(())
    }

    fn headers<'a>(
        &mut self,
        data: &'a [u8],
        stream: &mut MessageStream<'a>,
    ) -> Result<(bool, Vec<Header<'a>>), MimePreflightError> {
        self.deadline()?;
        let remaining = self
            .max_metadata
            .saturating_sub(self.summary.metadata_bytes);
        let tail = &data[stream.offset()..];
        let cap = usize::try_from(remaining.min(length(tail)?)).map_err(|_| derived_overflow())?;
        // Parsing a bounded prefix avoids guessing folded/quoted header extent.
        // A successful end-of-headers within this prefix is identical to the
        // full stream; an incomplete prefix cannot authorize the eager parser.
        let mut header_stream = MessageStream::new(&tail[..cap]);
        let mut headers = Vec::new();
        let complete = header_stream.parse_headers(&MessageParser::default(), &mut headers);
        if !complete && cap < tail.len() {
            return Err(error(
                "mime_metadata_limit_exceeded",
                "The email's MIME headers exceed the configured container-metadata limit. It was not parsed.",
            ));
        }
        let consumed = header_stream.offset();
        self.summary.metadata_bytes = self
            .summary
            .metadata_bytes
            .checked_add(u64::try_from(consumed).map_err(|_| derived_overflow())?)
            .ok_or_else(derived_overflow)?;
        stream.skip_bytes(consumed);
        Ok((complete, headers))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Message,
    Digest,
    Multipart,
    Text,
    Binary,
}

struct Frame {
    kind: Kind,
    boundary: Option<Vec<u8>>,
}

fn kind(content_type: Option<&ContentType<'_>>, parent: Kind) -> (bool, Kind) {
    match content_type {
        Some(content_type) => match content_type.ctype() {
            "multipart" => (
                true,
                if content_type.subtype() == Some("digest") {
                    Kind::Digest
                } else {
                    Kind::Multipart
                },
            ),
            "text" => (false, Kind::Text),
            "message" if matches!(content_type.subtype(), Some("rfc822" | "global")) => {
                (false, Kind::Message)
            }
            _ => (false, Kind::Binary),
        },
        None if parent == Kind::Digest => (false, Kind::Message),
        None => (false, Kind::Text),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Encoding {
    None,
    Base64,
    QuotedPrintable,
}

fn encoding(headers: &Vec<Header<'_>>) -> Encoding {
    match headers.header_value(&HeaderName::ContentTransferEncoding) {
        Some(HeaderValue::Text(value)) if value.eq_ignore_ascii_case("base64") => Encoding::Base64,
        Some(HeaderValue::Text(value)) if value.eq_ignore_ascii_case("quoted-printable") => {
            Encoding::QuotedPrintable
        }
        _ => Encoding::None,
    }
}

pub(crate) fn preflight(
    bytes: &[u8],
    max_parts: u32,
    max_metadata_bytes: u64,
    max_potential_derived_bytes: u64,
    max_parser_input_bytes: u64,
    check_deadline: impl FnMut() -> bool,
) -> Result<MimePreflight, MimePreflightError> {
    let raw_bytes = length(bytes)?;
    let mut admission = Admission {
        summary: MimePreflight {
            parts: 0,
            metadata_bytes: 0,
            potential_derived_bytes: 0,
        },
        max_parts,
        max_metadata: max_metadata_bytes,
        max_derived: max_potential_derived_bytes,
        max_parser_input: max_parser_input_bytes,
        check_deadline,
    };
    // Retain the old root-size admission floor without multiplying every body
    // by every unrelated sibling. Actual nested materializations are charged.
    admission.temporary(raw_bytes)?;
    walk(bytes, ENCODED_MESSAGE_DEPTH, false, &mut admission)?;
    admission.summary.potential_derived_bytes =
        admission.summary.potential_derived_bytes.max(raw_bytes);
    admission.deadline()?;
    Ok(admission.summary)
}

fn walk(
    data: &[u8],
    encoded_depth: usize,
    count_root: bool,
    admission: &mut Admission<impl FnMut() -> bool>,
) -> Result<(), MimePreflightError> {
    if length(data)? > admission.max_parser_input {
        return Err(error(
            "parser_input_limit_exceeded",
            "A decoded nested email exceeds the configured structured-parser input boundary.",
        ));
    }
    let mut stream = MessageStream::new(data);
    let mut state = Frame {
        kind: Kind::Message,
        boundary: None,
    };
    // Frames are iterative for unencoded messages/multipart grouping. Every
    // inner frame requires an admitted part; only the existing root is free.
    let mut stack: Vec<(Frame, bool)> = Vec::new();
    let mut first = true;
    'outer: loop {
        admission.deadline()?;
        if stream.is_eof() {
            break;
        }
        if !first || count_root {
            admission.part()?;
        }
        first = false;
        let (complete, headers) = admission.headers(data, &mut stream)?;
        if !complete {
            break;
        }
        let body_start = stream.offset();
        let content_type = headers
            .header_value(&HeaderName::ContentType)
            .and_then(HeaderValue::as_content_type);
        let (multipart, mut mime_kind) = kind(content_type, state.kind);
        if multipart {
            if let Some(boundary) = content_type.and_then(|value| value.attribute("boundary")) {
                if stream.seek_next_part(boundary.as_bytes()) {
                    let next = Frame {
                        kind: mime_kind,
                        boundary: Some(boundary.as_bytes().to_vec()),
                    };
                    stack.push((state, false));
                    state = next;
                    stream.skip_crlf();
                    continue;
                }
                mime_kind = Kind::Text;
            } else {
                mime_kind = Kind::Binary;
            }
        }
        let encoding = encoding(&headers);
        if mime_kind == Kind::Message && encoding == Encoding::None {
            // into_owned() on an encoded ancestor can copy this source buffer;
            // malformed nested-message recovery can instead retain lossy text.
            admission.materialized(lossy_length(data)?)?;
            let next = Frame {
                kind: Kind::Message,
                boundary: state.boundary.take(),
            };
            stack.push((state, true));
            state = next;
            continue;
        }
        if mime_kind == Kind::Message && encoded_depth > 0 {
            admission.part_room()?; // A possible decoded child precedes decoding.
        }
        let boundary = state.boundary.as_deref().unwrap_or_default();
        if encoding != Encoding::None {
            let upper = if encoding == Encoding::Base64 {
                u64::try_from(stream.remaining()).map_err(|_| derived_overflow())?
            } else {
                // The real QP lexer can normalize bare LF to CRLF. Its output
                // fits raw body bytes + LF count; two bytes cover a transient
                // delimiter prefix. This preview borrows the same input.
                let mut preview = MessageStream::new(data);
                preview.skip_bytes(body_start);
                let (_, raw_body) = preview.mime_part(boundary);
                length(&raw_body)?
                    .checked_add(
                        u64::try_from(raw_body.iter().filter(|byte| **byte == b'\n').count())
                            .map_err(|_| derived_overflow())?,
                    )
                    .and_then(|value| value.checked_add(2))
                    .ok_or_else(derived_overflow)?
            };
            admission.temporary(upper)?;
        }
        let (end, mut body) = match encoding {
            Encoding::None => stream.mime_part(boundary),
            Encoding::Base64 => stream.decode_base64_mime(boundary),
            Encoding::QuotedPrintable => stream.decode_quoted_printable_mime(boundary),
        };
        admission.deadline()?;
        if end == usize::MAX {
            // Same malformed-encoding/boundary recovery positioning as parse_.
            let (end, found) = stream.seek_part_end(state.boundary.as_deref());
            body = data.get(body_start..end).unwrap_or_default().into();
            mime_kind = Kind::Text;
            if !found {
                state.boundary = None;
            }
        }
        match mime_kind {
            Kind::Message if encoded_depth > 0 => {
                admission.materialized(length(&body)?)?;
                walk(&body, encoded_depth - 1, true, admission)?;
            }
            Kind::Text => {
                let bound = if content_type
                    .and_then(|value| value.attribute("charset"))
                    .and_then(|charset| charset_decoder(charset.as_bytes()))
                    .is_some()
                {
                    // Locked single-byte/UTF decoders emit at most four UTF-8
                    // bytes per source byte; full_encoding uses the same bound.
                    length(&body)?.checked_mul(4).ok_or_else(derived_overflow)?
                } else {
                    lossy_length(&body)?
                };
                admission.materialized(bound)?;
            }
            _ => admission.materialized(length(&body)?)?,
        }
        if state.boundary.is_some() {
            'inner: loop {
                if state.kind == Kind::Message {
                    let Some((mut parent, true)) = stack.pop() else {
                        break 'outer;
                    };
                    parent.boundary = state.boundary.take();
                    state = parent;
                }
                if stream.is_multipart_end() {
                    let Some((parent, _)) = stack.pop() else {
                        break 'outer;
                    };
                    state = parent;
                    if let Some(boundary) = state.boundary.as_deref()
                        && stream.seek_next_part_offset(boundary).is_some()
                    {
                        continue 'inner;
                    }
                    break 'outer;
                }
                break 'inner;
            }
        } else if stream.is_eof() {
            break;
        }
    }
    Ok(())
}

// Exact UTF-8 lossy output length without allocating the replacement string.
fn lossy_length(mut bytes: &[u8]) -> Result<u64, MimePreflightError> {
    let mut total = 0_u64;
    loop {
        match std::str::from_utf8(bytes) {
            Ok(_) => {
                return total
                    .checked_add(length(bytes)?)
                    .ok_or_else(derived_overflow);
            }
            Err(error) => {
                total = total
                    .checked_add(
                        u64::try_from(error.valid_up_to()).map_err(|_| derived_overflow())?,
                    )
                    .and_then(|value| value.checked_add(3))
                    .ok_or_else(derived_overflow)?;
                let skipped = error.valid_up_to()
                    + error
                        .error_len()
                        .unwrap_or(bytes.len() - error.valid_up_to());
                bytes = &bytes[skipped..];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MessageOwner, lossy_length, preflight, release_parts};
    use mail_parser::{Message, MessageParser, PartType};

    fn part_count(message: &Message<'_>) -> usize {
        message
            .parts
            .iter()
            .map(|part| {
                1 + if let PartType::Message(child) = &part.body {
                    part_count(child)
                } else {
                    0
                }
            })
            .sum()
    }

    fn base64(bytes: &[u8]) -> String {
        const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut encoded = String::new();
        for chunk in bytes.chunks(3) {
            let word = (u32::from(chunk[0]) << 16)
                | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
                | u32::from(*chunk.get(2).unwrap_or(&0));
            for (shift, present) in [
                (18, true),
                (12, true),
                (6, chunk.len() > 1),
                (0, chunk.len() > 2),
            ] {
                encoded.push(if present {
                    char::from(TABLE[((word >> shift) & 63) as usize])
                } else {
                    '='
                });
            }
        }
        encoded
    }

    #[test]
    fn counts_actual_declared_parts() {
        let message = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\none\r\n--x\r\nContent-Type: text/plain\r\n\r\ntwo\r\n--x--\r\n";
        let summary = preflight(message, 2, 1024, 1024, 1024, || true).expect("bounded MIME");
        assert_eq!(summary.parts, 2);
        assert!(summary.metadata_bytes > 0);
        assert!(summary.potential_derived_bytes >= message.len() as u64);
    }

    #[test]
    fn blocks_width_before_full_structured_parsing() {
        let message = b"Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Disposition: attachment\r\n\r\na\r\n--x\r\nContent-Disposition: attachment\r\n\r\nb\r\n";
        let error = preflight(message, 1, 1024, 1024, 1024, || true).expect_err("too wide");
        assert_eq!(error.code, "mime_part_limit_exceeded");
    }

    #[test]
    fn ordinary_body_delimiter_spelling_is_not_a_declared_multipart() {
        let message = b"Subject: Authored text\r\n\r\n--chapter\r\nA sentence.\r\n--chapter--\r\n";
        assert_eq!(
            preflight(message, 0, 1024, 1024, 1024, || true)
                .expect("ordinary text")
                .parts,
            0
        );
    }

    #[test]
    fn deadline_precedes_header_materialization() {
        let error = preflight(b"Subject: small\r\n\r\nbody", 4, 1024, 1024, 1024, || false)
            .expect_err("expired");
        assert_eq!(error.code, "attachment_deadline_exceeded");
    }

    #[test]
    fn lossy_length_matches_standard_utf8_replacement_bytes() {
        for bytes in [
            &b"e\xcc\x81 \xf0\x9f\xa7\x91"[..],
            &b"\xff\x80\xe0\xa0"[..],
            &b"\xf0\x9f"[..],
            &b""[..],
        ] {
            assert_eq!(
                lossy_length(bytes).expect("small length"),
                String::from_utf8_lossy(bytes).len() as u64
            );
        }
    }

    #[test]
    fn actual_nested_chain_is_unchanged_and_all_parts_are_released_iteratively() {
        let mut bytes = b"Subject: leaf\r\n\r\nAuthored leaf.\r\n".to_vec();
        for level in 0..8 {
            bytes = format!(
                "Subject: layer {level}\r\nContent-Type: message/rfc822\r\n\r\n{}",
                String::from_utf8_lossy(&bytes)
            )
            .into_bytes();
        }
        let parsed = MessageParser::default()
            .parse(&bytes)
            .expect("real nested-chain parser");
        let expected_parts = part_count(&parsed);
        assert_eq!(expected_parts, 9);
        let summary =
            preflight(&bytes, 8, 16_384, 32_768, 4096, || true).expect("all chain parts admitted");
        assert_eq!(summary.parts as usize + 1, expected_parts);
        let before = parsed.clone();
        let mut owner = MessageOwner::new(parsed);
        assert_eq!(*owner, before); // Contents, offsets, headers and classifications.
        assert_eq!(release_parts(&mut owner.0), expected_parts);
        assert!(owner.parts.is_empty());
        assert_eq!(release_parts(&mut owner.0), 0); // Nothing is released twice.
        drop(owner); // The automatic owner path also handles an empty forest.
        drop(MessageOwner::new(before)); // Exercise automatic release of the real chain too.
    }

    #[test]
    fn encoded_depth_matches_the_dependency_instead_of_truncating_earlier() {
        let mut bytes = b"Subject: leaf\r\n\r\nAuthored leaf.\r\n".to_vec();
        for _ in 0..4 {
            bytes = format!(
                "Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64\r\n\r\n{}",
                base64(&bytes)
            )
            .into_bytes();
        }
        let parsed = MessageParser::default()
            .parse(&bytes)
            .expect("actual encoded depth policy");
        let summary =
            preflight(&bytes, 32, 16_384, 32_768, 4096, || true).expect("bounded encoded depth");
        assert_eq!(summary.parts as usize + 1, part_count(&parsed));
        assert_eq!(part_count(&parsed), 4);
        let owner = MessageOwner::new(parsed);
        assert_eq!(part_count(&owner), 4);
    }

    #[test]
    fn deadline_is_rechecked_during_structural_traversal() {
        let message = b"Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\none\r\n--x\r\nContent-Type: text/plain\r\n\r\ntwo\r\n--x--\r\n";
        let mut checks = 0;
        let error = preflight(message, 2, 1024, 1024, 1024, || {
            checks += 1;
            checks <= 4
        })
        .expect_err("expired during traversal");
        assert_eq!(error.code, "attachment_deadline_exceeded");
        assert_eq!(checks, 5);
    }
}
