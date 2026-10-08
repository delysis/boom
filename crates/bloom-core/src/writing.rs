//! Captured continuations may be replayed or branched independently of live edits.
use crate::{
    Error, Sampling, TEXT_LIMIT, authored_prefix, digest, document::Document, require, sampling,
};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

/// Continue authored chat text as prose, without an assistant turn template.
/// In-place editing supplies only turns preceding the edited message.
pub fn input_context(
    instructions: &str,
    history: &[crate::PromptTurn],
    speaker: &str,
    text: &str,
    caret: usize,
) -> Result<String, Error> {
    require(
        instructions.len() <= TEXT_LIMIT && history.len() <= 4096,
        "The captured input context exceeds its limit.",
    )?;
    let valid_name =
        |name: &str| !name.is_empty() && name.len() <= 256 && !name.contains(['\r', '\n']);
    require(valid_name(speaker), "Invalid input speaker.")?;
    let prefix = authored_prefix(text, caret)?;
    let mut context = String::new();
    if !instructions.is_empty() {
        context.push_str(instructions);
        context.push_str("\n\n");
    }
    for turn in history {
        require(
            ["user", "assistant"].contains(&turn.role.as_str())
                && valid_name(&turn.speaker.name)
                && turn.text.len() <= TEXT_LIMIT,
            "Invalid input history.",
        )?;
        context.push_str(&turn.speaker.name);
        context.push_str(": ");
        context.push_str(&turn.text);
        context.push_str("\n\n");
        require(
            context.len() <= TEXT_LIMIT,
            "Input history exceeds its limit.",
        )?;
    }
    context.push_str(speaker);
    context.push_str(": ");
    context.push_str(prefix);
    require(
        context.len() <= TEXT_LIMIT,
        "Input context exceeds its limit.",
    )?;
    Ok(context)
}

