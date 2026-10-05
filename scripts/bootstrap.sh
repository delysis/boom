#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MLX_RUNTIME=9afc3b55f75a0d41a3d0c11330b9df6a036d24e4
if [[ "$(uname -s)" != Darwin ]]; then echo 'The native app build requires macOS 15+ and Xcode. Core tests run independently on Linux.' >&2; exit 1; fi
command -v cargo >/dev/null || { echo 'Install Rust to build the attachment bridge.' >&2; exit 1; }
xcrun --find swift >/dev/null
mkdir -p "$HERE/.deps"
if [[ ! -e "$HERE/.deps/MLXSwiftLM" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/ml-explore/mlx-swift-lm.git "$HERE/.deps/MLXSwiftLM"
  git -C "$HERE/.deps/MLXSwiftLM" fetch --depth 1 origin "$MLX_RUNTIME"
  git -C "$HERE/.deps/MLXSwiftLM" checkout --detach "$MLX_RUNTIME"
fi
[[ "$(git -C "$HERE/.deps/MLXSwiftLM" rev-parse HEAD)" == "$MLX_RUNTIME" ]] || { echo 'Unexpected MLX Swift LM revision.' >&2; exit 1; }
# Dependency resolution is a DEVELOPMENT operation, not an app runtime feature.
# The emitted Cargo.lock and Package.resolved must be retained with Mac receipts.
mkdir -p "$HERE/.build-support"
(cd "$HERE" && cargo fmt --all -- --check && { [[ -f Cargo.lock ]] || cargo generate-lockfile; })
(cd "$HERE/App" && swift package resolve)
echo 'Source preparation complete. Review and retain the generated dependency locks before release.'
