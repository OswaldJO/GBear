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
            name: "GBearHID",
            path: "Sources/GBearHID",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "GBearKit",
            dependencies: ["GBearHID"],
            path: "Sources/GBearKit",
            resources: [
                .copy("Resources/BuiltinEmulatorCatalog.json")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("GameController"),
                .linkedFramework("VideoToolbox"),
            ]
        )
    ]
)
