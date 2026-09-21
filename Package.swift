// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "om",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OmVault", targets: ["OmVault"]),
        .executable(name: "om", targets: ["om"]),
    ],
    targets: [
        .target(name: "OmVault"),
        .executableTarget(name: "om", dependencies: ["OmVault"]),
        .testTarget(
            name: "OmVaultTests",
            dependencies: ["OmVault"],
            exclude: ["Resources"]
        ),
    ]
)
