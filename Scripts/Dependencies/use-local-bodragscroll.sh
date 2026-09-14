#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
source_path=${BODRAGSCROLL_PATH:-"$repository_root/../BODragScroll"}

if [ ! -f "$source_path/Package.swift" ]; then
    echo "BODragScroll package not found at: $source_path" >&2
    echo "Set BODRAGSCROLL_PATH to its local source directory." >&2
    exit 1
fi
source_path=$(CDPATH= cd -- "$source_path" && pwd)

cd "$repository_root"
swift package resolve
if swift package show-dependencies --format json | grep -Fq "\"path\": \"$source_path\""; then
    echo "AppAgent already uses editable BODragScroll source at: $source_path"
    exit 0
fi
swift package edit bodragscroll --path "$source_path"

echo "AppAgent now uses editable BODragScroll source at: $source_path"
