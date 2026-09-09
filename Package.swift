// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelightKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RelightKit", targets: ["RelightKit"]),
    ],
    targets: [
        .target(
            name: "RelightKit",
            // Shipped as a resource and compiled at launch rather than built
            // ahead of time: SwiftPM has no Metal build rule. In an Xcode
            // target, add the same file to the target's compile sources and
            // RelightRenderer will pick up the precompiled default library.
            resources: [.copy("Resources/Relight.metal")]
        ),
        .testTarget(
            name: "RelightKitTests",
            dependencies: ["RelightKit"]
        ),
    ]
)
