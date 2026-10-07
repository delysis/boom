# Original-scene comparison

These texts were authored by Codex for this study on 2026-10-07. They are synthetic fixtures, not human manuscripts or Bloom model outputs. No published passage was intentionally adapted. Original authorship reduces the familiar-passage confound; it cannot establish that every phrase is absent from training data.

Each manuscript has paired conditions: no literary example, or its one explicitly selected prose example. The selected examples use different characters and events. Text in the separate `-after` files remains in the captured manuscript after the caret and must not enter the model prompt. Use the complete preceding manuscript, one explicit BOS, ordinary Standard/Steady/Open settings, seeds 42/2026/8675309, a three-row shared-prefill batch and 256 tokens per row. Replay every condition after other profiles have run. Retain every output, empty ending and failure. Do not change filters, weights, defaults, stopping or prose after seeing results.

Before generating, register these assessment criteria:

- Continuity: characters, speaker attribution, objects, physical actions, time and the immediate unfinished action. A surprising development is valid when the text prepares or connects it.
- Prose: intelligible sentences, register and rhythm relative to the manuscript. Associative movement, comic reversals and paragraph-opening whitespace are valid.
- Repetition: whether repeated words or ideas do useful work, develop a motif or instead stall the scene.
- Useful variation: whether the three alternatives offer distinguishable narrative or stylistic routes the author could develop. String inequality alone is insufficient.
- Author control: actual captured context and omissions, seeds, output budgets, endings, full replay, and the absence of unsolicited manuscript insertion. Controller acceptance/Undo/branching has separate native evidence.

Create shuffled reading copies that conceal profile, seed and example condition. Assess every original output for continuity, prose and repetition on 0/1/2 scales (serious defect / requires repair / coherent and effective), with a concrete observation and possible author use. Reveal the key only after assessments are saved, then compare paired conditions and all three alternatives in each group. These are structured assistant judgments, not a human writer quality gate or a statistically powered ranking of profiles. Do not manufacture a winner from a small suite.
