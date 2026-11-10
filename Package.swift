// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "morphtext-swift",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MorphText", targets: ["MorphText"]),
    ],
    targets: [
        .target(name: "MorphText"),
        .executableTarget(
            name: "MorphTextDemo",
            dependencies: ["MorphText"],
            path: "Demo"
        ),
        .testTarget(
            name: "MorphTextTests",
            dependencies: ["MorphText"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
