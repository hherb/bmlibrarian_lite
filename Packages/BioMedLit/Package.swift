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
    name: "BioMedLit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BioMedLitLib",
            targets: ["BioMedLit"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BioMedLit",
            dependencies: [],
            path: "Sources/BioMedLit"
        ),
        .testTarget(
            name: "BioMedLitTests",
            dependencies: ["BioMedLit"],
            path: "Tests/BioMedLitTests"
        ),
    ]
)
