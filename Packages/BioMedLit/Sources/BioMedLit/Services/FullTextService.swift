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

import CryptoKit
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
    private let email: String

    /// URLSession for network requests.
    private let session: URLSession

    /// Europe PMC service for identifier resolution.
    private let europePMCService: EuropePMCService

    /// Recovers text from a downloaded PDF.
    ///
    /// Injectable for the same reason `session` and `europePMCService` are:
    /// without the seam the PDF tiers can only be tested against a real file,
    /// and PDFKit's own behaviour becomes part of every tier test's subject.
    private let extractor: PDFTextExtracting

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
    private let extractPDFText: Bool

    /// Writes a verified PDF's bytes to its cache file.
    ///
    /// Injectable so a test can make the write fail: `pdfCacheDirectory` is a
    /// fixed location, so without this seam a copy served but not cached
    /// (#480) could be tested only at helper level, never through the chain.
    /// Defaults to ``writeAtomically(_:to:)``.
    private let writeCachedPDF: @Sendable (Data, URL) throws -> Void

    /// How the Europe PMC full-text XML fetch retries a transient failure.
    ///
    /// Injectable so a test can pin what a throttle that outlasts its retries
    /// becomes: ``RetryConfiguration/serverError`` waits about seventy-five
    /// seconds (5 + 10 + 20 + 40) before giving up.
    private let europePMCRetry: RetryConfiguration

    /// How each request to PMC's open-data bucket retries a throttle, a 5xx
    /// or a transient transport failure.
    ///
    /// Injectable for the same reason as ``europePMCRetry``: a test pins what a
    /// 503 that outlasts its retries becomes without sleeping through the
    /// backoff. Defaults to ``RetryConfiguration/pmcOpenData``: four
    /// attempts, as Python's; the backoff between them is BioMedLit's own.
    private let pmcOpenDataRetry: RetryConfiguration

    /// How each request to OpenAlex retries a throttle, a 5xx or a transient
    /// transport failure (#480, stage B).
    ///
    /// Injectable for the same reason as ``pmcOpenDataRetry``. Defaults to
    /// ``RetryConfiguration/openAlex``: four attempts, as Python's.
    private let openAlexRetry: RetryConfiguration

    /// The user's CORE API key, trimmed; `nil` when none or blank, and then
    /// CORE is never asked and nothing is recorded (#480, stage C). It travels
    /// in the `Authorization` header alone, never in a URL or a log line.
    private let coreAPIKey: String?

    /// How each request to CORE retries a throttle, a 5xx or a transient
    /// transport failure. Injectable for the same reason as
    /// ``openAlexRetry``. Defaults to ``RetryConfiguration/core``: four
    /// attempts, as Python's.
    private let coreRetry: RetryConfiguration

    /// CORE's session pause, shared by every service in the process (two
    /// consecutive fetches ending in 429 stop CORE being asked). Injectable so
    /// a test owns its own.
    private let coreThrottle: CoreThrottle

    /// Whether this service asks CORE: a non-blank key was given.
    public nonisolated var asksCore: Bool { coreAPIKey != nil }

    /// Hosts this service paces itself on: one slot each (#489 tracks making
    /// it per host across instances, as Python's).
    private enum PacedHost: Hashable {
        case pmcOpenData
        case openAlex
        case core

        var minimumInterval: TimeInterval {
            switch self {
            case .pmcOpenData: return BioMedLitConstants.pmcOpenDataMinimumInterval
            case .openAlex: return BioMedLitConstants.openAlexMinimumInterval
            case .core: return BioMedLitConstants.coreMinimumInterval
            }
        }
    }

    /// When the next request to each paced host may go; reserved before a
    /// request waits, so two fetches interleaving on this actor cannot both
    /// take the same slot.
    private var nextRequest: [PacedHost: Date] = [:]

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
    private static let queryValueAllowed: CharacterSet = {
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
    ///   - coreRetry: How each request to CORE retries a transient failure.
    ///     Defaults to ``RetryConfiguration/core``.
    ///   - coreThrottle: CORE's session pause. Defaults to
    ///     ``CoreThrottle/shared``, the one every service in the process uses.
    ///   - writeCachedPDF: Writes a verified PDF to its cache file. Defaults
    ///     to ``writeAtomically(_:to:)``; injectable so a test can make the
    ///     write fail.
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
        coreRetry: RetryConfiguration = .core,
        coreThrottle: CoreThrottle = .shared,
        writeCachedPDF: @escaping @Sendable (Data, URL) throws -> Void = FullTextService.writeAtomically
    ) {
        self.email = email
        self.europePMCService = europePMCService
        self.session = session
        self.extractor = extractor
        self.extractPDFText = extractPDFText
        self.europePMCRetry = europePMCRetry
        self.pmcOpenDataRetry = pmcOpenDataRetry
        self.openAlexRetry = openAlexRetry
        let trimmedKey = coreAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.coreAPIKey = trimmedKey.isEmpty ? nil : trimmedKey
        self.coreRetry = coreRetry
        self.coreThrottle = coreThrottle
        self.writeCachedPDF = writeCachedPDF
    }

    /// The production cache write: the whole file or none, so a write that
    /// fails midway leaves no partial PDF a later lookup could serve.
    ///
    /// - Parameters:
    ///   - data: The verified PDF bytes.
    ///   - url: The cache file to write.
    /// - Throws: The write's error.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// The transport production uses.
    ///
    /// Separated from ``init(email:session:europePMCService:extractor:extractPDFText:europePMCRetry:pmcOpenDataRetry:openAlexRetry:coreAPIKey:coreRetry:coreThrottle:writeCachedPDF:)``
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
    /// ID, #480) → Europe PMC PDF → Unpaywall PDFs → OpenAlex PDFs → CORE's
    /// extracted text (with the user's key, #480 stage C) → DOI website. Each source is tried with retry logic for transient network
    /// failures. A body-less XML deposit is held back rather than returned, so
    /// the PDF tiers still get their turn.
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
    /// - Returns: The content and its source, what the JATS parse of it lost
    ///   (#181), and — when Europe PMC served XML this parser could not read, or
    ///   could not be reached at all — why this is not the best source that
    ///   existed (#183, #186).
    /// - Throws: When every source is exhausted, `FullTextError`:
    ///   `noFullTextAvailable` when every source answered without it (callers
    ///   record this on the document); `absenceNotEstablished` when Europe PMC
    ///   did not settle it; `pmcOpenDataNotEstablished` when PMC's open-data
    ///   bucket could not be read; `openAccessNotEstablished` when the
    ///   open-access PDFs (Unpaywall's, then OpenAlex's) did not settle it;
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
        primaryKind: ArticleIdentifierKind? = nil
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
                        contentKind: content.contentKind
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
                        contentKind: content.contentKind
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
        if let cacheKey, let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            let outcome = try await downloadAndExtract(from: pdfURL, key: cacheKey)
            if case .notCached = outcome {
                renderNotSavedFrom = pdfURL.absoluteString
            }
            if let result = pdfTierResult(
                outcome: outcome,
                content: .europePMCPDF(pdfURL: pdfURL),
                degradation: degradation,
                holdingAbstract: abstractOnly != nil,
                articleName: articleName,
                linkFallback: &pdfLinkFallback
            ) {
                return result
            }
        }

        // Try Unpaywall (open access PDFs). The DOI is trimmed to the same
        // definition of "blank" `ArticleCacheKey` uses, so the two guards agree
        // about the same input: a whitespace-only DOI keys nothing, and it must
        // not reach Unpaywall either.
        let unpaywallDOI = doi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Why the open-access copy Unpaywall or OpenAlex may know of went
        // unassessed, if it did: Unpaywall, the landing page it named or
        // OpenAlex could not settle whether a free copy exists, a PDF either
        // named could not be obtained (#478; every one is listed, #480), or
        // Unpaywall was not configured. Carried
        // on whatever fallback is returned, so a caller holding a better link
        // than that fallback knows not to trade it away (#464).
        var openAccessShortfall: OpenAccessShortfall?
        // An open-access copy served but not cached (#480): it ends the walk,
        // settles the question, and is the caching note's address
        var openAccessNotSavedFrom: String?
        // Whether any open-access copy was served: not cached, or cached
        // without text while an abstract is held. Either settles the
        // question; only the first ends the walk (a textless copy lets
        // another, OpenAlex's included, be tried for text)
        var openAccessCopyServed = false
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
                    "\($0.source.serviceName): \($0.failure?.describe() ?? "not configured")"
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
                degradation: degradation,
                holdingAbstract: abstractOnly != nil,
                articleName: articleName,
                linkFallback: &pdfLinkFallback,
                shortfall: &openAccessShortfall,
                notSavedFrom: &openAccessNotSavedFrom,
                copyServed: &openAccessCopyServed,
                tried: &triedPDFs
            ) {
                return result
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
                        degradation: degradation,
                        holdingAbstract: abstractOnly != nil,
                        articleName: articleName,
                        linkFallback: &pdfLinkFallback,
                        shortfall: &openAccessShortfall,
                        notSavedFrom: &openAccessNotSavedFrom,
                        copyServed: &openAccessCopyServed,
                        tried: &triedPDFs
                    ) {
                        return result
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
            // failure is an unsettled lookup, as OpenAlex's is (the
            // maintainer's decision, 2026-10-06). No key: never asked, nothing
            // recorded.
            if openAccessNotSavedFrom == nil {
                if let coreAPIKey {
                    switch try await fetchCoreText(doi: doi, apiKey: coreAPIKey) {
                    case .served(let text):
                        BioMedLitLib.logger?.info(
                            "Retrieved CORE's extracted text for DOI \(doi)", category: .fullText
                        )
                        // Text in hand: it beats a held abstract and a link,
                        // and settles the open-access question.
                        return FullTextResult(
                            content: .core(text: text),
                            degradation: degradation,
                            contentKind: .extracted,
                            extractedText: text
                        )
                    case .absent:
                        BioMedLitLib.logger?.info(
                            "CORE holds no text for DOI \(doi)", category: .fullText
                        )
                    case .unreachable(let failure):
                        openAccessShortfall = .adding(
                            OpenAccessShortfall(source: .core, failure: failure), to: openAccessShortfall
                        )
                        BioMedLitLib.logger?.warning(
                            "CORE could not be asked about DOI \(doi) (\(failure.describe())), so any "
                                + "text it holds is not assessed",
                            category: .fullText
                        )
                    }
                } else {
                    BioMedLitLib.logger?.debug(
                        "No CORE API key configured; CORE not asked about DOI \(doi)",
                        category: .fullText
                    )
                }
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
    ///   - openAccessShortfall: Why the open-access PDFs (Unpaywall's, then
    ///     OpenAlex's) left a free copy unassessed.
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

        // The same for the open-access PDFs, Unpaywall's and OpenAlex's: a free
        // copy they could not assess is not a copy that does not exist (#475).
        if let openAccessShortfall {
            BioMedLitLib.logger?.warning(
                "No source served full text for \(articleName), and the open-access copy "
                    + "went unassessed (\(openAccessShortfall.source.serviceName): "
                    + "\(openAccessShortfall.failure?.describe() ?? "not configured"))",
                category: .fullText
            )
            return .openAccessNotEstablished(openAccessShortfall)
        }

        BioMedLitLib.logger?.error("No full text available for \(articleName)", category: .fullText)
        return .noFullTextAvailable
    }

    // MARK: - Europe PMC

    /// The HTML and markdown renderings of a served JATS document, what the
    /// parse lost, and whether it had a body.
    typealias EuropePMCRendering = (
        html: String, markdown: String, warnings: JATSParseWarnings, contentKind: FullTextContentKind
    )

    /// The accession to ask `fullTextXML` by, if the article has one.
    ///
    /// The PMC ID first. A preprint has none, so its `PPR` record ID is next,
    /// as the identifier search found it.
    ///
    /// Only when that search *failed* is the document's own primary slot read
    /// instead, when it is stated (or shaped) as a preprint or a PMC record, so
    /// a throttled search does not cost the article its XML. A search that
    /// answered "no such record" is not second-guessed: asking `fullTextXML`
    /// about an article Europe PMC does not hold only adds a 404. A slot value
    /// is taken only with its prefix: a bare number there may be a PubMed ID,
    /// and `FullTextAccession.normalized` would read it as a PMC ID.
    ///
    /// Internal rather than private so the routing can be tested directly.
    ///
    /// - Parameters:
    ///   - pmcId: The PMC ID the document carries or the search resolved.
    ///   - resolvedPreprintAccession: The `PPR` ID the search resolved.
    ///   - pmid: The document's primary identifier slot.
    ///   - primaryKind: What the record said that slot holds, when it said.
    ///   - searchLostTheSource: Whether the identifier search failed without
    ///     matching a record, the one case the slot is read in.
    /// - Returns: The identifier to fetch by, not yet normalised (the fetch
    ///   does that, and records a refusal), or `nil` when there is none.
    static func fullTextAccession(
        pmcId: String?,
        resolvedPreprintAccession: String?,
        pmid: String?,
        primaryKind: ArticleIdentifierKind?,
        searchLostTheSource: Bool
    ) -> String? {
        if let pmcId = trimmed(pmcId) {
            return pmcId
        }
        if let preprint = trimmed(resolvedPreprintAccession) {
            return preprint
        }
        guard searchLostTheSource, let slot = trimmed(pmid) else { return nil }
        switch ArticleIdentifierKind.resolved(declared: primaryKind, accession: slot) {
        case .preprint:
            return FullTextAccession.prefixed(
                slot, as: BioMedLitConstants.europePMCPreprintAccessionPrefix
            )
        case .pmc:
            return FullTextAccession.prefixed(slot, as: BioMedLitConstants.pmcAccessionPrefix)
        case .pubmed, .europePMCSource, .unknown:
            return nil
        }
    }

    /// Ask Europe PMC for an article's full-text XML, and say what we got.
    ///
    /// Internal rather than private so each outcome can be tested on its own.
    /// Mirrors Python's `EuropePMCClient.fetch_fulltext_xml`.
    ///
    /// - Parameter accession: A PMC ID, with or without its `PMC` prefix, or a
    ///   preprint's `PPR` record ID.
    /// - Returns: The XML; Europe PMC's 404; or why it could not be read, of its
    ///   real kind once the retries are spent — a 429 stays a 429 (#434). A
    ///   blank answer is ``RequestFailure/incompleteResponse``, and an
    ///   identifier that is not an accession is never sent
    ///   (``RequestFailure/requestFailed``, #355). A preprint's 500 is asked
    ///   once, not retried (#451).
    /// - Throws: `CancellationError` if the caller cancelled, and nothing else:
    ///   a cancelled fetch is not a dead source.
    func fetchEuropePMCXML(accession: String) async throws -> FullTextXmlFetch {
        guard let normalized = FullTextAccession.normalized(accession),
              let url = URL(
                string: "\(BioMedLitConstants.europePMCBaseURL)/\(normalized)/fullTextXML"
              )
        else {
            BioMedLitLib.logger?.warning(
                "Not a PMC or preprint accession, so Europe PMC was not asked for its "
                    + "full text: '\(accession)'",
                category: .fullText
            )
            return .unreachable(.requestFailed)
        }

        BioMedLitLib.logger?.debug("Fetching Europe PMC XML from: \(url.absoluteString)", category: .fullText)

        let status: Int
        let body: Data
        do {
            (status, body) = try await RetryHelper.retry(
                config: europePMCRetry,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.requestEuropePMCXML(
                    url,
                    retriesServerFault: !normalized.hasPrefix(
                        BioMedLitConstants.europePMCPreprintAccessionPrefix
                    )
                )
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            // A throttle or server error that outlasted its retries.
            return .unreachable(.httpStatus(statusCode))
        } catch FullTextError.invalidResponse {
            return .unreachable(.malformedResponse)
        } catch {
            return .unreachable(SearchTransport.failure(for: error))
        }

        switch status {
        case BioMedLitConstants.httpStatusOK:
            // An empty answer has told us nothing about the article, so it is
            // an incomplete response, not an absence. It used to be parsed,
            // and reported to the reader as a parse failure.
            guard let served = ServedXML(body) else {
                BioMedLitLib.logger?.warning(
                    "Europe PMC served an empty full text for \(normalized)",
                    category: .fullText
                )
                return .unreachable(.incompleteResponse)
            }
            return .served(served)
        case BioMedLitConstants.httpStatusNotFound:
            BioMedLitLib.logger?.debug(
                "Europe PMC serves no full-text XML for \(normalized)", category: .fullText
            )
            return .absent
        default:
            return .unreachable(.forHTTPStatus(status))
        }
    }

    /// One request for full-text XML, throwing only what is worth retrying.
    ///
    /// - Parameters:
    ///   - url: The `fullTextXML` URL.
    ///   - retriesServerFault: Whether a 500 is treated as transient. It is not
    ///     for a preprint's `PPR` accession: Europe PMC answers a steady 500 for
    ///     text it will not serve, so each retry only repeats it (#451).
    ///     Throttles and gateway faults stay retryable.
    /// - Returns: The status and body of any answer the retry policy does not
    ///   treat as transient.
    /// - Throws: `FullTextError.serverError` for a status in
    ///   `BioMedLitConstants.retryableStatusCodes` (429, 500, 502–504), except
    ///   a 500 when `retriesServerFault` is false (that 500 is returned as a
    ///   status), `FullTextError.invalidResponse` when the answer is not HTTP, and the
    ///   transport's own error otherwise.
    private func requestEuropePMCXML(
        _ url: URL,
        retriesServerFault: Bool = true
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.invalidResponse("Not an HTTP response")
        }

        let statusCode = httpResponse.statusCode
        BioMedLitLib.logger?.debug("Europe PMC response status: \(statusCode)", category: .fullText)
        if BioMedLitConstants.retryableStatusCodes.contains(statusCode),
           retriesServerFault || statusCode != BioMedLitConstants.httpStatusInternalServerError {
            BioMedLitLib.logger?.warning(
                "Europe PMC server error (\(statusCode)), will retry with backoff",
                category: .fullText
            )
            throw FullTextError.serverError(statusCode: statusCode)
        }
        return (statusCode, data)
    }

    // MARK: - PMC's open-data bucket

    /// The PMC accession to ask PMC's open-data bucket by, if `pmcId` is one.
    ///
    /// - Parameter pmcId: The caller's PMC ID or the one the search resolved.
    /// - Returns: For example `"PMC10358571"`; `nil` for a blank value, a
    ///   preprint's `PPR` accession, or anything that is not an accession.
    static func pmcAccession(_ pmcId: String?) -> String? {
        guard let pmcId, let normalized = FullTextAccession.normalized(pmcId),
              normalized.hasPrefix(BioMedLitConstants.pmcAccessionPrefix) else { return nil }
        return normalized
    }

    /// Ask PMC's open-data bucket for the newest version of an article's JATS.
    ///
    /// Three paced requests: the listing, the metadata record, the XML.
    /// Mirrors Python's `PmcOpenDataClient.fetch_xml`; the statuses are pinned
    /// by `fulltext_parity/pmc_open_data.json` ("status"). Internal rather than
    /// private so each outcome can be tested on its own.
    ///
    /// - Parameter pmcid: A PMC ID, with or without its `PMC` prefix. Anything
    ///   else (a preprint, a DOI) is never asked.
    /// - Returns: The XML; `.absent` for a listing naming nothing under the
    ///   article's prefix, or a record whose `xml_url` is missing or `null`;
    ///   otherwise `.unreachable`: any status but 200 (a listing 404 included,
    ///   since S3 answers an article it does not hold with a 200 listing, and
    ///   a 404 after the listing named the record, the bucket disagreeing
    ///   with itself), a body that is not UTF-8 or does not parse, a listing
    ///   naming only unreadable versions, or an `xml_url` that is not this
    ///   bucket's (each ``RequestFailure/malformedResponse``), a blank XML
    ///   (``RequestFailure/incompleteResponse``), or the transport's failure.
    /// - Throws: `CancellationError` if the caller cancelled, and nothing else.
    func fetchPMCOpenDataXML(pmcid: String) async throws -> PMCOpenDataFetch {
        // Not a PMC ID: the bucket files by nothing else, as Python reads it.
        guard let accession = Self.pmcAccession(pmcid) else { return .absent }
        // A request we could not build was never sent: not an absence.
        guard var listing = URLComponents(string: BioMedLitConstants.pmcOpenDataBaseURL + "/")
        else { return .unreachable(.requestFailed) }
        listing.queryItems = [
            URLQueryItem(name: "list-type", value: Self.s3ListObjectsVersion),
            URLQueryItem(name: "prefix", value: "metadata/\(accession)."),
        ]
        guard let listingURL = listing.url else { return .unreachable(.requestFailed) }
        do {
            let (listingStatus, listingBody) = try await bucketGET(listingURL)
            // A 404 included: S3 answers an article it does not hold with a
            // 200 listing naming no version, so a listing 404 is `NoSuchBucket`
            // or something between us and it — never the article's absence.
            guard listingStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.httpStatus(listingStatus))
            }
            let key: String?
            do {
                key = try PMCOpenData.latestMetadataKey(listing: listingBody, pmcid: accession)
            } catch {
                return .unreachable(.malformedResponse)
            }
            guard let key else { return .absent }
            guard let recordURL = URL(string: "\(BioMedLitConstants.pmcOpenDataBaseURL)/\(key)")
            else { return .unreachable(.malformedResponse) }

            let (recordStatus, recordBody) = try await bucketGET(recordURL)
            guard recordStatus == BioMedLitConstants.httpStatusOK else {
                // The listing named it: a 404 here is the bucket disagreeing
                // with itself, recorded as what we got (#432's rule).
                return .unreachable(.httpStatus(recordStatus))
            }
            let record: PMCOpenDataRecord
            do {
                record = try PMCOpenDataRecord(metadata: recordBody)
            } catch {
                return .unreachable(.malformedResponse)
            }
            guard let xmlURL = record.xmlURL else { return .absent }

            let (xmlStatus, xmlBody) = try await bucketGET(xmlURL)
            guard xmlStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.httpStatus(xmlStatus))
            }
            // Strictly UTF-8, as Python decodes it. Without this the parser
            // honours whatever encoding the XML declares and `ServedXML`'s
            // blank test decodes lossily, so bytes we cannot read reached the
            // reader as text.
            guard PMCOpenData.strictUTF8(xmlBody) != nil else {
                return .unreachable(.malformedResponse)
            }
            guard let served = ServedXML(xmlBody) else {
                return .unreachable(.incompleteResponse)
            }
            return .served(served)
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            // A throttle or server error that outlasted its retries.
            return .unreachable(.httpStatus(statusCode))
        } catch FullTextError.invalidResponse {
            return .unreachable(.malformedResponse)
        } catch {
            // Logged by the chain, which knows what it falls through to.
            return .unreachable(SearchTransport.failure(for: error))
        }
    }

    /// S3's `ListObjectsV2` request, the `list-type` the listing asks for.
    private static let s3ListObjectsVersion = "2"

    /// One request to the bucket, retried per ``pmcOpenDataRetry``: 429 and
    /// 5xx, and transient transport failures. Four attempts by default, as
    /// Python's; the backoff is BioMedLit's own (Python's per-host pacer
    /// paces its retries instead).
    ///
    /// - Parameter url: The bucket URL.
    /// - Returns: The status and body of the first answer the retry policy
    ///   does not treat as transient. Its redirects are followed (the bucket
    ///   carries no credential), so every status is an
    ///   ``RequestFailure/httpStatus(_:)`` answer, as Python records it.
    /// - Throws: `FullTextError.serverError` for a status in
    ///   `BioMedLitConstants.retryableStatusCodes` that outlasted its retries,
    ///   `FullTextError.invalidResponse` when the answer is not HTTP,
    ///   `CancellationError` from a wait, and the transport's error.
    private func bucketGET(_ url: URL) async throws -> (status: Int, body: Data) {
        try await RetryHelper.retry(
            config: pmcOpenDataRetry,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.pacedAttempt(url, host: .pmcOpenData)
        }
    }

    /// One attempt at a request to a paced host, paced to its
    /// ``PacedHost/minimumInterval``: every attempt, a retry included, takes
    /// its own pacing slot.
    ///
    /// - Parameters:
    ///   - url: The URL to ask.
    ///   - host: Whose pacing slot the request takes.
    ///   - headers: Header fields to set on the request; none by default.
    /// - Returns: The status and body of an answer that is not transient.
    /// - Throws: `FullTextError.serverError` for a retryable status, so the
    ///   retry sees it; otherwise as ``bucketGET(_:)``.
    private func pacedAttempt(
        _ url: URL, host: PacedHost, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: Data) {
        let now = Date()
        let slot = max(now, nextRequest[host] ?? now)
        nextRequest[host] = slot.addingTimeInterval(host.minimumInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * Double(BioMedLitConstants.nanosecondsPerSecond)))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FullTextError.invalidResponse("Not an HTTP response")
        }
        if BioMedLitConstants.retryableStatusCodes.contains(http.statusCode) {
            throw FullTextError.serverError(statusCode: http.statusCode)
        }
        return (http.statusCode, data)
    }

    // MARK: - OpenAlex (#480, stage B)

    /// Ask OpenAlex which PDFs a work's locations name.
    ///
    /// The contact email is the service's `email`, the one CrossRef already
    /// receives; a blank one asks without `mailto`. The statuses are pinned
    /// by `fulltext_parity/openalex_locations.json` ("status"). Internal
    /// rather than private so each outcome can be tested on its own.
    ///
    /// - Parameter doi: The DOI, trimmed and non-empty.
    /// - Returns: Served URLs (possibly none); absent for a 404; or
    ///   unreachable, of its real kind (a body we cannot read is
    ///   `malformedResponse`).
    /// - Throws: `CancellationError` only.
    func fetchOpenAlexPDFURLs(doi: String) async throws -> OpenAlexFetch {
        let contact = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // A request we could not build was never sent: not an absence.
        guard let url = OpenAlex.workURL(doi: doi, mailto: contact.isEmpty ? nil : contact) else {
            return .unreachable(.requestFailed)
        }
        let answer: (status: Int, body: Data)
        do {
            answer = try await RetryHelper.retry(
                config: openAlexRetry,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.pacedAttempt(url, host: .openAlex)
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            // A throttle or server error that outlasted its retries.
            return .unreachable(.httpStatus(statusCode))
        } catch FullTextError.invalidResponse {
            // As the bucket maps it: an answer that is not HTTP
            return .unreachable(.malformedResponse)
        } catch {
            // Logged by the chain, which knows what it falls through to.
            return .unreachable(SearchTransport.failure(for: error))
        }
        switch answer.status {
        case BioMedLitConstants.httpStatusOK:
            do {
                return .served(try OpenAlex.pdfURLs(fromWork: answer.body))
            } catch {
                return .unreachable(.malformedResponse)
            }
        case BioMedLitConstants.httpStatusNotFound:
            // OpenAlex knows no work by this DOI (it answers with HTML)
            return .absent
        default:
            return .unreachable(.httpStatus(answer.status))
        }
    }

    // MARK: - CORE (#480, stage C)

    /// CORE's extracted text for a DOI (#480, stage C). The key travels in the
    /// `Authorization` header alone. A fetch ending in 429 counts towards the
    /// session pause; any other ending resets it. The statuses are pinned by
    /// `fulltext_parity/core_fulltext.json` ("status"). Internal rather than
    /// private so each outcome can be tested on its own.
    ///
    /// - Parameters:
    ///   - doi: The DOI, trimmed and non-empty.
    ///   - apiKey: The user's CORE key, trimmed and non-empty.
    /// - Returns: Served text when a result is this article's and long enough;
    ///   absent when none is; or unreachable, of its real kind: any status but
    ///   200 (a 404 included: a search's 404 says nothing about the article),
    ///   an answer we cannot read (`malformedResponse`), a transport failure,
    ///   or a session pause (`httpStatus(429)`, no request made).
    /// - Throws: `CancellationError` only.
    func fetchCoreText(doi: String, apiKey: String) async throws -> COREFetch {
        guard !doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        if coreThrottle.isPaused {
            return .unreachable(.httpStatus(BioMedLitConstants.httpStatusRateLimited))
        }
        // A request we could not build was never sent: not an absence.
        guard let url = CORE.searchURL(doi: doi) else { return .unreachable(.requestFailed) }
        let headers = ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        let answer: (status: Int, body: Data)
        do {
            answer = try await RetryHelper.retry(
                config: coreRetry,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.pacedAttempt(url, host: .core, headers: headers)
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            // A throttle or server error that outlasted its retries.
            coreThrottle.record(endedOn: statusCode)
            return .unreachable(.httpStatus(statusCode))
        } catch FullTextError.invalidResponse {
            // As OpenAlex maps it: an answer that is not HTTP
            coreThrottle.record(endedOn: nil)
            return .unreachable(.malformedResponse)
        } catch {
            // Logged by the chain, which knows what it falls through to.
            coreThrottle.record(endedOn: nil)
            return .unreachable(SearchTransport.failure(for: error))
        }
        coreThrottle.record(endedOn: answer.status)
        guard answer.status == BioMedLitConstants.httpStatusOK else {
            return .unreachable(.httpStatus(answer.status))
        }
        do {
            if let text = try CORE.fullText(fromAnswer: answer.body, doi: doi) {
                return .served(text)
            }
            return .absent
        } catch {
            return .unreachable(.malformedResponse)
        }
    }

    /// Convert served JATS XML to HTML and markdown.
    ///
    /// Separate from the fetch so a parse failure — a defect in us — can never
    /// be mistaken for the source's answer, and so it can be tested directly:
    /// `fetchFullText` catches the parse failure and falls through to the PDF
    /// and DOI sources, so it never reaches a caller through it.
    ///
    /// Renders the JATS of either source that serves it: Europe PMC's
    /// `fullTextXML`, or PMC's open-data bucket (#480).
    ///
    /// - Parameters:
    ///   - xml: The JATS XML Europe PMC or PMC's open-data bucket served.
    ///   - accession: The accession it was served under. Passed to the parser
    ///     for figure URLs only when it is a PMC ID: a preprint's figures are
    ///     not filed under its `PPR` ID.
    /// - Returns: The renderings, and what the parse lost.
    /// - Throws: `FullTextError.jatsParseFailure`, with the parser's own error.
    func renderEuropePMCXML(_ xml: Data, accession: String) throws -> EuropePMCRendering {
        let normalized = FullTextAccession.normalized(accession)
        let knownPMCId = normalized.flatMap {
            $0.hasPrefix(BioMedLitConstants.pmcAccessionPrefix) ? $0 : nil
        }
        do {
            let parser = JATSXMLParser(data: xml, knownPMCId: knownPMCId)
            let html = try parser.parseToHTML()
            // Create a second parser for markdown (XML parser is consumed after first parse)
            let markdownParser = JATSXMLParser(data: xml, knownPMCId: knownPMCId)
            let markdown = try markdownParser.parseToMarkdown()
            // Both parsers read the same bytes and so produce the same warnings
            // and the same content kind. The HTML parser's are taken for both
            // because that is the rendering the reader is shown — this is about
            // which instance is authoritative, not about which answer is right.
            return (
                html: html,
                markdown: markdown,
                warnings: parser.parseWarnings,
                contentKind: parser.producedBody ? .fulltext : .abstract
            )
        } catch let parseError as JATSParseError {
            // Kept typed. Flattening it to a string left `.noContent`,
            // `.alreadyParsed` and `.parsingFailed` indistinguishable to every
            // caller and to the log. Any other error travels as itself: it
            // must not be relabelled as malformed publisher XML.
            throw FullTextError.jatsParseFailure(parseError)
        }
    }

    // MARK: - Identifier Resolution

    /// What an identifier resolution learned, including what it could not learn.
    ///
    /// A bare `(pmcId:pdfRenderURL:)` tuple could not tell "Europe PMC has no
    /// record for this article" from "we could not ask Europe PMC" — opposite
    /// answers, the second of which skips the machine-readable source entirely
    /// (#186). It is the same collapse #183 corrected one layer up.
    ///
    /// Two facts are accumulated across the attempts rather than one, because
    /// "no attempt answered" and "an attempt answered about this article" are
    /// themselves opposite answers. A query that matched a record settles the
    /// question however the other queries went; a query that matched *nothing*
    /// only says that query did not match.
    private struct PMCResolution {
        /// The PMC ID, when one was found.
        let pmcId: String?

        /// The preprint's `PPR` record ID, when a matched record was a preprint.
        ///
        /// A preprint has no PMC ID, so without this the XML tier had nothing
        /// to ask by, and a preprint Europe PMC serves in full reached only its
        /// PDF, or nothing (#434).
        let preprintAccession: String?

        /// The free PDF render URL from the search result, when one was offered.
        let pdfRenderURL: String?

        /// Why the first failed search failed, or `nil` when every attempted
        /// search answered.
        ///
        /// Kept across every attempt: one failing leaves us unable to say, on
        /// that attempt's evidence, that the article has no PMC record. Carried
        /// so a chain that ends without full text can say why Europe PMC did
        /// not settle it, rather than only that it did not. The only record of
        /// a failed search, so "a search failed" and "why" cannot disagree.
        let failure: RequestFailure?

        /// Whether any attempted search matched a record for this article.
        ///
        /// Europe PMC answering with a record that names no PMC ID *is* the
        /// absent-source answer: the article is indexed and has no PMC deposit,
        /// so there was never a machine-readable copy to lose. Without this bit
        /// that answer is indistinguishable from having asked nobody, and a
        /// transient failure on an earlier query would report an article that
        /// simply is not in PMC as one we could not reach — the misattribution
        /// this whole channel exists to prevent, inverted (#186).
        let matchedARecord: Bool

        /// Why the machine-readable source was lost because we could not ask,
        /// or `nil` when it was not.
        ///
        /// The rule the degradation is raised on, kept here rather than at the
        /// call site so the facts that decide it cannot be recombined
        /// differently by a second consumer.
        ///
        /// Both conditions are load-bearing: a search that never failed has
        /// nothing to report, and a record that was matched answers the question
        /// outright. `pmcId == nil` is deliberately *not* a third condition —
        /// only a matched record can carry an ID, so a non-nil `pmcId` already
        /// implies `matchedARecord`. Spelling it out anyway would add a check no
        /// test could ever fail, which is how a predicate starts to look
        /// defensive and stops being read.
        var sourceLostTo: RequestFailure? {
            matchedARecord ? nil : failure
        }

        /// The starting value of a resolution: nothing attempted, nothing learned.
        static let nothingAttempted = PMCResolution(
            pmcId: nil, preprintAccession: nil, pdfRenderURL: nil,
            failure: nil, matchedARecord: false
        )

        /// The answer when a search completed and matched nothing.
        ///
        /// Deliberately the same value as ``nothingAttempted``, not a coincidence
        /// to be tidied away: a query that matched nothing taught us nothing, so
        /// it must contribute nothing to the fold. It is named separately because
        /// the two say different things at the call site.
        static let noMatch = nothingAttempted

        /// The answer when a search threw.
        ///
        /// - Parameter failure: Why it threw, by kind.
        /// - Returns: A resolution that learned nothing but the failure.
        static func failed(_ failure: RequestFailure) -> PMCResolution {
            PMCResolution(
                pmcId: nil, preprintAccession: nil, pdfRenderURL: nil,
                failure: failure, matchedARecord: false
            )
        }

        /// This resolution combined with a later attempt's.
        ///
        /// Every field accumulates, which is the whole point: returning the
        /// attempt that happened to succeed would drop what the earlier ones
        /// learned, and then `failure` would silently mean "the last search
        /// failed" rather than "a search failed". The two differ exactly when one
        /// query fails and a later one recovers — and a free PDF URL offered by a
        /// query that found no PMC ID is worth just as much as one offered by the
        /// query that did.
        ///
        /// - Parameter next: What a later attempt learned.
        /// - Returns: The two resolutions merged, preferring the earlier answer
        ///   for the values that can only be answered once.
        func merging(_ next: PMCResolution) -> PMCResolution {
            PMCResolution(
                pmcId: pmcId ?? next.pmcId,
                preprintAccession: preprintAccession ?? next.preprintAccession,
                pdfRenderURL: pdfRenderURL ?? next.pdfRenderURL,
                failure: failure ?? next.failure,
                matchedARecord: matchedARecord || next.matchedARecord
            )
        }
    }

    /// One identifier query, and the identifier it was built from.
    ///
    /// Paired so the log line can name what resolved the article without the
    /// loop having to know which identifier it is on.
    /// Internal rather than private so ``identifierQueries(pmid:pmcId:doi:primaryKind:)`` can be
    /// tested on the query it builds, which is the whole of its behaviour.
    struct PMCQuery {
        /// How to describe the identifier in a log line.
        let describedAs: String

        /// The Europe PMC query to run.
        let query: String
    }

    /// Resolve a PMC ID and PDF render URL from the identifiers a document
    /// carries, via Europe PMC search.
    ///
    /// Tries the primary slot, then the PMC ID, then the DOI — see
    /// ``identifierQueries(pmid:pmcId:doi:primaryKind:)`` — stopping at the first PMC ID.
    /// Also extracts the free PDF render URL from the `fullTextUrlList` in the
    /// search response.
    ///
    /// Written as a fold rather than as two blocks that each accumulate by hand.
    /// The hand-written version had the first attempt assign where the second
    /// OR-ed, which was correct only because the first ran first: a third query
    /// added above it would have silently discarded its failure — the very defect
    /// this accumulation exists to prevent (#186).
    ///
    /// - Parameters:
    ///   - pmid: The document's primary identifier slot.
    ///   - pmcId: PubMed Central ID, when the document already carries one.
    ///     Still worth querying: the record it names carries the free PDF
    ///     render URL this method also collects.
    ///   - doi: DOI to resolve.
    /// - Returns: What every attempted query learned, merged. A resolution that
    ///   merely matched nothing reports no `failure`.
    /// - Throws: `CancellationError` if the caller cancelled. Only cancellation
    ///   propagates, so the chain never reads "the caller stopped us" as "this
    ///   article has no PMC record".
    private func resolvePMCIdAndPDFUrl(
        pmid: String?,
        pmcId: String?,
        doi: String?,
        primaryKind: ArticleIdentifierKind?
    ) async throws -> PMCResolution {
        var accumulated = PMCResolution.nothingAttempted

        for candidate in Self.identifierQueries(
            pmid: pmid, pmcId: pmcId, doi: doi, primaryKind: primaryKind
        ) {
            accumulated = accumulated.merging(
                try await searchForPMCIdAndPDFUrl(query: candidate.query)
            )
            if let pmcId = accumulated.pmcId {
                BioMedLitLib.logger?.info(
                    "Resolved \(candidate.describedAs) to \(pmcId)",
                    category: .fullText
                )
                return accumulated
            }
        }

        return accumulated
    }

    /// The identifier queries worth running, most specific first.
    ///
    /// Internal rather than private so the queries can be tested directly: the
    /// query string *is* this method's behaviour, and asking Europe PMC for an
    /// identifier under a source that cannot hold it fails by matching nothing,
    /// which is indistinguishable from the article not existing.
    ///
    /// Rungs are climbed in the same order ``ArticleCacheKey`` climbs them, so
    /// the most specific identifier is asked for first. The PMC rung matters on
    /// its own: an article can carry a PMC ID and nothing else, and until that
    /// was asked for it resolved no render URL, so such an article reached no
    /// PDF tier at all however the cache was keyed (#202).
    ///
    /// - Parameters:
    ///   - pmid: The document's primary identifier slot, if any. Not only ever
    ///     a PubMed ID — see ``primaryIdentifierQuery(for:kind:)``.
    ///   - pmcId: PubMed Central ID to resolve, if any.
    ///   - doi: DOI to resolve, if any.
    /// - Returns: A query per identifier that is present and not blank, with
    ///   duplicates removed. A PMC-only Europe PMC record arrives with the same
    ///   accession in both the primary slot and `pmcId` — `result.pmid ?? result.id`
    ///   yields the PMC ID when there is no PMID — and both rungs then build the
    ///   byte-identical `PMCID:` query. Left in, that asks Europe PMC the same
    ///   question twice, and on the failure path pays the retry backoff twice,
    ///   for exactly the record class this ladder was added to serve.
    static func identifierQueries(
        pmid: String?,
        pmcId: String?,
        doi: String?,
        primaryKind: ArticleIdentifierKind? = nil
    ) -> [PMCQuery] {
        var queries: [PMCQuery] = []
        if let identifier = trimmed(pmid) {
            queries.append(primaryIdentifierQuery(for: identifier, kind: primaryKind))
        }
        if let pmcId = trimmed(pmcId) {
            queries.append(
                PMCQuery(
                    describedAs: "PMC ID \(pmcId)",
                    query: "\(BioMedLitConstants.europePMCPMCIDField):\(pmcId)"
                )
            )
        }
        if let doi = trimmed(doi) {
            queries.append(PMCQuery(describedAs: "DOI \(doi)", query: "DOI:\"\(doi)\""))
        }

        // Keeps the first of each query string, so the surviving rung is the
        // more specific one and its `describedAs` is the one that names the
        // article in the log.
        var seen: Set<String> = []
        return queries.filter { seen.insert($0.query).inserted }
    }

    /// An identifier with surrounding whitespace removed, or `nil` if nothing
    /// is left. A slot holding only spaces must contribute no query rather than
    /// one asking Europe PMC for the empty string.
    ///
    /// - Parameter identifier: The raw slot value.
    /// - Returns: The trimmed identifier, or `nil` when it holds nothing.
    private static func trimmed(_ identifier: String?) -> String? {
        guard let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// The Europe PMC query that can match the document's primary identifier.
    ///
    /// The slot does not hold one kind of thing. `EuropePMCService` fills it as
    /// `result.pmid ?? result.id ?? ""`, so it carries a PubMed ID for a MEDLINE
    /// record, a `PPR…` accession for a preprint, a PMC ID for a PMC-only
    /// record, and — through that `?? ""` — nothing at all for a record with
    /// neither. Europe PMC answers for each only when asked in its own terms.
    /// Every value was previously asked for as `ext_id:<id> src:med`, which only
    /// a PubMed ID can match.
    ///
    /// The cost fell on preprints. One reached its full text only if it also
    /// carried a DOI, through the rung below, and never by its own accession;
    /// one without a DOI was unreachable despite Europe PMC holding an
    /// open-access PDF for it.
    ///
    /// Routed on the kind the record stated, and only on the accession's shape
    /// where it stated none — see ``ArticleIdentifierKind``. Europe PMC sends
    /// each record's kind and we used to discard it, so every route here was
    /// once a guess from a string (#209). A guess cannot name the sources it
    /// does not know about, and each of those matches nothing when asked as
    /// `src:med`.
    ///
    /// - Parameters:
    ///   - identifier: The trimmed, non-empty primary identifier.
    ///   - kind: What the record said it is, when it said.
    /// - Returns: The query, paired with how to name the identifier in a log.
    private static func primaryIdentifierQuery(
        for identifier: String,
        kind: ArticleIdentifierKind?
    ) -> PMCQuery {
        switch ArticleIdentifierKind.resolved(declared: kind, accession: identifier) {
        case .preprint:
            return PMCQuery(
                describedAs: "preprint \(identifier)",
                query: "ext_id:\(identifier) src:\(BioMedLitConstants.europePMCPreprintSource)"
            )

        case .pmc:
            return PMCQuery(
                describedAs: "PMC ID \(identifier)",
                query: "\(BioMedLitConstants.europePMCPMCIDField):\(identifier)"
            )

        case .europePMCSource(let source):
            return PMCQuery(
                describedAs: "\(source.uppercased()) record \(identifier)",
                query: "ext_id:\(identifier) src:\(source)"
            )

        case .pubmed:
            return PMCQuery(
                describedAs: "PMID \(identifier)",
                query: "ext_id:\(identifier) src:\(BioMedLitConstants.europePMCMedlineSource)"
            )

        // Nothing named this identifier's kind and its shape does not settle it.
        // `src:med` is where such a value has always gone; it matches nothing
        // unless the value really is a PubMed ID, and
        // `searchForPMCIdAndPDFUrl` logs the empty result so the dead end is
        // visible rather than silent.
        case .unknown:
            return PMCQuery(
                describedAs: "identifier \(identifier)",
                query: "ext_id:\(identifier) src:\(BioMedLitConstants.europePMCMedlineSource)"
            )
        }
    }

    /// The primary slot's value, when it really is a PubMed ID.
    ///
    /// Only a PubMed ID may be pasted after the PubMed base URL. The slot also
    /// holds `PPR…` and `PMC…` accessions and can hold nothing at all, and each
    /// of those builds a URL that names no article — see the final fallback in
    /// ``fetchFullText(pmcId:doi:pmid:primaryKind:)`` for what that cost the reader.
    ///
    /// Delegated rather than decided here. Every link and citation surface in
    /// the apps asks the same question, and a rule this consequential answered
    /// separately per surface is how #186 came to be fixed on one of four.
    ///
    /// - Parameters:
    ///   - identifier: The raw primary identifier slot.
    ///   - kind: What is known about the slot — stated by the record, or
    ///     resolved by the caller where a provider had to vouch for it.
    /// - Returns: The trimmed PubMed ID, or `nil` if the slot holds anything else.
    private static func pubmedIdentifier(
        in identifier: String?,
        kind: ArticleIdentifierKind?
    ) -> String? {
        ArticleIdentifierKind.pubmedID(in: identifier, declared: kind)
    }

    /// Search Europe PMC and extract PMC ID and PDF render URL from the first result.
    ///
    /// - Parameter query: The Europe PMC query to run.
    /// - Returns: What the first result carried, `noMatch` when the search
    ///   matched nothing, and `failed` when it threw anything but cancellation.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func searchForPMCIdAndPDFUrl(query: String) async throws -> PMCResolution {
        do {
            // `lookup` sends the query as it is, which is required, not
            // cosmetic. `search` appends ` NOT SRC:PPR` to any query that does
            // not already contain that literal, so this ladder once asked
            // `DOI:"…" NOT SRC:PPR` — a filter that cannot match a preprint by
            // construction, which is the one record class the DOI rung is the
            // recovery path for. Verified against the live API: the DOI of a
            // `SRC:PPR` record returns one hit, and none once the exclusion is
            // appended. The accession rung only ever worked because `src:ppr`
            // happens to contain `SRC:PPR` as a substring.
            //
            // A preprint filter belongs to discovery, where the reader is asking
            // what the literature holds. This is a lookup of one known article
            // by its own identifier, and the answer is not ours to filter.
            //
            // Sending the query unchanged is also what lets the `noMatch` line
            // below name the string that was actually sent.
            let records = try await europePMCService.lookup(query: query, pageSize: 1)
            if let firstArticle = records.first {
                let pmcId = firstArticle.pmcId?.isEmpty == false ? firstArticle.pmcId : nil
                // The record's own ID, not the primary slot: a preprint that also
                // has a PubMed ID fills the slot with that. Taken only in its
                // prefixed form, so nothing else is asked for as a preprint.
                let preprintAccession = firstArticle.identifierKind == .preprint
                    ? firstArticle.europePMCRecordID.flatMap {
                        FullTextAccession.prefixed(
                            $0, as: BioMedLitConstants.europePMCPreprintAccessionPrefix
                        )
                    }
                    : nil
                // `matchedARecord` regardless of whether it named a PMC ID: the
                // record is Europe PMC's answer about this article either way.
                return PMCResolution(
                    pmcId: pmcId,
                    preprintAccession: preprintAccession,
                    pdfRenderURL: firstArticle.pdfRenderURL,
                    failure: nil,
                    matchedARecord: true
                )
            }
        } catch where error.isCancellation {
            // As above: cancelling the search must not be read as "this article
            // has no PMC record", which would skip the Europe PMC branch whole.
            throw CancellationError()
        } catch {
            // Warning rather than debug: "Europe PMC has nothing for this
            // article" and "we could not ask Europe PMC" are opposite answers,
            // and this one skips the machine-readable source entirely. The
            // returned flag is what carries that distinction to the reader; the
            // log line only ever carried it to us.
            BioMedLitLib.logger?.warning(
                "PMC ID resolution failed for query '\(query)': \(error.localizedDescription)",
                category: .fullText
            )
            return .failed(
                (error as? SourceRequestError)?.failure ?? SearchTransport.failure(for: error)
            )
        }

        // Names the query that matched nothing. A zero-hit search is the one
        // outcome that says nothing to the reader — `noMatch` merges as
        // `nothingAttempted`, no degradation is recorded, and both PDF tiers are
        // then skipped — so without this line, a query aimed at a source that
        // cannot answer it is indistinguishable from an article Europe PMC has
        // never heard of. That indistinguishability *is* #202, and the routing
        // above still falls through to `src:med` for any accession shape it does
        // not yet recognise.
        BioMedLitLib.logger?.info(
            "Europe PMC matched no record for query '\(query)'",
            category: .fullText
        )
        return .noMatch
    }

    // MARK: - Unpaywall

    /// Why the Unpaywall tier could not settle whether an open-access copy
    /// exists, as opposed to its being told there is none.
    ///
    /// Private to the tier: the chain turns it into the result's
    /// ``FullTextResult/openAccessShortfall`` and goes on, as it does for any
    /// Unpaywall miss.
    private enum UnpaywallTierFailure: Error {
        /// Unpaywall was not configured, answered with an error status other
        /// than 404 or in a form that could not be read, named an address the
        /// tier cannot fetch, or the landing page it named could not be read;
        /// the shortfall names which.
        case unsettled(OpenAccessShortfall)
    }

    /// What Unpaywall's answer offers: every PDF URL it names, and the choice
    /// that picks the landing page when it names none.
    private struct UnpaywallFetch {
        /// Every location's `url_for_pdf`, deduplicated, best location first.
        let pdfURLs: [String]

        /// The landing page to read when ``pdfURLs`` is empty.
        let choice: UnpaywallLandingPage.Choice
    }

    /// Every PDF address Unpaywall offers for a DOI, best location first,
    /// reading a landing page only when no location names a PDF (#464, #480).
    ///
    /// Addresses are returned as given: one the chain cannot fetch is refused
    /// by ``tryOpenAccessPDFs``, per address, so it no longer stops the
    /// locations after it. The landing page is read outside the Unpaywall
    /// retry, with its own: a slow repository must not send the same question
    /// to Unpaywall again.
    ///
    /// - Parameter doi: Digital Object Identifier.
    /// - Returns: The PDF addresses; empty when Unpaywall answered 404, named
    ///   no PDF, and no landing page declared one.
    /// - Throws: `UnpaywallTierFailure` when Unpaywall was not configured,
    ///   answered with any other error status or unreadably, or its landing
    ///   page could not be read or fetched; `CancellationError`; whatever else
    ///   the Unpaywall request throws.
    private func fetchUnpaywallPDFCandidates(doi: String) async throws -> [String] {
        let fetched: UnpaywallFetch
        do {
            fetched = try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.fetchUnpaywallChoice(doi: doi)
            }
        } catch FullTextError.noFullTextAvailable {
            return []
        }
        if !fetched.pdfURLs.isEmpty { return fetched.pdfURLs }
        guard case .page(let landing) = fetched.choice else { return [] }
        // Python's `requests` refuses the same addresses, and the page is
        // recorded as unread (#474)
        guard let pageURL = UnpaywallLandingPage.fetchableURL(landing) else {
            throw Self.unfetchableAddress(landing, source: .landingPage)
        }
        switch try await readLandingPage(pageURL) {
        case .declared(let pdfURL):
            return [pdfURL.absoluteString]
        case .declaresNone:
            return []
        case .unreachable(let failure):
            throw UnpaywallTierFailure.unsettled(
                OpenAccessShortfall(source: .landingPage, failure: failure)
            )
        }
    }

    /// The failure for an address Unpaywall gave that the tier cannot fetch.
    ///
    /// - Parameters:
    ///   - address: The address, as Unpaywall gave it.
    ///   - source: The lookup it left unsettled: the PDF for a `url_for_pdf`,
    ///     the landing page for a page.
    /// - Returns: The tier failure to throw, a failed request.
    private static func unfetchableAddress(
        _ address: String, source: OpenAccessSource
    ) -> UnpaywallTierFailure {
        BioMedLitLib.logger?.warning(
            "Unpaywall named an address that cannot be fetched ('\(address)'), so the "
                + "open-access copy is not assessed",
            category: .fullText
        )
        return .unsettled(OpenAccessShortfall(source: source, failure: .requestFailed))
    }

    /// What an Unpaywall tier failure left unsettled, if anything.
    ///
    /// - Parameter error: What `fetchUnpaywallPDFCandidates` threw, other than
    ///   cancellation.
    /// - Returns: The lookup that went unsettled and why; `nil` for an error
    ///   that is no source failing to answer: a fault in our own request
    ///   (`invalidResponse`: the base URL or the email could not be encoded), or
    ///   a DOI that could not be sent (`noIdentifiers`). A missing email arrives
    ///   as `UnpaywallTierFailure`, so the reader is told it was not configured.
    private static func openAccessShortfall(for error: Error) -> OpenAccessShortfall? {
        let failure: RequestFailure
        switch error {
        case UnpaywallTierFailure.unsettled(let shortfall):
            return shortfall
        case FullTextError.serverError(let statusCode):
            failure = .httpStatus(statusCode)
        case FullTextError.networkError:
            failure = .connection
        case FullTextError.invalidResponse, FullTextError.noIdentifiers:
            return nil
        default:
            failure = SearchTransport.failure(for: error)
        }
        return OpenAccessShortfall(source: .unpaywall, failure: failure)
    }

    /// Read a landing page Unpaywall names for the PDF it declares.
    ///
    /// A page served as a PDF is the PDF (a repository bitstream link); the
    /// download's `%PDF` check still has the last word. An HTML page, or one
    /// of no stated type, is read up to ``BioMedLitConstants/landingPageMaxBytes``
    /// for the tag, decoded by its declared charset or as UTF-8. The page
    /// itself is never returned as a PDF otherwise.
    ///
    /// A throttle or server fault in ``BioMedLitConstants/retryableStatusCodes``
    /// is retried; one that outlasts the retries, any other status that
    /// ``UnpaywallLandingPage/webPageStatusUnsettled(_:)`` calls unsettled,
    /// and a transport failure are ``UnpaywallLandingPage/Read/unreachable(_:)``:
    /// a page that could not answer is not a page without a PDF.
    ///
    /// - Parameter pageURL: The landing page.
    /// - Returns: What the read settled.
    /// - Throws: `CancellationError` when cancelled, and nothing else.
    private func readLandingPage(_ pageURL: URL) async throws -> UnpaywallLandingPage.Read {
        var request = URLRequest(url: pageURL)
        request.setValue(BioMedLitConstants.landingPageAccept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                let (bytes, response) = try await self.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FullTextError.invalidResponse("Invalid server response")
                }
                // A 429 or a 500/502/503/504 is "not now": retried, and if it
                // outlasts the retries, a page that could not answer
                if BioMedLitConstants.retryableStatusCodes.contains(http.statusCode) {
                    throw FullTextError.serverError(statusCode: http.statusCode)
                }
                return (http, try await Self.landingPageBody(bytes, response: http))
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch {
            let failure: RequestFailure
            switch error {
            case FullTextError.serverError(let statusCode):
                failure = .httpStatus(statusCode)
            case FullTextError.invalidResponse:
                failure = .malformedResponse
            default:
                failure = SearchTransport.failure(for: error)
            }
            BioMedLitLib.logger?.warning(
                "The open-access copy's landing page \(pageURL.absoluteString) could not be "
                    + "read (\(failure.describe())), so any PDF it declares is not assessed",
                category: .fullText
            )
            return .unreachable(failure)
        }

        let status = response.statusCode
        if status >= BioMedLitConstants.httpErrorStatusMin {
            if UnpaywallLandingPage.webPageStatusUnsettled(status) {
                BioMedLitLib.logger?.warning(
                    "The open-access copy's landing page \(pageURL.absoluteString) answered "
                        + "HTTP \(status), so any PDF it declares is not assessed",
                    category: .fullText
                )
                return .unreachable(.httpStatus(status))
            }
            BioMedLitLib.logger?.info(
                "The open-access copy's landing page answered HTTP \(status); no PDF from it",
                category: .fullText
            )
            return .declaresNone
        }
        let finalURL = response.url ?? pageURL
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains(BioMedLitConstants.landingPagePDFMarker) {
            BioMedLitLib.logger?.info(
                "The open-access copy's landing page is itself a PDF: \(finalURL.absoluteString)",
                category: .fullText
            )
            return .declared(finalURL)
        }
        if !contentType.isEmpty && !contentType.contains(BioMedLitConstants.landingPageHTMLMarker) {
            BioMedLitLib.logger?.info(
                "The open-access copy's landing page is \(contentType), not HTML; no PDF declared",
                category: .fullText
            )
            return .declaresNone
        }
        let html = UnpaywallLandingPage.pageText(data, textEncodingName: response.textEncodingName)
        guard let pdfURL = UnpaywallLandingPage.citationPDFURL(html: html, pageURL: finalURL) else {
            BioMedLitLib.logger?.info(
                "The open-access copy's landing page \(pageURL.absoluteString) declares no PDF",
                category: .fullText
            )
            return .declaresNone
        }
        BioMedLitLib.logger?.info(
            "The open-access copy's landing page declares \(pdfURL.absoluteString)",
            category: .fullText
        )
        return .declared(pdfURL)
    }

    /// Read a landing page's body, up to ``BioMedLitConstants/landingPageMaxBytes``,
    /// if it is going to be parsed.
    ///
    /// Nothing is read of a body the page is not going to be parsed from: an
    /// error status or a type that is not HTML is settled by its headers, so
    /// a large file served as the page is not downloaded here.
    ///
    /// - Parameters:
    ///   - bytes: The body as it streams.
    ///   - response: The page's response.
    /// - Returns: The bytes read, at most the cap; nothing when it is not read.
    /// - Throws: Whatever the stream throws.
    private static func landingPageBody(
        _ bytes: URLSession.AsyncBytes, response: HTTPURLResponse
    ) async throws -> Data {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard response.statusCode < BioMedLitConstants.httpErrorStatusMin,
              contentType.isEmpty || contentType.contains(BioMedLitConstants.landingPageHTMLMarker)
        else { return Data() }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= BioMedLitConstants.landingPageMaxBytes { break }
        }
        return body
    }

    /// Ask Unpaywall which URLs it offers for a DOI.
    ///
    /// - Parameter doi: Digital Object Identifier.
    /// - Returns: Every PDF URL it names, and the choice of PDF, landing page,
    ///   or neither.
    /// - Throws: `FullTextError.noFullTextAvailable` for a 404;
    ///   `FullTextError.serverError` for a 429, 500, 502, 503 or 504, so it is
    ///   retried; `UnpaywallTierFailure` for no configured email, any other
    ///   status of 400 or above, and an answer that will not decode.
    private func fetchUnpaywallChoice(doi: String) async throws -> UnpaywallFetch {
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FullTextError.noIdentifiers
        }

        // The email goes in through URLComponents rather than being interpolated
        // into a URL string, so the scheme comes from ``unpaywallBaseURL`` rather
        // than being spelled out here. Unpaywall requires the address as the
        // caller's identity, so it has to arrive exactly as configured.
        //
        // Each guard below names the thing that actually failed. The DOI cannot
        // influence the scheme and the address cannot influence the path, so an
        // error message that blames the wrong one sends the reader to the wrong
        // file.
        guard var components = URLComponents(string: "\(BioMedLitConstants.unpaywallBaseURL)/\(encodedDOI)") else {
            let reason = "Unpaywall base URL '\(BioMedLitConstants.unpaywallBaseURL)' is not a valid URL"
            BioMedLitLib.logger?.error(reason, category: .fullText)
            throw FullTextError.invalidResponse(reason)
        }

        // Unpaywall answers 422 for a missing address, which would surface to the
        // reader as "Unpaywall did not serve it", blaming the article for our
        // configuration. Not asked, it is reported as not configured, with the
        // advice that goes with that (Python's `usable_unpaywall_email`).
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            BioMedLitLib.logger?.error(
                "Unpaywall requires a contact email address; none is configured", category: .fullText
            )
            throw UnpaywallTierFailure.unsettled(.unpaywallNotConfigured)
        }

        // `addingPercentEncoding` is total for any `String` Swift can hold, so
        // this is a formality rather than address validation -- the emptiness
        // check above is what actually rejects a bad value.
        guard let encodedEmail = trimmedEmail.addingPercentEncoding(
            withAllowedCharacters: Self.queryValueAllowed
        ) else {
            let reason = "Contact email address could not be percent-encoded"
            BioMedLitLib.logger?.error(reason, category: .fullText)
            throw FullTextError.invalidResponse(reason)
        }
        components.percentEncodedQueryItems = [URLQueryItem(name: "email", value: encodedEmail)]

        guard let url = components.url else {
            let reason = "Unpaywall base URL '\(BioMedLitConstants.unpaywallBaseURL)' produced no usable URL"
            BioMedLitLib.logger?.error(reason, category: .fullText)
            throw FullTextError.invalidResponse(reason)
        }

        // Not reachable while ``unpaywallBaseURL`` is the https literal it is
        // today. It stands so that editing that constant cannot silently
        // downgrade the transport carrying the reader's email address.
        guard url.scheme == "https" else {
            let reason = "Unpaywall base URL must use https, got '\(url.scheme ?? "no scheme")' "
                + "-- check BioMedLitConstants.unpaywallBaseURL"
            BioMedLitLib.logger?.error(reason, category: .fullText)
            throw FullTextError.invalidResponse(reason)
        }

        // Path only: the query carries the reader's email address, which has no
        // place in a log file.
        BioMedLitLib.logger?.debug("Fetching Unpaywall data for DOI: \(doi)", category: .fullText)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError("Invalid server response")
        }

        BioMedLitLib.logger?.debug("Unpaywall response status: \(httpResponse.statusCode)", category: .fullText)

        // Below 400 the answer is decoded, as Python's `raise_for_status` lets it
        // through: a 204's empty body is then an answer that could not be read,
        // not an error status Unpaywall answered with.
        guard httpResponse.statusCode < BioMedLitConstants.httpErrorStatusMin else {
            if httpResponse.statusCode == BioMedLitConstants.httpStatusNotFound {
                throw FullTextError.noFullTextAvailable
            }
            // A throttle or server fault is retried, and one that outlasts the
            // retries leaves the tier unsettled rather than empty
            if BioMedLitConstants.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw FullTextError.serverError(statusCode: httpResponse.statusCode)
            }
            // Any other error status leaves it unsettled too, unretried: only a
            // 404 says Unpaywall holds no record of the DOI. Python records every
            // such status as a failed lookup (`pdf_discovery`), and the reader is
            // told the copy went unassessed in the same words (#466).
            throw UnpaywallTierFailure.unsettled(
                OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(httpResponse.statusCode))
            )
        }

        // Parse Unpaywall response. An answer we cannot read has told us
        // nothing about the article, so it is not an absence either.
        let result: UnpaywallResponse
        do {
            result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to decode Unpaywall response: \(error.localizedDescription)",
                category: .fullText
            )
            throw UnpaywallTierFailure.unsettled(
                OpenAccessShortfall(source: .unpaywall, failure: .malformedResponse)
            )
        }

        // A PDF is `url_for_pdf` only. A location's `url` is its landing page
        // whenever `url_for_pdf` is missing, and is returned as a page to read,
        // never as the PDF: downloading it stored a repository page as the
        // article (#464). Every location's PDF is offered, best first, so one
        // copy refused does not end the tier (#480). An answer offering
        // neither leaves `fetchUnpaywallPDFCandidates` nothing to try.
        return UnpaywallFetch(
            pdfURLs: UnpaywallLandingPage.pdfURLs(from: result),
            choice: UnpaywallLandingPage.choose(from: result)
        )
    }

    // MARK: - PDF Caching

    /// Return this article's cached PDF, downloading it first if there is none.
    ///
    /// The cache check is step one, as `doc/cross_platform/fulltext_retrieval.md`
    /// specifies for every platform. Without it this method re-downloaded on
    /// every call — a second fetch of bytes already on disk — and
    /// ``cachedPDFPath(for:)``'s validation and quarantine had no production
    /// caller at all, so a corrupt entry was never moved aside by anything but a
    /// test. A cached entry that fails validation is quarantined there and reads
    /// as a miss, which is exactly what makes the download below the repair.
    ///
    /// The article is named by an ``ArticleCacheKey`` rather than by a PMID,
    /// because a PMID is not the only identifier an article has and was not
    /// always present. An empty PMID used to be refused outright — correctly,
    /// since every such article would otherwise share one entry — but that cost
    /// those articles their extraction entirely (#202). The key falls back to
    /// the PMC ID and then the DOI, and only an article carrying none of the
    /// three has no name to file bytes under. No *key* can be constructed for
    /// such an article — the article itself certainly exists — so this method,
    /// which takes a key, has no refusal left to make.
    ///
    /// - Parameters:
    ///   - url: URL to download the PDF from, on a cache miss.
    ///   - key: Names the article the bytes belong to.
    /// - Returns: Local file path to the cached PDF.
    /// - Throws: `FullTextError` on failure.
    public func downloadAndCachePDF(from url: URL, for key: ArticleCacheKey) async throws -> String {
        if let cached = Self.cachedPDFPath(for: key, from: url) {
            BioMedLitLib.logger?.info(
                "Serving the cached PDF for \(key.logDescription) from \(cached)",
                category: .fullText
            )
            return cached
        }

        BioMedLitLib.logger?.info(
            "Downloading PDF for \(key.logDescription) from \(url.absoluteString)",
            category: .fullText
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await RetryHelper.retry(
                config: .pdfDownload,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.session.data(from: url)
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch {
            throw FullTextError.pdfDownloadFailed(SearchTransport.failure(for: error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.pdfDownloadFailed(.malformedResponse)
        }
        guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed(.httpStatus(httpResponse.statusCode))
        }

        // Verify it looks like a PDF by checking magic bytes (%PDF). A login
        // page or a bot wall's challenge served with a 200 stops here (#480).
        let pdfMagic = Data(BioMedLitConstants.pdfMagicBytes)
        guard data.count > pdfMagic.count,
              data.prefix(pdfMagic.count) == pdfMagic else {
            throw FullTextError.pdfDownloadFailed(.malformedResponse)
        }

        // Cache the PDF
        let filePath = try cachePDF(data: data, for: key, from: url)
        BioMedLitLib.logger?.info("Cached PDF at: \(filePath)", category: .fullText)

        return filePath
    }

    /// What a PDF tier's download-and-extract attempt produced.
    ///
    /// Five outcomes rather than a `(path?, text?)` pair, because two of them
    /// used to share `(nil, nil)` and the tier could not tell them apart. It
    /// therefore keyed its decision to try the next tier on whether an abstract
    /// happened to be in hand, so a Europe PMC render URL that 404s ended the
    /// chain and an open-access Unpaywall copy of the same paper was never
    /// fetched. "We chose not to look" and "we looked and the source is dead"
    /// call for opposite moves.
    private enum PDFTierOutcome {
        /// Extraction is switched off, so nothing was downloaded.
        case notAttempted

        /// The source did not serve the PDF, and why (#478): the status, the
        /// transport failure, or `malformedResponse` for a body that is not a
        /// PDF.
        case downloadFailed(RequestFailure)

        /// The source served the PDF, and it could not be cached. A fault of
        /// ours, which says nothing about the copy, so its link is kept even
        /// for a PDF Unpaywall named (#478).
        case notCached

        /// The file is on disk and holds no recoverable prose — a scan, or a
        /// document PDFKit declined to open.
        ///
        /// Carries coverage whenever a page count is known, so the reader can
        /// be told that nothing was recovered. That covers a scan and a
        /// password-protected file alike — PDFKit reports a page count for a
        /// locked document even though it hands back no text. `nil` only when
        /// the file could not be opened at all, where there is nothing to
        /// count and the reason went to the log.
        case noText(localPath: String, coverage: PDFExtractionCoverage?)

        /// Prose was recovered, and this much of the document yielded it.
        case extracted(localPath: String, text: String, coverage: PDFExtractionCoverage)
    }

    /// Download a PDF tier's file, cache it, and recover its text.
    ///
    /// An ordinary failure — a 404, a server error, a file PDFKit cannot open —
    /// is reported as an outcome rather than thrown. Throwing on those would
    /// turn a tier that merely came up empty into a hard failure of the whole
    /// chain.
    ///
    /// Cancellation is the one thing this does not swallow: it propagates as
    /// `CancellationError`, matching every other guard in this file. A cancelled
    /// download is not a dead source, and letting it fall through here would
    /// return a normal, non-throwing result for a fetch the caller walked away
    /// from — caching a bare link as this article's full text, the outcome
    /// `fetchFullText`'s own doc comment promises cannot happen. The check after
    /// extraction is what makes the extractor's own early exit safe: it stops
    /// mid-document on cancellation, and the partial value it returns is
    /// discarded here rather than reported as a real extraction.
    ///
    /// Every empty outcome is logged at warning level, as bmlib does, because a
    /// scan that yields nothing is invisible otherwise and a partial extraction
    /// must not be mistaken for a whole article.
    ///
    /// - Parameters:
    ///   - url: The remote PDF.
    ///   - key: Names the article, and so the cached file. Non-optional: a
    ///     document carrying no identifier at all reaches no PDF tier in the
    ///     first place, so there is no refusal for this method to make. See
    ///     ``fetchFullText(pmcId:doi:pmid:primaryKind:)``.
    /// - Returns: What the attempt produced. See ``PDFTierOutcome``.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func downloadAndExtract(
        from url: URL,
        key: ArticleCacheKey
    ) async throws -> PDFTierOutcome {
        guard extractPDFText else { return .notAttempted }

        let path: String
        do {
            path = try await downloadAndCachePDF(from: url, for: key)
        } catch where error.isCancellation {
            // As above: a cancelled download must not be read as an absent PDF.
            throw CancellationError()
        } catch {
            BioMedLitLib.logger?.warning(
                "Could not download the PDF for \(key.logDescription) from "
                    + "\(url.absoluteString): \(error.localizedDescription); "
                    + "trying the next source",
                category: .fullText
            )
            if case FullTextError.pdfDownloadFailed(let failure) = error {
                return .downloadFailed(failure)
            }
            // The only other failure the download throws is the cache write's
            return .notCached
        }

        let extraction = extractor.extract(from: URL(fileURLWithPath: path))
        // Before anything is read off `extraction`: the extractor stops early
        // when cancelled, so a cancelled read looks exactly like a short
        // document unless the cancellation is asked about first.
        try Task.checkCancellation()

        guard extraction.success else {
            BioMedLitLib.logger?.warning(
                "PDF text extraction failed for \(path): "
                    + "\(extraction.errorMessage ?? "no reason reported")",
                category: .fullText
            )
            // The page count survives a failed read when PDFKit could open the
            // document enough to count pages — a locked file, typically. Passed
            // on so the reader learns that no text reached any analysis, rather
            // than being shown a document that looks entirely ordinary.
            return .noText(
                localPath: path,
                coverage: extraction.pageCount > 0 ? extraction.coverage : nil
            )
        }
        guard extraction.charCount > 0 else {
            BioMedLitLib.logger?.warning(
                "PDF \(path) yielded no extractable text over \(extraction.pageCount) page(s) — "
                    + "likely a scan; "
                    + "\(extraction.warnings.prefix(BioMedLitConstants.loggedPageWarningLimit))",
                category: .fullText
            )
            return .noText(localPath: path, coverage: extraction.coverage)
        }
        if !extraction.isComplete {
            BioMedLitLib.logger?.warning(
                "PDF \(path) extracted only \(extraction.convertedPages) of "
                    + "\(extraction.pageCount) pages — the attached text is incomplete",
                category: .fullText
            )
        }
        BioMedLitLib.logger?.info(
            "Extracted \(extraction.charCount) chars of text from PDF \(path)",
            category: .fullText
        )
        return .extracted(localPath: path, text: extraction.text, coverage: extraction.coverage)
    }

    /// Turn a PDF tier's outcome into the result to return, or `nil` to let the
    /// chain try the next tier.
    ///
    /// Shared by the Europe PMC PDF tier and, through ``tryOpenAccessPDFs``,
    /// every open-access PDF Unpaywall or OpenAlex names, so they cannot decide
    /// this differently — the render and Unpaywall tiers once had one copy of
    /// the rule each, and only one of them was ever updated.
    ///
    /// - Parameters:
    ///   - outcome: What the download and extraction produced.
    ///   - content: The content value to attach to a returned result.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    ///   - holdingAbstract: Whether a body-less rendering is being kept in
    ///     reserve. A tier that recovered nothing must not displace it.
    ///   - articleName: How to name this article in the log line.
    ///   - linkFallback: Set to a link-only result when a download failed, so
    ///     the chain can still offer the URL if no later tier does better.
    ///     First writer wins: the earliest tier is the best-quality source.
    /// - Returns: The result to return, or `nil` to continue the chain.
    private func pdfTierResult(
        outcome: PDFTierOutcome,
        content: FullTextContent,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        linkFallback: inout FullTextResult?
    ) -> FullTextResult? {
        switch outcome {
        case .downloadFailed, .notCached:
            // Try the next tier, but keep the URL. Returning it here — which is
            // what this did, because a failed download was indistinguishable
            // from "extraction is switched off" — ended the chain on a link we
            // had just proved we could not fetch, so an open-access Unpaywall
            // copy of the same paper was never tried. Held in reserve instead:
            // a link we could not download is still better than a publisher
            // page, and still worse than a copy a later tier actually retrieves.
            // Only the render tier arrives here with either: a PDF an
            // open-access source named is handled by `tryOpenAccessPDFs`,
            // which refuses one not served (#478) and keeps one not cached
            // with its caching note (#480).
            if linkFallback == nil {
                linkFallback = FullTextResult(content: content, degradation: degradation)
            }
            return nil

        case .notAttempted:
            // Nothing was downloaded because nothing was meant to be. The URL
            // is still worth handing over, unless an abstract is in reserve —
            // a bare link does not beat a rendering of the article's abstract.
            if holdingAbstract { return nil }
            return FullTextResult(content: content, degradation: degradation)

        case .noText(let localPath, let coverage):
            if holdingAbstract {
                BioMedLitLib.logger?.info(
                    "The \(content.source.displayName) PDF yielded no text for \(articleName); "
                        + "keeping the abstract",
                    category: .fullText
                )
                return nil
            }
            // The file is real even though its prose is not, so the path goes
            // with it: a scan is still worth showing the reader. The coverage
            // goes too, so the reader is told that nothing was recovered —
            // otherwise a scan displays as an ordinary article while every
            // analysis of it silently ran on no text at all.
            return FullTextResult(
                content: content,
                degradation: degradation,
                contentKind: .none,
                localPDFPath: localPath,
                extractionCoverage: coverage
            )

        case .extracted(let localPath, let text, let coverage):
            return FullTextResult(
                content: content,
                degradation: degradation,
                contentKind: .extracted,
                extractedText: text,
                localPDFPath: localPath,
                extractionCoverage: coverage
            )
        }
    }

    /// Try each PDF a source named, in order, until one is served (#480).
    ///
    /// An address already tried is skipped. An address the chain cannot
    /// fetch, or a download the source refused, is added to the shortfall
    /// under `source`, with its address: the reader is told every copy that
    /// went unassessed. **The first copy served ends the walk:** extracted, it
    /// is the result; served but not cached, its link becomes the link
    /// fallback (it beats any held), its address is the caching note, and no
    /// further candidate is asked, saving being our problem, not the source's.
    /// A copy cached without text while an abstract is held settles the
    /// question too, but the walk goes on for a copy with text.
    ///
    /// The caching note's address is the URL the link is kept under
    /// (`absoluteString`), so the app can tell whether the link it stored is
    /// that copy's.
    ///
    /// - Parameters:
    ///   - addresses: The PDF addresses, as the source gave them.
    ///   - source: Whose PDF a failure is recorded against (`.pdf`, `.openAlexPDF`).
    ///   - content: The result content for an address.
    ///   - cacheKey: Names the article, and so the cached file.
    ///   - degradation: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:)``.
    ///   - holdingAbstract: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:)``.
    ///   - articleName: How to name this article in the log.
    ///   - linkFallback: The chain's link fallback.
    ///   - shortfall: What went unsettled so far; added to.
    ///   - notSavedFrom: Set to the address of a copy served but not cached.
    ///   - copyServed: Set when a copy is served, whether not cached or
    ///     cached without text: either settles the open-access question.
    ///   - tried: Addresses already asked, across sources; updated.
    /// - Returns: The result to return, or `nil` to go on down the chain.
    /// - Throws: `CancellationError`.
    private func tryOpenAccessPDFs(
        _ addresses: [String],
        refusedAs source: OpenAccessSource,
        content: (URL) -> FullTextContent,
        cacheKey: ArticleCacheKey,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        linkFallback: inout FullTextResult?,
        shortfall: inout OpenAccessShortfall?,
        notSavedFrom: inout String?,
        copyServed: inout Bool,
        tried: inout Set<String>
    ) async throws -> FullTextResult? {
        for address in addresses where tried.insert(address).inserted {
            // An address we cannot fetch leaves that copy unassessed, not
            // absent (#474): refused, recorded against the PDF, not the source
            // that answered (#478). Python's `requests` refuses the same.
            guard let pdfURL = UnpaywallLandingPage.fetchableURL(address) else {
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: .requestFailed, address: address),
                    to: shortfall
                )
                BioMedLitLib.logger?.warning(
                    "\(source.serviceName) for \(articleName) is at an address that cannot be "
                        + "fetched ('\(address)'), so that copy is not assessed",
                    category: .fullText
                )
                continue
            }
            let outcome = try await downloadAndExtract(from: pdfURL, key: cacheKey)
            switch outcome {
            case .downloadFailed(let failure):
                // Refused, not offered (#478): not held as a link fallback,
                // and the reader is told of it on whatever the chain returns
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: failure, address: address),
                    to: shortfall
                )
                BioMedLitLib.logger?.warning(
                    "\(source.serviceName) at \(OpenAccessShortfall.host(of: address)) could not be "
                        + "obtained for \(articleName) (\(failure.describe()))",
                    category: .fullText
                )
                continue
            case .notCached:
                linkFallback = FullTextResult(content: content(pdfURL), degradation: degradation)
                notSavedFrom = pdfURL.absoluteString
                copyServed = true
                return nil
            case .noText:
                // Obtained, so the question is settled; with an abstract held
                // the walk goes on for a copy with text
                copyServed = true
                if let result = pdfTierResult(
                    outcome: outcome,
                    content: content(pdfURL),
                    degradation: degradation,
                    holdingAbstract: holdingAbstract,
                    articleName: articleName,
                    linkFallback: &linkFallback
                ) {
                    return result
                }
            case .notAttempted, .extracted:
                if let result = pdfTierResult(
                    outcome: outcome,
                    content: content(pdfURL),
                    degradation: degradation,
                    holdingAbstract: holdingAbstract,
                    articleName: articleName,
                    linkFallback: &linkFallback
                ) {
                    return result
                }
            }
        }
        return nil
    }

    /// The shortfall the fallbacks carry (#480): a copy served, whether not
    /// cached or cached without text, settles the open-access question, so
    /// nothing that went unsettled is told then. `FullTextResult.init` asserts the same of the link itself.
    ///
    /// - Parameters:
    ///   - shortfall: What went unsettled in the open-access tiers.
    ///   - copyServed: Whether an open-access copy was served: not cached, or
    ///     cached without text while an abstract is held.
    /// - Returns: The shortfall to carry, or `nil` when the question is settled.
    static func settledOpenAccessShortfall(
        _ shortfall: OpenAccessShortfall?, copyServed: Bool
    ) -> OpenAccessShortfall? {
        copyServed ? nil : shortfall
    }

    /// Save PDF data to the cache directory.
    ///
    /// - Parameters:
    ///   - data: The verified PDF bytes.
    ///   - key: Names the article the entry belongs to.
    ///   - url: The remote PDF the bytes came from. Part of the key, so a
    ///     second source for the same article gets its own entry rather than
    ///     overwriting the first — see ``cacheFilename(key:url:)``.
    /// - Returns: The path the bytes were written to.
    /// - Throws: `FullTextError.cachingFailed` on a failed write.
    private func cachePDF(data: Data, for key: ArticleCacheKey, from url: URL) throws -> String {
        let cacheDir = Self.pdfCacheDirectory
        let fileURL = cacheDir.appendingPathComponent(Self.cacheFilename(key: key, url: url))

        do {
            try writeCachedPDF(data, fileURL)
            return fileURL.path
        } catch {
            BioMedLitLib.logger?.error("Failed to cache PDF: \(error.localizedDescription)", category: .fullText)
            throw FullTextError.cachingFailed(error.localizedDescription)
        }
    }

    /// Get the cache directory for PDF files.
    public static var pdfCacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = appSupport
            .appendingPathComponent(BioMedLitConstants.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.pdfCacheFolderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to create PDF cache directory: \(error.localizedDescription)",
                category: .fullText
            )
        }

        return cacheDir
    }

    /// The cached PDF for a document, or `nil` when there is none usable.
    ///
    /// Validated rather than merely existence-checked. `downloadAndCachePDF`
    /// verifies the magic bytes on the way in; this did not check them on the
    /// way out, so a caller would have been handed the path to an entry
    /// corrupted by anything outside this service — an interrupted restore, a
    /// sync eviction, a file written by an older build — and would have kept
    /// treating it as the article's full text indefinitely, since nothing
    /// downstream re-validates a path it already has.
    ///
    /// A failing entry is renamed rather than deleted, so it can be inspected,
    /// and the method answers `nil` so the next fetch re-downloads. Those two
    /// facts are the whole justification: the entry stops being served as this
    /// article's text, and its bytes stay available to whoever investigates.
    ///
    /// Note bmlib's issue #71 argues something stronger for the Python path —
    /// that a bad entry left in place *hides* a freshly cached copy behind it —
    /// and that reasoning does not transfer here. It is a property of bmlib's
    /// two-tier cache, which consults an HTML entry before the PDF one. This
    /// cache holds a single entry per article and source URL, and a re-download
    /// overwrites it atomically, so there is nothing for a corrupt entry to
    /// hide.
    ///
    /// Best-effort: a rename that itself fails is logged and the read still
    /// answers `nil`, because turning a recoverable miss into a thrown error
    /// helps nobody.
    ///
    /// Every article is named by an ``ArticleCacheKey``, which cannot be built
    /// without at least one identifier, so there is no shared `<cache>/.pdf`
    /// entry for this method to mistake for any particular article's (#202).
    ///
    /// - Parameters:
    ///   - key: Names the article to check for.
    ///   - url: The remote PDF the caller wants. Part of the key — see
    ///     ``cacheFilename(key:url:)``.
    /// - Returns: The cached file's path, or `nil` if there is none or the
    ///   entry was unusable.
    public static func cachedPDFPath(for key: ArticleCacheKey, from url: URL) -> String? {
        let fileURL = pdfCacheDirectory
            .appendingPathComponent(cacheFilename(key: key, url: url))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let magic = Data(BioMedLitConstants.pdfMagicBytes)
        let handle = try? FileHandle(forReadingFrom: fileURL)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: magic.count)) ?? nil

        if let head, head == magic { return fileURL.path }

        BioMedLitLib.logger?.warning(
            "Cached PDF for \(key.logDescription) is not a PDF; quarantining it so the next "
                + "fetch re-downloads instead of serving it forever",
            category: .fullText
        )
        let aside = fileURL.appendingPathExtension(BioMedLitConstants.quarantinedPDFExtension)
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            BioMedLitLib.logger?.error(
                "Could not quarantine the corrupt cached PDF for \(key.logDescription): "
                    + "\(error.localizedDescription)",
                category: .fullText
            )
        }
        return nil
    }

    /// The filename one article's copy of one PDF is cached under.
    ///
    /// Keyed on the source URL as well as the article, because an article can
    /// be offered more than one PDF — Europe PMC's render URL and Unpaywall's
    /// open-access copy are different files of the same paper. Keyed on the
    /// PMID alone, the first tier to download won the entry and every later
    /// tier was served *its* bytes: the chain then returned that file as the
    /// Unpaywall result, recorded `fullTextSource = "unpaywall"` over a Europe
    /// PMC download, and never fetched the copy that might have extracted
    /// cleanly.
    ///
    /// The article half comes from ``ArticleCacheKey``, which sanitises or
    /// digests the identifier it holds — identifiers reach us from search
    /// results, and `appendingPathComponent` on a value holding `/` or `..`
    /// would place the file outside the cache directory.
    ///
    /// Entries written before the URL became part of the key, or before the key
    /// named the *kind* of identifier it holds (#202), simply never match: they
    /// are re-downloaded once, and the old entries are then orphaned rather than
    /// replaced. ``deleteCachedPDF(for:)`` matches on the tagged prefix, so it
    /// cannot find them either, and only ``clearPDFCache()`` reclaims them. That
    /// is still the cheap direction to be wrong in — a stale entry costs one
    /// download and some disk, while serving the wrong article's bytes costs the
    /// reader a wrong answer.
    ///
    /// `Hasher` is deliberately not used for the fingerprint: Swift seeds it
    /// per process, so a filename built from it would change on every launch
    /// and every entry would miss forever.
    ///
    /// Internal rather than private so a test can name the file it is about to
    /// plant without duplicating the key derivation — a duplicate that would
    /// keep passing if the real one changed.
    ///
    /// - Parameters:
    ///   - key: Names the article this entry belongs to.
    ///   - url: The remote PDF this entry holds.
    /// - Returns: The filename, including extension.
    static func cacheFilename(key: ArticleCacheKey, url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fingerprint = digest
            .prefix(BioMedLitConstants.cacheKeyFingerprintBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(key.filenameComponent)-\(fingerprint).\(BioMedLitConstants.pdfExtension)"
    }

    /// Delete every cached PDF for a document.
    ///
    /// Plural because one article can hold an entry per source URL — see
    /// ``cacheFilename(key:url:)``. Quarantined entries go too: they belong to
    /// the same article and are of no use once it is being discarded.
    ///
    /// - Parameter key: Names the article whose PDFs are to be deleted.
    public static func deleteCachedPDF(for key: ArticleCacheKey) {
        let articleName = key.filenameComponent
        let cacheDir = pdfCacheDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in contents
        where fileURL.lastPathComponent.hasPrefix("\(articleName)-")
            || fileURL.lastPathComponent.hasPrefix("\(articleName).") {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Whether "clear cache" should remove this file.
    ///
    /// A separate predicate so it can be tested without calling
    /// ``clearPDFCache()``, which empties the *real* user cache directory — a
    /// test that called it would delete the PDFs of whoever ran the suite.
    ///
    /// - Parameter fileURL: A file found in the cache directory.
    /// - Returns: `true` for a cached PDF or a quarantined one.
    static func isClearableCacheEntry(_ fileURL: URL) -> Bool {
        fileURL.pathExtension == BioMedLitConstants.pdfExtension
            || fileURL.pathExtension == BioMedLitConstants.quarantinedPDFExtension
    }

    /// Clear all cached PDFs.
    ///
    /// Quarantined entries are removed too. Filtering on the `pdf` extension
    /// alone left every `.corrupt` file behind, so the bytes a quarantine set
    /// aside for inspection accumulated in a directory the user had explicitly
    /// asked to empty, and "clear cache" did not clear the cache.
    public static func clearPDFCache() {
        let cacheDir = pdfCacheDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents where Self.isClearableCacheEntry(fileURL) {
                try FileManager.default.removeItem(at: fileURL)
            }
            BioMedLitLib.logger?.info("Cleared PDF cache", category: .fullText)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to clear PDF cache: \(error.localizedDescription)",
                category: .fullText
            )
        }
    }
}
