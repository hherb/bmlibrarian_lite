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
            name: "BioMedLit",
            targets: ["BioMedLit"]
        ),
    ],
    dependencies: [],
    targets: [
        // SPIKE (WP-2, doc/cross_platform/bmlib_sync/uniffi_spike.md): bmlib's
        // Rust crate through UniFFI. `BmlibFFI` is the committed xcframework of
        // dynamic frameworks built by bmlib's
        // `rust/bmlib-ffi/scripts/build-xcframework.sh`, pinned in
        // `Frameworks/BmlibFFI.pin.json`; a path inside this repository, so an
        // Xcode Cloud fresh clone resolves it (HANDOVER, Xcode Cloud contract).
        .binaryTarget(
            name: "BmlibFFI",
            path: "Frameworks/BmlibFFI.xcframework"
        ),
        // The UniFFI-generated Swift over BmlibFFI. Generated, never edited:
        // regenerate it with the xcframework, from the same bmlib commit.
        .target(
            name: "BmlibCore",
            dependencies: ["BmlibFFI"],
            path: "Sources/BmlibCore"
        ),
        .target(
            name: "BioMedLit",
            dependencies: ["BmlibCore"],
            path: "Sources/BioMedLit"
        ),
        .testTarget(
            name: "BioMedLitTests",
            dependencies: ["BioMedLit"],
            path: "Tests/BioMedLitTests",
            // PDF fixtures are read from disk via #filePath (see
            // PDFTextExtractorTests), the same way JATSRealCorpusTests reads the
            // JATS corpus, never from a bundle — so they are excluded here
            // rather than declared as `resources:`.
            exclude: ["Fixtures"]
        ),
    ]
)
