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

/// PMC's open-data bucket as a JATS full-text source (#480).
///
/// Pure helpers, pinned with Python and Kotlin by
/// `doc/cross_platform/fulltext_parity/pmc_open_data.json`.
public enum PMCOpenData {
    /// Why an answer from the bucket could not be read.
    ///
    /// Every case is an answer we could not read, never the bucket saying it
    /// holds nothing: the fetch records each as
    /// ``RequestFailure/malformedResponse``, as Python's `ValueError` is.
    public enum UnreadableAnswer: Error, Equatable {
        /// The body is not valid UTF-8. The bucket serves UTF-8, and Python
        /// decodes every body strictly as UTF-8.
        case notUTF8
        /// The listing is not an S3 `ListBucketResult`.
        case notAListing
        /// The listing names keys under the article's prefix, but none whose
        /// version is ASCII digits.
        case noReadableVersion
        /// The metadata record is not a JSON object.
        case notARecord
        /// The record's `xml_url` is present but not this bucket's `s3://`
        /// URL of an object.
        case unreadableXMLURL
    }

    /// `body` as UTF-8 text, or `nil` when it is not valid UTF-8.
    ///
    /// Strict, as Python's `bytes.decode("utf-8")` is: a lossy decode would
    /// read an unreadable body as text with replacement characters in it.
    /// The lossy decode is re-encoded and compared, because every invalid
    /// byte becomes U+FFFD and so changes the bytes.
    ///
    /// - Parameter body: A body the bucket served.
    /// - Returns: The text, or `nil` for invalid UTF-8.
    public static func strictUTF8(_ body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        return Data(text.utf8) == body ? text : nil
    }

    /// The metadata key of the newest version of `pmcid` an S3 listing names.
    ///
    /// A key is a version of `pmcid` when it is `metadata/{pmcid}.{N}.json`
    /// with `N` ASCII digits only. Versions compare as numbers (`.10` beats
    /// `.2`) of any length, so a version longer than an `Int` can hold still
    /// compares correctly; equal numbers (`.2` and `.0002`) go to the key
    /// that sorts last, as Python's `max` over `(version, key)` does. A key
    /// for a longer PMC ID (`metadata/PMC1234.1.json` for `PMC123`) is not
    /// under the article's prefix and is not this article's.
    ///
    /// Namespace-strict, as Python's is: the root must be `ListBucketResult`
    /// in the S3 namespace (with or without a prefix), and only `Key`
    /// elements in that namespace are read.
    ///
    /// - Parameters:
    ///   - listing: A `ListObjectsV2` answer for the prefix
    ///     `metadata/{pmcid}.`.
    ///   - pmcid: The PMC ID, in `PMC<digits>` form.
    /// - Returns: The key, or `nil` when the listing names nothing under the
    ///   article's prefix: the article is in neither collection.
    /// - Throws: ``UnreadableAnswer`` when the body is not UTF-8, is not an
    ///   S3 `ListBucketResult`, or names keys under the article's prefix none
    ///   of which is a readable version: an unreadable answer, never an
    ///   absence.
    public static func latestMetadataKey(listing: Data, pmcid: String) throws -> String? {
        guard strictUTF8(listing) != nil else { throw UnreadableAnswer.notUTF8 }
        let reader = ListingReader()
        let parser = XMLParser(data: listing)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse(),
              reader.rootElement == listingElement,
              reader.rootNamespace == BioMedLitConstants.s3ListingNamespace else {
            throw UnreadableAnswer.notAListing
        }
        // Matched by UTF-8 bytes, as Python's regex matches code points: a
        // `String` comparison would fold a combining mark after the `.` into
        // the `.`'s `Character` and hide the key from the prefix.
        let prefix = Array("\(metadataDirectory)/\(pmcid).".utf8)
        let suffix = Array(metadataSuffix.utf8)
        var namedUnderPrefix = false
        var best: (version: ArraySlice<UInt8>, key: String)?
        for key in reader.keys where key.utf8.starts(with: prefix) {
            namedUnderPrefix = true
            let rest = Array(key.utf8.dropFirst(prefix.count))
            guard rest.count > suffix.count, rest.suffix(suffix.count).elementsEqual(suffix)
            else { continue }
            let digits = rest.dropLast(suffix.count)
            guard digits.allSatisfy(isASCIIDigit) else { continue }
            let version = significantDigits(digits)
            if let current = best, !isNewer(version, key, than: current.version, current.key) {
                continue
            }
            best = (version, key)
        }
        if best == nil && namedUnderPrefix { throw UnreadableAnswer.noReadableVersion }
        return best?.key
    }

    /// The public HTTPS address of an object in the bucket, or `nil` for
    /// anything else. The `?md5=` query is dropped.
    public static func httpsURL(_ s3URL: String) -> URL? {
        let prefix = "s3://\(BioMedLitConstants.pmcOpenDataBucket)/"
        guard s3URL.hasPrefix(prefix) else { return nil }
        let key = s3URL.dropFirst(prefix.count).split(separator: "?", maxSplits: 1,
                                                      omittingEmptySubsequences: false).first ?? ""
        guard !key.isEmpty else { return nil }
        return URL(string: "\(BioMedLitConstants.pmcOpenDataBaseURL)/\(key)")
    }

    /// The directory the bucket files metadata records in.
    private static let metadataDirectory = "metadata"
    /// What every metadata record's key ends with.
    private static let metadataSuffix = ".json"

    /// Whether a UTF-8 code unit is an ASCII digit, `0` to `9`.
    ///
    /// Read by code unit rather than by `Character`: `isNumber` admits
    /// `١`, and a digit with a combining mark is one `Character`.
    private static func isASCIIDigit(_ unit: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(unit)
    }

