// swift-tools-version: 5.9

// Compiles the app's source files (copied in by ci/prepare_tests.py) as a library,
// so their real iOS behavior can be tested on the simulator.
import PackageDescription

let package = Package(
    name: "GoldieVerification",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .library(name: "GoldieCore", targets: ["GoldieCore"])
    ],
    targets: [
        .target(name: "GoldieCore", path: "Sources/GoldieCore"),
        .testTarget(name: "GoldieCoreTests", dependencies: ["GoldieCore"], path: "Tests/GoldieCoreTests"),
    ]
)
