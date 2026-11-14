#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
# Homophone checks need pypinyin; without it they silently degrade and a few
# tests fail in a confusing way. Fail early with the install command instead.
"${PYTHON:-python3}" -c 'import pypinyin' 2>/dev/null || {
  printf '%s\n' 'Python tests need pypinyin: python3 -m pip install pypinyin==0.55.0' >&2; exit 1; }
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
native_test CleanupFeedbackTests native/CleanupFeedback.swift native/Input.swift native/Audio.swift
native_test CloudCredentialsTests native/CloudEditor.swift native/Audio.swift -framework Security
native_test SetupMigrationTests native/ModelSetup.swift
native_test SetupProcessTests native/ModelSetup.swift
native_test PermissionTests native/Permissions.swift
native_test DictationLimitTests native/DictationLimit.swift
native_test MeetingAudioTests native/MeetingAudio.swift native/Audio.swift
sparkle_dir="$(bash scripts/prepare-sparkle.sh)"
native_test UpdaterTests native/AppUpdater.swift -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle_dir"
