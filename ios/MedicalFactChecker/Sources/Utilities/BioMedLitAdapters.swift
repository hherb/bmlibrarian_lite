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

import Foundation
import BioMedLit

// MARK: - Module Type Aliases
// Note: Types from the BioMedLit module are imported directly (not via BioMedLit. prefix)
// because the module has an enum called BioMedLit which causes a name collision.
// The types SearchResult, SearchArticle, PubMedService, etc. are at the module top-level.

/// Type alias for BioMedLit SearchResult to avoid collision with app types.
typealias BMLSearchResult = SearchResult

/// Type alias for BioMedLit SearchArticle to avoid collision with app types.
typealias BMLSearchArticle = SearchArticle

/// Type alias for BioMedLit SearchProvider to disambiguate from app SearchProvider.
/// Note: The app has its own SearchProvider enum in SearchProvider.swift, and BioMedLit
/// also exports SearchProvider. We use the one from BioMedLit via this alias.
typealias BMLSearchProvider = SearchProvider

/// Type alias for BioMedLit FullTextResult to disambiguate from app FullTextResult.
typealias BMLFullTextResult = FullTextResult

/// Type alias for BioMedLit FullTextSource to disambiguate from app FullTextSource.
typealias BMLFullTextSource = FullTextSource

/// Type alias for BioMedLit PubMedService.
typealias BMLPubMedService = PubMedService

/// Type alias for BioMedLit EuropePMCService.
typealias BMLEuropePMCService = EuropePMCService

/// Type alias for BioMedLit FullTextService.
typealias BMLFullTextService = FullTextService

// MARK: - Shared Utility Type Aliases

/// Type alias for BioMedLit QueryTranslator (now shared in BioMedLit package).
typealias BMLQueryTranslator = QueryTranslator

/// Type alias for BioMedLit ResponseParser (now shared in BioMedLit package).
typealias BMLResponseParser = ResponseParser

/// Type alias for BioMedLit QueryConstants (now shared in BioMedLit package).
typealias BMLQueryConstants = QueryConstants

/// Type alias for BioMedLit StructuredQuery (now shared in BioMedLit package).
typealias BMLStructuredQuery = StructuredQuery

/// Type alias for BioMedLit SearchConcept (now shared in BioMedLit package).
typealias BMLSearchConcept = SearchConcept

/// Type alias for BioMedLit DateRange (now shared in BioMedLit package).
typealias BMLDateRange = DateRange

/// Type alias for BioMedLit Verdict (now shared in BioMedLit package).
typealias BMLVerdict = Verdict

/// Type alias for BioMedLit QueryBuilderFactory (now shared in BioMedLit package).
typealias BMLQueryBuilderFactory = QueryBuilderFactory

/// Type alias for BioMedLit SearchResultMerger (now shared in BioMedLit package).
///
/// Note: Due to Swift module name collision (both MedicalFactChecker and BioMedLit
/// define SearchProvider), use `BioMedLitAdapters.buildQuery` wrapper instead of
/// calling `BMLQueryBuilderFactory.build` directly from other files.
typealias BMLSearchResultMerger = SearchResultMerger

// MARK: - Unified Article Metadata

/// Unified article metadata that normalizes data from different search providers.
///
/// This struct provides a common interface for article data regardless of source,
/// enabling consistent handling throughout the app. Each provider's response
/// format is converted to this unified representation.
struct UnifiedArticleMetadata: Sendable, Identifiable, Equatable {
    // MARK: - Identification

    /// `Identifiable` conformance for in-process use only.
    ///
    /// This is *not* a document identity and must never be persisted, written
    /// into a report, or compared across runs. It is derived from the article's
    /// own fields, which is the shape ``Document/id`` exists to avoid: two
    /// records describing one article collapse onto one value, and a record
    /// with an empty slot collapses with every other such record.
    ///
    /// The fallback was `title.hashValue`, which is worse than derived — Swift
    /// seeds `hashValue` per process, so the value differed on every launch.
    /// Deduplication does not use this; it has its own key in
    /// `SearchResultMerger.deduplicationKey(for:)`.
    var id: String { "\(source.rawValue)-\(pmid.isEmpty ? (doi ?? title) : pmid)" }

    /// PubMed ID (may be empty for preprints or non-PubMed sources).
    let pmid: String

    /// PubMed Central ID (e.g., "PMC1234567").
    let pmcId: String?

    /// Digital Object Identifier.
    let doi: String?

    // MARK: - Bibliographic Data

    /// Article title.
    let title: String

    /// Article abstract text.
    let abstract: String

    /// List of author names in display format.
    let authors: [String]

