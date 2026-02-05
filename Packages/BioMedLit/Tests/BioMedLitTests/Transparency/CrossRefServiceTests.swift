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

import XCTest
@testable import BioMedLit

/// Unit tests for CrossRefService.
///
/// Tests cover:
/// - Funder extraction from CrossRef work responses
/// - Title, journal, and author extraction
/// - Publication date parsing
/// - Error handling
final class CrossRefServiceTests: XCTestCase {

    // MARK: - Properties

    var service: CrossRefService!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        service = CrossRefService(email: "test@example.com")
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Funder Extraction Tests

    /// Test extractFunders with industry funder data.
    func testExtractFundersIndustry() {
        let funders = service.extractFunders(from: TransparencyTestFixtures.industryFundedWorkJSON)

        XCTAssertEqual(funders.count, 1)
        XCTAssertEqual(funders.first?.name, "Pfizer Inc.")
        XCTAssertEqual(funders.first?.funderDOI, "10.13039/100004319")
        XCTAssertTrue(funders.first?.isIndustry ?? false)
        XCTAssertEqual(funders.first?.confidence, 1.0)
        XCTAssertEqual(funders.first?.awardNumbers, ["GRANT-2024-001"])
    }

    /// Test extractFunders with academic funder data.
    func testExtractFundersAcademic() {
        let funders = service.extractFunders(from: TransparencyTestFixtures.academicFundedWorkJSON)

        XCTAssertEqual(funders.count, 1)
        XCTAssertEqual(funders.first?.name, "National Institutes of Health")
        XCTAssertFalse(funders.first?.isIndustry ?? true)
    }

    /// Test extractFunders with mixed funding sources.
    func testExtractFundersMixed() {
        let funders = service.extractFunders(from: TransparencyTestFixtures.mixedFundedWorkJSON)

        XCTAssertEqual(funders.count, 2)

        let industryFunder = funders.first { $0.isIndustry }
        let nonIndustryFunder = funders.first { !$0.isIndustry }

        XCTAssertNotNil(industryFunder)
        XCTAssertEqual(industryFunder?.name, "Novartis AG")

        XCTAssertNotNil(nonIndustryFunder)
        XCTAssertEqual(nonIndustryFunder?.name, "National Science Foundation")
    }

    /// Test extractFunders returns empty array when no funders.
    func testExtractFundersEmpty() {
        let funders = service.extractFunders(from: TransparencyTestFixtures.workNoFundersJSON)
        XCTAssertTrue(funders.isEmpty)
    }

    /// Test extractFunders with nil input.
    func testExtractFundersNil() {
        let funders = service.extractFunders(from: nil)
        XCTAssertTrue(funders.isEmpty)
    }

    // MARK: - Title Extraction Tests

    /// Test extractTitle returns correct title.
    func testExtractTitle() {
        let title = service.extractTitle(from: TransparencyTestFixtures.industryFundedWorkJSON)
        XCTAssertEqual(title, "A Randomized, Double-Blind, Placebo-Controlled Study")
    }

    /// Test extractTitle returns nil when no title.
    func testExtractTitleMissing() {
        let work: [String: Any] = ["author": []]
        let title = service.extractTitle(from: work)
        XCTAssertNil(title)
    }

    /// Test extractTitle with nil input.
    func testExtractTitleNil() {
        let title = service.extractTitle(from: nil)
        XCTAssertNil(title)
    }

    // MARK: - Journal Extraction Tests

    /// Test extractJournal returns correct journal name.
    func testExtractJournal() {
        let journal = service.extractJournal(from: TransparencyTestFixtures.industryFundedWorkJSON)
        XCTAssertEqual(journal, "New England Journal of Medicine")
    }

    /// Test extractJournal returns nil when no journal.
    func testExtractJournalMissing() {
        let work: [String: Any] = ["title": ["Test"]]
        let journal = service.extractJournal(from: work)
        XCTAssertNil(journal)
    }

    /// Test extractJournal with nil input.
    func testExtractJournalNil() {
        let journal = service.extractJournal(from: nil)
        XCTAssertNil(journal)
    }

    // MARK: - Author Extraction Tests

