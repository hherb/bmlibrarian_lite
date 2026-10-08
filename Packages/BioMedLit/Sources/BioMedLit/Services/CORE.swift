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

    /// The resolver and `doi:` prefixes a DOI is asked without, in the order removed:
    /// Python's `PDFDiscoverer._clean_doi` list, matched ignoring case (so `doi:` twice).
    private static let resolverPrefixes = [
        "https://doi.org/", "http://doi.org/", "https://www.doi.org/", "http://www.doi.org/",
        "https://dx.doi.org/", "http://dx.doi.org/", "doi:", "DOI:",
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

    /// The DOI CORE is asked by: trimmed, each resolver or `doi:` prefix removed in
    /// turn, ignoring case, the rest as given (Python's `PDFDiscoverer._clean_doi`).
    /// A DOI held as `https://doi.org/10.…` is searched bare, as Python's chain asks it.
    ///
    /// - Parameter doi: The DOI as the document holds it.
    /// - Returns: The bare DOI; blank for a blank one.
    public static func bareDOI(_ doi: String) -> String {
        var text = Substring(doi.trimmingCharacters(in: .whitespacesAndNewlines))
        for prefix in resolverPrefixes where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = text.dropFirst(prefix.count)
        }
        return String(text)
    }

    /// A DOI as compared: trimmed, lower-cased, one resolver or `doi:` prefix removed.
    public static func normalisedDOI(_ doi: String) -> String {
        var text = doi.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let prefix = doiPrefixes.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fingerprint a refused key is remembered by (#498): the SHA-256 digest of the
    /// trimmed key's UTF-8 bytes, as lower-case hex, Python's `core_key_digest`. A refusal
    /// is scoped to the key CORE refused, so a key corrected in the settings is asked
    /// again; the key itself is never held for that, and the digest is never logged.
    /// Forwards to ``KeyDigest/key(_:)``, which Elsevier's session shares.
    public static func keyDigest(_ apiKey: String) -> String {
        KeyDigest.key(apiKey)
    }

    /// A DOI as asked by a path: trimmed, one resolver or `doi:` prefix removed as
    /// ``normalisedDOI(_:)`` matches it (in any case), trimmed again; its own case kept.
    /// Python's `elsevier_api._bare_doi`, which removes the same prefixes.
    ///
    /// - Parameter doi: The DOI as a source wrote it.
    /// - Returns: The DOI without its prefix, its case kept; blank for a blank one.
    static func doiWithoutPrefix(_ doi: String) -> String {
        var text = Substring(doi.trimmingCharacters(in: .whitespacesAndNewlines))
        let lowered = text.lowercased()
        if let prefix = doiPrefixes.first(where: { lowered.hasPrefix($0) }) {
            text = text.dropFirst(prefix.count)
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
    /// CORE refused the key, on this fetch or an earlier one this session (#498): CORE
    /// was not asked about the article, and the reader is told the key, never the article.
    case keyRefused
}

/// CORE's session state, shared by every `FullTextService`, since the app builds one per
/// screen: the rules of ``KeyedServiceSession``, with CORE's own instance. Two consecutive
/// fetches ending in 429 pause CORE until the process ends: its key buys a daily budget no
/// pacing can express. A fetch ending in 401 marks the key it was sent with refused for the
/// rest of the process (#498): every article would be refused alike, so CORE is not asked
/// with that key again. The refusal is the key's, held as its ``CORE/keyDigest(_:)``:
/// another key, such as one corrected in the settings, is asked as usual, and a 401 for it
/// refuses that key instead. CORE has no refusal from a network; that is Elsevier's.
public final class CoreThrottle: KeyedServiceSession, @unchecked Sendable {
    /// CORE's session state every service in this process shares: the 429
    /// pause and the refused key. Shares nothing with ``ElsevierSession/shared``.
    public static let shared = CoreThrottle()

    /// Start unpaused, with no key refused.
    ///
    /// - Parameter pauseAfter: Consecutive 429 endings that pause CORE.
    public init(pauseAfter: Int = BioMedLitConstants.corePauseAfterConsecutive429) {
        super.init(
            serviceName: BioMedLitConstants.coreServiceName,
            keyRefusedStatus: BioMedLitConstants.coreKeyRefusedStatus,
            pauseAfter: pauseAfter
        )
    }
}
