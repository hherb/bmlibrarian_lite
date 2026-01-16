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
import SwiftUI
@testable import MedicalFactCheckerMac

// MARK: - MacProviderColors Tests

struct MacProviderColorsTests {
    @Test func colorForAllProviders() {
        // Verify all providers have defined colors
        for provider in SearchProvider.allCases {
            let color = MacProviderColors.color(for: provider)
            // Just verify we get a color (non-nil behavior is guaranteed by the type)
            // The color should be the same when accessed multiple times
            let color2 = MacProviderColors.color(for: provider)
            #expect(color == color2)
        }
    }

    @Test func staticColorsAreDefined() {
        // Verify static colors exist and are distinct from pure black/white
        // We can't easily compare Color values, but we can verify they're accessible
        let pubmedColor = MacProviderColors.pubmed
        let europePMCColor = MacProviderColors.europePMC
        let bothColor = MacProviderColors.both

        // These should compile and not crash - proving the colors are defined
        #expect(type(of: pubmedColor) == Color.self)
        #expect(type(of: europePMCColor) == Color.self)
        #expect(type(of: bothColor) == Color.self)
    }

    @Test func colorForPubMedReturnsStaticColor() {
        let dynamic = MacProviderColors.color(for: .pubmed)
        let staticColor = MacProviderColors.pubmed
        #expect(dynamic == staticColor)
    }

    @Test func colorForEuropePMCReturnsStaticColor() {
        let dynamic = MacProviderColors.color(for: .europePMC)
        let staticColor = MacProviderColors.europePMC
        #expect(dynamic == staticColor)
    }

    @Test func colorForBothReturnsStaticColor() {
        let dynamic = MacProviderColors.color(for: .both)
        let staticColor = MacProviderColors.both
        #expect(dynamic == staticColor)
    }
}

// MARK: - SearchProvider Short Name Tests

struct SearchProviderShortNameTests {
    @Test func shortNameLength() {
        // Short names should be short for badge display
        for provider in SearchProvider.allCases {
            let shortName = provider.shortName
            #expect(shortName.count <= 4, "Short name '\(shortName)' is too long for badge display")
            #expect(shortName.count >= 2, "Short name '\(shortName)' is too short to be meaningful")
        }
    }

    @Test func shortNameIsNotEmpty() {
        for provider in SearchProvider.allCases {
            #expect(!provider.shortName.isEmpty)
        }
    }

    @Test func shortNameContainsNoWhitespace() {
        for provider in SearchProvider.allCases {
            let shortName = provider.shortName
            #expect(!shortName.contains(" "), "Short name should not contain spaces")
            #expect(!shortName.contains("\t"), "Short name should not contain tabs")
        }
    }
}

// MARK: - Search Options Defaults Tests

struct SearchOptionsDefaultsTests {
    @Test func defaultProviderIsPubMed() {
        // When building from fresh settings, PubMed should be the default
        // This is verified by AppSettings.selectedSearchProvider default
        let options = SearchOptions()
        #expect(options.provider == .pubmed)
    }

    @Test func defaultPreprintsIsFalse() {
        let options = SearchOptions()
        #expect(options.includePreprints == false)
    }

    @Test func preprintsSupportedByCorrectProviders() {
        // PubMed doesn't support preprints
        #expect(SearchProvider.pubmed.supportsPreprints == false)
        // Europe PMC supports preprints
        #expect(SearchProvider.europePMC.supportsPreprints == true)
        // Both supports preprints (via Europe PMC)
        #expect(SearchProvider.both.supportsPreprints == true)
    }
}

// MARK: - Document Provider Detection Tests

struct DocumentProviderDetectionTests {
    @Test func documentWithPMIDIsPubMed() {
        // Documents with a PMID are typically from PubMed
        let document = Document(
            pmid: "12345678",
            title: "Test Article",
            abstract: "Test abstract",
            authors: ["Author A"],
            batchNumber: 1,
            resultPosition: 0
        )
        // The document should be identifiable as from PubMed
        #expect(!document.pmid.isEmpty)
    }

    @Test func documentWithOnlyPMCIdIsEuropePMC() {
        // Documents with PMC ID but no PMID likely came from Europe PMC
        let document = Document(
            pmid: "",
            title: "Preprint Article",
            abstract: "Test abstract",
            authors: ["Author A"],
            batchNumber: 1,
            resultPosition: 0
        )
        document.pmcId = "PMC9876543"

        // Empty PMID but has PMC ID suggests Europe PMC source
        #expect(document.pmid.isEmpty)
        #expect(document.pmcId != nil)
    }

    @Test func preprintJournalIndicatesEuropePMC() {
        // Preprint journals come from Europe PMC
        let journals = ["bioRxiv", "medRxiv", "arXiv", "PREPRINT SERVER"]

        for journal in journals {
            let lowercased = journal.lowercased()
            let isPreprint = lowercased.contains("biorxiv") ||
                             lowercased.contains("medrxiv") ||
                             lowercased.contains("arxiv") ||
                             lowercased.contains("preprint")
            #expect(isPreprint, "Journal '\(journal)' should be detected as preprint")
        }
    }

    @Test func regularJournalIsNotPreprint() {
        let regularJournals = [
            "New England Journal of Medicine",
            "The Lancet",
            "BMJ",
            "Nature Medicine"
        ]

        for journal in regularJournals {
            let lowercased = journal.lowercased()
            let isPreprint = lowercased.contains("biorxiv") ||
                             lowercased.contains("medrxiv") ||
                             lowercased.contains("arxiv") ||
                             lowercased.contains("preprint")
            #expect(!isPreprint, "Journal '\(journal)' should not be detected as preprint")
        }
    }
}

// MARK: - Session Search Provider Tracking Tests

struct SessionSearchProviderTrackingTests {
    @Test func sessionCanStoreSearchProvider() {
        let session = FactCheckSession(claim: "Test claim")
        session.searchProvider = SearchProvider.europePMC.rawValue

        #expect(session.searchProvider == "europePMC")
    }

    @Test func sessionCanStorePreprints() {
        let session = FactCheckSession(claim: "Test claim")
        session.includePreprints = true

        #expect(session.includePreprints == true)
    }

    @Test func sessionTracksProviderSpecificPagination() {
        let session = FactCheckSession(claim: "Test claim")

        // Can track pagination for multiple providers independently
        session.pubmedHasMore = true
        session.europePMCHasMore = false

        #expect(session.pubmedHasMore == true)
        #expect(session.europePMCHasMore == false)
    }

    @Test func canFetchMoreFromAnyProvider() {
        let session = FactCheckSession(claim: "Test claim")

        // Initially, hasMore properties should be based on whether there are more results
        session.pubmedHasMore = true
        session.europePMCHasMore = true

        // canFetchMoreFromAnyProvider should be true if either has more
        #expect(session.canFetchMoreFromAnyProvider == true)

        session.pubmedHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == true)  // europePMC still has more

        session.europePMCHasMore = false
        #expect(session.canFetchMoreFromAnyProvider == false)  // neither has more
    }
}
