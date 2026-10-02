use crate::text::{canonicalize_html, extract_xml_text};
use crate::{
    BoundedText, BundleIndex, CanonicalizationWorkBudget, DocumentLimits, ProcessorFailure,
    RenderResult, RenderedDocument,
};
use attachment_native_types::{DetectedFormat, ObjectId, SegmentKind, TextFormat, TextSegment};
use quick_xml::Reader;
use quick_xml::events::Event;
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn is_structural_member(format: DetectedFormat, name: &str) -> bool {
    let name = portable_name(name);
    match format {
        DetectedFormat::Docx => {
            name == "[Content_Types].xml"
                || name.ends_with(".rels")
                || name.starts_with("docProps/")
                || (name.starts_with("word/") && name.ends_with(".xml"))
        }
        DetectedFormat::Pptx => {
            name == "[Content_Types].xml"
                || name.ends_with(".rels")
                || name.starts_with("docProps/")
                || (name.starts_with("ppt/") && name.ends_with(".xml"))
        }
        DetectedFormat::Xlsx => {
            name == "[Content_Types].xml"
                || name.ends_with(".rels")
                || name.starts_with("docProps/")
                || (name.starts_with("xl/") && name.ends_with(".xml"))
        }
        DetectedFormat::Epub => {
            name == "META-INF/container.xml"
                || name.ends_with(".opf")
                || name.ends_with(".ncx")
                || name.ends_with(".xhtml")
                || name.ends_with(".html")
                || name.ends_with(".htm")
        }
        DetectedFormat::OpenDocumentText
        | DetectedFormat::OpenDocumentSpreadsheet
        | DetectedFormat::OpenDocumentPresentation => {
            matches!(
                name.as_str(),
                "content.xml"
                    | "styles.xml"
                    | "meta.xml"
                    | "settings.xml"
                    | "META-INF/manifest.xml"
                    | "mimetype"
            )
        }
        _ => false,
    }
}

