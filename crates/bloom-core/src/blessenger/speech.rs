use crate::{Error, digest, require};
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

const MAX_TEXT: usize = 65_536;
const MAX_FRAGMENT: usize = 2048;

/// Only the committed projection prefix is remembered. The native message owns
/// the text. A different token-delta partition cannot change spoken words.
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

/// Reading is a projection of visible Markdown, never a network fetch or a
/// second generated answer. Raw HTML is inert; markup and destination URLs are
/// not pronounced. Explicit code text remains text, not executable authority.
fn projection(text: &str) -> String {
    let mut result = String::new();
    let mut image_depth = 0_u32;
    for event in Parser::new_ext(text, Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH) {
        match event {
            Event::Start(Tag::Image { .. }) => image_depth += 1,
            Event::End(TagEnd::Image) => image_depth = image_depth.saturating_sub(1),
            Event::Text(value) | Event::Code(value) if image_depth == 0 => result.push_str(&value),
            Event::SoftBreak | Event::HardBreak | Event::Rule => result.push('\n'),
            Event::End(
                TagEnd::Paragraph
                | TagEnd::Heading(_)
                | TagEnd::Item
                | TagEnd::CodeBlock
                | TagEnd::TableRow,
            ) => {
                if !result.ends_with('\n') {
                    result.push('\n');
                }
            }
            _ => {}
        }
    }
    // Paragraph-ending whitespace supplied by the parser is provisional. Use
    // one stable separator, and expose a trailing separator only when actual
    // source whitespace completes the last word. "four " and "four five"
    // consequently share exactly the same already committed prefix.
    let mut stable = result.split_whitespace().collect::<Vec<_>>().join(" ");
    if !stable.is_empty() && text.chars().last().is_some_and(char::is_whitespace) {
        stable.push(' ');
    }
    stable
}

pub fn speech_fragments(
    mut cursor: SpeechCursor,
    source: &str,
    finished: bool,
) -> Result<SpeechEmission, Error> {
    require(
        source.len() <= MAX_TEXT && cursor.bytes <= MAX_TEXT && cursor.next <= 512,
        "The speech text exceeds its bounded response.",
    )?;
    let text = projection(source);
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
    let mut fragments = Vec::new();
    loop {
        let tail = &text[cursor.bytes..];
        if tail.is_empty() {
            break;
        }
        let target = if cursor.next == 0 { 4 } else { 16 };
        let mut words = 0;
        let mut cut = None;
        for (start, word) in tail.unicode_word_indices() {
            let end = start + word.len();
            let next = tail[end..].chars().next();
            // Apostrophes and hyphens can continue an unfinished word. A plain
            // boundary at the current end is not complete until finalization.
            let complete =
                finished || next.is_some_and(|c| c.is_whitespace() || ",.!?;:)]}\"”»".contains(c));
            if !complete {
                break;
            }
            words += 1;
            let mut boundary = end;
            for (offset, c) in tail[end..].char_indices() {
                if c.is_whitespace() || ",.!?;:)]}\"”»".contains(c) {
                    boundary = end + offset + c.len_utf8();
                } else {
                    break;
                }
            }
            let sentence = tail[end..boundary].chars().any(|c| ".!?;\n".contains(c));
            if (words >= target || (cursor.next > 0 && sentence)) && boundary <= MAX_FRAGMENT {
                cut = Some(boundary);
                break;
            }
            if boundary > MAX_FRAGMENT {
                break;
            }
        }
        if cut.is_none() && finished && tail.len() <= MAX_FRAGMENT {
            cut = Some(tail.len());
        }
        if cut.is_none() && tail.len() > MAX_FRAGMENT {
            // A pathological unbroken word has no safe early speech boundary.
            // Refuse it rather than drop bytes or build an unbounded TTS input.
            let boundary = tail[..tail.floor_char_boundary(MAX_FRAGMENT)]
                .char_indices()
                .filter(|(_, c)| c.is_whitespace())
                .map(|(i, c)| i + c.len_utf8())
                .next_back();
            cut = boundary.filter(|end| *end > 0);
            require(
                cut.is_some(),
                "One speech fragment exceeds 2048 bytes without a word boundary.",
            )?;
        }
        let Some(count) = cut else { break };
        require(
            cursor.next < 512,
            "The response exceeds 512 speech fragments.",
        )?;
        let end = cursor.bytes + count;
        let fragment = text[cursor.bytes..end].trim().to_string();
        if !fragment.is_empty() {
            fragments.push(Fragment {
                ordinal: cursor.next,
                text: fragment,
                start: cursor.bytes,
                end,
            });
            cursor.next += 1;
        }
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
}
