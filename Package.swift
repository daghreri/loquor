// swift-tools-version: 6.2
// The Loquor menu-bar app. Build the .app with scripts/build-app.sh;
// check the logic with `swift run selftest`.
import PackageDescription

let package = Package(
    name: "Loquor",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT v2 on CoreML (chosen in milestone 1). No traits: ASR only.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        // Logic with no UI or system dependencies, so it can be checked without a keyboard.
        .target(name: "LoquorCore", path: "Sources/LoquorCore"),
        .executableTarget(
            name: "Loquor",
            dependencies: ["LoquorCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Loquor"),
        .executableTarget(name: "selftest", dependencies: ["LoquorCore"], path: "Sources/selftest"),
    ]
)
