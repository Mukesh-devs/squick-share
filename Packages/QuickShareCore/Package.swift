// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShareCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QuickShareCore", targets: ["QuickShareCore"]),
        .executable(name: "squick-share-cli", targets: ["SquickShareCLI"]),
    ],
    dependencies: [
        // Must be >= the protoc-gen-swift version used by scripts/generate-protos.sh.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "QuickShareCore",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .executableTarget(
            name: "SquickShareCLI",
            dependencies: ["QuickShareCore"]
        ),
        .testTarget(
            name: "QuickShareCoreTests",
            dependencies: ["QuickShareCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
