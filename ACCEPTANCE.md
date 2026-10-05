# Bloom acceptance gates

Record exact source and lock inventories, bundle/executable hashes, designated requirement, model manifests, runtime, hardware, workspace root and operation receipts. Retain all failures. Component checks do not substitute for native or distribution gates.

## Consultation

Start fresh. Give two ordinary chats instructions and editable exchanges, then pin them as voices without loading a model or making a cache. Verify that the same fields and message editing work before and after pinning. Import, duplicate and export a pinned chat as a voice. Consult both through `@`; verify separate answers use the same captured question/history and discussion includes completed earlier answers. Rename and edit a voice; historical speakers and revisions must remain unchanged. Quit and relaunch, then verify instructions, examples, attribution and replies. Exercise failures before the first token, cancellation and interruption. Pending replies must finish explicitly.

Explicit attachments and references determine context. Inspect supplied context and omissions. Ask cannot edit. Propose requires acceptance. Edit grants one voice one document revision. Stale document/source changes, IME composition, malformed edits and interrupted writes must retain evidence and refuse unsafe application.

## Writing

Use substantial authored prose and chosen literary examples. Verify exact bytes supplied before the cursor and the exclusion of following text. Generate three distinct real-model alternatives sequentially, replay a seed, request another set, navigate with Option-Up/Down, branch one alternative, partially accept another and undo. Verify manuscript bytes and lineage throughout. Automatic ghost text stays out of Copy, export, storage and Undo until accepted. Edits, cursor movement, example changes and partial acceptance invalidate obsolete results.

Evaluate Steady, Standard and experimental Open against a fixed literary prompt/seed set. Retain every output and failure. Review continuity, style, repetition, diversity and author control; nonempty output is not a quality gate.

Verify checkpoint-authored suppression before sampling, unmodified allowed logits, EOS eligibility and seeded replay after intervening requests. Bind the effective policy and exact terminal token to encrypted recipes, receipts and journals; reject suppressed tokens in prose or terminal records. Interrupted recovery retains a known stopping token without treating a pending attempt as completed. Earlier recipes with an unrecorded policy must refuse replay without replacing their stored outputs. Compare fixed prompts and seeds before and after policy changes, retaining every trial.

Generation timing starts before MLX constructs its token iterator, which performs prompt prefill. Earlier receipts timed only the subsequent stream consumption and cannot establish total first-token or generation latency. Preserve those receipts when comparing runs.

The developer `--mlx-smoke --writing-fixtures /absolute/public-suite.json --pack /absolute/model-directory --evidence /absolute/new-directory` evaluation admits either the pinned converted writing pack or its pinned official checkpoint through the product's cache/hash checks. Reference runs record their distinct model identity, original weight size and weight kind. Compare identical prompts, seeds and sampling with both, retaining every output and failure. Using the same runtime isolates conversion effects; it does not qualify an independent architecture implementation or establish literary quality.

Decoding uses the checkpoint decoder without the tokenizer library's additional English punctuation/spacing cleanup. Compare the emitted tokens against an independent raw decoder, including spaced ellipses, punctuation, apostrophes and binary-distinct Unicode. The in-memory override must leave admitted tokenizer files unchanged. Capture `textDecoding` in the Rust generation policy; retain earlier records, but refuse replay under different or unrecorded decoding semantics rather than rewriting their saved outputs.

The explicit `--writing-control-smoke capture --fixture /absolute/public-fixture.json --evidence /absolute/new-directory` diagnostic drives Explore, partial acceptance, the native editor's Undo action, branching and replay after live edits. A separate process runs `--writing-control-smoke verify --evidence /absolute/existing-directory` to check encrypted persistence and complete backup restore. Run both with outbound networking denied. These background controller/editor checks and offscreen body renders do not qualify visible interaction, Keychain dialogs or writing quality.

Context selection must retain the largest fitting recent grapheme suffix, including nonmonotonic token counts and a full prompt that fits when its examples-only count would cause rejection. `--writing-context-smoke --fixture /absolute/public-context-suite.json --evidence /absolute/new-directory` exhaustively checks small cases against the loaded tokenizer, measures a long case off the main thread, and verifies interruption followed by a fresh request. Independently compare exported prompts and counts with the reference tokenizer. These checks qualify the exercised cases and planner behavior; they do not establish 32 GB performance or typing latency.

## Privacy, recovery and installation

Through the signed production bundle, measure actual Keychain authorization dialogs on first, repeated and rebuilt launches, concurrent consumers, denial and missing/wrong-key conditions. Require at most one authorization dialog per launch, no retries after failure and no silent replacement key. Calls alone do not qualify this gate.

Verify authenticated identity swapping, corrupt records, missing/unknown indices, interrupted save and edit journals, conflicting recovery and no empty replacement state. Export a passphrase-encrypted complete backup and restore it into a fresh workspace. Verify documents, chats, all voice revisions, branches, candidates, originals, receipts and journals. Wrong passphrase must admit nothing. Models and disposable caches must be excluded.

Check every standard Hugging Face cache root and the pinned public snapshots. Verify local pack import, hashes, missing/modified files, interrupted download/resume and atomic admission. Startup and inference must run with outbound networking denied at the OS level. Inspect app-owned files and logs for private plaintext. Exercise image/audio/video/PDF/text originals and explicit attachment routing through paste, drop and menus; include switch-destination and cancellation cases. Missing on-device speech assets must offer explicit setup and cannot trigger an inference-time download.

Inspect the exact bundle at wide and narrow sizes in light and dark appearances, including focused empty controls, typing, selection, Unicode, input methods, Undo and accessibility. A quiet empty page must have no active operation that merely opens an avoidable error alert. Every visible control must lead to a working action or state its availability.

## Actual 32 GB MacBook

Measure cold/warm loading, loading peaks, allocator caches, context working set, first token, throughput, cancellation, typing, memory pressure and swap growth. Initial targets: peak process footprint ≤24 GiB; warm 4K-token first response ≤8 seconds; sustained decode ≥10 tokens/second; decode cancellation ≤2 seconds; typing latency ≤100 ms. Reserve at least 8 GiB and respect the lower Metal budget. Admit both models only after accounting for their overlap and recomputing available context. Under pressure, release the inactive model and disclose reload delay.

This gate remains unqualified on the 128 GB development Mac.

## Distribution and receipts

Deliver the exact runnable bundle, pinned manifests, native demonstration recordings, complete failure/output evidence and source/build/model-bound receipts. Integrate tested commits into the private source repository. Model packs remain local until publication is authorized and account access is available.

Prepare hardened Developer ID signing, notarization, stapling and installation/relaunch checks. Apple Development signing is local test evidence and does not qualify distribution. The distribution gate remains open without a Developer ID identity and actual notarization/stapling results.
