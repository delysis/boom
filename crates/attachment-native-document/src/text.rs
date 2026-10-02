use crate::{
    BoundedText, CanonicalizationWorkBudget, DocumentLimits, ProcessorFailure, RenderResult,
    RenderedDocument, utf8_prefix_len,
};
use attachment_native_types::{DetectedFormat, SegmentKind, TextFormat, TextSegment};
use html_to_markdown_rs::{ConversionOptions, WarningKind, convert};
use mail_parser::{Address, MessageParser};
use quick_xml::Reader;
use quick_xml::events::Event;
use serde_json::Value;
use std::collections::BTreeMap;

pub(crate) fn canonicalize_plain(
    bytes: &[u8],
    format: DetectedFormat,
    limits: &DocumentLimits,
) -> RenderResult {
    let (text, truncated) = bounded_utf8(bytes, limits.max_processor_input_bytes)?;
    let text = normalize_newlines(text.trim_start_matches('\u{feff}'));
    let mut document = RenderedDocument::document(
        if format == DetectedFormat::Markdown {
            TextFormat::Markdown
        } else {
            TextFormat::Plain
        },
        text,
    );
    if truncated {
        document.record_issue(ProcessorFailure::partial(
            "text_processor_input_limit",
            "Input text was truncated before canonicalization at the per-processor byte limit.",
        ));
    }
    Ok((!document.text.is_empty()).then_some(document))
}

pub(crate) fn canonicalize_json(
    bytes: &[u8],
    limits: &DocumentLimits,
    max_output_bytes: usize,
) -> RenderResult {
    let (text, truncated) = bounded_utf8(bytes, limits.max_processor_input_bytes)?;
    if truncated {
        return Err(ProcessorFailure::partial(
            "json_processor_input_limit",
            "The JSON exceeds the bounded parser input limit; it was not parsed from a truncated prefix.",
        ));
    }
    let value: Value = serde_json::from_str(text).map_err(|_| {
        ProcessorFailure::malformed(
            "json_parse_failed",
            "The attachment has JSON-like bytes but is not valid JSON.",
        )
    })?;
    if let Some(result) = crate::exports::conversation_export(&value, limits, max_output_bytes) {
        return result;
    }
    let pretty = serde_json::to_string_pretty(&value).map_err(|_| {
        ProcessorFailure::malformed(
            "json_render_failed",
            "The parsed JSON could not be rendered deterministically.",
        )
    })?;
    let rendered = fenced_block("json", &pretty);
    Ok(Some(RenderedDocument::document(
        TextFormat::Markdown,
        rendered,
    )))
}

pub(crate) fn canonicalize_delimited(
    bytes: &[u8],
    format: DetectedFormat,
    limits: &DocumentLimits,
    max_output_bytes: usize,
) -> RenderResult {
    let input = if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "delimited_processor_input_limit",
            "The delimited document exceeds the bounded parser input limit and was not partially parsed.",
        ));
    } else {
        bytes
    };
    let (input, linkedin_preamble) = linkedin_csv_payload(input);
    let delimiter = if format == DetectedFormat::Tsv {
        b'\t'
    } else {
        b','
    };
    let conservative_cells = input
        .iter()
        .filter(|byte| **byte == delimiter)
        .count()
        .saturating_add(1);
    if u64::try_from(conservative_cells).unwrap_or(u64::MAX) > limits.max_csv_cells {
        return Err(ProcessorFailure::partial(
            "delimited_cell_limit_exceeded",
            "The delimited document exceeds the configured cell limit and was not partially parsed.",
        ));
    }
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .flexible(true)
        .delimiter(delimiter)
        .from_reader(input);
    let mut rows = Vec::new();
    let mut cells = 0_u64;
    let mut truncated = false;
    for record in reader.records() {
        if rows.len() >= usize::try_from(limits.max_csv_rows).unwrap_or(usize::MAX) {
            truncated = true;
            break;
        }
        let record = record.map_err(|_| {
            ProcessorFailure::malformed(
                "delimited_parse_failed",
                "The attachment has delimited-text-like bytes but contains malformed records.",
            )
        })?;
        let next_cells = cells.saturating_add(u64::try_from(record.len()).unwrap_or(u64::MAX));
        if next_cells > limits.max_csv_cells {
            truncated = true;
            break;
        }
        cells = next_cells;
        rows.push(record.iter().map(str::to_string).collect::<Vec<_>>());
    }
    if rows.is_empty() {
        return Ok(None);
    }
    let width = rows.iter().map(Vec::len).max().unwrap_or(0);
    let mut markdown = BoundedText::new(max_output_bytes);
    let header = markdown_row(rows.first().map(Vec::as_slice).unwrap_or_default(), width);
    let mut complete = markdown.push(&header).complete;
    let mut separator = String::from("|");
    for _ in 0..width {
        separator.push_str(" --- |");
    }
    separator.push('\n');
    if complete {
        complete = markdown.push(&separator).complete;
    }
    for row in rows.iter().skip(1) {
        if !complete {
            break;
        }
        complete = markdown.push(&markdown_row(row, width)).complete;
    }
    let output_budget_exhausted = markdown.was_truncated();
    let mut document = RenderedDocument::document(TextFormat::Markdown, markdown.into_string());
    if linkedin_preamble {
        document.warnings.push("LinkedIn's introductory Notes section was omitted. All table columns, including commentary and URL, remain separate.".to_string());
    }
    document.output_budget_exhausted = output_budget_exhausted;
    if truncated {
        document.record_issue(ProcessorFailure::partial(
            "delimited_row_or_cell_limit_exceeded",
            "Rows or cells were truncated at the configured delimited-document limit.",
        ));
    }
    Ok(Some(document))
}

