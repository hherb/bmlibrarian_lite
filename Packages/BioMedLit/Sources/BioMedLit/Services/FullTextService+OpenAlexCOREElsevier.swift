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

extension FullTextService {
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
    /// session pause; any other ending resets it. A fetch ending in 401 marks
    /// this key refused for the session (#498); another key is asked as usual.
    /// The statuses are pinned by
    /// `fulltext_parity/core_fulltext.json` ("status"). Internal rather than
    /// private so each outcome can be tested on its own. A blank DOI sends
    /// nothing and is `.absent`, which records nothing, exactly as not asking
    /// does; callers ask only with a DOI.
    ///
    /// - Parameters:
    ///   - doi: The DOI, trimmed and non-empty (``CORE/bareDOI(_:)``).
    ///   - apiKey: The user's CORE key, trimmed and non-empty.
    /// - Returns: Served text when a result is this article's and long enough;
    ///   absent when none is; or unreachable, of its real kind: any status but
    ///   200 (a 404 included: a search's 404 says nothing about the article),
    ///   an answer we cannot read (`malformedResponse`), a transport failure,
    ///   or a session pause (`httpStatus(429)`, no request made); or
    ///   `keyRefused` for a 401, and for every later fetch with that key (no
    ///   request made).
    /// - Throws: `CancellationError` only.
    func fetchCoreText(doi: String, apiKey: String) async throws -> COREFetch {
        guard !doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        // The key before the pause: it is the cause the reader can act on (#498).
        // Only the refused key is refused: a corrected one is asked again.
        let keyDigest = CORE.keyDigest(apiKey)
        if coreThrottle.refuses(keyDigest: keyDigest) { return .keyRefused }
        if coreThrottle.isPaused {
            return .unreachable(.httpStatus(BioMedLitConstants.httpStatusRateLimited))
        }
        // A request we could not build was never sent: not an absence.
        guard let url = CORE.searchURL(doi: doi) else { return .unreachable(.requestFailed) }
        // URLSession drops `Authorization` from a redirected request, to any
        // host (observed on Darwin 27, CFNetwork 3896), so the key never
        // follows a redirect elsewhere, as Python and OkHttp ensure by hand.
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
            coreThrottle.record(endedOn: statusCode, keyDigest: keyDigest)
            return .unreachable(.httpStatus(statusCode))
        } catch FullTextError.invalidResponse {
            // As OpenAlex maps it: an answer that is not HTTP
            coreThrottle.record(endedOn: nil, keyDigest: keyDigest)
            return .unreachable(.malformedResponse)
        } catch {
            // Logged by the chain, which knows what it falls through to.
            coreThrottle.record(endedOn: nil, keyDigest: keyDigest)
            return .unreachable(SearchTransport.failure(for: error))
        }
        coreThrottle.record(endedOn: answer.status, keyDigest: keyDigest)
        if answer.status == BioMedLitConstants.coreKeyRefusedStatus { return .keyRefused }
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

    // MARK: - Elsevier's Article API (#480, stage C2)

