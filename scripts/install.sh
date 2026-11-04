#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$HOME/Applications/freetalk.app"
if [ -d "$app_dir" ]; then
  printf '%s\n' 'freetalk is already installed. Quit it, then use scripts/update.sh.' >&2
  exit 1
fi
codesign --verify --deep --strict "$project_dir/build/freetalk.app"
mkdir -p "$HOME/Applications"
ditto "$project_dir/build/freetalk.app" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
