// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "git-pont",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "GitPontCore", targets: ["GitPontCore"]),
        .library(name: "GitPontGitHub", targets: ["GitPontGitHub"]),
        .library(name: "GitPontGitLab", targets: ["GitPontGitLab"]),
        .library(name: "GitPontForge", targets: ["GitPontForge"]),
        .library(name: "GitPontBitbucket", targets: ["GitPontBitbucket"]),
        .library(name: "GitPontKeychain", targets: ["GitPontKeychain"]),
        .library(name: "GitPontGitCLI", targets: ["GitPontGitCLI"])
    ],
    targets: [
        .target(name: "GitPontCore"),
        .target(name: "GitPontGitHub", dependencies: ["GitPontCore"]),
        .target(name: "GitPontGitLab", dependencies: ["GitPontCore"]),
        .target(name: "GitPontForge", dependencies: ["GitPontCore"]),
        .target(name: "GitPontBitbucket", dependencies: ["GitPontCore"]),
        .target(name: "GitPontKeychain", dependencies: ["GitPontCore"]),
        .target(name: "GitPontGitCLI", dependencies: ["GitPontCore"]),
        .testTarget(name: "GitPontCoreTests", dependencies: ["GitPontCore"]),
        .testTarget(name: "GitPontGitHubTests", dependencies: ["GitPontGitHub", "GitPontCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontGitLabTests", dependencies: ["GitPontGitLab", "GitPontCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontForgeTests", dependencies: ["GitPontForge", "GitPontCore"], resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontBitbucketTests", dependencies: ["GitPontBitbucket", "GitPontCore"]),
        .testTarget(name: "GitPontKeychainTests", dependencies: ["GitPontKeychain", "GitPontCore"]),
        .testTarget(name: "GitPontGitCLITests", dependencies: ["GitPontGitCLI", "GitPontCore"]),
        .testTarget(name: "GitPontLiveIntegrationTests", dependencies: ["GitPontGitHub", "GitPontGitLab", "GitPontForge", "GitPontBitbucket", "GitPontCore"])
    ]
)
