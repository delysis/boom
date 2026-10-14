# Bloom

Bloom is a native, private macOS workspace for consulting editable voices and writing with a base language model. AppKit owns text editing, selection, input methods and Undo. SwiftUI presents the interface. Safe Rust validates voices, preserves speakers, plans authored prompts, sets sampling and memory policy, edits lazy UTF-8 trees, and inspects attachments through a narrow in-process C boundary. MLX performs inference on this Mac.

Bloom has two compile-time layouts. The author build keeps a continuous manuscript with a bounded text width beside its document library and optional chat; two native icons control the side panes. The writing surface has no paper outline or implied pagination. The chat build has a conversation library and chat, with no manuscript pane. Live title-bar search finds document bodies and chat text. Imported folders are snapshots inside the workspace; ordinary source files are never edited. The native Writing menu offers continuations, writing examples, inline suggestions and variation. Requested alternatives appear in a temporary tray; accepting text uses the editor's normal Undo path. Every chat supports instructions and editable exchanges. Pin a chat as a voice, then mention it elsewhere with `@`. Several mentions give separate answers by default; discussion lets later voices read earlier answers from that round.

Continuation replay uses its saved manuscript, prompt, model, sampling and seed even after live edits. Branching streams the captured immutable file revision into a new manuscript and retains its lineage. Acceptance requires the current manuscript, caret and example revisions to match the request. Captured model text carries its exact byte and UTF-16 origins; native acceptance rechecks the full file record and current input generation.

Generation applies the pinned checkpoint's control-token suppression before sampling. New recipes, receipts and recovery journals retain the effective token policy and exact stopping token, excluding control tokens from prose. Replay executes its recorded prefill strategy: historical `balanced_v1` and current `fixed_v1` remain distinct, with the same admitted token ceiling. Decoder, mask, vocabulary and schema policy must still match the loaded model. Earlier records without that policy remain readable and branchable, but require a fresh Explore request for replayable alternatives.

Writing lazily captures chosen example passages and a bounded manuscript prefix ending at the caret. When that captured prefix exceeds the token budget, Rust excludes impossible suffixes using validated vocabulary bounds and asks the loaded tokenizer to check the remaining suffixes in order. The first fit retains the most recent contiguous text possible, without splitting a grapheme. Token counts can decrease when text is added; a binary search cannot establish this result. Text after the caret is excluded.

The Rust writing-prompt builder includes the model's beginning-of-text marker. The native encoder disables automatic insertion so the model receives one boundary token. Counting, suffix selection and both generation shapes use that same compiled prompt. Authored prose has no chat turn template or inserted source headers.

## Files and ownership

The ordinary workspace is `~/Library/Application Support/Bloom`. `workspace.json` stores settings, titles, conversations, drafts, voice revisions, proposals and imported-source references. `identity.json` identifies that workspace. Attachment originals, continuations and generation checkpoints are ordinary files under `Objects`. Bloom uses files directly, without an application database, encryption keys or storage migration.

Manuscripts use immutable UTF-8 pages and a small per-document source/history root under `Documents`. Opening, typing, selection and Undo use bounded native windows; source files are never assembled into a document-sized String or attributed buffer. Imports and exports stream through bounded chunks. Document root changes preserve canonical Undo/Redo groups and their cursors; renaming only updates the title metadata. Trash retains source roots, imported originals and drafts. Original files selected for import are left unchanged.

Model requests read explicit source ranges with immutable tree revisions and absolute byte/UTF-16 origins. Their text hashes describe the supplied passages separately from the full source revision. Proposals can modify only those captured ranges through the same native editing owner. Library search scans requested document bodies in background chunks, yielding to foreground edits.

Copy uses ordinary text for selections up to 128 KiB. Larger cross-window selections stream into a text file and place its file URL on the clipboard, up to 1 GiB per copy; receiving apps need to accept files. Cut removes source only after clipboard publication succeeds. The current clipboard file survives quitting Bloom, and later large copies remove inactive cache files.

