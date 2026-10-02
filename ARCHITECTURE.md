# Architecture and invariants

## Modules

| Module | Responsibility |
|---|---|
| `Core` / `BoomCore` | Dependency-free snapshots, revisions, exact edit validation, reference graphs, Gemma prompt formatting, cache identities, cancellation flags and MP4 container policy. Portable XCTest suite. |
| `App` | AppKit/SwiftUI workspace, persistence, local installer, native media handling, one inference owner, source/proposal presentation and real-weight smoke executable. |
| `RustBridge` | Small, bounded C ABI over the five copied attachment crates in `crates/`; no filesystem/network/model authority. |
| `RuntimeAdditions` | Original additions appended to two exact pinned CoreML-LLM source files to retain file-private access without exposing arbitrary model memory. |
| `scripts` | Strict source preparation, native/static linking, packaging, identity receipts and portable checks. No CI workflow or cloud agent. |

The app does not depend on the old Loom/Mom frontends. The narrow reuse boundary is the stable attachment service, not either application's store or command surface.

## Inference and ownership

Apple Foundation Models provides a conditional on-device chat default on macOS 26 or newer when the system model reports available. Each request uses a new session. Apple's session API does not expose raw token-prefix continuation, so it does not generate document ghost text. Apple sessions are not represented as native KV persona caches. macOS 15 cannot run this public API.

`GemmaRunner` owns one model instance and one serial prediction queue. There are no independent chat/completion/media engines competing for the same mutable KV storage. The UI cancels autocomplete before foreground work, awaits its completion, and does not release foreground ownership until its work has returned. Shutdown cancels and joins foreground work, ghost work and the runner before saving and exiting. A cancellation flag is sticky; a consumer stopping its stream is not treated as proof the producer stopped.

`boomLoad` validates the admitted Gemma shape and rejects experimental environment overrides. It loads the pinned chunk engine directly rather than invoking the upstream broad chat/downloader service. Its optional prefill task and warm-up finish before the engine is published. Source `.mlpackage` compilation produces CoreML temporary compiled output; the content-verified model directory is not a compiler scratch directory. Incomplete compiled prefill directories are refused before upstream cleanup logic can delete them.

`boomRunInternal` tokenizes the actual assembled prompt, checks input/output budgets, validates tokens, then either restores an exact token prefix or starts cold. It uses available batched prefill, then serial decode. The complete decoded text is delivered to the UI rather than assumed-append-only text deltas. Incomplete Unicode is not accepted into the editor. The decoder is greedy; no FIM training claim, sampling-quality claim or speculative drafter is implied.

Chat uses Gemma turn tokens with no hidden system preamble. Document autocomplete supplies the beginning-of-sequence token, explicitly followed document text when present, and a bounded prefix of the current document. It does not use chat turns or an instruction sentence. The suffix remains in the editor and is never represented as supplied to the model. The visible suggestion stops at the first blank line and is revalidated against the live caret and source revisions before acceptance.

## Native cache format

The snapshot contains a schema, full identity, exact prefix token IDs, committed position, next predicted token and all eight logical FP16 KV tensors. Each tensor carries its name, shape and little-endian bytes. Dense storage is copied directly; padded/strided storage is serialized by logical element. Copy-back work is quiesced before reading or restoring buffers.

Restore authenticates the sealed record and validates every tensor before mutating any live buffer. Model manifest, tokenizer assets, runtime revision, generated integration-source fingerprint, app source hash, dependency-lock hash, OS, hardware identity, compute policy, context size, prompt version and prefix are bound through the identities. A prefix tokenization mismatch is a measured cold miss, not permission to reuse incompatible state. Byte-identical restore and token parity are native smoke gates, not results claimed by portable tests.