    /// A version's ASCII digits without their leading zeros (`0` stays `0`).
    ///
    /// Two such runs compare as numbers by length first, then digit by
    /// digit, with no integer that could overflow.
    ///
    /// - Parameter digits: A non-empty run of ASCII digits.
    /// - Returns: The run from its first significant digit.
    private static func significantDigits(_ digits: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let trimmed = digits.drop { $0 == UInt8(ascii: "0") }
        return trimmed.isEmpty ? digits.suffix(1) : trimmed
    }

    /// Whether `version` (of `key`) beats `other` (of `otherKey`).
    ///
    /// Numeric order on significant digits; an equal number goes to the key
    /// that sorts last, as Python's `max` over `(version, key)` breaks it.
    private static func isNewer(_ version: ArraySlice<UInt8>, _ key: String,
                                than other: ArraySlice<UInt8>, _ otherKey: String) -> Bool {
        if version.count != other.count { return version.count > other.count }
        if !version.elementsEqual(other) { return other.lexicographicallyPrecedes(version) }
        // By code point, as Python compares strings.
        return otherKey.unicodeScalars.lexicographicallyPrecedes(key.unicodeScalars)
    }

    /// The listing's root element, by local name.
    private static let listingElement = "ListBucketResult"
    /// An object key inside the listing, by local name.
    private static let keyElement = "Key"

    /// Collects the root's local name and namespace and every S3 `Key`.
    ///
    /// Requires `shouldProcessNamespaces`, so element names arrive as local
    /// names with their namespace URI beside them.
    private final class ListingReader: NSObject, XMLParserDelegate {
        var rootElement: String?
        var rootNamespace: String?
        var keys: [String] = []
        private var inKey = false
        private var text = ""

        private func isS3Key(_ name: String, _ namespaceURI: String?) -> Bool {
            name == PMCOpenData.keyElement && namespaceURI == BioMedLitConstants.s3ListingNamespace
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if rootElement == nil {
                rootElement = name
                rootNamespace = namespaceURI
            }
            if isS3Key(name, namespaceURI) { inKey = true; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inKey { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if isS3Key(name, namespaceURI) {
                keys.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                inKey = false
            }
        }
    }
}

/// What one bucket metadata record says; a flag of the wrong type says nothing.
public struct PMCOpenDataRecord: Equatable, Sendable {
    /// The JATS XML's HTTPS address, or `nil` when the record names none.
    public let xmlURL: URL?
    /// Whether PMC lists the article as open access; `nil` when not said.
    public let isOpenAccess: Bool?
    /// Whether it is an author manuscript; `nil` when not said.
    public let isManuscript: Bool?
    /// The licence, for example `"CC BY"` or `"TDM"`.
    public let licenseCode: String?

    /// Read a metadata record the bucket served.
    ///
    /// - Parameter metadata: The record's body, untrusted.
    /// - Throws: ``PMCOpenData/UnreadableAnswer/notUTF8`` for a body that is
    ///   not UTF-8, ``PMCOpenData/UnreadableAnswer/notARecord`` when it is
    ///   not a JSON object, and
    ///   ``PMCOpenData/UnreadableAnswer/unreadableXMLURL`` when `xml_url`
    ///   names something we cannot read.
    public init(metadata: Data) throws {
        guard PMCOpenData.strictUTF8(metadata) != nil else {
            throw PMCOpenData.UnreadableAnswer.notUTF8
        }
        guard let object = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any]
        else { throw PMCOpenData.UnreadableAnswer.notARecord }
        xmlURL = try Self.xmlURL(object["xml_url"])
        isOpenAccess = Self.bool(object["is_pmc_openaccess"])
        isManuscript = Self.bool(object["is_manuscript"])
        licenseCode = object["license_code"] as? String
    }

    /// The HTTPS address a record's `xml_url` names.
    ///
    /// Missing or JSON `null` names no XML: the record's own answer that the
    /// version has none. Anything else must be this bucket's `s3://` URL of
    /// an object; a value of another type, another bucket's URL, an `https`
    /// URL or a blank is an answer we cannot read, never an absence, because
    /// reading it as one would tell the reader the bucket holds no text.
    ///
    /// - Parameter value: The decoded `xml_url`, untrusted.
    /// - Returns: The address, or `nil` when the record names no XML.
    /// - Throws: ``PMCOpenData/UnreadableAnswer/unreadableXMLURL``.
    private static func xmlURL(_ value: Any?) throws -> URL? {
        guard let value, !(value is NSNull) else { return nil }
        guard let s3URL = value as? String, let url = PMCOpenData.httpsURL(s3URL) else {
            throw PMCOpenData.UnreadableAnswer.unreadableXMLURL
        }
        return url
    }

    /// A JSON boolean only: `JSONSerialization` bridges `1` to `true`, which
    /// the contract's "fields of the wrong type" row refuses.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// What asking PMC's open-data bucket for an article's JATS produced (#480).
///
/// The sibling of ``FullTextXmlFetch``, and Python's `PmcOpenDataFetch`.
/// ``absent`` is the bucket's own answer that it holds no XML for the article
/// (a listing naming nothing under its prefix, or a record naming no XML);
/// ``unreachable(_:)`` is an answer we could not get or could not read, of its
/// real kind. A listing 404 is unreachable: S3 answers a 200 listing naming no
/// version for an article it does not hold, so a 404 is `NoSuchBucket` or
/// something between us and it.
enum PMCOpenDataFetch: Sendable, Equatable {
    /// The bucket served the article's JATS. Never blank.
    case served(ServedXML)

    /// The bucket holds no XML for this article.
    case absent

    /// The bucket's answer is missing, for the reason given.
    case unreachable(RequestFailure)
}
