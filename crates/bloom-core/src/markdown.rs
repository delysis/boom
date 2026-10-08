//! Source-preserving CommonMark styling, shared by native editors and readers.
use super::{Error, TEXT_LIMIT, require};
use pulldown_cmark::{Event, Options, Parser, Tag};
use serde::Serialize;
use std::ops::Range;
use uuid::Uuid;

#[derive(Serialize)]
pub struct MediaSpan {
    pub id: Uuid,
    pub location: usize,
    pub length: usize,
}

/// Only parsed local links may become media. Code, malformed identities and
/// remote URLs remain prose; the original UTF-16 positions never change.
pub fn media_spans(text: &str) -> Result<Vec<MediaSpan>, Error> {
    require(text.len() <= TEXT_LIMIT, "Markdown exceeds 2 MiB.")?;
    let mut offsets = vec![0_usize; text.len() + 1];
    let mut utf16 = 0;
    for (byte, character) in text.char_indices() {
        offsets[byte] = utf16;
        utf16 += character.len_utf16();
    }
    offsets[text.len()] = utf16;
    let mut result = Vec::new();
    for (event, range) in Parser::new(text).into_offset_iter() {
        let Event::Start(Tag::Link { dest_url, .. } | Tag::Image { dest_url, .. }) = event else {
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
        require(
            result.len() < 4096,
            "Document exceeds 4096 media references.",
        )?;
        result.push(MediaSpan {
            id,
            location: offsets[range.start],
            length: offsets[range.end] - offsets[range.start],
        });
    }
    Ok(result)
}

#[derive(Serialize)]
pub struct Span {
    kind: &'static str,
    location: usize,
    length: usize,
    level: u8,
}

pub fn spans(text: &str) -> Result<Vec<Span>, Error> {
    require(text.len() <= TEXT_LIMIT, "Markdown exceeds 2 MiB.")?;
    let mut offsets = vec![0_usize; text.len() + 1];
    let mut utf16 = 0;
    for (byte, character) in text.char_indices() {
        offsets[byte] = utf16;
        utf16 += character.len_utf16();
    }
    offsets[text.len()] = utf16;
    let mut result = Vec::new();
    let mut add = |kind, range: Range<usize>, level| {
        if range.start < range.end && result.len() < 20_000 {
            result.push(Span {
                kind,
                location: offsets[range.start],
                length: offsets[range.end] - offsets[range.start],
                level,
            });
        }
    };
    for (event, range) in Parser::new_ext(
        text,
        Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS,
    )
    .into_offset_iter()
    {
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
