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

/// The PDF cache used to be keyed on the PMID alone, and refused an empty one.
///
/// The refusal was correct — every article with no PMID would otherwise share
/// one entry — but it cost those articles their PDF extraction entirely, and
/// the tier reported a download failure indistinguishable from a real one
/// (#202). A Europe PMC record can carry a PMC ID with no PMID, and those are
/// exactly the open-access articles most likely to have a usable free PDF.
///
/// The repair is a ladder: the first identifier the document actually has,
/// tagged with which kind it is so two kinds can never name the same entry.
final class ArticleCacheKeyTests: XCTestCase {
    // MARK: - The ladder

    /// The primary identifier wins when there is one, so a document lands on the
    /// same rung on every run rather than accumulating an entry per rung. The
    /// filename still differs from pre-``ArticleCacheKey`` builds — every rung is
    /// now tagged — so this is about stability from here on, not continuity with
    /// what is already on disk.
    func testPrimaryIdentifierIsPreferredOverEveryOtherIdentifier() {
        let key = ArticleCacheKey(
            pmid: "12345678", pmcId: "PMC7654321", doi: "10.1/abc",
            primaryKind: .pubmed
        )

        XCTAssertEqual(key?.filenameComponent, "pmid_12345678")
    }

    /// The defect #202 names, directly: a Europe PMC article with a PMC ID and
    /// no PMID must get a cache entry rather than be refused.
    func testPMCIdentifierIsUsedWhenThePrimarySlotIsEmpty() {
        let key = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: "10.1/abc")

