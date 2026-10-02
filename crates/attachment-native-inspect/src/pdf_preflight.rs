//! Allocation-free PDF structural allocation preflight.
//!
//! This is not a PDF validator. It rejects obviously over-wide object and
//! cross-reference declarations before `lopdf` is allowed to materialize its
//! object maps. Strict parsing remains authoritative after this gate.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PdfPreflight {
    pub(crate) object_declarations: u32,
    pub(crate) xref_entries: u64,
    pub(crate) potential_embedded_files: u32,
    pub(crate) metadata_bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PdfPreflightError {
    pub(crate) code: &'static str,
    pub(crate) message: &'static str,
}

pub(crate) fn preflight(
    bytes: &[u8],
    max_objects: u32,
    max_entries: u32,
    max_metadata_bytes: u64,
) -> Result<PdfPreflight, PdfPreflightError> {
    let object_declarations = count_object_declarations(bytes, max_objects)?;
    let mut xref_entries = 0_u64;
    let mut metadata_bytes = 0_u64;
    let mut in_xref = false;
    let mut cursor = 0_usize;

    while cursor < bytes.len() {
        let start = cursor;
        while cursor < bytes.len() && bytes[cursor] != b'\n' && bytes[cursor] != b'\r' {
            cursor += 1;
        }
        while cursor < bytes.len() && matches!(bytes[cursor], b'\n' | b'\r') {
            cursor += 1;
        }
        let raw = &bytes[start..cursor];
        let line = trim_ascii(raw);
        if line == b"xref" {
            in_xref = true;
        } else if in_xref && (line.starts_with(b"trailer") || line.starts_with(b"startxref")) {
            in_xref = false;
        }

        if contains_object_header(line) {
            metadata_bytes = checked_metadata(metadata_bytes, raw.len(), max_metadata_bytes)?;
        }

        if in_xref {
            metadata_bytes = checked_metadata(metadata_bytes, raw.len(), max_metadata_bytes)?;
            if let Some(count) = xref_subsection_count(line) {
                xref_entries = xref_entries.checked_add(count).ok_or(limit_error(
                    "pdf_xref_count_overflow",
                    "The PDF cross-reference count cannot be represented safely.",
                ))?;
                if xref_entries > u64::from(max_objects) {
                    return Err(limit_error(
                        "pdf_xref_object_limit_exceeded",
                        "The PDF cross-reference table declares more objects than the remaining global object budget. It was not parsed.",
                    ));
                }
            }
        }
    }

    let xref_size = if has_name_pair(bytes, b"/Type", b"/XRef") {
        maximum_name_integer(bytes, b"/Size")?
    } else {
        0
    };
    if xref_size > u64::from(max_objects) {
        return Err(limit_error(
            "pdf_xref_object_limit_exceeded",
            "A PDF cross-reference stream declares more objects than the remaining global object budget. It was not parsed.",
        ));
    }
    xref_entries = xref_entries.max(xref_size);

    let potential_embedded_files =
        count_name(bytes, b"/Filespec").max(count_name(bytes, b"/EmbeddedFile"));
    if potential_embedded_files > max_entries {
        return Err(limit_error(
            "archive_entry_limit_exceeded",
            "The PDF declares more potential embedded files than the remaining global entry budget. It was not parsed.",
        ));
    }

    Ok(PdfPreflight {
        object_declarations,
        xref_entries,
        potential_embedded_files,
        metadata_bytes,
    })
}

fn count_object_declarations(bytes: &[u8], limit: u32) -> Result<u32, PdfPreflightError> {
    let mut count = 0_u32;
    let mut previous_number = false;
    let mut two_numbers = false;
    let mut cursor = 0_usize;
    while let Some(token) = next_pdf_token(bytes, &mut cursor) {
        if token == b"obj" && two_numbers {
            count = count.checked_add(1).ok_or(limit_error(
                "pdf_object_count_overflow",
                "The PDF object count cannot be represented safely.",
            ))?;
            if count > limit {
                return Err(limit_error(
                    "pdf_object_limit_exceeded",
                    "The PDF declares more objects than the remaining global object budget. It was not parsed.",
                ));
            }
            previous_number = false;
            two_numbers = false;
            continue;
        }
        let number = parse_u64(token).is_some();
        two_numbers = previous_number && number;
        previous_number = number;
    }
    Ok(count)
}

fn next_pdf_token<'a>(bytes: &'a [u8], cursor: &mut usize) -> Option<&'a [u8]> {
    loop {
        while bytes
            .get(*cursor)
            .is_some_and(|byte| byte.is_ascii_whitespace())
        {
            *cursor += 1;
        }
        if bytes.get(*cursor) != Some(&b'%') {
            break;
        }
        while bytes
            .get(*cursor)
            .is_some_and(|byte| !matches!(byte, b'\r' | b'\n'))
        {
            *cursor += 1;
        }
    }
    let start = *cursor;
    let first = *bytes.get(start)?;
    if is_pdf_delimiter(first) {
        *cursor += 1;
        return Some(&bytes[start..*cursor]);
    }
    while bytes.get(*cursor).is_some_and(|byte| {
        !byte.is_ascii_whitespace() && !is_pdf_delimiter(*byte) && *byte != b'%'
    }) {
        *cursor += 1;
    }
    (*cursor > start).then_some(&bytes[start..*cursor])
}

