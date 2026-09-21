// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "om",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OmVault", targets: ["OmVault"]),
        .executable(name: "om", targets: ["om"]),
        .executable(name: "OmEditor", targets: ["OmEditor"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/nodes-app/swift-markdown-engine",
            exact: "0.13.0"
        ),
    ],
    targets: [
        .target(name: "OmVault"),
        .executableTarget(name: "om", dependencies: ["OmVault"]),
        .executableTarget(
            name: "OmEditor",
            dependencies: [
                "OmVault",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ]
        ),
        .testTarget(
            name: "OmVaultTests",
            dependencies: ["OmVault"],
            exclude: ["Resources"]
        ),
        .testTarget(name: "OmEditorTests", dependencies: ["OmEditor"]),
    ]
)
