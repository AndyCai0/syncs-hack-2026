#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_runner="$repo_root/.venv/bin/uvicorn"

if [[ ! -x "$backend_runner" ]]; then
  echo "Missing $backend_runner"
  echo "Create the environment with: python3 -m venv .venv && .venv/bin/pip install -r backend/requirements.txt"
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to start the frontend"
  exit 1
fi
if [[ ! -d "$repo_root/frontend/node_modules" ]]; then
  echo "Missing frontend/node_modules; run: npm --prefix frontend ci"
  exit 1
fi

backend_pid=""
frontend_pid=""

cleanup() {
  [[ -n "$backend_pid" ]] && kill "$backend_pid" 2>/dev/null || true
  [[ -n "$frontend_pid" ]] && kill "$frontend_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Backend: http://127.0.0.1:8000"
echo "Frontend: http://127.0.0.1:5173"
echo "Press Ctrl-C to stop both servers."

(cd "$repo_root" && "$backend_runner" backend.app.main:app --host 127.0.0.1 --port 8000) &
backend_pid=$!

backend_ready=false
for _ in {1..120}; do
  if ! kill -0 "$backend_pid" 2>/dev/null; then
    echo "Backend exited before becoming ready"
    exit 1
  fi
  if "$repo_root/.venv/bin/python" -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/api/health", timeout=1).read()' \
    >/dev/null 2>&1; then
    backend_ready=true
    break
  fi
  sleep 0.1
done
if [[ "$backend_ready" != true ]]; then
  echo "Backend did not become ready within 12 seconds"
  exit 1
fi

(cd "$repo_root" && npm --prefix frontend run dev -- --host 127.0.0.1) &
frontend_pid=$!

while kill -0 "$backend_pid" 2>/dev/null && kill -0 "$frontend_pid" 2>/dev/null; do
  sleep 1
done
