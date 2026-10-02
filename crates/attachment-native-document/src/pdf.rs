use crate::{BoundedText, DocumentLimits, ProcessorFailure, RenderResult, RenderedDocument};
use attachment_native_types::{SegmentKind, TextFormat, TextSegment};
use lopdf::{Document, LoadOptions, Object, ObjectId};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) struct PdfOutcome {
    pub text: RenderResult,
    pub opaque_warnings: Vec<String>,
}

pub(crate) fn canonicalize_pdf(
    bytes: &[u8],
    limits: &DocumentLimits,
    max_output_bytes: usize,
) -> PdfOutcome {
    if bytes.len() > limits.max_pdf_input_bytes {
        return PdfOutcome {
            text: Err(ProcessorFailure::partial(
                "pdf_processor_input_limit",
                "The PDF exceeds the bounded in-process parser input limit; it remains available only as an opaque artifact.",
            )),
            opaque_warnings: vec![
                "PDF text extraction was skipped at the bounded parser input limit.".to_string(),
            ],
        };
    }
    let options = LoadOptions {
        strict: true,
        max_decompressed_size: Some(limits.max_pdf_page_decompressed_bytes),
        ..LoadOptions::default()
    };
    let mut document = match Document::load_mem_with_options(bytes, options) {
        Ok(document) => document,
        Err(_) => {
            return PdfOutcome {
                text: Err(ProcessorFailure::malformed(
                    "pdf_parse_failed",
                    "The attachment has a PDF signature but its structure is malformed, encrypted, or unsupported.",
                )),
                opaque_warnings: vec![
                    "The PDF could not be parsed safely; its original bytes remain opaque."
                        .to_string(),
                ],
            };
        }
    };
    let page_limit = usize::try_from(limits.max_pdf_pages).unwrap_or(usize::MAX);
    let all_pages = document.get_pages();
    let mut output = BoundedText::new(max_output_bytes);
    output.push("# PDF\n\n");
    let mut segments = Vec::new();
    let mut warnings = Vec::new();
    let mut issues = Vec::new();
    let mut extracted_pages = 0_u32;
    for (page, page_id) in all_pages.iter().take(page_limit) {
        if expose_inherited_resources(&mut document, *page_id).is_none() {
            let failure = ProcessorFailure::partial(
                "pdf_page_resources_unavailable",
                format!(
                    "PDF page {page} has invalid or excessively nested inherited resources and was omitted."
                ),
            );
            warnings.push(failure.safe_message.clone());
            issues.push(failure);
            continue;
        }
        let heading = format!("## Page {page}\n\n");
        let page_output_budget = output.remaining().saturating_sub(heading.len() + 2);
        if page_output_budget == 0 {
            output.push(&heading);
            output.mark_truncated();
            break;
        }
        let page_text_limit = page_output_budget.min(limits.max_pdf_page_decompressed_bytes);
        let mut page_text = BoundedText::new(page_text_limit);
        let mut page_failed = false;
        for chunk in document
            .extract_text_chunks_with_limit(&[*page], limits.max_pdf_page_decompressed_bytes)
        {
            match chunk {
                Ok(chunk) => {
                    if !page_text.push(&chunk).complete {
                        break;
                    }
                }
                Err(_) => {
                    page_failed = true;
                    break;
                }
            }
        }
        let page_text_truncated = page_text.was_truncated();
        let truncated_by_page_limit = page_text_truncated && page_text_limit < page_output_budget;
        if page_failed {
            let failure = ProcessorFailure::partial(
                "pdf_page_decode_limit_exceeded",
                format!(
                    "PDF page {page} could not be decoded within the configured decompression limit."
                ),
            );
            warnings.push(failure.safe_message.clone());
            issues.push(failure);
            continue;
        }
        if truncated_by_page_limit {
            let failure = ProcessorFailure::partial(
                "pdf_page_text_limit_exceeded",
                format!(
                    "PDF page {page} exceeded the configured per-page text limit and was omitted."
                ),
            );
            warnings.push(failure.safe_message.clone());
            issues.push(failure);
            continue;
        }
        let page_text = page_text.into_string();
        if page_text.trim().is_empty() {
            continue;
        }
        let start = output.len();
        let heading_span = output.push(&heading);
        let text_span = output.push(page_text.trim());
        let suffix_span = output.push("\n\n");
        if page_text_truncated {
            output.mark_truncated();
        }
        if output.len() > start {
            segments.push(TextSegment {
                kind: SegmentKind::Page,
                label: Some(format!("Page {page}")),
                start_byte: start,
                end_byte: output.len(),
                coordinates: Some(BTreeMap::from([("page".to_string(), page.to_string())])),
            });
            extracted_pages = extracted_pages.saturating_add(1);
        }
        if !heading_span.complete
            || !text_span.complete
            || !suffix_span.complete
            || page_text_truncated
        {
            break;
        }
    }
    if all_pages.len() > page_limit {
        let failure = ProcessorFailure::partial(
            "pdf_page_limit_exceeded",
            "PDF pages were truncated at the configured page limit.",
        );
        warnings.push(failure.safe_message.clone());
        issues.push(failure);
    }
    let output_budget_exhausted = output.was_truncated();
    let text = if extracted_pages == 0 && !output_budget_exhausted {
        Ok(None)
    } else {
        Ok(Some(RenderedDocument {
            format: TextFormat::Markdown,
            text: output.into_string(),
            segments,
            warnings: warnings.clone(),
            issues,
            output_budget_exhausted,
        }))
    };
    PdfOutcome {
        text,
        opaque_warnings: warnings,
    }
}

