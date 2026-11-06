// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "om",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OmVault", targets: ["OmVault"]),
        .library(name: "OmCrypto", targets: ["OmCrypto"]),
        .library(name: "OmShell", targets: ["OmShell"]),
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
        .target(
            name: "OmCrashSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OmRenderSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .target(name: "OmVault"),
        .target(name: "OmCrypto", dependencies: ["OmVault"]),
        .target(name: "OmShell", dependencies: ["OmVault", "OmCrypto", "OmCrashSupport"]),
        .executableTarget(name: "om", dependencies: ["OmVault", "OmShell"]),
        .executableTarget(
            name: "OmEditor",
            dependencies: [
                "OmVault",
                "OmCrypto",
                "OmShell",
                "OmRenderSupport",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            ]
        ),
        .testTarget(
            name: "OmVaultTests",
            dependencies: ["OmVault"],
            exclude: ["Resources"]
        ),
        .testTarget(name: "OmCryptoTests", dependencies: ["OmCrypto"]),
        .testTarget(name: "OmEditorTests", dependencies: ["OmEditor"]),
        .testTarget(name: "OmShellTests", dependencies: ["OmShell"]),
    ]
)