pub(crate) fn canonicalize_docx(
    source: &ObjectId,
    index: &BundleIndex,
    limits: &DocumentLimits,
    max_output_bytes: usize,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let children = index.children(source);
    let mut parts = children
        .iter()
        .filter(|child| is_docx_text_part(&child.name))
        .collect::<Vec<_>>();
    parts.sort_by_key(|child| docx_part_rank(&child.name));
    if parts.is_empty() {
        return Err(ProcessorFailure::malformed(
            "docx_document_part_missing",
            "The DOCX container has no readable main document part.",
        ));
    }
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# Word document\n\n");
    let mut segments = Vec::new();
    let mut warnings = active_content_warnings(children);
    let mut issues = Vec::new();
    let mut success = 0_u32;
    for part in parts {
        work_budget.checkpoint()?;
        let label = docx_part_label(&part.name);
        match extract_xml_text(&part.bytes, limits, Some(&|name| name == b"t"), work_budget) {
            Ok(mut extracted) => {
                warnings.append(&mut extracted.warnings);
                issues.append(&mut extracted.issues);
                if extracted.text.trim().is_empty() {
                    continue;
                }
                let section = format!("## {label}\n\n{}\n\n", extracted.text.trim());
                let span = output.push(&section);
                if span.end > span.start {
                    segments.push(TextSegment {
                        kind: SegmentKind::Document,
                        label: Some(label),
                        start_byte: span.start,
                        end_byte: span.end,
                        coordinates: Some(BTreeMap::from([(
                            "member".to_string(),
                            portable_name(&part.name),
                        )])),
                    });
                    success = success.saturating_add(1);
                }
                if !span.complete {
                    break;
                }
            }
            Err(error) => {
                warnings.push(format!(
                    "{} could not be read: {}",
                    portable_name(&part.name),
                    error.safe_message
                ));
                issues.push(error);
            }
        }
    }
    if success == 0 && !output.was_truncated() {
        return Err(ProcessorFailure::malformed(
            "docx_text_extraction_failed",
            "The DOCX structure was inspected, but no document text could be recovered from its XML parts.",
        ));
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

pub(crate) fn canonicalize_pptx(
    source: &ObjectId,
    index: &BundleIndex,
    limits: &DocumentLimits,
    max_output_bytes: usize,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let children = index.children(source);
    let mut slides = children
        .iter()
        .filter_map(|child| slide_number(&child.name).map(|number| (number, child)))
        .collect::<Vec<_>>();
    slides.sort_by_key(|(number, child)| (*number, portable_name(&child.name)));
    if slides.is_empty() {
        return Err(ProcessorFailure::malformed(
            "pptx_slide_parts_missing",
            "The PPTX container has no readable slide XML parts.",
        ));
    }
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# Presentation\n\n");
    let mut segments = Vec::new();
    let mut warnings = active_content_warnings(children);
    let mut issues = Vec::new();
    let mut success = 0_u32;
    for (number, slide) in slides {
        work_budget.checkpoint()?;
        match extract_xml_text(
            &slide.bytes,
            limits,
            Some(&|name| name == b"t"),
            work_budget,
        ) {
            Ok(mut extracted) => {
                let section = if extracted.text.trim().is_empty() {
                    format!("## Slide {number}\n\n_(No extractable text.)_\n\n")
                } else {
                    format!("## Slide {number}\n\n{}\n\n", extracted.text.trim())
                };
                let span = output.push(&section);
                if span.end > span.start {
                    segments.push(TextSegment {
                        kind: SegmentKind::Slide,
                        label: Some(format!("Slide {number}")),
                        start_byte: span.start,
                        end_byte: span.end,
                        coordinates: Some(BTreeMap::from([
                            ("slide".to_string(), number.to_string()),
                            ("member".to_string(), portable_name(&slide.name)),
                        ])),
                    });
                    success = success.saturating_add(1);
                }
                warnings.append(&mut extracted.warnings);
                issues.append(&mut extracted.issues);
                if !span.complete {
                    break;
                }
            }
            Err(error) => {
                warnings.push(format!(
                    "Slide {number} could not be read: {}",
                    error.safe_message
                ));
                issues.push(error);
            }
        }
    }
    if success == 0 && !output.was_truncated() {
        return Err(ProcessorFailure::malformed(
            "pptx_text_extraction_failed",
            "The PPTX structure was inspected, but no slide could be parsed.",
        ));
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

pub(crate) fn canonicalize_xlsx(
    source: &ObjectId,
    index: &BundleIndex,
    limits: &DocumentLimits,
    max_output_bytes: usize,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let children = index.children(source);
    let shared = children
        .iter()
        .find(|child| portable_name(&child.name) == "xl/sharedStrings.xml")
        .map(|child| parse_shared_strings(&child.bytes, limits, work_budget))
        .transpose()?
        .unwrap_or_default();
    let mut sheets = children
        .iter()
        .filter_map(|child| worksheet_number(&child.name).map(|number| (number, child)))
        .collect::<Vec<_>>();
    sheets.sort_by_key(|(number, child)| (*number, portable_name(&child.name)));
    if sheets.is_empty() {
        return Err(ProcessorFailure::malformed(
            "xlsx_sheet_parts_missing",
            "The XLSX container has no readable worksheet XML parts.",
        ));
    }
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# Workbook\n\n");
    let mut segments = Vec::new();
    let mut warnings = active_content_warnings(children);
    let mut issues = Vec::new();
    let mut cell_budget = limits.max_csv_cells;
    let mut success = 0_u32;
    for (number, sheet) in sheets {
        work_budget.checkpoint()?;
        match parse_sheet(&sheet.bytes, &shared, limits, &mut cell_budget, work_budget) {
            Ok(mut parsed) => {
                let start = output.len();
                let heading = format!(
                    "## Sheet {number}\n\n| Cell | Value | Formula |\n| --- | --- | --- |\n"
                );
                let mut complete = output.push(&heading).complete;
                for cell in parsed.cells {
                    if !complete {
                        break;
                    }
                    let row = format!(
                        "| {} | {} | {} |\n",
                        escape_cell(&cell.reference),
                        escape_cell(&cell.value),
                        escape_cell(cell.formula.as_deref().unwrap_or_default())
                    );
                    complete = output.push(&row).complete;
                }
                if complete {
                    complete = output.push("\n").complete;
                }
                if output.len() > start {
                    segments.push(TextSegment {
                        kind: SegmentKind::Sheet,
                        label: Some(format!("Sheet {number}")),
                        start_byte: start,
                        end_byte: output.len(),
                        coordinates: Some(BTreeMap::from([
                            ("sheet".to_string(), number.to_string()),
                            ("member".to_string(), portable_name(&sheet.name)),
                        ])),
                    });
                    success = success.saturating_add(1);
                }
                warnings.append(&mut parsed.warnings);
                issues.append(&mut parsed.issues);
                if !complete {
                    break;
                }
            }
            Err(error) => {
                warnings.push(format!(
                    "Sheet {number} could not be read: {}",
                    error.safe_message
                ));
                issues.push(error);
            }
        }
    }
    if success == 0 && !output.was_truncated() {
        return Err(ProcessorFailure::malformed(
            "xlsx_text_extraction_failed",
            "The XLSX structure was inspected, but no worksheet could be parsed.",
        ));
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

pub(crate) fn canonicalize_epub(
    source: &ObjectId,
    index: &BundleIndex,
    limits: &DocumentLimits,
    max_output_bytes: usize,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let children = index.children(source);
    let by_name = children
        .iter()
        .map(|child| (portable_name(&child.name), child.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    let fallback_opf = by_name.keys().find(|name| name.ends_with(".opf")).cloned();
    let opf_name = match children
        .iter()
        .find(|child| portable_name(&child.name) == "META-INF/container.xml")
    {
        Some(child) => match parse_container_rootfile(&child.bytes, limits, work_budget) {
            Ok(name) => name.or_else(|| fallback_opf.clone()),
            Err(error) => {
                warnings.push(error.safe_message.clone());
                issues.push(error);
                fallback_opf.clone()
            }
        },
        None => fallback_opf,
    };
    if let Some(failure) = work_budget.exhausted_failure() {
        return Err(failure);
    }
    let ordered = match opf_name.as_ref().and_then(|name| by_name.get(name)) {
        Some(opf) => match parse_epub_spine(&opf.name, &opf.bytes, limits, work_budget) {
            Ok(ordered) => ordered,
            Err(error) => {
                warnings.push(error.safe_message.clone());
                issues.push(error);
                Vec::new()
            }
        },
        None => Vec::new(),
    };
    if let Some(failure) = work_budget.exhausted_failure() {
        return Err(failure);
    }
    let mut content_names = ordered
        .into_iter()
        .filter(|name| by_name.contains_key(name))
        .collect::<Vec<_>>();
    if content_names.is_empty() {
        warnings.push(
            "EPUB spine order could not be established; readable documents use deterministic member-name order."
                .to_string(),
        );
        content_names = by_name
            .keys()
            .filter(|name| is_epub_content_name(name))
            .cloned()
            .collect();
    }
    let mut seen = BTreeSet::new();
    content_names.retain(|name| seen.insert(name.clone()));
    if content_names.is_empty() {
        return Err(ProcessorFailure::malformed(
            "epub_content_parts_missing",
            "The EPUB container has no readable HTML content documents.",
        ));
    }
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# EPUB\n\n");
    let mut segments = Vec::new();
    let mut success = 0_u32;
    for name in content_names {
        work_budget.checkpoint()?;
        let Some(child) = by_name.get(&name) else {
            continue;
        };
        match canonicalize_html(&child.bytes, limits) {
            Ok(Some(mut document)) => {
                let section = format!("## {name}\n\n{}\n\n", document.text.trim());
                let span = output.push(&section);
                if span.end > span.start {
                    segments.push(TextSegment {
                        kind: SegmentKind::Document,
                        label: Some(name.clone()),
                        start_byte: span.start,
                        end_byte: span.end,
                        coordinates: Some(BTreeMap::from([("member".to_string(), name)])),
                    });
                    success = success.saturating_add(1);
                }
                warnings.append(&mut document.warnings);
                issues.append(&mut document.issues);
                if !span.complete {
                    break;
                }
            }
            Ok(None) => {}
            Err(error) => {
                warnings.push(format!(
                    "An EPUB content document could not be read: {}",
                    error.safe_message
                ));
                issues.push(error);
            }
        }
    }
    if success == 0 && !output.was_truncated() {
        return Err(ProcessorFailure::malformed(
            "epub_text_extraction_failed",
            "The EPUB structure was inspected, but no content document could be converted.",
        ));
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

pub(crate) fn canonicalize_open_document(
    source: &ObjectId,
    format: DetectedFormat,
    index: &BundleIndex,
    limits: &DocumentLimits,
    max_output_bytes: usize,
    work_budget: &mut CanonicalizationWorkBudget,
) -> RenderResult {
    let children = index.children(source);
    let Some(content) = children
        .iter()
        .find(|child| portable_name(&child.name) == "content.xml")
    else {
        return Err(ProcessorFailure::malformed(
            "open_document_content_missing",
            "The OpenDocument container has no readable content.xml part.",
        ));
    };
    let mut extracted = extract_xml_text(&content.bytes, limits, None, work_budget)?;
    if extracted.text.trim().is_empty() {
        return Err(ProcessorFailure::malformed(
            "open_document_text_missing",
            "The OpenDocument content part contains no extractable text.",
        ));
    }
    let label = match format {
        DetectedFormat::OpenDocumentText => "OpenDocument text",
        DetectedFormat::OpenDocumentSpreadsheet => "OpenDocument spreadsheet",
        DetectedFormat::OpenDocumentPresentation => "OpenDocument presentation",
        _ => "OpenDocument",
    };
    let mut output = BoundedText::new(max_output_bytes);
    output.push(&format!("# {label}\n\n"));
    let span = output.push(extracted.text.trim());
    if span.complete {
        output.push("\n");
    }
    extracted.warnings.extend(active_content_warnings(children));
    if format == DetectedFormat::OpenDocumentSpreadsheet {
        extracted.warnings.push(
            "Spreadsheet text is presented in document order; formula and cell-coordinate fidelity requires a dedicated spreadsheet adapter."
                .to_string(),
        );
    }
    let output_budget_exhausted = output.was_truncated();
    Ok(Some(RenderedDocument {
        format: TextFormat::Markdown,
        text: output.into_string(),
        segments: (span.end > span.start)
            .then(|| TextSegment {
                kind: match format {
                    DetectedFormat::OpenDocumentSpreadsheet => SegmentKind::Sheet,
                    DetectedFormat::OpenDocumentPresentation => SegmentKind::Slide,
                    _ => SegmentKind::Document,
                },
                label: Some(label.to_string()),
                start_byte: span.start,
                end_byte: span.end,
                coordinates: Some(BTreeMap::from([(
                    "member".to_string(),
                    "content.xml".to_string(),
                )])),
            })
            .into_iter()
            .collect(),
        warnings: extracted.warnings,
        issues: extracted.issues,
        output_budget_exhausted,
    }))
}

#[derive(Debug, Clone)]
struct SheetCell {
    reference: String,
    value: String,
    formula: Option<String>,
}

struct ParsedSheet {
    cells: Vec<SheetCell>,
    warnings: Vec<String>,
    issues: Vec<ProcessorFailure>,
}

fn parse_shared_strings(
    bytes: &[u8],
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<Vec<String>, ProcessorFailure> {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "xlsx_shared_strings_limit",
            "The workbook shared-string table exceeds the bounded XML input limit.",
        ));
    }
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(false);
    let mut strings = Vec::new();
    let mut current = String::new();
    let mut in_item = false;
    let mut in_text = false;
    let mut events = 0_u64;
    let mut elements = Vec::new();
    loop {
        check_xml_event_budget(&mut events, limits, work_budget)?;
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                validate_xml_attributes(&element)?;
                push_xml_element(&mut elements, element.name().as_ref(), limits)?;
                match local_name(element.name().as_ref()) {
                    b"si" => {
                        current.clear();
                        in_item = true;
                    }
                    b"t" if in_item => in_text = true,
                    _ => {}
                }
            }
            Ok(Event::Empty(element)) => {
                validate_xml_attributes(&element)?;
                if local_name(element.name().as_ref()) == b"si" {
                    strings.push(String::new());
                }
            }
            Ok(Event::End(element)) => {
                pop_xml_element(
                    &mut elements,
                    element.name().as_ref(),
                    "xlsx_shared_strings_malformed",
                    "The workbook shared-string XML is malformed.",
                )?;
                match local_name(element.name().as_ref()) {
                    b"si" => {
                        strings.push(current.clone());
                        in_item = false;
                    }
                    b"t" => in_text = false,
                    _ => {}
                }
            }
            Ok(Event::Text(text)) if in_text => current.push_str(&decoded_text(&text)?),
            Ok(Event::CData(text)) if in_text => current.push_str(&decoded_cdata(&text)?),
            Ok(Event::Eof) => {
                if !elements.is_empty() || in_item || in_text {
                    return Err(ProcessorFailure::malformed(
                        "xlsx_shared_strings_malformed",
                        "The workbook shared-string XML ended before all elements were closed.",
                    ));
                }
                break;
            }
            Ok(_) => {}
            Err(_) => {
                return Err(ProcessorFailure::malformed(
                    "xlsx_shared_strings_malformed",
                    "The workbook shared-string XML is malformed.",
                ));
            }
        }
    }
    Ok(strings)
}

fn parse_sheet(
    bytes: &[u8],
    shared: &[String],
    limits: &DocumentLimits,
    remaining_cells: &mut u64,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<ParsedSheet, ProcessorFailure> {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "xlsx_sheet_input_limit",
            "A worksheet exceeds the bounded XML input limit.",
        ));
    }
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(false);
    let mut cells = Vec::new();
    let mut current: Option<SheetCell> = None;
    let mut cell_type = String::new();
    let mut capture = Capture::None;
    let mut events = 0_u64;
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    let mut elements = Vec::new();
    loop {
        check_xml_event_budget(&mut events, limits, work_budget)?;
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                validate_xml_attributes(&element)?;
                push_xml_element(&mut elements, element.name().as_ref(), limits)?;
                match local_name(element.name().as_ref()) {
                    b"c" => {
                        let reference = attribute(&element, b"r")?
                            .unwrap_or_else(|| format!("cell-{}", cells.len().saturating_add(1)));
                        cell_type = attribute(&element, b"t")?.unwrap_or_default();
                        current = Some(SheetCell {
                            reference,
                            value: String::new(),
                            formula: None,
                        });
                    }
                    b"v" if current.is_some() => capture = Capture::Value,
                    b"f" if current.is_some() => capture = Capture::Formula,
                    b"t" if current.is_some() && cell_type == "inlineStr" => {
                        capture = Capture::Value
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(element)) => validate_xml_attributes(&element)?,
            Ok(Event::End(element)) => {
                pop_xml_element(
                    &mut elements,
                    element.name().as_ref(),
                    "xlsx_sheet_malformed",
                    "A worksheet XML part is malformed.",
                )?;
                match local_name(element.name().as_ref()) {
                    b"v" | b"f" | b"t" => capture = Capture::None,
                    b"c" => {
                        if *remaining_cells == 0 {
                            let failure = ProcessorFailure::partial(
                                "xlsx_cell_limit_exceeded",
                                "Worksheet cells were truncated at the configured cell limit.",
                            );
                            warnings.push(failure.safe_message.clone());
                            issues.push(failure);
                            break;
                        }
                        if let Some(mut cell) = current.take() {
                            if cell_type == "s" && !cell.value.is_empty() {
                                cell.value = cell
                                    .value
                                    .parse::<usize>()
                                    .ok()
                                    .and_then(|index| shared.get(index))
                                    .cloned()
                                    .unwrap_or_else(|| {
                                        let failure = ProcessorFailure::malformed(
                                            "xlsx_shared_string_reference_missing",
                                            "A worksheet references a missing shared string.",
                                        );
                                        warnings.push(failure.safe_message.clone());
                                        issues.push(failure);
                                        "[missing shared string]".to_string()
                                    });
                            }
                            if !cell.value.is_empty() || cell.formula.is_some() {
                                cells.push(cell);
                                *remaining_cells = remaining_cells.saturating_sub(1);
                            }
                        }
                        cell_type.clear();
                        capture = Capture::None;
                    }
                    _ => {}
                }
            }
            Ok(Event::Text(value)) => {
                if let Some(cell) = current.as_mut() {
                    let value = decoded_text(&value)?;
                    match capture {
                        Capture::Value => cell.value.push_str(&value),
                        Capture::Formula => cell
                            .formula
                            .get_or_insert_with(String::new)
                            .push_str(&value),
                        Capture::None => {}
                    }
                }
            }
            Ok(Event::CData(value)) => {
                if let Some(cell) = current.as_mut() {
                    let value = decoded_cdata(&value)?;
                    match capture {
                        Capture::Value => cell.value.push_str(&value),
                        Capture::Formula => cell
                            .formula
                            .get_or_insert_with(String::new)
                            .push_str(&value),
                        Capture::None => {}
                    }
                }
            }
            Ok(Event::Eof) => {
                if !elements.is_empty() || current.is_some() || capture != Capture::None {
                    return Err(ProcessorFailure::malformed(
                        "xlsx_sheet_malformed",
                        "A worksheet XML part ended before all elements were closed.",
                    ));
                }
                break;
            }
            Ok(_) => {}
            Err(_) => {
                return Err(ProcessorFailure::malformed(
                    "xlsx_sheet_malformed",
                    "A worksheet XML part is malformed.",
                ));
            }
        }
    }
    Ok(ParsedSheet {
        cells,
        warnings,
        issues,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Capture {
    None,
    Value,
    Formula,
}

fn parse_container_rootfile(
    bytes: &[u8],
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<Option<String>, ProcessorFailure> {
    xml_attribute_search(bytes, b"rootfile", b"full-path", limits, work_budget)
        .map(|value| value.and_then(|path| normalize_member_reference("", &path)))
}

fn parse_epub_spine(
    opf_name: &str,
    bytes: &[u8],
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<Vec<String>, ProcessorFailure> {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "epub_package_input_limit",
            "The EPUB package document exceeds the bounded XML input limit.",
        ));
    }
    let base = opf_name
        .rsplit_once('/')
        .map(|(base, _)| base)
        .unwrap_or("");
    let mut reader = Reader::from_reader(bytes);
    let mut manifest = BTreeMap::new();
    let mut spine = Vec::new();
    let mut events = 0_u64;
    let mut elements = Vec::new();
    loop {
        check_xml_event_budget(&mut events, limits, work_budget)?;
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                validate_xml_attributes(&element)?;
                push_xml_element(&mut elements, element.name().as_ref(), limits)?;
                collect_epub_reference(&element, base, &mut manifest, &mut spine)?;
            }
            Ok(Event::Empty(element)) => {
                validate_xml_attributes(&element)?;
                collect_epub_reference(&element, base, &mut manifest, &mut spine)?;
            }
            Ok(Event::End(element)) => pop_xml_element(
                &mut elements,
                element.name().as_ref(),
                "epub_package_malformed",
                "The EPUB package document is malformed XML.",
            )?,
            Ok(Event::Eof) => {
                if !elements.is_empty() {
                    return Err(ProcessorFailure::malformed(
                        "epub_package_malformed",
                        "The EPUB package document ended before all elements were closed.",
                    ));
                }
                break;
            }
            Ok(_) => {}
            Err(_) => {
                return Err(ProcessorFailure::malformed(
                    "epub_package_malformed",
                    "The EPUB package document is malformed XML.",
                ));
            }
        }
    }
    Ok(spine
        .into_iter()
        .filter_map(|id| manifest.get(&id).cloned())
        .collect())
}

fn collect_epub_reference(
    element: &quick_xml::events::BytesStart<'_>,
    base: &str,
    manifest: &mut BTreeMap<String, String>,
    spine: &mut Vec<String>,
) -> Result<(), ProcessorFailure> {
    match local_name(element.name().as_ref()) {
        b"item" => {
            if let (Some(id), Some(href)) =
                (attribute(element, b"id")?, attribute(element, b"href")?)
                && let Some(path) = normalize_member_reference(base, &href)
            {
                manifest.insert(id, path);
            }
        }
        b"itemref" => {
            if let Some(id) = attribute(element, b"idref")? {
                spine.push(id);
            }
        }
        _ => {}
    }
    Ok(())
}

fn xml_attribute_search(
    bytes: &[u8],
    element_name: &[u8],
    attribute_name: &[u8],
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<Option<String>, ProcessorFailure> {
    if bytes.len() > limits.max_processor_input_bytes {
        return Err(ProcessorFailure::partial(
            "xml_processor_input_limit",
            "An XML part exceeds the bounded parser input limit.",
        ));
    }
    let mut reader = Reader::from_reader(bytes);
    let mut events = 0_u64;
    let mut elements = Vec::new();
    let mut matched = None;
    loop {
        check_xml_event_budget(&mut events, limits, work_budget)?;
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                validate_xml_attributes(&element)?;
                push_xml_element(&mut elements, element.name().as_ref(), limits)?;
                if local_name(element.name().as_ref()) == element_name {
                    matched = attribute(&element, attribute_name)?;
                }
            }
            Ok(Event::Empty(element)) => {
                validate_xml_attributes(&element)?;
                if local_name(element.name().as_ref()) == element_name {
                    matched = attribute(&element, attribute_name)?;
                }
            }
            Ok(Event::End(element)) => pop_xml_element(
                &mut elements,
                element.name().as_ref(),
                "xml_parse_failed",
                "An XML package part is malformed.",
            )?,
            Ok(Event::Eof) => {
                if !elements.is_empty() {
                    return Err(ProcessorFailure::malformed(
                        "xml_parse_failed",
                        "An XML package part ended before all elements were closed.",
                    ));
                }
                return Ok(matched);
            }
            Ok(_) => {}
            Err(_) => {
                return Err(ProcessorFailure::malformed(
                    "xml_parse_failed",
                    "An XML package part is malformed.",
                ));
            }
        }
    }
}

fn attribute(
    element: &quick_xml::events::BytesStart<'_>,
    key: &[u8],
) -> Result<Option<String>, ProcessorFailure> {
    for attribute in element.attributes().with_checks(true) {
        let attribute = attribute.map_err(|_| malformed_xml_attribute())?;
        let value = attribute
            .normalized_value(quick_xml::XmlVersion::Implicit1_0)
            .map_err(|_| malformed_xml_attribute())?;
        if local_name(attribute.key.as_ref()) == key {
            return Ok(Some(value.into_owned()));
        }
    }
    Ok(None)
}

fn validate_xml_attributes(
    element: &quick_xml::events::BytesStart<'_>,
) -> Result<(), ProcessorFailure> {
    for attribute in element.attributes().with_checks(true) {
        let attribute = attribute.map_err(|_| malformed_xml_attribute())?;
        let _ = attribute
            .normalized_value(quick_xml::XmlVersion::Implicit1_0)
            .map_err(|_| malformed_xml_attribute())?;
    }
    Ok(())
}

fn malformed_xml_attribute() -> ProcessorFailure {
    ProcessorFailure::malformed(
        "xml_attribute_malformed",
        "An XML package part contains a malformed or duplicate attribute.",
    )
}

fn decoded_text(value: &quick_xml::events::BytesText<'_>) -> Result<String, ProcessorFailure> {
    let decoded = value.xml10_content().map_err(|_| {
        ProcessorFailure::malformed(
            "xml_text_decode_failed",
            "An XML text node uses an invalid character encoding.",
        )
    })?;
    quick_xml::escape::unescape(&decoded)
        .map(|value| value.into_owned())
        .map_err(|_| {
            ProcessorFailure::malformed(
                "xml_entity_decode_failed",
                "An XML text node contains an invalid entity reference.",
            )
        })
}

fn decoded_cdata(value: &quick_xml::events::BytesCData<'_>) -> Result<String, ProcessorFailure> {
    value.decode().map(|value| value.into_owned()).map_err(|_| {
        ProcessorFailure::malformed(
            "xml_cdata_decode_failed",
            "An XML CDATA section uses an invalid character encoding.",
        )
    })
}

fn check_xml_event_budget(
    events: &mut u64,
    limits: &DocumentLimits,
    work_budget: &mut CanonicalizationWorkBudget,
) -> Result<(), ProcessorFailure> {
    work_budget.charge_xml_event()?;
    *events = events.saturating_add(1);
    if *events > limits.max_xml_events {
        return Err(ProcessorFailure::partial(
            "xml_event_limit_exceeded",
            "XML processing stopped at the configured event limit.",
        ));
    }
    Ok(())
}

fn push_xml_element(
    elements: &mut Vec<Vec<u8>>,
    name: &[u8],
    limits: &DocumentLimits,
) -> Result<(), ProcessorFailure> {
    if elements.len() >= usize::try_from(limits.max_xml_depth).unwrap_or(usize::MAX) {
        return Err(ProcessorFailure::partial(
            "xml_depth_limit_exceeded",
            "XML processing stopped at the configured element-depth limit.",
        ));
    }
    elements.push(name.to_vec());
    Ok(())
}

fn pop_xml_element(
    elements: &mut Vec<Vec<u8>>,
    name: &[u8],
    code: &'static str,
    message: &'static str,
) -> Result<(), ProcessorFailure> {
    if elements.pop().as_deref() != Some(name) {
        return Err(ProcessorFailure::malformed(code, message));
    }
    Ok(())
}

fn normalize_member_reference(base: &str, href: &str) -> Option<String> {
    let href = href
        .split('#')
        .next()
        .unwrap_or_default()
        .replace('\\', "/");
    if href.is_empty() || href.starts_with('/') || href.contains(':') {
        return None;
    }
    let mut components = base
        .split('/')
        .filter(|component| !component.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    for component in href.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                let _ = components.pop()?;
            }
            value => components.push(value.to_string()),
        }
    }
    (!components.is_empty()).then(|| components.join("/"))
}

fn active_content_warnings(children: &[crate::NamedChild]) -> Vec<String> {
    let mut warnings = Vec::new();
    if children.iter().any(|child| {
        let name = portable_name(&child.name).to_ascii_lowercase();
        name.ends_with("vbaproject.bin")
            || name.contains("/embeddings/")
            || name.starts_with("scripts/")
            || name.starts_with("basic/")
    }) {
        warnings.push(
            "Embedded active content was retained as a separate opaque object and was never executed."
                .to_string(),
        );
    }
    if children
        .iter()
        .any(|child| portable_name(&child.name).ends_with(".rels"))
    {
        warnings.push(
            "Office relationship metadata was inspected as data; external relationships were never opened."
                .to_string(),
        );
    }
    warnings
}

fn docx_part_rank(name: &str) -> (u8, String) {
    let name = portable_name(name);
    let rank = if name == "word/document.xml" {
        0
    } else if name.contains("header") {
        1
    } else if name.contains("footer") {
        2
    } else if name.ends_with("footnotes.xml") {
        3
    } else if name.ends_with("endnotes.xml") {
        4
    } else if name.ends_with("comments.xml") {
        5
    } else {
        6
    };
    (rank, name)
}

fn docx_part_label(name: &str) -> String {
    let name = portable_name(name);
    if name == "word/document.xml" {
        "Document".to_string()
    } else {
        name.rsplit('/').next().unwrap_or(&name).to_string()
    }
}

fn is_docx_text_part(name: &str) -> bool {
    let name = portable_name(name);
    name == "word/document.xml"
        || (name.starts_with("word/header") && name.ends_with(".xml"))
        || (name.starts_with("word/footer") && name.ends_with(".xml"))
        || matches!(
            name.as_str(),
            "word/footnotes.xml" | "word/endnotes.xml" | "word/comments.xml"
        )
}

fn slide_number(name: &str) -> Option<u32> {
    numbered_xml_member(name, "ppt/slides/slide")
}

fn worksheet_number(name: &str) -> Option<u32> {
    numbered_xml_member(name, "xl/worksheets/sheet")
}

fn numbered_xml_member(name: &str, prefix: &str) -> Option<u32> {
    portable_name(name)
        .strip_prefix(prefix)?
        .strip_suffix(".xml")?
        .parse()
        .ok()
}

fn is_epub_content_name(name: &str) -> bool {
    name.ends_with(".xhtml") || name.ends_with(".html") || name.ends_with(".htm")
}

fn portable_name(name: &str) -> String {
    name.replace('\\', "/")
}

fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

fn escape_cell(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('|', "\\|")
        .replace("\r\n", "<br>")
        .replace(['\r', '\n'], "<br>")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epub_references_cannot_escape_the_archive_namespace() {
        assert_eq!(
            normalize_member_reference("OPS/text", "../images/cover.xhtml"),
            Some("OPS/images/cover.xhtml".to_string())
        );
        assert_eq!(normalize_member_reference("", "../../outside"), None);
        assert_eq!(
            normalize_member_reference("OPS", "https://example.com/x"),
            None
        );
    }

    #[test]
    fn malformed_worksheet_is_rejected_without_partial_cells() {
        let mut remaining = 10;
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let result = parse_sheet(
            b"<worksheet><c r=\"A1\"><v>1</worksheet>",
            &[],
            &limits,
            &mut remaining,
            &mut work_budget,
        );
        assert!(matches!(
            result,
            Err(ProcessorFailure {
                code: "xlsx_sheet_malformed",
                ..
            })
        ));
    }

    #[test]
    fn shared_strings_and_formulas_are_preserved() -> Result<(), ProcessorFailure> {
        let mut remaining = 10;
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let parsed = parse_sheet(
            br#"<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>"#,
            &["hello".to_string()],
            &limits,
            &mut remaining,
            &mut work_budget,
        )?;
        assert!(parsed.warnings.is_empty());
        assert!(parsed.issues.is_empty());
        assert_eq!(parsed.cells.len(), 2);
        assert_eq!(parsed.cells[0].value, "hello");
        assert_eq!(parsed.cells[1].formula.as_deref(), Some("1+1"));
        Ok(())
    }

    #[test]
    fn empty_shared_string_keeps_following_indexes_stable() -> Result<(), ProcessorFailure> {
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let strings = parse_shared_strings(
            br#"<sst><si/><si><t>second</t></si></sst>"#,
            &limits,
            &mut work_budget,
        )?;
        assert_eq!(strings, vec![String::new(), "second".to_string()]);
        Ok(())
    }

    #[test]
    fn worksheet_valid_prefix_with_unclosed_tail_is_rejected() {
        let mut remaining = 10;
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let result = parse_sheet(
            br#"<worksheet><c r="A1"><v>1</v></c><c r="A2"><v>2"#,
            &[],
            &limits,
            &mut remaining,
            &mut work_budget,
        );
        assert!(matches!(
            result,
            Err(ProcessorFailure {
                code: "xlsx_sheet_malformed",
                ..
            })
        ));
    }

    #[test]
    fn epub_duplicate_attributes_are_rejected() {
        let limits = DocumentLimits::default();
        let mut work_budget = CanonicalizationWorkBudget::new(
            &limits,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        );
        let result = parse_epub_spine(
            "OPS/package.opf",
            br#"<package><manifest><item id="chapter" id="duplicate" href="chapter.xhtml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#,
            &limits,
            &mut work_budget,
        );
        assert!(matches!(
            result,
            Err(ProcessorFailure {
                code: "xml_attribute_malformed",
                ..
            })
        ));
    }
}
