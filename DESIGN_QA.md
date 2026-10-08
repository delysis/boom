# Bloom text and layout review

## Why this check exists

The chat composer once used a SwiftUI `Text` overlay as the placeholder for a
`TextEditor`. Its 5-point leading and 7-point top padding were guesses. The
editor's AppKit text container sets its own inset, fragment padding and line
baseline, so matching the nominal font size did not align the placeholder with
the insertion point. Earlier GUI checks established that the composer was
visible and accepted typing, but did not inspect the empty field *while focused*
or compare its placeholder with the first typed glyph. The misalignment passed
those checks.

## Layout rule

Use a native text control's prompt or draw secondary text through the same text
container that lays out the editable glyphs. Do not position a placeholder with
an independent overlay and hand tuned offsets. The same rule applies to ghost
text, search prompts and inline suggestions. Review the actual control at the
supported appearance and window sizes; font-size equality alone is not layout
evidence.

## Before handing off a text UI change

1. Build and launch the exact candidate bundle. Record its source revision,
   executable path and process identity so an older Bloom window cannot supply
   the screenshot.
2. At normal and narrow window widths, inspect the empty unfocused control,
   then focus it without typing. Confirm the placeholder and insertion point
   occupy the same first line and start position. Do this in both dark and light
   appearance if the change affects colors, focus or chrome.
3. Type the first character and compare its origin with the placeholder's
   origin. Type a second line, then erase back to empty. Check wrapping,
   selection, composition/focus, Return, Command-Return, Undo and the action row
   while the control grows. A native prompt alone is insufficient if the chosen
   control changes multiline editing behavior.
4. Capture focused-empty and typed screenshots from that same process. If any
   origin or baseline looks wrong, fix the shared layout rather than adjusting
   a screenshot-specific offset. A compilation result or unfocused screenshot
   does not close this visual check.

Keep any remaining untested state explicit in the handoff. This check is a
native UI review, separate from Swift core tests and the real-model smoke.

## Pane and command review

The window once kept three minimum-width panes visible until a resize event
crossed one threshold. Opening a pane from the toolbar or library at the same
width bypassed that check, leaving the composer clipped. Derive visible panes
from window width and the requested pane set; do not persist a temporary resize
collapse as the user's preference. At the minimum window width, open each of
library, document and chat in turn. Confirm every chat control and the send
button remain fully visible and clickable. Widen again and confirm the panes
requested before narrowing return. Check both a fresh window and a window
narrowed after launch.

The Markdown editor stores plain UTF-8. A font trait changed only temporary
display attributes, so it could never be an authoring command. All formatting
controls must edit the Markdown source through the text view's normal undo path.
For each keyboard shortcut and context menu action, select text, apply the
action, inspect both the editor and decrypted document bytes, apply it again to remove
the syntax, then undo. The native font palette and Writing Tools must not offer
formatting that cannot be represented in the saved document.

Test deletion inside Bloom separately from removing an indexed encrypted record
while Bloom is closed. An absent, corrupt, or incompatible indexed record must
stop loading with a clear error and leave the surviving records intact. Never
replace that workspace with empty state or silently remove the indexed document.

## Composer, attachment and privacy review

Edit a short chat reply in place. Its native font and wrapping must match the
conversation, its height must follow the text, and the native checkmark and
discard icons must remain adjacent with distinct hit areas and hover labels.
Click both and check the persisted result; an accessibility action returning
success does not establish that it ran. Check native Undo and Command-Return
while editing, including when the Writing menu command is enabled. Keep named voice
attribution visible, retain the original message and captured sources, and
record human edits as metadata. Generic authorship labels and prompt scaffolding
do not belong in the conversation prose. Other participants must still be named
in model input; the current assistant's own answers use their native role.

Every message has one compact action rail, aligned with its speaker's side.
Pointer entry or keyboard focus reveals timestamps, copy, edit and branch;
replies also offer one feedback menu. Reserve the rail's height so entering it
cannot reflow the transcript. Keep context-menu access as well. Check actual
button hit regions at narrow widths and edit both roles through the pencil,
save and discard through native icons, and verify originals remain encrypted.
New messages retain their creation time across generation retries, completion,
edits and branches; unknown historical times remain unknown. Test feedback
selection and removal, branch boundaries, and hidden-action keyboard focus.
Native fixture renders qualify layout states; they do not by themselves prove
physical pointer tracking or VoiceOver behavior.

Attachment ownership is chosen by the receiving surface, before inspection or
any asynchronous work. The document editor captures its document ID, revision
and insertion range; the chat composer captures its chat ID. The shared
paste/drop decoder identifies file URLs or image bytes but cannot choose a
destination. Import has no default destination. Menu commands name their
destination explicitly. If a target disappears or changes during import, stop
with a stale-target error; never silently move the attachment to the other
surface. When changing input code, inspect every cell in this routing matrix:

