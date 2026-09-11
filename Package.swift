// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExpressionChoreography",
    platforms: [.macOS(.v13)],
    products: [
        // The portable core. Foundation only: no AppKit, Core Image, Metal,
        // screen reads, network, speech or model services.
        .library(name: "ExpressionChoreography", targets: ["ExpressionChoreography"]),
        // The drop-in adapter that maps core output onto MotionFrame / ExpressionPose.
        .library(name: "ChoreographyHostKit", targets: ["ChoreographyHostKit"]),
        // Head-less frame dump used to check behaviour without a renderer.
        .executable(name: "choreo-demo", targets: ["ChoreographyDemo"]),
    ],
    targets: [
        .target(
            name: "ExpressionChoreography",
            path: "Sources/ExpressionChoreography"
        ),
        .target(
            name: "ChoreographyHostKit",
            dependencies: ["ExpressionChoreography"],
            path: "integrations/ChoreographyHostKit",
            // CHOREOGRAPHY_HOST_SHIM compiles the verbatim excerpt of the app's
            // own Motion.swift types so the adapter can be type-checked and
            // tested here. The flag is never set inside the real app, where the
            // genuine declarations already exist.
            swiftSettings: [.define("CHOREOGRAPHY_HOST_SHIM")]
        ),
        .executableTarget(
            name: "ChoreographyDemo",
            dependencies: ["ChoreographyHostKit"],
            path: "examples/ChoreographyDemo"
        ),
        .testTarget(
            name: "ExpressionChoreographyTests",
            dependencies: ["ExpressionChoreography"],
            path: "Tests/ExpressionChoreographyTests"
        ),
        .testTarget(
            name: "ChoreographyHostKitTests",
            dependencies: ["ChoreographyHostKit"],
            path: "Tests/ChoreographyHostKitTests"
        ),
    ]
)
