#!/bin/bash
# Launch the real settings UI (isolated data, no worker, updater or hotkey) and
# fail if it crashes while building its pages. Unit tests never construct the
# window, so a crash in a settings card would otherwise surface only at launch.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$(bash scripts/build-settings-preview.sh | tail -1)"
# Skip window restoration: after an earlier crash AppKit would otherwise wait
# on a "reopen windows?" prompt before the settings window is ever built.
"$app_dir/Contents/MacOS/freetalk" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep "${SMOKE_SECONDS:-8}"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"; wait "$pid" 2>/dev/null || true
  printf '%s\n' 'Settings UI launched and stayed up'
else
  status=0; wait "$pid" || status=$?
  printf 'Settings UI exited during launch (status %s)\n' "$status" >&2
  exit 1
fi
