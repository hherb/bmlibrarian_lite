// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
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

import XCTest
@testable import BioMedLit

/// Structural tests for the industry-matching pattern lists.
///
/// `FunderClassificationTests` measures the classifier against the labelled
/// corpus, which catches any change that *moves* precision or recall. It cannot
/// see a pattern that matches nothing: adding one moves no metric, so a dead
/// entry ships green and quietly stops flagging the funders it was meant to
/// catch. Three ways to write one, none of which the corpus can detect:
///
/// - an invalid regex, which `RegexHelper.regex` turns into `nil` via `try?` and
///   `anyMatch` then skips for good;
/// - a `\b`-anchored pattern placed in the substring list, where it becomes a
///   literal search for the characters `\` and `b`;
/// - an uppercase stem, which can never match because the name is lowercased
///   before the comparison.
final class IndustryPatternStructureTests: XCTestCase {

    // MARK: - Stems are plain lowercase literals

    func testEveryStemIsLowercased() {
        for stem in IndustryPatterns.funderNameStems {
            XCTAssertEqual(
                stem, stem.lowercased(),
                "'\(stem)' can never match: funder names are lowercased before the comparison"
            )
        }
    }

    func testNoStemIsARegexSource() {
        for stem in IndustryPatterns.funderNameStems {
            XCTAssertFalse(
                stem.contains("\\"),
                "'\(stem)' is a regex source in the substring list; it would be matched literally"
            )
        }
    }

    func testNoStemIsEmpty() {
        for stem in IndustryPatterns.funderNameStems {
            XCTAssertFalse(stem.isEmpty, "an empty stem matches every name")
        }
    }

    // MARK: - Whole-word patterns are valid, anchored regexes

    func testEveryFunderNameWordCompiles() {
        for pattern in IndustryPatterns.funderNameWords {
            XCTAssertNotNil(
                RegexHelper.regex(pattern),
                "'\(pattern)' is not a valid regex; try? drops it and it never fires"
            )
        }
    }

    func testEveryIndustryKeywordCompiles() {
        for pattern in IndustryPatterns.industryKeywords {
            XCTAssertNotNil(
                RegexHelper.regex(pattern),
                "'\(pattern)' is not a valid regex; try? drops it and it never fires"
            )
        }
    }

    /// The whole-word list exists to *not* match inside a longer word. An
    /// unanchored entry there is a stem wearing the wrong list's semantics.
    func testEveryFunderNameWordIsWordAnchored() {
        for pattern in IndustryPatterns.funderNameWords {
            XCTAssertTrue(
                pattern.hasPrefix(#"\b"#) && pattern.hasSuffix(#"\b"#),
                "'\(pattern)' is unanchored in the whole-word list; it would match inside longer words"
            )
        }
    }

    // MARK: - The lists stay disjoint in kind

    /// `classifyFunder` reads the two funder lists and not `industryKeywords`,
    /// which holds COI *prose* phrases. A phrase like "advisory board" in a funder
    /// list would fire on an organisation name.
    func testCOIProsePhrasesStayOutOfTheFunderLists() {
        let funderPatterns = Set(IndustryPatterns.funderNameWords)
        for phrase in IndustryPatterns.industryKeywords where phrase.contains(" ") {
            XCTAssertFalse(
                funderPatterns.contains(phrase),
                "'\(phrase)' is a COI prose phrase and does not belong in a funder-name list"
            )
        }
    }
}
