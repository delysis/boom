# E04 — Ask for fewer pieces, not a different language

Unranked elegance archive. Exact base: `88ee71642e5d5cdeaa25764d314aac82bc8cfa84`.

`GemmaPrompt.visibleCompletion` materialized all paragraph and line pieces before retaining the first paragraph and up to three lines. The candidate uses bounded `String.split` calls, preserving empty pieces, leading whitespace and the existing completion admission policy.

This bounds the number of split pieces. It does **not** establish constant-time execution, bounded input size, a measured allocation reduction, or a benchmark speedup. A long unbroken paragraph still takes work. No dependency, format or model route is changed.

## The rejected attractive refactor

An earlier byte-scanning attempt changed the observed CR/LF behavior of Swift's String-level `components(separatedBy:)` on Swift 6.2.1 Linux. The actual differential run produced 666 assertion failures. That candidate was discarded, not patched around by changing the oracle. Its source and failed log remain in the delivered book archive.

## Executed evidence

- Original portable Core: 39 XCTest tests passed.
- This candidate: 43 XCTest tests passed, zero failures.
- New tests cover all 21,845 strings of length zero through seven over a / space / LF / CR, plus Unicode and control combinations, byte-limit edges and a million-byte unselected tail.
- All original portable Core files were reconstructed against their Git blob hashes.

These runs used Swift 6.2.1 on Linux x86_64. macOS/Foundation parity, actual application, UI and model acceptance remain unexecuted. Run the differential tests on the supported native platform and preserve the existing repository gates before promotion.

This is independent of E01 (cancellation lifetime), though both change different regions of Prompt.swift. Review and test their composition rather than replacing one complete file with the other.

Historical affinity: Hughes's compositional account of avoiding unnecessary intermediate work; differential/property testing as an executable counterargument to a plausible refactor. This is not a claim that Hughes authored this particular change.