fn linkedin_csv_payload(bytes: &[u8]) -> (&[u8], bool) {
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    if !bytes.starts_with(b"Notes:") {
        return (bytes, false);
    }
    let mut offset = 0;
    for line in bytes.split_inclusive(|byte| *byte == b'\n').take(64) {
        if line.starts_with(b"First Name,Last Name,") {
            return (&bytes[offset..], true);
        }
        offset += line.len();
        if offset > 8192 {
            break;
        }
    }
    (bytes, false)
}

pub(crate) fn canonicalize_html(bytes: &[u8], limits: &DocumentLimits) -> RenderResult {
    let (html, truncated) = bounded_utf8(bytes, limits.max_processor_input_bytes)?;
    let options = ConversionOptions {
        extract_metadata: false,
        extract_images: false,
        capture_svg: false,
        infer_dimensions: false,
        skip_images: true,
        max_depth: Some(limits.max_html_depth),
        compact_tables: true,
        ..ConversionOptions::default()
    };
    let result = convert(html, options).map_err(|_| {
        ProcessorFailure::malformed(
            "html_conversion_failed",
            "The HTML could not be converted safely to Markdown.",
        )
    })?;
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    for warning in result.warnings {
        match html_warning_failure(warning.kind, &warning.message) {
            Some(failure) => issues.push(failure),
            None => warnings.push(warning.message),
        }
    }
    if truncated {
        issues.push(ProcessorFailure::partial(
            "html_processor_input_limit",
            "HTML input was truncated before conversion at the per-processor byte limit.",
        ));
    }
    let Some(content) = result.content.filter(|content| !content.trim().is_empty()) else {
        return match issues.into_iter().next() {
            Some(failure) => Err(failure),
            None => Ok(None),
        };
    };
    let mut document = RenderedDocument::document(TextFormat::Markdown, content);
    document.warnings = warnings;
    for failure in issues {
        document.record_issue(failure);
    }
    if contains_ascii_case_insensitive(html.as_bytes(), b"<img") {
        document.warnings.push(
            "HTML image elements were omitted from canonical text and were not fetched."
                .to_string(),
        );
    }
    Ok(Some(document))
}

fn html_warning_failure(kind: WarningKind, message: &str) -> Option<ProcessorFailure> {
    match kind {
        WarningKind::DepthLimitExceeded => Some(ProcessorFailure::partial(
            "html_depth_limit_exceeded",
            message,
        )),
        WarningKind::TruncatedInput => Some(ProcessorFailure::partial(
            "html_conversion_input_truncated",
            message,
        )),
        WarningKind::MalformedHtml | WarningKind::EncodingFallback => Some(
            ProcessorFailure::malformed("html_best_effort_conversion", message),
        ),
        WarningKind::ImageExtractionFailed | WarningKind::SanitizationApplied => None,
    }
}

