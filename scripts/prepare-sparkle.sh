#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_version=2.10.1
sparkle_sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
vendor_dir="$project_dir/build/vendor"
sparkle_dir="$vendor_dir/Sparkle-$sparkle_version"
archive="$vendor_dir/Sparkle-$sparkle_version.tar.xz"
mkdir -p "$vendor_dir"
if [ ! -f "$archive" ] || ! printf '%s  %s\n' "$sparkle_sha" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" -o "$archive.partial"
  printf '%s  %s\n' "$sparkle_sha" "$archive.partial" | shasum -a 256 -c - >&2
  mv "$archive.partial" "$archive"
fi
if [ ! -f "$sparkle_dir/Sparkle.framework/Versions/B/Sparkle" ] || [ ! -x "$sparkle_dir/bin/generate_appcast" ]; then
  mkdir -p "$sparkle_dir"
  tar -xf "$archive" -C "$sparkle_dir"
fi
printf '%s\n' "$sparkle_dir"
