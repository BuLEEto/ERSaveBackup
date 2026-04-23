#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
odin build . \
    -collection:gui=/home/lee/odin/guiframework \
    -out:./build/ersavebackup

if [[ "${1:-build}" == "run" ]]; then
    exec ./build/ersavebackup
fi