    /// Journal or source name.
    let journal: String

    /// Publication date as string (format varies by source).
    let publicationDate: String?

    /// Publication year as integer for sorting/filtering.
    let year: Int?

    // MARK: - Indexing & Classification

    /// MeSH terms (Medical Subject Headings) for the article.
    let meshTerms: [String]

    // MARK: - Source Tracking

    /// Which provider this article came from.
    let source: SearchProvider

    /// Whether this is a preprint (Europe PMC only).
    let isPreprint: Bool

    /// What kind of identifier ``pmid`` holds, when the provider said.
    ///
    /// `nil` where nothing was stated, which is what a PubMed result and every
    /// pre-#209 stored document answer. See ``ArticleIdentifierKind``.
    let identifierKind: ArticleIdentifierKind?

    /// Whether full text is available in PubMed Central.
    ///
    /// True if the article has a PMC ID or the `inPMC` flag is set.
    /// Used to show availability badge before user attempts to fetch full text.
    let hasFullTextInPMC: Bool

    /// Batch number for pagination tracking.
    let batchNumber: Int

    /// Position within search results (0-indexed).
    let resultPosition: Int

    // MARK: - Initialization

    /// Initialize unified metadata with all fields.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID.
    ///   - pmcId: PubMed Central ID.
    ///   - doi: Digital Object Identifier.
    ///   - title: Article title.
    ///   - abstract: Abstract text.
    ///   - authors: List of author names.
    ///   - journal: Journal name.
    ///   - publicationDate: Publication date string.
    ///   - year: Publication year.
    ///   - meshTerms: MeSH indexing terms.
    ///   - source: Provider that returned this article.
    ///   - isPreprint: Whether this is a preprint.
    ///   - hasFullTextInPMC: Whether full text is available in PMC.
    ///   - batchNumber: Batch number for tracking.
    ///   - resultPosition: Position in search results.
    init(
        pmid: String = "",
        pmcId: String? = nil,
        doi: String? = nil,
        title: String,
        abstract: String,
        authors: [String] = [],
        journal: String = "",
        publicationDate: String? = nil,
        year: Int? = nil,
        meshTerms: [String] = [],
        source: SearchProvider,
        isPreprint: Bool = false,
        identifierKind: ArticleIdentifierKind? = nil,
        hasFullTextInPMC: Bool = false,
        batchNumber: Int = 1,
        resultPosition: Int = 0
    ) {
        self.pmid = pmid
        self.pmcId = pmcId
        self.doi = doi
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.journal = journal
        self.publicationDate = publicationDate
        self.year = year
        self.meshTerms = meshTerms
        self.source = source
        self.isPreprint = isPreprint
        self.identifierKind = identifierKind
        self.hasFullTextInPMC = hasFullTextInPMC
        self.batchNumber = batchNumber
        self.resultPosition = resultPosition
    }
}

// MARK: - BioMedLit Adapters

/// Adapters to convert between BioMedLit types and app-local types.
///
/// This allows the app to use BioMedLit services internally while maintaining
/// backwards compatibility with existing app data models.
enum BioMedLitAdapters {
    // MARK: - Query Building (Type-Safe Wrapper)

    /// Build a query string from a StructuredQuery using the appropriate provider syntax.
    ///
    /// This wrapper function resolves the SearchProvider type collision between
    /// MedicalFactChecker and BioMedLit modules. Call this instead of
    /// `BMLQueryBuilderFactory.build` directly.
    ///
    /// - Parameters:
    ///   - query: The structured query to translate.
    ///   - provider: The app's SearchProvider enum (from MedicalFactChecker).
    /// - Returns: Provider-specific query string.
    static func buildQuery(from query: BMLStructuredQuery, for provider: MedicalFactChecker.SearchProvider) -> String {
        // Convert app SearchProvider to BioMedLit SearchProvider and build query.
        // We use the PubMedQueryBuilder and EuropePMCQueryBuilder directly to avoid
        // the type collision with QueryBuilderFactory.build(from:for:).
        switch provider {
        case .pubmed:
            return PubMedQueryBuilder.build(from: query)
        case .europePMC:
            return EuropePMCQueryBuilder.build(from: query)
        case .both:
            // Default to PubMed syntax for "both" mode
            return PubMedQueryBuilder.build(from: query)
        }
    }

    // MARK: - Search Result Conversion