pub(crate) fn canonicalize_xml(
    bytes: &[u8],
    label: &str,
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let extracted = extract_xml_text(bytes, limits, None, work_budget)?;
    if extracted.text.trim().is_empty() {
        if let Some(failure) = extracted.issues.into_iter().next() {
            return Err(failure);
        }
        return Ok(None);
    }
    let mut output = format!("# {label}\n\n");
    output.push_str(extracted.text.trim());
    output.push('\n');
    let mut document = RenderedDocument::document(TextFormat::Markdown, output);
    document.warnings = extracted.warnings;
    document.issues = extracted.issues;
    Ok(Some(document))
}

pub(crate) fn canonicalize_notebook(
    bytes: &[u8],
    limits: &DocumentLimits,
    max_output_bytes: usize,
) -> RenderResult {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "notebook_processor_input_limit",
            "The notebook exceeds the bounded parser input limit and was not partially parsed.",
        ));
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| {
        ProcessorFailure::malformed(
            "notebook_parse_failed",
            "The attachment resembles a notebook but is not valid notebook JSON.",
        )
    })?;
    let cells = value
        .get("cells")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            ProcessorFailure::malformed(
                "notebook_cells_missing",
                "The notebook has no valid cells array.",
            )
        })?;
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# Notebook\n\n");
    let mut segments = Vec::new();
    let limit = usize::try_from(limits.max_notebook_cells).unwrap_or(usize::MAX);
    for (index, cell) in cells.iter().take(limit).enumerate() {
        let kind = cell
            .get("cell_type")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let source = json_text(cell.get("source"));
        let mut cell_output = String::new();
        match kind {
            "markdown" | "raw" => {
                cell_output.push_str(&source);
                ensure_trailing_newline(&mut cell_output);
            }
            "code" => {
                cell_output.push_str(&fenced_block("", &source));
                if let Some(outputs) = cell.get("outputs").and_then(Value::as_array) {
                    for value in outputs {
                        let rendered = notebook_output_text(value);
                        if !rendered.is_empty() {
                            cell_output.push_str("\nOutput:\n\n");
                            cell_output.push_str(&fenced_block("text", &rendered));
                        }
                    }
                }
            }
            _ => {
                cell_output.push_str(&fenced_block("text", &source));
            }
        }
        ensure_trailing_newline(&mut cell_output);
        cell_output.push('\n');
        let span = output.push(&cell_output);
        if span.end > span.start {
            segments.push(TextSegment {
                kind: SegmentKind::NotebookCell,
                label: Some(format!("Cell {} ({kind})", index + 1)),
                start_byte: span.start,
                end_byte: span.end,
                coordinates: Some(BTreeMap::from([
                    ("cell_index".to_string(), index.to_string()),
                    ("cell_type".to_string(), kind.to_string()),
                ])),
            });
        }
        if !span.complete {
            break;
        }
    }
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    if cells.len() > limit {
        let failure = ProcessorFailure::partial(
            "notebook_cell_limit_exceeded",
            "Notebook cells were truncated at the configured cell limit.",
        );
        warnings.push(failure.safe_message.clone());
        issues.push(failure);
    }
    let output_budget_exhausted = output.was_truncated();
    Ok(Some(RenderedDocument {
        format: TextFormat::Markdown,
        text: output.into_string(),
        segments,
        warnings,
        issues,
        output_budget_exhausted,
    }))
}

