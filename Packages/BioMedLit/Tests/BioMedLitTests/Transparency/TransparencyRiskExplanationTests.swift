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

/// Tests for explaining a high transparency-risk rating to a report's reader.
final class TransparencyRiskExplanationTests: XCTestCase {

    // MARK: - Fixtures

    /// A COI statement with no industry ties.
    private let cleanCOI = COIAnalysisResult(statement: "The authors declare no competing interests.")

    /// A result built the way the analysis service builds one.
    private func build(
        coi: COIAnalysisResult = .notAvailable,
        data: DataAvailabilityResult = .notStated,
        industry: Bool = false,
        funders: [FunderInfo] = [],
        registrations: [TrialRegistration] = [],
        compliance: ResultsComplianceStatus = .unknown,
        fullTextSearched: Bool? = true,
        sources: [String] = [TransparencyConstants.pubMedSourceName, TransparencyConstants.crossRefSourceName]
    ) -> TransparencyResult {
        var builder = TransparencyResultBuilder(doi: "10.1000/test", pmid: "123")
        builder.coiAnalysis = coi
        builder.dataAvailability = data
        builder.industryFundingDetected = industry
        builder.industryFundingConfidence = industry ? 0.9 : 0
        builder.funders = funders
        builder.trialRegistrations = registrations
        builder.resultsCompliance = compliance
        builder.fullTextSearched = fullTextSearched
        builder.dataSourcesUsed = sources
        return builder.build()
    }

    private func registration(resultsPosted: Bool) -> TrialRegistration {
        TrialRegistration(
            registry: TransparencyConstants.clinicalTrialsRegistryName,
            registrationId: "NCT00000001",
            resultsPosted: resultsPosted
        )
    }

    // MARK: - Rules agree with the rating

    /// The triggers are what the rating is computed from, so every
    /// combination rated high names at least one, and none rated otherwise does.
    func testTriggersAreNonEmptyExactlyWhenRatedHigh() {
        let levels = DataDisclosureLevel.allCases
        for score in stride(from: 0, through: 100, by: 5) {
            for industry in [false, true] {
                for level in levels {
                    for coi in [false, true] {
                        let rating = TransparencyScorer.calculateRiskLevel(
                            score: score, industryFunding: industry,
                            dataAvailability: level, coiDisclosed: coi
                        )
                        let triggers = TransparencyScorer.highRiskTriggers(
                            score: score, industryFunding: industry,
                            dataAvailability: level, coiDisclosed: coi
                        )
                        XCTAssertEqual(
                            rating == .high, !triggers.isEmpty,
                            "score \(score), industry \(industry), \(level), coi \(coi)"
                        )
                    }
                }
            }
        }
    }

    /// Every rule met is named, not only the first.
    func testAllMatchingTriggersAreReturned() {
        let triggers = TransparencyScorer.highRiskTriggers(
            score: 10, industryFunding: true, dataAvailability: .notAvailable, coiDisclosed: false
        )
        XCTAssertEqual(triggers, [
            .scoreBelowThreshold(score: 10, threshold: TransparencyConstants.highRiskScoreThreshold),
            .industryFundingWithWithheldData(.notAvailable),
            .missingCOIStatement,
        ])
    }

    /// A disabled rule is not named.
    func testDisabledRulesAreNotReturned() {
        let triggers = TransparencyScorer.highRiskTriggers(
            score: 80, industryFunding: true, dataAvailability: .restricted, coiDisclosed: false,
            industryDataTriggersHighRisk: false, missingCoiTriggersHighRisk: false
        )
        XCTAssertEqual(triggers, [])
    }

    // MARK: - Score components

    /// The components are what the score is the sum of, across inputs that
    /// exercise every term.
    func testScoreComponentsSumToScore() {
        let cases: [TransparencyResult] = [
            build(),
            build(coi: cleanCOI, data: DataAvailabilityResult(disclosureLevel: .fullOpen)),
            build(
                coi: COIAnalysisResult(statement: "Consultant to Pfizer.", hasIndustryTies: true),
                data: DataAvailabilityResult(disclosureLevel: .notAvailable),
                industry: true,
                registrations: [registration(resultsPosted: false)],
                compliance: .missing
            ),
            build(
                coi: cleanCOI,
                data: DataAvailabilityResult(disclosureLevel: .availableOnRequest),
                registrations: [registration(resultsPosted: true)],
                compliance: .compliant
            ),
        ]
        for result in cases {
            let sum = TransparencyScorer.scoreComponents(for: result).reduce(0) { $0 + $1.points }
            XCTAssertEqual(sum, result.transparencyScore)
        }
    }