    /// Ask Elsevier's Article API for one Elsevier article's PDF, and save it
    /// beside its cache name under the document's cache key, where it waits for
    /// its title check (#480, stage C2; #560).
    ///
    /// The checks that make no request come first, in the contract's order
    /// (``Elsevier/answerWithoutAsking(session:keyDigest:credentialsDigest:sendable:)``);
    /// a fetch that asks is classified by ``Elsevier/classify(status:headers:body:)``
    /// and recorded by ``Elsevier/record(_:endedOn:in:keyDigest:credentialsDigest:)``.
    /// The key travels in `X-ELS-APIKey` and the token in `X-ELS-Insttoken`
    /// alone; a redirect is never followed, as it would carry them wherever it
    /// points, so a 3xx is classified as the status it is. Internal rather than
    /// private so each outcome can be tested on its own.
    ///
    /// - Parameters:
    ///   - doi: The DOI, as the document carries it; an Elsevier DOI.
    ///   - cacheKey: Names the article, and so the cached file.
    /// - Returns: `.cached` with the cached PDF's path when this article's PDF
    ///   from Elsevier is already on disk (no request made, whatever the
    ///   session holds; checked when it is read); `.downloaded` for a PDF just
    ///   served, written beside its cache name, which the caller must pass to
    ///   ``admit(staged:cachePath:title:)`` (that removes the waiting file
    ///   whatever it decides); `.absent` for a 404 or a first page only
    ///   (logged at INFO, never served), and for a call without a key or an
    ///   Elsevier DOI, which sends nothing and records nothing; unreachable, of
    ///   its real kind (a paused Elsevier is `httpStatus(429)`, no request
    ///   made); the refused key or credentials; or `.notSaved` for a PDF served
    ///   and not written.
    /// - Throws: `CancellationError` only.
    func fetchElsevierPDF(doi: String, cacheKey: ArticleCacheKey) async throws -> ElsevierFetch {
        guard let apiKey = elsevierAPIKey, Elsevier.isEligible(doi: doi) else { return .absent }
        // The cache first, as every PDF tier consults it: a read is no request,
        // so the checks below keep their order, and a PDF saved earlier (on the
        // institution's network, say) is served even when Elsevier would now
        // refuse or is paused, without spending the weekly quota. A corrupt
        // entry is quarantined and reads as a miss.
        if let url = Elsevier.articleURL(doi: doi), let cached = Self.cachedPDFPath(for: cacheKey, from: url) {
            BioMedLitLib.logger?.info(
                "Serving the cached PDF from \(BioMedLitConstants.elsevierServiceName) for DOI \(doi) "
                    + "at \(cached)",
                category: .fullText
            )
            return .cached(localPath: cached)
        }
        let keyDigest = KeyDigest.key(apiKey)
        let credentialsDigest = KeyDigest.credentials(key: apiKey, token: elsevierInstToken)
        let sendable = Elsevier.isSendable(key: apiKey, token: elsevierInstToken)
        if let unasked = Elsevier.answerWithoutAsking(
            session: elsevierSession, keyDigest: keyDigest, credentialsDigest: credentialsDigest,
            sendable: sendable
        ) {
            if !sendable, unasked == .unreachable(.requestFailed) {
                // Never the value: only that the settings hold one that cannot be sent
                BioMedLitLib.logger?.warning(
                    "The Elsevier API key or institutional token in the settings holds a "
                        + "character that cannot be sent in a request (often an invisible one "
                        + "pasted with it); \(BioMedLitConstants.elsevierServiceName) is not "
                        + "asked. Enter it again.",
                    category: .fullText
                )
            }
            return Self.elsevierFetch(for: unasked)
        }
        // A request we could not build was never sent: not an absence.
        guard let url = Elsevier.articleURL(doi: doi) else { return .unreachable(.requestFailed) }
        var request = URLRequest(url: url)
        request.timeoutInterval = BioMedLitConstants.pdfDownloadTimeout
        request.setValue(apiKey, forHTTPHeaderField: BioMedLitConstants.elsevierKeyHeader)
        if let token = elsevierInstToken {
            request.setValue(token, forHTTPHeaderField: BioMedLitConstants.elsevierTokenHeader)
        }
        request.setValue(BioMedLitConstants.elsevierAccept, forHTTPHeaderField: "Accept")

        let answer: ElsevierAnswer
        let status: Int?
        let body: Data
        do {
            let (response, data) = try await RetryHelper.retry(
                config: elsevierRetry,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.elsevierAttempt(request)
            }
            status = response.statusCode
            body = data
            // Straight to the classifier, a 3xx included: the contract's
            // `http_status`, never a refused redirect
            answer = Elsevier.classify(
                status: response.statusCode, headers: Self.headerFields(of: response), body: data
            )
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            // A throttle or server error that outlasted its retries.
            (answer, status, body) = (.unreachable(.httpStatus(statusCode)), statusCode, Data())
        } catch FullTextError.invalidResponse {
            // As OpenAlex maps it: an answer that is not HTTP
            (answer, status, body) = (.unreachable(.malformedResponse), nil, Data())
        } catch {
            // Logged by the chain, which knows what it falls through to.
            (answer, status, body) = (.unreachable(SearchTransport.failure(for: error)), nil, Data())
        }
        Elsevier.record(
            answer, endedOn: status, in: elsevierSession, keyDigest: keyDigest,
            credentialsDigest: credentialsDigest
        )
        guard answer == .served else {
            if answer == .firstPageOnly {
                BioMedLitLib.logger?.info(
                    "\(BioMedLitConstants.elsevierServiceName) served only the first page for DOI "
                        + "\(doi): this requestor is not entitled to the article; not used",
                    category: .fullText
                )
            }
            return Self.elsevierFetch(for: answer)
        }
        // Beside its cache name until its title check lets it in (#560)
        let cachePath = Self.cachePath(for: cacheKey, from: url)
        let staged = Self.stagedPath(beside: cachePath)
        do {
            // The unlogged write: the one ERROR below names the consequence
            try writeCachedPDF(body, URL(fileURLWithPath: staged))
            return .downloaded(stagedPath: staged, cachePath: cachePath)
        } catch {
            Self.discardStaged(staged)
            // Never a link: the article URL needs the key. The chain records it
            // as an unsettled lookup unless a later copy is served.
            BioMedLitLib.logger?.error(
                "\(BioMedLitConstants.elsevierServiceName) served the PDF for DOI \(doi), and it "
                    + "could not be saved on this device (\(error.localizedDescription))",
                category: .fullText
            )
            return .notSaved
        }
    }

