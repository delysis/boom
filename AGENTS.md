# Boom development

All development should be conducted in safe idiomatic Rust, written as if by John Carmack and reviewed as if by Linus Torvalds, unless otherwise specified. The macOS interface and model integration are native Swift, SwiftUI and AppKit; the attachment bridge is Rust with a small C ABI.

Keep this source repository free of JavaScript, TypeScript, Node tooling, web frontends and the parent native-platform gate. Use `scripts/check-portable.sh` for portable checks and `scripts/build-macos.sh` for the native Swift/Rust build. Run real model and visual UI checks when behavior changes; compilation alone does not qualify the app.

For document ghost text, pass a raw authored prefix to Gemma, with no chat turn template. Chat may use its chat template. A chat supplies only its explicit document attachment, `[[references]]`, `@personas`, selected file attachments, and its own conversation; selecting a document in the editor does not implicitly attach it. Preserve source revisions and stale checks for edits.

For interface changes, follow `DESIGN_QA.md` and inspect a built app at wide and narrow sizes before delivery. Keep user-facing controls tied to real actions.
