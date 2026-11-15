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
    ///   naming only unreadable versions, an `xml_url` that is not this
    ///   bucket's file of the listed version, or XML whose bytes do not match
    ///   the record's md5 (each ``RequestFailure/malformedResponse``), a blank XML
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
                record = try PMCOpenDataRecord(
                    metadata: recordBody, stem: PMCOpenData.stem(ofMetadataKey: key))
            } catch {
                return .unreachable(.malformedResponse)
            }
            guard let xmlURL = record.xmlURL else { return .absent }

            let (xmlStatus, xmlBody) = try await bucketGET(xmlURL)
            guard xmlStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.httpStatus(xmlStatus))
            }
            // Damaged or stale bytes are not the article: a fault, never served (#780).
            if let md5 = record.xmlMD5, PMCOpenData.md5Hex(xmlBody) != md5 {
                BioMedLitLib.logger?.warning(
                    "PMC's open-access collection's JATS for \(accession) does not match its "
                        + "record's md5",
                    category: .fullText
                )
                return .unreachable(.malformedResponse)
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

    // MARK: - Paced requests (every paced host's tier)

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
    func pacedAttempt(
        _ url: URL, host: PacedHost, headers: [String: String] = [:]
    ) async throws -> (status: Int, body: Data) {
        try await waitForSlot(host)
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

    /// Wait for this request's pacing slot on a paced host, reserving it
    /// first so two fetches interleaving on this actor cannot both take it.
    ///
    /// - Parameter host: Whose pacing slot the request takes.
    /// - Throws: `CancellationError` from the wait.
    func waitForSlot(_ host: PacedHost) async throws {
        let now = Date()
        let slot = max(now, nextRequest[host] ?? now)
        nextRequest[host] = slot.addingTimeInterval(host.minimumInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * Double(BioMedLitConstants.nanosecondsPerSecond)))
        }
    }
}
