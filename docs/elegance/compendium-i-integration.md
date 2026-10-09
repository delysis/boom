# Elegance Compendium I integration

Reviewed against Boom `88ee71642e5d5cdeaa25764d314aac82bc8cfa84` and Native-platform
`cdfea8a74da09e102b124f5d382030c85d08f976`.
The supplied archive is evidence and proposed design, not executable authority.
Its teaching specimens are not production patches. Earlier Linux Core receipts
claimed in Boom PRs #1/#2 are unavailable in the supplied archive; this integration
uses fresh macOS checks and does not reconstruct those historical runs.

## Disposition of every observation

| ID | Disposition and source basis |
| --- | --- |
| O01 | Applied E01 in `Prompt.swift`. The removed handler survives the lock scope; callbacks and destructors may reenter. Registration/cancellation remain linearized, and producer joining remains the consumer's job. |
| O02 | Already repaired in Native `llama-native-cache/src/fingerprint.rs`; retain framing, optional tags and owner/fingerprint admission. No duplicate repair. |
| O03 | Applied E03 in Native and the deliberately incorporated Boom inspector. Borrowed ASCII comparisons preserve the existing predicate, including COM0/COM10/superscript negatives. |
| O04 | Applied and repaired E04. The delivered all-String splitting proposal failed 238 macOS differential comparisons. Preserve String's two-LF paragraph matching, then locate up to three line ends with NSString UTF-16 searches; the unchanged differential corpus passes. A first all-NSString repair also failed and its receipt is retained locally. No speedup claim. |
| O05 | `LibrarySelection.Effect` is `.none`, `.open` or `.rename`. Both native document/chat callers handle the exhaustive result; range/toggle/anchor behavior remains covered. |
| O06 | `ContextPlan.revalidate` now builds one identity index and rejects duplicate IDs before comparing revisions. Identical and conflicting duplicates in either order reject. This is an identity-contract repair, not a claimed performance win for the 24-document default. |
| O07 | No persisted schema change. `Speaker` is historical attribution data. Current native voice construction supplies the ID/revision together, and Rust consultation ownership checks the exact captured pair. No invalid live authority state was demonstrated. |
| O08 | Retain computed `DocumentSnapshot.revision`: snapshots have mutable text. Caching it would introduce invalidation state. Native `ProductCore` already obtains authoritative revisions through Rust; no new cache without a measured repeated-cost problem. |
| O09 | Documented `Digest.canonical` as local JSONEncoder identity semantics, not a universal cross-language canonical JSON format. No identity or stored-format migration. Native product policy uses Rust and its existing digest contracts. |
| O10 | Keep the tested portable SHA implementation. The teaching eight-word addition does not establish whole-hash correctness, ABI benefit or a measured allocation/code-generation improvement. Swift Core still supports its declared tools floor; no InlineArray adoption solely for cosmetic extent. |
| O11 | The default context resolver admits at most 262,144 UTF-8 bytes. Character lengths and budget are at most that bound, so every quota product is at most 68,719,476,736, below signed 64-bit Int. Configurable oversized limits are not a demonstrated product input. No checked-arithmetic rewrite of this bounded current path. |
| O12 | Compile the immutable wiki, voice and attachment-link regexes once; retain the existing parsing grammar, order, throwing signatures and code/fence suppression behavior. The constant patterns are validated by the parser suite. |
| O13 | Retain the current imported-directory renderer. A projection cache would need query/document revision binding and native large-library profiling. This audit supplied neither a measured bottleneck nor an equivalent projection implementation. |
| O14 | Keep `SourceReference.kind` as an extensible persisted provenance tag. Producers use document, attachment and writing-example tags; owning revalidation checks identity/revision rather than treating a string as authority. An exhaustive enum would change decoding of stored/extended evidence without a demonstrated need. |
| O15 | Clarified `ValidatedEdit` as inert planner output, not an authorizing capability. `ByteRange` is transport data. Rust document planning and native `WorkspaceModel.commit` check captured grants, identity/revision, current editor state and disk state before mutation. Public DTO construction does not bypass that owning path. |
| O16 | Keep distinct admission and display-sanitization passes. They preserve absolute/NUL/parent/device rejection precedence and raw-name provenance; combining them has no demonstrated correctness or measured performance benefit. |
| O17 | Mailbox preflight stops after the smaller remaining entry/edge budget plus one. It still rejects before parser allocation and retains the exact issue and zero-derived-work outcome. Tests exercise the actual inspector at the limit and beyond either limit, including a large rejected tail. |
| O18 | Notice collection retains malformed Cargo entries as explicit unresolved rows and rejects incomplete source inventory. No compactMap omission and no fabricated unknown package version. |
| O19 | Notice collection starts from expected Swift pins, requires one matching checkout at the exact clean revision, and records missing/duplicate/mismatched/modified outcomes. Untracked notices cannot borrow a pin. Missing notice files remain explicit unresolved notice outcomes. Fixtures execute the real collector; distribution approval remains false. |
| O20 | Propagate the accepted inspector source and tests into Boom, then update the incorporated source pin to the promoted Native commit. The separate pin and consumer qualification are recorded in `NOTICE.md`. |
| O21 | Already corrected on current Native main: `crates/native/README.md` identifies the canonical monorepo and marks standalone material historical. No duplicate documentation change. |
| O22 | Keep Core's Swift tools 6.0 / language-mode 5 contract. A strict-concurrency migration is a separate change with compiler/runtime acceptance obligations; version text alone is not a defect. |
| O23 | Retain the existing journal's pending-only interruption transition and immutable terminal evidence. No teaching baseline substituted for the production protocol. |
| O24 | Traced Rust Box allocation/free and the Swift borrowed-input/defer-free consumers. Corrected ABI documentation: every entry point's result is freed exactly once with its unchanged pointer/length; CAF success returns binary WAV rather than JSON. Input bounds are below isize::MAX; caller-provided readable memory remains the C contract. This review does not claim a complete sanitizer/platform proof. |
| O25 | No machine-placement or renderer change without the missing measurement. Portable tests, native compilation, packaged smoke interactions and real-model checks establish their own exercised scopes, not GPU throughput or release acceptance. |
| O26 | Preserve the supplied archive's erratum and local failed receipts. Fresh integrated-source checks are separate evidence, never substitutes for unavailable earlier runs. |

The integration's receipt records exact commits, toolchains, tests, artifact paths
and remaining external/platform limits. Compilation alone does not establish
real model, native interaction, notarization or distribution approval.