| Input | Document editor | Chat composer |
| --- | --- | --- |
| File paste | Source reference projected as inline media | Unboxed message media |
| Image paste | Source reference projected as inline media | Unboxed message media |
| File drop | Source reference projected as inline media | Unboxed message media |
| Image drop | Source reference projected as inline media | Unboxed message media |
| File menu | Explicit document target | Explicit chat target |

Verify the saved document bytes and chat's pending attachments, then switch
between documents/chats before an import completes and check that neither
destination receives the other's payload. Re-run this matrix after adding a
new attachment type or input surface. A passing compiler check cannot prove
the route, and a preview alone cannot prove the saved document owns the file.

The composer actions occupy exactly one row. Use measured fitting to move
controls into the overflow menu only when the current width requires it; do
not select a layout from a fixed window-width cutoff. Inspect the narrowest
chat-only pane and a wide three-pane layout. Confirm all actions remain
reachable and no control is clipped or moved to a second row.

Rename a selected document and chat through both a second click and their
context menus. The title must become an editable field in the same sidebar row;
Return commits, Escape cancels, and neither path opens a modal rename alert.

Paste or drop an image between two paragraphs. The image belongs at that position,
without a filename header, card, extraction button or permanent options menu.
Repeat with playable audio and video; preparation for assistant consumption is
automatic on explicit Send. Image description/OCR is not a paste prerequisite.
Ordinary context menus provide intentional copy, cut and export. Delete an
embedded object as a unit, undo, type on either side, and reopen. Verify source
bytes, encrypted original and insertion target separately.

`NativeInlineMedia` projects Rust-parsed local references through the shared
TextKit delegate used by display, isolated measurement and ghost layouts.
Reference characters remain the canonical source; null glyphs conceal them and
TextKit reserves the media's actual line height. Native media views use those
line rectangles. Do not create a second attachment list or independent height
calculation below an editor. Measure wide, narrow, intermediate and wide again;
assert paragraphs following media cannot overlap it. Native insertion updates
attributed ranges before source publication: caret normalization must use live
storage ranges, not the prior parser snapshot. Check typing directly before a
media object, native Undo and complete-object deletion.

Writing must pass original images and audio waveforms to the base checkpoint,
without a chat template or a substituted description/transcript. Capture original
identities and ordered occurrences in encrypted recipes. Supply only references
before the caret and in selected examples; count expanded model tokens before
admission. Context lower bounds use compiled media markers, never discarded
filename/UUID text, and suffixes cannot bisect an embedded object. Exercise a
real image batch and seeded replay, changed-image and changed-waveform controls,
automatic suggestions, and combined media. Retain every output; sensitivity and
successful decoding do not establish accurate interpretation or literary quality.
Video playback is a separate qualified action from sampled-frame analysis; this
raw writing adapter admits image/audio only.

Media preparation replaces a placeholder with a player. Attach preparation and
teardown to a stable container, not that changing conditional branch. The player
must consume its proposed area before overlays lay out; require a visible first
frame and a timeline with nonzero width, alongside playback and decoder checks.
An unboxed player that shows only controls does not pass visual acceptance.

Switch documents and verify playback stops and memory-backed media is released.
Inspect app-owned storage for plaintext media. Copy or export Markdown and confirm
its source references remain intact. An explicit copy of one embedded object
retains its original bytes for pasting into another workspace, with no plaintext
app-owned temporary file. Re-run the receiving-surface routing matrix after each
new media type.

For chunked transcription, test two consecutive segments of a real compressed
recording, then one final short segment. Each segment must contain converted
audio before recognition. Verify a recorded transcript's words and explicit
coverage separately from the conversion check.

Launch the sealed `.app` through LaunchServices and verify its signature binds
`Info.plist` and seals resources. A direct executable launch is not a privacy
permission acceptance test. On macOS 26+, test with the speech asset missing
and installed; no legacy recognition fallback is permitted. On older systems,
verify both the on-device capability check and the required on-device request
flag. Check the microphone flow separately from file audio.

Treat every decoder-to-framework handoff as a consumer contract. Valid decoded
PCM is not necessarily valid Speech input: negotiate the installed module's
format and use `SpeechAudioInput` as the sole `AnalyzerInput` construction site.
Check sample representation, rate, channels, frame counts and cancellation
before entering nonthrowing native initializers. Do not rely on catching a
framework precondition trap. A conversion-only test is insufficient: regression
tests must construct the actual framework input with microphone, stereo and
compressed-file shapes. Format tests need no installed speech asset; signed
transcription and physical microphone checks do.

After speech changes, exercise both controls through start, stop, and another
recording in a fresh public fixture. The waveform attaches playable raw audio;
the microphone inserts editable transcript text. Neither sends automatically or
opens model setup. Preparation is automatic; the intentional model picker lists
eligible local weights before downloadable Hugging Face checkpoints, with offline
import in its overflow menu. Check cancellation
followed by reuse and silence followed by reuse. Recognition owns its result
consumer and cancellation watcher; finish or cancel and join both before the
operation returns. Retain failed attempts. Never test a new diagnostic identity
against a human workspace; bind each visible fixture to a unique launch identity.

## Completion navigation and context review

