use crate::{Error, require};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TurnDecision {
    Semantic,
    ForcedTimeout,
    Explicit,
}

/// A level-triggered gate. A pause or semantic answer that arrives while the
/// inference session is preparing remains visible when readiness arrives.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CallGate {
    pub call: Uuid,
    pub epoch: u64,
    pub speaking: bool,
    pub ready: bool,
    pub muted: bool,
    pub ended: bool,
    pub paused_at: Option<u64>,
    pub decision: Option<TurnDecision>,
    pub admitted: bool,
    pub last_frame: Option<u64>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CallEvent {
    Speech {
        frame: u64,
    },
    Pause {
        epoch: u64,
        frame: u64,
    },
    Ready {
        epoch: u64,
    },
    EndOfUtterance {
        epoch: u64,
        frame: u64,
        decision: TurnDecision,
    },
    Mute {
        muted: bool,
    },
    End,
}
#[derive(Debug, Serialize)]
pub struct CallTransition {
    pub gate: CallGate,
    pub interrupt: bool,
    pub admit: bool,
    pub ignored: bool,
}

pub fn advance_call(mut gate: CallGate, event: CallEvent) -> Result<CallTransition, Error> {
    require(!gate.call.is_nil(), "A call needs a stable identity.")?;
    if gate.ended {
        return Ok(CallTransition {
            gate,
            interrupt: false,
            admit: false,
            ignored: true,
        });
    }
    let frame = match &event {
        CallEvent::Speech { frame } | CallEvent::Pause { frame, .. } => Some(*frame),
        _ => None,
    };
    if frame.is_some_and(|frame| gate.last_frame.is_some_and(|previous| frame < previous)) {
        return Ok(CallTransition {
            gate,
            interrupt: false,
            admit: false,
            ignored: true,
        });
    }
    let mut interrupt = false;
    let mut ignored = false;
    match event {
        CallEvent::End => {
            gate.ended = true;
            gate.ready = false;
            gate.speaking = false;
            interrupt = true;
        }
        CallEvent::Mute { muted } => {
            gate.muted = muted;
            if muted {
                gate.epoch = gate
                    .epoch
                    .checked_add(1)
                    .ok_or_else(|| Error("Call epoch exhausted.".into()))?;
                gate.speaking = false;
                gate.ready = false;
                gate.paused_at = None;
                gate.decision = None;
                gate.admitted = false;
            }
        }
        CallEvent::Speech { frame } => {
            require(frame <= u64::MAX / 2, "Capture frame counter is invalid.")?;
            if gate.muted {
                ignored = true;
            } else if !gate.speaking {
                gate.epoch = gate
                    .epoch
                    .checked_add(1)
                    .ok_or_else(|| Error("Call epoch exhausted.".into()))?;
                gate.speaking = true;
                gate.ready = false;
                gate.paused_at = None;
                gate.decision = None;
                gate.admitted = false;
                interrupt = true;
            }
        }
        CallEvent::Pause { epoch, frame } => {
            if epoch == 0 || epoch != gate.epoch || gate.muted || gate.admitted {
                ignored = true;
            } else {
                gate.speaking = false;
                gate.paused_at = Some(frame);
            }
        }
        CallEvent::Ready { epoch } => {
            if epoch == 0 || epoch != gate.epoch || gate.muted || gate.admitted {
                ignored = true;
            } else {
                gate.ready = true;
            }
        }
        CallEvent::EndOfUtterance {
            epoch,
            frame,
            decision,
        } => {
            if epoch != gate.epoch
                || gate.muted
                || gate.admitted
                || gate.speaking
                || gate.paused_at != Some(frame)
            {
                ignored = true;
            } else {
                gate.decision = Some(decision);
            }
        }
    }
    if !ignored && let Some(frame) = frame {
        gate.last_frame = Some(frame);
    }
    let admit = gate.epoch > 0
        && !gate.ended
        && !gate.muted
        && !gate.speaking
        && gate.ready
        && gate.paused_at.is_some()
        && gate.decision.is_some()
        && !gate.admitted;
    if admit {
        gate.admitted = true;
    }
    Ok(CallTransition {
        gate,
        interrupt,
        admit,
        ignored,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn gate() -> CallGate {
        CallGate {
            call: Uuid::from_u128(1),
            epoch: 0,
            speaking: false,
            ready: false,
            muted: false,
            ended: false,
            paused_at: None,
            decision: None,
            admitted: false,
            last_frame: None,
        }
    }
    #[test]
    fn silence_before_readiness_is_not_lost() {
        let a = advance_call(gate(), CallEvent::Speech { frame: 0 }).expect("speech");
        let a = advance_call(
            a.gate,
            CallEvent::Pause {
                epoch: 1,
                frame: 8000,
            },
        )
        .expect("pause");
        let a = advance_call(
            a.gate,
            CallEvent::EndOfUtterance {
                epoch: 1,
                frame: 8000,
                decision: TurnDecision::Semantic,
            },
        )
        .expect("eou");
        assert!(!a.admit);
        let a = advance_call(a.gate, CallEvent::Ready { epoch: 1 }).expect("ready");
        assert!(a.admit);
        assert!(
            !advance_call(a.gate, CallEvent::Ready { epoch: 1 })
                .expect("repeat")
                .admit
        );
    }
    #[test]
    fn acoustic_pause_is_not_a_semantic_end() {
        let a = advance_call(gate(), CallEvent::Speech { frame: 0 }).expect("speech");
        let a = advance_call(a.gate, CallEvent::Ready { epoch: 1 }).expect("ready");
        let a = advance_call(a.gate, CallEvent::Pause { epoch: 1, frame: 1 }).expect("pause");
        assert!(!a.admit);
    }
    #[test]
    fn resumed_speech_revokes_old_decisions_and_interrupts() {
        let a = advance_call(gate(), CallEvent::Speech { frame: 0 }).expect("speech");
        let a = advance_call(a.gate, CallEvent::Pause { epoch: 1, frame: 1 }).expect("pause");
        let a = advance_call(a.gate, CallEvent::Speech { frame: 2 }).expect("resume");
        assert!(a.interrupt);
        let a = advance_call(a.gate, CallEvent::Ready { epoch: 1 }).expect("old ready");
        assert!(a.ignored);
        let a = advance_call(
            a.gate,
            CallEvent::EndOfUtterance {
                epoch: 1,
                frame: 1,
                decision: TurnDecision::Semantic,
            },
        )
        .expect("old eou");
        assert!(a.ignored);
        assert!(!a.admit);
    }
    #[test]
    fn initial_silence_and_out_of_order_capture_do_not_admit() {
        let a =
            advance_call(gate(), CallEvent::Pause { epoch: 0, frame: 0 }).expect("initial pause");
        assert!(a.ignored);
        assert!(!a.admit);
        let a = advance_call(a.gate, CallEvent::Speech { frame: 100 }).expect("speech");
        let a = advance_call(
            a.gate,
            CallEvent::Pause {
                epoch: 1,
                frame: 99,
            },
        )
        .expect("old pause");
        assert!(a.ignored);
        assert!(a.gate.speaking);
    }
    #[test]
    fn end_and_mute_cannot_release_late_input() {
        let a = advance_call(gate(), CallEvent::Mute { muted: true }).expect("mute");
        assert!(
            advance_call(a.gate, CallEvent::Speech { frame: 0 })
                .expect("speech")
                .ignored
        );
        let a = advance_call(gate(), CallEvent::End).expect("end");
        assert!(a.interrupt);
        assert!(
            advance_call(a.gate, CallEvent::Ready { epoch: 0 })
                .expect("late")
                .ignored
        );
    }
}
