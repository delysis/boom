# Source provenance and notices

The newly authored files in this product are provided under the adjacent MIT license. This does not relicense native-platform, CoreML-LLM, MLX Swift LM, their dependencies, Apple SDKs, Foundation Models or model assets. Bootstrap obtains dependencies separately; the source tree contains neither third-party checkouts nor weights.

## Source authorities inspected

| Authority | Exact source or scope | Use |
|---|---|---|
| `delysis/native-platform` | Commit `637e60b6b044230ed24ed3118615a2e5538cae83`; tree `29f329624d3030a7d3f2e5b33fa3887b1d2beae3` | Five attachment crates copied into `crates/` with their source history identified here; no other runtime code reused. |
| `john-rocky/CoreML-LLM` | Commit `18a9b5fd3d7e1f1f5d182533c94d311a7e649f7c`; tree `9d1e6548d20b9edd4b3e18da32416389aaff7cf4` | MIT upstream; inspected model/engine/tokenizer interfaces, native arrays, reset/prefill semantics and E2B downloader entry. |
| `ml-explore/mlx-swift-lm` | Commit `9afc3b55f75a0d41a3d0c11330b9df6a036d24e4` | Native Swift Gemma 4 and MTP runtime; linked as a pinned source dependency. First-party Google QAT safetensors are converted locally into the Hugging Face cache. |
| CoreMLLLM source blob | `90cfb5dcea8e8bc79cc8f181b7d12724de77daee` | Exact blob checked before same-file original extension is appended. |
| ChunkedEngine source blob | `f26d7a5a9f045ffab08404a21c065bf32b06f1af` | Exact blob checked; exactly two load sites redirected to a local compile helper, then original extension appended. |
| Official Google Gemma 4 prompt and thinking guides | Inspected 2026-09-28 | Chat turn tokens are used for chat. Document ghost text uses a raw beginning-of-sequence and authored prefix, without chat turns. |
| `nodes-app/swift-markdown-engine` | README/architecture/package | Native Markdown/reference design comparison; no implementation copied or dependency added. |
| `exyte/Chat` | Package/README | Evaluated, not adopted as the macOS chat surface. |
| `john-rocky/coreai-kit` | Package/ChatSession/README | Evaluated; not linked or claimed as an implemented second backend. |
| `can1357/oh-my-pi` | Public editing documentation | Conceptual reference for bounded, stale-safe edit authority; no implementation copied. |
| `FuJacob/cotabby` | Public README/product behavior only | Autocomplete product reference only. **No Cotabby implementation or AGPL code copied or linked.** |

Useful primary documentation identifiers (not runtime endpoints):

```text
https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4
https://ai.google.dev/gemma/docs/capabilities/thinking
https://github.com/john-rocky/CoreML-LLM
https://github.com/delysis/native-platform
```

The build's notice collector inventories actual resolved Cargo source packages and Swift checkouts, retaining top-level notices and explicitly declared license files. It does not scan the developer's whole package cache and does not claim that a collected license is eligible for distribution. The generated license inventory deliberately records `distribution_approved: false`. Missing/embedded notices and all exact resolved licenses require review. Preserve upstream attribution, including notices for dependencies statically linked through the Rust service.

Model provenance/integrity is not model-license eligibility. The installer retains root model LICENSE/NOTICE files when offered by the selected inventory; review the publisher's actual current terms and the immutable downloaded assets. No model license is inferred from the runtime's MIT license.
