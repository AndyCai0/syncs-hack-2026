#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec npm --prefix "$repo_root/frontend" run dev -- --host 127.0.0.1
