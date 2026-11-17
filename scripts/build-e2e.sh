#!/bin/bash
# The app with test hooks for the in-app end-to-end checks (native/E2EHooks.swift),
# in build/freetalk-e2e.app so it is never mistaken for the normal build.
# Signed like the normal local build, so macOS keeps its permissions. Never install or publish it.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
FREETALK_APP_DIR="$project_dir/build/freetalk-e2e.app" FREETALK_SWIFT_FLAGS="-D E2E_HOOKS" bash "$project_dir/scripts/build.sh"
