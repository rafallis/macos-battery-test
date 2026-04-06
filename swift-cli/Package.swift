// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "battery-spoof",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "battery-spoof",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/battery-spoof",
            resources: [
                // The compiled Rust dylib must be placed here before `swift build`.
                // See build.sh for the automated copy step.
                .copy("Resources/libcyclecount.dylib"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
