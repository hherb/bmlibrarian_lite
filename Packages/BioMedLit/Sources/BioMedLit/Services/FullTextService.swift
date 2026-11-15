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

import Foundation

/// Service for retrieving full-text articles with fallback chain.
///
/// Attempts to retrieve full text from multiple sources in order:
/// 1. **Europe PMC XML** - Preferred source, machine-readable, converts to HTML/markdown
///    1a. **PMC's open-data bucket** - The same JATS by PMC ID, when Europe
///    PMC's XML gave no article: absent, unreachable or unparseable (#480). Not
///    asked after a body-less Europe PMC deposit, as Python and Kotlin do not
///    ask it then. It holds the author manuscripts Europe PMC does not serve.
/// 2. **Europe PMC PDF** - The free render URL, when the XML is unavailable or
///    carries no `<body>`
///    2a. **Elsevier's API PDF** - An Elsevier article's PDF (`10.1016/`), with
///    the user's key, for a requestor entitled to it (#480, stage C2). Held only
///    as a local file: its article URL needs the key, so it is never a link
/// 3. **Unpaywall PDF** - Open access PDFs via Unpaywall API, every one it
///    names (#480), or the PDF an open-access landing page declares (#464)
///    3a. **OpenAlex PDF** - The PDFs OpenAlex's locations name that Unpaywall
///    did not, unless an Unpaywall copy was served and not cached (#480)
/// 4. **DOI Resolution** - Falls back to opening publisher website
///
/// A body-less deposit, Europe PMC's or the bucket's, does not win at step 1.
/// It is held back and returned only if every PDF tier came up empty, so an
/// open-access PDF of the same paper is still reachable — see `fetchFullText`.
///
/// Thread-safe using Swift's actor model. Includes retry logic with
/// exponential backoff for network operations.
///
/// Usage:
/// ```swift
/// let service = FullTextService(email: "your@email.com")
/// let result = try await service.fetchFullText(
///     pmcId: "PMC7614751",
///     doi: "10.1234/example",
///     pmid: "12345678"
/// )
/// ```
public actor FullTextService {
    // MARK: - Properties

    /// Email for API identification (required by Unpaywall).
    let email: String

    /// URLSession for network requests.
    let session: URLSession

    /// Europe PMC service for identifier resolution.
    let europePMCService: EuropePMCService

    /// Recovers text from a downloaded PDF.
    ///
    /// Injectable for the same reason `session` and `europePMCService` are:
    /// without the seam the PDF tiers can only be tested against a real file,
    /// and PDFKit's own behaviour becomes part of every tier test's subject.
    let extractor: PDFTextExtracting

    /// Whether to download a PDF tier's file and recover its text.
    ///
    /// Mirrors bmlib's `convert_pdfs`. On, a PDF tier downloads, caches and
    /// extracts, so the article's prose reaches transparency analysis. Off, the
    /// tier returns the URL alone and nothing is downloaded, which is the
    /// behaviour every caller had before this existed.
    ///
    /// Transparency analysis is the whole of it: report generation works from
    /// the citations, and nothing passes recovered prose to it.
    ///
    /// The PDF's URL is reported either way, because extracted text recovers the
    /// prose and loses the figures, tables and layout.
    let extractPDFText: Bool

    /// Writes a verified PDF's bytes to the file it waits in beside its cache
    /// name until it is moved in: after its title check (#560), or, through
    /// ``downloadAndCachePDF(from:for:)``, without one.
    ///
    /// Injectable so a test can make the write fail: `pdfCacheDirectory` is a
    /// fixed location, so without this seam a copy served but not cached
    /// (#480) could be tested only at helper level, never through the chain.
    /// Defaults to ``writeAtomically(_:to:)``.
    let writeCachedPDF: @Sendable (Data, URL) throws -> Void

    /// Whether a cached PDF's first page with text carries the article's
    /// title (#546).
    ///
    /// Injectable for the reason `extractor` is: the tier tests serve bytes
    /// that only begin like a PDF, and a stub decides the check without a real
    /// file. Defaults to ``PDFTitleChecker/check(fileURL:title:)``.
    let titleChecker: @Sendable (URL, String) -> PDFTitleCheck

    /// The shared paper library (design §4.5), or `nil` when none is set, and
    /// then the chain runs exactly as without one. Read before any request,
    /// and what the chain fetches is kept there.
    let library: (any FullTextLibrary)?

    /// How the Europe PMC full-text XML fetch retries a transient failure.
    ///
    /// Injectable so a test can pin what a throttle that outlasts its retries
    /// becomes: ``RetryConfiguration/serverError`` waits about seventy-five
    /// seconds (5 + 10 + 20 + 40) before giving up.
    let europePMCRetry: RetryConfiguration

    /// How each request to PMC's open-data bucket retries a throttle, a 5xx
    /// or a transient transport failure.
    ///
    /// Injectable for the same reason as ``europePMCRetry``: a test pins what a
    /// 503 that outlasts its retries becomes without sleeping through the
    /// backoff. Defaults to ``RetryConfiguration/pmcOpenData``: four
    /// attempts, as Python's; the backoff between them is BioMedLit's own.
    let pmcOpenDataRetry: RetryConfiguration

    /// How each request to OpenAlex retries a throttle, a 5xx or a transient
    /// transport failure (#480, stage B).
    ///
    /// Injectable for the same reason as ``pmcOpenDataRetry``. Defaults to
    /// ``RetryConfiguration/openAlex``: four attempts, as Python's.
    let openAlexRetry: RetryConfiguration

    /// The user's CORE API key, trimmed; `nil` when none or blank, and then
    /// CORE is never asked and nothing is recorded (#480, stage C). It travels
    /// in the `Authorization` header alone, never in a URL or a log line.
    let coreAPIKey: String?

    /// How each request to CORE retries a throttle, a 5xx or a transient
    /// transport failure. Injectable for the same reason as
    /// ``openAlexRetry``. Defaults to ``RetryConfiguration/core``: four
    /// attempts, as Python's.
    let coreRetry: RetryConfiguration

    /// CORE's session state: the 429 pause (two consecutive fetches ending
    /// in 429 stop CORE being asked) and the refused key (#498), shared by
    /// every service in the process. Injectable so a test owns its own.
    let coreThrottle: CoreThrottle

    /// Whether this service asks CORE: a non-blank key was given.
    public nonisolated var asksCore: Bool { coreAPIKey != nil }

    /// Whether the user's CORE key was set but could not be read (the device
    /// locked, #511): CORE is then recorded as unreachable, never as not asked.
    let coreKeyUnreadable: Bool

    /// The user's Elsevier API key, trimmed; `nil` when none or blank, and then
    /// Elsevier's API is never asked and nothing is recorded (#480, stage C2).
    /// It travels in the `X-ELS-APIKey` header alone, never in a URL or a log line.
    let elsevierAPIKey: String?

    /// The user's Elsevier institutional token, trimmed; `nil` when none or
    /// blank. Sent in `X-ELS-Insttoken` beside the key, and never without one.
    let elsevierInstToken: String?

    /// How each request to Elsevier's API retries a throttle, a 5xx or a
    /// transient transport failure. Injectable for the same reason as
    /// ``coreRetry``. Defaults to ``RetryConfiguration/elsevier``: four
    /// attempts, as Python's.
    let elsevierRetry: RetryConfiguration

    /// Elsevier's session state: the 429 pause, the refused key and the
    /// credentials refused from this network, shared by every service in the
    /// process and with nothing of CORE's. Injectable so a test owns its own.
    let elsevierSession: ElsevierSession

    /// Whether this service asks Elsevier's API: a non-blank key was given.
    public nonisolated var asksElsevier: Bool { elsevierAPIKey != nil }

    /// Whether the user's Elsevier key or institutional token could not be
    /// read (#511): Elsevier is then recorded as unreachable, as Android's
    /// `ElsevierService` does, never as not asked.
    let elsevierCredentialsUnreadable: Bool

    /// Whether this service sends an institutional token with Elsevier's key: a
    /// non-blank token was given with a key.
    public nonisolated var sendsElsevierToken: Bool { elsevierInstToken != nil }

    /// Hosts this service paces itself on: one slot each (#489 tracks making
    /// it per host across instances, as Python's).
    enum PacedHost: Hashable {
        case pmcOpenData
        case openAlex
        case core
        case elsevier

        var minimumInterval: TimeInterval {
            switch self {
            case .pmcOpenData: return BioMedLitConstants.pmcOpenDataMinimumInterval
            case .openAlex: return BioMedLitConstants.openAlexMinimumInterval
            case .core: return BioMedLitConstants.coreMinimumInterval
            case .elsevier: return BioMedLitConstants.elsevierMinimumInterval
            }
        }
    }

    /// When the next request to each paced host may go; reserved before a
    /// request waits, so two fetches interleaving on this actor cannot both
    /// take the same slot.
    var nextRequest: [PacedHost: Date] = [:]

    /// Characters safe to leave unescaped inside a query-string *value*.
    ///
    /// `.urlQueryAllowed` describes a whole query, so of the characters removed
    /// here it permits `+`, `&`, `=` and `?`. Three of those matter to a value:
    /// `+` decodes to a space server-side, which would send Unpaywall a
    /// different address than the one configured, and an unescaped `&` or `=`
    /// would let the value split itself into query items nobody asked for.
    /// `?` is legal inside a value and is removed only so the set reads as the
    /// complete list of delimiters; `#` is not in `.urlQueryAllowed` to begin
    /// with, so removing it is a no-op kept for the same reason.
    static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return allowed
    }()

    // MARK: - Initialization

    /// Initialize the full-text service.
    ///
    /// - Parameters:
    ///   - email: Email address for API identification.
    ///   - session: Transport to use. Defaults to ``makeSession()``;
    ///     the parameter exists so tests can serve a canned response, without
    ///     which `fetchEuropePMCXML` has no offline coverage at all.
    ///   - europePMCService: Resolver for a missing PMC ID and its free PDF
    ///     render URL. Injectable for the same reason as `session`, and separate
    ///     from it because that service configures its own timeouts: passing
    ///     `session` straight through would change them in production. Without
    ///     this seam the Europe PMC PDF branch cannot be reached by a test at
    ///     all, which is how it shipped without coverage.
    ///   - extractor: Recovers text from a downloaded PDF. Defaults to
    ///     ``PDFKitTextExtractor``; injectable so a test can exercise the PDF
    ///     tiers without a real file.
    ///   - extractPDFText: Whether a PDF tier downloads, caches and extracts.
    ///     Defaults to `true`. Mirrors bmlib's `convert_pdfs`.
    ///   - europePMCRetry: How the full-text XML fetch retries a transient
    ///     failure. Defaults to ``RetryConfiguration/serverError``.
    ///   - pmcOpenDataRetry: How each request to PMC's open-data bucket
    ///     retries a transient failure. Defaults to
    ///     ``RetryConfiguration/pmcOpenData``.
    ///   - openAlexRetry: How each request to OpenAlex retries a transient
    ///     failure. Defaults to ``RetryConfiguration/openAlex``.
    ///   - coreAPIKey: The user's CORE API key. `nil` — the default — or
    ///     blank means CORE is never asked (#480, stage C).
    ///   - coreKeyUnreadable: The CORE key could not be read, so CORE is
    ///     recorded as unreachable. Defaults to `false`.
    ///   - coreRetry: How each request to CORE retries a transient failure.
    ///     Defaults to ``RetryConfiguration/core``.
    ///   - coreThrottle: CORE's session state: the 429 pause and the refused
    ///     key. Defaults to ``CoreThrottle/shared``, the one every service in
    ///     the process uses.
    ///   - elsevierAPIKey: The user's Elsevier API key. `nil` — the default —
    ///     or blank means Elsevier's API is never asked (#480, stage C2).
    ///   - elsevierInstToken: The user's Elsevier institutional token, sent
    ///     beside the key. `nil` — the default — or blank sends none.
    ///   - elsevierCredentialsUnreadable: The Elsevier key or token could not
    ///     be read, so Elsevier is recorded as unreachable. Defaults to `false`.
    ///   - elsevierRetry: How each request to Elsevier's API retries a
    ///     transient failure. Defaults to ``RetryConfiguration/elsevier``.
    ///   - elsevierSession: Elsevier's session state: the 429 pause, the
    ///     refused key and the credentials refused from this network. Defaults
    ///     to ``ElsevierSession/shared``, the one every service in the process uses.
    ///   - writeCachedPDF: Writes a verified PDF to the file it waits in
    ///     beside its cache name until it is moved in (#560). Defaults
    ///     to ``writeAtomically(_:to:)``; injectable so a test can make the
    ///     write fail.
    ///   - titleChecker: Whether a cached PDF carries the article's title
    ///     (#546). Defaults to ``PDFTitleChecker/check(fileURL:title:)``;
    ///     injectable so a test can decide it without a real PDF.
    ///   - library: The shared paper library, or `nil` — the default — for
    ///     none. Only macOS sets one; iOS keeps `nil`.
    public init(
        email: String,
        session: URLSession = FullTextService.makeSession(),
        europePMCService: EuropePMCService = EuropePMCService(),
        extractor: PDFTextExtracting = PDFKitTextExtractor(),
        extractPDFText: Bool = true,
        europePMCRetry: RetryConfiguration = .serverError,
        pmcOpenDataRetry: RetryConfiguration = .pmcOpenData,
        openAlexRetry: RetryConfiguration = .openAlex,
        coreAPIKey: String? = nil,
        coreKeyUnreadable: Bool = false,
        coreRetry: RetryConfiguration = .core,
        coreThrottle: CoreThrottle = .shared,
        elsevierAPIKey: String? = nil,
        elsevierInstToken: String? = nil,
        elsevierCredentialsUnreadable: Bool = false,
        elsevierRetry: RetryConfiguration = .elsevier,
        elsevierSession: ElsevierSession = .shared,
        writeCachedPDF: @escaping @Sendable (Data, URL) throws -> Void = FullTextService.writeAtomically,
        titleChecker: @escaping @Sendable (URL, String) -> PDFTitleCheck = { url, title in
            PDFTitleChecker.check(fileURL: url, title: title)
        },
        library: (any FullTextLibrary)? = nil
    ) {
        self.email = email
        self.europePMCService = europePMCService
        self.session = session
        self.extractor = extractor
        self.extractPDFText = extractPDFText
        self.europePMCRetry = europePMCRetry
        self.pmcOpenDataRetry = pmcOpenDataRetry
        self.openAlexRetry = openAlexRetry
        self.coreAPIKey = Self.setting(coreAPIKey)
        self.coreKeyUnreadable = coreKeyUnreadable
        self.coreRetry = coreRetry
        self.coreThrottle = coreThrottle
        self.elsevierAPIKey = Self.setting(elsevierAPIKey)
        // Never sent without a key, so not held without one either
        self.elsevierInstToken = self.elsevierAPIKey == nil ? nil : Self.setting(elsevierInstToken)
        self.elsevierCredentialsUnreadable = elsevierCredentialsUnreadable
        self.elsevierRetry = elsevierRetry
        self.elsevierSession = elsevierSession
        self.writeCachedPDF = writeCachedPDF
        self.titleChecker = titleChecker
        self.library = library
    }

    /// A credential as the settings hold it, trimmed; blank is none.
    ///
    /// - Parameter value: The setting's value, or `nil`.
    /// - Returns: The trimmed value, or `nil` when it is absent or blank.
    private static func setting(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The production cache write: the whole file or none, so a write that
    /// fails midway leaves no partial PDF a later lookup could serve.
    ///
    /// - Parameters:
    ///   - data: The verified PDF bytes.
    ///   - url: The file the PDF waits in beside its cache name (#560).
    /// - Throws: The write's error.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// The transport production uses.
    ///
    /// Separated from ``init(email:session:europePMCService:extractor:extractPDFText:europePMCRetry:pmcOpenDataRetry:openAlexRetry:coreAPIKey:coreKeyUnreadable:coreRetry:coreThrottle:elsevierAPIKey:elsevierInstToken:elsevierCredentialsUnreadable:elsevierRetry:elsevierSession:writeCachedPDF:titleChecker:library:)``
    /// so a test can
    /// substitute a stubbed `URLSession` without reproducing these timeouts.
    ///
    /// - Returns: A session configured with the package's request and download
    ///   timeouts, waiting for connectivity rather than failing offline.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = BioMedLitConstants.defaultRequestTimeout
        config.timeoutIntervalForResource = BioMedLitConstants.pdfDownloadTimeout
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    // MARK: - Main Entry Point

    /// Attempt to retrieve full text for a document.
    ///
    /// Tries sources in order: Europe PMC XML → PMC's open-data bucket (by PMC
    /// ID, #480) → Europe PMC PDF → Elsevier's API PDF (an Elsevier DOI, with
    /// the user's key, #480 stage C2) → Unpaywall PDFs → OpenAlex PDFs → CORE's
    /// extracted text (with the user's key, #480 stage C) → DOI website. Each
    /// source is tried with retry logic for transient network failures. A
    /// body-less XML deposit is held back rather than returned, so the PDF
    /// tiers still get their turn. A PDF that yields no text is returned only
    /// after CORE, asked once, served none (#499).
    ///
    /// With a library set (design §4.5), the library's JATS for the paper,
    /// when usable, ends the lookup before any request; otherwise a JATS a
    /// tier serves with a body is kept there, the library's PDF is read in
    /// place of the first PDF tier's download, and a PDF the chain reads from
    /// its cache is kept there; one this call downloaded loses its cache copy
    /// once the library holds it, one cached earlier keeps it. A library that
    /// cannot be used never stops the lookup: the result's
    /// ``FullTextResult/libraryFailure`` says why, and the source stays where
    /// it is, waiting for the library when it could not be reached
    /// (``FullTextResult/libraryWaiting``).
    ///
    /// - Parameters:
    ///   - pmcId: PubMed Central ID (e.g., "PMC1234567").
    ///   - doi: Digital Object Identifier.
    ///   - pmid: The document's primary identifier slot. Not only ever a PubMed
    ///     ID — see ``ArticleIdentifierKind``.
    ///   - primaryKind: What the provider said that slot holds, when it said.
    ///     `nil` — every document stored before the kind was recorded — reads
    ///     the kind from the identifier's shape instead, which is what this
    ///     chain did for every article before #209.
    ///   - title: The article's title, as stored (#546). Every PDF a tier
    ///     caches, or finds cached, is checked against it, a download before
    ///     it takes its cache name (#560): one whose first
    ///     page with text does not carry it is another article's, set aside
    ///     beside its cached name with ``BioMedLitConstants/pdfMismatchSuffix``,
    ///     recorded as a ``OpenAccessUnsettledReason/wrongArticle`` skip with
    ///     its address (never an absence), and the next source is tried.
    ///     `nil`, the default, checks nothing.
    /// - Returns: The content and its source, what the JATS parse of it lost
    ///   (#181), and — when Europe PMC served XML this parser could not read, or
    ///   could not be reached at all — why this is not the best source that
    ///   existed (#183, #186).
    /// - Throws: When every source is exhausted, `FullTextError`:
    ///   `noFullTextAvailable` when every source answered without it (callers
    ///   record this on the document); `absenceNotEstablished` when Europe PMC
    ///   did not settle it; `pmcOpenDataNotEstablished` when PMC's open-data
    ///   bucket could not be read; `openAccessNotEstablished` when the
    ///   copies after the render (Elsevier's API, then Unpaywall's and
    ///   OpenAlex's PDFs, then CORE) did not settle it;
    ///   `identifierKindUnresolved` when the PubMed last resort could not be
    ///   authorised. None of the last four may
    ///   be recorded (see
    ///   ``exhaustedChainError(primarySlot:primaryKind:europePMCShortfall:pmcOpenDataShortfall:openAccessShortfall:articleName:)``).
    ///   `CancellationError` if the caller cancelled: it propagates
    ///   rather than falling
    ///   through, so a link is never cached as this article's full text just
    ///   because the caller went away.
    public func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String,
        primaryKind: ArticleIdentifierKind? = nil,
        title: String? = nil
    ) async throws -> FullTextResult {
        let lookup = LibraryLookup(
            library: library,
            paper: Self.libraryPaper(pmcId: pmcId, doi: doi, pmid: pmid, primaryKind: primaryKind, title: title)
        )
        return lookup.finish(try await fetchThroughChain(
            pmcId: pmcId, doi: doi, pmid: pmid, primaryKind: primaryKind, title: title, lookup: lookup
        ))
    }

    /// ``fetchFullText(pmcId:doi:pmid:primaryKind:title:)``'s chain, given the
    /// fetch's part of the library, which it reads, keeps into and records
    /// failures on.
    private func fetchThroughChain(
        pmcId: String?,
        doi: String?,
        pmid: String,
        primaryKind: ArticleIdentifierKind?,
        title: String?,
        lookup: LibraryLookup
    ) async throws -> FullTextResult {
        // Names the article for the PDF cache. Built once, from the identifiers
        // the *document* carries rather than from `resolvedPmcId` below: a key
        // that depended on whether a Europe PMC lookup succeeded would file the
        // same article under two names across runs.
        //
        // `nil` only when the document carries no identifier at all, and the
        // two PDF tiers below are guarded on it rather than on a refusal inside
        // the download: the render URL is resolved from these same identifiers,
        // and the Unpaywall tier needs a DOI, so the guard costs at most one
        // skipped request on an input carrying nothing to key on. A guard inside
        // the download would instead be a branch production never takes, and an
        // untaken branch protects nothing.
        let cacheKey = ArticleCacheKey(
            pmid: pmid,
            pmcId: pmcId,
            doi: doi,
            primaryKind: primaryKind
        )

        // How the log lines below name this article. The PMID slot is exactly
        // what is empty for the articles this ladder exists to serve, so a line
        // reading "for PMID " would be blank precisely where it is most needed.
        let articleName = cacheKey?.logDescription ?? "an article with no identifier"

        BioMedLitLib.logger?.info(
            "Fetching full text for \(articleName) (PMC: \(pmcId ?? "none"), DOI: \(doi ?? "none"))",
            category: .fullText
        )

        // Set when a better source existed and was lost, and attached to
        // whichever fallback the chain returns instead (#183, #186).
        var degradation: FullTextDegradation?

        // A body-less Europe PMC rendering, kept aside until every better tier
        // has had its turn. `nil` when none was seen.
        var abstractOnly: FullTextResult?

        // A PDF URL whose download failed, kept in case no later tier does
        // better. See `pdfTierResult`.
        var pdfLinkFallback: FullTextResult?

        // What Europe PMC's side of the chain got instead of the article's text,
        // if anything. Set by a lost identifier search, a fetch that
        // failed and a `fullTextXML` 404; cleared by a fetch that was served.
        // Read only at the very end: a chain that found nothing must not call
        // the article's full text absent while this is set (#434).
        var europePMCShortfall: RequestFailure?

        // What PMC's open-data bucket got instead of the article's JATS, if it
        // was asked and could not be read (#480). Its own absence sets nothing.
        var pmcOpenDataShortfall: RequestFailure?

        // The library's JATS first (design §4.5): usable, it ends the lookup
        // before any request. Its notes and failures are logged by the library.
        if let library = lookup.inUse {
            switch library.jats(for: lookup.paper) {
            case .usable(let xml, let file):
                if let served = libraryJATSResult(xml, file: file, lookup: lookup, articleName: articleName) {
                    // Held back like Europe PMC's body-less deposit
                    if served.contentKind == .abstract { abstractOnly = served } else { return served }
                }
            case .wrongPaper(let message):
                lookup.fail(message, ends: true, unreachable: false)
            case .failed(let failure):
                lookup.fail(failure.description, ends: true, unreachable: failure.waits)
            case .unusable, .none:
                break
            }
        }

        // Resolve PMC ID and PDF render URL from PMID or DOI if not already available
        var resolvedPmcId = pmcId
        var resolvedPreprintAccession: String?
        var searchLostTheSource = false
        var pdfRenderURL: String?
        var identifiersResolved = false
        if resolvedPmcId == nil || resolvedPmcId?.isEmpty == true {
            let resolved = try await resolvePMCIdAndPDFUrl(
                pmid: pmid, pmcId: pmcId, doi: doi, primaryKind: primaryKind
            )
            identifiersResolved = true
            resolvedPmcId = resolved.pmcId
            resolvedPreprintAccession = resolved.preprintAccession
            pdfRenderURL = resolved.pdfRenderURL
            // Only when the failure actually cost us the source. A failed PMID
            // search that the DOI search then recovered from cost the reader
            // nothing, and neither does one where a later query answered that
            // this article has no PMC record at all. The XML branch's own
            // outcome decides from here.
            if let lostTo = resolved.sourceLostTo {
                searchLostTheSource = true
                degradation = .europePMCUnreachable
                europePMCShortfall = lostTo
            }
        }

        // Try Europe PMC first (best quality - machine readable XML). A
        // preprint has no PMC ID and is asked for by its `PPR` record ID.
        if let accession = Self.fullTextAccession(
            pmcId: resolvedPmcId,
            resolvedPreprintAccession: resolvedPreprintAccession,
            pmid: pmid,
            primaryKind: primaryKind,
            searchLostTheSource: searchLostTheSource
        ) {
            switch try await fetchEuropePMCXML(accession: accession) {
            case .served(let xml):
                // Europe PMC answered, so whatever the identifier search lost,
                // it did not cost the reader this source.
                degradation = nil
                europePMCShortfall = nil
                do {
                    let content = try renderEuropePMCXML(xml.data, accession: accession)
                    BioMedLitLib.logger?.info(
                        "Successfully retrieved Europe PMC full text for \(accession)",
                        category: .fullText
                    )
                    let parsed = FullTextResult(
                        content: .europePMC(html: content.html, markdown: content.markdown),
                        warnings: content.warnings,
                        contentKind: content.contentKind,
                        libraryFile: keptJATS(xml.data, content, origin: .europePMC, key: cacheKey, lookup: lookup)
                    )
                    // A body-less deposit is not an article. Returning it here —
                    // as this did — made it beat every remaining tier, so an
                    // open-access PDF of the same paper was unreachable, and the
                    // abstract was cached and scored as an article body. Held
                    // back instead, and returned at the end only if nothing
                    // better arrives, mirroring bmlib's `_with_abstract_fallback`.
                    if content.contentKind == .abstract {
                        BioMedLitLib.logger?.info(
                            "Europe PMC served an abstract-only deposit for \(accession); "
                                + "holding it back in case a PDF tier does better",
                            category: .fullText
                        )
                        abstractOnly = parsed
                    } else {
                        return parsed
                    }
                } catch FullTextError.jatsParseFailure(let parseError) {
                    // Deliberately not thrown: the remaining sources are the
                    // reason this method is a chain, and a reader who can be
                    // given the publisher's PDF should get it rather than an
                    // error. Recorded on every result the chain goes on to
                    // return, so the reader is told that a better source existed
                    // and we could not use it — the half of #183 the log cannot
                    // do. Logged at error: a defect in us, not an absent source.
                    degradation = .jatsParseFailed
                    BioMedLitLib.logger?.error(
                        "Europe PMC XML for \(accession) was retrieved but could not be parsed "
                            + "(\(parseError)); falling back to a PDF or publisher link",
                        category: .fullText
                    )
                }

            case .absent:
                // Europe PMC's own answer, so never a degradation: a note that
                // fires on every article not deposited as open access is
                // worthless on the ones where it is true. But not the
                // article's absence either. `fullTextXML` serves open-access
                // text only, and a PMC or PPR accession names a record Europe
                // PMC mirrors, so the 404 may mean "not open access" (#432).
                degradation = nil
                europePMCShortfall = .httpStatus(BioMedLitConstants.httpStatusNotFound)
                BioMedLitLib.logger?.warning(
                    "Europe PMC did not serve full text for \(accession) (HTTP 404); "
                        + "trying the PDF tiers",
                    category: .fullText
                )

            case .unreachable(let failure):
                // We could not get Europe PMC's answer — a throttle or server
                // error that outlasted its retries, a transport failure, a
                // status we do not model, a blank body, or an identifier that
                // is not an accession. The source may well have had the text,
                // and the reader is looking at a substitute because of us
                // (#186).
                degradation = .europePMCUnreachable
                europePMCShortfall = failure
                BioMedLitLib.logger?.warning(
                    "Europe PMC XML could not be retrieved for \(accession) "
                        + "(\(failure.describe())); falling back to a PDF or publisher link",
                    category: .fullText
                )
            }
        }

        // PMC's open-data bucket (#480), by PMC ID, when Europe PMC's XML gave
        // no article. Not asked after a body-less Europe PMC deposit: Python
        // and Kotlin have no content kind and read that deposit as served, so
        // asking here alone would break parity. `resolvedPmcId` is the
        // caller's PMC ID or the one the search resolved; a `PPR` preprint
        // accession is never asked, because the bucket files by PMC ID only.
        if abstractOnly == nil,
           let bucketPMCID = Self.pmcAccession(resolvedPmcId) {
            switch try await fetchPMCOpenDataXML(pmcid: bucketPMCID) {
            case .served(let xml):
                do {
                    let content = try renderEuropePMCXML(xml.data, accession: bucketPMCID)
                    BioMedLitLib.logger?.info(
                        "Retrieved full text for \(bucketPMCID) from PMC's open-access collection",
                        category: .fullText
                    )
                    // A parse of the bucket's JATS replaces whatever Europe PMC
                    // lost: the machine-readable source was not lost after all.
                    let parsed = FullTextResult(
                        content: .pmcOpenData(html: content.html, markdown: content.markdown),
                        warnings: content.warnings,
                        contentKind: content.contentKind,
                        libraryFile: keptJATS(xml.data, content, origin: .pmcOpenData, key: cacheKey, lookup: lookup)
                    )
                    // Held back like Europe PMC's, so a PDF tier still gets its
                    // turn at the article body.
                    if content.contentKind == .abstract {
                        abstractOnly = parsed
                    } else {
                        return parsed
                    }
                } catch FullTextError.jatsParseFailure(let parseError) {
                    // Python records an unconvertible bucket XML as a
                    // malformed answer, so the chain does not call the full
                    // text absent on it. No degradation: that names Europe
                    // PMC's XML, which this is not.
                    pmcOpenDataShortfall = .malformedResponse
                    BioMedLitLib.logger?.error(
                        "PMC's open-access collection's XML for \(bucketPMCID) could not be parsed "
                            + "(\(parseError)); trying the PDF tiers",
                        category: .fullText
                    )
                }
            case .absent:
                // The bucket's own answer about itself: nothing to record.
                break
            case .unreachable(let failure):
                pmcOpenDataShortfall = failure
                BioMedLitLib.logger?.warning(
                    "PMC's open-access collection could not be read for \(bucketPMCID) "
                        + "(\(failure.describe())); trying the PDF tiers",
                    category: .fullText
                )
            }
        }

        // The DOI CORE is asked by: resolver prefixes removed, as Python's
        // `_clean_doi` (blank asks nothing)
        let coreDOI = CORE.bareDOI(doi ?? "")

        // The library's PDF, before the first PDF tier's request (design §4.5)
        if let result = try libraryPDFResult(
            lookup: lookup,
            title: title,
            degradation: degradation,
            holdingAbstract: abstractOnly != nil,
            articleName: articleName
        ) {
            return try await textlessCopyOrCORE(result, doi: coreDOI, degradation: degradation)
        }

        // Try Europe PMC PDF render URL (when XML is unavailable or body-less).
        //
        // The render URL arrives with the PMC ID resolution above, which runs
        // only when the caller had none. Every app call site passes the PMC ID
        // it already holds, so this tier was reached with nothing to try on its
        // most common input and the chain went straight to Unpaywall — the tier
        // the extraction slice was built for, skipped for exactly the
        // open-access articles that have a free render URL. Resolved here
        // instead, and only here: this line is reached only when the XML tier
        // did not return, so an article whose XML has a body still costs no
        // extra request.
        //
        // Only `pdfRenderURL` is taken from the resolution here. Its
        // `sourceLostTo` is deliberately ignored: the XML tier above has
        // already run and recorded its own outcome, and letting a failed
        // *render-URL* lookup set `.europePMCUnreachable` would overwrite the
        // more specific reason with a vaguer one.
        if !identifiersResolved {
            // `resolvedPmcId` is still the document's own `pmcId` here, never a
            // looked-up value: it is reassigned only inside the branch that sets
            // `identifiersResolved = true`, which this line is guarded against.
            // That is what keeps the PMC rung asking about the document rather
            // than about whatever an earlier search happened to return.
            pdfRenderURL = try await resolvePMCIdAndPDFUrl(
                pmid: pmid, pmcId: resolvedPmcId, doi: doi, primaryKind: primaryKind
            ).pdfRenderURL
            identifiersResolved = true
        }
        if pdfRenderURL == nil {
            // Says why the best PDF tier is about to be skipped. Without it the
            // skip is silent, and a routing bug that resolves no render URL is
            // indistinguishable from an article that genuinely has no free PDF
            // — which is the shape of #202 itself.
            BioMedLitLib.logger?.info(
                "No Europe PMC render URL resolved for \(articleName); skipping that PDF tier",
                category: .fullText
            )
        }
        // A render served and not cached (#480). Not an open-access copy, so it
        // neither settles the shortfall nor stops the Unpaywall walk: a copy
        // Unpaywall names may still be saved. Told only if none is.
        var renderNotSavedFrom: String?
        // Why a copy the render, Elsevier's API, Unpaywall or OpenAlex may
        // hold went unassessed, if it did: the render served another
        // article's PDF (#546); Elsevier could not be asked, refused the
        // credentials or served a PDF that could not be saved or was another
        // article's (#480, stage C2); Unpaywall, the landing page it named or
        // OpenAlex could not settle whether a free copy exists, a PDF either
        // named could not be obtained (#478; every one is listed, #480) or
        // was another article's (#546), or Unpaywall was not configured. In
        // chain order, the render's first. Carried on whatever fallback is
        // returned, so a caller holding a better link than that fallback
        // knows not to trade it away (#464).
        var openAccessShortfall: OpenAccessShortfall?
        if let cacheKey, let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            let outcome = keptInLibrary(
                try await downloadAndExtract(from: pdfURL, key: cacheKey, title: title),
                origin: .europePMCPDF,
                lookup: lookup
            )
            // Every outcome named, so a new one is decided here, not lost
            switch outcome {
            case .notCached:
                renderNotSavedFrom = pdfURL.absoluteString
            case .wrongArticle:
                // Another article's: no link to it is kept, and the question
                // stays open, as Python's Europe PMC skip leaves it
                openAccessShortfall = .adding(
                    .wrongArticle(source: .europePMCPDF, address: pdfURL.absoluteString), to: openAccessShortfall
                )
            case .vanished:
                // Gone twice before it was read (#560): not obtained, no link
                openAccessShortfall = .adding(
                    OpenAccessShortfall(source: .europePMCPDF, failure: .requestFailed, address: pdfURL.absoluteString),
                    to: openAccessShortfall
                )
            case .notAttempted, .downloadFailed, .noText, .extracted:
                // Left to pdfTierResult below
                break
            }
            if let result = pdfTierResult(
                outcome: outcome,
                content: .europePMCPDF(pdfURL: pdfURL),
                degradation: degradation,
                holdingAbstract: abstractOnly != nil,
                articleName: articleName,
                linkFallback: &pdfLinkFallback
            ) {
                return try await textlessCopyOrCORE(result, doi: coreDOI, degradation: degradation)
            }
        }

        // The DOI the copies after the render are asked by. Trimmed to the
        // same definition of "blank" `ArticleCacheKey` uses, so the two guards
        // agree about the same input: a whitespace-only DOI keys nothing, and
        // it must not reach Elsevier or Unpaywall either.
        let unpaywallDOI = doi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Whether any copy was served: not cached, or cached without text
        // while an abstract is held. Either settles the question; only the
        // first ends the walk (a textless copy lets another, OpenAlex's
        // included, be tried for text)
        var openAccessCopyServed = false
        // Elsevier's API (#480, stage C2): after the render, before any
        // Unpaywall lookup, only for an Elsevier DOI and only with the user's
        // key. Its PDF is held only as a local file, and nothing it does falls
        // back to a link: its article URL needs the key.
        // Asked by the DOI cleaned as CORE's is (Python's `_clean_doi`), so a
        // DOI stored as `https://www.doi.org/10.1016/...` is Elsevier's too.
        if let cacheKey,
           let result = try await elsevierResult(
               doi: coreDOI,
               cacheKey: cacheKey,
               title: title,
               degradation: degradation,
               holdingAbstract: abstractOnly != nil,
               articleName: articleName,
               shortfall: &openAccessShortfall,
               copyServed: &openAccessCopyServed,
               lookup: lookup
           ) {
            return try await textlessCopyOrCORE(result, doi: coreDOI, degradation: degradation)
        }

        // Try Unpaywall (open access PDFs).
        // An open-access copy served but not cached (#480): it ends the walk,
        // settles the question, and is the caching note's address
        var openAccessNotSavedFrom: String?
        var triedPDFs = Set<String>()
        if let cacheKey, !unpaywallDOI.isEmpty {
            let doi = unpaywallDOI
            var candidates: [String] = []
            do {
                candidates = try await fetchUnpaywallPDFCandidates(doi: doi)
                if candidates.isEmpty {
                    BioMedLitLib.logger?.info(
                        "Unpaywall offers no PDF for DOI \(doi)", category: .fullText
                    )
                }
            } catch where error.isCancellation {
                // As above: a cancelled fetch must not be read as an absent PDF.
                throw CancellationError()
            } catch {
                let shortfall = Self.openAccessShortfall(for: error)
                // Before any PDF's, so the list keeps the chain's order
                if let shortfall {
                    openAccessShortfall = .adding(shortfall, to: openAccessShortfall)
                }
                // The tier's own failure type carries no description, so the
                // shortfall names what went unsettled and why
                let cause = shortfall.map {
                    "\($0.source.serviceName): \($0.reason.described)"
                } ?? error.localizedDescription
                BioMedLitLib.logger?.warning(
                    "Unpaywall failed for DOI \(doi) (\(cause))", category: .fullText
                )
            }
            if let result = try await tryOpenAccessPDFs(
                candidates,
                refusedAs: .pdf,
                content: { .unpaywall(pdfURL: $0) },
                cacheKey: cacheKey,
                title: title,
                degradation: degradation,
                holdingAbstract: abstractOnly != nil,
                articleName: articleName,
                linkFallback: &pdfLinkFallback,
                shortfall: &openAccessShortfall,
                notSavedFrom: &openAccessNotSavedFrom,
                copyServed: &openAccessCopyServed,
                tried: &triedPDFs,
                lookup: lookup
            ) {
                return try await textlessCopyOrCORE(result, doi: coreDOI, degradation: degradation)
            }
            // OpenAlex, for the PDFs Unpaywall did not name (#480, stage B);
            // not once an Unpaywall copy was served and not cached: that copy
            // ends the walk, its link kept, and asking further cannot raise the
            // odds (the maintainer's decision, 2026-10-05). A copy cached that
            // yielded no text while an abstract is held does not stop it
            // (`openAccessCopyServed` alone): a textless copy is no full text
            // obtained, so OpenAlex's may still give it (fulltext_retrieval.md,
            // "Every platform tries every PDF Unpaywall names")
            if openAccessNotSavedFrom == nil {
                switch try await fetchOpenAlexPDFURLs(doi: doi) {
                case .served(let urls):
                    if let result = try await tryOpenAccessPDFs(
                        OpenAlex.untried(urls, tried: triedPDFs),
                        refusedAs: .openAlexPDF,
                        content: { .openAlex(pdfURL: $0) },
                        cacheKey: cacheKey,
                        title: title,
                        degradation: degradation,
                        holdingAbstract: abstractOnly != nil,
                        articleName: articleName,
                        linkFallback: &pdfLinkFallback,
                        shortfall: &openAccessShortfall,
                        notSavedFrom: &openAccessNotSavedFrom,
                        copyServed: &openAccessCopyServed,
                        tried: &triedPDFs,
                        lookup: lookup
                    ) {
                        return try await textlessCopyOrCORE(result, doi: coreDOI, degradation: degradation)
                    }
                case .absent:
                    BioMedLitLib.logger?.info(
                        "OpenAlex knows no work by DOI \(doi)", category: .fullText
                    )
                case .unreachable(let failure):
                    openAccessShortfall = .adding(
                        OpenAccessShortfall(source: .openAlex, failure: failure), to: openAccessShortfall
                    )
                    BioMedLitLib.logger?.warning(
                        "OpenAlex could not be asked about DOI \(doi) (\(failure.describe())), so any "
                            + "open-access copy it knows of is not assessed",
                        category: .fullText
                    )
                }
            }
            // CORE's extracted text (#480, stage C): the poorest form, so last,
            // only with the user's key and only when no copy was served. A
            // failure is an unsettled lookup, as OpenAlex's is. No key: never
            // asked, nothing recorded.
            if openAccessNotSavedFrom == nil,
               let result = try await coreTextResult(
                   doi: coreDOI, degradation: degradation, shortfall: &openAccessShortfall
               ) {
                return result
            }
        }
        openAccessShortfall = Self.settledOpenAccessShortfall(
            openAccessShortfall, copyServed: openAccessCopyServed
        )
        // The note names the copy that settled it, else a render not saved
        let pdfNotSavedFrom = openAccessNotSavedFrom ?? renderNotSavedFrom

        // The reader gets the abstract rather than a bare link. No web URL is
        // attached to it: `Document.fullTextLinkDestination` already resolves
        // the DOI page or the PubMed record for every document, and a second
        // copy here would give the views two sources for one link.
        if let abstractOnly {
            BioMedLitLib.logger?.info(
                "No tier beat the abstract-only rendering for \(articleName); returning it",
                category: .fullText
            )
            return abstractOnly.noting(
                openAccessShortfall: openAccessShortfall, pdfNotSavedFrom: pdfNotSavedFrom
            )
        }

        // Then a PDF whose bytes we could not fetch. Below the abstract, which
        // is text in hand, and above the publisher page, which is a guess at
        // where the article might be — this URL is at least known to name it.
        if let pdfLinkFallback {
            BioMedLitLib.logger?.info(
                "No tier retrieved a PDF for \(articleName); returning the link we could not "
                    + "download",
                category: .fullText
            )
            return pdfLinkFallback.noting(
                openAccessShortfall: openAccessShortfall, pdfNotSavedFrom: pdfNotSavedFrom
            )
        }

        // Fallback to DOI or PubMed URL
        if !unpaywallDOI.isEmpty,
           let url = URL(string: "\(BioMedLitConstants.doiBaseURL)/\(unpaywallDOI)") {
            BioMedLitLib.logger?.info(
                "Falling back to DOI URL for \(unpaywallDOI)",
                category: .fullText
            )
            return FullTextResult(
                content: .doi(webURL: url),
                degradation: degradation,
                openAccessShortfall: openAccessShortfall,
                pdfNotSavedFrom: pdfNotSavedFrom
            )
        }

        // Final fallback: the PubMed record — but only when the primary slot
        // really holds a PubMed ID.
        //
        // The slot does not hold one kind of thing (see
        // ``primaryIdentifierQuery(for:kind:)``), and pasting whatever it holds after
        // the PubMed base URL fabricates a destination rather than naming one. A
        // preprint gave `…/PPR1287966/`, which 404s; an empty slot gave `…//`,
        // PubMed's front page, offered to the reader as this article's full
        // text. Both render as an ordinary publisher link, so a local routing
        // fault reached the reader as a real destination — which is #202's own
        // failure shape, on the very articles this ladder exists to serve.
        //
        // An article with no PubMed ID and no DOI has genuinely nowhere left to
        // point, and `noFullTextAvailable` says so honestly.
        if let pubmedID = Self.pubmedIdentifier(in: pmid, kind: primaryKind),
           let url = URL(string: "\(BioMedLitConstants.pubmedWebBaseURL)/\(pubmedID)/") {
            BioMedLitLib.logger?.info(
                "Falling back to the PubMed record for \(articleName)",
                category: .fullText
            )
            return FullTextResult(
                content: .doi(webURL: url),
                degradation: degradation,
                openAccessShortfall: openAccessShortfall,
                pdfNotSavedFrom: pdfNotSavedFrom
            )
        }

        throw Self.exhaustedChainError(
            primarySlot: pmid,
            primaryKind: primaryKind,
            europePMCShortfall: europePMCShortfall,
            pmcOpenDataShortfall: pmcOpenDataShortfall,
            openAccessShortfall: openAccessShortfall,
            articleName: articleName
        )
    }

    /// The error for a chain that found nothing to return, keeping an absence
    /// apart from an answer that was not established.
    ///
    /// Only ``FullTextError/noFullTextAvailable`` is recorded on the document,
    /// and it takes the retry away for good, so it is returned only when no
    /// source left the question unsettled and no last resort was refused.
    /// Static, and independent of the service's state, so the rule is testable:
    /// the open-access arm is all but unreachable through the chain, because
    /// every fallback returned after the open-access PDFs (Unpaywall's, then
    /// OpenAlex's) carries the shortfall
    /// and the DOI link among them always builds (#475).
    ///
    /// - Parameters:
    ///   - primarySlot: The document's primary identifier slot.
    ///   - primaryKind: What the provider said that slot holds, if it said.
    ///   - europePMCShortfall: What Europe PMC's side got instead of the text.
    ///   - pmcOpenDataShortfall: What PMC's open-data bucket got instead of
    ///     the article's JATS, when it could not be read (#480). Consulted
    ///     only when Europe PMC left no shortfall, so the reader is given one
    ///     sentence.
    ///   - openAccessShortfall: Why the open-access copies (a render of
    ///     another article, Elsevier's API, Unpaywall's and OpenAlex's PDFs,
    ///     CORE) left one unassessed.
    ///   - articleName: How the log names the article.
    /// - Returns: The error to throw.
    static func exhaustedChainError(
        primarySlot: String,
        primaryKind: ArticleIdentifierKind?,
        europePMCShortfall: RequestFailure?,
        pmcOpenDataShortfall: RequestFailure?,
        openAccessShortfall: OpenAccessShortfall?,
        articleName: String
    ) -> FullTextError {
        // Two different answers, and they must not be given the same words.
        //
        // A slot that still holds something we could not classify means the
        // *last resort was refused*, not that the article has nothing. Saying
        // "no full text available" there states a fact about the literature to
        // explain a decision of ours, and the callers record that on the
        // document and take the retry away. The reader is left with a permanent
        // claim that the paper does not exist in full anywhere, which for a
        // PubMed record they can see in a browser is simply false.
        //
        // Only when the kind is genuinely *unresolved*. A stated preprint whose
        // sources are exhausted is not this case: we know exactly what the
        // identifier is, it simply has no PubMed record. It ends in
        // `noFullTextAvailable`, or in one of the two below when a source did
        // not settle it. The refusal this case describes is narrower —
        // nobody said, the shape does not settle it, and no provider vouched.
        let unclassified = primarySlot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unclassified.isEmpty,
           ArticleIdentifierKind.resolved(declared: primaryKind, accession: unclassified) == .unknown {
            BioMedLitLib.logger?.error(
                """
                Exhausted every source for \(articleName) and could not \
                establish that '\(unclassified)' is a PubMed ID, so the PubMed \
                record was not offered
                """,
                category: .fullText
            )
            return .identifierKindUnresolved(unclassified)
        }

        // Nothing was found, but Europe PMC did not settle the question: it
        // could not be asked, or it answered 404 for an article it holds. The
        // callers mark `noFullTextAvailable` on the document for good, so
        // saying it here would take the retry away from an article whose only
        // fault was a busy or closed Europe PMC (#434).
        if let europePMCShortfall {
            BioMedLitLib.logger?.warning(
                "No source served full text for \(articleName), and Europe PMC did not "
                    + "settle it (\(europePMCShortfall.describe()))",
                category: .fullText
            )
            return .absenceNotEstablished(europePMCShortfall)
        }

        // The same for PMC's open-data bucket, which holds the author
        // manuscripts Europe PMC does not serve: one it could not read may
        // have held the article (#480).
        if let pmcOpenDataShortfall {
            BioMedLitLib.logger?.warning(
                "No source served full text for \(articleName), and PMC's open-access "
                    + "collection could not be read (\(pmcOpenDataShortfall.describe()))",
                category: .fullText
            )
            return .pmcOpenDataNotEstablished(pmcOpenDataShortfall)
        }

        // The same for the copies after the render, Elsevier's, Unpaywall's
        // and OpenAlex's: a copy they could not assess is not a copy that
        // does not exist (#475, #480).
        if let openAccessShortfall {
            BioMedLitLib.logger?.warning(
                "No source served full text for \(articleName), and the open-access copy "
                    + "went unassessed (\(openAccessShortfall.source.serviceName): "
                    + "\(openAccessShortfall.reason.described))",
                category: .fullText
            )
            return .openAccessNotEstablished(openAccessShortfall)
        }

        BioMedLitLib.logger?.error("No full text available for \(articleName)", category: .fullText)
        return .noFullTextAvailable
    }
}
