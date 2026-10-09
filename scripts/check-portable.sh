#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$HERE" && cargo fmt --all -- --check && cargo test --workspace --locked && cargo clippy --workspace --all-targets --locked -- -D warnings)
(cd "$HERE/Core" && swift test)
if [[ "$(uname -s)" == Darwin ]]; then python3 "$HERE/scripts/test-notice-collector.py"; fi
swiftc -frontend -parse "$HERE"/App/Sources/Boom/*.swift
# Each executable script has top-level statements; parse it as its own source unit.
for script in "$HERE"/scripts/*.swift; do swiftc -frontend -parse "$script"; done
swiftc -swift-version 5 -typecheck "$HERE/App/Sources/Boom/AsyncWork.swift"
clang -fsyntax-only -Wall -Wextra -Werror -I"$HERE/App/Sources/CAttachment/include" "$HERE/App/Sources/CAttachment/shim.c"
for script in "$HERE"/scripts/*.sh; do bash -n "$script"; done
echo 'Portable tests, Swift syntax, async join helper type-check and C header passed.'
echo 'Native Swift/MLX type-check and native runtime tests were NOT run by this script.'
