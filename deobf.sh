#!/bin/bash
# One-shot turnkey deobfuscator launcher
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUNE_BIN="/data/data/com.termux/files/home/.local/bin/lune"

if [ -z "$1" ]; then
    echo "Usage: ./deobf.sh <path_to_obfuscated_file> [--out <output_dir>]"
    echo "Example: ./deobf.sh /storage/emulated/0/Download/scriptbackdoor.txt"
    exit 1
fi

"$LUNE_BIN" run "$DIR/deobf.luau" "$@"
