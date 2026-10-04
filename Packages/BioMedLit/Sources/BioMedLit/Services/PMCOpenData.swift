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
    public enum ListingError: Error, Equatable { case notAListing }

    /// The metadata key of the newest version of `pmcid` an S3 listing names.
    ///
    /// Versions compare as numbers (`.10` beats `.2`); a key for a longer
    /// PMC ID is not this article's.
    ///
    /// - Returns: The key, or `nil` when the listing names no version.
    /// - Throws: `ListingError.notAListing` when the body is not an S3
    ///   `ListBucketResult`: an unreadable answer, never an absence.
    public static func latestMetadataKey(listing: Data, pmcid: String) throws -> String? {
        let reader = ListingReader()
        let parser = XMLParser(data: listing)
        parser.delegate = reader
        guard parser.parse(), reader.rootElement == "ListBucketResult" else {
            throw ListingError.notAListing
        }
        let prefix = "metadata/\(pmcid)."
        let suffix = ".json"
        var best: (version: Int, key: String)?
        for key in reader.keys where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            let middle = key.dropFirst(prefix.count).dropLast(suffix.count)
            guard !middle.isEmpty, middle.allSatisfy(\.isASCIIDigitCharacter),
                  let version = Int(middle) else { continue }
            if best == nil || version > best!.version { best = (version, key) }
        }
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

    private final class ListingReader: NSObject, XMLParserDelegate {
        var rootElement: String?
        var keys: [String] = []
        private var inKey = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if rootElement == nil { rootElement = name }
            if name == "Key" { inKey = true; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inKey { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == "Key" {
                keys.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                inKey = false
            }
        }
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// What one bucket metadata record says; a field of the wrong type says nothing.
public struct PMCOpenDataRecord: Equatable, Sendable {
    public let xmlURL: URL?
    public let isOpenAccess: Bool?
    public let isManuscript: Bool?
    public let licenseCode: String?

    /// - Throws: `PMCOpenData.ListingError.notAListing` when `metadata` is
    ///   not a JSON object.
    public init(metadata: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any]
        else { throw PMCOpenData.ListingError.notAListing }
        xmlURL = (object["xml_url"] as? String).flatMap(PMCOpenData.httpsURL)
        isOpenAccess = Self.bool(object["is_pmc_openaccess"])
        isManuscript = Self.bool(object["is_manuscript"])
        licenseCode = object["license_code"] as? String
    }

    /// A JSON boolean only: `JSONSerialization` bridges `1` to `true`, which
    /// the contract's "fields of the wrong type" row refuses.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
