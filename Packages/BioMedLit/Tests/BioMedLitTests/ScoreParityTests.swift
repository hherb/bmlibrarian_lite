// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// What an unreadable relevance score is: the shared rows of
/// `doc/cross_platform/llm_parity/score_values.json`. A reply holds a whole
/// number from 1 to 5 or no score, and no score is a parse failure, never a
/// score.
final class ScoreParityTests: XCTestCase {
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/llm_parity/score_values.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return nil }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private func cases() throws -> [[String: Any]] {
        let file = try XCTUnwrap(Self.contractFile, "score_values.json not found")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        let contract = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(contract["cases"] as? [[String: Any]])
    }

    func testEachCase() throws {
        let rows = try cases()
        XCTAssertGreaterThanOrEqual(rows.count, 18)
        for row in rows {
            let name = row["name"] as? String ?? ""
            let reply = try XCTUnwrap(row["reply"] as? String, name)
            let expected = row["score"] as? Int
            let result = ResponseParser.parseScoreResponse(reply)
            XCTAssertEqual(result.score, expected, name)
            XCTAssertEqual(result.parseFailed, expected == nil, name)
        }
    }

    func testAScoreOutsideIntsRangeIsAFailureNotATrap() {
        for literal in ["1e300", "-1e300", "9223372036854775808", "1e19"] {
            let result = ResponseParser.parseScoreResponse("{\"score\": \(literal)}")
            XCTAssertNil(result.score, literal)
            XCTAssertTrue(result.parseFailed, literal)
        }
    }

    func testAScoreIsNeverClamped() {
        XCTAssertNil(ResponseParser.parseScoreResponse("{\"score\": 9}").score)
        XCTAssertNil(ResponseParser.parseScoreResponse("{\"score\": 0}").score)
    }
}
