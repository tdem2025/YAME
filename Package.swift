// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YAME",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "YAME", targets: ["YAME"]),
        .library(name: "YAMECore", targets: ["YAMECore"]),
    ],
    targets: [
        // Pure-Swift ID3 engine: no dependencies, also builds on Linux.
        .target(name: "YAMECore"),
        // The SwiftUI app.
        .executableTarget(name: "YAME", dependencies: ["YAMECore"]),
        .testTarget(name: "YAMECoreTests", dependencies: ["YAMECore"]),
    ],
    swiftLanguageModes: [.v5]
)
