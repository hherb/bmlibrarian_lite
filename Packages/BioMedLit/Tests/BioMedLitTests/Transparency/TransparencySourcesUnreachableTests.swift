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

/// A source the analysis could not read makes its result provisional (#385).
///
/// A CrossRef outage reads exactly like a study with no funders, and the
/// result was stamped with the current analyzer version and kept as final:
/// a transient outage became a permanent "industry funding: not detected"
/// that nothing re-analysed. Python has recorded this as
/// `sources_unreachable` since #346; these pin the Swift port, driven through
/// the real service over a stubbed session. Each failure has a control in
/// which the source *answered* — a 404 is the source's answer about the
/// study, and calling it an outage would re-analyse honest results forever.
final class TransparencySourcesUnreachableTests: XCTestCase {

    /// A status no service retries, so a failure costs no backoff time.
    private static let refused = 403

    /// A trial title carrying its NCT ID, which is where the service looks.
    private static let trialTitle = "A randomized trial NCT01234567 of drug X"

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeService() -> TransparencyAnalysisService {
        TransparencyAnalysisService(email: "test@example.com", session: stubbedSession())
    }

    /// A CrossRef work answer with the given title and no funders.
    private static func crossRefWork(title: String) -> Data {
        Data(#"{"status":"ok","message":{"title":["\#(title)"]}}"#.utf8)
    }

    /// A ClinicalTrials.gov v2 record ``ClinicalTrialsService/extractTrialInfo(from:)`` reads.
    private static let registryStudy = Data(#"""
    {"protocolSection":{"identificationModule":{"nctId":"NCT01234567"},
     "sponsorCollaboratorsModule":{"leadSponsor":{"name":"University X","class":"OTHER"}}},
     "hasResults":true}
    """#.utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - CrossRef

    func testAnUnreachableCrossRefMakesTheResultProvisional() async throws {
        StubURLProtocol.stubbed = (Self.refused, Data())

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, true)
        XCTAssertTrue(result.isProvisional)
        XCTAssertTrue(result.needsReanalysis, "an outage kept as final is never revisited")
        XCTAssertTrue(result.warnings.contains(TransparencyConstants.crossRefUnreachableWarning))
    }

    func testACrossRefWithNoSuchWorkIsAnAnswer() async throws {
        StubURLProtocol.stubbed = (404, Data())

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, false)
        XCTAssertFalse(result.needsReanalysis)
    }

    func testAServedCrossRefIsFinal() async throws {
        StubURLProtocol.routes = ["api.crossref.org": (200, Self.crossRefWork(title: "A cohort study"))]
        StubURLProtocol.stubbed = (404, Data())

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, false)
        XCTAssertTrue(result.dataSourcesUsed.contains(TransparencyConstants.crossRefSourceName))
    }

    // MARK: - PubMed

    func testAnUnreachablePubMedMakesTheResultProvisional() async throws {
        StubURLProtocol.stubbed = (Self.refused, Data())

        let result = try await makeService().analyze(pmid: "12345678")

        XCTAssertEqual(result.sourcesUnreachable, true)
        XCTAssertTrue(result.warnings.contains(TransparencyConstants.pubMedUnreachableWarning))
    }

    // MARK: - ClinicalTrials.gov

    func testAnUnreachableRegistryMakesTheResultProvisional() async throws {
        StubURLProtocol.routes = [
            "api.crossref.org": (200, Self.crossRefWork(title: Self.trialTitle)),
            "clinicaltrials.gov": (Self.refused, Data()),
        ]

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, true)
        XCTAssertFalse(result.riskIndicators.contains(RiskIndicatorStrings.missingTrialRegistration))
    }

    func testAnUnreadableRegistryRecordMakesTheResultProvisional() async throws {
        StubURLProtocol.routes = [
            "api.crossref.org": (200, Self.crossRefWork(title: Self.trialTitle)),
            "clinicaltrials.gov": (200, Data("{}".utf8)),
        ]

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, true, "unparsed is not absent")
    }

    func testARegistryWithNoSuchTrialIsAnAnswer() async throws {
        StubURLProtocol.routes = [
            "api.crossref.org": (200, Self.crossRefWork(title: Self.trialTitle)),
            "clinicaltrials.gov": (404, Data()),
        ]

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, false)
        XCTAssertTrue(result.riskIndicators.contains(RiskIndicatorStrings.missingTrialRegistration))
    }

    func testAServedRegistrationIsFinal() async throws {
        StubURLProtocol.routes = [
            "api.crossref.org": (200, Self.crossRefWork(title: Self.trialTitle)),
            "clinicaltrials.gov": (200, Self.registryStudy),
        ]

        let result = try await makeService().analyze(doi: "10.1000/x")

        XCTAssertEqual(result.sourcesUnreachable, false)
        XCTAssertEqual(result.trialRegistrations.count, 1)
    }

    // MARK: - The result's own rules

    /// Stored JSON from before the flag existed still decodes, as not provisional.
    func testAResultStoredWithoutTheFlagDecodes() throws {
        let stored = TransparencyResult(pmid: "1")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        )
        object.removeValue(forKey: "sourcesUnreachable")

        let decoded = try JSONDecoder().decode(
            TransparencyResult.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.sourcesUnreachable)
        XCTAssertFalse(decoded.isProvisional)
    }

    func testTheFlagSurvivesARoundTrip() throws {
        let stored = TransparencyResult(pmid: "1", sourcesUnreachable: true)

        let decoded = try JSONDecoder().decode(
            TransparencyResult.self,
            from: JSONEncoder().encode(stored)
        )

        XCTAssertEqual(decoded.sourcesUnreachable, true)
    }

    /// A newer build's result arrives by CloudKit sync; re-analysing it here
    /// would overwrite it with an older analyzer's answer (Python's #374 rule).
    func testANewerBuildsProvisionalResultIsNotReanalysed() {
        let newer = TransparencyResult(
            pmid: "1",
            analyzerVersion: TransparencyConstants.analyzerVersion + 1,
            sourcesUnreachable: true
        )

        XCTAssertTrue(newer.isProvisional)
        XCTAssertFalse(newer.needsReanalysis)
    }

    func testAnOlderBuildsResultIsReanalysedWhateverItsSources() {
        let older = TransparencyResult(
            pmid: "1",
            analyzerVersion: TransparencyConstants.analyzerVersion - 1,
            sourcesUnreachable: false
        )

        XCTAssertTrue(older.needsReanalysis)
    }

    // MARK: - The reader is told

    func testAProvisionalResultCarriesTheCaveat() {
        let result = TransparencyResult(
            pmid: "1",
            transparencyScore: 20,
            riskLevel: .high,
            fullTextSearched: true,
            sourcesUnreachable: true
        )

        let explanation = TransparencyRiskExplanation(result: result)

        XCTAssertTrue(explanation.caveats.contains(TransparencyConstants.provisionalResultCaveat))
    }

    func testAFinalResultDoesNotCarryIt() {
        let result = TransparencyResult(
            pmid: "1",
            transparencyScore: 20,
            riskLevel: .high,
            fullTextSearched: true,
            sourcesUnreachable: false
        )

        let explanation = TransparencyRiskExplanation(result: result)

        XCTAssertFalse(explanation.caveats.contains(TransparencyConstants.provisionalResultCaveat))
    }
}
