# Boom

A local macOS writing workspace: native Markdown in the center, documents/chats/personas on the left, and chat on the right. SwiftUI presents the shell; AppKit owns the editor, toolbar, menus, selection, composition and undo. The copied Rust attachment host is statically linked in-process through a small C ABI. This repository contains Swift, Rust, C and shell code, with no JavaScript or TypeScript. There is no Tauri, WebView, HTML frontend, localhost server, Python runtime, FTE, account system or cloud inference path in this product.

**Current status:** the macOS build passes 78 Swift core tests, four Rust bridge tests, strict Clippy, Swift release compilation/linking, and sealed ad-hoc local packaging. A sealed build passed the 21-check real-weight smoke, including long-source excerpts. A separate isolated attachment-routing smoke and a native editor keyboard pass also passed. Repeat these gates for a new candidate. Distribution signing, notarization, Apple model availability and a full concurrent-use UI pass remain open gates; see `ACCEPTANCE.md`.

## Repository placement

Boom is a separate native source tree. Five narrowly scoped attachment crates were copied from `delysis/native-platform` at commit `637e60b6b044230ed24ed3118615a2e5538cae83`; the app uses them through one Rust C ABI bridge. No native-kit frontend or runtime was imported. Existing applications and stores are not migrated.

The CoreML-LLM dependency is pinned to commit `18a9b5fd3d7e1f1f5d182533c94d311a7e649f7c`, tree `9d1e6548d20b9edd4b3e18da32416389aaff7cf4`. No third-party checkout or model weights are embedded in this source archive. Bootstrap verifies exact source blobs before applying the two local model-loading substitutions and appending the original integration extensions in `RuntimeAdditions/`.

## Build on the Mac

Use macOS 15 or newer, an Apple Silicon Mac, Xcode with a Swift 6 toolchain, and Rust. Build from this branch in its isolated worktree.

```sh
scripts/bootstrap.sh
scripts/build-macos.sh "$PWD/out/new-build"
open "$PWD/out/new-build/Boom.app"
```

Bootstrap obtains the exact pinned CoreML runtime, normalizes Rust with `rustfmt`, and resolves `RustBridge/Cargo.lock` and `App/Package.resolved`. Retain and review both locks. Subsequent builds use locked Cargo resolution and disabled automatic Swift resolution. The native build asks rustc for its actual static-library linker requirements.

The build records toolchain/SDK, source and lock hashes, notices, linked libraries, executable SHA-256 and bundle size. It embeds source/lock identities in the app; an unbundled `swift run` executable cannot load persistent model caches. SwiftPM resources are retained under `Contents/Resources`; the complete local test bundle is sealed with an ad-hoc signature that binds its privacy descriptions. This is not a distribution signature or notarized package.

Portable verification needs no Mac, model or third-party Swift dependency:

```sh
scripts/check-portable.sh
```

The real-weight native harness runs from the built bundle, using a model directory already imported/downloaded and verified by the application:

```sh
"out/new-build/Boom.app/Contents/MacOS/Boom" \
  --smoke \
  --model "/absolute/path/to/verified/gemma4-e2b-model-directory" \
  --evidence "/absolute/path/to/a-new-native-smoke-directory"
```

The evidence parent must already exist; the final evidence directory must not. The smoke test never substitutes a mock model and never overwrites previous evidence.

## Using the workspace

The toolbar contains the three pane toggles. Its background continues through the library sidebar. With the document and chat both open, narrowing the window below 980 points closes the library before either working pane becomes cramped; the toolbar can reopen it explicitly. The chat composer keeps its controls on one row and shortens the model badge to an accessible icon at compact widths. Small add controls in the library create documents and chats. `⌘1`, `⌘2`, `⌘3` toggle the panes. `⌘N` creates a document; `⇧⌘N` creates a chat. `⌘O` imports UTF-8 Markdown; `⇧⌘S` exports it. `⌘F` uses native Find. Documents autosave. System/light/dark appearance is in View → Appearance.

**Autocomplete:** with Gemma loaded, pause at the caret; press Tab to accept, Option-Right to accept one word, Option-Left to reverse the last accepted word, Escape to dismiss or Control-Space to request it. The grey suggestion lives in a separate display layout, not in document text, clipboard text or the undo stack before acceptance. Selection, input-method composition, editing, document switching, context changes and cancellation invalidate it. Document completion feeds a bounded authored prefix directly to the model after its beginning-of-sequence token, with no chat template. Explicitly linked documents precede that prefix. Long sources retain beginning and end excerpts inside the model's measured token budget. Option-Up/Down reserves completion navigation without moving the caret, but this CoreML export supplies only one deterministic candidate. Apple's session API is used for chat only because it does not expose raw continuation.

**Follow a document:** type `[[Style guide]]`, or use the document's context menu. `[[Display title|UUID]]` is the stable form, available through Copy Stable Reference. References resolve transitively; cycles, ambiguity, missing references and budget overflows are errors, not silent omissions. The ordered followed-document prefix is prefilled and saved in one encrypted native-KV cache slot; the active draft is outside that prefix. The user can explicitly clear the derived autocomplete cache without deleting personas.

**Consult a persona:** type `@name` in chat or click a persona. Save as Persona in a chat's context menu requires a completed conversation ending with an assistant response. It prefills that exact archived prefix, copies the actual eight native KV tensors, encrypts the record, reads it back and authenticates it before publishing readiness. A consultation restores only a matching model/runtime/prefix. Up to three named personas are consulted separately; their KV states are never merged. Rebuild is explicit after an identity change.