pub(crate) fn canonicalize_email(
    bytes: &[u8],
    limits: &DocumentLimits,
    max_output_bytes: usize,
) -> RenderResult {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "email_processor_input_limit",
            "The email exceeds the bounded parser input limit and was not partially parsed.",
        ));
    }
    let message = MessageParser::default().parse(bytes).ok_or_else(|| {
        ProcessorFailure::malformed(
            "email_parse_failed",
            "The attachment resembles an email but its MIME structure is invalid.",
        )
    })?;
    let mut header = String::from("# Email\n\n");
    let header_start = header.len();
    if let Some(from) = message.from() {
        push_email_header(&mut header, "From", &format_addresses(from));
    }
    if let Some(to) = message.to() {
        push_email_header(&mut header, "To", &format_addresses(to));
    }
    if let Some(cc) = message.cc() {
        push_email_header(&mut header, "Cc", &format_addresses(cc));
    }
    if let Some(date) = message.date() {
        push_email_header(&mut header, "Date", &date.to_string());
    }
    if let Some(message_id) = message.message_id() {
        push_email_header(&mut header, "Message-ID", message_id);
    }
    if let Some(subject) = message.subject() {
        push_email_header(&mut header, "Subject", subject.trim());
    }
    if let Some(labels) = message
        .header("X-Gmail-Labels")
        .and_then(|value| value.as_text())
    {
        push_email_header(&mut header, "Gmail labels", labels);
    }
    header.push_str("**Attachments:** ");
    header.push_str(&message.attachment_count().to_string());
    header.push_str("\n\n");
    let mut output = BoundedText::new(max_output_bytes);
    let header_span = output.push(&header);
    let header_end = header_span.end;
    let body_start = output.len();
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    let body = if let Some(body) = message.body_text(0) {
        Some(normalize_newlines(body.as_ref()))
    } else if let Some(body) = message.body_html(0) {
        let html = canonicalize_html(body.as_bytes(), limits)?;
        if let Some(mut html) = html {
            warnings.append(&mut html.warnings);
            issues.append(&mut html.issues);
            Some(html.text)
        } else {
            None
        }
    } else {
        None
    };
    if header_span.complete
        && let Some(body) = body
    {
        let body_span = output.push(&body);
        if body_span.complete {
            output.push("\n");
        }
    }
    let body_end = output.len();
    let mut segments = Vec::new();
    if header_end > header_start {
        segments.push(TextSegment {
            kind: SegmentKind::EmailHeader,
            label: Some("Message headers".to_string()),
            start_byte: header_start,
            end_byte: header_end,
            coordinates: None,
        });
    }
    if body_end > body_start {
        segments.push(TextSegment {
            kind: SegmentKind::EmailBody,
            label: Some("Message body".to_string()),
            start_byte: body_start,
            end_byte: body_end,
            coordinates: None,
        });
    }
    let output_budget_exhausted = output.was_truncated();
    Ok(Some(RenderedDocument {
        format: TextFormat::Markdown,
        text: output.into_string(),
        segments,
        warnings,
        issues,
        output_budget_exhausted,
    }))
}

