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
            from: "1.0.1"
        )
    ],
    targets: [
        .target(
            name: "AppAgent",
            dependencies: [
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
