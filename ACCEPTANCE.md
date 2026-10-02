# Native acceptance — release is blocked until these gates pass

Native build and model receipts live in `out/`. A core test is not a native model test. Keep build/test failures, corrupt inputs and previous receipts. Never revise a receipt to make an unrun gate green.

## 1. Source and build

Run bootstrap, review both resolved lockfiles, then run the native build to a new output directory. The script must pass core tests, Rust fmt/test/Clippy, native static compilation and Swift release compilation/linking. Inspect every compiler diagnostic, not just the final exit status. Record source/tree hash, macOS, Xcode, SDK, Swift, Rust, lockfile hashes, linked libraries and bundle size. Neither bypass the upstream blob checks nor widen the model route to get a green build.

The Rust bridge's four tests and strict Clippy pass on macOS. Any native compile repair needs a new source hash. Resolved transitive licenses and notices still require review before distributing a bundle.

## 2. Explicit installation and offline inference

First launch must create only this product's new store/key and must not touch Mom/Loom's data. On macOS 26+, check Apple model availability and exercise on-device chat before installing Gemma; `modelNotReady` is a system prerequisite, not a passing Apple inference check. Gemma document completion must use raw prefixes with no chat delimiters. On macOS 15, verify Apple's unavailability is explained without a failed generation attempt. Exercise the default E2B download: resolve the actual `n1024` inventory, retain its immutable revision, reuse verified Hugging Face blobs without an asset transfer, verify every new asset and ensure the tokenizer/config/chunks are present in the cache. Exercise model import and a source `.mlpackage` bundle. Reject modified assets, missing coremldata, extra executable files, symlinks, redirects outside the allowlist, partial files and an unsupported model without deleting the source.

After a verified model is installed, deny outbound networking at the operating-system/firewall level. Chat, personas, autocomplete, PDF extraction and prepared local media must still work; start/reload must not trigger tokenizer downloads. Observe network attempts during startup and all source-link/attachment interactions. No HTTP listener or subprocess inference service may appear. Record the observation rather than inferring offline behavior from import names.

## 3. Real-weight harness

Run the exact command in README using the built `.app` executable and a fresh evidence directory. A passing `receipt.json` requires actual generation, eight nonempty KV tensors, encrypted disk save, restore into an independent loaded engine, a positive restored-token count, cold/restored token-ID parity, A/B/A isolation, unrelated-prefix cold miss, cancellation followed by parity, context overflow refusal, wrong-model rejection, tampered-ciphertext refusal, followed-document disk-cache use and token parity, and the real Rust attachment fixture. The harness uses an ephemeral test encryption key and **does not test Keychain**. It uses two model instances for isolation testing; this is not the shipping app's resident-model count or a performance benchmark.

Then test a real app quit/relaunch: save a persona, quit after joined completion, relaunch, consult it and observe a nonzero restore count without re-prefilling the cached prefix. Repeat after editing a followed document, rebuilding the binary, changing a dependency lock and changing model assets. Correct behavior is verified new identity/rebuild or a disclosed miss, never incompatible cache reuse. Corrupt records remain retained until explicit user action. Do not conflate a saved transcript with a passing KV restore.

## 4. Editor, chat and edit authority

Exercise all pane combinations, resizing, system/light/dark modes, keyboard commands, accessibility labels, native Find, focus and scrolling. Confirm there are no additional pane-visibility controls inside panes. Typing during generation stays responsive. Test IME composition (Japanese/Chinese), accented combining sequences, emoji sequences, right-to-left text, selections and long wrapped lines. Ghost text must not enter autosaved/exported Markdown, Copy, selection or undo before Tab; after Tab it is one undoable insertion. Reject stale suggestions after editing, moving the caret, changing sources, switching document, hiding the pane or cancelling.

Test empty document insert, unique anchor replacement, multiple non-overlapping edits, absent/duplicate/overlapping anchors, stale revision, concurrent external change, wrong target ID, malformed/fenced/partial JSON, exceeded context, interrupted generation and a full-disk write. Ask must never apply edits. Propose must wait. Edit must touch only the current granted document and must not modify followed documents or arbitrary files. Undo should restore the expected prior text; intervening edits must disable a stale proposal's dedicated Undo action.

Kill the app at prepared-journal, file-replacement and final-mark boundaries. Restart and verify the original files/receipts remain recoverable and the proposal is not applied twice. Missing/corrupt workspace index, unknown schema and missing/wrong Keychain key must stop safely rather than create an empty replacement workspace. Generation failure before the first token must remain visible in chat, not disappear as an ordinary completed response.

## 5. Attachments and measurement

Exercise text, PDF with text/images/attachments, DOCX, spreadsheet and archive examples through the actual retained Rust host; inspect its complete/partial/blocked receipts. Include oversized files, empty files, archive path traversal, expansion bombs and unsupported opaque data. Test native first-frame image description, scanned PDF refusal/partial coverage, bounded audio and sampled self-contained MP4. Reject remote playlists and reference movies. Verify original bytes and inspection receipts survive errors and explicit export reproduces their hash.

Finally record cold/warm first-token time, completion latency while typing, cancel-to-idle time, resident/peak memory, model count, idle CPU and app bundle size on the actual Mac. Compare against the current native-platform UI using the same model/input where meaningful. No speed, memory or "leaner binary" claim is admitted before these measurements. Notarization, App Sandbox/XPC hardening, signing distribution and a dependency license audit are separate distribution gates, not implied by ad-hoc local signing.
