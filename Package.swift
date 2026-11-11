// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "morpheum",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Morpheum", targets: ["Morpheum"]),
    ],
    targets: [
        .target(name: "Morpheum"),
        .executableTarget(
            name: "MorpheumDemo",
            dependencies: ["Morpheum"],
            path: "Demo"
        ),
        .testTarget(
            name: "MorpheumTests",
            dependencies: ["Morpheum"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
