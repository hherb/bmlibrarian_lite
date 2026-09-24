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
import OSLog
import SwiftData
import BioMedLit

/// Logger for stored-JSON encode and decode failures on ``Document``.
///
/// Declared here rather than taken from the per-platform `AppLogger`: this model
/// is compiled into the iOS app, the macOS app and the test target, and the two
/// app loggers do not share a category set.
private let documentLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.bmlibrarian.MedicalFactChecker",
    category: "Persistence"
)

/// A PubMed document retrieved for fact-checking.
///
/// Contains article metadata, relevance scoring, and extracted citations.
@Model
final class Document {
    // MARK: - Identification

    /// This row's identity, opaque and unique, assigned once at creation.
    ///
    /// It names *this document*, not the article — it is what a saved report's
    /// `doc:` reference resolves against, and what a list uses to tell two rows
    /// apart. It deliberately encodes nothing about the article, for two
    /// reasons it was `"pmid-\(pmid)"` and did both wrong.
    ///
    /// **It must be unique, and `.unique` is gone.** The attribute was dropped
    /// for CloudKit, so nothing rejects a duplicate. An identity derived from
    /// the article hands the same string to every row describing that article,
    /// and `documents.first { $0.id == documentId }` then answers with whichever
    /// comes first (#208). The degenerate case is an empty slot: `pmid` holds
    /// whatever `EuropePMCService.searchArticle(from:)` put in the primary
    /// identifier slot — a PubMed ID, a `PPR…` preprint accession or a PMC
    /// accession — and a record carrying none of them left every such document
    /// as the literal `"pmid-"`.
    ///
    /// That degenerate case is reachable rather than observed: Europe PMC always
    /// sends `id`, so the slot is never empty from a live search. 0 of 100
    /// sampled `SRC:ETH OR SRC:CBA OR SRC:HIR` records and 0 of 100 `SRC:PPR`
    /// records lacked one, measured 2026-09-11. Which case was live does not
    /// change the remedy: a UUID makes uniqueness a property of the value
    /// rather than an argument about the data, so neither case can return.
    ///
    /// **It must not claim a kind.** The slot also holds `PPR…` preprint
    /// accessions and Europe PMC thesis accessions — bare decimals
    /// indistinguishable from a PubMed ID — so `pmid-889149` invited every
    /// reader of that string to treat it as one, and the PDF exporter did,
    /// printing `(PMID: 889149)` for a thesis (#212). Ask ``citationIdentifier``
    /// for an identifier that names its own namespace.
    ///
    /// Documents stored under the old scheme keep the identity they were given:
    /// their saved reports name it, and an exact match still resolves it. Only
    /// new documents get a UUID.
    var id: String = ""
    var pmid: String = ""
    var title: String = ""
    var abstract: String = ""

    // MARK: - Metadata

    /// Document authors (stored as transformable for CoreData compatibility).
    @Attribute(.transformable(by: StringArrayTransformer.name.rawValue))
    var authors: [String] = []

    var year: Int?
    var journal: String?
    var doi: String?
    var pmcId: String?

    /// MeSH terms for the document (stored as transformable for CoreData compatibility).
    @Attribute(.transformable(by: StringArrayTransformer.name.rawValue))
    var meshTerms: [String] = []

    var publicationDate: String?

    // MARK: - Scoring

    /// LLM relevance score (1-5 scale), nil if not yet scored or if scoring failed.
    var relevanceScore: Int?

    /// LLM explanation for the relevance score.
    var scoreExplanation: String?

    /// When the document was scored by LLM.
    var scoredAt: Date?

    /// True if LLM scoring was attempted but failed to parse after all retries.
    var scoreParseFailed: Bool = false

    // MARK: - Embedding Scoring

    /// Semantic similarity score (0.0-1.0 scale) from NLEmbedding.
    ///
    /// Computed using cosine similarity between the claim and document text.
    /// Nil if embedding scoring is disabled or not yet computed.
    var embeddingScore: Double?

    /// Embedding score converted to 1-5 scale for comparison with LLM score.
    ///
    /// Mapping thresholds tuned for typical sentence embedding similarity:
    /// - < 0.3: Score 1, 0.3-0.45: Score 2, 0.45-0.55: Score 3, 0.55-0.7: Score 4, >= 0.7: Score 5
    ///
    /// Note: This logic mirrors `EmbeddingService.normalizeToRelevanceScale()`.
    /// Duplicated here to avoid service dependency in the model layer.
    var embeddingScoreNormalized: Int? {
        guard let score = embeddingScore else { return nil }
        switch score {
        case ..<0.3: return 1
        case 0.3..<0.45: return 2
        case 0.45..<0.55: return 3
        case 0.55..<0.7: return 4
        default: return 5
        }
    }

    // MARK: - Batch Tracking

    /// Which batch this document was fetched in (1-indexed).
    var batchNumber: Int = 1

    /// Position within the PubMed results (0-indexed).
    var resultPosition: Int = 0

    // MARK: - Source Tracking

    /// The search provider that returned this document.
    ///
    /// Stored as raw string value of `SearchProvider` enum:
    /// - "pubmed": PubMed/NCBI
    /// - "europePMC": Europe PMC
    /// - "both": Found by both providers (merged result)
    var searchSource: String?

    /// Whether this is a preprint (Europe PMC only).
    var isPreprint: Bool = false

    /// What kind of identifier ``pmid`` holds, as the Europe PMC source token
    /// that names it (`med`, `ppr`, `pmc`, or any other the provider sent).
    ///
    /// The slot takes whatever identifier the record had, so its value cannot
    /// say what it is. Europe PMC states the kind once, on the search result;
    /// everything that needs it — the query that can match the identifier, the
    /// PDF cache filename — happens after that record is gone. Stored, the kind
    /// is carried; unstored, it is guessed back from the accession's shape,
    /// which can only recognise the shapes it was taught (#209).
    ///
    /// `nil` means "nothing was stated", for any of four reasons: the document
    /// was written before this field existed, Europe PMC sent no `source`, the
    /// provider was PubMed, or ``ArticleIdentifierKind/unknown`` was assigned.
    /// One column cannot tell those apart, and it does not need to — all four
    /// take the same path, the shape rule, which is exactly the behaviour every
    /// document had before. Do not read `nil` as "pre-dates the field" when
    /// planning a migration or a backfill; it does not narrow that far. The
    /// same lightweight SwiftData migration, and the same reasoning, as
    /// ``fullTextContentKindRaw``.
    ///
    /// Read and written through ``identifierKind``.
    var identifierKindToken: String?

    /// ``identifierKindToken`` as the kind it names.
    ///
    /// `nil` when the record stated none. Assigning
    /// ``ArticleIdentifierKind/unknown`` clears the field rather than storing a
    /// token, because a stated absence of knowledge is not knowledge.
    var identifierKind: ArticleIdentifierKind? {
        get { ArticleIdentifierKind(europePMCSource: identifierKindToken) }
        set { identifierKindToken = newValue?.europePMCSourceToken }
    }

    /// The `SearchProvider` enum value for the stored source string.
    ///
    /// Returns `.pubmed` as default if no source is set (for backwards compatibility).
    var searchSourceEnum: SearchProvider {
        guard let source = searchSource else { return .pubmed }
        return SearchProvider(rawValue: source) ?? .pubmed
    }

    // MARK: - Full Text

    /// The full text content (markdown format for XML sources, nil for PDF-only).
    var fullTextContent: String?

    /// The full text content in HTML format (from Europe PMC XML conversion).
    ///
    /// Preferred over markdown for proper table and figure rendering.
    var fullTextHTML: String?

