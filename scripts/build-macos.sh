#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS required.' >&2; exit 1; fi
[[ -f "$HERE/RustBridge/Cargo.lock" && -f "$HERE/App/Package.resolved" ]] || { echo 'Run scripts/bootstrap.sh once and review the dependency locks.' >&2; exit 1; }
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
(cd "$HERE/RustBridge" && cargo fmt -- --check && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings)
(cd "$HERE/RustBridge" && cargo rustc --release --locked --lib -- --print native-static-libs) 2>&1 | tee "$OUT/rust-native-link.log"
swift "$HERE/scripts/record-native-libs.swift" "$OUT/rust-native-link.log" "$HERE/.build-support/RustNativeLink.json"
(cd "$HERE/App" && swift build -c release --disable-automatic-resolution)
BIN="$(cd "$HERE/App" && swift build -c release --show-bin-path)"
APP="$OUT/Boom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Boom" "$APP/Contents/MacOS/Boom"
# SwiftPM's generated accessors search Bundle.main.bundleURL, which is the
# .app root. Keep their resource bundles there so the app is independent of
# the developer's SwiftPM build directory. Never copy weights into the app.
find "$BIN" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP/" \;
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
(
  cd "$HERE"
  { find App/Sources Core/Sources RuntimeAdditions RustBridge/src crates scripts -type f; printf '%s\n' App/Package.swift Core/Package.swift RustBridge/Cargo.toml Cargo.toml Info.plist; } | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$path"; done
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
# SwiftPM's resource-only bundles at the .app root prevent a valid whole-app
# signature. The Swift linker ad-hoc signs the Mach-O; verify that exact input
# and preserve its bytes in the local test bundle. Distribution requires a
# different resource layout and a sealed app signature.
codesign --verify --strict --verbose=2 "$BIN/Boom"
cmp "$BIN/Boom" "$APP/Contents/MacOS/Boom"
printf '%s\n' 'Linker ad-hoc signed executable verified; app bundle is unsealed and for local testing only.' > "$OUT/code-signing-scope.txt"
otool -L "$APP/Contents/MacOS/Boom" > "$OUT/dynamic-dependencies.txt"
shasum -a 256 "$APP/Contents/MacOS/Boom" > "$OUT/executable.sha256"
du -sk "$APP" > "$OUT/bundle-size-kib.txt"
echo "Built $APP"
echo 'Build success is not UI, Keychain, download, media, or real-weight acceptance. Run the documented native gates.'
