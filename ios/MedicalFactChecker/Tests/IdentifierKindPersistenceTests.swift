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
import XCTest
@testable import MedicalFactChecker

/// A document's identifier kind has to survive the trip from the search result
/// to the retrieval call, which happens days later and after a relaunch.
///
/// Europe PMC states the kind once, on the record. Everything that needs it —
/// the query that can match the identifier, the PDF cache filename, the preprint
/// badge — happens after the record is gone, so a kind that is not stored is a
/// kind that is guessed back from the accession's shape (#209).
final class IdentifierKindPersistenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeDocument() -> Document {
        Document(pmid: "PPR1287966", title: "A preprint", abstract: "")
    }

    // MARK: - Storage

    /// Stored as Europe PMC's own token, so writing a kind down invents nothing.
    func testAStoredKindReadsBackAsItself() {
        let document = makeDocument()

        document.identifierKind = .preprint

        XCTAssertEqual(document.identifierKindToken, "ppr")
        XCTAssertEqual(document.identifierKind, .preprint)
    }

    /// A document written before this field existed answers `nil`, which means
    /// "nobody told us" rather than "no kind". Consumers fall back to the
    /// accession's shape, which is exactly what every document did before the
    /// kind was carried.
    func testADocumentThatPredatesTheFieldHasNoKind() {
        let document = makeDocument()

        XCTAssertNil(document.identifierKindToken)
        XCTAssertNil(document.identifierKind)
    }

    /// An unmodelled Europe PMC source — a book, a patent, a thesis — round
    /// trips as itself. These are the records the shape rule cannot name at all,
    /// so the stored token is the only thing that can route them.
    func testAnUnmodelledSourceTokenRoundTrips() {
        let document = makeDocument()

        document.identifierKind = .europePMCSource("nbk")

        XCTAssertEqual(document.identifierKindToken, "nbk")
        XCTAssertEqual(document.identifierKind, .europePMCSource("nbk"))
    }

    /// `.unknown` records nothing, because it is the absence of knowledge. A
    /// stored token for it would turn "nobody said" into a claim, and reading it
    /// back would then skip the shape rule that can still name some of them.
    func testAnUnknownKindStoresNothing() {
        let document = makeDocument()
        document.identifierKind = .preprint

        document.identifierKind = .unknown

        XCTAssertNil(document.identifierKindToken)
    }

    // MARK: - The adapter

    /// The kind reaches the app's metadata from the BioMedLit search article,
    /// which is the only hop where the record's `source` field is still around.
    func testTheAdapterCarriesTheKindOntoAppMetadata() {
        let metadata = BioMedLitAdapters.toUnifiedArticleMetadata(
            BMLSearchArticle(
                pmid: "PPR1287966",
                title: "A preprint",
                abstract: "",
                authors: "",
                journal: "",
                year: "2026",
                source: .europePMC,
                identifierKind: .preprint
            ),
            appProvider: .europePMC,
            batchNumber: 1,
            resultPosition: 0
        )

        XCTAssertEqual(metadata.identifierKind, .preprint)
    }

    /// The preprint badge has been in both apps since before this change and has
    /// never once lit up: the adapter hard-coded `isPreprint: false`, because
    /// the only thing that knew — the record's source — was discarded at decode.
    func testAPreprintRecordIsMarkedAsAPreprint() {
        let metadata = BioMedLitAdapters.toUnifiedArticleMetadata(
            BMLSearchArticle(
                pmid: "PPR1287966",
                title: "A preprint",
                abstract: "",
                authors: "",
                journal: "",
                year: "2026",
                source: .europePMC,
                identifierKind: .preprint
            ),
            appProvider: .europePMC,
            batchNumber: 1,
            resultPosition: 0
        )

        XCTAssertTrue(metadata.isPreprint)
    }

    /// A peer-reviewed article must not pick up the badge, and an article whose
    /// provider said nothing must not either — an unlit badge on a preprint is a
    /// missing fact, a lit one on a journal article is a wrong one.
    func testAnArticleThatIsNotAPreprintIsNotMarkedAsOne() {
        for kind: ArticleIdentifierKind? in [.pubmed, .pmc, .europePMCSource("nbk"), nil] {
            let metadata = BioMedLitAdapters.toUnifiedArticleMetadata(
                BMLSearchArticle(
                    pmid: "12662058",
                    title: "An article",
                    abstract: "",
                    authors: "",
                    journal: "",
                    year: "2026",
                    source: .europePMC,
                    identifierKind: kind
                ),
                appProvider: .europePMC,
                batchNumber: 1,
                resultPosition: 0
            )

            XCTAssertFalse(
                metadata.isPreprint,
                "\(String(describing: kind)) must not be marked a preprint"
            )
        }
    }

    // MARK: - The one writer

    /// Both places the workflow builds a document from a search result copy the
    /// same eight fields by hand, and a ninth had to reach both. Copying the
    /// kind into one of them is how a document fetched through the other would
    /// silently keep guessing — the drift `applyFullTextResult` exists to
    /// prevent, on a second field.
    func testASearchResultWritesItsKindAndPreprintFlagOntoTheDocument() {
        let document = makeDocument()

        document.applySearchMetadata(preprintMetadata(), provider: .europePMC)

        XCTAssertEqual(document.identifierKind, .preprint)
        XCTAssertTrue(document.isPreprint)
    }

    /// The writer owns every metadata field, not only the new ones: a caller
    /// that still set some by hand would be the drift this consolidates away.
    func testTheWriterCarriesTheRestOfTheMetadata() {
        let document = makeDocument()

        document.applySearchMetadata(preprintMetadata(), provider: .europePMC)

        XCTAssertEqual(document.doi, "10.64898/2026.07.25.26358746")
        XCTAssertEqual(document.pmcId, nil)
        XCTAssertEqual(document.year, 2026)
        XCTAssertEqual(document.journal, "bioRxiv")
        XCTAssertEqual(document.publicationDate, "2026-07-25")
        XCTAssertEqual(document.meshTerms, ["Humans"])
        XCTAssertEqual(document.searchSource, MedicalFactChecker.SearchProvider.europePMC.rawValue)
    }

    private func preprintMetadata() -> UnifiedArticleMetadata {
        UnifiedArticleMetadata(
            pmid: "PPR1287966",
            pmcId: nil,
            doi: "10.64898/2026.07.25.26358746",
            title: "A preprint",
            abstract: "",
            authors: ["Author, A"],
            journal: "bioRxiv",
            publicationDate: "2026-07-25",
            year: 2026,
            meshTerms: ["Humans"],
            source: .europePMC,
            isPreprint: true,
            identifierKind: .preprint,
            hasFullTextInPMC: false,
            batchNumber: 1,
            resultPosition: 0
        )
    }
}