    /// What the JATS parse of the cached full text lost, as the versioned JSON
    /// object ``JATSParseWarnings`` encodes —
    /// `{"schemaVersion":1,"losses":[{"kind":"openFigures","count":2}]}`.
    ///
    /// A record holding the pre-#184 bare `[String]` of English log lines has no
    /// schema version, so it fails to decode and reads back as an unspecified
    /// loss rather than as a clean parse. It is rewritten from the parser on the
    /// next fetch.
    ///
    /// Persisted rather than kept on the in-flight result because full text is
    /// cached here and re-rendered from here: on macOS the viewer reads only this
    /// model, so a warning that lived only on the result would never be seen at
    /// all, and on iOS it would be shown once and lost on reopen (#181).
    ///
    /// `nil` means "nothing known" — a document cached before this field existed
    /// — and reads back as clean rather than as a truncation. Written and cleared
    /// in the same statements as the content it describes; warnings that outlive
    /// their content would label the next article with the last one's losses.
    var fullTextParseWarningsJSON: String?

    /// Why the cached full text is not the best source that existed, if it is not.
    ///
    /// The raw value of ``FullTextDegradation``. Persisted for the same reason as
    /// the warnings above: `MacFullTextViewer` renders only from this model, so a
    /// note held on the in-flight result alone would never be shown there, and on
    /// iOS would be lost on reopen.
    ///
    /// `nil` means "nothing known". For a record written since this field
    /// existed that amounts to "this is the best source we had", because only a
    /// failed parse sets it (#183). For one cached before it, a silent fallback
    /// is indistinguishable from a genuine best source — an accepted limitation,
    /// not a guarantee. Those records are rewritten on the next fetch.
    var fullTextDegradedReasonRaw: String?

    /// What the stored full text actually is, as a ``FullTextContentKind`` raw
    /// value.
    ///
    /// `nil` means "written before this field existed", which is not the same as
    /// ``FullTextContentKind/none``: such a record's text may be an article
    /// body, an abstract-only deposit, or nothing, and there is no way to tell
    /// after the fact. Those records keep the old field-population behaviour and
    /// are rewritten on the next fetch. A required field would instead strand
    /// every one of them behind a decode failure that reads as "never fetched" —
    /// the reasoning `fullTextDegradedReasonRaw` was added with.
    var fullTextContentKindRaw: String?

    /// Where this document's PDF is — either a filesystem path or, when nothing
    /// was downloaded, the remote URL string it was offered at.
    ///
    /// The field has always carried both, which is why
    /// ``fullTextPDFPathIsLocalFile`` exists beside it: the two are read with
    /// different `URL` constructors and only the writer knows which was stored.
    var fullTextPDFPath: String?

    /// Whether ``fullTextPDFPath`` holds a filesystem path rather than a remote
    /// URL string.
    ///
    /// Recorded rather than inferred. The kind alone cannot answer it: a PDF
    /// that downloaded and cached fine but yielded no text — a scan — is stored
    /// under ``FullTextContentKind/none`` with a real file on disk, and reading
    /// "is this a file?" off `contentKind == .extracted` sent exactly that
    /// record down the remote-URL branch, where `URL(string:)` turned an
    /// absolute path into a schemeless URL and the rebuilt result reported
    /// `localPDFPath: nil` for a file that was demonstrably there. Guessing from
    /// the string's shape would be the same mistake with more steps; the writer
    /// knows, so the writer says.
    ///
    /// `nil` means "written before this field existed", and such a record keeps
    /// today's behaviour exactly: it is read as a remote URL string, which is
    /// what `URL(string:)` was always applied to. Same reasoning, and the same
    /// lightweight SwiftData migration, as ``fullTextContentKindRaw`` above.
    var fullTextPDFPathIsLocalFile: Bool?

    /// Pages of the stored PDF that yielded text, or `nil` when no extraction
    /// was run.
    ///
    /// Paired with ``fullTextTotalPages``; read them through
    /// ``storedExtractionCoverage``, which returns them together or not at all.
    /// Two scalar columns rather than one encoded value because SwiftData
    /// lightweight-migrates added optional scalars, and because a `#Predicate`
    /// can compare them — the reasoning ``fullTextContentKindRaw`` was added
    /// with.
    ///
    /// `nil` means "no extraction", not "no pages". A record written before
    /// these existed also answers `nil`: its text may well be partial and there
    /// is no way to tell after the fact, so it keeps the pre-existing silence
    /// and is rewritten on the next fetch.
    var fullTextExtractedPages: Int?

    /// Pages the stored PDF holds, or `nil` when no extraction was run.
    ///
    /// See ``fullTextExtractedPages``.
    var fullTextTotalPages: Int?

    /// Source of the full text (for display and debugging).
    /// Values: "europepmc", "unpaywall", "doi"
    var fullTextSource: String?

    /// When the full text was fetched.
    var fullTextFetchedAt: Date?

    /// True if full text fetch was attempted but no source was available.
    var fullTextUnavailable: Bool = false

    /// Whether full text is known to be available in PubMed Central.
    ///
    /// Set from search results metadata (Europe PMC `inPMC` flag or presence of PMC ID).
    /// Used to display availability indicator before user attempts to fetch full text.
    var hasFullTextInPMC: Bool = false

    // MARK: - Transparency Analysis

    /// JSON-encoded transparency analysis result.
    ///
    /// Stored as String to avoid SwiftData schema migration for a new model.
    /// Decode via `transparencyResult` computed property.
    var transparencyResultJSON: String?

    /// When transparency analysis was last performed.
    var transparencyAnalyzedAt: Date?