One held workspace lock prevents two editing processes from writing the same workspace. Complete backup joins preceding saves, exports and generation producers, then captures native file clones under the source writer queue and metadata lock. The long copy reads only that snapshot through a 64 KiB buffer; the live editor, Undo, scrolling and later saves remain available. A marked composition remains live and its last completed checkpoint is captured. Unsupported native cloning fails without a long copy under the writer locks. It preserves every workspace file, including unknown files; external model weights and disposable inference caches stay outside the workspace. Restore copies into a fresh selected directory and opens it after the previous engine closes. No passphrase or old-format reader is involved.

Unsent questions remain with their conversation or manuscript, and writing examples retain their order across restart and backup restore. Markdown and portable voice JSON are explicit exports. Exported files publish off the UI thread and can proceed during generation; closing the workspace joins their producers. Requests for one destination publish in order, and cancellation before publication preserves an existing destination.

Workspace windows disable AppKit state preservation and restoration snapshots. Bloom restores document/chat selection and pane state from its ordinary workspace metadata. App-owned media decoding and playback use memory. On macOS 26 and later, startup prepares the system's on-device dictation asset.

## Models

Bloom checks every configured Hugging Face cache root, including `HF_HUB_CACHE`, `HF_HOME`, `XDG_CACHE_HOME` and the usual home cache. Verified local 4-bit conversions are preferred. Startup prepares the models automatically: it reuses verified local files, or anonymously downloads the pinned `mlx-community/gemma-4-12B-it-qat-4bit` and `mlx-community/gemma-4-12B-4bit` snapshots when needed. The same snapshots can be imported offline. Every admitted file is checked against the signed catalog; interrupted transfers resume from retained bounded ranges. Generation begins only after local admission. macOS 26 and later also prepares the system's on-device dictation asset automatically; Apple manages that shared asset and its later updates.

Each public quantized snapshot needs about 11 GB of weights and uses a 4-bit default with 8-bit overrides. Published identity and hashes do not establish its conversion lineage, output quality or paired memory qualification. The local 4-bit packs contain roughly 7.5 GB each and are built separately with the developer converter. Packs remain local for now; no public Bloom model repository has been published. The pinned official full-precision checkpoints remain identifiable for developer comparisons, but cannot pass the application's 24 GiB load-admission policy and are not offered by ordinary setup.

The pair shares an application budget capped at 24 GiB on every host, reduced further by physical memory and Metal's working-set limit. On a 32 GiB machine the policy reserves at least 8 GiB. Rust budgets the model's full/sliding attention caches, batch expansion and allocation overlap, reserving 2 GiB for other working allocations. MLX's disposable cache is bounded; active operations observe process usage and request cancellation on excess. One coordinator serializes loading and generation, joins producers, and lets foreground consultation preempt automatic suggestions. Context is capped at 16,384 tokens and further limited by available memory. Keep both models resident when their contexts fit; otherwise release the inactive model and reload the same verified snapshot when requested. Consultation, Explore and replay remain available after that release. A draft assistant is optional and is not required for voices.

Explore prefills its captured prose once, expands that cache to three rows, and decodes the alternatives in one MLX tensor batch. Rows use independent seeded samplers and stop independently; completed rows keep their positions until the batch finishes. Replay repeats the recorded batch width and ordered seeds, retaining all replayed alternatives and selecting the requested row. A short suggestion uses one row; requesting its other two alternatives uses a two-row batch. Context admission accounts for every row and the cache expansion overlap. `--mlx-smoke --batch --pack ABSOLUTE_DIRECTORY --evidence NEW_DIRECTORY` retains public-prose serial/batch measurements, raw outputs, exact replay, cache dimensions, cancellation and subsequent-operation results. This short single-model comparison does not establish paired full-context memory usage.

Live text requests automatically look up the longest exact prepared-token prefix whose full-attention prefix and every sliding window remain resident. Prompt and processed generated tokens use the same index across conversations and manuscripts within one workspace/model namespace. Immutable incoming KV pages share backing across selected batch rows and returning branches; working native caches hydrate only the required prefix/window. Each loaded runner has a 1 GiB resident tensor pool, with unique backing accounting, inactive LRU eviction and rolling local retention of two native windows plus an incoming-page overlap. Overwritten local history is bounded; nothing is serialized to disk. The measured application memory guard and context admission remain authoritative. Memory pressure, closing a workspace and model release clear the pool. Unsupported prepared media/state and explicit historical replay currently use fresh caches. Forward shapes and original batch lineage are recorded as cache provenance; they do not restrict normal prefix eligibility. Faithful historical warm replay needs complete parent/sibling forward matrices and is not qualified by these diagnostics. Cache metrics expose prefix counts, actual geometry, resident tensor bytes and miss reasons. Cached performance remains separate from the cold paired full-context gate.