    /// Test extractAuthors returns formatted author names.
    func testExtractAuthors() {
        let authors = service.extractAuthors(from: TransparencyTestFixtures.industryFundedWorkJSON)

        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(authors[0], "Smith, John")
        XCTAssertEqual(authors[1], "Doe, Jane")
    }

    /// Test extractAuthors handles authors with only family name.
    func testExtractAuthorsFamilyOnly() {
        let work: [String: Any] = [
            "author": [
                ["family": "Smith"],
            ],
        ]

        let authors = service.extractAuthors(from: work)
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0], "Smith")
    }

    /// Test extractAuthors returns empty array when no authors.
    func testExtractAuthorsEmpty() {
        let work: [String: Any] = ["title": ["Test"]]
        let authors = service.extractAuthors(from: work)
        XCTAssertTrue(authors.isEmpty)
    }

    /// Test extractAuthors with nil input.
    func testExtractAuthorsNil() {
        let authors = service.extractAuthors(from: nil)
        XCTAssertTrue(authors.isEmpty)
    }

    // MARK: - Publication Date Tests

    /// Test extractPublicationDate with full date.
    func testExtractPublicationDateFull() {
        let date = service.extractPublicationDate(from: TransparencyTestFixtures.industryFundedWorkJSON)
        XCTAssertNotNil(date)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: date!), 2024)
        XCTAssertEqual(calendar.component(.month, from: date!), 3)
        XCTAssertEqual(calendar.component(.day, from: date!), 15)
    }

    /// Test extractPublicationDate prefers published-print over published-online.
    func testExtractPublicationDatePrefersPrint() {
        let work: [String: Any] = [
            "published-print": ["date-parts": [[2024, 6, 1]]],
            "published-online": ["date-parts": [[2024, 3, 1]]],
        ]

        let date = service.extractPublicationDate(from: work)
        XCTAssertNotNil(date)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.month, from: date!), 6)
    }

    /// Test extractPublicationDate falls back to published-online.
    func testExtractPublicationDateFallbackToOnline() {
        let date = service.extractPublicationDate(from: TransparencyTestFixtures.academicFundedWorkJSON)
        XCTAssertNotNil(date)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: date!), 2024)
        XCTAssertEqual(calendar.component(.month, from: date!), 1)
    }

    /// Test extractPublicationDate returns nil when no date.
    func testExtractPublicationDateMissing() {
        let work: [String: Any] = ["title": ["Test"]]
        let date = service.extractPublicationDate(from: work)
        XCTAssertNil(date)
    }

    /// Test extractPublicationDate with nil input.
    func testExtractPublicationDateNil() {
        let date = service.extractPublicationDate(from: nil)
        XCTAssertNil(date)
    }

    /// Test extractPublicationDate handles year-only date.
    func testExtractPublicationDateYearOnly() {
        let work: [String: Any] = [
            "published-print": ["date-parts": [[2024]]],
        ]

        let date = service.extractPublicationDate(from: work)
        XCTAssertNotNil(date)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: date!), 2024)
        // Should default to January 1
        XCTAssertEqual(calendar.component(.month, from: date!), TransparencyConstants.defaultMonth)
        XCTAssertEqual(calendar.component(.day, from: date!), TransparencyConstants.defaultDay)
    }

    // MARK: - Error Tests

    /// Test CrossRefError descriptions.
    func testCrossRefErrorDescriptions() {
        XCTAssertNotNil(CrossRefError.invalidDOI("test").errorDescription)
        XCTAssertNotNil(CrossRefError.networkError("test").errorDescription)
        XCTAssertNotNil(CrossRefError.httpError(statusCode: 400).errorDescription)
        XCTAssertNotNil(CrossRefError.serverError(statusCode: 500).errorDescription)
        XCTAssertNotNil(CrossRefError.parseError("test").errorDescription)
    }

    /// Test CrossRefError retryable status.
    func testCrossRefErrorRetryable() {
        XCTAssertFalse(CrossRefError.invalidDOI("test").isRetryable)
        XCTAssertTrue(CrossRefError.networkError("test").isRetryable)
        XCTAssertFalse(CrossRefError.httpError(statusCode: 400).isRetryable)
        XCTAssertTrue(CrossRefError.serverError(statusCode: 500).isRetryable)
        XCTAssertFalse(CrossRefError.parseError("test").isRetryable)
    }
}
