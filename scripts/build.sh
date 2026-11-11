#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/freetalk.app"
deployment_target=14.0
# A stable local identity keeps TCC grants across rebuilds. Ad-hoc signatures
# change their CDHash (and macOS treats the app as new) on every build.
# Release builds set FREETALK_LOCAL_SIGNING=0 so published archives never
# depend on the keychain of the machine that built them.
if [ -z "${FREETALK_SIGNING_IDENTITY:-}" ] && [ "${FREETALK_LOCAL_SIGNING:-1}" != 0 ] \
  && security find-identity -v -p codesigning 2>/dev/null | grep -q '"freetalk Local Signing"'; then
  FREETALK_SIGNING_IDENTITY="freetalk Local Signing"
fi
sparkle_dir="$(bash "$project_dir/scripts/prepare-sparkle.sh")"
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -swift-version 5 -O -target "arm64-apple-macos$deployment_target" \
  "$project_dir"/native/*.swift \
  -framework AppKit -framework AVFoundation -framework ApplicationServices \
  -framework Carbon -framework CoreAudio -framework AudioToolbox -framework NaturalLanguage -framework Security -framework WebKit \
  -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app_dir/Contents/MacOS/freetalk"
cp "$project_dir/native/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Frameworks"
rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
sparkle_framework="$app_dir/Contents/Frameworks/Sparkle.framework"
if [ -n "${FREETALK_SIGNING_IDENTITY:-}" ]; then
  codesign -f -s "$FREETALK_SIGNING_IDENTITY" -o runtime "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
  codesign -f -s "$FREETALK_SIGNING_IDENTITY" -o runtime --preserve-metadata=entitlements "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
  codesign -f -s "$FREETALK_SIGNING_IDENTITY" -o runtime "$sparkle_framework/Versions/B/Autoupdate"
  codesign -f -s "$FREETALK_SIGNING_IDENTITY" -o runtime "$sparkle_framework/Versions/B/Updater.app"
  codesign -f -s "$FREETALK_SIGNING_IDENTITY" -o runtime "$sparkle_framework"
fi
# Do not inherit the build host's compiler default (which may target a newer OS).
plist_target=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$app_dir/Contents/Info.plist")
binary_target=$(xcrun vtool -show-build "$app_dir/Contents/MacOS/freetalk" | awk '$1 == "minos" { print $2 }')
if [ "$plist_target" != "$deployment_target" ] || [ "$binary_target" != "$deployment_target" ]; then
  printf '%s\n' 'macOS deployment target does not match the app metadata.' >&2
  exit 1
fi
ditto "$project_dir/python" "$app_dir/Contents/Resources/python"
ditto "$project_dir/prompts" "$app_dir/Contents/Resources/prompts"
ditto "$project_dir/setup" "$app_dir/Contents/Resources/setup"
ditto "$project_dir/integrations" "$app_dir/Contents/Resources/integrations"
rm -f "$app_dir/Contents/MacOS/freetalk-cli"
mkdir -p "$app_dir/Contents/Resources/bin"
cp "$project_dir/scripts/freetalk" "$app_dir/Contents/Resources/bin/freetalk"
chmod +x "$app_dir/Contents/Resources/bin/freetalk"
mkdir -p "$app_dir/Contents/Resources/Licenses"
cp "$sparkle_dir/LICENSE" "$app_dir/Contents/Resources/Licenses/Sparkle.txt"
swift "$project_dir/scripts/make-icon.swift" "$project_dir/build/AppIcon.iconset"
iconutil --convert icns "$project_dir/build/AppIcon.iconset" --output "$app_dir/Contents/Resources/AppIcon.icns"
# Compiled caches are local build products, never part of the signed resources.
find "$app_dir/Contents/Resources" -type d -name __pycache__ -exec rm -rf {} +
codesign --force --sign "${FREETALK_SIGNING_IDENTITY:--}" --identifier io.github.zacklinkk.freetalk "$app_dir"
printf '%s\n' "$app_dir"
