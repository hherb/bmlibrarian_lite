// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// How a model reads a text — without its reference list, in overlapping
/// windows, the answers merged — by the shared rows of
/// `doc/cross_platform/llm_parity/text_windows.json` (Python is canonical).
final class TextWindowsContractTests: XCTestCase {
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/llm_parity/text_windows.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return nil }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private func contract() throws -> [String: Any] {
        let file = try XCTUnwrap(Self.contractFile, "text_windows.json not found")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func rows(_ key: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(contract()[key] as? [[String: Any]], key)
        XCTAssertFalse(rows.isEmpty, key)
        return rows
    }

    func testTheBoundsAreTheContracts() throws {
        let contract = try contract()
        XCTAssertEqual(contract["window_chars"] as? Int, BioMedLitConstants.textWindowChars)
        XCTAssertEqual(contract["overlap_chars"] as? Int, BioMedLitConstants.textWindowOverlapChars)
        XCTAssertEqual(contract["boundary_search_chars"] as? Int, TextWindows.boundarySearchChars)
        XCTAssertEqual(
            contract["boundary_markers"] as? [String],
            TextWindows.boundaryMarkers.map { String(String.UnicodeScalarView($0.marker)) }
        )
    }

    func testEachWindowsCase() throws {
        for row in try rows("windows") {
            let name = row["name"] as? String ?? ""
            let text = try XCTUnwrap(row["text"] as? String, name)
            let windowChars = try XCTUnwrap(row["window_chars"] as? Int, name)
            let overlapChars = try XCTUnwrap(row["overlap_chars"] as? Int, name)
            let expected = try XCTUnwrap(row["windows"] as? [String], name)
            let windows = TextWindows.analysisWindows(text, windowChars: windowChars, overlapChars: overlapChars)
            // Compared as code points: String == would equate canonical equivalents
            XCTAssertEqual(windows.map { Array($0.unicodeScalars) }, expected.map { Array($0.unicodeScalars) }, name)
        }
    }

    func testEachReferencesCase() throws {
        for row in try rows("references") {
            let name = row["name"] as? String ?? ""
            let text = try XCTUnwrap(row["text"] as? String, name)
            let expected = try XCTUnwrap(row["without_references"] as? String, name)
            XCTAssertEqual(
                Array(TextWindows.withoutReferences(text).unicodeScalars), Array(expected.unicodeScalars), name
            )
        }
    }

    func testEachMergeCase() throws {
        for row in try rows("merge") {
            let name = row["name"] as? String ?? ""
            let passages = try XCTUnwrap(row["passages"] as? [String], name)
            let kept = try XCTUnwrap(row["kept"] as? [String], name)
            XCTAssertEqual(TextWindows.mergedWindowItems(passages) { $0 }, kept, name)
        }
    }

    /// Python strips U+200B from nothing; Foundation's whitespace set would.
    func testAZeroWidthSpaceIsText() {
        XCTAssertEqual(TextWindows.analysisWindows(" \u{200B}Body. "), ["\u{200B}Body."])
    }
}