    /// What a fetch learned from an answer that is not a PDF served: a first
    /// page is no article, so an absence.
    ///
    /// - Parameter answer: The answer, classified or given without asking.
    /// - Returns: The fetch's outcome. `.served` never reaches here (the caller
    ///   saves it); were it to, it is unreachable, never an absence.
    private static func elsevierFetch(for answer: ElsevierAnswer) -> ElsevierFetch {
        switch answer {
        case .served:
            assertionFailure("A served answer is saved by the caller, not mapped")
            return .unreachable(.requestFailed)
        case .absent, .firstPageOnly: return .absent
        case .unreachable(let failure): return .unreachable(failure)
        case .keyRefused: return .keyRefused
        case .networkRefused: return .networkRefused
        }
    }

    /// One attempt at Elsevier's API, paced to
    /// ``BioMedLitConstants/elsevierMinimumInterval``: every attempt, a retry
    /// included, takes its own slot.
    ///
    /// Redirects are refused (``RedirectRefusingTaskDelegate``), so a 3xx comes
    /// back as the answer. The body arrives whole, as URLSession's data task
    /// reads it; of an error body only the first
    /// ``BioMedLitConstants/elsevierErrorBodyMaxBytes`` are examined, for the
    /// token, and nothing of it is logged or kept.
    ///
    /// - Parameter request: The article request, its headers set.
    /// - Returns: The response, its headers included, and the body.
    /// - Throws: `FullTextError.serverError` for a retryable status, so the
    ///   retry sees it; `FullTextError.invalidResponse` when the answer is not
    ///   HTTP; `CancellationError` from the wait; and the transport's error.
    private func elsevierAttempt(_ request: URLRequest) async throws -> (response: HTTPURLResponse, body: Data) {
        try await waitForSlot(.elsevier)
        let (data, response) = try await session.data(for: request, delegate: RedirectRefusingTaskDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw FullTextError.invalidResponse("Not an HTTP response")
        }
        if BioMedLitConstants.retryableStatusCodes.contains(http.statusCode) {
            throw FullTextError.serverError(statusCode: http.statusCode)
        }
        return (http, data)
    }

