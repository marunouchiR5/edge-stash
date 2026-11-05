// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeStash",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (geometry + hide/reveal policy), unit-tested.
        .target(name: "EdgeStashCore"),
        // The menu bar app: Accessibility window control, mouse tracking, UI.
        .executableTarget(
            name: "EdgeStash",
            dependencies: ["EdgeStashCore"],
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(name: "EdgeStashCoreTests", dependencies: ["EdgeStashCore"]),
    ]
)