    /// Disclosed industry ties show as the credit and the penalty they are,
    /// rather than as a net zero that reads as nothing found.
    func testDisclosedIndustryTiesShowAsCreditAndPenalty() {
        let result = build(coi: COIAnalysisResult(statement: "Consultant to Pfizer.", hasIndustryTies: true))
        let labels = TransparencyScorer.scoreComponents(for: result).map(\.label)
        XCTAssertTrue(labels.contains("Conflict of interest statement present"))
        XCTAssertTrue(labels.contains("Conflict of interest statement discloses industry ties"))
    }

    func testSignedPoints() {
        XCTAssertEqual(ScoreComponent(label: "a", points: 5).signedPoints, "+5")
        XCTAssertEqual(ScoreComponent(label: "a", points: -10).signedPoints, "-10")
    }

    // MARK: - Explanation

    /// The commonest high rating: no statement found although the text was searched.
    func testMissingCOIWithFullTextNamesTheRuleWithoutTextCaveat() {
        let result = build(data: DataAvailabilityResult(disclosureLevel: .fullOpen))
        XCTAssertEqual(result.riskLevel, .high)

        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertEqual(explanation.reasons.count, 1)
        XCTAssertTrue(explanation.reasons[0].contains("No conflict of interest statement was found in the full text"))
        XCTAssertTrue(explanation.caveats.isEmpty, "\(explanation.caveats)")
        XCTAssertEqual(explanation.certainty, .fullText)
        XCTAssertNil(explanation.certainty.note, "full-text analysis is the standard and needs no qualifier")
        XCTAssertTrue(explanation.scoreBreakdown.isEmpty, "a score above the cut-off is not a reason")
    }

    /// Without full text, no statement could have been found; the rating must
    /// say it is unassessed, not present it as evidence against the study.
    func testMissingCOIWithoutFullTextIsFlaggedAsUnassessed() {
        let result = build(fullTextSearched: false)
        XCTAssertEqual(result.riskLevel, .high)

        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertEqual(explanation.certainty, .limitedNoFullText)
        XCTAssertTrue(explanation.reasons[0].contains("was not searched"))
        XCTAssertTrue(explanation.caveats.contains { $0.contains("shown as unassessed") })
    }

    /// A result stored before the field existed says its text coverage is unknown.
    func testUnrecordedFullTextIsReportedAsUnknown() {
        let explanation = TransparencyRiskExplanation(result: build(fullTextSearched: nil))
        XCTAssertEqual(explanation.certainty, .unrecorded)
        XCTAssertEqual(explanation.certainty.note, TransparencyConstants.unrecordedCertaintyNote)
        XCTAssertTrue(explanation.caveats.contains { $0.contains("unassessed") })
    }

    /// A reason that stands without the full text keeps the rating from
    /// reading as unassessed: unposted trial results are a registry finding.
    func testRegistryFindingIsNotCaveatedAsMissingText() {
        let result = build(
            coi: cleanCOI,
            data: DataAvailabilityResult(disclosureLevel: .notAvailable),
            industry: true,
            registrations: [registration(resultsPosted: false)],
            compliance: .missing,
            fullTextSearched: false
        )
        XCTAssertEqual(result.riskLevel, .high)
        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertFalse(explanation.caveats.contains { $0.contains("unassessed") }, "\(explanation.caveats)")
    }

    /// A low score is explained by the terms that produced it.
    func testLowScoreCarriesItsBreakdown() {
        // 50 - 15 (no data) + 5 (COI statement) - 15 (outcome switching) = 25.
        var builder = TransparencyResultBuilder(doi: "10.1000/x")
        builder.coiAnalysis = cleanCOI
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        builder.outcomeSwitchingDetected = true
        builder.fullTextSearched = true
        builder.dataSourcesUsed = [TransparencyConstants.crossRefSourceName]
        let low = builder.build()
        XCTAssertLessThan(low.transparencyScore, TransparencyConstants.highRiskScoreThreshold)

        let explanation = TransparencyRiskExplanation(result: low)
        XCTAssertTrue(explanation.reasons[0].contains("below the high-risk cut-off"))
        XCTAssertEqual(
            explanation.scoreBreakdown.reduce(0) { $0 + $1.points },
            low.transparencyScore
        )
    }