    /// A response's header fields as names and values; the classifier matches
    /// a name in any case.
    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String { fields[name] = "\(value)" }
        }
        return fields
    }

    /// Ask Elsevier's API for this article's PDF (#480, stage C2) and record
    /// what it left unsettled: the chain's Elsevier step.
    ///
    /// Served, the PDF's text is extracted as any downloaded PDF's, by the rule
    /// every PDF tier shares (``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:libraryFile:)``).
    /// A 404 or a first page adds nothing. An unreachable Elsevier, its refused
    /// key or its refusal from this network is added to the shortfall. A PDF
    /// that could not be saved adds `request_failed` (the apps' deviation from
    /// the desktop's not-saved note, which carries a link): a copy served later
    /// settles it. Nothing here ever becomes a link fallback.
    ///
    /// Not asked while PDF extraction is off (``extractPDFText``), an accepted
    /// limit: every other PDF tier then hands over its URL alone, and
    /// Elsevier's URL can never be handed over, so there is nothing it could
    /// give. Nothing is recorded then, as without a key.
    ///
    /// - Parameters:
    ///   - doi: The DOI, trimmed; blank asks nothing.
    ///   - cacheKey: Names the article, and so the cached file.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    ///   - holdingAbstract: Whether a body-less rendering is held: a PDF without
    ///     text does not displace it.
    ///   - articleName: How to name this article in the log.
    ///   - shortfall: What went unsettled so far; added to.
    ///   - copyServed: Set when the PDF is cached without text while an
    ///     abstract is held: obtained, so the question is settled.
    ///   - lookup: The fetch's part of the library, which the PDF read is
    ///     kept in.
    /// - Returns: The result to return, or `nil` to go on to Unpaywall.
    /// - Throws: `CancellationError`.
    func elsevierResult(
        doi: String,
        cacheKey: ArticleCacheKey,
        title: String?,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        shortfall: inout OpenAccessShortfall?,
        copyServed: inout Bool,
        lookup: LibraryLookup
    ) async throws -> FullTextResult? {
        guard !doi.isEmpty, Elsevier.isEligible(doi: doi) else { return nil }
        // its PDF is only read with extraction on, so only then is a lost key a loss
        guard !(elsevierCredentialsUnreadable && extractPDFText) else {
            shortfall = .adding(OpenAccessShortfall(source: .elsevier, failure: .requestFailed), to: shortfall)
            BioMedLitLib.logger?.warning(
                "\(BioMedLitConstants.elsevierServiceName)'s key or token could not be read, so it was "
                    + "not asked about DOI \(doi) and any PDF it holds is not assessed",
                category: .fullText
            )
            return nil
        }
        guard elsevierAPIKey != nil else {
            BioMedLitLib.logger?.debug(
                "No Elsevier API key configured; Elsevier's API not asked about DOI \(doi)",
                category: .fullText
            )
            return nil
        }
        // Its PDF can only be downloaded, never offered as a link, so with
        // extraction off there is nothing it could give
        guard extractPDFText else {
            BioMedLitLib.logger?.debug(
                "PDF extraction is off; Elsevier's API not asked about DOI \(doi)", category: .fullText
            )
            return nil
        }
        let service = BioMedLitConstants.elsevierServiceName
        var fetched = try await fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        var read = try readElsevierPDF(fetched, doi: doi, title: title)
        if case .vanished? = read?.outcome {
            // Set aside by another fetch between the cache read and this one
            // (#560): asked again, once, so the download is judged on its own
            BioMedLitLib.logger?.info(
                "The cached PDF from \(service) for DOI \(doi) went away before it was read "
                    + "(another fetch set it aside?); asking again",
                category: .fullText
            )
            fetched = try await fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
            read = try readElsevierPDF(fetched, doi: doi, title: title)
        }
        if let read = read.map({ keptInLibrary($0, origin: .elsevier, lookup: lookup) }) {
            let localPath: String
            switch read {
            case .wrongArticle:
                // Another article's, set aside: recorded under the article
                // URL it was asked by (no key in it), as Python's is, and
                // Unpaywall is tried
                let address = Elsevier.articleURL(doi: doi)?.absoluteString ?? BioMedLitConstants.elsevierBaseURL
                shortfall = .adding(.wrongArticle(source: .elsevier, address: address), to: shortfall)
                return nil
            case .notCached, .vanished:
                // Served, and not kept where it can be read: as a PDF not
                // saved, never a link, and so with no address. A failed move
                // was logged where it failed
                if case .vanished = read {
                    BioMedLitLib.logger?.error(
                        "The PDF from \(service) for DOI \(doi) went away from the cache before it "
                            + "was read, twice",
                        category: .fullText
                    )
                }
                shortfall = .adding(
                    OpenAccessShortfall(source: .elsevier, failure: .requestFailed), to: shortfall
                )
                return nil
            case .noText(let path, _):
                copyServed = true
                localPath = path
            case .extracted(let path, _, _):
                localPath = path
            case .notAttempted, .downloadFailed:
                // Outcomes of a download tier, never of a PDF in hand
                assertionFailure("Elsevier's PDF read came to \(read)")
                return nil
            }
            // Never a download failure or a cache failure here, so no link
            var noLink: FullTextResult?
            let result = pdfTierResult(
                outcome: read,
                content: .elsevier(localPath: localPath),
                degradation: degradation,
                holdingAbstract: holdingAbstract,
                articleName: articleName,
                linkFallback: &noLink
            )
            assert(noLink == nil, "Elsevier's article URL is never a link")
            return result
        }
        switch fetched {
        case .cached, .downloaded:
            // Read above
            break
        case .absent:
            BioMedLitLib.logger?.info(
                "\(service) has no PDF of DOI \(doi) for this requestor; trying Unpaywall",
                category: .fullText
            )
        case .unreachable(let failure):
            shortfall = .adding(OpenAccessShortfall(source: .elsevier, failure: failure), to: shortfall)
            BioMedLitLib.logger?.warning(
                "\(service) could not be asked about DOI \(doi) (\(failure.describe())), so any "
                    + "PDF it holds is not assessed",
                category: .fullText
            )
        case .keyRefused:
            // A skip, not a failure: told as the key. Logged once, by the
            // session, when new.
            shortfall = .adding(.elsevierKeyRefused, to: shortfall)
            BioMedLitLib.logger?.debug(
                "\(service)'s key is refused; not asked about DOI \(doi)", category: .fullText
            )
        case .networkRefused:
            shortfall = .adding(.elsevierNetworkRefused, to: shortfall)
            BioMedLitLib.logger?.debug(
                "\(service) refuses these credentials from this network; not asked about DOI \(doi)",
                category: .fullText
            )
        case .notSaved:
            // Logged at ERROR, with its cause, by the fetch
            shortfall = .adding(
                OpenAccessShortfall(source: .elsevier, failure: .requestFailed), to: shortfall
            )
        }
        return nil
    }

    /// Read the PDF an Elsevier fetch served: the cached one through its title
    /// check, or the download once its check admitted it (#560).
    ///
    /// - Parameters:
    ///   - fetched: What ``fetchElsevierPDF(doi:cacheKey:)`` came to.
    ///   - doi: The DOI, for the log.
    ///   - title: The article's title, or `nil` to check nothing.
    /// - Returns: What came of the PDF (`.noText` and `.extracted` carry where
    ///   it is read from; a refusal carries no path) and whether this call
    ///   admitted it to the cache, or `nil` when the fetch served no PDF.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func readElsevierPDF(
        _ fetched: ElsevierFetch,
        doi: String,
        title: String?
    ) throws -> (outcome: PDFTierOutcome, admitted: Bool)? {
        let service = BioMedLitConstants.elsevierServiceName
        switch fetched {
        case .cached(let localPath):
            BioMedLitLib.logger?.info(
                "Retrieved the PDF from \(service) for DOI \(doi) at \(localPath)", category: .fullText
            )
            return (try extractText(fromCachedPDF: localPath, title: title), false)
        case .downloaded(let staged, let cachePath):
            switch try admit(staged: staged, cachePath: cachePath, title: title) {
            case .admitted(let localPath):
                BioMedLitLib.logger?.info(
                    "Retrieved the PDF from \(service) for DOI \(doi) at \(localPath)", category: .fullText
                )
                // Judged already: read without a second check
                return (try extractText(fromCachedPDF: localPath, title: nil), true)
            case .refused: return (.wrongArticle, false)
            case .notCached: return (.notCached, false)
            case .gone: return (.vanished, false)
            }
        case .absent, .unreachable, .keyRefused, .networkRefused, .notSaved:
            return nil
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
}
