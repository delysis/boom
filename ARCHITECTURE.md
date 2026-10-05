# Bloom architecture

The product has two compile-time native layouts: author and chat. Rust derives their panes and toolbar controls together. Both use the same encrypted record format. Author imports capture folder structure and original bytes; no ordinary-file writeback exists. Live search reads captured document bodies off the UI thread and binds highlight ranges to the query and source revision. Swift owns AppKit/SwiftUI, Keychain/CryptoKit, AVFoundation/Speech and MLX integration. New validation and request-planning policy lives in the safe Rust `bloom-core` crate. A single Cargo workspace also contains the attachment inspector and its narrow C bridge.

## Captured authority

A Voice is independent of a model: stable UUID, unique mention name, display name, instructions, ordered examples and immutable content revision. A send captures the selected revisions, model, question, history, sources and speaker names. Historical attribution does not consult the mutable voice library. Rust treats another voice's contribution as explicitly attributed content, rather than silently turning it into the current voice's assistant response.

Separate answers share the captured history and question. Discussion additionally supplies completed earlier responses from that round. There are at most three voices. Ask has no edit authority. Propose requires acceptance. Edit is limited to one captured voice and the granted document revision. Rust compiles explicit read-only or revision-bound tool permission into every consultation. Rust also parses whole-response edit JSON and validates exact, nonoverlapping Unicode anchors; Swift commits the accepted result through encrypted recovery journals and native Undo. Sources are revalidated against the editor and encrypted disk state before an edit is committed. A response cannot become complete before its patch is validated and any authorized automatic commit finishes.

## Authored continuation

A CompletionRecipe captures manuscript UUID/revision and snapshot, UTF-16 cursor, chosen examples in order, exact prompt and digest, omitted prefix count, model identity, profile and output budget. Rust rejects cursor positions inside a Unicode grapheme. Examples contribute their prose; the prompt has no chat instructions or technical source headings. Text after the cursor is excluded.

CandidateBundle records retain recipes, seeds, actual outputs, token IDs, terminal state and branch origin. Automatic suggestions produce one candidate capped at 64 tokens. Explore produces three candidates sequentially, each capped at 256. Only explicit acceptance changes the manuscript. Branching uses the captured snapshot, retains following text, and records the original document/revision and candidate identity. Editing, moving the cursor, changing examples and composition invalidate acceptance of old results. Native Undo owns accepted insertions.

## Model and generation ownership

The signed catalog binds local converted packs and pinned public source checkpoints to expected hashes. Cache discovery is separate from admission: a file's presence does not prove integrity or residency. Download is explicit, anonymous, resumable and verified before admission. Conversion is a developer executable rather than an installation dependency.

GenerationCoordinator serializes model loading and GPU generation. Cancellation retains ownership until the producer is joined. Foreground requests cancel background suggestions. UI callbacks capture cancellation/operation identity, candidate identity and editor epoch. Model identity and available memory determine context admission; architecture's advertised context is not a promise that it fits.

## Durable private state

WorkspaceStore is an actor. Vault serializes authenticated AES-GCM record access, binds kind and UUID as associated data, rejects symlinks and bounded-read violations, and atomically replaces encrypted records. VaultSession holds one cached Keychain outcome for the process. Neither denial nor invalid records cause an automatic replacement key or empty workspace.

A save journal records intended index and document replacements before writing them. Recovery validates every before/after revision before repairing any record. A separate edit journal binds proposal, document and before/after revisions. Interrupted replies retain their speaker and partial text and become explicitly cancelled.

Complete backup enumerates every encrypted private record and re-encrypts their contents under an Argon2id-derived passphrase key. A fresh restore validates records in staging, rewraps them under the current vault key, and admits them atomically. Weights and disposable caches are outside this private-record set.

Attachment originals and inspection receipts are encrypted. Image decoding, audio conversion and video playback receive bytes in memory. On-device speech is a platform service with explicit asset setup. Portable voice JSON, Markdown and readable chat exports are deliberate user actions.

A voice is a pinned chat. Chat instructions and editable user/assistant messages form its source; Rust compiles those into a model-independent, immutable Voice snapshot. The pinned chat and voice share an identity. Explicit edits preserve previous message versions, model receipts, and voice revisions. Imported voices open as ordinary chats. There is no separate voice editing form.
