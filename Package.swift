// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeStash",
    platforms: [.macOS(.v14)],
    targets: [
        // Geometry, hide/reveal policy, safe acquisition and preferences, unit-tested.
        .target(name: "EdgeStashCore"),
        // The menu bar app: Accessibility window control, mouse tracking, UI.
        .executableTarget(
            name: "EdgeStash",
            dependencies: ["EdgeStashCore"],
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(name: "EdgeStashCoreTests", dependencies: ["EdgeStashCore"]),
        .testTarget(name: "EdgeStashTests", dependencies: ["EdgeStash"]),
    ]
)