Automatic suggestions reload an evicted writing model when the manuscript owns input focus and typing requests a continuation. Chat focus cannot start that reload. An open alternatives tray retains its captured choices; a dismissed or invalidated suggestion cannot prevent resumption after Undo. Native edits cancel obsolete suggestions, and foreground consultation joins the cancelled producer before acquiring the model coordinator.

Model-cache reclamation retains the generation coordinator's lease and releases native allocations on the dedicated inference queue. Memory-pressure cleanup uses the same path, allowing the main actor to continue handling manuscript input.

## Build and checks

Use an Apple Silicon Mac, macOS 15 or later, Xcode with Swift 6, and Rust.

Standalone Core checks support Linux with Swift 6.1 or later. Core keeps Swift language mode 5 and uses Swift Crypto for SHA-256; on macOS, that package forwards to system CryptoKit.

```sh
scripts/bootstrap.sh
scripts/check-portable.sh
scripts/build-macos.sh "$PWD/out/fresh-build" author
# Use a different output directory and `chat` to build the conversation-only layout.
open "$PWD/out/fresh-build/Bloom.app"
```

Cargo has one workspace and lock. Swift dependencies are resolved once, with MLX Swift LM pinned to `9afc3b55f75a0d41a3d0c11330b9df6a036d24e4`. Builds use locked dependencies, run Rust and native tests, record actual static linker requirements, and reject source changes during the build. The signed bundle contains source/lock inventories, notices and the model catalog. Development signing uses a stable Apple Development identity; Developer ID distribution is a separate gate.

`bloom-tokenizer-reference` is an offline developer executable in that same Rust workspace. It uses the pinned Hugging Face Rust tokenizer to encode explicit UTF-8 files or decode explicit token-ID arrays, retaining counts and hashes. It is not linked into Bloom. For compiled prompts that already include the beginning-of-text marker, compare its encoding without additional special tokens against native receipts. The tool also compares those tokens with standard checkpoint post-processing of the authored text after removing the compiler's leading marker. Default features and network support are disabled.

The safe Rust `bloom-delivery` developer tool owns signing admission and command receipts. The third build argument selects `development` (default) or `distribution`; distribution requires an explicitly configured Developer ID Application identity and secure timestamp. Inspection and archive preparation do not submit to Apple or launch the app. See [DISTRIBUTION.md](DISTRIBUTION.md) for the exact preparation, notarization, stapling and installation sequence.

Audio/video preview, extraction and transcription share safe Rust admission before constructing native decoders. Playlists, external data references, reference movies and compressed movie metadata are rejected; their imported originals remain on disk and can still be explicitly exported. Audio conversion uses the captured import bytes, and validation precedes speech asset setup or authorization. Native codec tests use authored public MP4/M4A fixtures and memory-backed decoding without playing sound.

Video model input uses a shared, memory-only storyboard for writing and consultation. Tiny 4 Hz RGB probes rank persistent abrupt changes and discount flashes and steady movement; periodic frames preserve a five-second maximum visual gap. Safe Rust owns the scan budget, selection, timeline validation and prompt compilation. Each view contains at most 16 timestamped native video frames, each with a 70-token visual budget, from the first minute, and discloses later duration and detected cuts omitted by the frame budget. This heuristic can miss short events or gradual transitions; it does not identify semantic scenes.

The unified Gemma 4 models receive the continuous soundtrack as chronological 16 kHz mono waveform windows between storyboard groups. Original presentation timestamps preserve delayed tracks and silence. Frame times, frame hashes, sound intervals and waveform hashes are captured in continuation recipes and consultation receipts. Models without raw audio receive the storyboard with an explicit soundtrack omission. Completed derivations occupy at most 24 MiB across four memory cache entries and are disposable under pressure; no plaintext preparation files are created. The complete original remains available for explicit export.

