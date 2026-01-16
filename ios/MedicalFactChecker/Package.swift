// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