    /// Industry funders are named in the reason.
    func testIndustryReasonNamesFunders() {
        let pfizer = FunderInfo(name: "Pfizer Inc.", isIndustry: true, confidence: 0.9)
        let nih = FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9)
        let result = build(
            coi: cleanCOI,
            data: DataAvailabilityResult(disclosureLevel: .restricted),
            industry: true,
            funders: [pfizer, nih]
        )
        let explanation = TransparencyRiskExplanation(result: result)
        let reason = try? XCTUnwrap(explanation.reasons.first { $0.contains("Industry funding") })
        XCTAssertTrue(reason?.contains("Pfizer Inc.") == true)
        XCTAssertFalse(reason?.contains("NIH") == true)
        XCTAssertTrue(reason?.contains("available only with restrictions") == true)
        XCTAssertFalse(
            explanation.otherConcerns.contains(RiskIndicatorStrings.industryFunding),
            "a concern the reason already states is not repeated"
        )
    }

    /// A stored high rating no current rule explains says so rather than
    /// showing an empty list of reasons.
    func testUnexplainedHighRatingIsCaveated() {
        let result = TransparencyResult(
            coiAnalysis: cleanCOI,
            dataAvailability: DataAvailabilityResult(disclosureLevel: .fullOpen),
            transparencyScore: 90,
            riskLevel: .high,
            dataSourcesUsed: [TransparencyConstants.pubMedSourceName],
            fullTextSearched: true
        )
        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertTrue(explanation.reasons.isEmpty)
        XCTAssertTrue(explanation.caveats.contains { $0.contains("None of the current high-risk rules") })
    }

    /// Stale results, unreadable metadata and analysis errors are all caveats.
    func testProvenanceCaveats() {
        let result = TransparencyResult(
            transparencyScore: 40,
            riskLevel: .high,
            dataSourcesUsed: [],
            errors: ["timeout"],
            analyzerVersion: nil,
            fullTextSearched: true
        )
        let caveats = TransparencyRiskExplanation(result: result).caveats
        XCTAssertTrue(caveats.contains { $0.contains("older version of the analyser") })
        XCTAssertTrue(caveats.contains { $0.contains("No CrossRef record was retrieved") })
        XCTAssertTrue(caveats.contains { $0.contains("timeout") })
    }

    /// Funders come only from CrossRef; a PubMed record does not stand in for it.
    func testMissingCrossRefIsCaveatedEvenWithPubMed() {
        let explanation = TransparencyRiskExplanation(result: build(sources: [TransparencyConstants.pubMedSourceName]))
        XCTAssertTrue(explanation.caveats.contains { $0.contains("funders were not checked") })
        let withCrossRef = TransparencyRiskExplanation(result: build(sources: [TransparencyConstants.crossRefSourceName]))
        XCTAssertFalse(withCrossRef.caveats.contains { $0.contains("funders were not checked") })
    }

    /// Without full text, the COI warning is not repeated unqualified, and a
    /// score term recording a missing statement says it was not searched.
    func testUnsearchedStatementsAreNotRepeatedAsFindings() {
        var builder = TransparencyResultBuilder(doi: "10.1000/x")
        builder.industryFundingDetected = true
        builder.industryFundingConfidence = 0.9
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        builder.outcomeSwitchingDetected = true
        builder.fullTextSearched = false
        builder.warnings = [RiskIndicatorStrings.fundingWithoutCoiStatement]
        let result = builder.build()
        XCTAssertLessThan(result.transparencyScore, TransparencyConstants.highRiskScoreThreshold)

        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertFalse(explanation.otherConcerns.contains(RiskIndicatorStrings.fundingWithoutCoiStatement))
        XCTAssertTrue(explanation.scoreBreakdown.contains {
            $0.label == "No conflict of interest statement found (full text not searched)"
        })
    }

    // MARK: - Unassessed

    /// A high rating resting only on unsearched text is shown as unassessed.
    func testTextOnlyHighRatingIsUnassessed() {
        let result = build(fullTextSearched: false)
        XCTAssertEqual(result.riskLevel, .high)
        XCTAssertTrue(TransparencyRiskExplanation.isUnassessed(result: result))
        XCTAssertTrue(TransparencyRiskExplanation(result: result).isUnassessed)
        XCTAssertTrue(TransparencyRiskExplanation.isUnassessed(result: build(fullTextSearched: nil)))
    }

    /// The same finding from searched text is a real high rating.
    func testSearchedTextHighRatingIsNotUnassessed() {
        let result = build(fullTextSearched: true)
        XCTAssertEqual(result.riskLevel, .high)
        XCTAssertFalse(TransparencyRiskExplanation.isUnassessed(result: result))
    }

    /// A reason standing without the text keeps the rating high, limited or not.
    func testRegistryFindingKeepsTheRatingHigh() {
        let result = build(
            coi: cleanCOI,
            data: DataAvailabilityResult(disclosureLevel: .notAvailable),
            industry: true,
            registrations: [registration(resultsPosted: false)],
            compliance: .missing,
            fullTextSearched: false
        )
        XCTAssertEqual(result.riskLevel, .high)
        XCTAssertFalse(TransparencyRiskExplanation.isUnassessed(result: result))
    }

    /// Only a high rating can be shown as unassessed.
    func testLowerRatingsAreNeverUnassessed() {
        let result = build(coi: cleanCOI, data: DataAvailabilityResult(disclosureLevel: .fullOpen), fullTextSearched: false)
        XCTAssertNotEqual(result.riskLevel, .high)
        XCTAssertFalse(TransparencyRiskExplanation.isUnassessed(result: result))
    }

    func testUnassessedSummary() {
        XCTAssertNil(HighRiskTransparencySection.unassessedSummary(count: 0))
        XCTAssertTrue(HighRiskTransparencySection.unassessedSummary(count: 1)!.hasPrefix("1 study is shown as unassessed"))
        XCTAssertTrue(HighRiskTransparencySection.unassessedSummary(count: 3)!.hasPrefix("3 studies are shown as unassessed"))
    }

    /// With no high-risk study but some unassessed, the section says so rather than vanishing.
    func testSectionWithOnlyUnassessedStudies() throws {
        let text = try XCTUnwrap(HighRiskTransparencySection.plainText(for: [], unassessedCount: 2))
        XCTAssertTrue(text.contains("2 studies are shown as unassessed"))
        XCTAssertNil(HighRiskTransparencySection.plainText(for: [], unassessedCount: 0))
    }

    // MARK: - Section

    func testSectionIsAbsentWithoutHighRiskStudies() {
        XCTAssertNil(HighRiskTransparencySection.plainText(for: []))
    }

    func testSectionListsEachStudyWithItsReasons() throws {
        let entry = HighRiskTransparencyEntry(
            reference: "Smith et al., 2020",
            citation: "Smith J et al. (2020). A trial. DOI: 10.1000/test",
            result: build(fullTextSearched: false)
        )
        let text = try XCTUnwrap(HighRiskTransparencySection.plainText(for: [entry, entry]))
        XCTAssertTrue(text.hasPrefix(HighRiskTransparencySection.heading.uppercased()))
        XCTAssertTrue(text.contains("2 studies were rated high transparency risk"))
        XCTAssertTrue(text.contains("Smith et al., 2020: Smith J et al. (2020). A trial."))
        XCTAssertTrue(text.contains("Rated high risk because:"))
        XCTAssertTrue(text.contains("shown as unassessed"))
        XCTAssertTrue(text.contains(TransparencyConstants.limitedCertaintyNote))
    }

    /// A text-less rating says so beside its score even when another reason stands.
    func testLimitedCertaintyIsStatedEvenWhenAReasonStandsWithoutText() {
        let result = build(
            coi: cleanCOI,
            data: DataAvailabilityResult(disclosureLevel: .notAvailable),
            industry: true,
            registrations: [registration(resultsPosted: false)],
            compliance: .missing,
            fullTextSearched: false
        )
        let explanation = TransparencyRiskExplanation(result: result)
        XCTAssertTrue(explanation.plainTextLines.contains("  \(TransparencyConstants.limitedCertaintyNote)"))
    }

    /// A caller holding better evidence than the result's record can supply it.
    func testCertaintyOverrideReplacesAnUnrecordedOne() {
        let explanation = TransparencyRiskExplanation(
            result: build(fullTextSearched: nil),
            certainty: .limitedNoFullText
        )
        XCTAssertEqual(explanation.certainty.note, TransparencyConstants.limitedCertaintyNote)
    }

    // MARK: - Certainty

    func testCertaintyFromRecord() {
        XCTAssertEqual(TransparencyCertainty(fullTextSearched: true), .fullText)
        XCTAssertEqual(TransparencyCertainty(fullTextSearched: false), .limitedNoFullText)
        XCTAssertEqual(TransparencyCertainty(fullTextSearched: nil), .unrecorded)
        XCTAssertFalse(TransparencyCertainty.fullText.isLimited)
        XCTAssertTrue(TransparencyCertainty.limitedNoFullText.isLimited)
        XCTAssertTrue(TransparencyCertainty.unrecorded.isLimited)
        XCTAssertEqual(
            TransparencyConstants.limitedCertaintyNote,
            "Limited certainty because of lack of full text access"
        )
    }

    /// The tooltip, like every other rating surface, carries the note.
    func testTooltipCarriesCertaintyNote() {
        XCTAssertTrue(
            TransparencyScorer.formatTooltip(for: build(fullTextSearched: false))
                .contains(TransparencyConstants.limitedCertaintyNote)
        )
        XCTAssertFalse(
            TransparencyScorer.formatTooltip(for: build(fullTextSearched: true))
                .contains(TransparencyConstants.limitedCertaintyNote)
        )
    }

    // MARK: - Persistence

    /// Results stored before `fullTextSearched` existed still decode, as unknown.
    func testResultWithoutFullTextFieldDecodesAsUnknown() throws {
        let encoded = try JSONEncoder().encode(build(fullTextSearched: true))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fullTextSearched")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TransparencyResult.self, from: legacy)
        XCTAssertNil(decoded.fullTextSearched)
    }
}