#[cfg(test)]
mod input_tests {
    use super::*;
    #[test]
    fn attributed_input_is_raw_prose_and_caret_bound() {
        let history = [crate::PromptTurn {
            role: "assistant".into(),
            text: "The harbor was quiet.".into(),
            speaker: crate::Speaker {
                name: "Mara".into(),
                voice_id: None,
                voice_revision: None,
            },
        }];
        let text = "Café 👩🏽‍💻. AFTER";
        let caret = "Café 👩🏽‍💻.".encode_utf16().count();
        assert_eq!(
            input_context("A story", &history, "You", text, caret).expect("valid attributed input"),
            "A story\n\nMara: The harbor was quiet.\n\nYou: Café 👩🏽‍💻."
        );
        assert!(input_context("", &history, "You", text, 6).is_err());
        assert!(input_context("", &history, "Spoof\nSpeaker", text, caret).is_err());
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HistoryEntry {
    pub id: Uuid,
    pub document_id: Uuid,
    pub max_tokens: usize,
    pub candidates: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct History {
    pub explorations: Vec<Uuid>,
    pub latest: Option<Uuid>,
}

pub fn history(document: Uuid, entries: &[HistoryEntry]) -> Result<History, Error> {
    require(
        !document.is_nil() && entries.len() <= 16_384,
        "Invalid continuation history.",
    )?;
    let mut ids = std::collections::BTreeSet::new();
    for entry in entries {
        require(
            !entry.id.is_nil()
                && !entry.document_id.is_nil()
                && ids.insert(entry.id)
                && (1..=256).contains(&entry.max_tokens)
                && entry.candidates <= 3,
            "Continuation history contains an invalid or repeated record.",
        )?;
    }
    let matching = entries
        .iter()
        .rev()
        .filter(|entry| entry.document_id == document)
        .collect::<Vec<_>>();
    // A long request or alternatives requested from a short suggestion is an
    // explicit exploration; automatic single suggestions remain out of its menu.
    let explorations = matching
        .iter()
        .filter(|entry| entry.max_tokens > 64 || entry.candidates > 1)
        .map(|entry| entry.id)
        .collect::<Vec<_>>();
    let latest = explorations
        .first()
        .copied()
        .or_else(|| matching.first().map(|entry| entry.id));
    Ok(History {
        explorations,
        latest,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    id: Uuid,
    title: String,
    digest: String,
    kind: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MediaReference {
    pub id: Uuid,
    pub name: String,
    pub root_digest: String,
    pub kind: String,
    pub text: Option<String>,
    pub source_digest: Option<String>,
    pub frame_digests: Option<Vec<String>>,
    pub video: Option<crate::storyboard::Timeline>,
}

#[derive(Serialize)]
pub struct MediaPrompt {
    pub prompt: String,
    pub media: Vec<MediaReference>,
}

pub fn compile_media_prompt(text: &str, media: &[MediaReference]) -> Result<MediaPrompt, Error> {
    require(
        text.len() <= 18 * TEXT_LIMIT && media.len() <= 8,
        "Writing media exceeds its budget.",
    )?;
    for reference in media {
        require(
            !reference.id.is_nil()
                && reference.name.len() <= 4096
                && reference.root_digest.len() == 64
                && reference
                    .root_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                && ["image", "audio", "pdf", "video", "text"].contains(&reference.kind.as_str())
                && if ["pdf", "video"].contains(&reference.kind.as_str()) {
                    reference.frame_digests.as_ref().is_some_and(|frames| {
                        (1..=if reference.kind == "video" { 16 } else { 8 }).contains(&frames.len())
                            && frames.iter().all(|digest| {
                                digest.len() == 64
                                    && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
                            })
                    })
                } else {
                    reference.frame_digests.is_none()
                }
                && if reference.kind == "text" {
                    reference
                        .text
                        .as_ref()
                        .is_some_and(|text| !text.is_empty() && text.len() <= 262_144)
                        && reference.source_digest.as_ref().is_some_and(|digest| {
                            digest.len() == 64
                                && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
                        })
                } else {
                    reference.text.is_none() && reference.source_digest.is_none()
                },
            "Invalid writing media identity.",
        )?;
        if let Some(video) = &reference.video {
            require(
                reference.kind == "video",
                "Timeline attached to non-video media.",
            )?;
            video.validate(reference.frame_digests.as_ref().map_or(0, Vec::len))?;
        }
        require(
            media
                .iter()
                .all(|other| other.id != reference.id || other == reference),
            "Conflicting writing media identities.",
        )?;
    }
    if media.is_empty() {
        return Ok(MediaPrompt {
            prompt: text.into(),
            media: Vec::new(),
        });
    }
    let mut byte_offsets = vec![0; text.encode_utf16().count() + 1];
    let mut offset = 0;
    for (byte, character) in text.char_indices() {
        byte_offsets[offset] = byte;
        offset += character.len_utf16();
    }
    byte_offsets[offset] = text.len();
    let mut prompt = String::new();
    let mut ordered = Vec::new();
    let mut cursor = 0;
    for span in crate::markdown::media_spans(text)? {
        let Some(reference) = media.iter().find(|reference| reference.id == span.id) else {
            continue;
        };
        let start = byte_offsets[span.location];
        let end = byte_offsets[span.location + span.length];
        prompt.push_str(&text[cursor..start]);
        prompt.push_str(&reference.prompt_content());
        ordered.push(reference.clone());
        cursor = end;
    }
    prompt.push_str(&text[cursor..]);
    require(
        ordered.len() <= 8,
        "Writing input exceeds eight media occurrences.",
    )?;
    Ok(MediaPrompt {
        prompt,
        media: ordered,
    })
}

impl MediaReference {
    pub fn prompt_content(&self) -> std::borrow::Cow<'_, str> {
        match self.kind.as_str() {
            "image" => "<|image|>".into(),
            "audio" => "<|audio|>".into(),
            "video" if self.video.is_some() => self
                .video
                .as_ref()
                .expect("timeline")
                .prompt_content()
                .into(),
            "pdf" | "video" => "<|image|>\n"
                .repeat(self.frame_digests.as_ref().map_or(0, Vec::len))
                .into(),
            _ => self.text.as_deref().unwrap_or("").into(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Recipe {
    pub document: Document,
    #[serde(rename = "caretUTF16")]
    caret: usize,
    sources: Vec<Source>,
    prompt: String,
    prompt_digest: String,
    source_prompt: Option<String>,
    media: Option<Vec<MediaReference>>,
    omitted_prefix_characters: usize,
    model: String,
    profile: String,
    settings: Sampling,
    max_tokens: usize,
    generation_policy: Option<crate::sampling_policy::Policy>,
}

pub fn validate(recipe: &Recipe) -> Result<bool, Error> {
    if let Some(policy) = &recipe.generation_policy {
        policy.validate()?;
    }
    let prefix = authored_prefix(&recipe.document.text, recipe.caret)?;
    let boundaries: Vec<_> = prefix
        .grapheme_indices(true)
        .map(|(index, _)| index)
        .collect();
    require(
        !recipe.document.id.is_nil()
            && !boundaries.is_empty()
            && recipe.omitted_prefix_characters < boundaries.len(),
        "The captured manuscript suffix is invalid.",
    )?;
    let start = boundaries[recipe.omitted_prefix_characters];
    let source_prompt = recipe.source_prompt.as_deref().unwrap_or(&recipe.prompt);
    let compiled = compile_media_prompt(source_prompt, recipe.media.as_deref().unwrap_or(&[]))?;
    require(
        recipe.media.as_deref().unwrap_or(&[]).iter().all(|media| {
            recipe.sources.iter().any(|source| {
                source.id == media.id
                    && source.kind
                        == if media.kind == "text" {
                            "attachment"
                        } else {
                            "media"
                        }
                    && source.digest == *media.source_digest.as_ref().unwrap_or(&media.root_digest)
            })
        }),
        "Writing media is missing its original source identity.",
    )?;
    require(
        compiled.prompt == recipe.prompt
            && recipe.media.as_deref().unwrap_or(&[]) == compiled.media,
        "The captured multimodal prompt changed.",
    )?;
    require(
        recipe.prompt.len() <= 18 * TEXT_LIMIT
            && recipe.prompt.starts_with("<bos>")
            && source_prompt.ends_with(&prefix[start..])
            && digest(recipe.prompt.as_bytes()) == recipe.prompt_digest,
        "The captured writing prompt changed; its record was retained.",
    )?;
    require(
        !recipe.model.is_empty()
            && recipe.model.len() <= 4096
            && (1..=256).contains(&recipe.max_tokens)
            && recipe.settings == sampling(&recipe.profile)?,
        "The captured writing model, sampling, or output budget is invalid.",
    )?;
    require(
        recipe.sources.len() <= 41
            && recipe.sources.iter().all(|source| {
                !source.id.is_nil()
                    && source.title.len() <= TEXT_LIMIT
                    && source.digest.len() == 64
                    && source.digest.bytes().all(|byte| byte.is_ascii_hexdigit())
                    && ["document", "writing-example", "media", "attachment"]
                        .contains(&source.kind.as_str())
            }),
        "The captured writing sources are invalid.",
    )?;
    Ok(true)
}

pub fn branch(recipe: &Recipe, continuation: &str) -> Result<String, Error> {
    validate(recipe)?;
    require(
        recipe
            .document
            .text
            .len()
            .saturating_add(continuation.len())
            <= TEXT_LIMIT,
        "The branched manuscript exceeds 2 MiB.",
    )?;
    let prefix = authored_prefix(&recipe.document.text, recipe.caret)?;
    let mut text = String::with_capacity(recipe.document.text.len() + continuation.len());
    text.push_str(prefix);
    text.push_str(continuation);
    text.push_str(&recipe.document.text[prefix.len()..]);
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn storyboard_sound_is_interleaved_and_invalid_timeline_is_rejected() -> Result<(), Error> {
        let mut video = MediaReference {
            id: Uuid::from_u128(4),
            name: "scene.mp4".into(),
            root_digest: "a".repeat(64),
            kind: "video".into(),
            text: None,
            source_digest: None,
            frame_digests: Some(vec!["b".repeat(64), "c".repeat(64)]),
            video: Some(crate::storyboard::Timeline {
                duration_ms: 70_000,
                covered_ms: 60_000,
                frame_times_ms: vec![0, 5_000],
                audio: vec![],
                detected_cuts: 1,
                omitted_cuts: 0,
                soundtrack_omitted: false,
            }),
        };
        let source = format!(
            "👩🏽‍💻\n[Attachment: video](boom-attachment:{})\nContinue:",
            video.id
        );
        assert!(
            compile_media_prompt(&source, &[video.clone()]).is_err(),
            "Long visual gap"
        );
        let timeline = video.video.as_mut().expect("timeline");
        timeline.duration_ms = 6_000;
        timeline.covered_ms = 6_000;
        timeline.audio = vec![crate::storyboard::AudioSegment {
            start_ms: 0,
            end_ms: 6_000,
            digest: "d".repeat(64),
        }];
        let compiled = compile_media_prompt(&source, &[video.clone()])?;
        assert_eq!(
            compiled.prompt,
            "👩🏽‍💻\n[Video 00:00.000]\n<|video|>\n[Video 00:05.000]\n<|video|>\n[Sound 0.000–6.000s]\n<|audio|>\n\nContinue:"
        );
        video.video.as_mut().expect("timeline").audio[0].start_ms = 1;
        assert!(
            compile_media_prompt(&source, &[video]).is_err(),
            "Overlapping audio"
        );
        Ok(())
    }
    #[test]
    fn text_and_sampled_frames_compile_with_captured_content_and_identities() -> Result<(), Error> {
        let text = MediaReference {
            id: Uuid::from_u128(3),
            name: "prose.docx".into(),
            root_digest: "a".repeat(64),
            kind: "text".into(),
            text: Some("The café was quiet. 👩‍💻".into()),
            source_digest: Some("b".repeat(64)),
            frame_digests: None,
            video: None,
        };
        let video = MediaReference {
            id: Uuid::from_u128(4),
            name: "scene.mp4".into(),
            root_digest: "c".repeat(64),
            kind: "video".into(),
            text: None,
            source_digest: None,
            frame_digests: Some(vec!["d".repeat(64), "e".repeat(64)]),
            video: None,
        };
        let source = format!(
            "<bos>[Attachment: text](boom-attachment:{})\n[Attachment: video](boom-attachment:{})\nContinue:",
            text.id, video.id
        );
        let compiled = compile_media_prompt(&source, &[text.clone(), video.clone()])?;
        assert_eq!(
            compiled.prompt,
            "<bos>The café was quiet. 👩‍💻\n<|image|>\n<|image|>\n\nContinue:"
        );
        assert_eq!(compiled.media, [text, video]);
        let mut changed = compiled.media;
        changed[1].frame_digests = Some(vec!["wrong".into()]);
        assert!(compile_media_prompt(&source, &changed).is_err());
        Ok(())
    }
    #[test]
    fn compiled_media_preserves_order_and_literal_code_and_authored_suffix() -> Result<(), Error> {
        let a = MediaReference {
            id: Uuid::from_u128(1),
            name: "café.png".into(),
            root_digest: "a".repeat(64),
            kind: "image".into(),
            text: None,
            source_digest: None,
            frame_digests: None,
            video: None,
        };
        let b = MediaReference {
            id: Uuid::from_u128(2),
            name: "recording.wav".into(),
            root_digest: "b".repeat(64),
            kind: "audio".into(),
            text: None,
            source_digest: None,
            frame_digests: None,
            video: None,
        };
        let image = format!("[Attachment: café](boom-attachment:{})", a.id);
        let audio = format!("[Attachment: audio](boom-attachment:{})", b.id);
        let source = format!(
            "<bos>👩‍💻
{audio}
`{image}`
{image}
Label:"
        );
        let compiled = compile_media_prompt(&source, &[a.clone(), b.clone()])?;
        assert_eq!(compiled.media, [b, a]);
        assert_eq!(
            compiled.prompt,
            format!(
                "<bos>👩‍💻
<|audio|>
`{image}`
<|image|>
Label:"
            )
        );
        Ok(())
    }

    #[test]
    fn history_is_document_scoped_and_preserves_explicit_sets_before_auto_suggestions()
    -> Result<(), Error> {
        let document = Uuid::new_v4();
        let other = Uuid::new_v4();
        let first = Uuid::new_v4();
        let alternatives = Uuid::new_v4();
        let automatic = Uuid::new_v4();
        let entries = [
            HistoryEntry {
                id: first,
                document_id: document,
                max_tokens: 256,
                candidates: 3,
            },
            HistoryEntry {
                id: Uuid::new_v4(),
                document_id: other,
                max_tokens: 256,
                candidates: 3,
            },
            HistoryEntry {
                id: alternatives,
                document_id: document,
                max_tokens: 64,
                candidates: 3,
            },
            HistoryEntry {
                id: automatic,
                document_id: document,
                max_tokens: 64,
                candidates: 1,
            },
        ];
        let plan = history(document, &entries)?;
        assert_eq!(plan.explorations, [alternatives, first]);
        assert_eq!(plan.latest, Some(alternatives));
        assert_eq!(history(document, &entries[3..])?.latest, Some(automatic));
        assert!(history(Uuid::new_v4(), &entries)?.latest.is_none());
        assert!(history(Uuid::nil(), &entries).is_err());
        assert!(
            history(
                document,
                &[HistoryEntry {
                    id: automatic,
                    document_id: document,
                    max_tokens: 64,
                    candidates: 4
                }]
            )
            .is_err()
        );
        assert!(
            history(
                document,
                &[HistoryEntry {
                    id: automatic,
                    document_id: document,
                    max_tokens: 0,
                    candidates: 1
                }]
            )
            .is_err()
        );
        let duplicate = HistoryEntry {
            id: first,
            document_id: document,
            max_tokens: 256,
            candidates: 3,
        };
        assert!(
            history(
                document,
                &[
                    duplicate,
                    HistoryEntry {
                        id: first,
                        document_id: other,
                        max_tokens: 256,
                        candidates: 3
                    }
                ]
            )
            .is_err()
        );
        Ok(())
    }
    fn recipe() -> Result<Recipe, serde_json::Error> {
        let prompt = "<bos>Example prose.\n\nCafé 👩‍💻 waits";
        serde_json::from_value(
            json!({"document":{"id":Uuid::new_v4(),"title":"Draft","text":"Café 👩‍💻 waits UNSEEN"},
            "caretUTF16":"Café 👩‍💻 waits".encode_utf16().count(),"sources":[],"prompt":prompt,
            "promptDigest":digest(prompt.as_bytes()),"omittedPrefixCharacters":0,"model":"public-test-model",
            "profile":"standard","settings":{"temperature":1.0,"topP":0.95,"topK":64,"minP":0.0},"maxTokens":256}),
        )
    }
    #[test]
    fn captured_branch_preserves_unicode_and_text_after_the_caret()
    -> Result<(), Box<dyn std::error::Error>> {
        let recipe = recipe()?;
        assert!(validate(&recipe)?);
        assert_eq!(
            branch(&recipe, " quietly.")?,
            "Café 👩‍💻 waits quietly. UNSEEN"
        );
        assert_eq!(recipe.document.text, "Café 👩‍💻 waits UNSEEN");
        assert!(branch(&recipe, &"x".repeat(TEXT_LIMIT)).is_err());
        Ok(())
    }
    #[test]
    fn altered_prompt_sampling_and_split_carets_reject_without_using_live_sources()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut recipe = recipe()?;
        recipe.prompt.push('x');
        assert!(validate(&recipe).is_err());
        recipe.prompt.pop();
        recipe.settings.temperature = 0.5;
        assert!(validate(&recipe).is_err());
        recipe.settings.temperature = 1.0;
        recipe.caret = 6;
        assert!(validate(&recipe).is_err());
        Ok(())
    }
}
