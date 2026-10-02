#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME=18a9b5fd3d7e1f1f5d182533c94d311a7e649f7c
if [[ "$(uname -s)" != Darwin ]]; then echo 'The native app build requires macOS 15+ and Xcode. Core tests run independently on Linux.' >&2; exit 1; fi
command -v cargo >/dev/null || { echo 'Install Rust to build the attachment bridge.' >&2; exit 1; }
xcrun --find swift >/dev/null
mkdir -p "$HERE/.deps"
if [[ ! -e "$HERE/.deps/CoreML-LLM" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/john-rocky/CoreML-LLM.git "$HERE/.deps/CoreML-LLM"
  git -C "$HERE/.deps/CoreML-LLM" fetch --depth 1 origin "$RUNTIME"
  git -C "$HERE/.deps/CoreML-LLM" checkout --detach "$RUNTIME"
fi
[[ "$(git -C "$HERE/.deps/CoreML-LLM" rev-parse HEAD)" == "$RUNTIME" ]] || { echo 'Unexpected CoreML runtime revision.' >&2; exit 1; }
swift "$HERE/scripts/prepare-runtime.swift" "$HERE/.deps/CoreML-LLM" "$HERE"
# Dependency resolution is a DEVELOPMENT operation, not an app runtime feature.
# The emitted Cargo.lock and Package.resolved must be retained with Mac receipts.
mkdir -p "$HERE/.build-support"
(cd "$HERE/RustBridge" && cargo fmt -- --check && { [[ -f Cargo.lock ]] || cargo generate-lockfile; })
(cd "$HERE/App" && swift package resolve)
echo 'Source preparation complete. Review and retain the generated dependency locks before release.'
