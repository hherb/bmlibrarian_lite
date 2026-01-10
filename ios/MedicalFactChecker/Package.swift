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
        .library(
            name: "MedicalFactChecker",
            targets: ["MedicalFactChecker"]
        ),
    ],
    dependencies: [
        // No external dependencies - using only Apple frameworks
    ],
    targets: [
        .target(
            name: "MedicalFactChecker",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "MedicalFactCheckerTests",
            dependencies: ["MedicalFactChecker"],
            path: "Tests"
        ),
    ]
)