fn format_addresses(addresses: &Address<'_>) -> String {
    addresses
        .iter()
        .filter_map(|address| match (address.name(), address.address()) {
            (Some(name), Some(mailbox)) => Some(format!("{name} <{mailbox}>")),
            (Some(name), None) => Some(name.to_string()),
            (None, Some(mailbox)) => Some(mailbox.to_string()),
            (None, None) => None,
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn push_email_header(output: &mut String, label: &str, value: &str) {
    output.push_str("**");
    output.push_str(label);
    output.push_str(":** ");
    output.push_str(&value.replace(['\r', '\n'], " "));
    output.push('\n');
}

type TextElementPredicate<'a> = dyn Fn(&[u8]) -> bool + 'a;

#[derive(Debug)]
pub(crate) struct ExtractedXmlText {
    pub text: String,
    pub warnings: Vec<String>,
    pub issues: Vec<ProcessorFailure>,
}

pub(crate) fn extract_xml_text(
    bytes: &[u8],
    limits: &DocumentLimits,
    accepted_text_element: Option<&TextElementPredicate<'_>>,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<ExtractedXmlText, ProcessorFailure> {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "xml_processor_input_limit",
            "An XML part exceeds the bounded parser input limit and was not partially parsed.",
        ));
    }
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(false);
    let mut output = String::new();
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    let mut events = 0_u64;
    let mut elements = Vec::new();
    let mut text_stack = Vec::new();
    loop {
        work_budget.charge_xml_event()?;
        events = events.saturating_add(1);
        if events > limits.max_xml_events {
            let failure = ProcessorFailure::partial(
                "xml_event_limit_exceeded",
                "XML traversal stopped at the configured per-part event limit.",
            );
            warnings.push(failure.safe_message.clone());
            issues.push(failure);
            break;
        }
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                validate_xml_attributes(&element)?;
                if elements.len()
                    >= usize::try_from(limits.max_xml_depth).unwrap_or(usize::MAX)
                {
                    let failure = ProcessorFailure::partial(
                        "xml_depth_limit_exceeded",
                        "XML traversal stopped at the configured depth limit.",
                    );
                    warnings.push(failure.safe_message.clone());
                    issues.push(failure);
                    break;
                }
                elements.push(element.name().as_ref().to_vec());
                let local = local_name(element.name().as_ref()).to_vec();
                text_stack.push(
                    accepted_text_element
                        .map(|predicate| predicate(&local))
                        .unwrap_or(true),
                );
                if is_xml_break_start(&local) {
                    push_space_or_newline(&mut output, '\n');
                }
            }
            Ok(Event::Empty(element)) => {
                validate_xml_attributes(&element)?;
                if is_xml_break_start(local_name(element.name().as_ref())) {
                    push_space_or_newline(&mut output, '\n');
                }
            }
            Ok(Event::End(element)) => {
                let name = element.name();
                if elements.pop().as_deref() != Some(name.as_ref()) || text_stack.is_empty() {
                    return Err(ProcessorFailure::malformed(
                        "xml_parse_failed",
                        "The attachment has XML-like bytes but contains mismatched elements.",
                    ));
                }
                let local = local_name(name.as_ref());
                if is_xml_break_end(local) {
                    push_space_or_newline(&mut output, '\n');
                }
                let _ = text_stack.pop();
            }
            Ok(Event::Text(value)) => {
                if text_stack.last().copied().unwrap_or(true) {
                    let decoded = value.xml10_content().map_err(|_| {
                        ProcessorFailure::malformed(
                            "xml_text_decode_failed",
                            "An XML text node uses an invalid character encoding.",
                        )
                    })?;
                    let unescaped = quick_xml::escape::unescape(&decoded).map_err(|_| {
                        ProcessorFailure::malformed(
                            "xml_entity_decode_failed",
                            "An XML text node contains an invalid entity reference.",
                        )
                    })?;
                    push_normalized_text(&mut output, &unescaped);
                }
            }
            Ok(Event::CData(value)) => {
                if text_stack.last().copied().unwrap_or(true) {
                    let decoded = value.decode().map_err(|_| {
                        ProcessorFailure::malformed(
                            "xml_cdata_decode_failed",
                            "An XML CDATA section uses an invalid character encoding.",
                        )
                    })?;
                    push_normalized_text(&mut output, &decoded);
                }
            }
            Ok(Event::DocType(_)) => warnings.push(
                "An XML document type declaration was ignored; external entities are never resolved."
                    .to_string(),
            ),
            Ok(Event::Eof) => {
                if !elements.is_empty() || !text_stack.is_empty() {
                    return Err(ProcessorFailure::malformed(
                        "xml_parse_failed",
                        "The attachment has XML-like bytes but contains unclosed elements.",
                    ));
                }
                break;
            }
            Ok(_) => {}
            Err(_) => {
                return Err(ProcessorFailure::malformed(
                    "xml_parse_failed",
                    "The attachment has XML-like bytes but is not well-formed XML.",
                ));
            }
        }
    }
    Ok(ExtractedXmlText {
        text: normalize_blank_lines(&output),
        warnings,
        issues,
    })
}

fn validate_xml_attributes(
    element: &quick_xml::events::BytesStart<'_>,
) -> Result<(), ProcessorFailure> {
    for attribute in element.attributes().with_checks(true) {
        let attribute = attribute.map_err(|_| {
            ProcessorFailure::malformed(
                "xml_attribute_malformed",
                "The XML contains a malformed or duplicate attribute.",
            )
        })?;
        let _ = attribute
            .normalized_value(quick_xml::XmlVersion::Implicit1_0)
            .map_err(|_| {
                ProcessorFailure::malformed(
                    "xml_attribute_malformed",
                    "The XML contains an attribute with an invalid value.",
                )
            })?;
    }
    Ok(())
}

pub(crate) fn fenced_block(language: &str, content: &str) -> String {
    let longest = longest_backtick_run(content);
    let fence = "`".repeat(longest.saturating_add(1).max(3));
    let mut output = String::new();
    output.push_str(&fence);
    output.push_str(language);
    output.push('\n');
    output.push_str(content);
    ensure_trailing_newline(&mut output);
    output.push_str(&fence);
    output.push('\n');
    output
}

fn bounded_utf8(bytes: &[u8], max_bytes: usize) -> Result<(&str, bool), ProcessorFailure> {
    let text = std::str::from_utf8(bytes).map_err(|_| {
        ProcessorFailure::malformed(
            "text_utf8_invalid",
            "The detected text attachment is not valid UTF-8.",
        )
    })?;
    if text.len() <= max_bytes {
        return Ok((text, false));
    }
    Ok((&text[..utf8_prefix_len(text, max_bytes)], true))
}

