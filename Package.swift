// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GBear",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GBearKit", targets: ["GBearKit"])
    ],
    targets: [
        .target(
            name: "PlayniteHID",
            path: "Sources/PlayniteHID",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "GBearKit",
            dependencies: ["PlayniteHID"],
            path: "Sources/GBearKit",
            resources: [
                .copy("Resources/BuiltinEmulatorCatalog.json")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        )
    ]
)
