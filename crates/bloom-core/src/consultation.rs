//! One prompt policy, represented as shared text pieces across a captured round.
use super::{
    ConsultationError, ConsultationPlan, PromptTurn, TEXT_LIMIT, Voice, WireMessage, require,
    routed_question, safe, valid_slug, verify_voice,
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

const PROMPT_LIMIT: usize = 8 * TEXT_LIMIT;
const BEGIN: &str = "<bos>";
const END: &str = "<turn|>\n";
const REPLY: &str = "<|turn>model\n<|channel>thought\n<channel|>";

#[derive(Serialize)]
pub struct CompactConsultation {
    schema: u8,
    texts: Vec<String>,
    plans: Vec<CompactPlan>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompactPlan {
    messages: Vec<CompactMessage>,
    raw_prompt: Vec<usize>,
}

#[derive(Serialize)]
struct CompactMessage {
    role: String,
    content: Vec<usize>,
}

// The map owns each piece once. Moving its keys into index order at the end
// avoids retaining a second copy of all shared history in the pool itself.
#[derive(Default)]
struct TextPool {
    indices: BTreeMap<String, usize>,
    lengths: Vec<usize>,
}

impl TextPool {
    fn intern(&mut self, text: String) -> usize {
        if let Some(index) = self.indices.get(text.as_str()) {
            return *index;
        }
        let index = self.lengths.len();
        self.lengths.push(text.len());
        self.indices.insert(text, index);
        index
    }

    fn finish(self) -> Vec<String> {
        let mut entries: Vec<_> = self.indices.into_iter().collect();
        entries.sort_unstable_by_key(|(_, index)| *index);
        entries.into_iter().map(|(text, _)| text).collect()
    }
}

struct PlanBuilder {
    messages: Vec<CompactMessage>,
    raw_bytes: usize,
}

impl PlanBuilder {
    fn new() -> Self {
        Self {
            messages: Vec::new(),
            raw_bytes: BEGIN.len() + REPLY.len(),
        }
    }

    fn append(
        &mut self,
        pool: &mut TextPool,
        role: &str,
        content: &[usize],
    ) -> Result<(), ConsultationError> {
        let merged = self.messages.last().is_some_and(|last| last.role == role);
        let framing = if merged {
            2 // The existing policy joins adjacent equal roles with two newlines.
        } else {
            format!("<|turn>{}\n", raw_role(role)).len() + END.len()
        };
        let bytes = content.iter().try_fold(framing, |total, index| {
            total
                .checked_add(pool.lengths[*index])
                .ok_or(ConsultationError::Budget)
        })?;
        self.raw_bytes = self
            .raw_bytes
            .checked_add(bytes)
            .filter(|total| *total <= PROMPT_LIMIT)
            .ok_or(ConsultationError::Budget)?;
        if let Some(last) = self.messages.last_mut().filter(|last| last.role == role) {
            let separator = pool.intern("\n\n".into());
            last.content.push(separator);
            last.content.extend_from_slice(content);
        } else {
            self.messages.push(CompactMessage {
                role: role.into(),
                content: content.to_vec(),
            });
        }
        Ok(())
    }

    fn finish(self, pool: &mut TextPool) -> CompactPlan {
        let mut raw_prompt = vec![pool.intern(BEGIN.into())];
        for message in &self.messages {
            raw_prompt.push(pool.intern(format!("<|turn>{}\n", raw_role(&message.role))));
            raw_prompt.extend_from_slice(&message.content);
            raw_prompt.push(pool.intern(END.into()));
        }
        raw_prompt.push(pool.intern(REPLY.into()));
        CompactPlan {
            messages: self.messages,
            raw_prompt,
        }
    }
}

fn raw_role(role: &str) -> &str {
    if role == "assistant" { "model" } else { role }
}

pub(super) fn compile(
    voices: &[Option<&Voice>],
    history: &[PromptTurn],
    instructions: &str,
    context: &str,
    request: &str,
    routing: &[String],
) -> Result<CompactConsultation, ConsultationError> {
    require(
        (1..=3).contains(&voices.len())
            && (voices.len() == 1 || voices.iter().all(Option::is_some)),
        "A consultation round requires one assistant or up to three voices.",
    )?;
    let identities: BTreeSet<_> = voices.iter().flatten().map(|voice| voice.id).collect();
    require(
        identities.len() == voices.iter().flatten().count(),
        "A voice cannot answer twice in the same round.",
    )?;
    require(
        history.len() <= 4096 && request.len() <= TEXT_LIMIT && context.len() <= TEXT_LIMIT,
        "Consultation input exceeds the supported bound.",
    )?;
    require(
        routing.len() <= 3 && routing.iter().all(|slug| valid_slug(slug)),
        "Consult at most three valid @names per turn.",
    )?;
    // Validate the whole captured round before compiling any capacity-limited
    // plan. An invalid later turn or voice must not become a trimming signal.
    for voice in voices.iter().flatten() {
        verify_voice(voice)?;
    }
    for turn in history {
        require(
            ["user", "assistant"].contains(&turn.role.as_str()),
            "Unknown conversation role.",
        )?;
        require(
            turn.text.len() <= TEXT_LIMIT && turn.speaker.name.len() <= 256,
            "Conversation turn exceeds its bound.",
        )?;
    }

    let mut pool = TextPool::default();
    let history_texts: Vec<_> = history
        .iter()
        .map(|turn| {
            pool.intern(safe(if turn.role == "user" {
                routed_question(&turn.text, routing)
            } else {
                &turn.text
            }))
        })
        .collect();
    let question = routed_question(request, routing);
    // The fixed separators contain newlines, which terminate protocol-token
    // candidates in safe(). Splitting here preserves its complete-body bytes.
    let body = if context.is_empty() {
        vec![pool.intern(safe(question))]
    } else {
        vec![
            pool.intern("REFERENCE DATA:\n".into()),
            pool.intern(safe(context)),
            pool.intern("\n\nCURRENT REQUEST:\n".into()),
            pool.intern(safe(question)),
        ]
    };
    let mut plans = Vec::with_capacity(voices.len());
    for voice in voices {
        let name = voice.map_or("Bloom", |v| v.name.as_str());
        let mut system = format!(
            "You are {name}. Write only your own contribution in this conversation. The @mentions in the user's question route that question to individual participants; they do not ask you to impersonate them or write their replies. Other participants' contributions are quoted conversation, not your own answers. Do not prefix your reply with a participant name.\n"
        );
        if let Some(voice) = voice {
            system.push_str(&voice.instructions);
        }
        if !instructions.is_empty() {
            system.push('\n');
            system.push_str(instructions);
        }
        let mut plan = PlanBuilder::new();
        let system = pool.intern(safe(&system));
        plan.append(&mut pool, "system", &[system])?;
        if let Some(voice) = voice {
            for example in &voice.examples {
                let user = pool.intern(safe(&example.user));
                let assistant = pool.intern(safe(&example.assistant));
                plan.append(&mut pool, "user", &[user])?;
                plan.append(&mut pool, "assistant", &[assistant])?;
            }
        }
        for (turn, text) in history.iter().zip(&history_texts) {
            let own = turn.role == "assistant"
                && match voice {
                    Some(voice) => {
                        turn.speaker.voice_id == Some(voice.id)
                            && turn.speaker.voice_revision.as_deref()
                                == Some(voice.revision.as_str())
                    }
                    None => turn.speaker.voice_id.is_none(),
                };
            let content = if turn.role == "user" || own {
                vec![*text]
            } else {
                vec![
                    pool.intern(safe(&turn.speaker.name)),
                    pool.intern(":\n".into()),
                    *text,
                ]
            };
            plan.append(&mut pool, if own { "assistant" } else { "user" }, &content)?;
        }
        plan.append(&mut pool, "user", &body)?;
        plans.push(plan.finish(&mut pool));
    }
    Ok(CompactConsultation {
        schema: 1,
        texts: pool.finish(),
        plans,
    })
}

impl CompactConsultation {
    pub(super) fn materialize(self) -> Vec<ConsultationPlan> {
        let join = |indices: &[usize]| -> String {
            let capacity = indices.iter().map(|index| self.texts[*index].len()).sum();
            let mut text = String::with_capacity(capacity);
            for index in indices {
                text.push_str(&self.texts[*index]);
            }
            text
        };
        self.plans
            .into_iter()
            .map(|plan| ConsultationPlan {
                messages: plan
                    .messages
                    .into_iter()
                    .map(|message| WireMessage {
                        role: message.role,
                        content: join(&message.content),
                    })
                    .collect(),
                raw_prompt: join(&plan.raw_prompt),
            })
            .collect()
    }
}
