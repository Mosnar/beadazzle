// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Beadazzle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Beadazzle", targets: ["Beadazzle"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Mosnar/swift-markdown-engine",
            revision: "e3e7df28a031e4b93a57e3f6e349f4c85aef2c23"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Beadazzle",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Beadazzle"
        ),
        .testTarget(
            name: "BeadazzleTests",
            dependencies: ["Beadazzle"]
        )
    ]
)
