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
        .library(name: "GitPontKeychain", targets: ["GitPontKeychain"]),
        .library(name: "GitPontGitCLI", targets: ["GitPontGitCLI"])
    ],
    targets: [
        .target(name: "GitPontCore", path: "libs/swift/Sources/GitPontCore"),
        .target(name: "GitPontGitHub", dependencies: ["GitPontCore"], path: "libs/swift/Sources/GitPontGitHub"),
        .target(name: "GitPontGitLab", dependencies: ["GitPontCore"], path: "libs/swift/Sources/GitPontGitLab"),
        .target(name: "GitPontForge", dependencies: ["GitPontCore"], path: "libs/swift/Sources/GitPontForge"),
        .target(name: "GitPontKeychain", dependencies: ["GitPontCore"], path: "libs/swift/Sources/GitPontKeychain"),
        .target(name: "GitPontGitCLI", dependencies: ["GitPontCore"], path: "libs/swift/Sources/GitPontGitCLI"),
        .testTarget(name: "GitPontCoreTests", dependencies: ["GitPontCore"], path: "libs/swift/Tests/GitPontCoreTests"),
        .testTarget(name: "GitPontGitHubTests", dependencies: ["GitPontGitHub", "GitPontCore"], path: "libs/swift/Tests/GitPontGitHubTests", resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontGitLabTests", dependencies: ["GitPontGitLab", "GitPontCore"], path: "libs/swift/Tests/GitPontGitLabTests", resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontForgeTests", dependencies: ["GitPontForge", "GitPontCore"], path: "libs/swift/Tests/GitPontForgeTests", resources: [.process("Fixtures")]),
        .testTarget(name: "GitPontKeychainTests", dependencies: ["GitPontKeychain", "GitPontCore"], path: "libs/swift/Tests/GitPontKeychainTests"),
        .testTarget(name: "GitPontGitCLITests", dependencies: ["GitPontGitCLI", "GitPontCore"], path: "libs/swift/Tests/GitPontGitCLITests"),
        .testTarget(name: "GitPontLiveIntegrationTests", dependencies: ["GitPontGitHub", "GitPontGitLab", "GitPontForge", "GitPontCore"], path: "libs/swift/Tests/GitPontLiveIntegrationTests")
    ]
)
