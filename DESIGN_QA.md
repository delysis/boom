# Boom text and layout review

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
   executable path and process identity so an older Boom window cannot supply
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
action, inspect both the editor and saved `.md` bytes, apply it again to remove
the syntax, then undo. The native font palette and Writing Tools must not offer
formatting that cannot be represented in the saved document.

For a deleted document, test both deletion inside Boom and moving the `.md`
file away while Boom is closed. Reopen with the existing workspace index and
confirm the window opens, the missing document is absent from the library, and
saved chat messages remain. Do not treat a corrupt or unreadable existing file
as missing; that should still stop with a clear error and leave its bytes intact.

## Composer, attachment and privacy review

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
Switch documents and verify playback stops and temporary video files are
removed. Copy or export the Markdown and confirm the original
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
Do not mark alternative-candidate navigation as working until the backend
actually exposes multiple candidates; the current compiled graph returns only
argmax tokens. After partial acceptance, new generation must use the accepted
prefix rather than the original prefix.

Exercise a chat with a long attached document and autocomplete with a long
followed document against the loaded model. Inspect the captured context: the
beginning and end excerpts and an omission marker must correspond to the bytes
actually sent. Keep the current chat request; if it cannot fit, refuse visibly.
The bundle's measured compiled token limit takes precedence over advertised
model architecture or a hardware sizing recommendation.
