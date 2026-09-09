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
/// 2. **Unpaywall PDF** - Open access PDFs via Unpaywall API
/// 3. **DOI Resolution** - Falls back to opening publisher website
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
    /// extracts, so the article's prose reaches transparency analysis and report
    /// generation. Off, the tier returns the URL alone and nothing is
    /// downloaded, which is the behaviour every caller had before this existed.
    ///
    /// The PDF's URL is reported either way, because extracted text recovers the
    /// prose and loses the figures, tables and layout.
    private let extractPDFText: Bool

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
    public init(
        email: String,
        session: URLSession = FullTextService.makeSession(),
        europePMCService: EuropePMCService = EuropePMCService(),
        extractor: PDFTextExtracting = PDFKitTextExtractor(),
        extractPDFText: Bool = true
    ) {
        self.email = email
        self.europePMCService = europePMCService
        self.session = session
        self.extractor = extractor
        self.extractPDFText = extractPDFText
    }

    /// The transport production uses.
    ///
    /// Separated from ``init(email:session:europePMCService:)`` so a test can
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
    /// Tries sources in order: Europe PMC XML → Unpaywall PDF → DOI website.
    /// Each source is tried with retry logic for transient network failures.
    ///
    /// - Parameters:
    ///   - pmcId: PubMed Central ID (e.g., "PMC1234567").
    ///   - doi: Digital Object Identifier.
    ///   - pmid: PubMed ID (for fallback URL).
    /// - Returns: The content and its source, what the JATS parse of it lost
    ///   (#181), and — when Europe PMC served XML this parser could not read, or
    ///   could not be reached at all — why this is not the best source that
    ///   existed (#183, #186).
    /// - Throws: `FullTextError` if all sources fail, or `CancellationError` if
    ///   the caller cancelled. Cancellation propagates rather than falling
    ///   through, so a link is never cached as this article's full text just
    ///   because the caller went away.
    public func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String
    ) async throws -> FullTextResult {
        BioMedLitLib.logger?.info(
            "Fetching full text for PMID \(pmid) (PMC: \(pmcId ?? "none"), DOI: \(doi ?? "none"))",
            category: .fullText
        )

        // Set when a better source existed and was lost, and attached to
        // whichever fallback the chain returns instead (#183, #186).
        var degradation: FullTextDegradation?

        // A body-less Europe PMC rendering, kept aside until every better tier
        // has had its turn. `nil` when none was seen.
        var abstractOnly: FullTextResult?

        // Resolve PMC ID and PDF render URL from PMID or DOI if not already available
        var resolvedPmcId = pmcId
        var pdfRenderURL: String?
        if resolvedPmcId == nil || resolvedPmcId?.isEmpty == true {
            let resolved = try await resolvePMCIdAndPDFUrl(pmid: pmid, doi: doi)
            resolvedPmcId = resolved.pmcId
            pdfRenderURL = resolved.pdfRenderURL
            // Only when the failure actually cost us the source. A failed PMID
            // search that the DOI search then recovered from cost the reader
            // nothing, and neither does one where a later query answered that
            // this article has no PMC record at all. The XML branch's own
            // outcome decides from here.
            if resolved.lostTheSource {
                degradation = .europePMCUnreachable
            }
        }

        // Try Europe PMC first (best quality - machine readable XML)
        if let pmcId = resolvedPmcId, !pmcId.isEmpty {
            do {
                let content = try await fetchEuropePMCWithRetry(pmcId: pmcId)
                BioMedLitLib.logger?.info(
                    "Successfully retrieved Europe PMC full text for \(pmcId)",
                    category: .fullText
                )
                let parsed = FullTextResult(
                    content: .europePMC(html: content.html, markdown: content.markdown),
                    warnings: content.warnings,
                    contentKind: content.contentKind
                )
                // A body-less deposit is not an article. Returning it here — as
                // this did — made it beat every remaining tier, so an
                // open-access PDF of the same paper was unreachable, and the
                // abstract was cached and scored as an article body. Held back
                // instead, and returned at the end only if nothing better
                // arrives, mirroring bmlib's `_with_abstract_fallback`.
                if content.contentKind == .abstract {
                    BioMedLitLib.logger?.info(
                        "Europe PMC served an abstract-only deposit for \(pmcId); "
                            + "holding it back in case a PDF tier does better",
                        category: .fullText
                    )
                    abstractOnly = parsed
                } else {
                    return parsed
                }
            } catch where error.isCancellation {
                // A cancelled fetch is not a dead source. Falling through would
                // hand back a doi.org link as though Europe PMC had nothing,
                // and cache that as the article's full text.
                //
                // Tested by fact rather than by type: the transport reports
                // cancellation as `URLError.cancelled`, and only the retry
                // backoff raises `CancellationError` — see ``isCancellation``.
                throw CancellationError()
            } catch {
                // Deliberately swallowed: the remaining sources are the reason
                // this method is a chain, and a reader who can be given the
                // publisher's PDF should get it rather than an error.
                //
                // Logged at error rather than warning when the XML was there and
                // this parser could not read it — that is a defect in us, not an
                // absent source, and the two read identically in a log otherwise.
                if case FullTextError.jatsParseFailure(let parseError) = error {
                    // Recorded on every result the chain goes on to return, so
                    // the reader is told that a better source existed and we
                    // could not use it — the half of #183 the log cannot do.
                    degradation = .jatsParseFailed
                    BioMedLitLib.logger?.error(
                        "Europe PMC XML for \(pmcId) was retrieved but could not be parsed "
                            + "(\(parseError)); falling back to a PDF or publisher link",
                        category: .fullText
                    )
                } else if case FullTextError.noFullTextAvailable = error {
                    // The source answered and had nothing. Never a degradation:
                    // a note that fires on every article never deposited as
                    // full text is worthless on the ones where it is true.
                    BioMedLitLib.logger?.warning(
                        "Europe PMC has no machine-readable text for \(pmcId)",
                        category: .fullText
                    )
                } else {
                    // Everything else — a server error that outlasted its
                    // retries, a transport failure, a status we do not model —
                    // means we could not reach the source, not that it was
                    // empty. Those are opposite answers, and collapsing them
                    // tells the reader the evidence base is thin when the
                    // shortfall is ours (#186).
                    degradation = .europePMCUnreachable
                    BioMedLitLib.logger?.warning(
                        "Europe PMC XML could not be retrieved for \(pmcId): "
                            + "\(error.localizedDescription); falling back to a PDF "
                            + "or publisher link",
                        category: .fullText
                    )
                }
            }
        }

        // Try Europe PMC PDF render URL (when XML unavailable but free PDF exists)
        if let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            let (localPath, text) = try await downloadAndExtract(from: pdfURL, pmid: pmid)
            // A PDF tier counts as a success as soon as it has a URL, so a
            // download or extraction that gave nothing would otherwise discard
            // an abstract already in hand and leave the reader a bare link.
            // bmlib's `_with_abstract_fallback` makes the same call.
            if text == nil, abstractOnly != nil {
                BioMedLitLib.logger?.info(
                    "The Europe PMC PDF yielded no text for PMID \(pmid); keeping the abstract",
                    category: .fullText
                )
            } else {
                return FullTextResult(
                    content: .europePMCPDF(pdfURL: pdfURL),
                    degradation: degradation,
                    contentKind: text == nil ? .none : .extracted,
                    extractedText: text,
                    localPDFPath: localPath
                )
            }
        }

        // Try Unpaywall (open access PDFs)
        if let doi = doi, !doi.isEmpty {
            do {
                let pdfURL = try await fetchUnpaywallPDFWithRetry(doi: doi)
                BioMedLitLib.logger?.info(
                    "Successfully found Unpaywall PDF for DOI \(doi)",
                    category: .fullText
                )
                let (localPath, text) = try await downloadAndExtract(from: pdfURL, pmid: pmid)
                if text == nil, abstractOnly != nil {
                    BioMedLitLib.logger?.info(
                        "The Unpaywall PDF yielded no text for PMID \(pmid); keeping the abstract",
                        category: .fullText
                    )
                } else {
                    return FullTextResult(
                        content: .unpaywall(pdfURL: pdfURL),
                        degradation: degradation,
                        contentKind: text == nil ? .none : .extracted,
                        extractedText: text,
                        localPDFPath: localPath
                    )
                }
            } catch where error.isCancellation {
                // As above: a cancelled fetch must not be read as an absent PDF.
                throw CancellationError()
            } catch {
                BioMedLitLib.logger?.warning(
                    "Unpaywall failed for DOI \(doi): \(error.localizedDescription)",
                    category: .fullText
                )
            }
        }

        // The reader gets the abstract rather than a bare link. No web URL is
        // attached to it: `Document.fullTextLinkDestination` already resolves
        // the DOI page or the PubMed record for every document, and a second
        // copy here would give the views two sources for one link.
        if let abstractOnly {
            BioMedLitLib.logger?.info(
                "No tier beat the abstract-only rendering for PMID \(pmid); returning it",
                category: .fullText
            )
            return abstractOnly
        }

        // Fallback to DOI or PubMed URL
        if let doi = doi, !doi.isEmpty,
           let url = URL(string: "\(BioMedLitConstants.doiBaseURL)/\(doi)") {
            BioMedLitLib.logger?.info("Falling back to DOI URL for \(doi)", category: .fullText)
            return FullTextResult(content: .doi(webURL: url), degradation: degradation)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "\(BioMedLitConstants.pubmedWebBaseURL)/\(pmid)/") {
            BioMedLitLib.logger?.info("Falling back to PubMed URL for PMID \(pmid)", category: .fullText)
            return FullTextResult(content: .doi(webURL: url), degradation: degradation)
        }

        BioMedLitLib.logger?.error("No full text available for PMID \(pmid)", category: .fullText)
        throw FullTextError.noFullTextAvailable
    }

    // MARK: - Europe PMC

    /// Fetch full-text XML from Europe PMC with retry logic.
    private func fetchEuropePMCWithRetry(
        pmcId: String
    ) async throws -> (
        html: String, markdown: String, warnings: JATSParseWarnings, contentKind: FullTextContentKind
    ) {
        try await RetryHelper.retry(
            config: .serverError,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.fetchEuropePMCXML(pmcId: pmcId)
        }
    }

    /// Fetch full-text XML from Europe PMC and convert to HTML and markdown.
    ///
    /// Internal rather than private so the parse-to-caller channel can be tested
    /// directly: `fetchFullText` catches everything this throws and falls through
    /// to the PDF and DOI sources, so a parse failure never reaches a caller
    /// through it.
    ///
    /// - Parameter pmcId: PubMed Central ID (with or without "PMC" prefix).
    /// - Returns: The HTML and markdown renderings, and what the parse lost.
    /// - Throws: `FullTextError` on failure.
    func fetchEuropePMCXML(
        pmcId: String
    ) async throws -> (
        html: String, markdown: String, warnings: JATSParseWarnings, contentKind: FullTextContentKind
    ) {
        // Normalize PMC ID (ensure it has the PMC prefix)
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        guard let url = URL(string: "\(BioMedLitConstants.europePMCBaseURL)/\(normalizedId)/fullTextXML") else {
            throw FullTextError.invalidResponse("Invalid PMC ID format")
        }

        BioMedLitLib.logger?.debug("Fetching Europe PMC XML from: \(url.absoluteString)", category: .fullText)

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError("Invalid server response")
        }

        BioMedLitLib.logger?.debug("Europe PMC response status: \(httpResponse.statusCode)", category: .fullText)

        let statusCode = httpResponse.statusCode
        switch statusCode {
        case BioMedLitConstants.httpStatusOK:
            break  // Success, continue to parse
        case BioMedLitConstants.httpStatusNotFound:
            throw FullTextError.noFullTextAvailable
        case _ where BioMedLitConstants.retryableStatusCodes.contains(statusCode):
            // Server errors and rate limiting - retryable
            BioMedLitLib.logger?.warning(
                "Europe PMC server error (\(statusCode)), will retry with backoff",
                category: .fullText
            )
            throw FullTextError.serverError(statusCode: statusCode)
        default:
            throw FullTextError.invalidResponse("HTTP \(statusCode)")
        }

        // Parse JATS XML to both HTML and markdown, passing the known PMC ID for figure URLs
        let parser = JATSXMLParser(data: data, knownPMCId: normalizedId)
        do {
            let html = try parser.parseToHTML()
            // Create a second parser for markdown (XML parser is consumed after first parse)
            let markdownParser = JATSXMLParser(data: data, knownPMCId: normalizedId)
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
            // caller and to the log.
            throw FullTextError.jatsParseFailure(parseError)
        } catch {
            // Unreachable today: the `do` block wraps only the two synchronous
            // parse calls, and `JATSParseError` is the only thing they throw.
            // Kept against an edit that makes this block asynchronous, where an
            // unrelated failure — a cancelled task, say — must not be relabelled
            // as malformed publisher XML.
            //
            // Which means rethrowing it, not naming it. Wrapping it in
            // `xmlParseError` did the relabelling this clause exists to prevent:
            // a cancelled task would have surfaced as "Failed to parse XML:
            // cancelled" and been marked non-retryable. An error we cannot
            // classify travels as itself.
            BioMedLitLib.logger?.error(
                "Unexpected non-JATS error parsing \(normalizedId): \(error)",
                category: .parsing
            )
            throw error
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

        /// The free PDF render URL from the search result, when one was offered.
        let pdfRenderURL: String?

        /// Whether any attempted search threw rather than answering.
        ///
        /// OR-ed across every attempt: one failing leaves us unable to say, on
        /// that attempt's evidence, that the article has no PMC record.
        let searchFailed: Bool

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

        /// Whether the machine-readable source was lost because we could not ask.
        ///
        /// The rule the degradation is raised on, kept here rather than at the
        /// call site so the facts that decide it cannot be recombined
        /// differently by a second consumer.
        ///
        /// Both conjuncts are load-bearing: a search that never failed has
        /// nothing to report, and a record that was matched answers the question
        /// outright. `pmcId == nil` is deliberately *not* a third conjunct —
        /// only a matched record can carry an ID, so a non-nil `pmcId` already
        /// implies `matchedARecord`. Spelling it out anyway would add a check no
        /// test could ever fail, which is how a predicate starts to look
        /// defensive and stops being read.
        var lostTheSource: Bool {
            searchFailed && !matchedARecord
        }

        /// The starting value of a resolution: nothing attempted, nothing learned.
        static let nothingAttempted = PMCResolution(
            pmcId: nil, pdfRenderURL: nil, searchFailed: false, matchedARecord: false
        )

        /// The answer when a search completed and matched nothing.
        ///
        /// Deliberately the same value as ``nothingAttempted``, not a coincidence
        /// to be tidied away: a query that matched nothing taught us nothing, so
        /// it must contribute nothing to the fold. It is named separately because
        /// the two say different things at the call site.
        static let noMatch = nothingAttempted

        /// The answer when a search threw.
        static let failed = PMCResolution(
            pmcId: nil, pdfRenderURL: nil, searchFailed: true, matchedARecord: false
        )

        /// This resolution combined with a later attempt's.
        ///
        /// Every field accumulates, which is the whole point: returning the
        /// attempt that happened to succeed would drop what the earlier ones
        /// learned, and then `searchFailed` would silently mean "the last search
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
                pdfRenderURL: pdfRenderURL ?? next.pdfRenderURL,
                searchFailed: searchFailed || next.searchFailed,
                matchedARecord: matchedARecord || next.matchedARecord
            )
        }
    }

    /// One identifier query, and the identifier it was built from.
    ///
    /// Paired so the log line can name what resolved the article without the
    /// loop having to know which identifier it is on.
    private struct PMCQuery {
        /// How to describe the identifier in a log line.
        let describedAs: String

        /// The Europe PMC query to run.
        let query: String
    }

    /// Resolve a PMC ID and PDF render URL from a PMID or DOI via Europe PMC search.
    ///
    /// Tries PMID first (more specific), then DOI, stopping at the first PMC ID.
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
    ///   - pmid: PubMed ID to resolve.
    ///   - doi: DOI to resolve.
    /// - Returns: What every attempted query learned, merged. A resolution that
    ///   merely matched nothing reports `searchFailed == false`.
    /// - Throws: `CancellationError` if the caller cancelled. Only cancellation
    ///   propagates, so the chain never reads "the caller stopped us" as "this
    ///   article has no PMC record".
    private func resolvePMCIdAndPDFUrl(
        pmid: String?,
        doi: String?
    ) async throws -> PMCResolution {
        var accumulated = PMCResolution.nothingAttempted

        for candidate in Self.identifierQueries(pmid: pmid, doi: doi) {
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
    /// - Parameters:
    ///   - pmid: PubMed ID to resolve, if any.
    ///   - doi: DOI to resolve, if any.
    /// - Returns: A query per identifier that is present and non-empty.
    private static func identifierQueries(pmid: String?, doi: String?) -> [PMCQuery] {
        var queries: [PMCQuery] = []
        if let pmid = pmid, !pmid.isEmpty {
            queries.append(PMCQuery(describedAs: "PMID \(pmid)", query: "ext_id:\(pmid) src:med"))
        }
        if let doi = doi, !doi.isEmpty {
            queries.append(PMCQuery(describedAs: "DOI \(doi)", query: "DOI:\"\(doi)\""))
        }
        return queries
    }

    /// Search Europe PMC and extract PMC ID and PDF render URL from the first result.
    ///
    /// - Parameter query: The Europe PMC query to run.
    /// - Returns: What the first result carried, `noMatch` when the search
    ///   matched nothing, and `failed` when it threw anything but cancellation.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func searchForPMCIdAndPDFUrl(query: String) async throws -> PMCResolution {
        do {
            let result = try await europePMCService.search(
                query: query,
                pageSize: 1,
                requireAbstract: false
            )
            if let firstArticle = result.articles.first {
                let pmcId = firstArticle.pmcId?.isEmpty == false ? firstArticle.pmcId : nil
                // `matchedARecord` regardless of whether it named a PMC ID: the
                // record is Europe PMC's answer about this article either way.
                return PMCResolution(
                    pmcId: pmcId,
                    pdfRenderURL: firstArticle.pdfRenderURL,
                    searchFailed: false,
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
            return .failed
        }
        return .noMatch
    }

    // MARK: - Unpaywall

    /// Fetch PDF URL from Unpaywall with retry logic.
    private func fetchUnpaywallPDFWithRetry(doi: String) async throws -> URL {
        try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.fetchUnpaywallPDF(doi: doi)
        }
    }

    /// Fetch open access PDF URL from Unpaywall.
    ///
    /// - Parameter doi: Digital Object Identifier.
    /// - Returns: URL to downloadable PDF.
    /// - Throws: `FullTextError` on failure.
    private func fetchUnpaywallPDF(doi: String) async throws -> URL {
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
        // reader as "no full text available" -- an outage dressed up as an absent
        // PDF. Caught here instead, where the cause can still be named.
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            let reason = "Unpaywall requires a contact email address; none is configured"
            BioMedLitLib.logger?.error(reason, category: .fullText)
            throw FullTextError.invalidResponse(reason)
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

        guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            if httpResponse.statusCode == BioMedLitConstants.httpStatusNotFound {
                throw FullTextError.noFullTextAvailable
            }
            throw FullTextError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        // Parse Unpaywall response
        let result: UnpaywallResponse
        do {
            result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to decode Unpaywall response: \(error.localizedDescription)",
                category: .fullText
            )
            throw FullTextError.invalidResponse("JSON decode error: \(error.localizedDescription)")
        }

        // Try best OA location first
        if let bestOA = result.bestOaLocation,
           let urlString = bestOA.urlForPdf ?? bestOA.url,
           let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.debug("Found best OA location: \(pdfURL.absoluteString)", category: .fullText)
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let urlString = location.urlForPdf ?? location.url,
               let pdfURL = URL(string: urlString) {
                BioMedLitLib.logger?.debug("Found OA location: \(pdfURL.absoluteString)", category: .fullText)
                return pdfURL
            }
        }

        throw FullTextError.noFullTextAvailable
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
    /// An empty `pmid` is refused outright rather than downloaded uncached.
    /// `cachedPDFPath(for: "")` would otherwise resolve to the same path —
    /// `<cache>/.pdf` — for every article with no PMID, and an empty PMID is a
    /// real, reachable value: `EuropePMCService.swift` builds one as
    /// `result.pmid ?? result.id ?? ""`, and the macOS viewer documents an
    /// empty `pmid` with a non-nil `pmcId` as an ordinary Europe PMC-sourced
    /// article, not a bug. Before this method consulted the cache, every call
    /// re-downloaded, so extraction always read back the bytes it had just
    /// written and the shared filename never mattered; now that a cache hit
    /// short-circuits the download, a second empty-PMID article would
    /// deterministically read back the first one's cached text. Failing here
    /// costs nothing extra: `downloadAndExtract`, this method's only caller,
    /// already treats any thrown, non-cancellation error as "no PDF for this
    /// tier" and falls through to the next source, exactly as it does for a
    /// download that 404s — so refusing needs no new handling and cannot mix
    /// two articles' bytes under one key.
    ///
    /// - Parameters:
    ///   - url: URL to download the PDF from, on a cache miss.
    ///   - pmid: PubMed ID for naming the cached file. Must not be empty.
    /// - Returns: Local file path to the cached PDF.
    /// - Throws: `FullTextError` on failure, including an empty `pmid`.
    public func downloadAndCachePDF(from url: URL, for pmid: String) async throws -> String {
        guard !pmid.isEmpty else {
            throw FullTextError.cachingFailed(
                "empty PMID; refusing to read or write a cache entry shared by every "
                    + "article with no PMID"
            )
        }

        if let cached = Self.cachedPDFPath(for: pmid) {
            BioMedLitLib.logger?.info(
                "Serving the cached PDF for PMID \(pmid) from \(cached)",
                category: .fullText
            )
            return cached
        }

        BioMedLitLib.logger?.info(
            "Downloading PDF for PMID \(pmid) from \(url.absoluteString)",
            category: .fullText
        )

        let (data, response) = try await RetryHelper.retry(
            config: .pdfDownload,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.session.data(from: url)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed("Invalid response")
        }

        // Verify it looks like a PDF by checking magic bytes (%PDF)
        let pdfMagic = Data(BioMedLitConstants.pdfMagicBytes)
        guard data.count > pdfMagic.count,
              data.prefix(pdfMagic.count) == pdfMagic else {
            throw FullTextError.pdfDownloadFailed("Response is not a valid PDF")
        }

        // Cache the PDF
        let filePath = try cachePDF(data: data, for: pmid)
        BioMedLitLib.logger?.info("Cached PDF at: \(filePath)", category: .fullText)

        return filePath
    }

    /// Download a PDF tier's file, cache it, and recover its text.
    ///
    /// An ordinary failure — a 404, a server error, a file PDFKit cannot open —
    /// returns empty-handed and leaves the reader the URL, which is exactly what
    /// this tier returned before extraction existed. Throwing on those would turn
    /// a tier that succeeded into a fall-through to the publisher link.
    ///
    /// Cancellation is the one thing this does not swallow: it propagates as
    /// `CancellationError`, matching every other guard in this file. A cancelled
    /// download is not a dead source, and letting it fall through here would
    /// return a normal, non-throwing result for a fetch the caller walked away
    /// from — caching a bare link as this article's full text, the outcome
    /// `fetchFullText`'s own doc comment promises cannot happen.
    ///
    /// Every empty outcome is logged at warning level, as bmlib does, because a
    /// scan that yields nothing is invisible otherwise and a partial extraction
    /// must not be mistaken for a whole article.
    ///
    /// - Parameters:
    ///   - url: The remote PDF.
    ///   - pmid: PubMed ID, used to name the cached file.
    /// - Returns: The cached path and the recovered text. Both `nil` when the
    ///   flag is off; the text alone `nil` when nothing was recovered.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func downloadAndExtract(
        from url: URL,
        pmid: String
    ) async throws -> (localPath: String?, text: String?) {
        guard extractPDFText else { return (nil, nil) }

        let path: String
        do {
            path = try await downloadAndCachePDF(from: url, for: pmid)
        } catch where error.isCancellation {
            // As above: a cancelled download must not be read as an absent PDF.
            throw CancellationError()
        } catch {
            BioMedLitLib.logger?.warning(
                "Could not download the PDF for PMID \(pmid) from \(url.absoluteString): "
                    + "\(error.localizedDescription); returning the link alone",
                category: .fullText
            )
            return (nil, nil)
        }

        let extraction = extractor.extract(from: URL(fileURLWithPath: path))
        guard extraction.success else {
            BioMedLitLib.logger?.warning(
                "PDF text extraction failed for \(path): "
                    + "\(extraction.errorMessage ?? "no reason reported")",
                category: .fullText
            )
            return (path, nil)
        }
        guard extraction.charCount > 0 else {
            BioMedLitLib.logger?.warning(
                "PDF \(path) yielded no extractable text over \(extraction.pageCount) page(s) — "
                    + "likely a scan; \(extraction.warnings.prefix(3))",
                category: .fullText
            )
            return (path, nil)
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
        return (path, extraction.text)
    }

    /// Save PDF data to the cache directory.
    ///
    /// Refuses an empty `pmid`: see ``downloadAndCachePDF(from:for:)`` for why a
    /// shared key must never be written. `downloadAndCachePDF` already guards
    /// this before it can be reached, but the check is repeated here so this
    /// method cannot write a collision under any future caller either.
    private func cachePDF(data: Data, for pmid: String) throws -> String {
        guard !pmid.isEmpty else {
            throw FullTextError.cachingFailed(
                "empty PMID; refusing to write a cache entry shared by every article "
                    + "with no PMID"
            )
        }

        let cacheDir = Self.pdfCacheDirectory
        let fileURL = cacheDir.appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")

        do {
            try data.write(to: fileURL, options: .atomic)
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
    /// and the method answers `nil` so the next fetch re-downloads. Leaving it
    /// in place would be the worse failure: it would hide a freshly cached PDF
    /// behind it, so the article would re-download on every call for good.
    /// bmlib's issue #71 reaches the same conclusion for the equivalent Python
    /// path.
    ///
    /// Best-effort: a rename that itself fails is logged and the read still
    /// answers `nil`, because turning a recoverable miss into a thrown error
    /// helps nobody.
    ///
    /// An empty `pmid` always answers `nil`, without touching disk. Every
    /// article with no PMID would otherwise share the one path
    /// `<cache>/.pdf` — a real, reachable case (see
    /// ``downloadAndCachePDF(from:for:)``), and this method must not read,
    /// quarantine, or otherwise treat that shared entry as belonging to
    /// whichever article happens to ask first.
    ///
    /// - Parameter pmid: PubMed ID to check.
    /// - Returns: The cached file's path, or `nil` if there is none, `pmid` is
    ///   empty, or the entry was unusable.
    public static func cachedPDFPath(for pmid: String) -> String? {
        guard !pmid.isEmpty else { return nil }

        let fileURL = pdfCacheDirectory
            .appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let magic = Data(BioMedLitConstants.pdfMagicBytes)
        let handle = try? FileHandle(forReadingFrom: fileURL)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: magic.count)) ?? nil

        if let head, head == magic { return fileURL.path }

        BioMedLitLib.logger?.warning(
            "Cached PDF for PMID \(pmid) is not a PDF; quarantining it so the next "
                + "fetch re-downloads instead of serving it forever",
            category: .fullText
        )
        let aside = fileURL.appendingPathExtension("corrupt")
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            BioMedLitLib.logger?.error(
                "Could not quarantine the corrupt cached PDF for PMID \(pmid): "
                    + "\(error.localizedDescription)",
                category: .fullText
            )
        }
        return nil
    }

    /// Delete a cached PDF file.
    ///
    /// - Parameter pmid: PubMed ID of the PDF to delete.
    public static func deleteCachedPDF(for pmid: String) {
        let fileURL = pdfCacheDirectory.appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clear all cached PDFs.
    public static func clearPDFCache() {
        let cacheDir = pdfCacheDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents where fileURL.pathExtension == BioMedLitConstants.pdfExtension {
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

// MARK: - Unpaywall Response Types

/// Response from Unpaywall API.
private struct UnpaywallResponse: Codable {
    /// Best available open access location.
    let bestOaLocation: OALocation?

    /// All available open access locations.
    let oaLocations: [OALocation]?

    enum CodingKeys: String, CodingKey {
        case bestOaLocation = "best_oa_location"
        case oaLocations = "oa_locations"
    }
}

/// Open access location from Unpaywall.
private struct OALocation: Codable {
    /// Landing page URL.
    let url: String?

    /// Direct PDF URL (if available).
    let urlForPdf: String?

    /// Host type (publisher, repository, etc.).
    let hostType: String?

    /// License information.
    let license: String?

    enum CodingKeys: String, CodingKey {
        case url
        case urlForPdf = "url_for_pdf"
        case hostType = "host_type"
        case license
    }
}
