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
/// `EuropePMCService` fills the primary slot as `result.pmid ?? result.id ?? ""`
/// — the `?? ""` is why the slot can be empty at all — so it holds a PubMed ID,
/// a Europe PMC preprint accession (`PPR1287966`), or a PMC ID, depending on the
/// record. Were the rungs untagged, an article whose primary slot happened to
/// hold `PMC7654321` would name the same entry as a different article reached by
/// that PMC ID, and one would be served the other's bytes.
///
/// Tagging every rung — the primary one included — invalidates the entries
/// written by earlier builds. Those are re-downloaded once, but they are
/// *orphaned* rather than replaced: the new filename differs, and
/// `deleteCachedPDF` matches on the tagged prefix, so only `clearPDFCache()`
/// reclaims them. That is still the cheap direction to be wrong in, and the same
/// trade this cache already took when the source URL joined the key: a stale
/// entry costs one download and some disk, while serving the wrong article's
/// bytes costs the reader a wrong answer.
///
/// The tag names the identifier's *kind*, not the rung it arrived on. A
/// PMC-only record carries its accession in the primary slot *and* in `pmcId`,
/// so tagging the rung filed one article under two names and downloaded its PDF
/// twice — for exactly the record class this ladder was added to serve (#209).
/// Both rungs now tag `pmc`, so the two paths name one entry.
///
/// ## Usage
///
/// ```swift
/// guard let key = ArticleCacheKey(pmid: "", pmcId: "PMC7654321", doi: nil) else {
///     return  // no identifier to file bytes under
/// }
/// key.filenameComponent  // "pmc_PMC7654321"
/// ```
public struct ArticleCacheKey: Equatable, Hashable, Sendable {
    /// Which identifier named this article, and its value.
    ///
    /// The case is what keeps two kinds apart in the filename; the associated
    /// value is the raw identifier, before sanitising or digesting.
    public enum Identifier: Equatable, Hashable, Sendable {
        /// The document's primary identifier slot, and what kind of identifier
        /// it turned out to hold.
        ///
        /// The slot is deliberately not called `pmid`: it holds a PubMed ID for
        /// a MEDLINE record, a `PPR…` accession for a preprint, and a PMC ID for
        /// a PMC-only record. Naming it for one of the three would be a label
        /// that lies about the other two — so the kind rides alongside instead,
        /// stated by Europe PMC where it said and inferred from the accession
        /// where it did not.
        case primary(String, kind: ArticleIdentifierKind)

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
    ///     ``Identifier/primary(_:kind:)`` for why it is not only ever a PubMed
    ///     ID.
    ///   - pmcId: PubMed Central ID, if the document has one.
    ///   - doi: Digital Object Identifier, if the document has one.
    ///   - primaryKind: What the record said the primary slot holds, when it
    ///     said. Omitted or `nil`, the slot's kind is read from the accession's
    ///     shape, which is what every document stored before the kind was
    ///     recorded falls back on.
    /// - Returns: `nil` when all three are absent or blank, which is the one
    ///   case with no stable name to file bytes under.
    public init?(
        pmid: String?,
        pmcId: String?,
        doi: String?,
        primaryKind: ArticleIdentifierKind? = nil
    ) {
        if let value = Self.usable(pmid) {
            identifier = .primary(
                value,
                kind: ArticleIdentifierKind.resolved(declared: primaryKind, accession: value)
            )
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
    /// Each rung carries a tag naming its kind — see
    /// ``BioMedLitConstants/primaryCacheKeyTag`` — so no two kinds can produce
    /// the same string.
    ///
    /// **Two identifiers that differ only where sanitising is lossy still get
    /// their own components**, which is the property the cache actually needs
    /// and is stronger than keeping the kinds apart. `sanitized` is not
    /// injective: it maps every unsafe character to `_`, so `10.1/abc` and
    /// `10.1_abc` both become `10_1_abc`. A DOI is therefore digested outright,
    /// since it always carries `/` and `.` and never needed to be readable in a
    /// filename. The other two rungs keep their readable form *only while
    /// sanitising changes nothing*, and a digest is appended the moment it does
    /// — so a well-formed PMID or PMC accession names exactly what it always
    /// named, while a malformed one still gets an entry of its own instead of
    /// sharing another article's.
    ///
    /// The guarantee is deliberately not stated as total injectivity, which
    /// would be false: `_` is itself in ``BioMedLitConstants/cacheKeyAllowedCharacters``,
    /// so an identifier that already *looks* like a sanitised-and-digested one
    /// passes through untouched and collides with the real thing. Reaching that
    /// requires an identifier holding a 32-character hex tail no provider emits,
    /// and closing it would cost every readable filename — the trade is stated
    /// here rather than left for a reader to discover as a broken promise.
    ///
    /// Relying on real identifiers being alphanumeric would be a property of the
    /// data rather than of this type, and the primary slot takes whatever the
    /// caller passes.
    public var filenameComponent: String {
        switch identifier {
        case .primary(let value, let kind):
            return Self.component(Self.tag(for: kind), readable: value)
        case .pmcID(let value):
            return Self.component(BioMedLitConstants.pmcCacheKeyTag, readable: value)
        case .doi(let value):
            return "\(BioMedLitConstants.doiCacheKeyTag)_\(Self.digested(value))"
        }
    }

    /// A human-readable name for this article, for log lines.
    ///
    /// The DOI case names the DOI itself rather than its digest: a log line
    /// exists to be recognised, and nobody recognises a hash.
    public var logDescription: String {
        switch identifier {
        case .primary(let value, let kind):
            switch kind {
            case .pubmed: return "PMID \(value)"
            case .preprint: return "preprint \(value)"
            case .pmc: return "PMC ID \(value)"
            case .europePMCSource(let source): return "\(source.uppercased()) record \(value)"
            case .unknown: return "article \(value)"
            }
        case .pmcID(let value): return "PMC ID \(value)"
        case .doi(let value): return "DOI \(value)"
        }
    }

    /// The filename tag naming an identifier's kind.
    ///
    /// An identifier nobody classified takes
    /// ``BioMedLitConstants/primaryCacheKeyTag``, the untyped bucket every
    /// primary-slot value shared before the kinds were separated. A record that
    /// *stated* a source this build does not model takes
    /// ``BioMedLitConstants/europePMCSourceCacheKeyTag`` — a different
    /// situation, and since #212 a materially different one, because an
    /// unvouched decimal accession is now `unknown` rather than a PubMed ID and
    /// would otherwise share a name with a stated thesis carrying the same
    /// digits.
    ///
    /// Neither tag names the source token itself. The token is network-supplied
    /// and the filename format needs a fixed vocabulary, so two identifiers
    /// within one of these buckets that are byte-identical still collide.
    ///
    /// - Parameter kind: The identifier's kind.
    /// - Returns: The tag to file it under.
    private static func tag(for kind: ArticleIdentifierKind) -> String {
        switch kind {
        case .pubmed: return BioMedLitConstants.pubmedCacheKeyTag
        case .preprint: return BioMedLitConstants.preprintCacheKeyTag
        case .pmc: return BioMedLitConstants.pmcCacheKeyTag
        case .europePMCSource: return BioMedLitConstants.europePMCSourceCacheKeyTag
        case .unknown: return BioMedLitConstants.primaryCacheKeyTag
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

    /// A tagged filename component that stays readable when it safely can.
    ///
    /// Sanitising is lossy, so an identifier it alters gets a digest appended to
    /// tell it apart from every other identifier that sanitises the same way.
    /// One that survives sanitising untouched — every well-formed PMID and PMC
    /// accession — is already unique among such identifiers and is left alone,
    /// which is also what keeps this change from invalidating the entries the
    /// tagging above just re-established.
    ///
    /// - Parameters:
    ///   - tag: The rung's kind tag.
    ///   - readable: The raw identifier.
    /// - Returns: `<tag>_<identifier>`, plus `_<digest>` if sanitising was lossy.
    private static func component(_ tag: String, readable: String) -> String {
        let safe = sanitized(readable)
        guard safe != readable else { return "\(tag)_\(safe)" }
        return "\(tag)_\(safe)_\(digested(readable))"
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
