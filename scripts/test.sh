#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
"${PYTHON:-python3}" -m unittest discover -s tests -p 'test_*.py' -v
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Python tests complete. Native checks require macOS.'
  exit 0
fi
mkdir -p build/tests
native_test() {
  local name="$1"; shift
  swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "$@" "tests/$name.swift" \
    -framework AppKit -framework AVFoundation -framework ApplicationServices \
    -framework Carbon -framework CoreAudio -framework AudioToolbox -framework NaturalLanguage \
    -o "build/tests/$name"
  "build/tests/$name"
}
native_test HotkeyTests native/Input.swift native/Audio.swift
native_test InputIdentityTests native/Input.swift native/Audio.swift
native_test HistoryTests native/History.swift
native_test VocabularyTests native/Vocabulary.swift
native_test CorrectionsTests native/Corrections.swift native/Vocabulary.swift native/Input.swift native/Audio.swift
native_test SetupMigrationTests native/ModelSetup.swift
native_test SetupProcessTests native/ModelSetup.swift
native_test PermissionTests native/Permissions.swift
sparkle_dir="$(bash scripts/prepare-sparkle.sh)"
native_test UpdaterTests native/AppUpdater.swift -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle_dir"
