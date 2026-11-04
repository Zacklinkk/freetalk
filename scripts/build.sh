#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/freetalk.app"
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  "$project_dir"/native/*.swift \
  -framework AppKit -framework AVFoundation -framework ApplicationServices \
  -framework Carbon -framework CoreAudio -framework AudioToolbox -framework NaturalLanguage \
  -o "$app_dir/Contents/MacOS/freetalk"
cp "$project_dir/native/Info.plist" "$app_dir/Contents/Info.plist"
ditto "$project_dir/python" "$app_dir/Contents/Resources/python"
ditto "$project_dir/prompts" "$app_dir/Contents/Resources/prompts"
ditto "$project_dir/setup" "$app_dir/Contents/Resources/setup"
swift "$project_dir/scripts/make-icon.swift" "$project_dir/build/AppIcon.iconset"
iconutil --convert icns "$project_dir/build/AppIcon.iconset" --output "$app_dir/Contents/Resources/AppIcon.icns"
# Compiled caches are local build products, never part of the signed resources.
find "$app_dir/Contents/Resources" -type d -name __pycache__ -exec rm -rf {} +
codesign --force --sign "${FREETALK_SIGNING_IDENTITY:--}" --identifier io.github.zacklinkk.freetalk "$app_dir"
printf '%s\n' "$app_dir"