Personas retain immutable source messages and a native cache record. Cache rebuild creates a new encrypted cache and publishes the new persona record only after successful persistence; it does not rewrite a corrupt old cache in place. Replaced cache files may remain as evidence and are not automatically garbage-collected. Derived followed-document caching uses one replaceable authenticated slot plus one immutable in-memory snapshot. It excludes the active draft, preserving reuse while the writer types. No operation concatenates two independent KV caches.

## Document transactions and recovery

Markdown snapshots have a stable UUID and a content SHA-256 revision. Proposals include that exact ID/revision and a bounded list of old/new replacements. Every old anchor must occur exactly once in the captured current document; replacements cannot overlap. All replacements validate before any are applied. UTF-16 coordinates used by AppKit must also be valid Unicode boundaries; no splitting surrogate pairs or grapheme clusters.

The model receives no shell, arbitrary path, network, package install or general file-write tool. Ask has no edit authority. Propose/accepted Edit can alter only the captured active document. Followed documents are sources, not automatically editable targets. The source set and current selection are revalidated at completion and application. The filesystem writer additionally detects external modifications against the last known on-disk revision.

Before replacing a document, the app durably records the proposal and an authenticated prepared journal. The document replacement is atomic and coordinated. The live editor is updated before the final journal mark so a journal write failure cannot leave an obsolete buffer poised to overwrite the new file. The final outcome is marked applied; a receipt-write failure is surfaced explicitly. On restart, prepared/file-written journals are compared to actual before/after revisions. Matching content is labelled recovered; ambiguous outcomes require review and are not replayed blindly.

This is not a general multi-file transactional filesystem. An external non-cooperating writer can race filesystem operations, and a process/power-loss test on the target Mac remains required. User documents are plaintext intentionally. AES-GCM protects sealed private records, not the plain Markdown, process memory, swap, screenshots or an already-compromised logged-in account.

## Editor and presentation

Canonical `NSTextStorage` owns only the author's text. A separate layout manager draws the grey suggestion and displaced suffix. Tab inserts the accepted text as one native undoable action. Mouse clicks clear the temporary layout before canonical hit testing. Marked-text composition suppresses generation and external replacement; leaving the editor commits composition deliberately. Styling temporarily suppresses undo registration and delegate feedback.

The source editor is not a rendered WYSIWYG Markdown engine: delimiters remain editable, with restrained headings, emphasis, code and link styling. The custom editor was chosen to keep ghost text, source coordinates, clipboard and IME semantics explicit. Visual layout, right-to-left text, VoiceOver, wrapped ghost lines and native undo grouping remain macOS acceptance gates.

## Attachment boundary

Swift lends bounded UTF-8 display-name bytes and immutable input bytes to Rust, then frees exactly one Rust-owned result allocation. Rust catches panics at that boundary. The host supplies the existing immutable graph, preparation plan and receipt. A separate input SHA-256 is checked against Swift's bytes; the upstream graph's root ID is not assumed to be a raw digest.

Blocked inspection retains the original and raw receipt while admitting no text. Rust text preparation is capped at 256 KiB; the C response is capped at 8 MiB and original input at 64 MiB. Native transforms require an explicit action. PDF extraction retains page labels; image descriptions are of the first bounded/resized frame; audio is bounded by the loaded encoder; MP4 is sampled and does not imply full video/audio coverage. A container gate rejects external media references before AVFoundation sees MP4 bytes. Malicious or malformed media must still be exercised on the native frameworks; this is not a claim to have audited their decoders.

## Deliberate limits

One workspace/window, one loaded Gemma E2B model, one active editable document per tool operation; 2 MiB UTF-8 documents; eight attachments per turn; three independently scoped persona consultations; one persona for auto-Edit; one derived follow-cache slot; 1 GiB logical KV snapshot cap; bounded private records. No sync, accounts, plugins, embeddings/vector database, agents, arbitrary tools, automatic web fetching, implicit OCR or model conversion pipeline. Context beyond the chosen bundle is refused for chat/edit and explicitly excerpted for autocomplete.
