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
| File paste | Markdown link and inline document card | Chat attachment chip |
| Image paste | Markdown link and inline document card | Chat attachment chip |
| File drop | Markdown link and inline document card | Chat attachment chip |
| Image drop | Markdown link and inline document card | Chat attachment chip |
| File menu | Explicit document target | Explicit chat target |

Verify the saved document bytes and chat's pending attachments, then switch
between documents/chats before an import completes and check that neither
destination receives the other's payload. Re-run this matrix after adding a
new attachment type or input surface. A passing compiler check cannot prove
the route, and a chip alone cannot prove the saved document owns the file.

The composer actions occupy exactly one row. Use measured fitting to move
controls into the overflow menu only when the current width requires it; do
not select a layout from a fixed window-width cutoff. Inspect the narrowest
chat-only pane and a wide three-pane layout. Confirm all actions remain
reachable and no control is clipped or moved to a second row.

Rename a selected document and chat through both a second click and their
context menus. The title must become an editable field in the same sidebar row;
Return commits, Escape cancels, and neither path opens a modal rename alert.

Drop or choose a file while the document editor has focus and inspect the saved
Markdown link and the inline card. Reopen the document and check the retained
original, extracted text and coverage in the same document scroll. Repeat
through chat and confirm the two destinations are distinct. For audio, use a
short known-word local fixture and verify actual transcript content, not merely
that a file chip appears. Missing speech assets and failed segments must
produce a specific local error. A long recording must retain its original and
expose explicit full transcription rather than silently claiming complete
coverage.

Inspect the attachment as a reader would: the document editor should show its
file name without exposing the internal UUID or URL in ordinary reading, and
the card should open the same original after reopening the document. Test an
image, audio clip, video clip, PDF and text document. Confirm image zoom/fit,
audio play/pause and elapsed time, video controls, PDF paging, and collapsed
extracted text. Expand a long document, scroll its extracted text, collapse it,
and confirm the document remains one continuous scroll surface with an editable
caret. No attachment may create a second vertical scroll region or push the
editor into a separate apparent pane. Reopen the same document and repeat.
Switch documents and verify playback stops and memory-backed media is released.
Inspect app-owned storage for plaintext media. Copy or export the Markdown and confirm the original
attachment reference remains intact despite its styled display. Click around
the displayed reference and type nearby to catch selection or caret drift.

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
