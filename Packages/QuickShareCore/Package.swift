// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShareCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "QuickShareCore", targets: ["QuickShareCore"]),
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
        .testTarget(
            name: "QuickShareCoreTests",
            dependencies: ["QuickShareCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
