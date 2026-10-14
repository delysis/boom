//! Source-preserving CommonMark styling, shared by native editors and readers.
use super::{Error, TEXT_LIMIT, require};
use pulldown_cmark::{BrokenLinkCallback, Event, LinkType, Options, Parser, Tag};
use serde::Serialize;
use std::ops::Range;
use uuid::Uuid;

fn byte_to_utf16_offsets(text: &str) -> Vec<usize> {
    let mut offsets = vec![0_usize; text.len() + 1];
    let mut utf16 = 0;
    for (byte, character) in text.char_indices() {
        offsets[byte] = utf16;
        utf16 += character.len_utf16();
    }
    offsets[text.len()] = utf16;
    offsets
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MediaSpan {
    pub id: Uuid,
    pub location: usize,
    pub length: usize,
}

/// Only parsed local links may become media. Code, malformed identities and
/// remote URLs remain prose; the original UTF-16 positions never change.
pub fn media_spans(text: &str) -> Result<Vec<MediaSpan>, Error> {
    require(text.len() <= TEXT_LIMIT, "Markdown exceeds 2 MiB.")?;
    media_from_parser(text, Parser::new(text))
}
fn media_from_parser<'a, F: BrokenLinkCallback<'a>>(
    text: &'a str,
    parser: Parser<'a, F>,
) -> Result<Vec<MediaSpan>, Error> {
    media_from_parser_cancelled(text, parser, &mut || false)
}
fn media_from_parser_cancelled<'a, F: BrokenLinkCallback<'a>>(
    text: &'a str,
    parser: Parser<'a, F>,
    cancelled: &mut impl FnMut() -> bool,
) -> Result<Vec<MediaSpan>, Error> {
    let mut offsets = None;
    let mut result = Vec::new();
    let mut parser = parser.into_offset_iter();
    loop {
        let Some((event, range)) = parser
            .next_with_check(cancelled)
            .map_err(|_| Error("Paged Markdown projection was cancelled.".into()))?
        else {
            break;
        };
        let Event::Start(
            Tag::Link {
                dest_url,
                link_type,
                ..
            }
            | Tag::Image {
                dest_url,
                link_type,
                ..
            },
        ) = event
        else {
            continue;
        };
        let Some(identity) = dest_url.strip_prefix("boom-attachment:") else {
            continue;
        };
        let Ok(id) = Uuid::parse_str(identity) else {
            continue;
        };
        if identity.len() != 36 {
            continue;
        }
        let range = if link_type == LinkType::Collapsed {
            // The actual Collapsed decision consumes adjacent [] while the
            // ordinary event ends at its first label. Media is one source
            // object; keep the complete marker selectable/deletable. A
            // clipped or unexpected suffix stays literal, without widening
            // any parser event or ordinary style range.
            let Some(end) = range.end.checked_add(2) else {
                continue;
            };
            if text.as_bytes().get(range.end..end) != Some(b"[]".as_slice()) {
                continue;
            }
            range.start..end
        } else {
            range
        };
        require(
            result.len() < 4096,
            "Document exceeds 4096 media references.",
        )?;
        let offsets = offsets.get_or_insert_with(|| byte_to_utf16_offsets(text));
        result.push(MediaSpan {
            id,
            location: offsets[range.start],
            length: offsets[range.end] - offsets[range.start],
        });
    }
    Ok(result)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Span {
    kind: &'static str,
    location: usize,
    length: usize,
    level: u8,
}

pub fn spans(text: &str) -> Result<Vec<Span>, Error> {
    require(text.len() <= TEXT_LIMIT, "Markdown exceeds 2 MiB.")?;
    spans_from_parser(
        text,
        Parser::new_ext(
            text,
            Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS,
        ),
    )
}
fn spans_from_parser<'a, F: BrokenLinkCallback<'a>>(
    text: &'a str,
    parser: Parser<'a, F>,
) -> Result<Vec<Span>, Error> {
    spans_from_parser_cancelled(text, parser, &mut || false, false)
}
fn spans_from_parser_cancelled<'a, F: BrokenLinkCallback<'a>>(
    text: &'a str,
    parser: Parser<'a, F>,
    cancelled: &mut impl FnMut() -> bool,
    include_html: bool,
) -> Result<Vec<Span>, Error> {
    let mut offsets = None;
    let mut result = Vec::new();
    let mut add = |kind, range: Range<usize>, level| {
        if range.start < range.end && result.len() < 20_000 {
            let offsets = offsets.get_or_insert_with(|| byte_to_utf16_offsets(text));
            result.push(Span {
                kind,
                location: offsets[range.start],
                length: offsets[range.end] - offsets[range.start],
                level,
            });
        }
    };
    let mut parser = parser.into_offset_iter();
    loop {
        let Some((event, range)) = parser
            .next_with_check(cancelled)
            .map_err(|_| Error("Paged Markdown projection was cancelled.".into()))?
        else {
            break;
        };
        let source = &text[range.clone()];
        match event {
            Event::Start(tag) => {
                let (kind, level, delimiter) = match tag {
                    Tag::Heading { level, .. } => ("heading", level as u8, ""),
                    Tag::Strong => (
                        "strong",
                        0,
                        if source.starts_with("__") { "__" } else { "**" },
                    ),
                    Tag::Emphasis => (
                        "emphasis",
                        0,
                        if source.starts_with('_') { "_" } else { "*" },
                    ),
                    Tag::Strikethrough => ("strike", 0, "~~"),
                    Tag::CodeBlock(_) => ("code", 0, ""),
                    Tag::BlockQuote(_) => ("quote", 0, ""),
                    Tag::Link { .. } => ("link", 0, ""),
                    Tag::Table(_) => ("table", 0, ""),
                    _ => continue,
                };
                add(kind, range.clone(), level);
                if !delimiter.is_empty()
                    && source.starts_with(delimiter)
                    && source.ends_with(delimiter)
                {
                    add("syntax", range.start..range.start + delimiter.len(), 0);
                    add("syntax", range.end - delimiter.len()..range.end, 0);
                }
                if kind == "heading" && source.starts_with('#') {
                    let prefix = source.len() - source.trim_start_matches(['#', ' ', '\t']).len();
                    add("syntax", range.start..range.start + prefix, 0);
                }
                if kind == "link"
                    && source.starts_with('[')
                    && let Some(end) = source.rfind(']')
                {
                    add("syntax", range.start..range.start + 1, 0);
                    add("syntax", range.start + end..range.end, 0);
                }
            }
            Event::Html(_) if include_html => {
                add("literal", range, 0);
            }
            Event::Code(_) => {
                add("code", range.clone(), 0);
                let ticks = source.len() - source.trim_start_matches('`').len();
                if ticks > 0 && source.ends_with(&"`".repeat(ticks)) {
                    add("syntax", range.start..range.start + ticks, 0);
                    add("syntax", range.end - ticks..range.end, 0);
                }
            }
            _ => {}
        }
    }
    require(
        result.len() < 20_000,
        "Markdown styling exceeds 20000 spans.",
    )?;
    Ok(result)
}

/// The range belongs to the exact logical window in the captured context.
/// Unknown blocks stay literal; independent completed blocks may render before
/// global EOF without acquiring any proof about unsearched references.
pub fn paged_spans(context: &bloom_text::MarkupContext) -> Result<Vec<Span>, Error> {
    paged_spans_with_cancel(context, &mut || false)
}
pub fn paged_spans_with_cancel(
    context: &bloom_text::MarkupContext,
    cancelled: &mut impl FnMut() -> bool,
) -> Result<Vec<Span>, Error> {
    require(
        context.mode == bloom_text::MarkupMode::Style,
        "Styling context has different parser options.",
    )?;
    let mut result = Vec::new();
    for (range, level) in &context.inline_headings {
        require(!cancelled(), "Paged Markdown projection was cancelled.")?;
        let first = range.start.max(context.window_start.utf16);
        let last = range.end.min(context.window_end.utf16);
        if first >= last {
            continue;
        }
        require(result.len() < 20_000, "Window styling exceeds 20000 spans.")?;
        result.push(Span {
            kind: "heading",
            location: usize::try_from(first - context.window_start.utf16)
                .map_err(|_| Error("Window heading position overflow.".into()))?,
            length: usize::try_from(last - first)
                .map_err(|_| Error("Window heading length overflow.".into()))?,
            level: *level,
        });
    }
    for style in &context.inline_styles {
        require(!cancelled(), "Paged Markdown projection was cancelled.")?;
        let first = style.start.utf16.max(context.window_start.utf16);
        let last = style.end.utf16.min(context.window_end.utf16);
        if first >= last {
            continue;
        }
        require(result.len() < 20_000, "Window styling exceeds 20000 spans.")?;
        let kind = match style.kind {
            pulldown_cmark::paged::InlineStyleKind::Strong => "strong",
            pulldown_cmark::paged::InlineStyleKind::Emphasis => "emphasis",
            pulldown_cmark::paged::InlineStyleKind::Strike => "strike",
            pulldown_cmark::paged::InlineStyleKind::Syntax => "syntax",
            pulldown_cmark::paged::InlineStyleKind::Code => "code",
            pulldown_cmark::paged::InlineStyleKind::Link => "link",
        };
        result.push(Span {
            kind,
            location: usize::try_from(first - context.window_start.utf16)
                .map_err(|_| Error("Window inline position overflow.".into()))?,
            length: usize::try_from(last - first)
                .map_err(|_| Error("Window inline length overflow.".into()))?,
            level: 0,
        });
    }
    for fragment in &context.fragments {
        require(!cancelled(), "Paged Markdown projection was cancelled.")?;
        let local = if let Some(code) = &fragment.code {
            vec![Span {
                kind: "code",
                location: fragment.text[..code.start].encode_utf16().count(),
                length: fragment.text[code.clone()].encode_utf16().count(),
                level: 0,
            }]
        } else if fragment.inline_ready {
            let definitions = context
                .definitions_for(fragment)
                .map_err(|error| Error(error.to_string()))?;
            let parser = if fragment.inline_only {
                Parser::new_inline_fragment(&fragment.text, context.mode.options())
                    .ok_or_else(|| Error("Paged inline fragment exceeds its bound.".into()))?
            } else {
                Parser::new_ext_with_containers(
                    &fragment.text,
                    context.mode.options(),
                    &fragment.containers,
                )
            };
            spans_from_parser_cancelled(
                &fragment.text,
                parser
                    .with_reference_definitions(definitions)
                    .with_reference_fuel(usize::MAX),
                cancelled,
                true,
            )?
        } else {
            Vec::new()
        };
        for span in local {
            let start = fragment
                .start
                .utf16
                .checked_add(span.location as u64)
                .ok_or_else(|| Error("Paged style coordinate overflow.".into()))?;
            let end = start
                .checked_add(span.length as u64)
                .ok_or_else(|| Error("Paged style extent overflow.".into()))?;
            let first = start.max(context.window_start.utf16);
            let last = end.min(context.window_end.utf16);
            if first < last {
                require(result.len() < 20_000, "Window styling exceeds 20000 spans.")?;
                result.push(Span {
                    kind: span.kind,
                    location: usize::try_from(first - context.window_start.utf16)
                        .map_err(|_| Error("Window style position overflow.".into()))?,
                    length: usize::try_from(last - first)
                        .map_err(|_| Error("Window style length overflow.".into()))?,
                    level: span.level,
                });
            }
        }
    }
    Ok(result)
}

/// Media syntax must fit entirely in this actual window and have complete
/// block/reference context; a partial link never acquires a media capability.
pub fn paged_media_spans(context: &bloom_text::MarkupContext) -> Result<Vec<MediaSpan>, Error> {
    paged_media_spans_with_cancel(context, &mut || false)
}
pub fn paged_media_spans_with_cancel(
    context: &bloom_text::MarkupContext,
    cancelled: &mut impl FnMut() -> bool,
) -> Result<Vec<MediaSpan>, Error> {
    require(
        context.mode == bloom_text::MarkupMode::Media,
        "Media context has different parser options.",
    )?;
    let mut result = Vec::new();
    for (id, start, end) in &context.inline_media {
        require(!cancelled(), "Paged Markdown projection was cancelled.")?;
        require(
            start.bytes < end.bytes && start.utf16 < end.utf16,
            "Invalid paged media source extent.",
        )?;
        if start.utf16 >= context.window_start.utf16 && end.utf16 <= context.window_end.utf16 {
            require(result.len() < 4096, "Window exceeds 4096 media references.")?;
            result.push(MediaSpan {
                id: *id,
                location: usize::try_from(start.utf16 - context.window_start.utf16)
                    .map_err(|_| Error("Window media position overflow.".into()))?,
                length: usize::try_from(end.utf16 - start.utf16)
                    .map_err(|_| Error("Window media extent overflow.".into()))?,
            });
        }
    }
    for fragment in &context.fragments {
        require(!cancelled(), "Paged Markdown projection was cancelled.")?;
        if !fragment.inline_ready {
            continue;
        }
        let definitions = context
            .definitions_for(fragment)
            .map_err(|error| Error(error.to_string()))?;
        let parser = if fragment.inline_only {
            Parser::new_inline_fragment(&fragment.text, context.mode.options())
                .ok_or_else(|| Error("Paged inline fragment exceeds its bound.".into()))?
        } else {
            Parser::new_ext_with_containers(
                &fragment.text,
                context.mode.options(),
                &fragment.containers,
            )
        };
        let local = media_from_parser_cancelled(
            &fragment.text,
            parser
                .with_reference_definitions(definitions)
                .with_reference_fuel(usize::MAX),
            cancelled,
        )?;
        for span in local {
            let start = fragment
                .start
                .utf16
                .checked_add(span.location as u64)
                .ok_or_else(|| Error("Paged media coordinate overflow.".into()))?;
            let end = start
                .checked_add(span.length as u64)
                .ok_or_else(|| Error("Paged media extent overflow.".into()))?;
            if start >= context.window_start.utf16 && end <= context.window_end.utf16 {
                require(result.len() < 4096, "Window exceeds 4096 media references.")?;
                result.push(MediaSpan {
                    id: span.id,
                    location: usize::try_from(start - context.window_start.utf16)
                        .map_err(|_| Error("Window media position overflow.".into()))?,
                    length: span.length,
                });
            }
        }
    }
    result.sort_by_key(|span| span.location);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn media_projection_is_source_bound_and_excludes_code_and_remote_urls() -> Result<(), Error> {
        let id = "884646c1-14b4-490d-be8c-8953af793315";
        let link = format!("[Attachment: café\\]🙂.png](boom-attachment:{id})");
        let text = format!(
            "👩‍💻 before\n{link}\nafter\n`{link}`\n\n```\n{link}\n```\n[x](https://example.com)\n[x](boom-attachment:bad)"
        );
        let spans = media_spans(&text)?;
        assert_eq!(spans.len(), 1);
        let units: Vec<_> = text.encode_utf16().collect();
        let span = &spans[0];
        assert_eq!(
            String::from_utf16_lossy(&units[span.location..span.location + span.length]),
            link
        );
        assert_eq!(span.id.to_string(), id);
        Ok(())
    }
    #[test]
    fn collapsed_media_covers_the_complete_marker_without_widening_parser_or_style_events()
    -> Result<(), Error> {
        let id = "884646c1-14b4-490d-be8c-8953af793315";
        let prefix = "Before e\u{301}🙂 ";
        for marker in ["[asset][]", "![asset][]"] {
            let tail = format!(" After\n\n[asset]: boom-attachment:{id}\n");
            let text = format!("{prefix}{marker}{tail}");
            let (event, event_range) = Parser::new(&text)
                .into_offset_iter()
                .find(|(event, _)| {
                    matches!(event, Event::Start(Tag::Link { .. } | Tag::Image { .. }))
                })
                .expect("actual ordinary collapsed Link/Image");
            assert!(
                matches!(
                    event,
                    Event::Start(
                        Tag::Link {
                            link_type: LinkType::Collapsed,
                            ..
                        } | Tag::Image {
                            link_type: LinkType::Collapsed,
                            ..
                        }
                    )
                ),
                "marker={marker:?}"
            );
            assert_eq!(
                event_range,
                prefix.len()..prefix.len() + marker.len() - 2,
                "marker={marker:?}: pinned event extent stays unchanged"
            );
            let actual = media_spans(&text)?;
            assert_eq!(actual.len(), 1, "marker={marker:?}");
            assert_eq!(actual[0].id.to_string(), id);
            assert_eq!(actual[0].location, prefix.encode_utf16().count());
            assert_eq!(
                actual[0].length,
                marker.encode_utf16().count(),
                "marker={marker:?}: media must include its actual collapsed []"
            );
            let units: Vec<_> = text.encode_utf16().collect();
            assert_eq!(
                String::from_utf16_lossy(
                    &units[actual[0].location..actual[0].location + actual[0].length]
                ),
                marker
            );
            if !marker.starts_with('!') {
                let style = spans(&text)?;
                let link = style
                    .iter()
                    .find(|span| span.kind == "link")
                    .expect("ordinary Link style");
                assert_eq!(
                    link.length,
                    marker.encode_utf16().count() - 2,
                    "style still represents the original ordinary event range"
                );
            }
        }
        let separate = format!("{prefix}[asset] [] After\n\n[asset]: boom-attachment:{id}\n");
        let actual = media_spans(&separate)?;
        assert_eq!(actual.len(), 1);
        assert_eq!(
            actual[0].length,
            "[asset]".encode_utf16().count(),
            "a distinct literal [] following a Shortcut must not be consumed"
        );
        Ok(())
    }
    #[test]
    fn plain_unicode_prefix_and_final_media_keep_original_utf16_ranges() -> Result<(), Error> {
        let prefix = "café 🙂 👩‍💻 plain prose\n".repeat(256);
        assert!(spans(&prefix)?.is_empty());
        assert!(media_spans(&prefix)?.is_empty());
        let id = "884646c1-14b4-490d-be8c-8953af793315";
        let link = format!("[tail🙂](boom-attachment:{id})");
        let text = format!("{prefix}{link}");
        let expected_location = prefix.encode_utf16().count();
        let expected_length = link.encode_utf16().count();
        let media = media_spans(&text)?;
        assert_eq!(media.len(), 1);
        assert_eq!(media[0].id.to_string(), id);
        assert_eq!(media[0].location, expected_location);
        assert_eq!(media[0].length, expected_length);
        let styled = spans(&text)?;
        let link_span = styled
            .iter()
            .find(|span| span.kind == "link")
            .expect("parsed link styling");
        assert_eq!(link_span.location, expected_location);
        assert_eq!(link_span.length, expected_length);
        assert_eq!(
            link_span.location + link_span.length,
            text.encode_utf16().count()
        );
        Ok(())
    }
    #[test]
    fn unicode_nested_traits_and_code_use_original_utf16_ranges() -> Result<(), Error> {
        let text = "👩‍💻 **bold *emphasis*** and `**literal**`\n\n# Title\n";
        let spans = spans(text)?;
        let units: Vec<_> = text.encode_utf16().collect();
        let words = |kind| {
            spans
                .iter()
                .filter(|s| s.kind == kind)
                .map(|s| String::from_utf16_lossy(&units[s.location..s.location + s.length]))
                .collect::<Vec<_>>()
        };
        assert_eq!(words("strong"), ["**bold *emphasis***"]);
        assert_eq!(words("emphasis"), ["*emphasis*"]);
        assert_eq!(words("code"), ["`**literal**`"]);
        assert_eq!(words("heading"), ["# Title\n"]);
        Ok(())
    }
}

#[cfg(test)]
#[path = "markdown_paged_tests.rs"]
mod paged_controls;
