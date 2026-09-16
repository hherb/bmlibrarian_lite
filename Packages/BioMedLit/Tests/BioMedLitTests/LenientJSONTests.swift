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


import Foundation
import XCTest
@testable import BioMedLit

/// Reading JSON a source sends that a strict parser refuses (#255).
final class LenientJSONTests: XCTestCase {
    /// Decode a document and return it as an object.
    private func object(_ text: String) -> [String: Any]? {
        LenientJSON.value(from: Data(text.utf8)) as? [String: Any]
    }

    /// Ordinary JSON is read as it always was.
    func testOrdinaryJSONIsRead() {
        XCTAssertEqual(object(#"{"count":"3"}"#)?["count"] as? String, "3")
        XCTAssertNil(object("not json"))
        XCTAssertNil(object(""))
    }

    /// A raw newline inside a string is read rather than refused.
    func testARawNewlineInsideAStringIsRead() {
        let answer = "{\"ERROR\":\"Search Backend failed:\nretstart too large\"}"

        XCTAssertNil(
            try? JSONSerialization.jsonObject(with: Data(answer.utf8)),
            "the strict parser refuses it, which is why this exists"
        )
        XCTAssertEqual(object(answer)?["ERROR"] as? String, "Search Backend failed:\nretstart too large")
    }

    /// Every control character inside a string is escaped, and nothing else is.
    func testOnlyControlCharactersInsideStringsAreEscaped() {
        let answer = "{\n  \"a\": \"tab\there\",\n  \"b\": [1, 2]\n}"

        let escaped = String(
            data: LenientJSON.escapingControlCharacters(in: Data(answer.utf8)), encoding: .utf8
        )

        XCTAssertEqual(escaped, "{\n  \"a\": \"tab\\u0009here\",\n  \"b\": [1, 2]\n}")
    }

    /// An escaped quote does not end the string it is in.
    func testAnEscapedQuoteDoesNotEndTheString() {
        let answer = "{\"a\":\"say \\\"hi\\\"\nnow\"}"

        XCTAssertEqual(object(answer)?["a"] as? String, "say \"hi\"\nnow")
    }

    /// A multi-byte character survives unchanged.
    func testAMultiByteCharacterSurvives() {
        XCTAssertEqual(object("{\"a\":\"Müller – π\nx\"}")?["a"] as? String, "Müller – π\nx")
    }
}
