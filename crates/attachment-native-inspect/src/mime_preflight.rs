//! Allocation-free conservative MIME width and metadata preflight.
//!
//! `mail-parser` builds a message tree and decodes transfer encodings eagerly.
//! This pass walks the caller-owned input in place first. It deliberately
//! treats every syntactically plausible MIME delimiter as a part boundary: a
//! false positive blocks a strange message, while an under-count could hand an
//! attacker an unbounded parser allocation.

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

pub(crate) fn preflight(
    bytes: &[u8],
    max_parts: u32,
    max_metadata_bytes: u64,
    max_potential_derived_bytes: u64,
) -> Result<MimePreflight, MimePreflightError> {
    let mut parts = 0_u32;
    let mut metadata_bytes = 0_u64;
    let mut potential_derived_bytes = 0_u64;
    let mut in_headers = true;
    let mut in_part_body = false;
    let mut cursor = 0_usize;

    while cursor < bytes.len() {
        let line_start = cursor;
        while cursor < bytes.len() && bytes[cursor] != b'\n' {
            cursor += 1;
        }
        if cursor < bytes.len() {
            cursor += 1;
        }
        let line_with_ending = &bytes[line_start..cursor];
        let line = trim_line_ending(line_with_ending);

        if let Some(closing) = plausible_boundary_line(line) {
            if closing {
                in_headers = false;
                in_part_body = false;
            } else {
                parts = parts.checked_add(1).ok_or(MimePreflightError {
                    code: "mime_part_count_overflow",
                    message: "The MIME part count cannot be represented safely.",
                })?;
                if parts > max_parts {
                    return Err(MimePreflightError {
                        code: "mime_part_limit_exceeded",
                        message: "The email declares more potential MIME parts than the remaining global attachment budget. It was not parsed.",
                    });
                }
                in_headers = true;
                in_part_body = false;
            }
            continue;
        }

        let line_bytes = u64::try_from(line_with_ending.len()).map_err(|_| MimePreflightError {
            code: "mime_metadata_length_overflow",
            message: "MIME metadata length cannot be represented safely.",
        })?;
        if in_headers {
            metadata_bytes = metadata_bytes
                .checked_add(line_bytes)
                .ok_or(MimePreflightError {
                    code: "mime_metadata_length_overflow",
                    message: "MIME metadata length cannot be represented safely.",
                })?;
            if metadata_bytes > max_metadata_bytes {
                return Err(MimePreflightError {
                    code: "mime_metadata_limit_exceeded",
                    message: "The email's MIME headers exceed the configured container-metadata limit. It was not parsed.",
                });
            }
            if line.is_empty() {
                in_headers = false;
                in_part_body = parts > 0;
            }
        } else if in_part_body {
            potential_derived_bytes =
                potential_derived_bytes
                    .checked_add(line_bytes)
                    .ok_or(MimePreflightError {
                        code: "mime_derived_length_overflow",
                        message: "Potential MIME decoded length cannot be represented safely.",
                    })?;
            if potential_derived_bytes > max_potential_derived_bytes {
                return Err(MimePreflightError {
                    code: "mime_derived_budget_exceeded",
                    message: "The email's encoded MIME bodies can exceed the remaining cumulative derived-byte budget. It was not decoded.",
                });
            }
        }
    }

    // `mail-parser` can retain both nested message bodies and their decoded
    // descendants. The raw size times the number of structural parts is a
    // deliberately conservative, allocation-free upper bound on that eager
    // materialization. Ordinary defaults leave ample room; tight policies
    // fail closed before the parser rather than guessing which nested copies
    // it will retain.
    let raw_bytes = u64::try_from(bytes.len()).map_err(|_| MimePreflightError {
        code: "mime_derived_length_overflow",
        message: "Potential MIME decoded length cannot be represented safely.",
    })?;
    let eager_upper_bound =
        raw_bytes
            .checked_mul(u64::from(parts.max(1)))
            .ok_or(MimePreflightError {
                code: "mime_derived_length_overflow",
                message: "Potential MIME decoded length cannot be represented safely.",
            })?;
    potential_derived_bytes = potential_derived_bytes.max(eager_upper_bound);
    if potential_derived_bytes > max_potential_derived_bytes {
        return Err(MimePreflightError {
            code: "mime_derived_budget_exceeded",
            message: "The email's MIME structure can exceed the remaining cumulative decoded-byte budget. It was not parsed.",
        });
    }

    Ok(MimePreflight {
        parts,
        metadata_bytes,
        potential_derived_bytes,
    })
}

fn trim_line_ending(mut line: &[u8]) -> &[u8] {
    if line.ends_with(b"\n") {
        line = &line[..line.len() - 1];
    }
    if line.ends_with(b"\r") {
        line = &line[..line.len() - 1];
    }
    line
}

fn plausible_boundary_line(line: &[u8]) -> Option<bool> {
    let line = trim_ascii_end(line);
    if line.len() < 3 || !line.starts_with(b"--") || !is_boundary_byte(line[2]) {
        return None;
    }
    let closing = line.len() >= 4 && line.ends_with(b"--");
    let token_end = if closing { line.len() - 2 } else { line.len() };
    line[2..token_end]
        .iter()
        .all(|byte| is_boundary_byte(*byte))
        .then_some(closing)
}

fn trim_ascii_end(mut value: &[u8]) -> &[u8] {
    while value.last().is_some_and(u8::is_ascii_whitespace) {
        value = &value[..value.len() - 1];
    }
    value
}

fn is_boundary_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'\'' | b'(' | b')' | b'+' | b'_' | b',' | b'-' | b'.' | b'/' | b':' | b'=' | b'?'
        )
}

#[cfg(test)]
mod tests {
    use super::preflight;

    #[test]
    fn counts_nested_potential_parts_without_allocating() {
        let message = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\none\r\n--x\r\nContent-Type: text/plain\r\n\r\ntwo\r\n--x--\r\n";
        let summary = preflight(message, 2, 1024, 1024).expect("bounded MIME");
        assert_eq!(summary.parts, 2);
        assert!(summary.metadata_bytes > 0);
        assert!(summary.potential_derived_bytes >= 10);
    }

    #[test]
    fn blocks_width_before_a_structured_parser_can_run() {
        let message = b"X: y\r\n\r\n--x\r\nContent-Disposition: attachment\r\n\r\na\r\n--x\r\nContent-Disposition: attachment\r\n\r\nb\r\n";
        let error = preflight(message, 1, 1024, 1024).expect_err("too wide");
        assert_eq!(error.code, "mime_part_limit_exceeded");
    }
}
