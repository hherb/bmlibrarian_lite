// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// CORE's extracted text, asked by DOI with the user's own key (#480, stage C).
///
/// The pure rules, pinned by `doc/cross_platform/fulltext_parity/core_fulltext.json`;
/// the request is `FullTextService.fetchCoreText(doi:apiKey:)`. Only a result whose
/// own DOI is this article's counts: the request is a search, and another article's
/// text served as this one's would be worse than none.
public enum CORE {
    /// Ways a DOI is written that name the same DOI; one is removed.
    private static let doiPrefixes = [
        "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:",
    ]

    /// Why an answer could not be read.
    enum ParseError: Error {
        case notUTF8
        case notAnObject
        case resultsNotAList
    }

    /// CORE's search for one DOI, as a phrase query: trimmed, `\` and `"` escaped,
    /// percent-encoded as Python's `quote(s, safe="")`.
    public static func searchURL(doi: String, baseURL: String = BioMedLitConstants.coreBaseURL) -> URL? {
        let phrase = doi.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var base = Substring(baseURL)
        while base.hasSuffix("/") { base = base.dropLast() }
        let query = OpenAlex.escaped("doi:\"\(phrase)\"")
        return URL(string: "\(base)\(BioMedLitConstants.coreSearchPath)?q=\(query)&limit=\(BioMedLitConstants.coreSearchLimit)")
    }

    /// A DOI as compared: trimmed, lower-cased, one resolver or `doi:` prefix removed.
    public static func normalisedDOI(_ doi: String) -> String {
        var text = doi.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let prefix = doiPrefixes.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full text CORE's answer serves for this DOI, or nil; throws for an answer we cannot read.
    static func fullText(
        fromAnswer data: Data, doi: String,
        minCharacters: Int = BioMedLitConstants.coreMinFullTextCharacters
    ) throws -> String? {
        guard let body = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
        return try fullText(fromAnswerObject: object, doi: doi, minCharacters: minCharacters)
    }

    /// The selection rule on a parsed answer: the first result that is an object, whose
    /// string `doi` normalises to this DOI's and whose string `fullText`, trimmed, holds at
    /// least `minCharacters` Unicode code points (not graphemes).
    static func fullText(fromAnswerObject object: Any, doi: String, minCharacters: Int) throws -> String? {
        guard let answer = object as? [String: Any] else { throw ParseError.notAnObject }
        guard let results = answer["results"] as? [Any] else { throw ParseError.resultsNotAList }
        let wanted = normalisedDOI(doi)
        guard !wanted.isEmpty else { return nil }
        for case let result as [String: Any] in results {
            guard let resultDOI = result["doi"] as? String, normalisedDOI(resultDOI) == wanted,
                  let text = result["fullText"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.unicodeScalars.count >= minCharacters { return trimmed }
        }
        return nil
    }
}

/// What asking CORE for one DOI learned.
enum COREFetch: Equatable {
    case served(String)
    case absent
    case unreachable(RequestFailure)
}

/// CORE's session pause: two consecutive fetches ending in 429 stop CORE being asked
/// again until the process ends. Shared by every `FullTextService`, since the app builds
/// one per screen; CORE's key buys a daily budget no pacing can express.
public final class CoreThrottle: @unchecked Sendable {
    /// The pause every service in this process shares.
    public static let shared = CoreThrottle()

    private let lock = NSLock()
    private let pauseAfter: Int
    private var consecutive = 0
    private var paused = false

    public init(pauseAfter: Int = BioMedLitConstants.corePauseAfterConsecutive429) {
        self.pauseAfter = pauseAfter
    }

    /// Whether CORE is paused for the rest of the session.
    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Note how one fetch ended: its HTTP status, or nil when it got none.
    func record(endedOn status: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard status == BioMedLitConstants.httpStatusRateLimited else {
            consecutive = 0
            return
        }
        consecutive += 1
        if consecutive >= pauseAfter { paused = true }
    }
}