With a real model loaded, create a visible ghost suggestion. Option-Right must
accept one word and its following space without moving the caret elsewhere;
Option-Left must reverse only that acceptance. Repeat twice in each direction,
then type ordinary text, switch documents and check that old acceptances cannot
be reversed into a new state. Option-Up/Down must not move the document caret.
Generate actual alternatives with MLX before checking Option-Up/Down. Record each
captured prompt, seed, model identity, token output, and failure. Requesting
alternatives from a single short suggestion must use that same captured prompt.
After partial acceptance, new generation must use the accepted manuscript prefix.

`NativeCompletionTextView` owns ghost projection and reversible word navigation
for every prose input. Manuscripts and chat inputs provide captured-state clients,
not separate key handlers or suggestion overlays. Exercise the composer and inline
editing of both speakers with real weights, context after the caret excluded,
speaker attribution retained, repeated word acceptance/reversal, typing, Undo,
marked text, focus loss and stale callbacks. Save is always explicit. Retain input
recipes, seeds, token journals and cancelled attempts in encrypted storage.
Branching from a user message rerolls in a new conversation. Branching from an
assistant reply preserves that reply without generation. Keep the parent intact.

Exercise consultation with an explicit long attachment and writing with a long
manuscript and selected prose examples. Consultation must preserve the captured
question and attributed speakers; refusal must leave the draft intact. Writing
must supply only the preceding manuscript and ordered prose examples, using the
largest contiguous recent suffix when necessary. Inspect the actual prompt and
omissions. The admitted context budget takes precedence over advertised capacity.

The ordinary writing surface is the manuscript. Check that no permanent writing
control strip or sampling popover has returned. Explore, examples, and variation
are native Writing menu actions. Empty-document Explore is disabled. Requested
alternatives appear in a temporary tray and enter the manuscript only through
explicit acceptance or branching.

Leave inline suggestions enabled while partially accepting an explored
continuation. Wait beyond the autocomplete delay, then edit the manuscript or
move its caret. The open tray must retain the same captured alternatives and
seeds, with stale acceptance disabled and branching still available. Background
autocomplete must not replace that tray with a new short candidate. Also open
the tray while a delayed autocomplete request is pending and check that the
request cannot replace the displayed choices.

Explore must advance all three alternatives in one inference batch. Inspect
the retained row seeds, shared prompt prefill and cache batch dimensions; three
concurrent single-row tasks do not establish batching. Replay a non-first row
and verify the same ordered batch seeds and all token ledgers, with that row
selected. Cancel during decoding and before the first token, then run a new
operation. Completed rows remain complete while unfinished rows retain their
partial tokens as cancelled. Benchmark matched serial and batch workloads and
retain every output; report aggregate throughput and memory separately from
individual row latency and the paired full-context 24 GiB application budget.

Every manuscript window must retain ordinary AppKit keyboard focus. Never make
a visible test editor unable to become key to avoid interrupting the user.
Background native checks live offscreen; foreground use ends automation and
hands the window over without closing it. Check a first click in the editor,
including its empty page area, then caret placement and typing during generation.
Offscreen first-responder and persistence checks are component evidence; they
do not qualify actual focused mouse/keyboard behavior or typing latency.

## Shared text engine and resize transitions

AppKit/TextKit owns prose rendering, selection and editing. SwiftUI owns pane,
row and command layout. `NativeText.swift` is the only read-only prose bridge;
`NativeTextMeasurement.swift` supplies isolated proposed-size measurement to
both reading rows and the manuscript editor. `NativeTextStyle.swift` projects Rust Markdown spans onto native text storage for
both reading and editing. Keep labels and buttons in SwiftUI. Do not add another
prose renderer or a per-surface Markdown parser.

A text surface must have exactly one frame owner. Reading rows take their frame
from SwiftUI and cannot resize themselves. Their proposed-size measurement uses
an isolated TextKit container with the same attributed source and geometry as
the display container. Speculative measurement cannot mutate the live renderer.
Invalidate size when source or styling changes, including the first empty-to-text
update; synchronize the display container only with the actual assigned width.
The direct manuscript view also takes its frame from SwiftUI and uses that same
isolated measurement helper. The chat input owns a native scrolling document;
AppKit controls that inner document's frame and reports content height through
its live native layout. Preserve Undo and IME composition in both. These are
explicit layout contracts over the same engine, not interchangeable controls.

The resize regression first reproduced 18-point rows drawing up to 237 points
of wrapped text. Before handing off a prose change, run the native populated-chat
regression and the exact bundle's `--chat-layout-smoke` in a public fixture. Resize
the same populated conversation wide, narrow, intermediate and wide again in
both appearances. Include headings, lists, Unicode, state labels, arriving text,
inline editing and expanded proposal/attachment bodies. Assert actual glyph
bounds fit assigned rows and consecutive rows do not overlap. Check speculative
measurements leave displayed glyph geometry unchanged. Inspect the resulting
native renders as well: geometry assertions do not establish visual quality.
A fresh screenshot at each width cannot substitute for this transition check.
