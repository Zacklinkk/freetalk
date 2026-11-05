#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
app_dir="$project_dir/build/freetalk-hud-preview.app"
mkdir -p "$app_dir/Contents/MacOS"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  native/DictationLimit.swift native/RecordingLimitView.swift native/RecordingHUD.swift \
  native/Input.swift native/Audio.swift scripts/RecordingHUDPreview.swift \
  -framework AppKit -framework AVFoundation -framework ApplicationServices \
  -framework Carbon -framework CoreAudio -framework AudioToolbox \
  -o "$app_dir/Contents/MacOS/freetalk-hud-preview"
python3 - "$app_dir/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable='freetalk-hud-preview',
                      CFBundleIdentifier='io.github.zacklinkk.freetalk.hud-preview',
                      CFBundleName='freetalk HUD Preview', CFBundlePackageType='APPL',
                      LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True), f)
PY
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
