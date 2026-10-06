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
/// Pure functions, a port of Python's `oa_landing_page` module, pinned with
/// the Python and Android ports by
/// `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`: the
/// choice, the tag, the character references in its value, and which error
/// statuses leave a page unread.
enum UnpaywallLandingPage {
    /// What an Unpaywall answer offers the PDF tier: one of the two, or neither.
    enum Choice: Equatable {
        /// The first location's `url_for_pdf`, best location first.
        case pdf(String)
        /// The page to read for a PDF when no location offers a PDF URL.
        /// Never a PDF itself: only a page that may declare one.
        case page(String)
        /// No location offers either.
        case nothing

        /// The PDF URL, when that is the choice.
        var pdfURL: String? {
            if case .pdf(let url) = self { return url }
            return nil
        }

        /// The landing page, when that is the choice.
        var landingPage: String? {
            if case .page(let url) = self { return url }
            return nil
        }
    }

    /// What reading a landing page settled.
    ///
    /// Three outcomes, kept apart as ``FullTextXmlFetch`` keeps Europe PMC's:
    /// a page we could not read is not a page without a PDF.
    enum Read: Equatable {
        /// The PDF to download: the one the page declares, or the page itself
        /// when it was served as a PDF.
        case declared(URL)
        /// The page answered without one: no tag, not HTML, or an error status
        /// that is its answer (``webPageStatusUnsettled(_:)`` is false).
        case declaresNone
        /// The page could not answer: a transport failure, or a status that
        /// leaves it unsettled, after any retries.
        case unreachable(RequestFailure)
    }