/// lopdf 0.44 only discovers inherited resource dictionaries by reference.
/// Promote a valid inline ancestor dictionary in the parsed working copy. Move
/// it once, rather than cloning potentially large font/resource maps per page;
/// the original PDF bytes and retained text are never rewritten.
fn expose_inherited_resources(document: &mut Document, page_id: ObjectId) -> Option<()> {
    let mut current = page_id;
    let mut visited = BTreeSet::new();
    for _ in 0..128 {
        if !visited.insert(current) {
            return None;
        }
        let node = document.get_dictionary(current).ok()?;
        if let Ok(resources) = node.get(b"Resources") {
            if current != page_id && matches!(resources, Object::Dictionary(_)) {
                let resources = document
                    .get_dictionary_mut(current)
                    .ok()?
                    .remove(b"Resources")?;
                let resource_id = document.add_object(resources);
                document
                    .get_dictionary_mut(current)
                    .ok()?
                    .set("Resources", resource_id);
            }
            return Some(());
        }
        match node.get(b"Parent") {
            Ok(parent) => current = parent.as_reference().ok()?,
            Err(_) => return Some(()),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_pdf_stays_opaque_with_explicit_failure() {
        let outcome = canonicalize_pdf(
            b"%PDF-not-a-document",
            &DocumentLimits::default(),
            usize::MAX,
        );
        assert!(matches!(
            outcome.text,
            Err(ProcessorFailure {
                code: "pdf_parse_failed",
                ..
            })
        ));
        assert!(!outcome.opaque_warnings.is_empty());
    }

    #[test]
    fn successful_page_limit_is_a_typed_partial_issue() {
        use lopdf::content::{Content, Operation};
        use lopdf::{Document, Object, Stream, dictionary};

        let mut source = Document::with_version("1.5");
        let pages_id = source.new_object_id();
        let font_id = source.add_object(dictionary! {
            "Type" => "Font",
            "Subtype" => "Type1",
            "BaseFont" => "Courier",
        });
        let resources_id = source.add_object(dictionary! {
            "Font" => dictionary! { "F1" => font_id },
        });
        let pages = ["first", "second"]
            .into_iter()
            .map(|text| {
                let content = Content {
                    operations: vec![
                        Operation::new("BT", vec![]),
                        Operation::new("Tf", vec!["F1".into(), 12.into()]),
                        Operation::new("Td", vec![72.into(), 720.into()]),
                        Operation::new("Tj", vec![Object::string_literal(text)]),
                        Operation::new("ET", vec![]),
                    ],
                };
                let content_id = source.add_object(Stream::new(
                    dictionary! {},
                    content.encode().expect("fixture content should encode"),
                ));
                source
                    .add_object(dictionary! {
                        "Type" => "Page",
                        "Parent" => pages_id,
                        "Contents" => content_id,
                    })
                    .into()
            })
            .collect::<Vec<Object>>();
        source.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => pages,
                "Count" => 2,
                "Resources" => resources_id,
                "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
            }),
        );
        let catalog_id = source.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        source.trailer.set("Root", catalog_id);
        let mut bytes = Vec::new();
        source
            .save_to(&mut bytes)
            .expect("the in-memory PDF fixture should serialize");
        let outcome = canonicalize_pdf(
            &bytes,
            &DocumentLimits {
                max_pdf_pages: 1,
                ..DocumentLimits::default()
            },
            usize::MAX,
        );
        let document = outcome
            .text
            .expect("the fixture should parse")
            .expect("the first page should produce canonical text");
        assert!(
            document
                .issues
                .iter()
                .any(|issue| issue.code == "pdf_page_limit_exceeded")
        );
        assert_eq!(document.segments.len(), 1);
        assert_eq!(
            document.segments[0]
                .coordinates
                .as_ref()
                .expect("page coordinates")["page"],
            "1"
        );
        let full = canonicalize_pdf(&bytes, &DocumentLimits::default(), usize::MAX)
            .text
            .expect("parse both pages")
            .expect("extract both pages");
        assert_eq!(full.segments.len(), 2);
        for (segment, (number, word)) in full.segments.iter().zip([(1, "first"), (2, "second")]) {
            assert_eq!(segment.kind, SegmentKind::Page);
            assert_eq!(
                segment.coordinates.as_ref().expect("page coordinates")["page"],
                number.to_string()
            );
            assert_eq!(
                &full.text[segment.start_byte..segment.end_byte],
                format!("## Page {number}\n\n{word}\n\n")
            );
        }
        let resources = source
            .get_dictionary(resources_id)
            .expect("resources")
            .clone();
        source
            .get_dictionary_mut(pages_id)
            .expect("pages")
            .set("Resources", resources);
        let mut inline = Vec::new();
        source
            .save_to(&mut inline)
            .expect("serialize inline inherited resources");
        let inline = canonicalize_pdf(&inline, &DocumentLimits::default(), usize::MAX)
            .text
            .expect("parse inline resources")
            .expect("extract inherited inline resources");
        assert_eq!(inline.text, full.text);
        assert_eq!(inline.segments, full.segments);
    }

    #[test]
    fn inherited_resource_walk_rejects_cycles() {
        let mut document = Document::with_version("1.5");
        let node_id = document.new_object_id();
        let mut node = lopdf::Dictionary::new();
        node.set("Parent", node_id);
        document.objects.insert(node_id, Object::Dictionary(node));
        assert!(expose_inherited_resources(&mut document, node_id).is_none());
    }
}
