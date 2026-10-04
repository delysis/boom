#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS required.' >&2; exit 1; fi
[[ -f "$HERE/RustBridge/Cargo.lock" && -f "$HERE/App/Package.resolved" ]] || { echo 'Run scripts/bootstrap.sh once and review the dependency locks.' >&2; exit 1; }
MLX_RUNTIME=9afc3b55f75a0d41a3d0c11330b9df6a036d24e4
[[ "$(git -C "$HERE/.deps/MLXSwiftLM" rev-parse HEAD)" == "$MLX_RUNTIME" ]] || { echo 'Unexpected MLX Swift LM revision.' >&2; exit 1; }
git -C "$HERE/.deps/MLXSwiftLM" diff --quiet HEAD || { echo 'MLX Swift LM source has local changes.' >&2; exit 1; }
OUT="${1:-$HERE/out/$(date -u +%Y%m%dT%H%M%SZ)}"
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
mkdir -p "$OUT"
exec > >(tee "$OUT/build.log") 2>&1
uname -a
xcodebuild -version
swift --version
cargo --version
rustc --version
xcrun --sdk macosx --show-sdk-version
swift "$HERE/scripts/prepare-runtime.swift" "$HERE/.deps/CoreML-LLM" "$HERE"
(cd "$HERE/Core" && swift test)
(cd "$HERE/App" && swift test)
(cd "$HERE/RustBridge" && cargo fmt -- --check && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings)
(cd "$HERE/RustBridge" && cargo rustc --release --locked --lib -- --print native-static-libs) 2>&1 | tee "$OUT/rust-native-link.log"
swift "$HERE/scripts/record-native-libs.swift" "$OUT/rust-native-link.log" "$HERE/.build-support/RustNativeLink.json"
(cd "$HERE/App" && swift build -c release --disable-automatic-resolution)
BIN="$(cd "$HERE/App" && swift build -c release --show-bin-path)"
APP="$OUT/Bloom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Boom" "$APP/Contents/MacOS/Bloom"
# Keep package resources in the standard sealed location. Boom's supported
# Gemma bundles include their tokenizer configuration; the Hub package's
# GPT/T5 fallback resources are not part of Boom's model path.
find "$BIN" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP/Contents/Resources/" \;
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSSpeechRecognitionUsageDescription' "$APP/Contents/Info.plist")" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist")" ]]
(
  cd "$HERE"
  { find App/Sources Core/Sources RuntimeAdditions RustBridge/src crates scripts -type f; printf '%s\n' App/Package.swift Core/Package.swift RustBridge/Cargo.toml Cargo.toml Info.plist NOTICE.md; } | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done
) > "$OUT/source-files.sha256"
(
  cd "$HERE"
  shasum -a 256 RustBridge/Cargo.lock App/Package.resolved
) > "$OUT/dependency-locks.sha256"
SOURCE_HASH="$(shasum -a 256 "$OUT/source-files.sha256" | awk '{print $1}')"
LOCK_HASH="$(shasum -a 256 "$OUT/dependency-locks.sha256" | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Add :BoomSourceSHA256 string $SOURCE_HASH" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BoomDependencyLockSHA256 string $LOCK_HASH" "$APP/Contents/Info.plist"
cp "$OUT/source-files.sha256" "$OUT/dependency-locks.sha256" "$APP/Contents/Resources/"
cp "$HERE/LICENSE" "$HERE/NOTICE.md" "$APP/Contents/Resources/"
# Inventory only resolved package sources, never the developer's entire Cargo cache.
(cd "$HERE/RustBridge" && cargo metadata --locked --format-version 1) > "$OUT/cargo-metadata.json"
swift "$HERE/scripts/collect-notices.swift" "$HERE" "$OUT/cargo-metadata.json" "$APP/Contents/Resources/ThirdPartyNotices" "$OUT/license-inventory.json"
# Review the exact lockfiles, missing notices, and license eligibility before distribution.
cp "$HERE/RustBridge/Cargo.lock" "$OUT/Cargo.lock"
cp "$HERE/App/Package.resolved" "$OUT/Package.resolved"
# TCC reads the app's privacy descriptions from its signed bundle identity.
# Signing only the SwiftPM executable leaves Info.plist unbound and can abort
# Speech or microphone access when launched outside LaunchServices.
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" > "$OUT/code-signing-scope.txt" 2>&1
rg -q 'Info.plist entries=[1-9]' "$OUT/code-signing-scope.txt"
rg -q 'Sealed Resources version=2' "$OUT/code-signing-scope.txt"
otool -L "$APP/Contents/MacOS/Bloom" > "$OUT/dynamic-dependencies.txt"
shasum -a 256 "$APP/Contents/MacOS/Bloom" > "$OUT/executable.sha256"
du -sk "$APP" > "$OUT/bundle-size-kib.txt"
echo "Built $APP"
echo 'Build success is not UI, Keychain, download, media, or real-weight acceptance. Run the documented native gates.'
