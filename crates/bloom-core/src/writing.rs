//! Captured continuations may be replayed or branched independently of live edits.
use crate::{
    Error, Sampling, TEXT_LIMIT, authored_prefix, digest, document::Document, require, sampling,
};
use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    id: Uuid,
    title: String,
    digest: String,
    kind: String,
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
    require(
        recipe.prompt.len() <= 18 * TEXT_LIMIT
            && recipe.prompt.starts_with("<bos>")
            && recipe.prompt.ends_with(&prefix[start..])
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
        recipe.sources.len() <= 33
            && recipe.sources.iter().all(|source| {
                !source.id.is_nil()
                    && source.title.len() <= TEXT_LIMIT
                    && source.digest.len() == 64
                    && source.digest.bytes().all(|byte| byte.is_ascii_hexdigit())
                    && ["document", "writing-example"].contains(&source.kind.as_str())
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