    /// Decoded TransparencyResult from the stored JSON.
    ///
    /// Returns nil if no analysis has been performed or if decoding fails. The
    /// two cases are not the same thing, and callers that need to tell them apart
    /// should test ``hasTransparencyAnalysis`` — a decode failure is a stored
    /// result this build cannot read, not an absent one. It is logged rather than
    /// swallowed, because otherwise it presents to the user as "never analysed"
    /// and there is nothing anywhere to say why.
    var transparencyResult: TransparencyResult? {
        guard let json = transparencyResultJSON,
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(TransparencyResult.self, from: data)
        } catch {
            documentLog.error(
                """
                Stored transparency JSON failed to decode for PMID \
                \(self.pmid, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }

    /// Store a TransparencyResult as JSON.
    ///
    /// Reports whether the write happened. On the re-analysis path a silent
    /// failure leaves the previous, stale JSON in place while the UI clears its
    /// spinner and keeps showing the "re-analyze for a comparable score" notice —
    /// so the notice names a remedy the user has just watched do nothing. The
    /// caller needs to be able to say so.
    ///
    /// - Parameter result: The transparency analysis result to store.
    /// - Returns: `true` if the result was encoded and stored, `false` otherwise.
    @discardableResult
    func storeTransparencyResult(_ result: TransparencyResult) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(result)
            guard let json = String(data: data, encoding: .utf8) else {
                documentLog.error(
                    """
                    Transparency result for PMID \(self.pmid, privacy: .public) \
                    encoded to non-UTF-8 data and was not stored
                    """
                )
                return false
            }
            transparencyResultJSON = json
            transparencyAnalyzedAt = Date()
            return true
        } catch {
            documentLog.error(
                """
                Failed to encode transparency result for PMID \
                \(self.pmid, privacy: .public): \(String(describing: error), privacy: .public)
                """
            )
            return false
        }
    }

    /// Whether transparency analysis has been performed for this document.
    var hasTransparencyAnalysis: Bool {
        transparencyResultJSON != nil
    }

    /// Whether the stored analysis was produced by an older analyzer.
    ///
    /// `false` when there is no analysis at all — nothing stale to warn about.
    /// Otherwise mirrors ``TransparencyResult/isStale``: the evidence reaching the
    /// scorer changed, so the stored score cannot be read beside a current one and
    /// the UI should offer a re-run.
    ///
    /// Stored JSON that is present but will not decode counts as stale, not as
    /// absent. Treating it as absent left the document in a state it could never
    /// leave: nothing to display, nothing to warn about, and — because
    /// ``hasTransparencyAnalysis`` reads the raw string and returns `true` —
    /// permanently filtered out of re-analysis.
    var transparencyAnalysisIsStale: Bool {
        guard hasTransparencyAnalysis else { return false }
        guard let result = transparencyResult else { return true }
        return result.isStale
    }

    /// Whether transparency analysis can be attempted for this document at all.
    ///
    /// The two values the analyser is actually given, and nothing else. This is
    /// deliberately the same pair every call site passes — ``usableDOI`` and
    /// ``pubmedID`` — because `TransparencyAnalysisService.analyze` throws
    /// `noIdentifiers` when both are absent, and a gate that admits more than
    /// the analyser accepts offers the reader a button that cannot work.
    ///
    /// It read `!(pmid.isEmpty && doi == nil)`, which asks about the raw slot.
    /// The slot also holds preprint and Europe PMC thesis accessions, and since
    /// #212 those reach the analyser as `nil` rather than as a PubMed ID — so a
    /// thesis with no DOI passed this gate and threw. Not a rare shape: 60 of
    /// 100 `SRC:ETH OR SRC:CBA OR SRC:HIR` records sampled on 2026-09-11 carry
    /// no DOI.
    ///
    /// ``pmcId`` is deliberately not a third rung. The analyser has no route
    /// that starts from a PMC ID, so admitting one would re-open the gap this
    /// closes.
    ///
    /// Shared so the report views and the workflow agree on what is eligible
    /// instead of each restating it. Every caller of the analyser gates on this
    /// and then passes ``usableDOI`` and ``pubmedID`` — the same two values this
    /// tests, so the gate cannot drift from the call it guards.
    var canAnalyzeTransparency: Bool {
        pubmedID != nil || usableDOI != nil
    }

    /// ``doi`` with surrounding whitespace removed, or nil when it names nothing.
    ///
    /// The stored value arrives straight from a provider's JSON through
    /// ``applySearchMetadata(from:)``, so an empty string is representable. Both
    /// this gate and `TransparencyAnalysisService.analyze`'s own guard tested
    /// `doi != nil`, which `""` passes, and the analysis then ran against a
    /// blank DOI. That is #212's defect class one field over: a value present
    /// without naming anything. ``pubmedID`` already rejects a blank slot, so
    /// this is the pair made consistent rather than a new rule.
    var usableDOI: String? {
        guard let doi else { return nil }
        let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shortcut for badge display without full JSON decode.
    var transparencyRiskLevel: TransparencyRiskLevel? {
        transparencyResult?.riskLevel
    }

    /// How far this document's transparency rating can be relied on.
    ///
    /// The result's own record of whether the full text was analysed, when it
    /// has one. A result stored before that was recorded falls back on the
    /// document: one with no analysable full text now had none when it was
    /// analysed either, so its rating is limited. The fallback can only err
    /// towards calling a rating limited — if cached text was later removed —
    /// never towards presenting a text-less rating as full strength.
    ///
    /// `nil` when there is no readable analysis.
    var transparencyCertainty: TransparencyCertainty? {
        guard let result = transparencyResult else { return nil }
        if let searched = result.fullTextSearched {
            return TransparencyCertainty(fullTextSearched: searched)
        }
        return analyzableFullText == nil ? .limitedNoFullText : .unrecorded
    }

    /// Whether this document's high rating is shown as unassessed: every reason
    /// for it rests on statements in full text known not to have been searched. See
    /// `TransparencyRiskExplanation.isUnassessed(result:certainty:)`.
    var transparencyIsUnassessed: Bool {
        guard let result = transparencyResult else { return false }
        return TransparencyRiskExplanation.isUnassessed(result: result, certainty: transparencyCertainty)
    }

    /// The documents rated high transparency risk, as a report discusses them.
    ///
    /// The same documents the report's "flagged as high transparency risk"
    /// count covers, so the count and the discussion never disagree. Ordered
    /// by reference, then title: a session's documents are an unordered
    /// relationship, and a report should list them the same way every time.
    ///
    /// - Parameter documents: A session's documents.
    /// - Returns: One entry per document rated high and not shown as
    ///   unassessed, with why it was rated high.
    static func highRiskTransparencyEntries(in documents: [Document]) -> [HighRiskTransparencyEntry] {
        documents
            .compactMap { document -> (Document, TransparencyResult)? in
                // A rating shown as unassessed is not discussed as high risk.
                guard let result = document.transparencyResult, result.riskLevel == .high,
                      !document.transparencyIsUnassessed else {
                    return nil
                }
                return (document, result)
            }
            .sorted { ($0.0.shortReference, $0.0.displayTitle) < ($1.0.shortReference, $1.0.displayTitle) }
            .map { document, result in
                HighRiskTransparencyEntry(
                    reference: document.shortReference,
                    citation: [document.displayTitle, document.journal, document.citationIdentifier?.labelled]
                        .compactMap { $0 }
                        .joined(separator: ". "),
                    result: result,
                    certainty: document.transparencyCertainty
                )
            }
    }

    /// Whether this document holds a stored analysis this build cannot read.
    ///
    /// Such a result is neither absent nor rated: a report must say it could
    /// not be read rather than leave the study out of every count.
    var transparencyResultIsUnreadable: Bool {
        hasTransparencyAnalysis && transparencyResult == nil
    }

    // MARK: - Relationships

    var session: FactCheckSession?

    @Relationship(deleteRule: .cascade, inverse: \Citation.document)
    var citations: [Citation]? = []

    // MARK: - Initialization

    /// Creates a new document from PubMed metadata.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier.
    ///   - title: Article title.
    ///   - abstract: Article abstract text.
    ///   - authors: Author names (defaults to empty).
    ///   - batchNumber: Which batch this document was fetched in (1-indexed).
    ///   - resultPosition: Position within search results (0-indexed).
    init(
        pmid: String,
        title: String,
        abstract: String,
        authors: [String] = [],
        batchNumber: Int = 1,
        resultPosition: Int = 0
    ) {
        self.id = UUID().uuidString
        self.pmid = pmid
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.batchNumber = batchNumber
        self.resultPosition = resultPosition
    }

    /// Copy everything a search result knows about this article onto it.
    ///
    /// One writer rather than a field-by-field copy at each call site. The
    /// workflow builds documents in three places, and every field it copied by
    /// hand had to be remembered three times; the kind and the preprint flag are
    /// the two that arrived after those blocks were written. This is the same
    /// reason `applyFullTextResult` exists: a direct assignment at one site is
    /// how another site quietly keeps the old behaviour — which is exactly what
    /// happened to the alternative-query path, converted last and only after a
    /// review found it still hand-copying.
    ///
    /// - Parameters:
    ///   - metadata: The search result to copy from.
    ///   - provider: The provider that returned it, recorded as
    ///     ``searchSource``.
    func applySearchMetadata(_ metadata: UnifiedArticleMetadata, provider: SearchProvider) {
        year = metadata.year
        journal = metadata.journal
        doi = metadata.doi
        pmcId = metadata.pmcId
        meshTerms = metadata.meshTerms
        publicationDate = metadata.publicationDate
        isPreprint = metadata.isPreprint
        identifierKind = metadata.identifierKind
        searchSource = provider.rawValue
    }

    // MARK: - Computed Properties

    /// Title with HTML entities decoded and tags stripped for display.
    ///
    /// PubMed and Europe PMC titles often contain HTML entities (`&lt;i&gt;`)
    /// and formatting tags (`<i>`, `<sup>`) that should be rendered as plain text.
    var displayTitle: String {
        decodeHTMLEntities(title)
    }

    /// Formatted author string for display.
    var formattedAuthors: String {
        guard !authors.isEmpty else { return "Unknown" }
        if authors.count <= 3 {
            return authors.joined(separator: ", ")
        }
        return "\(authors[0]) et al."
    }

    /// Short reference format for citations.
    var shortReference: String {
        let authorPart: String
        if let firstAuthor = authors.first {
            // Extract surname (before comma in "LastName, FirstName" format)
            let surname = firstAuthor.components(separatedBy: ", ").first ?? firstAuthor
            authorPart = authors.count > 1 ? "\(surname) et al." : surname
        } else {
            authorPart = "Unknown"
        }
        let yearPart = year.map { String($0) } ?? "n.d."
        return "\(authorPart), \(yearPart)"
    }

    /// Check if document meets relevance threshold.
    ///
    /// Uses hardcoded threshold of 3 for SwiftData compatibility.
    /// The workflow uses `AppSettings.minScoreThreshold` for filtering.
    var isRelevant: Bool {
        guard let score = relevanceScore else { return false }
        return score >= 3
    }

    /// Check if document meets a specific score threshold.
    ///
    /// - Parameter threshold: Minimum score to consider relevant (1-5).
    /// - Returns: True if scored and score >= threshold.
    func meetsThreshold(_ threshold: Int) -> Bool {
        guard let score = relevanceScore else { return false }
        return score >= threshold
    }

    /// Check if document has been scored (or scoring was attempted but failed).
    var isScored: Bool {
        relevanceScore != nil || scoreParseFailed
    }

    // MARK: - Full Text Computed Properties

    /// Whether full text is available for this document.
    var hasFullText: Bool {
        fullTextHTML != nil || fullTextContent != nil || fullTextPDFPath != nil
    }

    /// Whether we've already tried to fetch full text (success or failure).
    var fullTextAttempted: Bool {
        fullTextFetchedAt != nil || fullTextUnavailable
    }

    /// Whether this document was fetched and nothing displayable came back.
    ///
    /// What a publisher-link fallback stores: a web URL is opened in a browser
    /// rather than held as text, so ``hasFullText`` is false even though the
    /// whole chain ran. Without this the iOS list shows such a record a download
    /// button and it reads as never-fetched (#187) — which is also the state in
    /// which a retrieval note has the most to say and the least chance of being
    /// seen, since there is no content to open a viewer with.
    ///
    /// Distinct from ``fullTextUnavailable``, which is the chain reporting that
    /// no source had anything at all.
    ///
    /// The predicate tests the *effect* — a date with nothing displayable behind
    /// it — because that is what the reader is actually looking at. Anything
    /// that later clears the cached content without clearing
    /// ``fullTextFetchedAt`` (a sync eviction, a cache trim) would make an
    /// evicted record read as link-only and show a stale retrieval note. Clear
    /// the date alongside the content, as ``clearFullTextCache()`` does.
    var isLinkOnly: Bool {
        fullTextAttempted && !hasFullText && !fullTextUnavailable
    }

    /// Where to send a reader whose full text is only reachable in a browser.
    ///
    /// The publisher's DOI page when there is a DOI, and the PubMed record
    /// otherwise — mirroring the chain's own last two fallbacks, so the card
    /// offers a route to the same place the retrieval settled on.
    ///
    /// The PubMed half is not a nicety. A `.webURL` result caches no content, so
    /// the URL the chain resolved is gone after the fetch, and a DOI-less record
    /// gated on the DOI alone had no route at all — the reader was shown a note
    /// saying a substitute exists and no way to reach it (#187). Empty strings
    /// are treated as absent, because `doiURL(for: "")` resolves to the DOI
    /// resolver's front page.
    var fullTextLinkDestination: URL? {
        if let doi = doi, !doi.isEmpty, let url = PlatformHelper.doiURL(for: doi) {
            return url
        }
        return pubmedURL
    }

    /// Why this record offers no browser link, for a card that would show one.
    ///
    /// `nil` whenever ``fullTextLinkDestination`` answers a URL, so a caller can
    /// render this in the `else` and never show both.
    ///
    /// Gating the PubMed fallback on a *stated* kind (#212) made this state
    /// reachable for the first time: a record with no DOI whose identifier
    /// nothing vouches for now has no destination at all. Rendering nothing
    /// there recreates #187 exactly — a notice saying a substitute exists,
    /// above the empty space where the way to reach it used to be. The reader
    /// is told what happened and given the accession to search with, which is
    /// the one thing the app still knows to be true about the record.
    var unresolvableIdentifierNotice: String? {
        guard fullTextLinkDestination == nil else { return nil }
        let identifier = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            return "This record carries no identifier that can be looked up."
        }
        return """
            This record's identifier could not be confirmed as a PubMed ID, so \
            no lookup link is offered. Search Europe PMC for \(identifier).
            """
    }

    // MARK: - PubMed Identity

    /// The provider that returned this record, as the package names it.
    ///
    /// A straight mapping, `both` included — the package models a merged search
    /// too (`BioMedLit.SearchProvider.both`), and what matters is that the value
    /// arrives at the resolver unflattened. Collapsing `both` to `.pubmed`, as
    /// an earlier adapter did, would have a merged search vouch for every
    /// document it produced including the ones only Europe PMC returned, which
    /// is the defect this property exists to close (#212). The resolver refuses
    /// to let `both` vouch for anything; that decision is only available to it
    /// if `both` is still legible when it gets there.
    ///
    /// `nil` where nothing was recorded. Documents predating provider tracking
    /// have no source, and the app guesses one for the provider badge; a guess
    /// is fine for a badge and is not fine for a link, so nothing is guessed
    /// here. Note the asymmetry with ``searchSourceEnum``, which *does* fall
    /// back to `.pubmed` for those rows: that fallback feeds display only, and
    /// unifying the two would silently reopen #212 for the oldest documents in
    /// the store.
    private var recordedProvider: BioMedLit.SearchProvider? {
        switch searchSource {
        case SearchProvider.pubmed.rawValue: return .pubmed
        case SearchProvider.europePMC.rawValue: return .europePMC
        case SearchProvider.both.rawValue: return .both
        default: return nil
        }
    }

    /// What is known about what ``pmid`` holds.
    ///
    /// The record's stated kind, the identifier's shape where a prefix settles
    /// it, and finally the provider — a PubMed search vouches for a bare decimal
    /// that nothing else names, which is what keeps documents stored before the
    /// kind field existed reaching their PubMed record.
    ///
    /// This, not ``identifierKind``, is what the retrieval chain is given: the
    /// chain has no provider of its own, so a document that resolved its kind
    /// only from the provider would arrive with nothing stated and be guessed
    /// about all over again.
    var resolvedIdentifierKind: ArticleIdentifierKind {
        ArticleIdentifierKind.resolved(
            declared: identifierKind,
            accession: pmid,
            provider: recordedProvider
        )
    }

    /// ``pmid`` when it really is a PubMed ID, and `nil` otherwise.
    var pubmedID: String? {
        ArticleIdentifierKind.pubmedID(in: pmid, declared: resolvedIdentifierKind)
    }

    /// This article's PubMed record, when it has one that can be named.
    ///
    /// The one accessor every PubMed link in either app goes through. Nine
    /// surfaces used to paste ``pmid`` after the base URL directly, so a
    /// preprint was offered a 404, an identifier-less record was offered
    /// PubMed's front page as its own full text, and a Europe PMC thesis
    /// accession — a bare decimal, indistinguishable from a PubMed ID — was
    /// offered a **real but unrelated article** (#212, #213).
    ///
    /// Optional, and never force-unwrapped: five of those surfaces wrote
    /// `URL(string:)!` over a network-supplied value, and `URL(string:)` answers
    /// `nil` for a string containing a space, so drawing a context menu over
    /// such a document brought the app down.
    var pubmedURL: URL? {
        guard let pubmedID else { return nil }
        return PlatformHelper.pubmedURL(for: pubmedID)
    }

    /// The identifier line for a citation, naming the namespace that resolves it.
    ///
    /// A citation outlives the app — it goes into an exported report someone
    /// else reads — so `PMID: PPR1287966` is the most consequential form a
    /// fabricated identifier takes. Each kind is named as what it is instead,
    /// and where neither the record nor the provider names a namespace there is
    /// no honest label to print: a bare number under any label invites the
    /// reader to take it for a PubMed ID.
    ///
    /// The one exception to "the kind names the namespace" is ``/BioMedLit/ArticleIdentifierKind/unknown``
    /// on a Europe PMC record: nothing stated the kind, but the search that
    /// returned it can still resolve the accession, so the *provider* names the
    /// namespace where the kind cannot. A record from any other search, or from
    /// none, gets no label — see ``recordedProvider`` for why a merged search is
    /// not allowed to speak here either.
    var citationIdentifier: CitationIdentifier? {
        let identifier = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        switch resolvedIdentifierKind {
        case .pubmed:
            guard let pubmedID else { return nil }
            return .pubMed(pubmedID)
        case .pmc:
            return .pmc(identifier)
        case .preprint, .europePMCSource:
            return .europePMC(identifier)
        case .unknown:
            guard recordedProvider == .europePMC else { return nil }
            return .europePMC(identifier)
        }
    }

    /// Display name for the full text source.
    var fullTextSourceDisplay: String? {
        guard let source = fullTextSource else { return nil }
        switch source {
        case "europepmc": return "Europe PMC"
        case "unpaywall": return "Unpaywall"
        case "doi": return "Publisher"
        case "cached": return "Cached"
        default: return source.capitalized
        }
    }

    /// Full citation string for references section.
    var fullCitation: String {
        var parts: [String] = []
        parts.append(formattedAuthors)
        if let year = year {
            parts.append("(\(year))")
        }
        parts.append(title)
        if let journal = journal {
            parts.append("*\(journal)*")
        }
        if let citationIdentifier {
            parts.append(citationIdentifier.labelled)
        }
        return parts.joined(separator: ". ")
    }

    /// The `AppFullTextSource` enum value for the stored source string.
    ///
    /// Returns nil if no source is set or if the string doesn't match a known source.
    var fullTextSourceEnum: AppFullTextSource? {
        guard let source = fullTextSource else { return nil }
        return AppFullTextSource(rawValue: source)
    }

    /// SF Symbol icon name for the full text source.
    var fullTextSourceIcon: String? {
        fullTextSourceEnum?.iconName
    }

    // MARK: - Full Text Update Methods

    /// Update the document with a successful full text result.
    ///
    /// - Parameter result: The full text retrieval result.
    func applyFullTextResult(_ result: AppFullTextResult) {
        fullTextSource = result.source.rawValue
        fullTextFetchedAt = Date()
        fullTextUnavailable = false
        storeParseWarnings(result.warnings)
        // Cleared, not merely set: an upload or a re-fetch that succeeded must
        // not inherit the previous attempt's note. Assigning these by hand at
        // each call site is what let the cache and the live result drift apart.
        fullTextDegradedReasonRaw = result.degradation?.rawValue
        fullTextContentKindRaw = result.contentKind.rawValue
        storeExtractionCoverage(result.extractionCoverage)

        switch result.content {
        case .markdown(let content):
            fullTextContent = content
            fullTextHTML = nil
            storePDFPath(nil, isLocalFile: false)
        case .html(let htmlContent, let markdownContent):
            fullTextHTML = htmlContent
            fullTextContent = markdownContent
            storePDFPath(nil, isLocalFile: false)
        case .pdfURL(let url):
            // The cached file when there is one, so the viewer opens a real
            // path. Before extraction existed this held the *remote URL*, which
            // read as "retrieved" and was handed to `URL(string:)` by every
            // consumer that thought it had a file. The remote URL falls back
            // only when nothing was downloaded, which is what the extraction
            // flag being off looks like — and which of the two was stored is
            // recorded rather than left to be inferred later.
            if let localPath = result.localPDFPath {
                storePDFPath(localPath, isLocalFile: true)
            } else {
                storePDFPath(url.absoluteString, isLocalFile: false)
            }
            // Prose recovered from the PDF, which is what transparency
            // analysis reads. `nil` for a scan or a failed extraction, exactly
            // as before.
            fullTextContent = result.extractedText
            fullTextHTML = nil
        case .webURL:
            // Web URLs don't store content locally
            fullTextContent = nil
            fullTextHTML = nil
            storePDFPath(nil, isLocalFile: false)
        }
    }

    /// Store a PDF path together with what kind of path it is.
    ///
    /// One writer for the pair, so the flag cannot be left describing a path
    /// that has since been replaced — the drift that a second, independent
    /// assignment invites.
    ///
    /// - Parameters:
    ///   - path: The filesystem path or remote URL string, or `nil` to clear.
    ///   - isLocalFile: Whether `path` is a file on disk. Ignored when `path`
    ///     is `nil`, which clears the flag too.
    private func storePDFPath(_ path: String?, isLocalFile: Bool) {
        fullTextPDFPath = path
        fullTextPDFPathIsLocalFile = path == nil ? nil : isLocalFile
    }

    /// Store an extraction's coverage, or clear it.
    ///
    /// One writer for the pair, for the reason ``storePDFPath(_:isLocalFile:)``
    /// is: two counts written independently can be left describing different
    /// extractions, and a coverage figure that disagrees with the text beside it
    /// tells the reader a precise, wrong thing.
    ///
    /// - Parameter coverage: The figure to store, or `nil` to clear both counts.
    private func storeExtractionCoverage(_ coverage: PDFExtractionCoverage?) {
        fullTextExtractedPages = coverage?.convertedPages
        fullTextTotalPages = coverage?.pageCount
    }

    /// The persisted extraction coverage, or `nil` when none was recorded.
    ///
    /// Answers `nil` unless *both* counts are present. A half-written pair is a
    /// record we cannot describe, and reporting "0 of 12 pages" for it would
    /// invent a figure rather than admit to not having one.
    private var storedExtractionCoverage: PDFExtractionCoverage? {
        guard let converted = fullTextExtractedPages, let total = fullTextTotalPages else {
            return nil
        }
        return PDFExtractionCoverage(convertedPages: converted, pageCount: total)
    }

    /// Mark the document as having no full text available.
    func markFullTextUnavailable() {
        fullTextUnavailable = true
        fullTextFetchedAt = nil
        fullTextContent = nil
        fullTextHTML = nil
        fullTextPDFPath = nil
        fullTextPDFPathIsLocalFile = nil
        fullTextSource = nil
        fullTextParseWarningsJSON = nil
        fullTextDegradedReasonRaw = nil
        fullTextContentKindRaw = nil
        storeExtractionCoverage(nil)
    }

    /// Clear cached full text data to allow re-fetching.
    func clearFullTextCache() {
        fullTextContent = nil
        fullTextHTML = nil
        fullTextPDFPath = nil
        fullTextPDFPathIsLocalFile = nil
        fullTextSource = nil
        fullTextFetchedAt = nil
        fullTextUnavailable = false
        fullTextParseWarningsJSON = nil
        fullTextDegradedReasonRaw = nil
        fullTextContentKindRaw = nil
        storeExtractionCoverage(nil)
    }

    // MARK: - Cached Full Text

    /// Which of the stored fields answers "what do we show the reader" —
    /// the single place that decision is made.
    ///
    /// `cachedFullTextResult` below and `MacFullTextViewer.renderedContent`
    /// both need it, and used to decide it independently: `MacFullTextViewer`
    /// re-implements its own loading/error/empty states around the content,
    /// so it could not simply call `cachedFullTextResult`, and instead
    /// re-read the same stored fields in the same field-population order.
    /// That was harmless while `fullTextContent` was only ever set for a
    /// parsed article — until extraction started populating it with recovered
    /// PDF prose too, and only one of the two copies was taught to check the
    /// content kind before falling through to it. The other kept showing the
    /// prose, silently dropping the figures, tables and layout the PDF was
    /// kept for. Two independent copies of one display rule is exactly the
    /// shape that had already drifted once, across four retrieval surfaces
    /// instead of two — see the HANDOVER note on that.
    ///
    /// Extraction serves *analysis*: `fullTextContent` holds the recovered
    /// prose for a PDF whose ``storedContentKind`` is
    /// ``FullTextContentKind/extracted``, which is what the transparency
    /// analyzer reads — through ``analyzableFullText``, the only consumer that
    /// treats stored text as an article body. Display still prefers the
    /// document, so that case is resolved — and answered as a PDF — before
    /// the ordinary field-population fallback below gets a chance to hand
    /// back the same text as prose.
    var displayedFullText: DisplayedFullText {
        if storedContentKind == .extracted, let path = fullTextPDFPath {
            return storedPDF(at: path)
        } else if let html = fullTextHTML {
            return .html(html, markdown: fullTextContent ?? "")
        } else if let markdown = fullTextContent {
            return .markdown(markdown)
        } else if let path = fullTextPDFPath {
            return storedPDF(at: path)
        } else {
            return .none
        }
    }

    /// Which kind of PDF reference ``fullTextPDFPath`` is holding.
    ///
    /// Read off ``fullTextPDFPathIsLocalFile`` rather than off the content
    /// kind or the shape of the string. A record predating that flag answers
    /// `false`, which is what `URL(string:)` was always applied to and so
    /// leaves those records behaving exactly as they did.
    private func storedPDF(at path: String) -> DisplayedFullText {
        fullTextPDFPathIsLocalFile == true
            ? .localPDF(path: path)
            : .remotePDFLink(urlString: path)
    }

    /// The filesystem path of this document's PDF, or `nil` when what is stored
    /// is a remote link rather than a file.
    ///
    /// For the actions that need a *file* — reveal it in Finder, hand it to
    /// Preview.app — rather than something to render. Those asked
    /// ``fullTextPDFPath`` for a non-`nil` value and then built a file URL from
    /// it, which is the guess ``fullTextPDFPathIsLocalFile`` was added to
    /// replace: when nothing was downloaded, that field holds a remote URL
    /// string, and `file:///…/https:/example.org/paper.pdf` is what Finder was
    /// being handed. The menu item was offered and did nothing at all.
    /// Read off the flag rather than off ``displayedFullText``, deliberately.
    /// Whether a file exists is not a display decision: a record whose display
    /// rule picks the HTML rendering may still have a cached PDF worth
    /// revealing, and routing this through the display rule would make "can I
    /// open this file" depend on which of several renderings won. Same rule as
    /// ``cachedFullTextResult``'s `localPDFPath`, and the same one writer keeps
    /// the flag honest.
    var localPDFFilePath: String? {
        fullTextPDFPathIsLocalFile == true ? fullTextPDFPath : nil
    }

    /// The stored full text an analyzer may treat as the article's body, or
    /// `nil` when there is none.
    ///
    /// The single place the content kind is consulted for analysis, read by
    /// `FactCheckWorkflow`, `ReportView` and `MacReportView` alike. Three
    /// copies of one rule is the shape this slice already had to correct twice
    /// — once across four retrieval surfaces, once across two display surfaces
    /// — so the rule is stated once and the call sites ask.
    ///
    /// An abstract-only Europe PMC deposit answers `nil`. Such a record's
    /// stored text is the abstract and nothing else: the deposit carries
    /// `<front>` and `<back>` but no `<body>`, which is why the retrieval chain
    /// labels it ``FullTextContentKind/abstract`` and holds it behind every PDF
    /// tier in the first place. Handing it over as article text is what the
    /// holdback exists to prevent, and it does not stop being a misuse just
    /// because no PDF tier answered and the abstract was returned after all —
    /// the transparency extractors would read a funding or COI sentence out of
    /// abstract prose and store a verdict about a body they never saw. bmlib
    /// takes the same line: a body-less rendering contains no article text.
    ///
    /// Every other kind is offered. Extracted PDF prose *is* the article, and a
    /// `nil` kind means "written before this field existed", which keeps its
    /// pre-existing behaviour rather than being newly withheld.
    ///
    /// The abstract is not lost — `abstract` holds it, and the analyzer is
    /// given the identifiers it uses to fetch registry and CrossRef metadata
    /// either way. What it stops getting is an abstract dressed as a body.
    var analyzableFullText: String? {
        storedContentKind == .abstract ? nil : fullTextContent
    }

    /// The cached full text, rebuilt as a result the viewers can render.
    ///
    /// One place rather than four: `FullTextTab`, `ScoredDocumentsView` and
    /// `ReportView` each rebuilt this inline, and every copy defaulted the
    /// warnings to clean, so a truncated article reopened from the cache
    /// rendered exactly like a complete one.
    ///
    /// Its content branch comes from ``displayedFullText``, the same property
    /// `MacFullTextViewer.renderedContent` consults, so the two cannot pick
    /// different content for the same document. `MacFullTextViewer` still
    /// places its own loading, error and empty states around that content,
    /// and still hands `MacPDFView` a filesystem path rather than the `URL`
    /// this type carries — those stay per-view concerns.
    ///
    /// `nil` when nothing displayable is cached. Do not read the banner's
    /// inputs through this property — use ``cachedRetrievalNotice``, which
    /// survives that `nil`.
    var cachedFullTextResult: AppFullTextResult? {
        let source = storedFullTextSource
        let content: AppFullTextContentType
        switch displayedFullText {
        case .html(let html, let markdown):
            content = .html(content: html, markdown: markdown)
        case .markdown(let markdown):
            content = .markdown(markdown)
        case .localPDF(let path):
            content = .pdfURL(URL(fileURLWithPath: path))
        case .remotePDFLink(let urlString):
            // Nothing was downloaded, so the stored value is the link itself.
            guard let url = URL(string: urlString) else { return nil }
            content = .pdfURL(url)
        case .none:
            return nil
        }
        return AppFullTextResult(
            content: content,
            source: source,
            warnings: storedParseWarnings,
            degradation: storedDegradation,
            contentKind: storedContentKind ?? .none,
            extractedText: storedContentKind == .extracted ? fullTextContent : nil,
            // Every stored path that is a file, not only the ones extraction
            // got text out of. A scan downloads and caches like any other PDF,
            // and reporting `nil` for it told the viewer there was no file to
            // open when there plainly was one.
            localPDFPath: fullTextPDFPathIsLocalFile == true ? fullTextPDFPath : nil,
            // Gated on there being a PDF, not on the kind: a scan stores
            // `.none` and still has a coverage figure worth reporting — `0` of
            // however many pages. What the gate excludes is a parsed article,
            // whose text was never extracted from anything.
            extractionCoverage: fullTextPDFPath == nil ? nil : storedExtractionCoverage
        )
    }

    /// What to tell the reader about how this document's full text was
    /// retrieved, whether or not any of it can be rendered.
    ///
    /// Deliberately not read through ``cachedFullTextResult``. That property
    /// rebuilds a *renderable* result and answers `nil` when no content was
    /// cached — which is exactly what a publisher-link fallback stores, because
    /// a web URL is opened in a browser rather than held as text. Reading the
    /// banner's inputs through it therefore threw away the degradation on the
    /// one outcome it was added for: Europe PMC had the machine-readable copy,
    /// this parser could not read it, and the chain fell through to a link. The
    /// reader was then told the article has no full text — #183's conclusion
    /// inverted, and cached, so every reopen repeated it.
    ///
    /// All three facts are read straight from the stored fields, so a record
    /// with no displayable content still speaks.
    ///
    /// The extraction coverage joins them for the same reason the other two are
    /// here: `MacFullTextViewer` renders only from this model, so a figure held
    /// on the in-flight result alone would never reach the reader there, and on
    /// iOS would be lost on reopen — which is how a partial extraction came to
    /// be shown exactly like a whole article.
    var cachedRetrievalNotice: (
        warnings: JATSParseWarnings,
        degradation: FullTextDegradation?,
        extractionCoverage: PDFExtractionCoverage?
    ) {
        (
            storedParseWarnings,
            storedDegradation,
            fullTextPDFPath == nil ? nil : storedExtractionCoverage
        )
    }

    /// The cached source, defaulting to ``AppFullTextSource/cached``.
    ///
    /// An unrecognised stored value is logged rather than quietly relabelled:
    /// this drives the provenance shown to the reader, and a record written by a
    /// newer build displaying as "Cached" asserts a source we do not actually
    /// know. The two accessors below take the same line for their own fields.
    private var storedFullTextSource: AppFullTextSource {
        guard let raw = fullTextSource else { return .cached }
        guard let source = AppFullTextSource(rawValue: raw) else {
            documentLog.error(
                """
                Unrecognised full-text source \(raw, privacy: .public) for PMID \
                \(self.pmid, privacy: .public); showing it as cached.
                """
            )
            return .cached
        }
        return source
    }

    /// What the cached parse lost, or clean when nothing was recorded.
    ///
    /// An undecodable field is *not* clean. The field is only ever written when
    /// a parse lost something, so "we cannot read it" and "nothing was lost" are
    /// opposite answers, and collapsing them presents a truncated article as
    /// complete — the one failure this whole channel exists to prevent. It
    /// reports an unspecified loss instead, and says so in the log.
    private var storedParseWarnings: JATSParseWarnings {
        guard let json = fullTextParseWarningsJSON else { return JATSParseWarnings() }
        do {
            return try JSONDecoder().decode(JATSParseWarnings.self, from: Data(json.utf8))
        } catch {
            // Also the path a record written before the losses were typed takes:
            // it holds a bare array of the old English lines, which has no
            // schema version and so cannot decode. Mapping those sentences back
            // to cases would re-create, in a persisted format, exactly the
            // wording coupling #184 removed. The record is rewritten from the
            // parser on the next fetch.
            documentLog.error(
                """
                Stored parse warnings failed to decode for PMID \
                \(self.pmid, privacy: .public): \(String(describing: error), privacy: .public). \
                Reporting an unspecified loss rather than a clean parse.
                """
            )
            return JATSParseWarnings(losses: [.unspecified])
        }
    }

    /// Why the cached source is not the best one that existed, or `nil`.
    ///
    /// An unrecognised value is *not* "no degradation". The field is only ever
    /// written when a better source was lost, so a raw value this build does not
    /// know — one written by a newer build — still means something was lost, and
    /// reporting none would tell the reader the publisher had no machine-readable
    /// text when we know otherwise.
    ///
    /// It reports ``FullTextDegradation/unspecified``, which says exactly that
    /// and no more. Naming a specific reason would be a guess, and the reason it
    /// used to guess — a failed parse — blames our own parser for a shortfall we
    /// cannot attribute (#186).
    private var storedDegradation: FullTextDegradation? {
        guard let raw = fullTextDegradedReasonRaw else { return nil }
        if let known = FullTextDegradation(rawValue: raw) { return known }
        documentLog.error(
            """
            Unrecognised full-text degradation \(raw, privacy: .public) stored for PMID \
            \(self.pmid, privacy: .public); reporting an unspecified one rather than none.
            """
        )
        return .unspecified
    }

    /// The persisted content kind, or `nil` for a record that predates it.
    ///
    /// An unrecognised value — a record written by a newer build — reads as
    /// `nil` rather than as a guess, so it falls back to field-population order
    /// instead of claiming a kind this build does not understand.
    private var storedContentKind: FullTextContentKind? {
        guard let raw = fullTextContentKindRaw else { return nil }
        if let known = FullTextContentKind(rawValue: raw) { return known }
        documentLog.error(
            """
            Unrecognised full-text content kind \(raw, privacy: .public) stored for PMID \
            \(self.pmid, privacy: .public); falling back to field-population order.
            """
        )
        return nil
    }

    /// The persisted form of "something was lost and this record cannot say
    /// what".
    ///
    /// Written when the real warnings could not be encoded. Encoding the case
    /// rather than storing a sentinel keeps the stored payload well-formed, so
    /// it reads back through the ordinary decode path as the loss it means
    /// instead of relying on a second failure to convey it.
    private static var unspecifiedWarningsJSON: String {
        let unspecified = JATSParseWarnings(losses: [.unspecified])
        guard let data = try? JSONEncoder().encode(unspecified),
              let json = String(data: data, encoding: .utf8)
        else {
            // One payload-free case cannot realistically fail to encode. If it
            // somehow does, any value this build cannot decode still reads back
            // as an unspecified loss, which is the answer we want anyway.
            return "unencodable"
        }
        return json
    }

    /// Record what a parse lost, clearing the field when it lost nothing.
    ///
    /// A clean parse and a failed encode are kept apart: the first is the reason
    /// the field is cleared, the second is a loss that could not be written down
    /// and is logged rather than silently downgraded to "clean".
    ///
    /// - Parameter warnings: The warnings from the parse being cached.
    private func storeParseWarnings(_ warnings: JATSParseWarnings) {
        guard !warnings.isClean else {
            fullTextParseWarningsJSON = nil
            return
        }
        guard let data = try? JSONEncoder().encode(warnings),
              let json = String(data: data, encoding: .utf8)
        else {
            documentLog.error(
                """
                Parse warnings for PMID \(self.pmid, privacy: .public) could not be encoded; \
                \(warnings.losses.count, privacy: .public) loss(es) \
                will not survive the cache. Recording an unspecified loss.
                """
            )
            // Not `nil`, which reads back as clean. Something *was* lost — that
            // is why we are past the guard above — so the honest record is one
            // that says so without saying what. A payload this build cannot
            // decode is precisely how `storedParseWarnings` spells that, so a
            // deliberately unreadable value carries the meaning exactly.
            fullTextParseWarningsJSON = Self.unspecifiedWarningsJSON
            return
        }
        fullTextParseWarningsJSON = json
    }

    // MARK: - Private Helpers

    /// Decodes HTML entities and removes HTML tags for plain text display.
    ///
    /// Handles common entities found in PubMed/Europe PMC titles:
    /// - Named entities: `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`, `&nbsp;`
    /// - Numeric entities: `&#60;`, `&#x3C;`
    /// - HTML tags: `<i>`, `</i>`, `<b>`, `<sup>`, etc.
    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string

        // Named HTML entities
        let namedEntities: [String: String] = [
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&nbsp;": " ",
            "&ndash;": "–",
            "&mdash;": "—",
            "&lsquo;": "'",
            "&rsquo;": "'",
            "&ldquo;": "\u{201C}",
            "&rdquo;": "\u{201D}",
            "&hellip;": "…",
            "&deg;": "°",
            "&plusmn;": "±",
            "&times;": "×",
            "&divide;": "÷",
            "&micro;": "µ",
            "&alpha;": "α",
            "&beta;": "β",
            "&gamma;": "γ",
            "&delta;": "δ",
        ]

        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities (decimal): &#60; -> <
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)

            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[codeRange]),
                   let scalar = Unicode.Scalar(code) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        // Numeric entities (hex): &#x3C; -> <
        if let regex = try? NSRegularExpression(pattern: "&#[xX]([0-9a-fA-F]+);", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)

            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let code = Int(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    let char = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }

        // Remove HTML tags (after decoding entities, since tags might have been encoded)
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result
    }
}

// MARK: - Citation Identifier

/// An article identifier together with the namespace that resolves it.
///
/// Kept as two fields rather than one pre-joined string because the two halves
/// are wanted in different places, and joining them early is what made the
/// clipboard useless: "Copy Identifier" put `PMID: 12345678` on the pasteboard,
/// which is not what a PubMed search box or a reference manager accepts. A
/// printed citation wants ``labelled``; a clipboard wants ``value``.
///
/// The namespace is never inferred from the value's shape. It comes from the
/// record's stated kind, or from the provider where the kind is unknown but the
/// search that returned the record can still resolve it — see
/// ``Document/citationIdentifier``. A bare number under a guessed label is #212
/// in the form that outlives the app.
struct CitationIdentifier: Equatable, Hashable, Sendable {
    /// A namespace that can actually resolve an identifier.
    ///
    /// A closed set, because the whole point of this type is that a label is
    /// never invented. A free `String` here let `CitationIdentifier(namespace:
    /// "PMID", value: pmid)` compile over the raw slot — #212 rebuilt by hand,
    /// at any call site — and let a typo such as `"PMC ID"` reach an exported
    /// citation with nothing to catch it.
    ///
    /// Raw values are not localised: these are the namespaces' own names, read
    /// by people who look the identifier up, including in other tools.
    enum Namespace: String, Equatable, Hashable, Sendable, CaseIterable {
        /// A PubMed record, resolvable at pubmed.ncbi.nlm.nih.gov.
        case pubmed = "PMID"

        /// A PubMed Central record, resolvable at ncbi.nlm.nih.gov/pmc.
        case pmc = "PMCID"

        /// A Europe PMC record: preprint, thesis or case report accession.
        case europePMC = "Europe PMC"
    }

    /// The namespace that resolves ``value``.
    let namespace: Namespace

    /// The identifier itself, with no label and no surrounding whitespace.
    let value: String

    /// The form a citation prints: namespace, colon, value.
    var labelled: String { "\(namespace.rawValue): \(value)" }

    /// Private so a namespace is always chosen through a named factory below.
    ///
    /// The factories are the whole enforcement: each one states which namespace
    /// it vouches for, so a caller cannot pair a value with a label the caller
    /// merely guessed.
    ///
    /// - Parameters:
    ///   - namespace: The namespace that resolves `value`.
    ///   - value: The identifier, trimmed by the caller.
    private init(namespace: Namespace, value: String) {
        self.namespace = namespace
        self.value = value
    }

    /// A PubMed ID, which only ``Document/pubmedID`` may vouch for.
    ///
    /// - Parameter id: A verified PubMed ID.
    /// - Returns: The identifier, labelled `PMID`.
    static func pubMed(_ id: String) -> Self {
        Self(namespace: .pubmed, value: id)
    }

    /// A PubMed Central accession.
    ///
    /// - Parameter accession: A PMC accession.
    /// - Returns: The identifier, labelled `PMCID`.
    static func pmc(_ accession: String) -> Self {
        Self(namespace: .pmc, value: accession)
    }

    /// A Europe PMC accession, which names no kind beyond its own provider.
    ///
    /// - Parameter accession: A Europe PMC accession.
    /// - Returns: The identifier, labelled `Europe PMC`.
    static func europePMC(_ accession: String) -> Self {
        Self(namespace: .europePMC, value: accession)
    }
}

// MARK: - Displayed Full Text

/// What ``Document/displayedFullText`` resolved to.
///
/// Two PDF cases rather than one, and the axis they split on is *where the
/// PDF is*, not how it was classified. They need different `URL` constructors
/// downstream, and a consumer that had to work out which from the string, or
/// from the content kind, would be guessing — which is exactly what went
/// wrong: keying "is this a real file?" on ``FullTextContentKind/extracted``
/// sent a downloaded-but-unextractable PDF (a scan: file on disk, kind
/// ``FullTextContentKind/none``) down the remote-URL branch, where
/// `URL(string:)` produced a schemeless URL the viewer could not open and the
/// rebuilt result claimed no local file existed. Both cases render
/// identically; the distinction is carried once, here, so nobody re-derives
/// it.
enum DisplayedFullText: Equatable {
    /// Rendered with `HTMLContentView` for its table support. `markdown`
    /// rides along as the plain-text form the same article was also stored
    /// as, for callers that copy or search it rather than render it.
    case html(String, markdown: String)

    /// Rendered with `MacMarkdownView` / `FullTextViewer`'s markdown branch.
    case markdown(String)

    /// A PDF on this device: `path` is a real filesystem path, whether or not
    /// any text was recovered from it. Read with `URL(fileURLWithPath:)`.
    case localPDF(path: String)

    /// A PDF that was never downloaded — nothing was stored but the link it
    /// was offered at. Three ways a record ends up here: it was written before
    /// extraction existed, it was written with extraction turned off, or the
    /// download simply failed. The last is the common one at runtime, and the
    /// easiest to forget: a 404 or a timeout stores the remote URL too.
    /// Read with `URL(string:)`.
    case remotePDFLink(urlString: String)

    /// Nothing cached to show.
    case none
}

// MARK: - Transparency Report Counts

/// How a report's documents fall across the transparency ratings it shows.
///
/// One computation for the screen, both printable views and the exported
/// text, so no two surfaces can count differently. ``high`` covers exactly the
/// documents ``Document/highRiskTransparencyEntries(in:)`` discusses.
struct TransparencyReportCounts: Equatable {
    /// Documents with a readable analysis.
    var analysed = 0
    /// Readable ratings shown as low risk.
    var low = 0
    /// Readable ratings shown as medium risk.
    var medium = 0
    /// Readable ratings shown as high risk; a high rating shown as unassessed
    /// is counted in ``unassessed`` instead.
    var high = 0
    /// High ratings shown as unassessed: every reason rests on full text known
    /// not to have been searched.
    var unassessed = 0
    /// Readable ratings made without the full text.
    var limited = 0
    /// Stored analyses this build cannot read.
    var unreadable = 0

    /// Counts a report's documents.
    ///
    /// - Parameter documents: The documents the report rests on.
    init(documents: [Document]) {
        for document in documents {
            guard let result = document.transparencyResult else {
                if document.transparencyResultIsUnreadable { unreadable += 1 }
                continue
            }
            analysed += 1
            if document.transparencyCertainty == .limitedNoFullText { limited += 1 }
            if document.transparencyIsUnassessed {
                unassessed += 1
                continue
            }
            switch result.riskLevel {
            case .low: low += 1
            case .medium: medium += 1
            case .high: high += 1
            case .unknown: break
            }
        }
    }

    /// The sentence naming stored analyses that could not be read, or `nil`
    /// when there are none. Such a study carries no rating, and saying so
    /// keeps it from reading as one examined that raised no concern.
    var unreadableSummary: String? {
        guard unreadable > 0 else { return nil }
        if unreadable == 1 {
            return "1 study's stored transparency analysis could not be read, so it carries "
                + "no rating here. Re-analyse to rate it."
        }
        return "\(unreadable) studies' stored transparency analyses could not be read, so they "
            + "carry no rating here. Re-analyse to rate them."
    }
}
