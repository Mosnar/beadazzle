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
            revision: "a2dc2ea551cf65d4c72a1062fb20a7ece0c8cca6"
        ),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        .executableTarget(
            name: "Beadazzle",
            dependencies: [
                "CSQLite",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Beadazzle"
        ),
        .testTarget(
            name: "BeadazzleTests",
            dependencies: ["Beadazzle", "CSQLite"]
        )
    ]
)