fn contains_object_header(line: &[u8]) -> bool {
    count_object_declarations(line, u32::MAX).is_ok_and(|count| count > 0)
}

fn xref_subsection_count(line: &[u8]) -> Option<u64> {
    let mut fields = line
        .split(u8::is_ascii_whitespace)
        .filter(|part| !part.is_empty());
    let start = fields.next()?;
    let count = fields.next()?;
    if fields.next().is_some() || parse_u64(start).is_none() {
        return None;
    }
    parse_u64(count)
}

fn maximum_name_integer(bytes: &[u8], name: &[u8]) -> Result<u64, PdfPreflightError> {
    let mut maximum = 0_u64;
    let mut cursor = 0_usize;
    while cursor + name.len() <= bytes.len() {
        if &bytes[cursor..cursor + name.len()] != name
            || bytes
                .get(cursor + name.len())
                .is_some_and(|byte| !is_pdf_separator(*byte))
        {
            cursor += 1;
            continue;
        }
        cursor += name.len();
        while bytes.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
        }
        let start = cursor;
        while bytes.get(cursor).is_some_and(u8::is_ascii_digit) {
            cursor += 1;
        }
        if cursor > start {
            let value = parse_u64(&bytes[start..cursor]).ok_or(limit_error(
                "pdf_xref_count_overflow",
                "A PDF cross-reference size cannot be represented safely.",
            ))?;
            maximum = maximum.max(value);
        }
    }
    Ok(maximum)
}

fn count_name(bytes: &[u8], name: &[u8]) -> u32 {
    let mut count = 0_u32;
    let mut cursor = 0_usize;
    while cursor + name.len() <= bytes.len() {
        if &bytes[cursor..cursor + name.len()] == name
            && bytes
                .get(cursor + name.len())
                .is_none_or(|byte| is_pdf_separator(*byte))
        {
            count = count.saturating_add(1);
            cursor += name.len();
        } else {
            cursor += 1;
        }
    }
    count
}

fn has_name_pair(bytes: &[u8], first: &[u8], second: &[u8]) -> bool {
    let mut cursor = 0_usize;
    while cursor + first.len() <= bytes.len() {
        if &bytes[cursor..cursor + first.len()] != first {
            cursor += 1;
            continue;
        }
        cursor += first.len();
        while bytes.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
        }
        if bytes.get(cursor..cursor.saturating_add(second.len())) == Some(second) {
            return true;
        }
    }
    false
}

fn checked_metadata(current: u64, additional: usize, limit: u64) -> Result<u64, PdfPreflightError> {
    let additional = u64::try_from(additional).map_err(|_| {
        limit_error(
            "pdf_metadata_length_overflow",
            "PDF structural metadata length cannot be represented safely.",
        )
    })?;
    let next = current.checked_add(additional).ok_or(limit_error(
        "pdf_metadata_length_overflow",
        "PDF structural metadata length cannot be represented safely.",
    ))?;
    if next > limit {
        return Err(limit_error(
            "pdf_metadata_limit_exceeded",
            "The PDF cross-reference and object metadata exceed the configured container-metadata limit. It was not parsed.",
        ));
    }
    Ok(next)
}

fn parse_u64(bytes: &[u8]) -> Option<u64> {
    if bytes.is_empty() {
        return None;
    }
    bytes.iter().try_fold(0_u64, |value, byte| {
        value
            .checked_mul(10)?
            .checked_add(u64::from(byte.checked_sub(b'0')?))
    })
}

fn trim_ascii(mut value: &[u8]) -> &[u8] {
    while value.first().is_some_and(u8::is_ascii_whitespace) {
        value = &value[1..];
    }
    while value.last().is_some_and(u8::is_ascii_whitespace) {
        value = &value[..value.len() - 1];
    }
    value
}

fn is_pdf_separator(byte: u8) -> bool {
    byte.is_ascii_whitespace() || is_pdf_delimiter(byte)
}

fn is_pdf_delimiter(byte: u8) -> bool {
    matches!(
        byte,
        b'/' | b'<' | b'>' | b'[' | b']' | b'(' | b')' | b'{' | b'}'
    )
}

const fn limit_error(code: &'static str, message: &'static str) -> PdfPreflightError {
    PdfPreflightError { code, message }
}

#[cfg(test)]
mod tests {
    use super::preflight;

    #[test]
    fn rejects_declared_xref_width_without_materializing_it() {
        let bytes = b"%PDF-1.7\nxref\n0 1000000\n";
        let error = preflight(bytes, 32, 32, 1024).expect_err("xref is too wide");
        assert_eq!(error.code, "pdf_xref_object_limit_exceeded");
    }

    #[test]
    fn rejects_indirect_object_width_without_materializing_it() {
        let bytes = b"%PDF-1.7\n1 0 obj\n2 0 obj\n3 0 obj\n";
        let error = preflight(bytes, 2, 8, 1024).expect_err("objects are too wide");
        assert_eq!(error.code, "pdf_object_limit_exceeded");
    }
}