        XCTAssertEqual(key?.filenameComponent, "pmc_PMC7654321")
    }

    /// A DOI is the last rung, and goes in as a digest rather than as
    /// sanitised text: `10.1/abc` and `10.1_abc` both sanitise to `10_1_abc`
    /// and would share an entry, which is the very collision this ladder exists
    /// to prevent.
    /// The digest is pinned to its exact hex rather than merely to its prefix.
    ///
    /// A cache filename must be the same string in every process that ever runs:
    /// Swift seeds `Hasher` per launch, so a filename built from one would change
    /// on every start and every entry would miss forever, growing the cache
    /// without bound and re-downloading every DOI-keyed PDF — silently, since
    /// a miss is indistinguishable from a first fetch. A same-process stability
    /// assertion cannot catch that, and neither can a `hasPrefix` check. Only
    /// the literal bytes can, and they pin the algorithm, the digest length
    /// (``BioMedLitConstants/doiCacheKeyDigestBytes``), and the hex encoding at
    /// once. Independently computed: `sha256("10.1/abc")`, first 16 bytes.
    func testDOIIsUsedWhenNoIdentifierIsAvailableAndIsDigested() throws {
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: "10.1/abc"))

        XCTAssertEqual(key.filenameComponent, "doi_8680376ce68f74cdeadea6aa60cc5dc7")
        // Not the sanitised text: `10.1/abc` sanitises to `10_1_abc`, which is
        // what the next test shows would merge two distinct articles.
        XCTAssertNotEqual(key.filenameComponent, "doi_10_1_abc")
    }

    /// Two DOIs that sanitise to the same string must still get their own
    /// entries. This is the case a sanitised DOI would have merged.
    func testDOIsThatSanitiseIdenticallyGetDifferentKeys() {
        let slashed = ArticleCacheKey(pmid: nil, pmcId: nil, doi: "10.1/abc")
        let underscored = ArticleCacheKey(pmid: nil, pmcId: nil, doi: "10.1_abc")

        XCTAssertNotEqual(slashed?.filenameComponent, underscored?.filenameComponent)
    }

    /// An article carrying none of the three has no stable name to file bytes
    /// under, so it is refused — as an empty PMID always was.
    func testAnArticleWithNoIdentifierAtAllHasNoKey() {
        XCTAssertNil(ArticleCacheKey(pmid: "", pmcId: "", doi: ""))
        XCTAssertNil(ArticleCacheKey(pmid: nil, pmcId: nil, doi: nil))
    }

    // MARK: - Collisions across rungs

    /// The reason every rung is tagged, including the first.
    ///
    /// `EuropePMCService` fills the primary slot as `result.pmid ?? result.id`,
    /// so it holds a PubMed ID, a Europe PMC preprint accession, or a PMC ID
    /// depending on the record. Untagged, an article whose primary slot happens
    /// to hold `PMC7654321` would name the same entry as a different article
    /// reached by a *PubMed ID* of `PMC7654321`, and one would be served the
    /// other's bytes.
    func testAPMCAccessionAndAPubMedIdentifierNeverShareAName() {
        let pubmed = ArticleCacheKey(pmid: "7654321", pmcId: nil, doi: nil)
        let pmc = ArticleCacheKey(pmid: "", pmcId: "7654321", doi: nil)

        XCTAssertNotEqual(pubmed?.filenameComponent, pmc?.filenameComponent)
    }

    /// The other half of that rule, and the correction #209 makes to it.
    ///
    /// Tagging on the *slot* an identifier arrived in filed one article under
    /// two names: a PMC-only record carries its accession in both the primary
    /// slot and `pmcId`, so it was downloaded twice and cached twice. Tagging on
    /// the identifier's *kind* collapses the two, because both names describe
    /// the same PMC accession — which is a statement about the article, not
    /// about which rung reached it.
    func testAPMCAccessionNamesOneEntryWhicheverRungReachesIt() {
        let viaPrimary = ArticleCacheKey(pmid: "PMC7654321", pmcId: nil, doi: nil)
        let viaPMCRung = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: nil)

        XCTAssertEqual(viaPrimary?.filenameComponent, "pmc_PMC7654321")
        XCTAssertEqual(viaPrimary?.filenameComponent, viaPMCRung?.filenameComponent)
    }

    // MARK: - The kind Europe PMC stated (#209)

    /// A record's stated kind names the entry, without consulting the shape of
    /// the accession. Europe PMC knows what it sent us; the shape rule is only
    /// a stand-in for records that predate the field.
    func testAStatedKindDecidesTheTag() {
        let key = ArticleCacheKey(
            pmid: "1287966",
            pmcId: nil,
            doi: nil,
            primaryKind: .preprint
        )

        XCTAssertEqual(key?.filenameComponent, "ppr_1287966")
    }

    /// An identifier no one classified and whose shape settles nothing keeps the
    /// untyped tag. Filing it under `pmid_` would claim it is a PubMed ID, the
    /// kind of label that put a `PPR…` accession behind a PubMed URL (#202).
    func testAnUnclassifiableIdentifierKeepsTheUntypedTag() {
        let key = ArticleCacheKey(pmid: "CN101548780", pmcId: nil, doi: nil)

        XCTAssertEqual(key?.filenameComponent, "id_CN101548780")
    }

    /// Two articles from different Europe PMC sources can carry the same
    /// external identifier, and neither states a kind this type tags on. They
    /// share the untyped tag, which is the one collision this design keeps — it
    /// costs a wrong entry only for two unclassified identifiers that are also
    /// byte-identical, and it is the same collision every primary-slot value had
    /// before the kinds were separated.
    ///
    /// Stated as a comparison of two keys rather than one assertion about one:
    /// the collision is a relationship, and a single expected string cannot
    /// witness it.
    func testTwoUnclassifiedIdentifiersStillShareTheUntypedTag() {
        let patent = ArticleCacheKey(
            pmid: "SHARED1234", pmcId: nil, doi: nil,
            primaryKind: .europePMCSource("pat")
        )
        let thesis = ArticleCacheKey(
            pmid: "SHARED1234", pmcId: nil, doi: nil,
            primaryKind: .europePMCSource("eth")
        )

        XCTAssertEqual(patent?.filenameComponent, thesis?.filenameComponent)
        XCTAssertEqual(patent?.filenameComponent, "src_SHARED1234")
    }

    /// An unmodelled source token files under the untyped bucket, never under a
    /// tag built from the token itself.
    ///
    /// The tag is interpolated into the filename without sanitising, because
    /// every tag is drawn from a fixed vocabulary. Returning the token here
    /// would put a provider-supplied string in that position. Nothing else in
    /// the suite pinned this branch: replacing it with `return token` passed
    /// every test before this case existed.
    func testAnUnmodelledSourceTokenFilesUnderAClosedTag() {
        let key = ArticleCacheKey(
            pmid: "879809", pmcId: nil, doi: nil,
            primaryKind: .europePMCSource("eth")
        )

        XCTAssertEqual(key?.filenameComponent, "src_879809")
        XCTAssertFalse(key?.filenameComponent.contains("eth") ?? true)
    }

    /// A stated source and an identifier nobody classified are different
    /// situations and must not share a name.
    ///
    /// Latent until #212: an unvouched decimal accession used to be called a
    /// PubMed ID, so it never landed in the untyped bucket at all. Now that it
    /// does, sharing the bucket with a stated `ETH` accession of the same digits
    /// would serve one article the other's bytes — the collision the tagging
    /// exists to prevent, reintroduced by the repair that removed a different
    /// one.
    func testAStatedSourceAndAnUnclassifiedIdentifierDoNotShareAName() {
        let thesis = ArticleCacheKey(
            pmid: "879809", pmcId: nil, doi: nil,
            primaryKind: .europePMCSource("eth")
        )
        let unclassified = ArticleCacheKey(pmid: "879809", pmcId: nil, doi: nil)

        XCTAssertNotEqual(thesis?.filenameComponent, unclassified?.filenameComponent)
    }

    /// A stated kind outranks the shape rule in the cache tag, and this is the
    /// case where getting it wrong costs a wrong answer rather than a wrong
    /// name: Europe PMC's thesis (`ETH`) and case-report (`CBA`) records carry
    /// bare numeric accessions, so the shape rule calls them PubMed IDs. Filing
    /// one under `pmid_` would let a thesis and a genuine PubMed article with
    /// the same digits share an entry and be served each other's bytes.
    func testANumericAccessionFromAnotherSourceDoesNotShareThePubMedTag() {
        let thesis = ArticleCacheKey(
            pmid: "879809", pmcId: nil, doi: nil,
            primaryKind: .europePMCSource("eth")
        )
        let article = ArticleCacheKey(
            pmid: "879809", pmcId: nil, doi: nil,
            primaryKind: .pubmed
        )

        XCTAssertEqual(article?.filenameComponent, "pmid_879809")
        XCTAssertNotEqual(thesis?.filenameComponent, article?.filenameComponent)
    }

    // MARK: - Preprints

    /// A Europe PMC preprint carries no PMID and no PMC ID: its accession
    /// arrives in the primary slot, and it must key on that rather than fall
    /// through to the DOI. Verified against live Europe PMC — a `SRC:PPR`
    /// record answers `pmid: null, pmcid: null, id: "PPR1287966"`.
    func testAPreprintAccessionKeysOnThePrimaryRung() {
        let key = ArticleCacheKey(pmid: "PPR1287966", pmcId: nil, doi: "10.64898/2026.07.25.26358746")

        XCTAssertEqual(key?.filenameComponent, "ppr_PPR1287966")
    }

    // MARK: - Path safety

    /// An identifier reaches this type from a search result, so a value holding
    /// `/` or `..` must not be able to walk the written file out of the cache
    /// directory.
    func testAHostileIdentifierCannotEscapeTheCacheDirectory() throws {
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "../../etc/passwd", pmcId: nil, doi: nil))

        XCTAssertFalse(key.filenameComponent.contains("/"))
        XCTAssertFalse(key.filenameComponent.contains(".."))
    }

    /// Whitespace is not an identifier. A slot holding only spaces must fall
    /// through to the next rung rather than name an entry after nothing.
    func testAWhitespaceOnlyIdentifierFallsThroughToTheNextRung() {
        let key = ArticleCacheKey(pmid: "   ", pmcId: "PMC7654321", doi: nil)

        XCTAssertEqual(key?.filenameComponent, "pmc_PMC7654321")
    }

    /// A padded identifier is stored trimmed, not merely accepted.
    ///
    /// `identifierQueries` trims separately before asking Europe PMC, so an
    /// untrimmed key would have the cache filing an article under `id__12345_`
    /// while the search asked about `12345` — the same article, two names, and
    /// no error anywhere to say so.
    func testAPaddedIdentifierIsStoredTrimmed() {
        let key = ArticleCacheKey(pmid: " 12345 ", pmcId: nil, doi: nil, primaryKind: .pubmed)

        XCTAssertEqual(key?.filenameComponent, "pmid_12345")
    }

    // MARK: - One name per article

    /// Tagging keeps two *kinds* apart; this is the stronger property the cache
    /// actually needs, that two distinct *identifiers* never share a name.
    ///
    /// Sanitising maps every unsafe character to `_`, so it is not injective:
    /// `PMC/1` and `PMC_1` both sanitise to `PMC_1`. Relying on real
    /// identifiers being alphanumeric would make this a property of the data
    /// rather than of the type, and the primary slot takes whatever it is given.
    func testIdentifiersThatSanitiseIdenticallyStillGetDifferentNames() {
        let slashed = ArticleCacheKey(pmid: "PMC/1", pmcId: nil, doi: nil)
        let underscored = ArticleCacheKey(pmid: "PMC_1", pmcId: nil, doi: nil)

        XCTAssertNotEqual(slashed?.filenameComponent, underscored?.filenameComponent)
    }

    /// The readable form survives for every identifier sanitising leaves alone,
    /// which is every well-formed PMID and PMC accession. Guarding injectivity
    /// must not cost the cache a second round of invalidation, nor make a
    /// filename unreadable for the identifiers that were always safe.
    func testAWellFormedIdentifierKeepsItsReadableName() {
        XCTAssertEqual(
            ArticleCacheKey(
                pmid: "12345678", pmcId: nil, doi: nil, primaryKind: .pubmed
            )?.filenameComponent,
            "pmid_12345678"
        )
        XCTAssertEqual(
            ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: nil)?.filenameComponent,
            "pmc_PMC7654321"
        )
    }

    /// The separator the filename depends on must stay out of the identifier.
    ///
    /// ``FullTextService/cacheFilename(key:url:)`` joins this component to the
    /// source-URL fingerprint with `-`, and ``FullTextService/deleteCachedPDF(for:)``
    /// finds an article's entries by matching that `-` boundary. Were `-` or `.`
    /// ever added to the allowed set, `id_123` would begin matching `id_1234`'s
    /// entries and deleting one article's cache would take another's with it.
    func testTheFilenameSeparatorsCannotAppearInAnIdentifier() {
        XCTAssertFalse(BioMedLitConstants.cacheKeyAllowedCharacters.contains("-"))
        XCTAssertFalse(BioMedLitConstants.cacheKeyAllowedCharacters.contains("."))
    }
}
