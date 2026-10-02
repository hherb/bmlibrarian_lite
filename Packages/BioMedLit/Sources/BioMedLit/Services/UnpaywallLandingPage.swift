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

/// Which URL an Unpaywall answer offers, and the PDF a landing page declares.
///
/// Unpaywall sets a location's `url` to `url_for_pdf` when it has one and to
/// the landing page when it does not, so `urlForPdf ?? url` adds no PDF, only
/// the landing page. The service took it, and PMID 40608933's repository
/// landing page was downloaded as "the PDF", failed the `%PDF` check, and was
/// stored as an Unpaywall full text with no text in it (#464). A landing page
/// usually declares its PDF in a Highwire Press tag,
/// `<meta name="citation_pdf_url" content="...">`, which
/// ``citationPDFURL(html:pageURL:)`` reads.
///
/// Pure functions, pinned with the Python and Android ports by
/// `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`.
enum UnpaywallLandingPage {
    /// What an Unpaywall answer offers the PDF tier. At most one is set.
    struct Choice: Equatable {
        /// The first location's `url_for_pdf`, best location first.
        let pdfURL: String?
        /// The page to read for a PDF when no location offers a PDF URL.
        let landingPage: String?
    }

    /// Decide which URL an Unpaywall answer offers.
    ///
    /// The first `url_for_pdf`, best location first. Failing that, the first
    /// landing page (`url_for_landing_page`, else `url`): never a PDF URL
    /// itself, only a page that may declare one.
    ///
    /// - Parameter response: Unpaywall's answer for one DOI.
    /// - Returns: The PDF URL, the landing page, or neither.
    static func choose(from response: UnpaywallResponse) -> Choice {
        let locations = [response.bestOaLocation].compactMap { $0 } + (response.oaLocations ?? [])
        if let pdf = locations.lazy.compactMap({ present($0.urlForPdf) }).first {
            return Choice(pdfURL: pdf, landingPage: nil)
        }
        let landing = locations.lazy
            .compactMap { present($0.urlForLandingPage) ?? present($0.url) }
            .first
        return Choice(pdfURL: nil, landingPage: landing)
    }

    /// Return the PDF a landing page declares, or `nil` when it declares none.
    ///
    /// The first `<meta name="citation_pdf_url">` whose content resolves,
    /// against the page's own URL, to an http(s) URL. Tag and attribute names
    /// are matched without regard to case; `property=` is not `name=`.
    ///
    /// - Parameters:
    ///   - html: The landing page as served.
    ///   - pageURL: Where it was served from, after redirects: the base a
    ///     relative URL resolves against.
    /// - Returns: The absolute PDF URL, or `nil`.
    static func citationPDFURL(html: String, pageURL: URL) -> URL? {
        let range = NSRange(html.startIndex..., in: html)
        for tagMatch in metaTag.matches(in: html, range: range) {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let attributes = attributes(of: String(html[tagRange]))
            guard attributes["name"]?.lowercased() == BioMedLitConstants.citationPDFURLMetaName,
                  let content = attributes["content"], !content.isEmpty,
                  let resolved = URL(string: content, relativeTo: pageURL)?.absoluteURL.standardized,
                  let scheme = resolved.scheme?.lowercased(),
                  BioMedLitConstants.landingPagePDFSchemes.contains(scheme)
            else { continue }
            return resolved
        }
        return nil
    }

    // MARK: - Parsing

    /// One `<meta ...>` tag. A `>` inside a quoted value ends it early, which
    /// no URL needs: it would be percent-encoded.
    private static let metaTag = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]
    )

    /// One attribute: double-quoted, single-quoted or unquoted value.
    private static let attribute = try! NSRegularExpression(
        pattern: #"([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    )

    /// A character reference: decimal, hexadecimal or named.
    private static let entity = try! NSRegularExpression(
        pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#
    )

    /// The named references a URL in an attribute plausibly carries.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    ]

    /// A tag's attributes: names lower-cased, values entity-decoded and
    /// trimmed, the first of a repeated name kept.
    private static func attributes(of tag: String) -> [String: String] {
        var found: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in attribute.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nameRange].lowercased()
            guard found[name] == nil else { continue }
            let value = (2...4).lazy
                .compactMap { Range(match.range(at: $0), in: tag) }
                .map { String(tag[$0]) }
                .first ?? ""
            found[name] = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return found
    }

    /// Replace character references with the characters they name.
    ///
    /// An unknown named reference, or a number that names no character, is
    /// left as written.
    private static func decodeEntities(_ text: String) -> String {
        var decoded = ""
        var cursor = text.startIndex
        let range = NSRange(text.startIndex..., in: text)
        for match in entity.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text),
                  let bodyRange = Range(match.range(at: 1), in: text) else { continue }
            decoded += text[cursor..<whole.lowerBound]
            decoded += character(for: String(text[bodyRange])) ?? String(text[whole])
            cursor = whole.upperBound
        }
        decoded += text[cursor...]
        return decoded
    }

    /// The character a reference's body (`amp`, `#38`, `#x26`) names.
    private static func character(for body: String) -> String? {
        guard body.hasPrefix("#") else { return namedEntities[body.lowercased()] }
        let digits = body.dropFirst()
        let value = digits.first.map { $0 == "x" || $0 == "X" } == true
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// A string value trimmed, or `nil` when it names nothing.
    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Unpaywall Response Types

/// Response from Unpaywall API.
struct UnpaywallResponse: Codable {
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
struct OALocation: Codable {
    /// `url_for_pdf` when Unpaywall has one, else the landing page.
    let url: String?

    /// Direct PDF URL (if available).
    let urlForPdf: String?

    /// The landing page, whether or not a PDF URL is known.
    let urlForLandingPage: String?

    /// Host type (publisher, repository, etc.).
    let hostType: String?

    /// License information.
    let license: String?

    enum CodingKeys: String, CodingKey {
        case url
        case urlForPdf = "url_for_pdf"
        case urlForLandingPage = "url_for_landing_page"
        case hostType = "host_type"
        case license
    }
}
