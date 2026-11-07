// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PrintProcessor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PrintProcessorCore", targets: ["PrintProcessorCore"]),
        .executable(name: "PrintProcessor", targets: ["PrintProcessor"]),
        .executable(name: "PrintProcessorCheck", targets: ["PrintProcessorCheck"]),
    ],
    targets: [
        .target(
            name: "PrintProcessorCore",
            path: "Sources/PrintProcessorCore"
        ),
        .executableTarget(
            name: "PrintProcessor",
            dependencies: ["PrintProcessorCore"],
            path: "Sources/PrintProcessor"
        ),
        .executableTarget(
            name: "PrintProcessorCheck",
            dependencies: ["PrintProcessorCore"],
            path: "Sources/PrintProcessorCheck"
        ),
    ]
)
