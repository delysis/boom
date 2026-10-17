use crate::{Error, digest, require};
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

const MAX_TEXT: usize = 65_536;
const MAX_FRAGMENT: usize = 2048;

/// A cursor into the stable spoken projection, never the mutable transport
/// delta. Only a verified prefix may be scheduled. Finalization is idempotent.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SpeechCursor {
    pub bytes: usize,
    pub digest: String,
    pub next: u32,
    pub finished: bool,
}
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Fragment {
    pub ordinal: u32,
    pub text: String,
    pub start: usize,
    pub end: usize,
}
#[derive(Debug, Serialize)]
pub struct SpeechEmission {
    pub cursor: SpeechCursor,
    pub fragments: Vec<Fragment>,
}

/// Markdown is not prefix-monotone: closing `**`, a link destination or an
/// entity can change earlier rendered text. Hold the unfinished construct,
/// rather than pronouncing punctuation then retracting it. This is deliberately
/// conservative for unusual Markdown; ordinary prose streams without delay.
/// Reference-style links remain provisional until finalization because a later
/// definition may resolve them. No resource is fetched by this projection.
fn stable_source_end(text: &str, finished: bool) -> usize {
    if finished {
        return text.len();
    }
    let mut open: Vec<(char, usize, usize)> = Vec::new();
    let mut i = 0;
    while i < text.len() {
        let ch = text[i..].chars().next().expect("UTF-8 boundary");
        if ch == '\\' {
            let after = i + ch.len_utf8();
            let Some(escaped) = text[after..].chars().next() else {
                return open.first().map_or(i, |v| v.2);
            };
            i = after + escaped.len_utf8();
            continue;
        }
        if ch == '`' {
            let width = text[i..].bytes().take_while(|c| *c == b'`').count();
            if open.last().is_some_and(|v| v.0 == '`' && v.1 == width) {
                open.pop();
            } else if open.last().is_none_or(|v| v.0 != '`') {
                open.push((ch, width, i));
            }
            i += width;
            continue;
        }
        if open.last().is_some_and(|v| v.0 == '`') {
            i += ch.len_utf8();
            continue;
        }
        if ch == '[' || (ch == '!' && text[i..].starts_with("![")) {
            let begin = i;
            let label = i + if ch == '!' { 2 } else { 1 };
            // An incomplete or reference link can reinterpret its entire label.
            let Some(close) = text[label..].find("](").map(|v| v + label) else {
                return open.first().map_or(begin, |v| v.2);
            };
            let mut depth = 1;
            let mut end = close + 2;
            while end < text.len() && depth > 0 {
                let c = text[end..].chars().next().expect("UTF-8 boundary");
                if c == '(' {
                    depth += 1;
                } else if c == ')' {
                    depth -= 1;
                }
                end += c.len_utf8();
            }
            if depth != 0 {
                return open.first().map_or(begin, |v| v.2);
            }
            i = end;
            continue;
        }
        if ch == '<' || ch == '&' {
            let terminal = if ch == '<' { '>' } else { ';' };
            if let Some(end) = text[i..].find(terminal) {
                i += end + 1;
                continue;
            }
            // A literal comparison/ampersand followed by whitespace is already
            // unambiguous; a possibly incomplete tag/entity is not.
            if !text[i..].chars().any(char::is_whitespace) {
                return open.first().map_or(i, |v| v.2);
            }
        }
        if ch == '*' || ch == '_' || ch == '~' {
            let width = text[i..].chars().take_while(|c| *c == ch).count();
            let before = text[..i].chars().next_back();
            let after = text[i + width..].chars().next();
            let intraword = ch == '_'
                && before.is_some_and(char::is_alphanumeric)
                && after.is_some_and(char::is_alphanumeric);
            if !intraword {
                if before.is_some_and(|c| !c.is_whitespace())
                    && open.last().is_some_and(|v| v.0 == ch && v.1 == width)
                {
                    open.pop();
                } else if after.is_none_or(|c| !c.is_whitespace()) {
                    open.push((ch, width, i));
                }
            }
            i += width;
            continue;
        }
        i += ch.len_utf8();
    }
    open.first().map_or(text.len(), |v| v.2)
}