    /// Convert BioMedLit SearchArticle to app UnifiedArticleMetadata.
    ///
    /// - Parameters:
    ///   - article: The BioMedLit SearchArticle.
    ///   - appProvider: App search provider to record as source.
    ///   - batchNumber: Which batch this article came from.
    ///   - resultPosition: Position in overall search results.
    /// - Returns: App-compatible UnifiedArticleMetadata.
    static func toUnifiedArticleMetadata(
        _ article: BMLSearchArticle,
        appProvider: SearchProvider,
        batchNumber: Int,
        resultPosition: Int
    ) -> UnifiedArticleMetadata {
        // Parse authors string back into array
        let authorsArray = parseAuthors(article.authors)

        return UnifiedArticleMetadata(
            pmid: article.pmid,
            pmcId: article.pmcId,
            doi: article.doi,
            title: article.title,
            abstract: article.abstract,
            authors: authorsArray,
            journal: article.journal,
            publicationDate: article.publicationDate,
            year: Int(article.year),
            meshTerms: [],  // BioMedLit doesn't parse MeSH terms yet
            source: appProvider,
            // Europe PMC states the record's kind, and `SearchArticle` now
            // carries it. Until #209 this was hard-coded `false` because nothing
            // downstream of the decode knew, which is why the preprint badge on
            // iOS had never once appeared. macOS draws no surface that reads the
            // flag yet (#210), so lighting it up here reaches one app.
            //
            // Resolved rather than compared against the stated kind alone: a
            // record that stated nothing still has a `PPR…` accession, and the
            // retrieval chain already treats such a record as a preprint via the
            // shape rule. Reading only the declared kind here would leave the
            // badge disagreeing with the ladder for exactly the records that
            // predate the field.
            isPreprint: ArticleIdentifierKind.resolved(
                declared: article.identifierKind,
                accession: article.pmid
            ) == .preprint,
            identifierKind: article.identifierKind,
            hasFullTextInPMC: article.hasFullText,
            batchNumber: batchNumber,
            resultPosition: resultPosition
        )
    }

    /// Convert BioMedLit SearchResult to app-compatible articles array.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit SearchResult.
    ///   - appProvider: App search provider to record as source.
    ///   - batchNumber: Which batch this result represents.
    ///   - basePosition: Starting position for result numbering.
    /// - Returns: Array of app-compatible UnifiedArticleMetadata.
    static func toUnifiedArticleMetadataArray(
        _ result: BMLSearchResult,
        appProvider: SearchProvider,
        batchNumber: Int,
        basePosition: Int
    ) -> [UnifiedArticleMetadata] {
        result.articles.enumerated().map { index, article in
            toUnifiedArticleMetadata(
                article,
                appProvider: appProvider,
                batchNumber: batchNumber,
                resultPosition: basePosition + index
            )
        }
    }

    // MARK: - Unified Search Result Conversion

    /// How many result positions a PubMed batch advances the offset by.
    ///
    /// BioMedLit's `nextOffset` counts the PMIDs the search consumed. Parsed
    /// articles can be fewer, since a `PubmedBookArticle` (a StatPearls chapter,
    /// say) yields none. Advancing by the article count would then re-request
    /// PMIDs already fetched, and a batch that parsed to nothing would be
    /// requested again on every "fetch more", never reaching the end.
    ///
    /// A `nil` `nextOffset` is BioMedLit saying there is no next page: the batch
    /// reached the last match, the next page would pass PubMed's offset cap, or
    /// esearch gave no usable count. The batch then advances to the end of the
    /// result set, so `hasMore` is false and a PubMed search offers no page
    /// PubMed cannot serve. A search of both providers still judges PubMed's next
    /// page against the combined total (#253).
    ///
    /// - Parameters:
    ///   - result: The BioMedLit PubMed result.
    ///   - basePosition: The offset the batch was requested at.
    ///   - articleCount: How many articles the batch produced.
    /// - Returns: The PMIDs consumed when BioMedLit states a next page, otherwise
    ///   the positions left to the end of the result set, and never fewer than
    ///   the articles the batch produced.
    static func pubMedPositionsAdvanced(
        by result: BMLSearchResult,
        basePosition: Int,
        articleCount: Int
    ) -> Int {
        guard let nextOffset = result.nextOffset, nextOffset > basePosition else {
            return max(articleCount, result.totalCount - basePosition)
        }
        return nextOffset - basePosition
    }

    /// Where PubMed's paging goes after a page.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit PubMed result.
    ///   - basePosition: The offset the page was requested at.
    ///   - articleCount: How many articles the page produced.
    /// - Returns: The state the session's PubMed paging moves to, which says
    ///   there is no next page where BioMedLit said so.
    static func pubMedPagination(
        for result: BMLSearchResult,
        basePosition: Int,
        articleCount: Int
    ) -> OffsetPaginationState {
        OffsetPaginationState(
            totalCount: result.totalCount,
            offset: basePosition,
            batchSize: pubMedPositionsAdvanced(
                by: result, basePosition: basePosition, articleCount: articleCount
            ),
            isExhausted: result.nextOffset == nil
        )
    }

