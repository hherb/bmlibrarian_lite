// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// OpenAlex's locations as open-access PDF sources (#480, stage B).
///
/// Pinned with Python's `openalex.py` by
/// `doc/cross_platform/fulltext_parity/openalex_locations.json`. Every
/// `locations[].pdf_url` is a candidate, whatever the location's `is_oa`: the
/// #480 spike recovered a copy OpenAlex marks closed.
public enum OpenAlex {
    /// RFC 3986's unreserved characters: all Python's `quote(s, safe="")`
    /// leaves bare. Everything else, `/` included, is escaped as UTF-8 bytes.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Why an answer could not be read.
    enum ParseError: Error {
        case notAWork
        case locationsNotAList
    }

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The address OpenAlex is asked about one DOI at: the DOI one path
    /// segment, only `locations` selected, the contact email a query value.
    ///
    /// - Parameters:
    ///   - doi: The DOI; surrounding whitespace is not part of it.
    ///   - mailto: The contact email, or `nil` (or empty) to ask without one.
    ///   - baseURL: OpenAlex's address.
    /// - Returns: The URL, or `nil` if it cannot be formed.
    public static func workURL(
        doi: String, mailto: String?, baseURL: String = BioMedLitConstants.openAlexBaseURL
    ) -> URL? {
        let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "\(baseURL)/works/doi:\(escaped(trimmed))?select=locations"
        if let mailto, !mailto.isEmpty {
            text += "&mailto=\(escaped(mailto))"
        }
        return URL(string: text)
    }

    /// Every PDF URL a work's locations name, from OpenAlex's JSON body.
    ///
    /// - Throws: `ParseError` or the decoder's error for a body we cannot read.
    static func pdfURLs(fromWork data: Data) throws -> [String] {
        try pdfURLs(fromWorkObject: try JSONSerialization.jsonObject(with: data))
    }

    /// Every PDF URL a decoded work's locations name: each `pdf_url` that is
    /// a non-blank string, trimmed, kept once, in OpenAlex's order; a location
    /// that is not an object is skipped; `locations` missing or null is none.
    ///
    /// - Throws: `ParseError.notAWork` unless an object;
    ///   `ParseError.locationsNotAList` for `locations` neither a list nor null.
    static func pdfURLs(fromWorkObject object: Any) throws -> [String] {
        guard let work = object as? [String: Any] else { throw ParseError.notAWork }
        let raw = work["locations"]
        if raw == nil || raw is NSNull { return [] }
        guard let locations = raw as? [Any] else { throw ParseError.locationsNotAList }
        var urls: [String] = []
        for case let location as [String: Any] in locations {
            guard let pdf = (location["pdf_url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !pdf.isEmpty else { continue }
            if !urls.contains(pdf) { urls.append(pdf) }
        }
        return urls
    }

    /// The URLs not already tried, in their order.
    static func untried(_ urls: [String], tried: Set<String>) -> [String] {
        urls.filter { !tried.contains($0) }
    }
}

/// What asking OpenAlex for a work's PDF locations produced; the sibling of
/// ``PMCOpenDataFetch``. `absent` is OpenAlex knowing no work by the DOI;
/// `served([])` a work naming no PDF. Both are answers.
enum OpenAlexFetch: Equatable {
    case served([String])
    case absent
    case unreachable(RequestFailure)
}
