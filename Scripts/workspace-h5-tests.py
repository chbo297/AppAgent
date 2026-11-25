#!/usr/bin/env python3
"""Workspace H5 tests: compile the real workspace H5 sources with JSONValue into one macOS
executable and run it (content validation, touch policy, scheme handler, bridge script in WebKit).

Usage: Scripts/workspace-h5-tests.py [--core-only]
"""

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Core/Foundation/JSONValue.swift",
    ROOT / "Sources/Core/Session/SessionWorkspace.swift",
    *(ROOT / "Sources/UI/Workspace" / (name + ".swift") for name in (
        "AppAgentWorkspaceH5Content", "AppAgentWorkspaceUIPolicy",
        "AppAgentWorkspaceSchemeHandler", "AppAgentWorkspaceBridgeScript",
    )),
    ROOT / "Tests/WorkspaceH5/WorkspaceH5DirectedTests.swift",
    ROOT / "Tests/WorkspaceH5/WorkspaceH5WebKitTests.swift",
]


def main() -> int:
    """Compile the workspace H5 sources into one executable, run it and return its exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-only", action="store_true", help="skip the WebKit bridge tests")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="workspace-h5-") as temporary:
        build = Path(temporary)
        executable = build / "workspace-h5-tests"
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(build / "module-cache"))
        command = [
            "swiftc", "-swift-version", "5", "-parse-as-library", "-g", "-warnings-as-errors",
            "-module-cache-path", str(build / "module-cache"),
            *map(str, SOURCES), "-o", str(executable),
        ]
        print("COMPILE " + shlex.join(command), flush=True)
        subprocess.run(command, check=True, timeout=300, env=environment)
        command = [str(executable)] + (["--core-only"] if args.core_only else [])
        return subprocess.run(command, timeout=300, env=environment).returncode


if __name__ == "__main__":
    raise SystemExit(main())
