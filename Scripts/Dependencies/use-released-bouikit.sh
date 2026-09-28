#!/bin/sh

set -eu

# 把根 Package.swift 与 demo 工程的 BOUIKit 依赖还原成已发布版本。
# 版本号取自 Package.swift 里的 `// BOUIKIT-LOCAL released: x.y.z` 标记注释；
# 发布了新版本就先手动把那行的版本号改成新版本，再跑本脚本。

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

cd "$repository_root"
swift package unedit bouikit 2>/dev/null || true

released_version=$(sed -n 's/.*BOUIKIT-LOCAL released: \([0-9][^ ]*\).*/\1/p' Package.swift | head -n 1)
if [ -n "$released_version" ]; then
    python3 "$(dirname "$0")/switch-demo-bouikit.py" released "$released_version"
else
    echo "Package.swift has no BOUIKIT-LOCAL marker; leaving the demo project untouched."
fi

python3 - "$repository_root/Package.swift" <<'PY'
import re
import sys

manifest_path = sys.argv[1]
manifest = open(manifest_path, encoding="utf-8").read()

pattern = re.compile(
    r"\.package\(name: \"BOUIKit\", path: \"[^\"]+\"\)\s*// BOUIKIT-LOCAL released: (?P<version>[^\n]+)\n"
)
match = pattern.search(manifest)
if match is None:
    print("Package.swift already uses the released BOUIKit dependency.")
    raise SystemExit(0)

replacement = (
    ".package(\n"
    "            url: \"https://github.com/chbo297/BOUIKit.git\",\n"
    "            from: \"%s\"\n"
    "        )\n" % match.group("version").strip()
)
open(manifest_path, "w", encoding="utf-8").write(pattern.sub(replacement, manifest, count=1))
print("Package.swift restored to released BOUIKit %s" % match.group("version").strip())
PY

swift package resolve >/dev/null

echo "AppAgent now uses the BOUIKit version declared in Package.swift."
