// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CannonballCopilot",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CannonballCore", targets: ["CannonballCore"]),
        .library(name: "CannonballApp", targets: ["CannonballApp"]),
    ],
    targets: [
        // Pure logic: models, telemetry clients, fusion, physics, decision engine.
        // No UI imports so it runs in unit tests and macOS bench harnesses.
        .target(name: "CannonballCore"),
        // SwiftUI surfaces; thin layer over CannonballCore view-models.
        .target(name: "CannonballApp", dependencies: ["CannonballCore"]),
        .testTarget(name: "CannonballCoreTests", dependencies: ["CannonballCore"]),
    ]
)
