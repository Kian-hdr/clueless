#!/usr/bin/env bash
set -euo pipefail

# Native Icon Composer artwork compilation, including the legacy macOS fallback.
# Run before bundle signing. This script never launches or stops the application.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/Icon_Output}"
ICON_DOCUMENT="$ROOT_DIR/Resources/Clueless.icon"
XCODE_DEVELOPER_DIR="$(xcode-select -p)"
ICON_TOOL="$(dirname "$XCODE_DEVELOPER_DIR")/Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ ! -x "$ICON_TOOL" ]]; then
  printf 'Icon Composer 2 ictool is required. Select Xcode 27 or later with xcode-select.\n' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
# Rendering confirms the native document loader can open the package. Schema
# validation is a separate source-maintenance check, documented in provenance.
"$ICON_TOOL" "$ICON_DOCUMENT" --export-image \
  --output-file "$OUTPUT_DIR/Clueless_Preview.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1

xcrun actool "$ICON_DOCUMENT" \
  --compile "$OUTPUT_DIR" \
  --platform macosx --minimum-deployment-target 14.2 \
  --app-icon Clueless \
  --output-partial-info-plist "$OUTPUT_DIR/IconInfo.plist" \
  --warnings --notices --output-format human-readable-text

test -s "$OUTPUT_DIR/Assets.car"
test -s "$OUTPUT_DIR/Clueless.icns"
test "$(plutil -extract CFBundleIconName raw "$OUTPUT_DIR/IconInfo.plist")" = Clueless
test "$(plutil -extract CFBundleIconFile raw "$OUTPUT_DIR/IconInfo.plist")" = Clueless
