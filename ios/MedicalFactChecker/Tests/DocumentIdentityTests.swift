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

/// What a document's identity may be built from.
///
/// It was `"pmid-\(pmid)"`, and `pmid` is the primary identifier slot rather
/// than a PubMed ID: `pmid ?? id ?? ""` at the Europe PMC decode site, so it
/// holds a `PPR…` preprint accession, a PMC accession, or a thesis accession
/// depending on the record. Two things followed, and the second is the one that
/// reached a reader.
///
/// Every document whose slot was empty shared the identity `"pmid-"`. SwiftData
/// dropped `.unique` for CloudKit, so nothing rejected the duplicates, and a
/// report's `documents.first { $0.id == documentId }` then handed back whichever
/// came first (#208).
///
/// And the identity *claimed a kind it could not prove*. A saved report carries
/// its references as `doc:<identity>`, an exported PDF read `doc:pmid-889149`
/// as a PubMed ID and printed `(PMID: 889149)` — a real 1977 paper on mouse
/// courtship, not the thesis being cited (#212).
///
/// An identity is now an opaque token, unique by construction and claiming
/// nothing. Documents stored under the old scheme keep their identities, and
/// their saved reports keep resolving by exact match.
final class DocumentIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeDocument(pmid: String) -> Document {
        Document(pmid: pmid, title: "An article", abstract: "")
    }

    /// The defect itself: no identifier, so no way to tell the two apart.
    func testTwoIdentifierlessDocumentsDoNotShareAnIdentity() {
        let first = makeDocument(pmid: "")
        let second = makeDocument(pmid: "")

        XCTAssertNotEqual(first.id, second.id)
    }

    /// Two records of the same article are still two rows, and a lookup that
    /// returns "one of them" is the bug. Reachable across sessions, where the
    /// deduplication that keeps a session's slots distinct does not apply.
    func testTwoDocumentsWithTheSameSlotDoNotShareAnIdentity() {
        let first = makeDocument(pmid: "12662058")
        let second = makeDocument(pmid: "12662058")

        XCTAssertNotEqual(first.id, second.id)
    }

    /// An identity names nothing about the article, so nothing downstream can
    /// read a namespace out of it. `pmid-PPR1287966` invited exactly that.
    func testAnIdentityClaimsNoNamespace() {
        let preprint = makeDocument(pmid: "PPR1287966")

        XCTAssertFalse(preprint.id.lowercased().contains("pmid"), preprint.id)
        XCTAssertFalse(preprint.id.contains("PPR1287966"), preprint.id)
    }

    /// Identity is assigned once and does not move.
    ///
    /// This is why the identity is not the tagged ladder `ArticleCacheKey` uses.
    /// A document is initialised from the primary slot alone and its kind, PMC
    /// ID and DOI arrive afterwards through ``Document/applySearchMetadata(_:provider:)``,
    /// so a ladder evaluated here would see only the slot — and one evaluated
    /// later would move under the saved reports that already name it.
    func testAnIdentityDoesNotMoveWhenMetadataArrives() {
        let document = makeDocument(pmid: "PPR1287966")
        let assigned = document.id

        document.pmcId = "PMC7654321"
        document.doi = "10.1101/2024.01.01.573000"
        document.identifierKind = .preprint

        XCTAssertEqual(document.id, assigned)
    }

    // MARK: - The store

    /// The hop that matters, because SwiftData is where the duplicates were
    /// tolerated: `.unique` was dropped for CloudKit, so the store accepted two
    /// rows under one identity and a lookup answered with whichever came first.
    ///
    /// Two identifier-less documents, stored together, must each be found as
    /// themselves.
    func testEachIdentifierlessDocumentIsFoundAsItself() throws {
        let container = try ModelContainer(
            for: Document.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let first = makeDocument(pmid: "")
        first.title = "The first article"
        let second = makeDocument(pmid: "")
        second.title = "The second article"
        context.insert(first)
        context.insert(second)
        try context.save()

        let stored = try ModelContext(container).fetch(FetchDescriptor<Document>())
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.first { $0.id == first.id }?.title, "The first article")
        XCTAssertEqual(stored.first { $0.id == second.id }?.title, "The second article")
    }

    /// A row written under the old scheme keeps the identity it was given, so
    /// the `doc:pmid-…` references in the report saved alongside it still
    /// resolve by exact match. This is the whole of the compatibility story:
    /// nothing rewrites a stored identity, so nothing has to be migrated.
    func testAStoredLegacyIdentityIsNotRewritten() throws {
        let container = try ModelContainer(
            for: Document.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let legacy = makeDocument(pmid: "12662058")
        legacy.id = "pmid-12662058"
        context.insert(legacy)
        try context.save()

        let refetched = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first
        )
        XCTAssertEqual(refetched.id, "pmid-12662058")
    }
}
