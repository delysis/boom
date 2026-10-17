#!/bin/bash
# Explicit developer setup, never called by the app. No model weights or
# clinical case data are fetched. Cached exact source supports offline builds.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REV=b2a94f258712b35888dc10dcb4a402a98c69946b
CACHE="$HERE/.build-support/BlessengerSource"
RESOURCE="$HERE/App/Sources/Boom/Resources"
mkdir -p "$CACHE" "$RESOURCE"
fetch() {
  local source="$1" target="$2" expected="$3"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$expected" ]]; then return; fi
  local stage
  stage="$(mktemp "$CACHE/.download.XXXXXX")"
  if ! curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 --max-filesize 4194304 \
    "https://raw.githubusercontent.com/delysis/native-platform/$REV/products/mom/$source" -o "$stage"; then
    rm -f "$stage"; return 1
  fi
  if [[ "$(shasum -a 256 "$stage" | cut -d' ' -f1)" != "$expected" ]]; then
    echo "Pinned Blessenger asset hash mismatch; retained $stage" >&2; return 1
  fi
  mv "$stage" "$target"
}
fetch crates/mom-llama-runtime/assets/therapy_consult_personas.yaml "$CACHE/personas.yaml" 09557b34bc9c85108ab7f901ca419fa50eb60283fb79519b6eeecccf8213ea64
fetch apps/mom-llama/ui/contact-portraits.png "$CACHE/portraits.png" f5d3d737e37821aaa39ad741dd9879512d0994604da5f6771827ebeffb29f51e
ruby "$HERE/scripts/blessenger-catalog.rb" "$HERE/scripts/blessenger-catalog.json" "$CACHE/personas.yaml" "$RESOURCE/BlessengerContacts.json"
cp "$CACHE/portraits.png" "$RESOURCE/BlessengerPortraits.png"
