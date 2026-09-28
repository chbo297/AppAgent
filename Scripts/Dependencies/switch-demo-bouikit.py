#!/usr/bin/env python3
"""在 demo 工程里把 BOUIKit 依赖切成本地源码 / 切回已发布版本。

用法：
    switch-demo-bouikit.py local
    switch-demo-bouikit.py released <version>

demo 工程（Examples/iOS/AppAgentDemo.xcodeproj）有独立于根 Package.swift 的包引用，
所以本地联调时两边都要切；切成本地的 pbxproj 不要提交。
"""

import pathlib
import re
import sys

PROJECT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "Examples/iOS/AppAgentDemo.xcodeproj/project.pbxproj"
)
OBJECT_ID = "A1B2C3D4E5F6A7B800000085"

LOCAL_REF = (
    "\t\t%s /* XCLocalSwiftPackageReference \"../../../BOUIKit\" */ = {\n"
    "\t\t\tisa = XCLocalSwiftPackageReference;\n"
    "\t\t\trelativePath = ../../../BOUIKit;\n"
    "\t\t};\n" % OBJECT_ID
)


def remote_ref(version):
    return (
        "\t\t%s /* XCRemoteSwiftPackageReference \"BOUIKit\" */ = {\n"
        "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
        "\t\t\trepositoryURL = \"https://github.com/chbo297/BOUIKit.git\";\n"
        "\t\t\trequirement = {\n"
        "\t\t\t\tkind = upToNextMajorVersion;\n"
        "\t\t\t\tminimumVersion = %s;\n"
        "\t\t\t};\n"
        "\t\t};\n" % (OBJECT_ID, version)
    )


REMOTE_REF_PATTERN = re.compile(
    r"\t\t%s /\* XCRemoteSwiftPackageReference \"BOUIKit\" \*/ = \{.*?\n\t\t\};\n" % OBJECT_ID,
    re.DOTALL,
)
LOCAL_REF_PATTERN = re.compile(
    r"\t\t%s /\* XCLocalSwiftPackageReference \"\.\./\.\./\.\./BOUIKit\" \*/ = \{.*?\n\t\t\};\n" % OBJECT_ID,
    re.DOTALL,
)
PACKAGE_LINE = "\t\t\tpackage = %s /* XCRemoteSwiftPackageReference \"BOUIKit\" */;\n" % OBJECT_ID


def to_local(text):
    if LOCAL_REF_PATTERN.search(text):
        print("Demo project already points BOUIKit at local source.")
        return None

    match = REMOTE_REF_PATTERN.search(text)
    if match is None:
        raise SystemExit("Could not find the remote BOUIKit package reference in the demo project.")

    text = text.replace(match.group(0), "")
    # 本地引用挂在 XCLocalSwiftPackageReference section 里（紧跟 BODragScroll 之后）。
    text = text.replace(
        "/* End XCLocalSwiftPackageReference section */",
        LOCAL_REF + "/* End XCLocalSwiftPackageReference section */",
        1,
    )
    text = text.replace(
        "%s /* XCRemoteSwiftPackageReference \"BOUIKit\" */," % OBJECT_ID,
        "%s /* XCLocalSwiftPackageReference \"../../../BOUIKit\" */," % OBJECT_ID,
        1,
    )
    # 本地包的 product dependency 不带 package 字段（与 BODragScroll 一致）。
    return text.replace(PACKAGE_LINE, "", 1)


def to_released(text, version):
    if REMOTE_REF_PATTERN.search(text):
        print("Demo project already uses the released BOUIKit package.")
        return None

    match = LOCAL_REF_PATTERN.search(text)
    if match is None:
        raise SystemExit("Could not find the local BOUIKit package reference in the demo project.")

    text = text.replace(match.group(0), "")
    text = text.replace(
        "/* End XCRemoteSwiftPackageReference section */",
        remote_ref(version) + "/* End XCRemoteSwiftPackageReference section */",
        1,
    )
    text = text.replace(
        "%s /* XCLocalSwiftPackageReference \"../../../BOUIKit\" */," % OBJECT_ID,
        "%s /* XCRemoteSwiftPackageReference \"BOUIKit\" */," % OBJECT_ID,
        1,
    )
    return text.replace(
        "\t\t%s /* BOUIKit */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n" % "A1B2C3D4E5F6A7B800000086",
        "\t\t%s /* BOUIKit */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;\n%s"
        % ("A1B2C3D4E5F6A7B800000086", PACKAGE_LINE),
        1,
    )


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    text = PROJECT.read_text(encoding="utf-8")

    if mode == "local":
        updated = to_local(text)
        message = "Demo project now builds BOUIKit from ../../../BOUIKit (do not commit)."
    elif mode == "released":
        if len(sys.argv) < 3:
            raise SystemExit("released mode needs a version argument.")
        updated = to_released(text, sys.argv[2])
        message = "Demo project restored to released BOUIKit %s." % sys.argv[2]
    else:
        raise SystemExit(__doc__)

    if updated is None:
        return
    PROJECT.write_text(updated, encoding="utf-8")
    print(message)


if __name__ == "__main__":
    main()
