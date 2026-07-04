#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${1:-/Volumes/dust/code/permute}"

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Destination not found: $DEST_DIR" >&2
  exit 1
fi

rsync -av --exclude ".DS_Store" "$ROOT_DIR/lib/" "$DEST_DIR/lib/"
rsync -av --exclude ".DS_Store" "$ROOT_DIR/permute.lua" "$DEST_DIR/permute.lua"

echo "Synced lib/ and permute.lua to $DEST_DIR"
