#!/bin/bash
# SwiftPM compiles C++/Swift, not Metal. Build the pinned upstream shader target
# once, and colocate it with the actual executable before tests or packaging.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin && $# == 1 && "$1" == /* ]] || { echo 'Usage: build-mlx-metallib.sh ABSOLUTE_OUTPUT' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'CMake 3.25 or newer is required for the pinned Metal build.' >&2; exit 1; }
python3 "$HERE/scripts/prepare-mlx-runtime.py" --verify
CMLX="$HERE/App/.build/checkouts/mlx-swift/Source/Cmlx"
[[ "$(git -C "$CMLX/mlx" rev-parse HEAD)" == 1f8e74e3f12f31365464a6867c6579f0e9b29d85 ]] || { echo 'Unexpected Metal source revision.' >&2; exit 1; }
[[ ! -L "$1" ]] || { echo 'Refusing a symlink output.' >&2; exit 1; }
mkdir -p "$HERE/.build-support" "$(dirname "$1")"
WORK="$(mktemp -d "$HERE/.build-support/metallib.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# All configure-time libraries come from the same resolved Swift dependency;
# this step neither downloads another runtime nor builds a second MLX library.
cmake -S "$CMLX/mlx" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_BENCHMARKS=OFF \
  -DMLX_BUILD_PYTHON_BINDINGS=OFF -DMLX_BUILD_CPU=OFF -DMLX_BUILD_CUDA=OFF \
  -DMLX_BUILD_GGUF=OFF -DMLX_BUILD_SAFETENSORS=OFF -DMLX_METAL_JIT=ON \
  -DFETCHCONTENT_SOURCE_DIR_METAL_CPP="$CMLX/metal-cpp" \
  -DFETCHCONTENT_SOURCE_DIR_JSON="$CMLX/json" -DFETCHCONTENT_SOURCE_DIR_FMT="$CMLX/fmt" \
  -DMLX_METAL_PATH="$WORK"
cmake --build "$WORK/build" --target mlx-metallib --parallel 3
[[ -s "$WORK/mlx.metallib" ]] || { echo 'The shader build produced no library.' >&2; exit 1; }
# Replacement touches only a caller-selected generated build output.
cp "$WORK/mlx.metallib" "$1"
shasum -a 256 "$1"
