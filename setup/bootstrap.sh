#!/bin/bash
# Install into app-owned storage only. No sudo, shell-profile changes, or account.
set -euo pipefail
umask 077
setup_dir="$(cd "$(dirname "$0")" && pwd)"
support_dir="$1"
existing_python="${2:-}"
model_selection="${3:-all}"
model_source="${4:-official}"
model_catalog="$setup_dir/catalog.json"
if [ "$model_selection" = meetingDiarizationModel ]; then model_catalog="$setup_dir/meeting-catalog.json"; fi
case "$model_source" in
  official|mirror) ;;
  *) printf '%s\n' '{"event":"error","message":"不支持的模型下载来源"}'; exit 1 ;;
esac
child_pid=''
cancel() {
  trap - TERM INT
  if [ -n "$child_pid" ]; then kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi
  exit 130
}
trap cancel TERM INT
run() {
  "$@" & child_pid=$!
  local result=0
  wait "$child_pid" || result=$?
  child_pid=''
  return "$result"
}
event() { printf '{"event":"progress","stage":"runtime","message":"%s"}\n' "$1"; }
mkdir -p "$support_dir"
if [ "$(uname -m)" != arm64 ]; then
  printf '%s\n' '{"event":"error","message":"需要 Apple Silicon Mac，暂不支持 Intel 或 Rosetta"}'
  exit 1
fi
event '检查本地运行环境…'
selected_python=''
if [ -n "$existing_python" ] && [ -x "$existing_python" ]; then
  if run "$existing_python" "$setup_dir/check_runtime.py" >/dev/null 2>&1; then selected_python="$existing_python"; fi
fi
managed_dir="$support_dir/runtime/managed-v1"
if [ -z "$selected_python" ] && [ -x "$managed_dir/venv/bin/python" ]; then
  if run "$managed_dir/venv/bin/python" "$setup_dir/check_runtime.py" >/dev/null 2>&1; then selected_python="$managed_dir/venv/bin/python"; fi
fi
if [ -z "$selected_python" ]; then
  event '准备运行环境 · 首次需要联网，请稍候…'
  mkdir -p "$support_dir/downloads" "$managed_dir/tools"
  archive="$support_dir/downloads/uv-0.13.7-aarch64-apple-darwin.tar.gz"
  expected='81b811b57e4624df7ed3aac148e0359100d9962f3d9dce00aec533dc2e086731'
  verify_archive() { [ -f "$archive" ] && [ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" = "$expected" ]; }
  if ! verify_archive; then
    # The small runtime bootstrap restarts safely; large model files resume.
    run /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --retry 2 \
      'https://github.com/astral-sh/uv/releases/download/0.13.7/uv-aarch64-apple-darwin.tar.gz' --output "$archive"
    if ! verify_archive; then printf '%s\n' '{"event":"error","message":"运行环境下载校验失败，请重试"}'; exit 1; fi
  fi
  run /usr/bin/tar -xzf "$archive" -C "$managed_dir/tools"
  uv_binary="$managed_dir/tools/uv-aarch64-apple-darwin/uv"
  export UV_PYTHON_INSTALL_DIR="$managed_dir/python"
  export UV_CACHE_DIR="$managed_dir/cache"
  export UV_PYTHON_BIN_DIR="$managed_dir/bin"
  export UV_NO_MODIFY_PATH=1 UV_NO_PROGRESS=1 UV_NO_CONFIG=1 UV_MANAGED_PYTHON=1
  event '安装独立 Python · 不修改系统 Python…'
  run "$uv_binary" python install 3.11.14 --no-bin >&2
  if [ ! -x "$managed_dir/venv/bin/python" ]; then
    run "$uv_binary" venv --python 3.11.14 "$managed_dir/venv" >&2
  fi
  event '安装本地语音推理组件…'
  run "$uv_binary" pip install --python "$managed_dir/venv/bin/python" --require-hashes --only-binary :all: \
    --index-url https://pypi.org/simple -r "$setup_dir/requirements.txt" >&2
  selected_python="$managed_dir/venv/bin/python"
  run "$selected_python" "$setup_dir/check_runtime.py" >&2
fi
event '运行环境就绪，开始核对模型…'
exec "$selected_python" -u "$setup_dir/models.py" --support "$support_dir" --python "$selected_python" --only "$model_selection" --source "$model_source" --catalog "$model_catalog"