fn projection(text: &str) -> String {
    let mut result = String::new();
    let mut image_depth = 0_u32;
    for event in Parser::new_ext(text, Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH) {
        match event {
            Event::Start(Tag::Image { .. }) => image_depth += 1,
            Event::End(TagEnd::Image) => image_depth = image_depth.saturating_sub(1),
            Event::Text(value) | Event::Code(value) if image_depth == 0 => result.push_str(&value),
            Event::SoftBreak | Event::HardBreak | Event::Rule => result.push(' '),
            Event::End(
                TagEnd::Paragraph
                | TagEnd::Heading(_)
                | TagEnd::Item
                | TagEnd::CodeBlock
                | TagEnd::TableRow,
            ) => result.push(' '),
            _ => {}
        }
    }
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn speech_fragments(
    cursor: SpeechCursor,
    source: &str,
    finished: bool,
) -> Result<SpeechEmission, Error> {
    speech_fragments_bounded(cursor, source, finished, 512)
}

/// A consumer controls its look-ahead without splitting or truncating the
/// source. Final input may need several admissions; `cursor.finished` means
/// every speakable byte has actually been admitted, not just that input ended.
pub fn speech_fragments_bounded(
    mut cursor: SpeechCursor,
    source: &str,
    finished: bool,
    maximum_fragments: usize,
) -> Result<SpeechEmission, Error> {
    require(
        (1..=512).contains(&maximum_fragments),
        "Speech admission requires between one and 512 fragment slots.",
    )?;
    require(
        source.len() <= MAX_TEXT && cursor.bytes <= MAX_TEXT && cursor.next <= 512,
        "The speech text exceeds its bounded response.",
    )?;
    let stable_end = stable_source_end(source, finished);
    let stable_source = &source[..stable_end];
    let text = projection(stable_source);
    require(
        cursor.bytes <= text.len() && text.is_char_boundary(cursor.bytes),
        "The speech prefix changed.",
    )?;
    require(
        (cursor.bytes == 0 && cursor.digest.is_empty())
            || digest(&text.as_bytes()[..cursor.bytes]) == cursor.digest,
        "Already scheduled speech cannot be rewritten by a later text delta.",
    )?;
    if cursor.finished {
        require(
            finished && cursor.bytes == text.len(),
            "Speech text arrived after its terminal boundary.",
        )?;
        return Ok(SpeechEmission {
            cursor,
            fragments: vec![],
        });
    }
    let ended_word = finished
        || stable_source
            .chars()
            .next_back()
            .is_some_and(char::is_whitespace);
    let mut fragments = Vec::new();
    while fragments.len() < maximum_fragments {
        let tail = &text[cursor.bytes..];
        if tail.trim().is_empty() {
            break;
        }
        let target = if cursor.next == 0 { 4 } else { 16 };
        let mut words = 0;
        let mut cut = None;
        let mut last_boundary = 0;
        // Whitespace-delimited lexical groups retain decimals, contractions,
        // abbreviations and punctuation with the word that owns them. A comma
        // arriving alone cannot prematurely split a future numeric token.
        let mut start = 0;
        for group in tail.split_inclusive(char::is_whitespace) {
            let content = group.trim();
            let end = start + group.trim_end().len();
            let complete = group.chars().next_back().is_some_and(char::is_whitespace) || ended_word;
            if !complete {
                break;
            }
            if !content.is_empty() {
                words += content.unicode_words().count();
                if end > MAX_FRAGMENT {
                    break;
                }
                last_boundary = end;
                let sentence = content.ends_with(['.', '!', '?', ';', '。', '！', '？']);
                if words >= target || (cursor.next > 0 && words >= 4 && sentence) {
                    cut = Some(end);
                    break;
                }
            }
            start += group.len();
        }
        if cut.is_none() && finished && tail.len() <= MAX_FRAGMENT {
            cut = Some(tail.len());
        }
        if cut.is_none() && tail.len() > MAX_FRAGMENT {
            require(
                last_boundary > 0,
                "One speech fragment exceeds 2048 bytes without a word boundary.",
            )?;
            cut = Some(last_boundary);
        }
        let Some(count) = cut else {
            break;
        };
        require(
            count > 0 && cursor.next < 512,
            "The response exceeds its speech fragment bound.",
        )?;
        let end = cursor.bytes + count;
        let fragment = text[cursor.bytes..end].trim().to_owned();
        if !fragment.is_empty() {
            fragments.push(Fragment {
                ordinal: cursor.next,
                text: fragment,
                start: cursor.bytes,
                end,
            });
            cursor.next += 1;
        }
        // Do not own a provisional trailing separator: closing Markdown can
        // remove it. The following fragment consumes its own leading spacing.
        cursor.bytes = end;
    }
    if cursor.bytes > 0 {
        cursor.digest = digest(&text.as_bytes()[..cursor.bytes]);
    }
    cursor.finished = finished && cursor.bytes == text.len();
    Ok(SpeechEmission { cursor, fragments })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_partial_fourth_word_waits_for_its_boundary() {
        let a =
            speech_fragments(SpeechCursor::default(), "One two three fou", false).expect("pending");
        assert!(a.fragments.is_empty());
        let b = speech_fragments(a.cursor, "One two three four ", false).expect("phrase");
        assert_eq!(b.fragments[0].text, "One two three four");
        let c = speech_fragments(b.cursor, "One two three four five.", true).expect("tail");
        assert_eq!(c.fragments[0].text, "five.");
        assert!(c.cursor.finished);
    }
    #[test]
    fn final_short_answers_and_unicode_are_not_stranded() {
        for text in ["Yes.", "Sí.", "是。", "🪷", "e\u{301}"] {
            let value = speech_fragments(SpeechCursor::default(), text, true).expect("short");
            assert_eq!(value.fragments.len(), 1);
            assert_eq!(value.fragments[0].text, text);
        }
    }
    #[test]
    fn arbitrary_utf8_delta_partition_does_not_duplicate_or_lose_words() {
        let text = "One two three four five six seven eight.\nA final small phrase.";
        let mut cursor = SpeechCursor::default();
        let mut pieces = Vec::new();
        for (index, character) in text.char_indices() {
            let end = index + character.len_utf8();
            let next = speech_fragments(cursor, &text[..end], end == text.len()).expect("delta");
            pieces.extend(next.fragments.into_iter().map(|fragment| fragment.text));
            cursor = next.cursor;
        }
        assert_eq!(
            pieces.join(" ").split_whitespace().collect::<Vec<_>>(),
            text.split_whitespace().collect::<Vec<_>>()
        );
        assert!(cursor.finished);
    }
    #[test]
    fn accepted_prefix_is_immutable_and_terminal_is_idempotent() {
        let a =
            speech_fragments(SpeechCursor::default(), "One two three four ", false).expect("first");
        assert!(speech_fragments(a.cursor, "One two five four ", false).is_err());
        let a = speech_fragments(SpeechCursor::default(), "Yes.", true).expect("final");
        assert!(
            speech_fragments(a.cursor.clone(), "Yes.", true)
                .expect("repeat")
                .fragments
                .is_empty()
        );
        assert!(speech_fragments(a.cursor, "Yes. More.", true).is_err());
    }
    #[test]
    fn markdown_is_read_without_fetching_link_targets_or_images() {
        let a = speech_fragments(
            SpeechCursor::default(),
            "**One** two [three](https://example.invalid) four. ![private](file:///secret)",
            true,
        )
        .expect("projection");
        assert_eq!(
            a.fragments
                .iter()
                .map(|f| f.text.as_str())
                .collect::<Vec<_>>(),
            vec!["One two three four."]
        );
    }
    #[test]
    fn invalid_cursor_and_unbounded_words_refuse() {
        let cursor = SpeechCursor {
            bytes: 1,
            ..SpeechCursor::default()
        };
        assert!(speech_fragments(cursor, "é", true).is_err());
        assert!(speech_fragments(SpeechCursor::default(), &"x".repeat(2049), true).is_err());
    }
    #[test]
    fn streamed_markdown_is_stable_at_every_unicode_boundary() {
        for text in [
            "**One two three four** five six seven eight.",
            "One two three four **five six** seven eight nine.",
            "One two three four [five six](https://example.invalid/a_(b)) seven eight.",
            "One two three four &amp; five six seven eight.",
            "One two three four `five six` seven eight.",
            "One two three four café 🪷 naïve résumé.",
            "One two three 4.25 milligrams, never 4. 25.",
            "One two three four ![not speech](https://example.invalid/a) five six.",
            "One two three four **five six seven eight ** nine**.",
        ] {
            let expected = projection(text);
            for stride in 1..=8 {
                let mut cursor = SpeechCursor::default();
                let mut spoken = Vec::new();
                let boundaries: Vec<_> =
                    text.char_indices().map(|(i, c)| i + c.len_utf8()).collect();
                for (i, end) in boundaries.iter().enumerate() {
                    if (i + 1) % stride != 0 && *end != text.len() {
                        continue;
                    }
                    let value =
                        speech_fragments(cursor, &text[..*end], *end == text.len()).expect(text);
                    spoken.extend(value.fragments.into_iter().map(|f| f.text));
                    cursor = value.cursor;
                }
                assert_eq!(spoken.join(" "), expected, "partition {stride}: {text}");
                assert!(cursor.finished);
            }
        }
    }
    #[test]
    fn punctuation_does_not_complete_a_provisional_numeric_word() {
        let first =
            speech_fragments(SpeechCursor::default(), "One two three 4.", false).expect("partial");
        assert!(first.fragments.is_empty());
        let next =
            speech_fragments(first.cursor, "One two three 4.25 ", false).expect("complete number");
        assert_eq!(next.fragments[0].text, "One two three 4.25");
    }
    #[test]
    fn a_later_reference_definition_cannot_rewrite_spoken_text() {
        let first = speech_fragments(
            SpeechCursor::default(),
            "One two three four [five six][ref] ",
            false,
        )
        .expect("provisional");
        assert_eq!(first.fragments.len(), 1);
        let next = speech_fragments(
            first.cursor,
            "One two three four [five six][ref]\n\n[ref]: https://example.invalid",
            true,
        )
        .expect("resolved");
        assert_eq!(next.fragments[0].text, "five six");
    }
    #[test]
    fn complete_long_read_aloud_drains_through_a_bounded_window() {
        let text = "One two three four five six seven eight. ".repeat(150);
        let expected = speech_fragments(SpeechCursor::default(), &text, true).expect("reference");
        assert!(expected.fragments.len() > 32);
        for limit in [1, 2, 7, 16, 32] {
            let mut cursor = SpeechCursor::default();
            let mut actual = Vec::new();
            while !cursor.finished {
                let before = cursor.bytes;
                let emission =
                    speech_fragments_bounded(cursor, &text, true, limit).expect("window");
                assert!(emission.fragments.len() <= limit);
                assert!(emission.cursor.bytes > before || emission.cursor.finished);
                cursor = emission.cursor;
                actual.extend(emission.fragments);
            }
            assert_eq!(actual, expected.fragments, "window {limit}");
            let repeated = speech_fragments_bounded(cursor, &text, true, limit).expect("repeat");
            assert!(repeated.fragments.is_empty());
            assert!(repeated.cursor.finished);
        }
    }

    #[test]
    fn bounded_admission_does_not_credit_unadmitted_words_or_accept_rewrites() {
        let first = speech_fragments_bounded(
            SpeechCursor::default(),
            "One two three four five six seven eight.",
            true,
            1,
        )
        .expect("first window");
        assert_eq!(first.fragments.len(), 1);
        assert!(!first.cursor.finished);
        assert!(speech_fragments_bounded(first.cursor.clone(), "Other text", true, 1).is_err());
        let final_part = speech_fragments_bounded(
            first.cursor,
            "One two three four five six seven eight.",
            true,
            1,
        )
        .expect("last window");
        assert_eq!(final_part.fragments[0].text, "five six seven eight.");
        assert!(final_part.cursor.finished);
        for invalid in [0, 513, usize::MAX] {
            assert!(
                speech_fragments_bounded(SpeechCursor::default(), "Yes.", true, invalid).is_err()
            );
        }
    }
}
