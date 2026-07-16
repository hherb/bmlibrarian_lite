// swift-tools-version: 5.9
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
    ],
    dependencies: [
        // BioMedLit shared library for JATS parsing and literature services
        .package(path: "../../Packages/BioMedLit"),
    ],
    targets: [
        // Full library target (for Xcode project compatibility)
        .target(
            name: "MedicalFactChecker",
            dependencies: [
                .product(name: "BioMedLit", package: "BioMedLit"),
            ],
            path: "Sources",
            exclude: [
                "macOS",
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
