#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
CONFIGURATION="${CLUELESS_BUILD_CONFIGURATION:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Clueless"
BUNDLE_ID="com.kiankonrad.Clueless"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
cd "$ROOT_DIR"
if [[ "$MODE" != "--build-only" ]]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
swift build -c "$CONFIGURATION"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
"$ROOT_DIR/script/build_icon.sh"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/InterviewAssistant" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/CluelessFastAnswer" "$APP_BUNDLE/Contents/Helpers/CluelessFastAnswer"
cp "$ROOT_DIR/.build/Icon_Output/Assets.car" "$ROOT_DIR/.build/Icon_Output/Clueless.icns" "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Clueless</string>
<key>CFBundleIdentifier</key><string>com.kiankonrad.Clueless</string>
<key>CFBundleName</key><string>Clueless</string>
<key>CFBundleDisplayName</key><string>Clueless</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Clueless</string>
<key>CFBundleIconName</key><string>Clueless</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Clueless transcribes your voice through ElevenLabs while you explicitly enable listening. No audio is recorded to disk.</string>
<key>NSAudioCaptureUsageDescription</key><string>Clueless transcribes call audio through ElevenLabs to suggest answers while listening is enabled.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST
SIGN_ID="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"; fi
if [[ -n "$SIGN_ID" ]]; then
  SIGN_FLAGS=(--options runtime)
  if [[ "$CONFIGURATION" == "release" ]]; then SIGN_FLAGS+=(--timestamp); fi
  codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$APP_BUNDLE/Contents/Helpers/CluelessFastAnswer"
  codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" --entitlements "$ROOT_DIR/script/Clueless.entitlements" "$APP_BUNDLE"
else
  codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/CluelessFastAnswer"
  codesign --force --sign - --entitlements "$ROOT_DIR/script/Clueless.entitlements" "$APP_BUNDLE"
fi
codesign --verify --strict "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  run) open -n "$APP_BUNDLE" ;;
  --verify|verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs|--telemetry|telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"Clueless\"" ;;
  *) printf 'usage: %s [run|--build-only|--verify|--debug|--logs|--telemetry]\n' "$0" >&2; exit 2 ;;
esac
