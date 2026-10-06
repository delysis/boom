# Bloom

Bloom is a native, private macOS workspace for consulting editable voices and writing with a base language model. AppKit owns text editing, selection, input methods and Undo. SwiftUI presents the interface. Safe Rust validates voices, preserves speakers, plans authored prompts, sets sampling and memory policy, derives backup keys, and inspects attachments through a narrow in-process C boundary. MLX performs inference on this Mac.

Bloom has two compile-time layouts. The author build keeps a bounded manuscript beside its document library and optional chat; two native icons control the side panes. The chat build has a conversation library and chat, with no manuscript pane. Live title-bar search finds document bodies and chat text. Imported folders are snapshots inside the encrypted library; ordinary source files are never edited. The native Writing menu offers continuations, writing examples, inline suggestions and variation. Requested alternatives appear in a temporary tray; accepting text uses the editor's normal Undo path. Every chat supports instructions and editable exchanges. Pin a chat as a voice, then mention it elsewhere with `@`. Several mentions give separate answers by default; discussion lets later voices read earlier answers from that round.

Continuation replay uses its saved manuscript, prompt, model, sampling and seed even after live edits. Branching creates a new manuscript from that captured snapshot and retains its lineage. Acceptance requires the current manuscript, caret and example revisions to match the request. Safe Rust validates captured recipes and branch size before either action.

Generation applies the pinned checkpoint's control-token suppression before sampling. New recipes, receipts and recovery journals retain the effective token policy and exact stopping token, excluding control tokens from prose. Replay requires the captured policy to match the loaded model; earlier records without that policy remain readable and branchable, but require a fresh Explore request for replayable alternatives.

Writing supplies the chosen examples as prose, followed by the manuscript before the caret. When the full prefix exceeds the budget, Rust excludes impossible suffixes using validated vocabulary bounds and asks the loaded tokenizer to check the remaining suffixes in order. The first fit retains the most recent contiguous text possible, without splitting a grapheme. Token counts can decrease when text is added; a binary search cannot establish this result. Text after the caret is excluded.

## Privacy and ownership

The fresh workspace is `~/Library/Application Support/Bloom/Private`. Documents, conversations, voice revisions, attachment originals, continuations, receipts and recovery journals are authenticated encrypted records. There is no migration, old-store reader, or plaintext workspace mode. Existing Boom stores are left alone.

A process-owned vault session reads one Keychain master-key item. The session retains either the key or the failure; another storage consumer cannot trigger another authorization attempt. Missing or invalid keys, corrupt records, unknown schemas and conflicting recovery journals stop safely and retain evidence. Call counts are component evidence; actual macOS dialog behavior has its own native gate.

Readable Markdown and portable voice JSON are explicit exports. Complete backup uses a separate passphrase-derived key and includes every private record, while excluding model weights and disposable caches. Restore requires a fresh workspace. App-owned media decoding and playback use memory rather than plaintext temporary files. Native speech input and output remain available; speech asset installation is an explicit setup operation.

Backup restore publishes the encrypted replacement with one native directory exchange; the canonical vault always retains a directory. Unsupported exchanges fail without falling back to separate moves. Failed workspace validation restores the previous encrypted bytes and document revision guards. If rollback cannot finish, both encrypted directories are retained.

Startup and backup admission share a Rust inventory check. Required originals, inspection receipts, generated-answer receipts, documents and candidates must be present. Original hashes and limits are verified; unknown private files cannot become empty state or be silently omitted from a complete backup. Unindexed encrypted records remain part of the backup.

## Models

Bloom checks the Hugging Face cache, including `HF_HUB_CACHE`, `HF_HOME`, `XDG_CACHE_HOME` and the usual home cache. Verified local 4-bit conversions are preferred. It also recognizes the pinned official `google/gemma-4-12B-it-qat-q4_0-unquantized` and `google/gemma-4-12B` snapshots and can download those public checkpoints anonymously when explicitly requested. Every admitted file is checked against the signed catalog. Startup and inference use local files.

The public full-precision checkpoints require about 24 GB each. Their presence in a cache does not establish that they fit on a 32 GB Mac. The local 4-bit packs contain roughly 7.5 GB each and are built separately with the developer converter. Packs remain local for now; no public Bloom model repository has been published.

The pair shares an application budget capped at 24 GiB on every host, reduced further by physical memory and Metal's working-set limit. On a 32 GiB machine the policy reserves at least 8 GiB. Rust budgets the model's full/sliding attention caches, batch expansion and allocation overlap, reserving 2 GiB for other working allocations. MLX's disposable cache is bounded; active operations observe process usage and request cancellation on excess. One coordinator serializes loading and generation, joins producers, and lets foreground consultation preempt automatic suggestions. Context is capped at 16,384 tokens and further limited by available memory. Pressure releases the inactive model. A draft assistant is optional and is not required for voices.

Explore prefills its captured prose once, expands that cache to three rows, and decodes the alternatives in one MLX tensor batch. Rows use independent seeded samplers and stop independently; completed rows keep their positions until the batch finishes. Replay repeats the recorded batch width and ordered seeds, retaining all replayed alternatives and selecting the requested row. A short suggestion uses one row; requesting its other two alternatives uses a two-row batch. Context admission accounts for every row and the cache expansion overlap. `--mlx-smoke --batch --pack ABSOLUTE_DIRECTORY --evidence NEW_DIRECTORY` retains public-prose serial/batch measurements, raw outputs, exact replay, cache dimensions, cancellation and subsequent-operation results. This short single-model comparison does not establish paired full-context memory usage.

