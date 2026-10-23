// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacJanitor",
    platforms: [.macOS(.v13)],
    targets: [
        // Cleanup rules, the run report, and the paths both front-ends share.
        .target(name: "JanitorCore", path: "Sources/JanitorCore"),
        // The CLI launchd runs periodically.
        .executableTarget(
            name: "janitor",
            dependencies: ["JanitorCore"],
            path: "Sources/janitor"
        ),
        // The menu-bar applet: shows the last run and triggers the launchd job.
        .executableTarget(
            name: "MacJanitor",
            dependencies: ["JanitorCore"],
            path: "Sources/MacJanitor"
        ),
        .testTarget(
            name: "JanitorCoreTests",
            dependencies: ["JanitorCore"],
            path: "Tests/JanitorCoreTests"
        ),
    ]
)
