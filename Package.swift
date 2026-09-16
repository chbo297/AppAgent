// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppAgent",
    platforms: [
        .iOS(.v13),
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
                )
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
