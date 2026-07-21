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
            revision: "b98fb14e0cfd8524bced7be8484fc75031d62f74"
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
