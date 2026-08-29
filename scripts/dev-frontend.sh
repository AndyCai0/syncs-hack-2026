#!/bin/zsh
# Vite dev server; node lives in the conda node22 env on this machine.
export PATH="/opt/miniconda3/envs/node22/bin:$PATH"
cd "$(dirname "$0")/../frontend"
exec npm run dev
