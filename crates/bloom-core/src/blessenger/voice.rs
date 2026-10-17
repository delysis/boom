use crate::{Error, require};
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Apple,
    Qwen,
}

/// A presentation binding. It grants no model, network, or process authority.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpeechVoice {
    pub provider: Provider,
    pub identifier: Option<String>,
    pub description: String,
    pub locale: String,
}

pub fn validate(voice: &SpeechVoice) -> Result<bool, Error> {
    // Both shipped speech adapters currently declare English. Do not display a
    // locale control whose value is accepted and ignored by the execution route.
    require(
        voice.locale == "en-US",
        "This speech profile supports English (en-US).",
    )?;
    require(
        !voice.description.trim().is_empty()
            && voice.description.len() <= 4096
            && !voice
                .description
                .chars()
                .any(|c| c.is_control() && c != '\n' && c != '\t'),
        "A speech description needs nonempty text of at most 4096 UTF-8 bytes.",
    )?;
    if let Some(id) = &voice.identifier {
        require(
            !id.is_empty() && id.len() <= 4096 && !id.chars().any(char::is_control),
            "The speech voice identifier is invalid.",
        )?;
    }
    // Provider-specific identity/readiness is checked against installed data by
    // the native owner, not guessed from the identifier's spelling here.
    match voice.provider {
        Provider::Apple | Provider::Qwen => Ok(true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(provider: Provider) -> SpeechVoice {
        SpeechVoice {
            provider,
            identifier: None,
            description: "Warm, clear conversational English.".into(),
            locale: "en-US".into(),
        }
    }
    #[test]
    fn speech_binding_preserves_description_and_has_no_runtime_authority() {
        for provider in [Provider::Apple, Provider::Qwen] {
            let mut voice = profile(provider);
            voice.description = "  Warm.\nA measured cadence. 🪷\t".into();
            let exact = voice.description.clone();
            assert!(validate(&voice).is_ok());
            assert_eq!(voice.description, exact);
            voice.identifier = Some("not-an-installed-model".into());
            assert!(
                validate(&voice).is_ok(),
                "Native admission, not this value, proves readiness"
            );
        }
    }
    #[test]
    fn unsupported_and_unbounded_speech_settings_are_rejected() {
        let mut voice = profile(Provider::Qwen);
        for text in [
            "".to_string(),
            " \n\t".to_string(),
            "x".repeat(4097),
            "A\0B".into(),
        ] {
            voice.description = text;
            assert!(validate(&voice).is_err());
        }
        voice.description = "x".repeat(4096);
        assert!(validate(&voice).is_ok());
        voice.locale = "ro-RO".into();
        assert!(validate(&voice).is_err());
        voice.locale = "en-US".into();
        for id in ["".to_string(), "id\0".into(), "x".repeat(4097)] {
            voice.identifier = Some(id);
            assert!(validate(&voice).is_err());
        }
    }
}
