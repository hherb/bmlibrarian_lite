// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Elsevier's Article Retrieval API, asked for an Elsevier article's PDF by DOI with
/// the user's own key and, when set, an institutional token (#480, stage C2).
///
/// The pure rules, pinned with Python's `elsevier_api.py` by
/// `doc/cross_platform/fulltext_parity/elsevier_article.json`: which DOIs are asked,
/// the request's address, how one answer is classified, and what it leaves in the
/// session. The key travels only in `X-ELS-APIKey` and the token only in
/// `X-ELS-Insttoken`: neither is ever part of the URL built here.
public enum Elsevier {
    /// What a path keeps bare: RFC 3986's unreserved characters and `/`, as Python's
    /// `quote(s, safe="/")`. Every other UTF-8 byte is percent-encoded, a `;` included,
    /// which a servlet would read as a path parameter.
    private static let pathSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
    )

    /// Whether a DOI is Elsevier's, and so may be asked about: CORE's normalised
    /// form starts `10.1016/`. Every other DOI makes no request and records nothing.
    ///
    /// - Parameter doi: The DOI as a source wrote it.
    public static func isEligible(doi: String) -> Bool {
        CORE.normalisedDOI(doi).hasPrefix(BioMedLitConstants.elsevierDOIPrefix)
    }

    /// The article request for one DOI. It carries neither the key nor the token.
    ///
    /// - Parameters:
    ///   - doi: The DOI; trimmed, one resolver or `doi:` prefix removed, its own case kept.
    ///   - baseURL: Elsevier's API root; trailing slashes are dropped.
    /// - Returns: The URL, pinned by the contract's `article_url` rows; nil if it cannot
    ///   be formed.
    public static func articleURL(
        doi: String, baseURL: String = BioMedLitConstants.elsevierBaseURL
    ) -> URL? {
        var base = Substring(baseURL)
        while base.hasSuffix("/") { base = base.dropLast() }
        // Foundation writes the escapes in upper-case hex, as Python's `quote` does.
        guard let path = CORE.doiWithoutPrefix(doi).addingPercentEncoding(withAllowedCharacters: pathSafe)
        else { return nil }
        return URL(string: "\(base)\(BioMedLitConstants.elsevierArticlePath)\(path)")
    }

    /// Whether a key and a token can be sent as header values at all: every character
    /// of each, trimmed, is printable ASCII (U+0020 to U+007E), Python's
    /// `credentials_sendable` (the contract's `sendable` rows). A zero-width space or a
    /// curly quote pasted with a key is not; such credentials are never sent.
    ///
    /// - Parameters:
    ///   - key: The key, as the settings hold it.
    ///   - token: The institutional token, or `nil`; a blank one is no token.
    /// - Returns: Whether both can be sent.
    public static func isSendable(key: String, token: String?) -> Bool {
        [key, token ?? ""].allSatisfy { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.allSatisfy {
                BioMedLitConstants.headerValueScalars.contains($0.value)
            }
        }
    }

    /// Classify one answer, after its retries (the contract's `answers` table).
    ///
    /// - Parameters:
    ///   - status: The HTTP status. A 3xx is never followed: it is unreachable.
    ///   - headers: The answer's headers; `X-ELS-Status` is matched by name in any case.
    ///   - body: The body, or at least its start: `%PDF` for a 200, and up to
    ///     ``BioMedLitConstants/elsevierErrorBodyMaxBytes`` for a 403 (more is not read).
    /// - Returns: What the answer means.
    public static func classify(status: Int, headers: [String: String], body: Data) -> ElsevierAnswer {
        switch status {
        case BioMedLitConstants.httpStatusOK:
            // Read before the body: the first page is a valid PDF, and never the
            // article's text.
            if isFirstPageOnly(headers: headers) { return .firstPageOnly }
            return body.starts(with: BioMedLitConstants.pdfMagicBytes)
                ? .served
                : .unreachable(.malformedResponse)
        case BioMedLitConstants.httpStatusNotFound:
            return .absent
        case BioMedLitConstants.elsevierKeyRefusedStatus:
            return .keyRefused
        case BioMedLitConstants.elsevierNetworkRefusedStatus where isNetworkRefusal(body):
            return .networkRefused
        default:
            return .unreachable(.httpStatus(status))
        }
    }

    /// Whether a 200 carries the first page only: an `X-ELS-Status` whose value,
    /// trimmed, starts `WARNING` in any case.
    private static func isFirstPageOnly(headers: [String: String]) -> Bool {
        let name = BioMedLitConstants.elsevierStatusHeader.lowercased()
        let prefix = BioMedLitConstants.elsevierWarningPrefix.lowercased()
        return headers.contains { header, value in
            header.lowercased() == name
                && value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(prefix)
        }
    }

    /// Whether a 403's body, read up to the bound, holds the token's ASCII bytes.
    private static func isNetworkRefusal(_ body: Data) -> Bool {
        let read = body.prefix(BioMedLitConstants.elsevierErrorBodyMaxBytes)
        return read.range(of: Data(BioMedLitConstants.elsevierNetworkRefusedToken.utf8)) != nil
    }

    /// The answer a fetch has without asking, in the contract's order: this key
    /// refused, these credentials refused from this network, the pause, then
    /// credentials that cannot be sent. Such a fetch makes no request and is recorded
    /// nowhere.
    ///
    /// - Parameters:
    ///   - session: Elsevier's session state.
    ///   - keyDigest: The key's ``KeyDigest/key(_:)``.
    ///   - credentialsDigest: The key's and token's ``KeyDigest/credentials(key:token:)``.
    ///   - sendable: The key's and token's ``isSendable(key:token:)``.
    /// - Returns: The answer, or nil when Elsevier is to be asked.
    static func answerWithoutAsking(
        session: KeyedServiceSession, keyDigest: String, credentialsDigest: String, sendable: Bool
    ) -> ElsevierAnswer? {
        if session.refuses(keyDigest: keyDigest) { return .keyRefused }
        if session.refusesNetwork(credentialsDigest: credentialsDigest) { return .networkRefused }
        if session.isPaused { return .unreachable(.httpStatus(BioMedLitConstants.httpStatusRateLimited)) }
        if !sendable { return .unreachable(.requestFailed) }
        return nil
    }

    /// Record how a fetch that made a request ended: an off-network refusal refuses
    /// those credentials; any other answer is noted by its status (a 401 refuses the
    /// key, a 429 counts toward the pause, anything else resets the count).
    ///
    /// - Parameters:
    ///   - answer: The answer classified.
    ///   - status: The HTTP status it ended on, or nil when it got none.
    ///   - session: Elsevier's session state.
    ///   - keyDigest: The key's ``KeyDigest/key(_:)``.
    ///   - credentialsDigest: The key's and token's ``KeyDigest/credentials(key:token:)``.
    static func record(
        _ answer: ElsevierAnswer, endedOn status: Int?, in session: KeyedServiceSession,
        keyDigest: String, credentialsDigest: String
    ) {
        if answer == .networkRefused {
            session.recordNetworkRefused(credentialsDigest: credentialsDigest)
        } else {
            session.record(endedOn: status, keyDigest: keyDigest)
        }
    }
}