The public `--video-storyboard-smoke --fixture ABSOLUTE_MP4 --evidence FRESH_ABSOLUTE_DIRECTORY` diagnostic compares full, frames-only and sound-only inputs with the cached writing and consultation models. It records every output, timing, prompt and source identity; semantic review remains distinct from successful inference. Google recommends small visual budgets for video and audio segments below 30 seconds ([model card](https://ai.google.dev/gemma/docs/core/model_card_4)); sound windows are at most 30 seconds and are independent of visual cuts, which can bisect speech. The cheap temporal-difference approach is informed by [FFmpeg's scene detector](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_scdet.c); Bloom's implementation is independent Rust code with explicit coverage and flash checks.

The developer-only `BloomPackBuilder` converts pinned source checkpoints outside normal installation. Its manifests retain source revisions and hashes, quantization settings, runtime revision, output hashes and licenses. The app executable does not perform conversion.

An explicit real-weight diagnostic preserves every attempt in a fresh evidence directory:

```sh
out/fresh-build/Bloom.app/Contents/MacOS/Bloom \
  --mlx-smoke --pack /absolute/path/to/verified/pack \
  --evidence /absolute/path/to/new/evidence
# Add --base and --seed INTEGER for the raw base-model diagnostic.
# Add --edit-smoke for a real consultation patch, file publication and Undo check.
```

Native interaction checks can open the exact bundle with `--native-check-workspace /absolute/path/to/isolated/workspace`. This uses the same ordinary file route in an isolated workspace. Its window is labelled Native check so it cannot be mistaken for the normal workspace. Background checks can add `--native-check-background --native-check-no-models --native-check-theme dark` (or `light`) to avoid activation and model loading. Use a separate workspace for every concurrent check.

The five attachment crates were narrowly copied from `delysis/native-platform` at `637e60b6b044230ed24ed3118615a2e5538cae83`. No parent frontend, web runtime, local server, cloud inference, CoreML runtime, Apple chat fallback or persistent persona KV mechanism is included.

## Qualification

The new ordinary file route requires fresh build, native editing, large-file, model and installation checks; earlier encrypted/SQL results do not qualify it. Component checks, native interaction, real-weight performance and distribution remain separate gates. Nonempty generation does not establish writing quality. Preserve failed outputs and receipts.

This development Mac has 128 GiB. The approved performance gate now measures the app here under a 24 GiB application budget, including loading overlap and full context under its ordinary residency policy; it no longer requires an actual 32 GiB MacBook. Use `--mlx-smoke --memory-budget --pack ABSOLUTE_WRITING_PACK --consultation-pack ABSOLUTE_CONSULTATION_PACK --evidence NEW_DIRECTORY` on the exact author bundle with outbound networking denied. Explicit paths prevent a preferred local pack from supplying a public-checkpoint trial. Memory, latency, throughput, cancellation and typing retain separate measured targets. Developer ID signing, notarization and stapling remain unqualified while only an Apple Development identity is available. See `ACCEPTANCE.md` for the remaining gates and `DESIGN_QA.md` for native interface checks.

### Developer prefill checks

The Rust `bloom-kernel-probe` binary owns an offline, bounded arithmetic screen for the pinned consultation pack. Give it the verified pack directory, the built `BloomPackBuilder` executable, and a fresh evidence directory, all as absolute paths:

```sh
cargo build --release -p bloom-core --bin bloom-kernel-probe --locked
target/release/bloom-kernel-probe /absolute/consultation-pack /absolute/BloomPackBuilder /absolute/new-evidence
```

The native MLX backend compares fused quantized multiplication with BF16 and FP16 dense multiplication, including dequantization in each measured operation. A fourth arm dequantizes once and reuses a BF16 matrix, recording its conversion cost and additional allocation separately. The Rust driver registers a balanced order, checks source hashes, denies outbound networking and access to the active author fixture workspace, bounds the child process group and joins it. The local group-32 pack produces 96 observations and 24 complete output tensors. This is a developer arithmetic screen, not application performance or model-quality qualification; it neither converts the pack nor changes ordinary inference.

For the pinned public consultation checkpoint, append its existing verified model inventory as a fourth absolute argument. The driver checks the source configuration and shard index, then screens the actual group-64 4-bit attention and 8-bit gate/up/down projections. Twelve cases produce 192 observations and 48 distinct complete output tensors. `bloom-kernel-review ABSOLUTE_EVIDENCE` independently reads every saved output, recomputes hashes and error statistics, and checks shapes, quantization, balanced order, conversion allocation and the operation budget. The public screen registers an 8 GiB component budget, separate from the application's 24 GiB gate. Both immediate conversion and reused dense execution remain experiments; this screen does not enable either in Bloom.

`BloomPackBuilder` also provides an input-packaging comparison for a captured 4,096-token consultation fixture:

```sh
/absolute/BloomPackBuilder --input-packaging-probe /absolute/consultation-pack /absolute/captured-fixture.json /absolute/new-evidence
```

It verifies the captured model and prompt identities, then compares native processor input with flat tokens in a fixed native/flat/flat/native order, using fresh KV caches and balanced 512-token prefill. It retains every full-vocabulary logit vector and observation, including partial evidence on failure. This one-model component check measures prefill and cache/logit settlement; it does not sample, qualify application performance, or change application behavior or defaults. Use an owning offline driver with a deadline, and compare complete vectors independently. The retained first comparison found identical logits and no supported speed benefit from flattening; the app keeps its native input path.

`bloom-prefill-profile` owns a developer-only operation profile of the pinned public consultation checkpoint. Supply its existing HF snapshot, a captured public 4K consultation fixture, the corresponding model inventory, the built `BloomPackBuilder`, and fresh evidence, using absolute paths:

```sh
cargo build --release -p bloom-core --bin bloom-prefill-profile --locked
target/release/bloom-prefill-profile run /absolute/public-snapshot /absolute/fixture.json /absolute/model-manifest.json /absolute/BloomPackBuilder /absolute/new-evidence
target/release/bloom-prefill-profile review /absolute/new-evidence
```

The Rust owner verifies every inventoried model file before and after execution, registers a baseline/profile/profile/baseline order, denies outbound networking and access to the active author fixture workspace, and joins its child process group with a 300-second native execution deadline. Native instrumentation delegates to the loaded model's unchanged linear projections, settling their inputs and outputs separately. Each output projection's input settlement includes the preceding attention, rotary and cache work. These synchronized groups perturb scheduling and are not individual GPU kernel timings. The independent reader requires exact equality of all four complete float32 logit vectors and retains every operation observation. This one-model probe changes no app runtime, weights, sampling settings, context budget or product qualification gate.

Replace `run` with `entry`, `priority` or `executor` to compare direct preparation with the production `TokenIterator` initializer in a direct/iterator/iterator/direct order. The latter two use user-initiated tasks; `executor` also uses the application's dispatch-queue configuration. Rust compiles and validates the captured checkpoint policy through the existing product API and supplies Standard sampling. The native probe captures unmasked first logits and the primed first sample without calling `next()`, which would pipeline another decode. Review requires exact logits, matching first samples, and the captured application's first token. It does not qualify stream delivery or the full app lifecycle.

The effective Metal command-buffer overrides are `MLX_MAX_OPS_PER_BUFFER` and `MLX_MAX_MB_PER_BUFFER`. Both owning probe tools set those names explicitly. The prefill report records their observed values and device architecture; review checks them against registration. Earlier developer receipts incorrectly labelled the unused names `MLX_METAL_MAX_OPS` and `MLX_METAL_MAX_MB`; retain those receipts as arithmetic/within-run comparisons rather than evidence that effective overrides were controlled. The application memory owner used the correct names.

The application memory diagnostic exercises the production residency controller and requires a complete 16,384-token context for each purpose before its registered 16,128-input/256-output trial. Writing includes three batched rows. Rust rejects reduced admission rather than letting the diagnostic silently shorten its workload. The diagnostic retains all initial loads and reloads separately; it warms each resident instance before measuring its 4K first response. The 24 GiB application cap and separate latency, decoding, cancellation and typing targets remain unchanged.

The explicit memory diagnostic accepts `--benchmark-prefill-tokens 256`, `512`, or `1024`. Ordinary new generation uses fixed 512-token prefill. Each diagnostic captures its geometry in receipts and file checkpoints; historical replay executes its recorded supported strategy and ceiling. Register comparisons before execution and retain every failed target. A smaller chunk is an experimental measurement option, not a qualified latency improvement.
