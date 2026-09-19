// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppAgent",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AppAgent",
            targets: ["AppAgent"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/chbo297/BODragScroll.git",
            from: "2.0.0"
        ),
        .package(
            url: "https://github.com/chbo297/BOUIKit.git",
            from: "0.1.1"
        )
    ],
    targets: [
        .target(
            name: "AppAgentObjCSupport",
            path: "ObjCSupport"
        ),
        .target(
            name: "AppAgent",
            dependencies: [
                "AppAgentObjCSupport",
                .product(
                    name: "BODragScroll",
                    package: "BODragScroll",
                    condition: .when(platforms: [.iOS, .macCatalyst])
                ),
                // UIKit hit-testing 便利层；在 macOS 上编译为空模块，无需平台条件。
                .product(name: "BOUIKit", package: "BOUIKit")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "AppAgentTests",
            dependencies: ["AppAgent"],
            path: "Tests"
        ),
    ]
)