/// What one answer of Elsevier's means (the contract's `answers` outcomes).
public enum ElsevierAnswer: Equatable, Sendable {
    /// A 200 whose body is a PDF: the article.
    case served
    /// No such article (404): nothing is recorded, and the chain goes on.
    case absent
    /// A 200 marked `WARNING`: the first page only, never the article's text. An
    /// absence, told apart so it can be logged as such.
    case firstPageOnly
    /// Elsevier could not be asked, or its answer could not be read.
    case unreachable(RequestFailure)
    /// Elsevier refused the key (401), now or earlier this session.
    case keyRefused
    /// Elsevier refused these credentials from this network (a 403 holding
    /// `AUTHENTICATION_ERROR`), now or earlier this session.
    case networkRefused
}

/// What asking Elsevier for one article's PDF learned.
enum ElsevierFetch: Equatable {
    /// The PDF, saved at this local path: never a link, as Elsevier's URL needs the key.
    case served(localPath: String)
    /// No PDF of this article for this requestor: nothing recorded, the chain goes on.
    case absent
    /// Elsevier could not be asked, or its answer could not be read.
    case unreachable(RequestFailure)
    /// Elsevier refused the key, so it was not asked about this article.
    case keyRefused
    /// Elsevier refused these credentials from this network.
    case networkRefused
    /// Elsevier served the PDF and it could not be saved on this device.
    case notSaved
}

/// Elsevier's session state, shared by every `FullTextService` in this process: the
/// rules of ``KeyedServiceSession``, with Elsevier's own instance. It shares nothing with
/// ``CoreThrottle/shared``: a CORE 429 never pauses Elsevier.
public final class ElsevierSession: KeyedServiceSession, @unchecked Sendable {
    /// Elsevier's session state every service in this process shares: the 429 pause,
    /// the refused key and the credentials refused from this network.
    public static let shared = ElsevierSession()

    /// Start unpaused, with nothing refused.
    ///
    /// - Parameter pauseAfter: Consecutive 429 endings that pause Elsevier.
    public init(pauseAfter: Int = BioMedLitConstants.elsevierPauseAfterConsecutive429) {
        super.init(
            serviceName: BioMedLitConstants.elsevierServiceName,
            keyRefusedStatus: BioMedLitConstants.elsevierKeyRefusedStatus,
            pauseAfter: pauseAfter
        )
    }
}