    /// Where Europe PMC's paging goes after a page.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit Europe PMC result.
    ///   - basePosition: The position the page numbered its articles from.
    ///   - articleCount: How many articles the page produced.
    ///   - currentCursor: The cursor the page was requested with.
    ///   - recordsReceived: How many records the search's earlier pages held,
    ///     readable or not, or `nil` when nobody counted them.
    /// - Returns: The state the session's Europe PMC paging moves to.
    static func europePMCPagination(
        for result: BMLSearchResult,
        basePosition: Int,
        articleCount: Int,
        currentCursor: String,
        recordsReceived: Int?
    ) -> CursorPaginationState {
        CursorPaginationState(
            totalCount: result.totalCount,
            fetchedCount: basePosition + articleCount,
            // A record that could not be read still came off the cursor
            recordsReceived: recordsReceived.map { $0 + result.recordsReceived },
            currentCursor: currentCursor,
            nextCursor: result.nextCursor
        )
    }

    // MARK: - Full Text Conversion

    /// Convert BioMedLit FullTextResult to app's AppFullTextResult.
    ///
    /// - Parameter result: The BioMedLit FullTextResult.
    /// - Returns: App-compatible AppFullTextResult.
    static func toAppFullTextResult(_ result: BMLFullTextResult) -> AppFullTextResult {
        // `warnings` and `degradation` are carried across for every case, not
        // just the parsed one: both describe the *retrieval*, and a fallback that
        // dropped them would be a PDF the reader is looking at precisely because
        // the parse failed, with nothing left to say so (#183). `contentKind`,
        // `extractedText` and `localPDFPath` describe the same retrieval, so the
        // same reasoning carries them across too: Task 8 reads them off the
        // document regardless of which case produced the result.
        AppFullTextResult(
            content: content(of: result.content, localPDFPath: result.localPDFPath),
            source: appSource(of: result.content),
            warnings: result.warnings,
            degradation: result.degradation,
            contentKind: result.contentKind,
            extractedText: result.extractedText,
            localPDFPath: result.localPDFPath,
            extractionCoverage: result.extractionCoverage
        )
    }

    /// Map the package's content to the app's equivalent.
    ///
    /// - Parameters:
    ///   - content: The package-side content.
    ///   - localPDFPath: Where the service already cached this PDF, when it did.
    /// - Returns: The app-side content type.
    private static func content(
        of content: FullTextContent,
        localPDFPath: String?
    ) -> AppFullTextContentType {
        switch content {
        case .europePMC(let html, let markdown):
            // Both HTML (for rendering) and markdown (for search/export fallback)
            return .html(content: html, markdown: markdown)
        case .europePMCPDF(let pdfURL), .unpaywall(let pdfURL):
            // The cached file wins over the remote URL. The iOS viewers render
            // the live result rather than the stored document, so mapping this
            // to the remote URL sent them back over the network for bytes
            // `downloadAndExtract` had just written to disk — the second
            // download this slice removed on macOS, still present on iOS
            // because nothing there read `localPDFPath` at all.
            if let localPDFPath {
                return .pdfURL(URL(fileURLWithPath: localPDFPath))
            }
            return .pdfURL(pdfURL)
        case .doi(let webURL):
            return .webURL(webURL)
        case .cached(let filePath):
            return .pdfURL(URL(fileURLWithPath: filePath))
        }
    }

    /// Map the package's source to the app's equivalent.
    ///
    /// - Parameter content: The package-side content, which names its own source.
    /// - Returns: The app-side source.
    private static func appSource(of content: FullTextContent) -> AppFullTextSource {
        switch content {
        case .europePMC: return .europePMC
        case .europePMCPDF: return .europePMCPDF
        case .unpaywall: return .unpaywall
        case .doi: return .doi
        case .cached: return .cached
        }
    }

    // MARK: - Private Helpers

    /// Parse author string back into array.
    ///
    /// Handles both "Author1, Author2, Author3" and "Author1, Author2 et al." formats.
    private static func parseAuthors(_ authorsString: String) -> [String] {
        guard !authorsString.isEmpty else { return [] }

        // Handle "et al." case
        let cleanedString = authorsString.replacingOccurrences(of: " et al.", with: "")

        // Split by ", " but be careful with author names that contain commas
        // BioMedLit uses "LastName, FirstName" format joined by ", "
        // We need to split properly
        return cleanedString.components(separatedBy: ", ")
    }
}