## Build and checks

Use an Apple Silicon Mac, macOS 15 or later, Xcode with Swift 6, and Rust.

```sh
scripts/bootstrap.sh
scripts/check-portable.sh
scripts/build-macos.sh "$PWD/out/fresh-build" author
# Use a different output directory and `chat` to build the conversation-only layout.
open "$PWD/out/fresh-build/Bloom.app"
```

Cargo has one workspace and lock. Swift dependencies are resolved once, with MLX Swift LM pinned to `9afc3b55f75a0d41a3d0c11330b9df6a036d24e4`. Builds use locked dependencies, run Rust and native tests, record actual static linker requirements, and reject source changes during the build. The signed bundle contains source/lock inventories, notices and the model catalog. Development signing uses a stable Apple Development identity; Developer ID distribution is a separate gate.

The safe Rust `bloom-delivery` developer tool owns signing admission and command receipts. The third build argument selects `development` (default) or `distribution`; distribution requires an explicitly configured Developer ID Application identity and secure timestamp. Inspection and archive preparation do not submit to Apple or launch the app. See [DISTRIBUTION.md](DISTRIBUTION.md) for the exact preparation, notarization, stapling and installation sequence.

Audio/video preview, extraction and transcription share safe Rust admission before constructing native decoders. Playlists, external data references, reference movies and compressed movie metadata are rejected; their imported originals remain encrypted and can still be explicitly exported. Audio conversion uses the captured import bytes, and validation precedes speech asset setup or authorization. Native codec tests use authored public MP4/M4A fixtures and memory-backed decoding without playing sound.

The developer-only `BloomPackBuilder` converts pinned source checkpoints outside normal installation. Its manifests retain source revisions and hashes, quantization settings, runtime revision, output hashes and licenses. The app executable does not perform conversion.

An explicit real-weight diagnostic preserves every attempt in a fresh evidence directory:

```sh
out/fresh-build/Bloom.app/Contents/MacOS/Bloom \
  --mlx-smoke --pack /absolute/path/to/verified/pack \
  --evidence /absolute/path/to/new/evidence
# Add --base and --seed INTEGER for the raw base-model diagnostic.
# Add --edit-smoke for a real consultation patch, encrypted commit and Undo check.
```

Native interaction checks can open the exact bundle with `--native-check-workspace /absolute/path/to/isolated/workspace`. This is an encrypted test workspace using the same process vault session, not a plaintext mode. Its window is labelled Native check so it cannot be mistaken for the normal workspace. Background checks can add `--native-check-background --native-check-no-models --native-check-theme dark` (or `light`) to avoid activation and model loading. Use a separate workspace for every concurrent check.

The five attachment crates were narrowly copied from `delysis/native-platform` at `637e60b6b044230ed24ed3118615a2e5538cae83`. No parent frontend, web runtime, local server, cloud inference, CoreML runtime, Apple chat fallback or persistent persona KV mechanism is included.

## Qualification

Component checks, a real-weight diagnostic, native interaction evidence, target-machine performance and distribution are separate gates. Nonempty generation does not establish writing quality. Preserve failed outputs and receipts.

This development Mac has 128 GiB. The approved performance gate now measures the app here under a 24 GiB application budget, including both resident models and full admitted context; it no longer requires an actual 32 GiB MacBook. Use `--mlx-smoke --memory-budget --pack ABSOLUTE_WRITING_PACK --evidence NEW_DIRECTORY` on the exact author bundle with consultation cached and outbound networking denied. Memory, latency, throughput, cancellation and typing retain separate measured targets. Developer ID signing, notarization and stapling remain unqualified while only an Apple Development identity is available. See `ACCEPTANCE.md` for the remaining gates and `DESIGN_QA.md` for native interface checks.

### Developer prefill checks

The Rust `bloom-kernel-probe` binary owns an offline, bounded arithmetic screen for the pinned consultation pack. Give it the verified pack directory, the built `BloomPackBuilder` executable, and a fresh evidence directory, all as absolute paths:

```sh
cargo build --release -p bloom-core --bin bloom-kernel-probe --locked
target/release/bloom-kernel-probe /absolute/consultation-pack /absolute/BloomPackBuilder /absolute/new-evidence
```

The native MLX backend compares fused group-32 quantized multiplication with BF16 and FP16 dense multiplication, including dequantization in each measured operation. The Rust driver registers the order, checks source hashes, denies outbound networking, bounds the child process group and joins it. All 72 observations and 18 distinct complete output tensors are retained. This is a developer arithmetic screen, not application performance or model-quality qualification; it neither converts the pack nor changes ordinary inference.

The application memory diagnostic requires both complete 16,384-token contexts before running its registered 16,128-input/256-output trials. Rust rejects reduced admission rather than letting the diagnostic silently shorten its workload. The 24 GiB application cap and separate latency, decoding, cancellation and typing targets remain unchanged.

The explicit memory diagnostic accepts `--benchmark-prefill-tokens 256`, `512`, or `1024`. Ordinary generation remains balanced 512-token prefill. Each diagnostic captures its geometry in receipts and encrypted journals; replay under another geometry is refused. Register comparisons before execution and retain every failed target. A smaller chunk is an experimental measurement option, not a qualified latency improvement.
