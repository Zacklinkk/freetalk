#!/bin/bash
# Compile the real settings UI with isolated data and no worker, updater or hotkey.
set -euo pipefail
cd "$(dirname "$0")/.."
preview_dir="$PWD/build/settings-preview"
mkdir -p "$preview_dir/native" "$preview_dir/support"
cp native/*.swift "$preview_dir/native/"
python3 - "$preview_dir" <<'PY'
import sys,pathlib,plistlib
p=pathlib.Path(sys.argv[1]);f=p/'native/main.swift';s=f.read_text()
s=s.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/freetalk", isDirectory: true)', 'URL(fileURLWithPath:'+repr(str(p/'support')).replace("'",'"')+')')
a=s.index('    func applicationDidFinishLaunching(');b=s.index('    func createMenu()',a)
s=s[:a]+'''    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UserDefaults.standard.set(false,forKey:"shortcutEnabled")
        createMenu(); createWindow(); refreshDevices(); showWindow()
    }

'''+s[b:];f.write_text(s)
app=p/'freetalk Settings Preview.app/Contents';(app/'MacOS').mkdir(parents=True,exist_ok=True)
info=plistlib.load(open('native/Info.plist','rb'));info.update(CFBundleIdentifier='io.github.zacklinkk.freetalk.settings-preview',CFBundleName='freetalk Settings Preview',CFBundleDisplayName='freetalk Settings Preview',LSUIElement=False)
plistlib.dump(info,open(app/'Info.plist','wb'))
PY
sparkle_dir="$(bash scripts/prepare-sparkle.sh)"
app_dir="$preview_dir/freetalk Settings Preview.app"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "$preview_dir"/native/*.swift \
 -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon -framework CoreAudio -framework AudioToolbox -framework NaturalLanguage -framework Security -framework WebKit \
 -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app_dir/Contents/MacOS/freetalk"
mkdir -p "$app_dir/Contents/Frameworks"
ditto "$sparkle_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
ditto build/freetalk.app/Contents/Resources "$app_dir/Contents/Resources"
codesign -f -s - "$app_dir"
printf '%s\n' "$app_dir"
