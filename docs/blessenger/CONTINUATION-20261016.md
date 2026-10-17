# Blessenger continuation — source and evidence boundary

## Integration identity

This incremental candidate is based on `delysis/boom` branch
`blessenger/port-20261016`, commit
`6082f1d8f99f1ef3b1ba4fd7025810cac09059be`, tree
`f87b59bd89264aa51765d1cccdcf1f2a3e232b35`.
It is not the earlier `implementation.patch` and must not be applied to the old
`277e48c…` source. The latter is still the pull request's *main-branch base*, not
this patch's application base.

This continuation is unpublished. The GitHub connection available for this
session exposes repository reads and artifact downloads but no repository writes.
The supplied patch is the implementation; this note does not assert a new commit,
native build, signed bundle, or completed port.

## Implemented changes

### Bounded, ordered speech

`crates/bloom-core/src/blessenger/speech.rs` now admits a caller-specified bounded
window of speech fragments. End of source input and end of fragment admission are
separate. A long completed Read Aloud request remains one bounded source string;
the native consumer refills its fragment window as synthesis consumes it instead
of either throwing when 32 fragments are waiting or allocating an unbounded queue.
The first four complete words, final short-answer flush, stable Markdown projection,
Unicode boundaries and prefix-rewrite checks are retained. There is no new timer,
Contact-name exception, voice-provider fallback, or alternate speech store.

`SpeechPlaybackProgress` records native played-back acknowledgements separately
from production and scheduling. Out-of-order callbacks release their own capacity
but cannot credit an unacknowledged earlier interval as delivered. Retirement
freezes that prefix before unscheduling; callbacks from stop or an old player are
inert. The native output's successful terminal transition still requires input
completion, complete fragment admission, joined synthesis, an empty fragment queue,
and a drained player. This does not claim that a physical listener heard every
frame: acoustic latency/quality still require loopback and human listening.

### Explicit synthesis and exact citations

The visible Synthesize Replies action captures two to four distinct consultants'
completed replies from the current question. It uses the conversation's admitted
model and the usual request, cancellation, result, and private receipt owners.
There is no invented new user message, automatic consensus, extra consultant,
source-template mutation, or consumption of either unsent draft.

Admission verifies the captured branch, exact plan, source digests, and matching
completed consultant receipts. Output is attributed to Synthesis, not to one
therapist. Stored citations reopen the exact consulted response. Terminal
publication and backup validation bind these references to the same source set;
changed or missing replies are not silently accepted. Ordinary newly admitted
replies also retain their attachment references for the Sources disclosure.

### Editable local speech identities

A Contact's Speech Voice menu and the default voice editor now expose the existing
`BlessengerState.speechVoices` bindings. This is not another Contact library.
Editing sound leaves the exact therapist instructions/examples unchanged.
The edit captures its destination and its previous optional binding; changing
selection cannot retarget Save, and a stale save cannot overwrite a newer choice.
The compare-and-replace witness distinguishes canonically equivalent strings with
different UTF-8 bytes. Cancel writes nothing; Use Default Voice explicitly removes
only the selected Contact's override. In-flight and recorded responses retain
their captured speech routes.

Rust validates the same serialized voice value used by native Settings, persistence,
and speech preparation. The declared profile is English (`en-US`); unsupported
language selections, unbounded descriptions and invalid identifiers are rejected
rather than accepted and ignored. Descriptions design local delivery and timbre;
there is no claim of cloning the named therapist or of training a model.

### Qualification wiring

The native-candidate workflow now tests actual code changes and pull requests,
with read-only repository permissions and checkout credentials disabled. It no
longer imports/commits patches inside the runner. The `Blessenger` test filter
includes the new standalone synthesis, voice-binding and playback test classes;
the old `BlessengerTests` filter would miss them. The portable syntax gate now
includes nested product source directories instead of only top-level Swift files.

## Evidence

The inherited GitHub run `38924846760` archived and tested the actual base commit
above: native compilation and **34 Blessenger tests** passed. Its exact source,
compiler/runtime logs and model-free native evidence were recovered. Those passes
do **not** qualify this modified candidate. Some inherited tests use tiny actual
Gemma model objects; that is not execution of the target 12B checkpoint or a live call.

For this candidate, the local Linux checks executed:

- Rust 1.92.0: `cargo test --offline --locked -p bloom-core --features chat-layout --lib`.
- `cargo clippy --offline --locked -p bloom-core --features chat-layout --all-targets -- -D warnings`.
- `cargo fmt --all -- --check`.
- Five dependency-free Swift 6.2.1 playback tests against an exact copy of the
  production `SpeechPlaybackProgress.swift`. They exercise all 120 callback
  permutations for five packets, duplicates, old epochs, interruption and bounds.
- Swift syntax parsing of all native source files and Blessenger test files,
  YAML parsing and shell syntax checks. Syntax parsing is not native typechecking.

The delivery's JSON receipt and logs record final counts, exit statuses, hashes,
and the exact candidate tree. Existing vendored dependency warnings remain in the
Rust logs; a successful project Clippy gate is not a claim of warning-free dependencies.

Ten new synthesis/voice-binding native store tests and the five playback tests are
wired into macOS CI. The native store tests are authored but **not executed here**.
No Apple SDK, physical microphone/output, target model weights, signing identity,
Keychain dialog, new native UI screenshot or new latency distribution was available
for this candidate. No private author data or existing store was accessed.

## Requirements advanced, not release-qualified

| Requirement | This candidate's change | Outstanding evidence |
|---|---|---|
| PIPE-02/03/04/07/08 | Bounded exact-once fragment admission and terminal tail flush | Native long-response integration and real Qwen/Apple listening |
| PIPE-01/05, CALL-10, LIFE-02 | Native player acknowledgement identity, contiguous delivery, retirement | Real device callbacks, interruption and producer-join integration |
| CHAT-08, CORE-01/02/03, SOURCE-05 | Explicit captured synthesis with readable exact citations | Native store tests, UI action and real-model synthesis |
| CONTACT-03/05, SPEECH-02, MODEL-07 | Per-Contact local sound editor and exact edit witness | Native Settings/edit races and actual selected-voice playback |
| PRIVATE-03/04 | Synthesis/attempt source agreement in commit and backup | New private-store and backup round-trip tests |
| UX-06, PORT-01/02/04 | Deliberate voice edit; reuse of existing owners; non-mutating CI | Packaged visual review and full ownership audit |

## Remaining completion blockers

This is not a completed implementation or qualification of all 105 requirements.
The next source review must not confuse existing code with a passing user journey.
In particular:

1. `BlessengerMedia.history` still prepares historical originals before model
   context fitting, with a 32-source limit. Long-call/long-case behavior needs a
   whole-context-unit admission solution, exact occurrence accounting, and bounded
   decoding evidence—not a raised constant. Current call, source, MTP and KV
   owners must be preserved while resolving it.
2. `BlessengerModel.preview` still provides image/text/coverage views rather than
   complete playable authored-audio/video review and full PDF preview. Recorded
   *response* replay is implemented separately; that does not close voice-note
   review. Explicit transcript editing and other source journeys need end-to-end
   reconciliation against the specification.
3. The captured call, causal audio preparation and actual MTP/Qwen bindings in the
   base require packaged multi-turn real-model qualification. The tiny-model tests
   and the earlier native-platform timing paste cannot supply it. Required evidence
   includes input-audio-stop to actual output, both MTP modes, interruptions, echo,
   sustained memory and source/history integrity, with full failure denominators.
4. No fresh-process durable KV-restore acceptance has been established. Preserve
   the distinction between encrypted transient spill, resident reuse and restart-safe
   restoration/replay. Do not add a second cache owner or claim that disk use proves
   restart acceleration.
5. Native design QA (wide/narrow, light/dark, IME, focus, voice editing, precise
   source reopening), complete source/export/backup journeys, and the remaining
   specification/decision ledger still need closure. No main promotion or release
   acceptance follows from the component checks.

## Safe integration

Apply only to a clean isolated checkout of the exact base, first with
`git apply --check`. The application continues to use the existing private-store
contract; no migration/reset or credential rewrite is part of this patch.
A code push runs the updated native candidate workflow. On a Mac with the pinned
dependencies, the repository also supports:

```sh
scripts/bootstrap.sh
scripts/build-macos.sh "$PWD/out/blessenger-candidate-$(date -u +%Y%m%dT%H%M%SZ)" blessenger prepare
```

The `prepare` profile does not sign or launch the application. It runs the existing
build gates and produces a candidate only on success. Signed packaged live-call,
privacy and visual acceptance remain separate, explicit gates.