fn normalize_newlines(value: &str) -> String {
    value.replace("\r\n", "\n").replace('\r', "\n")
}

fn normalize_blank_lines(value: &str) -> String {
    let mut output = String::new();
    let mut blank = false;
    for line in value.lines() {
        let line = line.trim();
        if line.is_empty() {
            if !blank && !output.is_empty() {
                output.push('\n');
            }
            blank = true;
        } else {
            if !output.is_empty() && !output.ends_with('\n') {
                output.push('\n');
            }
            output.push_str(line);
            output.push('\n');
            blank = false;
        }
    }
    output
}

fn markdown_row(row: &[String], width: usize) -> String {
    let mut output = String::new();
    output.push('|');
    for index in 0..width {
        output.push(' ');
        if let Some(value) = row.get(index) {
            output.push_str(&escape_markdown_cell(value));
        }
        output.push_str(" |");
    }
    output.push('\n');
    output
}

fn escape_markdown_cell(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('|', "\\|")
        .replace("\r\n", "<br>")
        .replace(['\r', '\n'], "<br>")
}

fn json_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Array(values)) => values.iter().filter_map(Value::as_str).collect::<String>(),
        _ => String::new(),
    }
}

fn notebook_output_text(value: &Value) -> String {
    if let Some(text) = value.get("text") {
        return json_text(Some(text));
    }
    if let Some(data) = value.get("data").and_then(Value::as_object) {
        for key in ["text/markdown", "text/plain"] {
            if let Some(value) = data.get(key) {
                return json_text(Some(value));
            }
        }
    }
    value
        .get("ename")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_default()
}

fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

fn is_xml_break_start(name: &[u8]) -> bool {
    matches!(
        name,
        b"p" | b"div"
            | b"section"
            | b"article"
            | b"title"
            | b"h1"
            | b"h2"
            | b"h3"
            | b"h4"
            | b"h5"
            | b"h6"
            | b"li"
            | b"tr"
            | b"row"
            | b"br"
    )
}

fn is_xml_break_end(name: &[u8]) -> bool {
    is_xml_break_start(name) || matches!(name, b"tc" | b"cell")
}

fn push_normalized_text(output: &mut String, value: &str) {
    for word in value.split_whitespace() {
        if !output.is_empty() && !output.ends_with([' ', '\n']) {
            output.push(' ');
        }
        output.push_str(word);
    }
}

fn push_space_or_newline(output: &mut String, value: char) {
    if output.is_empty() {
        return;
    }
    if value == '\n' {
        while output.ends_with(' ') {
            let _ = output.pop();
        }
        if !output.ends_with('\n') {
            output.push('\n');
        }
    } else if !output.ends_with([' ', '\n']) {
        output.push(value);
    }
}

fn ensure_trailing_newline(value: &mut String) {
    if !value.ends_with('\n') {
        value.push('\n');
    }
}

fn longest_backtick_run(value: &str) -> usize {
    let mut longest = 0;
    let mut current = 0;
    for character in value.chars() {
        if character == '`' {
            current += 1;
            longest = longest.max(current);
        } else {
            current = 0;
        }
    }
    longest
}

fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| {
        window
            .iter()
            .zip(needle)
            .all(|(left, right)| left.eq_ignore_ascii_case(right))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fence_is_longer_than_any_embedded_backtick_run() {
        let result = fenced_block("markdown", "before ``` nested ```` after");
        assert!(result.starts_with("`````markdown\n"));
        assert!(result.ends_with("`````\n"));
    }

    #[test]
    fn malformed_json_is_an_explicit_failure() {
        let result = canonicalize_json(b"{not json", &DocumentLimits::default(), 4096);
        assert!(matches!(
            result,
            Err(ProcessorFailure {
                code: "json_parse_failed",
                ..
            })
        ));
    }

    #[test]
    fn html_conversion_does_not_fetch_or_inline_images() -> Result<(), ProcessorFailure> {
        let document = canonicalize_html(
            br#"<h1>Hello</h1><img src="https://example.invalid/secret.png"><p>World</p>"#,
            &DocumentLimits::default(),
        )?
        .ok_or_else(|| ProcessorFailure::malformed("test_empty", "missing test output"))?;
        assert!(document.text.contains("# Hello"));
        assert!(document.text.contains("World"));
        assert!(!document.text.contains("example.invalid"));
        assert!(
            document
                .warnings
                .iter()
                .any(|warning| warning.contains("not fetched"))
        );
        Ok(())
    }

    #[test]
    fn xml_doctype_is_not_resolved() -> Result<(), ProcessorFailure> {
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let extracted = extract_xml_text(
            br#"<?xml version="1.0"?><!DOCTYPE x [<!ENTITY ext SYSTEM "file:///etc/passwd">]><x>safe</x>"#,
            &limits,
            None,
            &mut work_budget,
        )?;
        assert!(extracted.text.contains("safe"));
        assert!(
            extracted
                .warnings
                .iter()
                .any(|warning| warning.contains("never resolved"))
        );
        Ok(())
    }

    #[test]
    fn xml_parts_share_one_monotonic_event_budget() -> Result<(), ProcessorFailure> {
        let limits = DocumentLimits {
            max_total_xml_events: 5,
            ..DocumentLimits::default()
        };
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );

        let extracted = extract_xml_text(b"<x>a</x>", &limits, None, &mut work_budget)?;
        assert_eq!(extracted.text.trim(), "a");
        let failure = extract_xml_text(b"<x>b</x>", &limits, None, &mut work_budget)
            .expect_err("the second XML part must consume the same shared budget");
        assert_eq!(failure.code, "total_xml_event_limit_exceeded");
        Ok(())
    }

    #[test]
    fn xml_duplicate_attributes_are_rejected() {
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let failure = extract_xml_text(
            br#"<x value="one" value="two">text</x>"#,
            &limits,
            None,
            &mut work_budget,
        )
        .expect_err("duplicate XML attributes must not receive canonical text evidence");
        assert_eq!(failure.code, "xml_attribute_malformed");
    }

    #[test]
    fn notebook_code_fences_cannot_be_broken_by_cell_content() -> Result<(), ProcessorFailure> {
        let document = canonicalize_notebook(
            br#"{"cells":[{"cell_type":"code","source":["print('```')"]}],"nbformat":4}"#,
            &DocumentLimits::default(),
            usize::MAX,
        )?
        .ok_or_else(|| ProcessorFailure::malformed("test_empty", "missing test output"))?;
        assert!(document.text.contains("````\nprint('```')\n````"));
        Ok(())
    }

    #[test]
    fn delimited_aggregate_is_bounded_before_final_emission() -> Result<(), ProcessorFailure> {
        let document = canonicalize_delimited(
            "heading\néééééééé\nnever-reached\n".as_bytes(),
            DetectedFormat::Csv,
            &DocumentLimits::default(),
            31,
        )?
        .ok_or_else(|| ProcessorFailure::malformed("test_empty", "missing test output"))?;

        assert!(document.output_budget_exhausted);
        assert!(document.text.len() <= 31);
        assert!(document.text.is_char_boundary(document.text.len()));
        assert!(!document.text.contains("never-reached"));
        assert!(document.segments.iter().all(|segment| {
            segment.end_byte <= document.text.len()
                && document.text.is_char_boundary(segment.start_byte)
                && document.text.is_char_boundary(segment.end_byte)
        }));
        Ok(())
    }

    #[test]
    fn email_preserves_useful_headers_without_header_injection() -> Result<(), ProcessorFailure> {
        let document = canonicalize_email(
            b"From: Alice Example <alice@example.test>\r\nTo: Bob <bob@example.test>\r\nCc: Carol <carol@example.test>\r\nDate: Tue, 1 Jan 2030 12:00:00 +0000\r\nMessage-ID: <fixture@example.test>\r\nSubject: Planning\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nGrounded body.\r\n",
            &DocumentLimits::default(),
            usize::MAX,
        )?
        .ok_or_else(|| ProcessorFailure::malformed("test_empty", "missing test output"))?;
        assert!(
            document
                .text
                .contains("**From:** Alice Example <alice@example.test>")
        );
        assert!(document.text.contains("**To:** Bob <bob@example.test>"));
        assert!(
            document
                .text
                .contains("**Message-ID:** fixture@example.test")
        );
        assert!(document.text.contains("Grounded body."));
        Ok(())
    }
}