**Chat about a document:** start a chat from a document's context menu or attach a document through the chat paperclip menu. An “About …” chip above the composer shows and can remove the relationship. That document and its `[[links]]` are supplied on each turn. A general chat sees only its own messages, `[[references]]`, `@personas`, and attachments selected for that turn; switching the editor does not silently add a document. Right-click a message to edit and continue on a branch, branch from it, regenerate an answer on a branch, rate an answer, or copy its text.

**Work on the current document:** The compact composer menu defaults to Ask for each turn. Ask is read-only. Propose requests structured, revision-bound changes and presents old/new text with Accept and Reject. Edit explicitly grants automatic application to the current document for that operation. There is no ambient workspace or filesystem grant. Model output is accepted only as one complete JSON envelope; exact-match anchors, ambiguity, overlap, original document revision, source references and active-document identity are checked before mutation. Applied edits use native Undo and an encrypted recovery journal. Multi-persona Edit is refused; compare proposals instead.

**Composer controls:** The Ask/Propose/Edit badge shows the current authority. The paperclip menu chooses local files or pastes an image. The model badge shows the provider actually selected; Automatic prefers a loaded Gemma and otherwise uses Apple's Foundation Model when ready. Apple and Gemma can be selected explicitly when available. Neither backend exposes a genuine reasoning-level control here, so Boom does not show a switch that would have no effect. Dictate records up to 60 seconds and adds the on-device transcript to the draft. The microphone records a voice turn, sends it as Ask, and speaks a completed reply with Apple's local speech synthesizer. Both recording controls are click-to-start/click-to-stop. On macOS 26+, Boom uses `SpeechAnalyzer` only after the on-device dictation asset is installed; it requests that model asset on first use and never falls back to a network-capable recognizer. On macOS 15–25, it requires `supportsOnDeviceRecognition` and sets `requiresOnDeviceRecognition` before starting a request. If the local path is unavailable, voice input fails visibly. A transcript is held for manual insertion when the active chat or draft changes during recording. Recorded audio is a temporary WAV file removed after transcription; it is not attached to the chat.

**Attachments:** drag/drop, paste an image or use Attach. The original bytes and inspection receipt are retained encrypted. The existing Rust host performs bounded inspection and canonicalization; automatically supplied context is text only. Prepare Locally explicitly requests native PDF text extraction, first-image description, a bounded audio transcription or sampled MP4 frame descriptions. Coverage and machine-generated text are labelled. Scanned PDFs are not silently OCR'd; missing encoders and blocked/opaque inputs remain visibly unavailable. Attachment previews can show the retained inspection receipt and export original bytes.

## Model and data boundaries

When macOS 26 or newer reports the system model ready, Apple's Foundation Models framework supplies on-device chat. Raw document completion and native KV persona caches require Gemma. `--apple-smoke` tests chat when the system is ready. On a test Mac the framework reported `modelNotReady`; Boom polls for availability and can use local Gemma in the meantime. A live Apple chat gate remains open until the OS assets are ready.

The optional Gemma route is **Gemma 4 E2B through CoreML**, not E4B, 12B or a GGUF loader. The explicit default download resolves the E2B `n1024` branch to an immutable revision and selects the dependency's documented 2048-context shipping layout: four `swa` decoder chunks, four `prefill` chunks, positional sidecars, tokenizer and media assets. The prefill weight objects have the same publisher hashes as the decoder weights and are linked locally after verification, avoiding a duplicate transfer. The installer checks the required inventory before downloading, hashes every asset, checks the compiled decoder context against the model configuration, and creates a local manifest. Compatible local CoreML bundles can also be imported.

The downloader checks the Hugging Face Hub cache for verified content-addressed
blobs before transferring a file. New downloads and the flattened Boom CoreML
runtime live in that cache, respecting `HF_HUB_CACHE`, `HF_HOME` and
`XDG_CACHE_HOME`. The downloader retains verified whole files and completed
32 MiB ranges if an explicit transfer is interrupted. Choose Download again to
resume the same immutable revision. Only complete files with matching upstream
hashes enter the admitted model bundle.

`n1024` names the prefill branch; it is **not** a promise of a particular context length. The compiled decoder limits this shipping bundle to 2,048 tokens. Chat retains the current request and beginning/end excerpts of long reference sources, then removes oldest history if needed; the captured turn records the context actually sent. If the current request still cannot fit, generation is refused. Autocomplete similarly excerpts linked sources before reducing the active prefix. The core library contains a hardware-sizing policy for first-party Gemma 4 QAT variants and a measured KV-budget calculation, but the shipping CoreML runtime cannot yet load those variants, a matched MTP drafter or a larger context. No 12B/31B compatibility, latency, throughput or memory-efficiency result is claimed.

Workspace storage is under `~/Library/Application Support/Boom/`; downloaded model files are in the Hugging Face cache. Documents are ordinary UUID-named UTF-8 `.md` files. Chat/persona/source metadata, attachment originals/receipts and cache tensors are AES-GCM sealed with a separate Keychain key. Losing that key does not trigger replacement of existing private data. Corrupt, unknown-schema and missing-index cases fail without creating an empty workspace. This is an independent store, not a migration or reuse of Mom's encryption identity.

The only app-owned runtime network client is the explicit Gemma model installer. Apple's `AssetInventory` may download an on-device speech model when voice input is used; it receives a transcriber configuration, never audio content. Document/attachment links are not followed. This is a code-level boundary, **not a demonstrated OS-level per-host sandbox**; network-denied native testing remains mandatory. System framework or tokenizer behavior has not been empirically audited here.

See `ARCHITECTURE.md` for invariants and `NOTICE.md` for source provenance and license-review scope.
