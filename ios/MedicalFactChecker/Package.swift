// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MedicalFactChecker",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Main library containing all shared code
        .library(
            name: "MedicalFactChecker",
            targets: ["MedicalFactChecker"]
        ),
        // Shared library for cross-platform code (models, services, utilities)
        .library(
            name: "MedicalFactCheckerShared",
            targets: ["MedicalFactCheckerShared"]
        ),
    ],
    dependencies: [
        // No external dependencies - using only Apple frameworks
    ],
    targets: [
        // Full library target (for Xcode project compatibility)
        .target(
            name: "MedicalFactChecker",
            dependencies: [],
            path: "Sources",
            exclude: [
                "macOS",
            ]
        ),
        // Shared code target for cross-platform use
        // Contains models, services, and utilities that work on both iOS and macOS
        .target(
            name: "MedicalFactCheckerShared",
            dependencies: [],
            path: "Sources",
            exclude: [
                "App",
                "Views",
                "macOS",
                "Preview Content",
                "Assets.xcassets",
                "Info.plist",
            ],
            sources: [
                "Models",
                "Services",
                "Utilities",
            ]
        ),
        // Test target
        .testTarget(
            name: "MedicalFactCheckerTests",
            dependencies: ["MedicalFactChecker"],
            path: "Tests"
        ),
    ]
)
