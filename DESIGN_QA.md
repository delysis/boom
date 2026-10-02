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
width bypassed that check, leaving the composer clipped. Keep width constraints
in the pane state transitions as well as resize handling. At the minimum window
width, open each of library, document and chat in turn. Confirm every chat
control and the send button remain fully visible and clickable. Check both a
fresh window and a window narrowed after launch.

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
