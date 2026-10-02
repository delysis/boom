//! Bounded RTF text projection. Embedded objects and field instructions are
//! never evaluated. Unsupported encodings fail instead of fabricating prose.
use crate::{BoundedText, DocumentLimits, ProcessorFailure, RenderResult, RenderedDocument};
use attachment_native_types::TextFormat;

#[derive(Clone, Copy, Default)]
struct Group {
    skip: bool,
    hidden: bool,
    unicode_fallback: usize,
}

pub(crate) fn canonicalize(
    bytes: &[u8],
    limits: &DocumentLimits,
    max_output: usize,
) -> RenderResult {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "rtf_input_limit",
            "The RTF exceeds the parser input limit.",
        ));
    }
    if !bytes.starts_with(b"{\\rtf1") {
        return Err(invalid("The RTF header is unsupported."));
    }
    let mut groups = Vec::new();
    let mut group = Group {
        skip: false,
        hidden: false,
        unicode_fallback: 1,
    };
    let mut output = BoundedText::new(max_output);
    let mut index = 0usize;
    let mut skip_fallback = 0usize;
    let mut surrogate = None;
    let mut omitted = false;
    while index < bytes.len() {
        let byte = bytes[index];
        index += 1;
        match byte {
            b'{' => {
                if groups.len() >= limits.max_xml_depth as usize {
                    return Err(invalid("The RTF group nesting exceeds the parser limit."));
                }
                groups.push(group);
            }
            b'}' => {
                group = groups
                    .pop()
                    .ok_or_else(|| invalid("The RTF contains an unmatched closing group."))?;
            }
            b'\r' | b'\n' => {}
            b'\\' => {
                let control = *bytes
                    .get(index)
                    .ok_or_else(|| invalid("The RTF ends inside an escape."))?;
                index += 1;
                match control {
                    b'\\' | b'{' | b'}' => emit_byte(
                        control,
                        group.skip || group.hidden,
                        &mut skip_fallback,
                        &mut output,
                    ),
                    b'\'' => {
                        let hex = bytes
                            .get(index..index + 2)
                            .ok_or_else(|| invalid("The RTF contains a truncated hex escape."))?;
                        let value = u8::from_str_radix(
                            std::str::from_utf8(hex)
                                .map_err(|_| invalid("Invalid RTF hex escape."))?,
                            16,
                        )
                        .map_err(|_| invalid("Invalid RTF hex escape."))?;
                        index += 2;
                        emit_byte(
                            value,
                            group.skip || group.hidden,
                            &mut skip_fallback,
                            &mut output,
                        );
                    }
                    b'*' => {
                        group.skip = true;
                        omitted = true;
                    }
                    b'~' => emit_char(
                        '\u{a0}',
                        group.skip || group.hidden,
                        &mut skip_fallback,
                        &mut output,
                    ),
                    b'_' => emit_char(
                        '\u{2011}',
                        group.skip || group.hidden,
                        &mut skip_fallback,
                        &mut output,
                    ),
                    b'-' => {}
                    b if b.is_ascii_alphabetic() => {
                        let start = index - 1;
                        while bytes.get(index).is_some_and(u8::is_ascii_alphabetic) {
                            index += 1;
                        }
                        let word = &bytes[start..index];
                        let number_start = index;
                        if bytes.get(index) == Some(&b'-') {
                            index += 1;
                        }
                        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
                            index += 1;
                        }
                        let number = if index > number_start {
                            Some(
                                std::str::from_utf8(&bytes[number_start..index])
                                    .map_err(|_| invalid("Invalid RTF number."))?
                                    .parse::<i32>()
                                    .map_err(|_| invalid("Invalid RTF number."))?,
                            )
                        } else {
                            None
                        };
                        if bytes.get(index) == Some(&b' ') {
                            index += 1;
                        }
                        match word {
                            b"fonttbl" | b"colortbl" | b"stylesheet" | b"info" => group.skip = true,
                            b"pict" | b"object" | b"fldinst" | b"datastore" => {
                                group.skip = true;
                                omitted = true;
                            }
                            b"v" => {
                                group.hidden = number != Some(0);
                                omitted = true;
                            }
                            b"mac" | b"pc" | b"pca" => {
                                return Err(invalid("Only ANSI/Unicode RTF is supported."));
                            }
                            b"ansicpg" if number != Some(1252) => {
                                return Err(invalid(
                                    "This RTF code page is unsupported; export UTF-8 or DOCX.",
                                ));
                            }
                            b"uc" => {
                                group.unicode_fallback = usize::try_from(number.unwrap_or(1))
                                    .ok()
                                    .filter(|n| *n <= 16)
                                    .ok_or_else(|| {
                                        invalid("Invalid RTF Unicode fallback length.")
                                    })?;
                            }
                            b"u" => {
                                let unit = number
                                    .filter(|n| (-32768..=65535).contains(n))
                                    .ok_or_else(|| invalid("Invalid RTF Unicode escape."))?
                                    as u16;
                                if !group.skip && !group.hidden {
                                    if (0xd800..=0xdbff).contains(&unit) {
                                        if surrogate.replace(unit).is_some() {
                                            return Err(invalid("Unpaired RTF Unicode surrogate."));
                                        }
                                    } else if let Some(high) = surrogate.take() {
                                        if !(0xdc00..=0xdfff).contains(&unit) {
                                            return Err(invalid("Unpaired RTF Unicode surrogate."));
                                        }
                                        let scalar = 0x10000
                                            + ((u32::from(high) - 0xd800) << 10)
                                            + u32::from(unit)
                                            - 0xdc00;
                                        push_char(
                                            &mut output,
                                            char::from_u32(scalar).ok_or_else(|| {
                                                invalid("Invalid RTF Unicode scalar.")
                                            })?,
                                        );
                                    } else {
                                        push_char(
                                            &mut output,
                                            char::from_u32(u32::from(unit)).ok_or_else(|| {
                                                invalid("Unpaired RTF Unicode surrogate.")
                                            })?,
                                        );
                                    }
                                }
                                skip_fallback = group.unicode_fallback;
                            }
                            b"bin" => {
                                let length = usize::try_from(number.unwrap_or(-1))
                                    .map_err(|_| invalid("Invalid RTF binary length."))?;
                                index = index
                                    .checked_add(length)
                                    .filter(|end| *end <= bytes.len())
                                    .ok_or_else(|| invalid("Truncated RTF binary data."))?;
                                omitted = true;
                            }
                            b"par" | b"line" | b"row" => emit_char(
                                '\n',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"tab" | b"cell" => emit_char(
                                '\t',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"emdash" => emit_char(
                                '—',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"endash" => emit_char(
                                '–',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"bullet" => emit_char(
                                '•',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"lquote" => emit_char(
                                '‘',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"rquote" => emit_char(
                                '’',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"ldblquote" => emit_char(
                                '“',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            b"rdblquote" => emit_char(
                                '”',
                                group.skip || group.hidden,
                                &mut skip_fallback,
                                &mut output,
                            ),
                            _ => {}
                        }
                    }
                    _ => return Err(invalid("Unsupported RTF escape.")),
                }
            }
            _ if groups.is_empty() && !byte.is_ascii_whitespace() => {
                return Err(invalid("Text outside the RTF root group."));
            }
            _ => emit_byte(
                byte,
                group.skip || group.hidden,
                &mut skip_fallback,
                &mut output,
            ),
        }
    }
    if !groups.is_empty() || surrogate.is_some() {
        return Err(invalid("The RTF is truncated or has unpaired Unicode."));
    }
    let truncated = output.was_truncated();
    let mut document = RenderedDocument::document(TextFormat::Plain, output.into_string());
    document.output_budget_exhausted = truncated;
    if omitted {
        document.record_issue(ProcessorFailure::partial("rtf_nontext_omitted", "RTF hidden text, ignorable destinations, embedded media, or field instructions were omitted; no object was executed."));
    }
    Ok(Some(document))
}

fn emit_byte(byte: u8, skip: bool, fallback: &mut usize, output: &mut BoundedText) {
    const CP1252: [char; 32] = [
        '€', '\u{81}', '‚', 'ƒ', '„', '…', '†', '‡', 'ˆ', '‰', 'Š', '‹', 'Œ', '\u{8d}', 'Ž',
        '\u{8f}', '\u{90}', '‘', '’', '“', '”', '•', '–', '—', '˜', '™', 'š', '›', 'œ', '\u{9d}',
        'ž', 'Ÿ',
    ];
    let character = if (0x80..=0x9f).contains(&byte) {
        CP1252[usize::from(byte - 0x80)]
    } else {
        char::from(byte)
    };
    emit_char(character, skip, fallback, output);
}

fn emit_char(character: char, skip: bool, fallback: &mut usize, output: &mut BoundedText) {
    if *fallback > 0 {
        *fallback -= 1;
    } else if !skip {
        push_char(output, character);
    }
}

fn push_char(output: &mut BoundedText, character: char) {
    output.push(character.encode_utf8(&mut [0; 4]));
}
fn invalid(message: &str) -> ProcessorFailure {
    ProcessorFailure::malformed("rtf_invalid", message)
}
