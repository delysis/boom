# Source provenance and notices

Newly authored product source is provided under the adjacent MIT license. This does not relicense the attachment crates, MLX runtime, resolved dependencies, Apple SDKs, or model weights. Dependencies and weights are obtained separately.

## Incorporated source

| Authority | Pinned source | Use |
| --- | --- | --- |
| `delysis/native-platform` | Commit `d6915bad3ca7fa68ed483acff82ae86313934fd1`, attachment subtree `a610874342ad36aefa2908bfdd38367fd3f6bde0` | Five attachment crates in `crates/`; their original notices are retained. |
| `pulldown-cmark` | Crates.io `0.13.4`, published archive SHA256 `e9f068eba8e7071c5f9511831b44f32c740d5adf574e990f946ddb53db2f314e` | Local MIT-licensed parser in `vendor/pulldown-cmark`, extended with bounded resumable parsing. Original LICENSE is retained; this modified path dependency is not byte-identical to the registry release. |
| `ml-explore/mlx-swift-lm` | Commit `9afc3b55f75a0d41a3d0c11330b9df6a036d24e4` | Native Swift Gemma 4 runtime, developer conversion, and sampling. |
| Google Gemma 4 | Base `023679ed352de9bb66cc873c9009ce3482585c08`; instruction/QAT `b6ed86275a6a5735884e208bfed95b445a684ca2` | Separately acquired official checkpoints; converted pack manifests retain upstream and output hashes, settings, runtime identity, and licenses. |
| MLX Community Gemma 4 | Base `7d7c99c4d1b1d2ec2b52e2c46821cef2fa22ce0c`; instruction/QAT `e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6` | Separately downloaded public artifacts with pinned file hashes and configuration. Exact upstream conversion lineage is not independently established. Model cards and upstream license references accompany the catalog; app distribution does not include these weights. |

Bloom uses MLX for inference. Native-platform reuse is confined to attachment crates. No Cotabby implementation or AGPL source is copied or linked.

The local remediation includes the shared NPE-007 repair to XZ block-header
property bounds in `attachment-native-inspect`, bounded MIME traversal before
eager message parsing, ZIP directory count/extent admission and parser-domain
binding (including explicit ambiguity refusal), and borrowed XLSX shared-string values with complete
trailing XML validation in `attachment-native-document`. Their canonical owner is `delysis/native-platform`;
this is a reviewed local delta from the recorded import, not a new upstream
release or an assertion that the modified copy remains byte-identical to the
pinned subtree. The exact audit patch and before/after hashes identify the delta.

Primary model documentation:

- [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Gemma 4 prompt format](https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4)
- [Gemma Apache 2.0 license](https://ai.google.dev/gemma/apache_2)

The build notice collector inventories the actual resolved Cargo packages and Swift dependencies. It preserves top-level notices, bounded LICENSES/LICENCES directories and declared license files without scanning unrelated caches. Workspace-root notices apply only to identified workspace members. The exact omitted upstream notices for `html-to-markdown-rs` are retained under `licenses/`, bound to its published source revision and raw hashes in `supplemental.json`. An incomplete notice inventory refuses packaging. The generated inventory records `distribution_approved: false`; compilation does not constitute a distribution license review. Retain attribution for statically linked Rust dependencies as well as Swift dependencies.

Model integrity and runtime licensing are separate from eligibility to distribute weights. Review each exact model's license and notices before publication. Local packs and the app source remain separate artifacts.
