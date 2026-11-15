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
    func fetchUnpaywallPDFCandidates(doi: String) async throws -> [String] {
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
    static func openAccessShortfall(for error: Error) -> OpenAccessShortfall? {
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
}