// MARK: - BioMedLit Service Extensions

extension BMLPubMedService {
    /// Create a configured PubMed service from app settings.
    ///
    /// - Parameter settings: App settings containing NCBI credentials.
    /// - Returns: Configured PubMed service.
    static func create(from settings: AppSettings) -> BMLPubMedService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return BMLPubMedService(email: email, apiKey: apiKey)
    }
}

extension BMLEuropePMCService {
    /// Create a configured Europe PMC service.
    ///
    /// - Returns: Configured Europe PMC service.
    static func create() -> BMLEuropePMCService {
        return BMLEuropePMCService()
    }
}

extension BMLFullTextService {
    /// Create a configured full text service from app settings.
    ///
    /// - Parameter settings: App settings containing email for API identification.
    /// - Returns: Configured full text service.
    static func create(from settings: AppSettings) -> BMLFullTextService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        return BMLFullTextService(email: email)
    }

    /// Retrieve full text for a document, from every identifier it carries.
    ///
    /// One seam for all five fetch surfaces — two iOS views, two macOS views and
    /// the full-text tab — which ran the same call with hand-written argument
    /// lists. They had drifted four ways once before, and #186 was fixed on one
    /// of them while the others kept the defect.
    ///
    /// The stated identifier kind travels with the identifiers, which is what
    /// keeps `identifierKindToken` from being a field written for nobody: it is
    /// stored at search time and read here, days later, as the thing that says
    /// which Europe PMC source can answer for this article (#209).
    ///
    /// `resolvedIdentifierKind` rather than the stored token alone. The chain
    /// has no provider of its own, so a document whose kind is known only
    /// because a PubMed search returned it would arrive stating nothing — and
    /// since #212 nothing is what a bare decimal accession stays, which would
    /// cost every pre-#209 PubMed document its last-resort link.
    ///
    /// - Parameter document: The document to fetch for.
    /// - Returns: The retrieved content and everything the chain learned on the
    ///   way.
    /// - Throws: Whatever ``FullTextService/fetchFullText(pmcId:doi:pmid:primaryKind:)``
    ///   throws, cancellation included.
    func fetchFullText(for document: Document) async throws -> BMLFullTextResult {
        try await fetchFullText(
            pmcId: document.pmcId,
            doi: document.doi,
            pmid: document.pmid,
            primaryKind: document.resolvedIdentifierKind
        )
    }
}

/// Type alias for BioMedLit TransparencyAnalysisService.
typealias BMLTransparencyAnalysisService = TransparencyAnalysisService

extension TransparencyAnalysisService {
    /// Create a configured transparency analysis service from app settings.
    ///
    /// - Parameter settings: App settings containing NCBI credentials.
    /// - Returns: Configured transparency analysis service.
    static func create(from settings: AppSettings) -> TransparencyAnalysisService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return TransparencyAnalysisService(email: email, pubmedApiKey: apiKey)
    }

    /// Re-runs transparency analysis for a document whose full text just
    /// arrived, if the stored result was produced without one.
    ///
    /// Called from every full-text fetch site right after
    /// `Document.applyFullTextResult(_:)` succeeds, so the transparency badge
    /// catches up on its own — the reader who just fetched the full text
    /// should not also have to notice the badge is stale and press
    /// "Re-analyze" themselves. `Document.transparencyNeedsFullTextRerun`
    /// gates on there being a prior abstract-only result and a non-empty
    /// full text to hand it now, so this is a no-op for a document with no
    /// analysis yet, one already analysed with full text, or one still
    /// without usable text.
    ///
    /// Silent on failure: this runs opportunistically after a fetch the
    /// reader already asked for, and re-throwing would surface a second
    /// error alongside a full-text fetch that just succeeded.
    ///
    /// - Parameter document: The document to re-analyze, mutated in place.
    func reanalyzeAfterFullTextIfNeeded(for document: Document) async {
        guard document.transparencyNeedsFullTextRerun else { return }
        do {
            let result = try await analyze(
                doi: document.usableDOI,
                pmid: document.pubmedID,
                fullText: document.analyzableFullText
            )
            await MainActor.run {
                document.storeTransparencyResult(result)
            }
        } catch {
            // `privacy:` interpolation is not supported for this logger call in
            // the Swift toolchain used by CI, so keep the message plain while
            // retaining the essential metadata.
            AppLogger.fullText.error(
                "Automatic post-full-text transparency re-analysis failed for \(document.pmid): \(String(describing: error))"
            )
        }
    }
}