    /// Whether a web page's error status left the read unsettled.
    ///
    /// A throttle, a server fault, a 408 or a 425 is "not now". Any other 4xx
    /// (a bot wall, a 404) is the page's answer that it serves us nothing.
    /// Python's `web_page_status_unsettled`.
    ///
    /// - Parameter status: An error status (400 or above).
    /// - Returns: `true` when the status says nothing about the page's content.
    static func webPageStatusUnsettled(_ status: Int) -> Bool {
        status >= BioMedLitConstants.httpServerErrorStatusCodes.lowerBound
            || BioMedLitConstants.retryableStatusCodes.contains(status)
            || BioMedLitConstants.httpUnsettledClientStatusCodes.contains(status)
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
            return .pdf(pdf)
        }
        if let landing = locations.lazy
            .compactMap({ present($0.urlForLandingPage) ?? present($0.url) })
            .first {
            return .page(landing)
        }
        return .nothing
    }

    /// Every PDF URL an Unpaywall answer names, best location first (#480,
    /// stage B): each location's `url_for_pdf`, trimmed, kept once where it
    /// first appears. The chain tries them in this order; Python's
    /// `unpaywall_pdf_urls`, pinned by `unpaywall_landing_page.json`.
    ///
    /// - Parameter response: Unpaywall's answer for one DOI.
    /// - Returns: The PDF URLs, possibly none.
    static func pdfURLs(from response: UnpaywallResponse) -> [String] {
        let locations = [response.bestOaLocation].compactMap { $0 } + (response.oaLocations ?? [])
        var urls: [String] = []
        for location in locations {
            if let pdf = present(location.urlForPdf), !urls.contains(pdf) {
                urls.append(pdf)
            }
        }
        return urls
    }

    /// The URL an Unpaywall address names, when the tier can fetch it.
    ///
    /// An absolute http(s) URL with a host; anything else (a relative path, an
    /// `ftp:` or `file:` URL, text that will not parse) is refused. Python
    /// sends the address to `requests`, which refuses the same kinds of
    /// address with `MissingSchema`, `InvalidSchema` or `InvalidURL`, and
    /// records the lookup as a failed request rather than an absence (#474).
    ///
    /// - Parameter address: A `url_for_pdf` or landing page, as Unpaywall gave it.
    /// - Returns: The URL, or `nil` when it cannot be fetched.
    static func fetchableURL(_ address: String) -> URL? {
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              BioMedLitConstants.unpaywallFetchableSchemes.contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Return the PDF a landing page declares, or `nil` when it declares none.
    ///
    /// The first `<meta name="citation_pdf_url">` whose content resolves,
    /// against the page's own URL, to an http(s) URL. Tag and attribute names
    /// are matched without regard to case; `property=` is not `name=`. An
    /// absolute content is kept as given; a relative one is resolved, with any
    /// `..` that climbs above the root dropped (RFC 3986 section 5.2.4). A
    /// content that will not parse as a URL is passed over for the next tag.
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
                  let resolved = resolve(content, against: pageURL),
                  let scheme = resolved.scheme?.lowercased(),
                  BioMedLitConstants.unpaywallFetchableSchemes.contains(scheme)
            else { continue }
            return resolved
        }
        return nil
    }

    /// Decode a landing page's bytes as the other ports do: by the charset its
    /// Content-Type declares, else as UTF-8. Bytes the encoding cannot read
    /// become U+FFFD.
    ///
    /// - Parameters:
    ///   - data: The page's bytes, as read.
    ///   - textEncodingName: The declared charset (`URLResponse.textEncodingName`),
    ///     or `nil` when none was declared.
    /// - Returns: The page as text.
    static func pageText(_ data: Data, textEncodingName: String?) -> String {
        if let name = textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                )
                if let text = String(data: data, encoding: encoding) {
                    return text
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    /// Resolve a declared URL against the page it was found on.
    ///
    /// - Parameters:
    ///   - content: The declared URL, absolute or relative.
    ///   - pageURL: The page's URL.
    /// - Returns: The absolute URL, or `nil` when the content will not parse.
    private static func resolve(_ content: String, against pageURL: URL) -> URL? {
        // Absolute: kept as given, as Python's `urljoin` and Java's
        // `URI.resolve` keep it, dot segments and all
        if let absolute = URL(string: content), absolute.scheme != nil {
            return absolute
        }
        return URL(string: content, relativeTo: pageURL)?.absoluteURL.standardized
    }

    /// One `<meta ...>` tag. A `>` inside a quoted value ends it early, which
    /// no URL needs: it would be percent-encoded.
    private static let metaTag = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]
    )

    /// One attribute: double-quoted, single-quoted or unquoted value.
    private static let attribute = try! NSRegularExpression(
        pattern: #"([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    )

    /// One character reference, its `;` required: decimal, hexadecimal or
    /// named. Without the `;` it is no reference, so a URL's bare `&section=`
    /// is left alone, as a browser leaves it inside an attribute.
    private static let entity = try! NSRegularExpression(
        pattern: #"&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);"#
    )

    /// The named references a URL plausibly carries, matched with their case
    /// (`&Amp;` is not `&amp;`). Any other name is left as written.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    ]

    /// The largest Unicode code point.
    private static let maxCodePoint: UInt32 = 0x10FFFF

    /// The radix of a hexadecimal character reference.
    private static let hexRadix = 16

    /// The radix of a decimal character reference.
    private static let decimalRadix = 10

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
            found[name] = decodeCharacterReferences(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return found
    }

    /// Decode the character references in an attribute value.
    ///
    /// Numeric references and the five names in ``namedEntities``, each ending
    /// in `;`. An unknown name is left as written; a number that names no
    /// character (zero, a surrogate, beyond Unicode) becomes U+FFFD.
    ///
    /// - Parameter text: The value as written in the page.
    /// - Returns: The value with those references decoded.
    static func decodeCharacterReferences(_ text: String) -> String {
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

    /// The character a reference's body (`amp`, `#38`, `#x26`) names, or
    /// `nil` for a name to leave as written.
    private static func character(for body: String) -> String? {
        guard body.hasPrefix("#") else { return namedEntities[body] }
        let digits = body.dropFirst()
        let isHex = digits.first == "x" || digits.first == "X"
        let value = isHex
            ? UInt32(digits.dropFirst(), radix: hexRadix)
            : UInt32(digits, radix: decimalRadix)
        // `Unicode.Scalar` refuses a surrogate and anything past U+10FFFF;
        // zero it accepts, and a NUL is no character to put in a URL
        guard let value, value != 0, value <= maxCodePoint,
              let scalar = Unicode.Scalar(value) else {
            return BioMedLitConstants.unicodeReplacementCharacter
        }
        return String(Character(scalar))
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
