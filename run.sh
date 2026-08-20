#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v wget >/dev/null 2>&1; then
  echo "wget is required. On Ubuntu/WSL run: sudo apt-get update && sudo apt-get install -y wget coreutils" >&2
  exit 2
fi

exec "$SCRIPT_DIR/batch.sh" "$@"
