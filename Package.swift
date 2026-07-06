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
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.8.0"),
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
