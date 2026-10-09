# E01 — A destructor is also a callback

Unranked elegance archive. Base: `88ee71642e5d5cdeaa25764d314aac82bc8cfa84`.

## Observation and contract

`Core/Sources/BoomCore/Prompt.swift` manually balanced a lock around the cancellation flag and handler dictionary. Handler invocation already happened after unlocking. However, `removeCancellationHandler` discarded the removed closure while locked. Releasing its last capture can run arbitrary `deinit` code, including a call back into the same flag.

This change is **a local lifetime refactor plus a demonstrated reentrancy repair**, not a claim of observational equivalence on every program: the formerly deadlocking destructor now completes. Cancellation remains sticky; registration/cancellation remains serialized; a removed registration may already be executing; callback order is still unspecified; cancelling still does not join the producer or release its ownership.

The returned closure is retained across the lexical lock scope, then explicitly kept alive outside it with `withExtendedLifetime`. Moving only the explicit `handler()` call outside the lock was not enough. An apparently empty lifetime statement carries a real proof obligation.

## Historical affinity, not a claimed transmission

The C++ Core Guidelines' CP.22 warns against calling unknown code while holding a lock. Resource-lifetime reasoning extends that concern to destructors. Swift's lexical lock API makes the synchronization boundary visible; explicit lifetime extension makes the destruction boundary visible. Fewer lines are not the objective.

- https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines#Rconc-unknown
- https://www.swift.org/documentation/api-design-guidelines/

## Executed evidence

Linux x86_64; Swift 6.2.1. Exact original Core sources were reconstructed and checked against their Git blob hashes before testing.

- Original Core: 39 XCTest tests passed.
- Candidate Core: 42 XCTest tests passed, including all original tests and three new lifetime/reentrancy tests.
- A separate probe against the original `CancellationFlag` printed `before-remove`, then `entered-deinit`, and hit a three-second process timeout (exit 124).
- The same probe against the candidate printed `left-deinit` and `after-remove` and exited 0.

The first candidate build attempt used an incorrectly relocated module cache and failed; a fresh, dedicated scratch directory was used for the passing run. That failure is retained in the delivered evidence archive. This does not establish macOS app, GPU, model, UI, or packaged-runtime acceptance.

## Local qualification

Run `swift test --package-path Core` and the repository's existing portable/native gates. Do not merge on the strength of this document alone. No application UI, model selection, storage format, or generation-owner logic changes here.
