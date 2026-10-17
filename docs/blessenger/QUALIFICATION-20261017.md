# Blessenger: media and authorship qualification candidate

This continuation closes the source-level media/history and transcript-review
blockers recorded in `CONTINUATION-20261016.md`. It preserves the published
`652a34943a729e1a860a520342b4df538e0f21b7` implementation rather than replaying the
older `6082f1d8` patch. Native compilation and regression results must refer to the
commit/tree in their own CI artifact; an older green run cannot qualify a new tree.

## Implemented behavior

`BlessengerContext` builds chronological whole units: a user's question and every
reply to it. Rust `history_window` selects a bounded contiguous suffix BEFORE
originals are read/decrypted/decoded. The current input is mandatory; metadata
charges unique originals once and chronological media occurrences separately.
Native preparation then walks only the selected units, newest first, sharing each
original's admitted representation. A selected old compressed recording or PDF
that exceeds the actual decoded budget removes its ENTIRE unit and the older
prefix. It neither retries current decoding nor visits the newly excluded older
originals. Corruption, stale identity, and cancellation remain errors, not budget
misses. Real-tokenizer fitting slides complete units without decoding them again.
A narrowed capture cannot reintroduce an unprepared unit. A live causal input
reserves its complete maximum waveform, not just its initial one-token stub.
The retained receipt records included/omitted units, source occurrences and reason;
`Context Used` opens this disclosure without changing the conversation.

There is no raised source, frame, context, or memory limit. Exact Float32 waveform
headers are checked before sample allocation. The decoder handles non-zero-index
Data slices, rejects nonfinite samples, and cannot bypass a reservation through a
fallback decoder. Compressed audio checks admitted duration before accumulating
its samples, and checks every emitted packet as well.

`BlessengerMediaReview` displays the authenticated original, separately from its
bounded model representation. Audio/video use a negotiated in-memory AVPlayer,
with no autoplay or plaintext temporary export. PDF review shows all admitted
original pages (up to the existing 4096 review bound), not the model's eight-page
raster subset. Its navigation permits local destinations only. Closing or quitting
stops the player and joins owned recognition before releasing original bytes.

On-device recognition populates an EDITOR, not a message. Saving creates a new
immutable encrypted text attachment with original identity, previous-version link,
origin and coverage. Edited wording never replaces the waveform, prior transcript,
or sent message. Save, Attach Transcript, and Insert into Message are distinct
explicit effects. A stale original, prior version, draft, native view, caret or IME
state refuses the operation. Insertion uses one ordinary AppKit edit and native
Undo/Redo. Pure byte-bound validation precedes that edit; calling the mutating
`shouldChangeText` editing hook a second time caused the inherited Undo regression
and has been removed. A failed preflight adds no undo operation.

Library Contact removal also no longer deletes that Contact's unsent recipient
chip. The original audience, text, group name, attachments and draft revision stay
intact; normal resolution refuses the stale recipient until an explicit To-field
edit. Saved groups and previous consultations are not silently reduced.

## Component gate

The native-candidate workflow now compiles/tests ordinary source changes with a
read-only repository token and no retained checkout credential. It does not
import patches, commit, push, modify workflow permissions, launch the product,
read a production credential, download target model weights, or sign a bundle.
It records the exact source/tree, Rust/Core/native logs, model runtime source,
metallib construction, dependency-lock stability, and all failure output.

The native filter is `Blessenger`, not `BlessengerTests`: the latter excludes
standalone context, media-review, synthesis, transcript, voice-binding and playback
classes. Tests include actual private-store round trips and native text Undo,
actual AVFoundation playback negotiation, and PDFKit original-page review.
None of these is a successful physical call or target-weight model benchmark.

## Qualification procedure for the exact candidate

Start from a clean, isolated checkout. Existing author stores must not be copied,
reset or converted implicitly. Keep the pinned dependency locks unchanged.

```sh
scripts/bootstrap.sh
scripts/build-macos.sh "$PWD/out/blessenger-candidate-$(date -u +%Y%m%dT%H%M%SZ)" blessenger prepare
```

The existing `prepare` profile runs its build gates and prepares an unsigned
candidate without launching it. A real human-test bundle must use the existing
stable development-signing profile and explicit local permission. Keep its source,
dependency, executable and signature receipts together; do not mix CI debug, local
Release and older installed traces.

Use synthetic case material first. The required qualification journeys are:

1. A long conversation with over 100 media turns, a repeated original in multiple
   turns, one oversized older recording, and a deliberately unavailable excluded
   original. Send new text/audio; reopen Context Used; verify whole-unit omissions,
   exact current input, chronological occurrences, no excluded-original decoding,
   and unchanged source/history records. Repeat with a corrupt SELECTED source:
   it must fail explicitly, not be relabeled as an omission.
2. Record, stop, REVIEW, replay, cancel/review again, and explicitly send a voice
   note. Review video with soundtrack and a PDF longer than the model raster limit.
   Playback must not start from opening or restoring the sheet. Stop/close during
   preparation and after playback; reopen originals and verify their digests.
3. Transcribe on device, cancel, edit Unicode/whitespace, Save Version, reopen,
   Attach Transcript, and Insert at a captured selection. Undo/Redo must restore
   exact bytes once; Return in the transcript editor must never Send. Change the
   draft, caret, source or latest transcript while work is pending and verify
   refusal with retained edits. Backup/restore must retain all versions and originals.
4. Remove a Contact while an unsent group question exists. No recipient disappears
   from the draft and no reduced group is dispatched. Deliberate To-field removal
   permits the revised audience without changing the question or old consultations.

Then run the specification's packaged single-Contact call, four-Contact text
consultation, explicit synthesis, long Read Aloud, and interruption journeys. Use
the exact target Gemma 4 12B QAT, real admitted MTP assistant, Qwen speech voice and
turn model; compare MTP on/off without changing context, hardware or measurement
endpoints. Measure caller-audio-stop to rendered/audible responsive audio, not just
first-token or synthesis completion. Include timeouts/failures in denominators.
Inspect light/dark, wide/minimum window, keyboard/IME/focus, real credential prompts,
shutdown, echo/barge-in, long-call memory and playback continuity on the actual Mac.

Resident native KV and encrypted transient spill are implemented tiers. Do not
label transient spill as restart-safe raw KV restoration. Any accelerated-reopen
claim needs a fresh-process test naming the actual reuse/replay mechanism.

## Promotion boundary

The named media-context, review and transcript source gaps are implemented; the
new tests and current logs decide component correctness. Promotion still requires
all applicable functional-specification acceptance journeys on the exact packaged
candidate. There is no assertion here that physical calls, audio quality, latency,
restart reuse, signing or the entire 105-requirement specification are qualified.
