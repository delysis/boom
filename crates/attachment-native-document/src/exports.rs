//! Readable projections of exported conversations. Unrecognized fields remain
//! visible as JSON, so a schema change cannot silently discard evidence.
use crate::{BoundedText, DocumentLimits, ProcessorFailure, RenderResult, RenderedDocument};
use attachment_native_types::{SegmentKind, TextFormat, TextSegment};
use serde_json::Value;

pub(crate) fn conversation_export(
    value: &Value,
    limits: &DocumentLimits,
    max_output: usize,
) -> Option<RenderResult> {
    let rows = value.as_array()?;
    let claude = rows.iter().any(|row| row.get("chat_messages").is_some());
    let slack = rows.iter().any(|row| {
        row.get("type").and_then(Value::as_str) == Some("message") && row.get("ts").is_some()
    });
    if !claude && !slack {
        return None;
    }
    Some(render(rows, claude, limits, max_output))
}

fn render(
    rows: &[Value],
    claude: bool,
    limits: &DocumentLimits,
    max_output: usize,
) -> RenderResult {
    let mut output = BoundedText::new(max_output);
    let mut segments = Vec::new();
    let mut record_count = 0usize;
    for (index, row) in rows.iter().enumerate() {
        if output.was_truncated() {
            break;
        }
        if claude {
            let messages = row
                .get("chat_messages")
                .and_then(Value::as_array)
                .ok_or_else(|| malformed("A conversation is missing its chat_messages array."))?;
            let title = row
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("Untitled conversation");
            output.push("# ");
            output.push(&escape(title));
            output.push("\n\n");
            let mut metadata = row.clone();
            if let Some(object) = metadata.as_object_mut() {
                object.remove("chat_messages");
            }
            append_json(&mut output, &metadata)?;
            for (message_index, message) in messages.iter().enumerate() {
                if output.was_truncated() {
                    break;
                }
                record_count += 1;
                if record_count > limits.max_segments as usize {
                    output.mark_truncated();
                    break;
                }
                let start = output.len();
                let sender = message
                    .get("sender")
                    .and_then(Value::as_str)
                    .ok_or_else(|| malformed("A conversation message is missing its sender."))?;
                output.push("## ");
                output.push(&escape(sender));
                output.push("\n\n");
                // Claude exports occur with either content blocks or a text field.
                let mut metadata = message.clone();
                if let Some(blocks) = message.get("content").and_then(Value::as_array) {
                    for block in blocks {
                        if block.get("type").and_then(Value::as_str) == Some("text") {
                            let body = block
                                .get("text")
                                .and_then(Value::as_str)
                                .ok_or_else(|| malformed("A text block is missing text."))?;
                            output.push(&escape(body));
                            output.push("\n\n");
                            let mut metadata = block.clone();
                            if let Some(object) = metadata.as_object_mut() {
                                object.remove("type");
                                object.remove("text");
                                if !object.is_empty() {
                                    append_json(&mut output, &metadata)?;
                                }
                            }
                        } else {
                            output.push("Exported non-text block (not executed or fetched):\n\n");
                            append_json(&mut output, block)?;
                        }
                    }
                    if let Some(object) = metadata.as_object_mut() {
                        object.remove("content");
                    }
                } else if let Some(body) = message.get("text").and_then(Value::as_str) {
                    output.push(&escape(body));
                    output.push("\n\n");
                    if let Some(object) = metadata.as_object_mut() {
                        object.remove("text");
                    }
                } else {
                    return Err(malformed(
                        "A conversation message has neither content blocks nor text.",
                    ));
                }
                append_json(&mut output, &metadata)?;
                segments.push(segment(
                    start,
                    output.len(),
                    format!("/{index}/chat_messages/{message_index}"),
                ));
            }
        } else {
            record_count += 1;
            if record_count > limits.max_segments as usize {
                output.mark_truncated();
                break;
            }
            let start = output.len();
            output.push("## Slack message\n\n");
            if let Some(body) = row.get("text").and_then(Value::as_str) {
                output.push(&escape(body));
                output.push("\n\n");
                let mut metadata = row.clone();
                if let Some(object) = metadata.as_object_mut() {
                    object.remove("text");
                }
                append_json(&mut output, &metadata)?;
            } else {
                // System messages and files-only posts remain inspectable.
                append_json(&mut output, row)?;
            }
            segments.push(segment(start, output.len(), format!("/{index}")));
        }
    }
    let truncated = output.was_truncated();
    let mut document = RenderedDocument::document(TextFormat::Markdown, output.into_string());
    document.segments = segments;
    document.output_budget_exhausted = truncated;
    document.warnings.push("Conversation authorship and metadata are source claims; imported assistant text is not human-authored evidence. Linked files and media were not fetched.".to_string());
    Ok(Some(document))
}

fn segment(start: usize, end: usize, pointer: String) -> TextSegment {
    TextSegment {
        kind: SegmentKind::Document,
        label: Some(format!("JSON pointer {pointer}")),
        start_byte: start,
        end_byte: end,
        coordinates: None,
    }
}

fn append_json(output: &mut BoundedText, value: &Value) -> Result<(), ProcessorFailure> {
    if output.was_truncated() {
        return Ok(());
    }
    let text = serde_json::to_string_pretty(value)
        .map_err(|_| malformed("Export metadata could not be rendered."))?;
    // Four-space indentation prevents source strings from terminating a fence.
    for line in text.lines() {
        output.push("    ");
        output.push(line);
        output.push("\n");
    }
    output.push("\n");
    Ok(())
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn malformed(message: &str) -> ProcessorFailure {
    ProcessorFailure::malformed("conversation_export_invalid", message)
}
