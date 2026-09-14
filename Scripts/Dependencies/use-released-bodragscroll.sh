#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

cd "$repository_root"
swift package unedit bodragscroll

echo "AppAgent now uses the BODragScroll version declared in Package.swift."
