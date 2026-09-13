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

/// Finding the document an `Author, Year` citation names.
///
/// A citation with no target is resolved by its text alone, and every
/// reference whose malformed target was removed now arrives here. Each report
/// view carried its own lookup, which matched a surname as a substring and took
/// the first hit: `[Li, 2016]` opened a paper by Williams, and a tap on
/// `[Smith & Jones, 2016]` searched for an author called "smith & jones" and
/// opened nothing. Opening the wrong paper is worse than opening none, so a
/// citation that fits more than one document opens neither.
final class ReportCitationTests: XCTestCase {

    // MARK: - Capturing what the lookup reports

    /// Records the library's diagnostics so a test can assert on them.
    ///
    /// `@unchecked Sendable` with a lock because `BioMedLitLogger` requires
    /// `Sendable` and this is mutable; the lock is what makes that claim true.
    private final class RecordingLogger: BioMedLitLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        private func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append(message)
        }

        func debug(_ message: String, category: BioMedLitLogCategory) { record(message) }
        func info(_ message: String, category: BioMedLitLogCategory) { record(message) }
        func warning(_ message: String, category: BioMedLitLogCategory) { record(message) }
        func error(_ message: String, category: BioMedLitLogCategory) { record(message) }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
    }

    private let logger = RecordingLogger()

    override func setUp() {
        super.setUp()
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: logger
        ))
    }

    /// Restore the configuration the rest of the package's tests expect.
    override func tearDown() {
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: nil
        ))
        super.tearDown()
    }

    /// A document as the lookup sees it.
    private struct Candidate: Equatable {
        let authors: [String]
        let year: Int?
    }

    /// Whether `text` parses as a citation naming a document with these fields.
    private func citation(_ text: String, matches authors: [String], year: Int?) -> Bool {
        ReportCitation(citationText: text)?.matches(authors: authors, year: year) ?? false
    }

    // MARK: - Matching

    /// A citation matches a paper by its author in either stored name order.
    func testACitationMatchesItsAuthorsPaper() {
        XCTAssertTrue(citation("Smith, 2016", matches: ["Smith J"], year: 2016))
        XCTAssertTrue(citation("Smith, 2016", matches: ["Doe A", "Smith, John"], year: 2016))
        XCTAssertFalse(citation("Smith, 2016", matches: ["Smith J"], year: 2017))
        XCTAssertFalse(citation("Smith, 2016", matches: ["Smith J"], year: nil))
    }

    /// `et al.` and a year's disambiguating letter are not part of the match.
    func testEtAlAndAYearSuffixAreNotPartOfTheMatch() {
        XCTAssertTrue(citation("Smith et al., 2016a", matches: ["Smith J", "Doe A"], year: 2016))
    }

    /// A surname matches only as a whole word.
    ///
    /// Matched as a substring, `Li` found Williams and Oliveira.
    func testASurnameMatchesOnlyAsAWholeWord() {
        XCTAssertFalse(citation("Li, 2016", matches: ["Williams J"], year: 2016))
        XCTAssertFalse(citation("Li, 2016", matches: ["Oliveira P"], year: 2016))
        XCTAssertTrue(citation("Li, 2016", matches: ["Li Y"], year: 2016))
    }

    /// A citation naming two authors needs both.
    func testACitationNamingTwoAuthorsNeedsBoth() {
        XCTAssertTrue(citation("Smith & Jones, 2016", matches: ["Smith J", "Jones K"], year: 2016))
        XCTAssertTrue(citation("Smith and Jones, 2016", matches: ["Jones K", "Smith J"], year: 2016))
        XCTAssertFalse(citation("Smith & Jones, 2016", matches: ["Smith J"], year: 2016))
    }

    /// A surname of several words matches as that sequence of words.
    func testASurnameOfSeveralWordsMatchesAsASequence() {
        XCTAssertTrue(citation("van der Berg, 2018", matches: ["van der Berg H"], year: 2018))
        XCTAssertFalse(citation("van der Berg, 2018", matches: ["Berg H"], year: 2018))
    }

    /// Case and diacritics do not decide a match.
    func testCaseAndDiacriticsDoNotDecideAMatch() {
        XCTAssertTrue(citation("MÜLLER, 2020", matches: ["Muller K"], year: 2020))
    }

    /// A line break inside a citation is whitespace, as in the paragraph it
    /// was wrapped in.
    ///
    /// Trimmed of spaces alone, the year read `"\n2016"`, which is no number.
    func testALineBreakInsideACitationIsWhitespace() {
        XCTAssertTrue(citation("Smith,\n2016", matches: ["Smith J"], year: 2016))
    }

    // MARK: - What is not one citation

    /// A list of citations is not one citation.
    ///
    /// Split at its commas, `Smith, 2016; Jones, 2019` looked up Smith in 2019.
    func testACitationListIsNotOneCitation() {
        XCTAssertNil(ReportCitation(citationText: "Smith, 2016; Jones, 2019"))
    }

    /// Text without a trailing year, or without an author, is not a citation.
    func testTextWithoutAnAuthorAndYearIsNotACitation() {
        XCTAssertNil(ReportCitation(citationText: "the WHO guideline"))
        XCTAssertNil(ReportCitation(citationText: "Smith"))
        XCTAssertNil(ReportCitation(citationText: ", 2016"))
    }

    // MARK: - Choosing a document

    /// The one document a citation fits is chosen.
    func testTheOneMatchingDocumentIsChosen() {
        let smith = Candidate(authors: ["Smith J"], year: 2016)
        let candidates = [Candidate(authors: ["Williams J"], year: 2016), smith]

        let chosen = ReportCitation.uniqueMatch(
            forCitationText: "Smith, 2016", among: candidates, authors: \.authors, year: \.year
        )

        XCTAssertEqual(chosen, smith)
        XCTAssertEqual(logger.recorded, [])
    }

    /// A citation fitting several documents chooses none, and says so.
    ///
    /// `.first` opened whichever the session happened to list first.
    func testACitationFittingSeveralDocumentsChoosesNone() {
        let candidates = [
            Candidate(authors: ["Smith J"], year: 2016),
            Candidate(authors: ["Smith A", "Doe B"], year: 2016),
        ]

        let chosen = ReportCitation.uniqueMatch(
            forCitationText: "Smith et al., 2016a", among: candidates, authors: \.authors, year: \.year
        )

        XCTAssertNil(chosen)
        XCTAssertEqual(logger.recorded.count, 1, "\(logger.recorded)")
        XCTAssertTrue(logger.recorded.joined().contains("Smith et al., 2016a"), "\(logger.recorded)")
    }

    /// A citation fitting no document, or not a citation at all, chooses none
    /// and says so.
    func testACitationFittingNothingChoosesNone() {
        let candidates = [Candidate(authors: ["Williams J"], year: 2016)]

        XCTAssertNil(ReportCitation.uniqueMatch(
            forCitationText: "Li, 2016", among: candidates, authors: \.authors, year: \.year
        ))
        XCTAssertNil(ReportCitation.uniqueMatch(
            forCitationText: "Smith, 2016; Jones, 2019", among: candidates, authors: \.authors, year: \.year
        ))
        XCTAssertEqual(logger.recorded.count, 2, "\(logger.recorded)")
    }
}
