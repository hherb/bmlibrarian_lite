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
import BmlibCore

/// Crossref's retraction relations for a list of DOIs, over `URLSession`.
///
/// bmlib builds the batched requests and reads each answer; this actor only
/// sends them, one at a time and paced, and keeps a failed batch from reading
/// as anything but unanswered (unreachable is not absent).
public actor RetractionCrossrefLookup {
    /// Crossref's answer about one DOI.
    public struct CrossrefAnswer: Sendable {
        /// bmlib's reading of the answer.
        public let result: CrossrefResult

        /// Set exactly when ``result`` is `.unreachable`: what to tell the reader.
        public let failure: RequestFailure?
    }

    private let email: String
    private let session: URLSession
    private var lastRequestTime = Date.distantPast

    /// - Parameters:
    ///   - email: Contact address for Crossref's polite pool.
    ///   - session: The session requests go over.
    public init(email: String, session: URLSession = .shared) {
        self.email = email
        self.session = session
    }

    /// Ask Crossref about `dois`.
    ///
    /// - Parameter dois: DOIs in any form bmlib normalises.
    /// - Returns: An answer per normalised DOI; a DOI bmlib cannot send is absent.
    /// - Throws: `CancellationError` only.
    public func results(for dois: [String]) async throws -> [String: CrossrefAnswer] {
        guard !dois.isEmpty else { return [:] }
        let requests = crossrefRetractionRequests(dois: dois, mailto: email)
        var answers: [String: CrossrefAnswer] = [:]
        for batch in requests.batches {
            try Task.checkCancellation()
            answers.merge(try await answer(batch)) { _, new in new }
        }
        return answers
    }

    /// Send one batch and read what came back.
    private func answer(_ batch: CrossrefBatch) async throws -> [String: CrossrefAnswer] {
        guard let url = URL(string: batch.url) else {
            return unreachable(batch, .requestFailed)
        }
        var request = URLRequest(url: url)
        request.setValue(
            "\(BioMedLitConstants.retractionUserAgentProduct) (mailto:\(email))",
            forHTTPHeaderField: "User-Agent"
        )
        await enforceRateLimit()

        let status: Int
        let body: Data
        do {
            (status, body) = try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw TransientStatus(code: nil) }
                if BioMedLitConstants.retryableStatusCodes.contains(http.statusCode) {
                    throw TransientStatus(code: http.statusCode)
                }
                return (http.statusCode, data)
            }
        } catch let transient as TransientStatus {
            // Retries spent: the batch is unanswered, whatever the status said.
            return unreachable(batch, transient.code.map(RequestFailure.httpStatus) ?? .requestFailed)
        } catch {
            if error.isCancellation { throw CancellationError() }
            return unreachable(batch, SearchTransport.failure(for: error))
        }

        let parsed = parseCrossrefRetractionResponse(status: UInt16(clamping: status), body: body, requestedDois: batch.dois)
        let statusFailure: RequestFailure? = status == BioMedLitConstants.httpStatusOK ? nil : .httpStatus(status)
        return Dictionary(uniqueKeysWithValues: parsed.map { doi, result in
            guard case .unreachable(let reason) = result else {
                return (doi, CrossrefAnswer(result: result, failure: nil))
            }
            // bmlib's reason is for the log only (golden rule 13).
            BioMedLitLib.logger?.debug("Crossref answer unreadable: \(reason)", category: .network)
            let failure = statusFailure ?? .malformedResponse
            return (doi, CrossrefAnswer(result: .unreachable(reason: failure.describe()), failure: failure))
        })
    }

    private func unreachable(_ batch: CrossrefBatch, _ failure: RequestFailure) -> [String: CrossrefAnswer] {
        let answer = CrossrefAnswer(result: .unreachable(reason: failure.describe()), failure: failure)
        return Dictionary(uniqueKeysWithValues: batch.dois.map { ($0, answer) })
    }

    /// Keep Crossref's polite-pool pacing between batches.
    private func enforceRateLimit() async {
        let wait = TransparencyConstants.minimumRequestInterval - Date().timeIntervalSince(lastRequestTime)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequestTime = Date()
    }

    /// A status worth another attempt; kept only to be retried, never shown.
    private struct TransientStatus: RetryableError {
        let code: Int?
        var isRetryable: Bool { true }
    }
}
