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

import BioMedLit
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// A report discusses every document it flags as high transparency risk.
///
/// The summary said "N document(s) flagged as high transparency risk" and
/// nothing more: a reader was told to distrust studies without being told
/// which, or why.
final class HighRiskTransparencyReportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    /// A document whose stored analysis is built from the given findings.
    private func makeDocument(
        pmid: String,
        surname: String,
        year: Int,
        coiStatement: String?,
        fullTextSearched: Bool,
        configure: (inout TransparencyResultBuilder) -> Void = { _ in }
    ) -> Document {
        let document = Document(
            pmid: pmid,
            title: "Study by \(surname)",
            abstract: "",
            authors: ["\(surname), A", "Other, B"]
        )
        document.year = year
        var builder = TransparencyResultBuilder(pmid: pmid)
        builder.coiAnalysis = COIAnalysisResult(statement: coiStatement)
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .fullOpen)
        builder.dataSourcesUsed = [TransparencyConstants.pubMedSourceName]
        builder.fullTextSearched = fullTextSearched
        configure(&builder)
        document.storeTransparencyResult(builder.build())
        return document
    }

    /// Exactly the documents the summary counts as high risk, in a stable order.
    func testEntriesAreTheHighRiskDocumentsInReferenceOrder() {
        let low = makeDocument(
            pmid: "1", surname: "Adams", year: 2020,
            coiStatement: "None declared.", fullTextSearched: true
        )
        let highLater = makeDocument(
            pmid: "2", surname: "Young", year: 2021,
            coiStatement: nil, fullTextSearched: true
        )
        let highEarlier = makeDocument(
            pmid: "3", surname: "Baker", year: 2019,
            coiStatement: nil, fullTextSearched: false
        )
        let unanalysed = Document(pmid: "4", title: "Not analysed", abstract: "")
        let registryFinding = makeDocument(
            pmid: "5", surname: "Cole", year: 2018,
            coiStatement: "None declared.", fullTextSearched: false
        ) { builder in
            builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
            builder.industryFundingDetected = true
            builder.industryFundingConfidence = 0.9
        }
        XCTAssertNotEqual(low.transparencyRiskLevel, .high)
        XCTAssertEqual(highLater.transparencyRiskLevel, .high)
        XCTAssertEqual(highEarlier.transparencyRiskLevel, .high)
        XCTAssertEqual(registryFinding.transparencyRiskLevel, .high)
        XCTAssertTrue(highEarlier.transparencyIsUnassessed, "its only reason is a statement nobody could look for")
        XCTAssertFalse(registryFinding.transparencyIsUnassessed)

        let entries = Document.highRiskTransparencyEntries(
            in: [highLater, low, unanalysed, highEarlier, registryFinding]
        )

        XCTAssertEqual(entries.map(\.reference), ["Cole et al., 2018", "Young et al., 2021"])
        XCTAssertTrue(entries[1].citation.hasPrefix("Study by Young"))
        XCTAssertEqual(entries[0].explanation.certainty, .limitedNoFullText)
        XCTAssertEqual(entries[1].explanation.certainty, .fullText)
    }

    /// Copied, shared and exported text carries the discussion too.
    func testSharedReportCarriesTheHighRiskDiscussion() throws {
        let container = try ModelContainer(
            for: FactCheckSession.self, Document.self, EvidenceReport.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = FactCheckSession(claim: "A claim")
        let document = makeDocument(
            pmid: "2", surname: "Young", year: 2021,
            coiStatement: nil, fullTextSearched: true
        )
        let report = EvidenceReport(
            verdict: .supported,
            summary: "A summary",
            fullReport: "The body.",
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1,
            searchShortfallsRecord: ReportSearchCompleteness.completeSearchRecord
        )
        context.insert(session)
        context.insert(document)
        context.insert(report)
        session.documents = [document]
        report.session = session

        let shared = report.plainTextReport

        XCTAssertTrue(shared.contains(HighRiskTransparencySection.heading.uppercased()), shared)
        XCTAssertTrue(shared.contains("Young et al., 2021: Study by Young"), shared)
        XCTAssertTrue(shared.contains("No conflict of interest statement was found in the full text"), shared)
        XCTAssertLessThan(
            try XCTUnwrap(shared.range(of: "The body.")).lowerBound,
            try XCTUnwrap(shared.range(of: HighRiskTransparencySection.heading.uppercased())).lowerBound,
            "the discussion follows the report body"
        )
    }

    /// A rating made without the full text says so; one made with it does not.
    func testCertaintyFollowsTheRecordedFullTextAccess() {
        let withText = makeDocument(
            pmid: "1", surname: "Adams", year: 2020, coiStatement: nil, fullTextSearched: true
        )
        let withoutText = makeDocument(
            pmid: "2", surname: "Baker", year: 2020, coiStatement: nil, fullTextSearched: false
        )
        XCTAssertEqual(withText.transparencyCertainty, .fullText)
        XCTAssertEqual(withoutText.transparencyCertainty, .limitedNoFullText)
        XCTAssertEqual(
            withoutText.transparencyCertainty?.note,
            "Limited certainty because of lack of full text access"
        )
    }

    /// A result stored before access was recorded falls back on the document:
    /// with no analysable full text now, there was none to analyse then.
    func testUnrecordedAccessFallsBackOnTheDocumentsFullText() throws {
        let document = makeDocument(
            pmid: "1", surname: "Adams", year: 2020, coiStatement: nil, fullTextSearched: true
        )
        let json = try XCTUnwrap(document.transparencyResultJSON)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        object.removeValue(forKey: "fullTextSearched")
        document.transparencyResultJSON = String(
            data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8
        )
        XCTAssertNil(document.transparencyResult?.fullTextSearched)
        XCTAssertEqual(document.transparencyCertainty, .limitedNoFullText)

        document.fullTextContent = "Body text of the article."
        XCTAssertEqual(document.transparencyCertainty, .unrecorded)
    }

    /// Exported text carries the note with the rating it qualifies.
    func testSharedSectionStatesLimitedCertainty() throws {
        let entries = Document.highRiskTransparencyEntries(in: [
            makeDocument(pmid: "2", surname: "Baker", year: 2019, coiStatement: "None.", fullTextSearched: false) {
                $0.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
                $0.industryFundingDetected = true
            }
        ])
        let text = try XCTUnwrap(HighRiskTransparencySection.plainText(for: entries))
        XCTAssertTrue(text.contains("Limited certainty because of lack of full text access"), text)
    }

    /// A report with no high-risk document carries no empty section.
    func testSharedReportWithoutHighRiskDocumentsHasNoSection() {
        let report = EvidenceReport(
            verdict: .supported,
            summary: "A summary",
            fullReport: "The body.",
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1,
            searchShortfallsRecord: ReportSearchCompleteness.completeSearchRecord
        )
        XCTAssertFalse(report.plainTextReport.contains(HighRiskTransparencySection.heading.uppercased()))
    }
}
