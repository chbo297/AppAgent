#!/bin/sh

set -eu

# 把根 Package.swift 与 demo 工程的 BOUIKit 依赖临时切成本地源码路径，用于与 ../BOUIKit 联调。
#
# 为什么不用 `swift package edit`：xcodebuild（Catalyst 测试、demo 工程）不认 SwiftPM 的
# editable checkout（`Packages/` 符号链接），只有命令行 `swift build` 认。所以这里直接改
# Package.swift 的依赖声明，并把原来的版本要求记在标记注释里，便于一键还原。
#
# 切换后的 Package.swift 与 project.pbxproj **都不要提交**；发布前跑 use-released-bouikit.sh 还原。

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
source_path=${BOUIKIT_PATH:-"$repository_root/../BOUIKit"}

if [ ! -f "$source_path/Package.swift" ]; then
    echo "BOUIKit package not found at: $source_path" >&2
    echo "Set BOUIKIT_PATH to its local source directory." >&2
    exit 1
fi
source_path=$(CDPATH= cd -- "$source_path" && pwd)

cd "$repository_root"
swift package unedit bouikit 2>/dev/null || true

BOUIKIT_LOCAL_PATH="$source_path" python3 - "$repository_root/Package.swift" <<'PY'
import os
import re
import sys

manifest_path = sys.argv[1]
local_path = os.environ["BOUIKIT_LOCAL_PATH"]
manifest = open(manifest_path, encoding="utf-8").read()

if "BOUIKIT-LOCAL" in manifest:
    print("Package.swift already points BOUIKit at local source.")
    raise SystemExit(0)

pattern = re.compile(
    r"\.package\(\s*\n\s*url: \"https://github\.com/chbo297/BOUIKit\.git\",\s*\n\s*from: \"(?P<version>[^\"]+)\"\s*\n\s*\)"
)
match = pattern.search(manifest)
if match is None:
    print("Could not find the released BOUIKit dependency declaration in Package.swift.", file=sys.stderr)
    raise SystemExit(1)

replacement = (
    ".package(name: \"BOUIKit\", path: \"%s\")  // BOUIKIT-LOCAL released: %s"
    % (local_path, match.group("version"))
)
open(manifest_path, "w", encoding="utf-8").write(pattern.sub(replacement, manifest, count=1))
print("Package.swift now points BOUIKit at: %s" % local_path)
PY

swift package resolve >/dev/null

python3 "$(dirname "$0")/switch-demo-bouikit.py" local

echo "Reminder: do not commit Package.swift / AppAgentDemo.xcodeproj while they point at local BOUIKit source."
