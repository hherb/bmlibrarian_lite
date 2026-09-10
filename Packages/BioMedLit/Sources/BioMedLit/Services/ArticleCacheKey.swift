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
import CryptoKit

/// The stable name one article's cached PDFs are filed under.
///
/// The PDF cache was keyed on the PMID alone and refused an empty one. The
/// refusal was right — every article with no PMID would otherwise share a
/// single entry and be served the first one's bytes — but it cost those
/// articles their PDF extraction entirely, and the tier reported a download
/// failure indistinguishable from a real one (#202).
///
/// This type replaces the refusal with a ladder. It takes the three
/// identifiers a document carries and picks the first it actually has,
/// recording *which kind* it picked so that two kinds can never name the same
/// entry. An article carrying none of the three still has no stable name, and
/// is still refused — but nothing in the retrieval chain can fetch a PDF for
/// such an article anyway.
///
/// ## Why the kind is part of the name
///
/// `EuropePMCService` fills the primary slot as `result.pmid ?? result.id`, so
/// it holds a PubMed ID, a Europe PMC preprint accession (`PPR1287966`), or a
/// PMC ID, depending on the record. Were the rungs untagged, an article whose
/// primary slot happened to hold `PMC7654321` would name the same entry as a
/// different article reached by that PMC ID, and one would be served the
/// other's bytes.
///
/// Tagging every rung — the primary one included — invalidates the entries
/// written by earlier builds, which are re-downloaded once and then superseded.
/// That is the cheap direction to be wrong in, and the same trade this cache
/// already took when the source URL joined the key: a stale entry costs one
/// download, while serving the wrong article's bytes costs the reader a wrong
/// answer.
///
/// ## Usage
///
/// ```swift
/// guard let key = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: nil) else {
///     return  // no identifier to file bytes under
/// }
/// key.filenameComponent  // "pmc_PMC7654321"
/// ```
public struct ArticleCacheKey: Equatable {
    /// Which identifier named this article, and its value.
    ///
    /// The case is what keeps two kinds apart in the filename; the associated
    /// value is the raw identifier, before sanitising or digesting.
    public enum Identifier: Equatable {
        /// The document's primary identifier slot.
        ///
        /// Deliberately not called `pmid`: the slot holds a PubMed ID for a
        /// MEDLINE record, a `PPR…` accession for a preprint, and a PMC ID for
        /// a PMC-only record. Naming it for one of the three would be a label
        /// that lies about the other two.
        case primary(String)

        /// A PubMed Central ID, used when the primary slot is empty.
        case pmcID(String)

        /// A DOI, used when the document carries neither of the above.
        case doi(String)
    }

    /// The identifier this key is built from.
    public let identifier: Identifier

    /// Build a key from the identifiers a document carries.
    ///
    /// Rungs are tried in order — primary slot, PMC ID, DOI — and the first
    /// one holding more than whitespace wins. Order matters for cache
    /// stability rather than for correctness: any rung names the article
    /// uniquely, but a document must land on the same rung on every run or it
    /// accumulates one entry per rung.
    ///
    /// For that reason callers must pass the identifiers the *document*
    /// carries, never one resolved from a network lookup: a key that depends
    /// on whether a search succeeded is not stable.
    ///
    /// - Parameters:
    ///   - pmid: The document's primary identifier slot. See
    ///     ``Identifier/primary(_:)`` for why it is not only ever a PubMed ID.
    ///   - pmcId: PubMed Central ID, if the document has one.
    ///   - doi: Digital Object Identifier, if the document has one.
    /// - Returns: `nil` when all three are absent or blank, which is the one
    ///   case with no stable name to file bytes under.
    public init?(pmid: String?, pmcId: String?, doi: String?) {
        if let value = Self.usable(pmid) {
            identifier = .primary(value)
        } else if let value = Self.usable(pmcId) {
            identifier = .pmcID(value)
        } else if let value = Self.usable(doi) {
            identifier = .doi(value)
        } else {
            return nil
        }
    }

    /// The article half of a cache filename.
    ///
    /// Each rung carries a prefix naming its kind, so no two kinds can produce
    /// the same string. `_` separates the prefix from the identifier because
    /// `-` is not in ``BioMedLitConstants/cacheKeyAllowedCharacters`` and so
    /// remains free to separate this component from the source-URL fingerprint
    /// that follows it.
    ///
    /// A DOI is digested rather than sanitised. It carries `/` and `.`, neither
    /// of which survives sanitising, so `10.1/abc` and `10.1_abc` would both
    /// become `10_1_abc` and share one entry. A digest cannot collide, and a
    /// DOI never needed to be readable in a filename.
    public var filenameComponent: String {
        switch identifier {
        case .primary(let value):
            return "id_\(Self.sanitized(value))"
        case .pmcID(let value):
            return "pmc_\(Self.sanitized(value))"
        case .doi(let value):
            return "doi_\(Self.digested(value))"
        }
    }

    /// A human-readable name for this article, for log lines.
    ///
    /// The DOI case names the DOI itself rather than its digest: a log line
    /// exists to be recognised, and nobody recognises a hash.
    public var logDescription: String {
        switch identifier {
        case .primary(let value): return "article \(value)"
        case .pmcID(let value): return "PMC ID \(value)"
        case .doi(let value): return "DOI \(value)"
        }
    }

    /// An identifier reduced to the value worth keying on, or `nil`.
    ///
    /// Whitespace is trimmed first, so a slot holding only spaces falls
    /// through to the next rung rather than naming an entry after nothing.
    ///
    /// - Parameter identifier: The raw slot value.
    /// - Returns: The trimmed identifier, or `nil` when it holds nothing.
    private static func usable(_ identifier: String?) -> String? {
        guard let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// An identifier reduced to characters that are safe in a filename.
    ///
    /// Identifiers reach this type from search results, and
    /// `appendingPathComponent` on a value holding `/` or `..` would place the
    /// written file outside the cache directory.
    ///
    /// - Parameter identifier: The identifier to sanitise.
    /// - Returns: The identifier with every unsafe character replaced by `_`.
    private static func sanitized(_ identifier: String) -> String {
        String(
            identifier.map {
                BioMedLitConstants.cacheKeyAllowedCharacters.contains($0) ? $0 : "_"
            }
        )
    }

    /// An identifier reduced to a hex digest.
    ///
    /// `Hasher` is deliberately not used: Swift seeds it per process, so a
    /// filename built from it would change on every launch and every entry
    /// would miss forever.
    ///
    /// - Parameter identifier: The identifier to digest.
    /// - Returns: The leading ``BioMedLitConstants/doiCacheKeyDigestBytes`` of
    ///   its SHA-256, in hex.
    private static func digested(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .prefix(BioMedLitConstants.doiCacheKeyDigestBytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
