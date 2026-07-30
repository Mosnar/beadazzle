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
            revision: "049233f2007842d118ea95474b065ce2af66be29"
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
            path: "Sources/Beadazzle",
            resources: [
                .copy("Resources/LICENSE"),
                .copy("Resources/THIRD_PARTY_NOTICES.md"),
            ]
        ),
        .testTarget(
            name: "BeadazzleTests",
            dependencies: ["Beadazzle"]
        )
    ]
)
