#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Path to the Skald GUI framework checkout — https://github.com/BuLEEto/Skald
# Defaults to a sibling directory next to this repo; override by exporting
# GUI_PATH if you keep Skald elsewhere.
GUI_PATH="${GUI_PATH:-$(cd "$(dirname "$0")/../Skald" 2>/dev/null && pwd)}"

if [[ -z "$GUI_PATH" || ! -d "$GUI_PATH" ]]; then
    echo "error: Skald not found at ../Skald — set GUI_PATH to your checkout." >&2
    exit 1
fi

mkdir -p build
odin build . \
    -collection:gui="$GUI_PATH" \
    -out:./build/ersavebackup

if [[ "${1:-build}" == "run" ]]; then
    exec ./build/ersavebackup
fi
