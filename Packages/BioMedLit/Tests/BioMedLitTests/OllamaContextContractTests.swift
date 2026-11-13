// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// The `num_ctx` an Ollama request is sent, by the shared rows of
/// `doc/cross_platform/llm_parity/ollama_context.json` (#760).
final class OllamaContextContractTests: XCTestCase {
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/llm_parity/ollama_context.json"
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
        let file = try XCTUnwrap(Self.contractFile, "ollama_context.json not found")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTheBoundsAreTheContracts() throws {
        let contract = try contract()
        XCTAssertEqual(contract["chars_per_token"] as? Int, BioMedLitConstants.ollamaCharsPerToken)
        XCTAssertEqual(contract["template_tokens"] as? Int, BioMedLitConstants.ollamaTemplateTokens)
        XCTAssertEqual(contract["min_num_ctx"] as? Int, BioMedLitConstants.ollamaMinNumCtx)
        XCTAssertEqual(contract["max_num_ctx"] as? Int, BioMedLitConstants.ollamaMaxNumCtx)
    }

    func testEachCase() throws {
        let rows = try XCTUnwrap(contract()["cases"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty, "an empty table would pass vacuously")
        for row in rows {
            let name = row["name"] as? String ?? ""
            let promptCodePoints = try XCTUnwrap(row["prompt_code_points"] as? Int, name)
            let maxTokens = try XCTUnwrap(row["max_tokens"] as? Int, name)
            let expected = try XCTUnwrap(row["num_ctx"] as? Int, name)
            XCTAssertEqual(OllamaContext.numCtx(promptCodePoints: promptCodePoints, maxTokens: maxTokens), expected, name)
        }
    }

    func testMessagesAreCountedInCodePoints() {
        // "é" as e + combining accent is one Character but two code points
        let decomposed = String(repeating: "e\u{301}", count: 11_904)
        XCTAssertEqual(OllamaContext.numCtx(contents: [decomposed], maxTokens: 0), 8192)
        XCTAssertEqual(OllamaContext.numCtx(contents: [decomposed, "x"], maxTokens: 0), 16384)
        // an emoji outside the BMP is one code point (two UTF-16 units)
        let emoji = String(repeating: "\u{1F600}", count: 23_808)
        XCTAssertEqual(OllamaContext.numCtx(contents: [emoji], maxTokens: 0), 8192)
        XCTAssertEqual(OllamaContext.numCtx(contents: [emoji, "x"], maxTokens: 0), 16384)
    }

    func testTheNativeRootDropsTheOpenAIVersionSegment() {
        XCTAssertEqual(OllamaContext.nativeRoot("http://localhost:11434/v1"), "http://localhost:11434")
        XCTAssertEqual(OllamaContext.nativeRoot("http://mac.local:11434/v1/"), "http://mac.local:11434")
        XCTAssertEqual(OllamaContext.nativeRoot("http://mac.local:11434"), "http://mac.local:11434")
    }
}
