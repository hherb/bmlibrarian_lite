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

import Testing
@testable import Medical_Fact_Checker

struct Medical_Fact_CheckerTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
}

// MARK: - FactCheckSession Pagination Tests

struct FactCheckSessionPaginationTests {

    // MARK: - searchProviderEnum Tests

    @Test func searchProviderEnumNilWhenNotSet() {
        let session = FactCheckSession(claim: "Test claim")
        #expect(session.searchProviderEnum == nil)
    }

    @Test func searchProviderEnumPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        #expect(session.searchProviderEnum == .pubmed)
    }

    @Test func searchProviderEnumEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        #expect(session.searchProviderEnum == .europePMC)
    }

    @Test func searchProviderEnumBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"
        #expect(session.searchProviderEnum == .both)
    }

    @Test func searchProviderEnumSetter() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProviderEnum = .europePMC
        #expect(session.searchProvider == "europepmc")
    }

    // MARK: - canFetchMoreFromAnyProvider Tests

    @Test func canFetchMoreFromAnyProviderLegacyFallback() {
        // When no provider is set, falls back to PubMed offset check
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 100
        session.pubmedOffset = 20

        #expect(session.canFetchMoreFromAnyProvider == true)

        session.pubmedOffset = 100
        #expect(session.canFetchMoreFromAnyProvider == false)
    }

    @Test func canFetchMoreFromAnyProviderPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true

        #expect(session.canFetchMoreFromAnyProvider == true)

        session.pubmedHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == false)
    }

    @Test func canFetchMoreFromAnyProviderEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        session.europePMCHasMore = true

        #expect(session.canFetchMoreFromAnyProvider == true)

        session.europePMCHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == false)
    }

    @Test func canFetchMoreFromAnyProviderBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"

        // Both have more
        session.pubmedHasMore = true
        session.europePMCHasMore = true
        #expect(session.canFetchMoreFromAnyProvider == true)

        // Only PubMed has more
        session.pubmedHasMore = true
        session.europePMCHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == true)

        // Only Europe PMC has more
        session.pubmedHasMore = false
        session.europePMCHasMore = true
        #expect(session.canFetchMoreFromAnyProvider == true)

        // Neither has more
        session.pubmedHasMore = false
        session.europePMCHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == false)
    }

    // MARK: - canFetchMoreDocuments Tests

    @Test func canFetchMoreDocumentsAliasesAnyProvider() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true

        #expect(session.canFetchMoreDocuments == session.canFetchMoreFromAnyProvider)
    }

    // MARK: - remainingPubMedResults Tests

    @Test func remainingPubMedResults() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 150
        session.pubmedOffset = 50

        #expect(session.remainingPubMedResults == 100)
    }

    @Test func remainingPubMedResultsNeverNegative() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 50
        session.pubmedOffset = 100  // Offset exceeds total

        #expect(session.remainingPubMedResults == 0)
    }

    // MARK: - remainingEuropePMCResults Tests

    @Test func remainingEuropePMCResultsWhenNoMore() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = false

        #expect(session.remainingEuropePMCResults == 0)
    }

    @Test func remainingEuropePMCResultsWithKnownTotal() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = true
        session.europePMCTotalResults = 200
        session.europePMCOffset = 50

        #expect(session.remainingEuropePMCResults == 150)
    }

    @Test func remainingEuropePMCResultsFallsBackToDefault() {
        let session = FactCheckSession(claim: "Test claim")
        session.europePMCHasMore = true
        session.europePMCTotalResults = 0
        session.europePMCOffset = 0

        // Should fall back to defaultMaxResults (20)
        #expect(session.remainingEuropePMCResults == SearchOptions.SearchOptionsDefaults.defaultMaxResults)
    }

    // MARK: - estimatedRemainingResults Tests

    @Test func estimatedRemainingResultsLegacyFallback() {
        let session = FactCheckSession(claim: "Test claim")
        session.pubmedTotalResults = 100
        session.pubmedOffset = 30

        #expect(session.estimatedRemainingResults == 70)
    }

    @Test func estimatedRemainingResultsPubMed() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedTotalResults = 100
        session.pubmedOffset = 25
        session.pubmedHasMore = true

        #expect(session.estimatedRemainingResults == 75)

        session.pubmedHasMore = false
        #expect(session.estimatedRemainingResults == 0)
    }

    @Test func estimatedRemainingResultsEuropePMC() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "europepmc"
        session.europePMCTotalResults = 80
        session.europePMCOffset = 20
        session.europePMCHasMore = true

        #expect(session.estimatedRemainingResults == 60)

        session.europePMCHasMore = false
        #expect(session.estimatedRemainingResults == 0)
    }

    @Test func estimatedRemainingResultsBoth() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "both"
        session.pubmedTotalResults = 100
        session.pubmedOffset = 30
        session.pubmedHasMore = true
        session.europePMCTotalResults = 50
        session.europePMCOffset = 10
        session.europePMCHasMore = true

        // PubMed: 70, Europe PMC: 40, Total: 110
        #expect(session.estimatedRemainingResults == 110)
    }

    // MARK: - canGetMoreEvidence Tests

    @Test func canGetMoreEvidenceWithResults() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = true
        session.smartSearchEnabled = true

        #expect(session.canGetMoreEvidence == true)
    }

    @Test func canGetMoreEvidenceWithSmartSearch() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = "pubmed"
        session.pubmedHasMore = false
        session.smartSearchEnabled = false

        // Smart search not yet tried
        #expect(session.canGetMoreEvidence == true)

        session.smartSearchEnabled = true
        #expect(session.canGetMoreEvidence == false)
    }

    // MARK: - totalFetchedDocuments Tests

    @Test func totalFetchedDocumentsEmpty() {
        let session = FactCheckSession(claim: "Test claim")
        #expect(session.totalFetchedDocuments == 0)
    }

    @Test func totalFetchedDocumentsNilDocuments() {
        let session = FactCheckSession(claim: "Test claim")
        session.documents = nil
        #expect(session.totalFetchedDocuments == 0)
    }
}
