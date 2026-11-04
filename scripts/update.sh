#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$HOME/Applications/freetalk.app"
if /usr/bin/pgrep -x freetalk >/dev/null || /usr/bin/pgrep -x LocalVoice >/dev/null; then
  printf '%s\n' 'Quit freetalk / Local Voice from its menu before updating.' >&2
  exit 1
fi
bash "$project_dir/scripts/build.sh"
if [ -d "$app_dir" ]; then
  mv "$app_dir" "$project_dir/build/freetalk.previous.$(date +%Y%m%d%H%M%S).app"
fi
mkdir -p "$HOME/Applications"
ditto "$project_dir/build/freetalk.app" "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [ -d "$HOME/Applications/Local Voice.app" ]; then
  mv "$HOME/Applications/Local Voice.app" "$project_dir/build/Local Voice.previous.$(date +%Y%m%d%H%M%S).app"
fi
printf '%s\n' "$app_dir"
