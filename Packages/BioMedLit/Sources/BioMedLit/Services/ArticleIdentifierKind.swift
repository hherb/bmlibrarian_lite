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

/// What kind of identifier an article's primary slot holds.
///
/// The slot itself cannot say. `EuropePMCService` fills it as
/// `result.pmid ?? result.id ?? ""`, so it carries a PubMed ID for a MEDLINE
/// record, a `PPR…` accession for a preprint, a PMC ID for a PMC-only record,
/// and — through that `?? ""` — nothing at all. Two things downstream need to
/// know which: the Europe PMC query that can match it, since Europe PMC answers
/// only when an identifier is asked for in its own terms, and the PDF cache
/// filename, where two kinds sharing a name serve one article the other's bytes
/// (#202).
///
/// ## Told, not guessed
///
/// Europe PMC states the kind on every record it returns, in the `source` field
/// (`MED`, `PPR`, `PMC`, and a dozen more). That is the authority, and this type
/// exists so it is carried from the decode site to the two places that ask,
/// rather than discarded there and reconstructed from the accession's shape
/// (#209).
///
/// The shape rule remains, as ``inferred(from:)``, for the records that told us
/// nothing: every document stored before the kind was recorded, and any
/// identifier reaching the retrieval chain from somewhere other than a Europe
/// PMC search. It answers ``unknown`` where the shape does not settle it, which
/// is what keeps the `src:med` fall-through from claiming to be a decision.
///
/// What the shape rule may *not* do is name a PubMed ID. A bare decimal is one
/// shape shared by PubMed IDs and by Europe PMC's thesis, case-report and `HIR`
/// accessions, and guessing wrong there hands the reader a real but unrelated
/// article (#212). Where a bare decimal really is a PubMed ID, either the record
/// said so or a PubMed search vouches for it —
/// see ``resolved(declared:accession:provider:)`` and ``pubmedID(in:declared:)``.
public enum ArticleIdentifierKind: Equatable, Hashable, Sendable {
    /// A PubMed ID, Europe PMC's `MED` source.
    ///
    /// Also the kind of every record PubMed itself returns: a PubMed record is
    /// a MEDLINE record, which is what Europe PMC's token names.
    case pubmed

    /// A Europe PMC preprint accession (`PPR1287966`), source `PPR`.
    ///
    /// A preprint carries no PMID and no PMC ID, so this accession and its DOI
    /// are its only identifiers.
    case preprint

    /// A PubMed Central accession (`PMC1082889`), source `PMC`.
    case pmc

    /// A Europe PMC source token this type does not model, lower-cased.
    ///
    /// Europe PMC also serves patents (`PAT`), agricultural records (`AGR`),
    /// theses (`ETH`), case reports (`CBA`) and more, each answering only under
    /// its own token. Keeping the token is what lets such a record be asked for
    /// in its own terms; without it the query names `src:med` and matches
    /// nothing, which is indistinguishable from the article not existing.
    case europePMCSource(String)

    /// Nobody said, and the identifier's shape does not settle it.
    ///
    /// A stated absence of knowledge rather than a kind, so it defers to the
    /// shape rule wherever one is available — see ``resolved(declared:accession:)``.
    case unknown

    /// The kind Europe PMC stated for a record.
    ///
    /// A token outside `[a-z0-9]` is refused rather than carried. The token is
    /// network-supplied, and it reaches two places that need a closed set: a
    /// Europe PMC query as `src:<token>`, where a space or a colon would make
    /// the query parse as something else and match nothing, and — through
    /// ``ArticleCacheKey`` — a filename tag, which is interpolated without
    /// sanitising because every tag is drawn from a fixed vocabulary. Refusing
    /// here is what keeps that assumption true at both ends. Every source token
    /// Europe PMC publishes is a short alphanumeric word, so this refuses
    /// nothing the provider actually sends.
    ///
    /// - Parameter europePMCSource: The record's `source` field, as decoded.
    /// - Returns: `nil` when the record carried no token, or one outside the
    ///   allowed alphabet. Neither is a kind, and neither must be recorded as
    ///   one.
    public init?(europePMCSource: String?) {
        guard let token = europePMCSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !token.isEmpty
        else { return nil }

        guard token.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isWholeNumber) })
        else {
            // Logged rather than dropped quietly. Every token Europe PMC
            // publishes fits this alphabet, so reaching here means the field
            // changed shape under us — and the consequence is silent: the kind
            // reverts to the shape rule and the routing this type exists to fix
            // stops happening, with nothing else to show for it.
            BioMedLitLib.logger?.warning(
                """
                Europe PMC source token '\(token)' is outside the expected \
                alphabet and was not recorded as a kind
                """,
                category: .search
            )
            return nil
        }

        switch token {
        case BioMedLitConstants.europePMCMedlineSource: self = .pubmed
        case BioMedLitConstants.europePMCPreprintSource: self = .preprint
        case BioMedLitConstants.europePMCPMCSource: self = .pmc
        default: self = .europePMCSource(token)
        }
    }

    /// The kind an identifier's shape suggests, for records that stated none.
    ///
    /// Only the two prefixes settle anything. Everything else is ``unknown``,
    /// **including a bare decimal number** — the shape of a PubMed ID, and
    /// equally the shape of a Europe PMC thesis (`ETH`), case report (`CBA`) or
    /// `HIR` accession, none of which carry a PubMed ID at all. 322,044 such
    /// records with abstracts are served today, so this is not a hypothetical
    /// collision.
    ///
    /// Reading that shape as ``pubmed`` was #212. The value went behind the
    /// PubMed base URL and came back as a **real but unrelated article**: Europe
    /// PMC thesis `889149` and PubMed article `889149` — a 1977 paper on mouse
    /// courtship — both exist. A dead link tells the reader something is wrong;
    /// a live link to the wrong paper does not.
    ///
    /// Nothing routes differently for losing that branch: ``unknown`` already
    /// queried `src:med`, which is where a bare number went before. What changed
    /// is that the shape no longer *claims* a kind, so
    /// ``pubmedID(in:declared:)`` refuses it. Where a number really is a PubMed
    /// ID, something says so — the record's `source`, or the provider that
    /// returned it; see ``resolved(declared:accession:provider:)``.
    ///
    /// Case is ignored: Europe PMC writes these accessions upper-case by
    /// convention, and a convention is not a guarantee.
    ///
    /// - Parameter accession: The primary slot's value.
    /// - Returns: The kind its shape settles, or ``unknown``.
    public static func inferred(from accession: String) -> ArticleIdentifierKind {
        let normalised = accession.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalised.isEmpty else { return .unknown }

        if normalised.hasPrefix(BioMedLitConstants.europePMCPreprintAccessionPrefix) {
            return .preprint
        }
        if normalised.hasPrefix(BioMedLitConstants.pmcAccessionPrefix) {
            return .pmc
        }
        return .unknown
    }

    /// Whether every character is an ASCII digit.
    ///
    /// `Character.isNumber` is deliberately not used: it is true for `½`, for
    /// superscripts, and for every non-Latin digit, so `١٢٣` would satisfy it
    /// and be called a PubMed ID. A PubMed ID is an ASCII decimal integer, and
    /// this is the test standing between a slot's value and the PubMed URL —
    /// the one place a wrong label reaches the reader as a real but different
    /// article.
    ///
    /// - Parameter value: The string to test.
    /// - Returns: `true` when `value` is non-empty and all ASCII digits.
    static func isAllASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isWholeNumber }
    }

    /// The kind to act on, given what the record stated and what it holds.
    ///
    /// - Parameters:
    ///   - declared: The kind carried from the record, if one was.
    ///   - accession: The primary slot's value, used only when nothing was
    ///     stated.
    /// - Returns: The stated kind, or the one the shape suggests.
    public static func resolved(
        declared: ArticleIdentifierKind?,
        accession: String
    ) -> ArticleIdentifierKind {
        guard let declared, declared != .unknown else {
            return inferred(from: accession)
        }
        return declared
    }

    /// The kind to act on, given what the record stated, what it holds, and who
    /// returned it.
    ///
    /// Three sources of knowledge, strongest first:
    ///
    /// 1. **The record's own word**, carried since #209. A thesis found through
    ///    a merged search is still a thesis.
    /// 2. **The identifier's shape**, where a prefix settles it. `PPR1287966` is
    ///    a preprint whoever handed it to us, and a provider's blanket claim
    ///    must not overrule the value in front of it — calling that accession a
    ///    PubMed ID would ask Europe PMC for it under `src:med`, where it
    ///    matches nothing.
    /// 3. **The provider**, which can vouch for what the record did not.
    ///
    /// Only ``SearchProvider/pubmed`` vouches, and only for a bare decimal.
    /// PubMed returns MEDLINE records and nothing else, so a search of PubMed
    /// states what a stored document may never have recorded — which is what
    /// keeps every document written before the kind field existed, on the
    /// default provider, reaching its PubMed record.
    ///
    /// ``SearchProvider/both`` vouches for nothing. A merged search records the
    /// *mode* on every document it produces, including the ones only Europe PMC
    /// returned, so it cannot speak for any one article. Making it vouch would
    /// reopen #212 for exactly the records that issue is about.
    ///
    /// - Parameters:
    ///   - declared: The kind carried from the record, if one was.
    ///   - accession: The primary slot's value.
    ///   - provider: The search that returned the record, when one did.
    /// - Returns: The kind to act on, or ``unknown`` when nothing settles it.
    public static func resolved(
        declared: ArticleIdentifierKind?,
        accession: String,
        provider: SearchProvider?
    ) -> ArticleIdentifierKind {
        let byRecordOrShape = resolved(declared: declared, accession: accession)
        guard byRecordOrShape == .unknown else { return byRecordOrShape }

        if provider == .pubmed,
           isAllASCIIDigits(accession.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .pubmed
        }
        return .unknown
    }

    /// The identifier, when it is one that may be pasted after the PubMed URL.
    ///
    /// The single authority for that question. It is asked by the retrieval
    /// chain's last resort and by every app surface that offers a PubMed link or
    /// prints a `PMID:` line — nine of them, which had none of this rule between
    /// them and five of which force-unwrapped the result (#213). A predicate
    /// this consequential re-implemented per surface is how #186 came to be
    /// fixed on one of four.
    ///
    /// Two independent tests, and both must pass:
    ///
    /// - **Someone said it is a PubMed ID.** Shape alone never says so, because
    ///   Europe PMC's numeric accessions are indistinguishable from a PubMed ID
    ///   and resolve, on PubMed, to a real but unrelated article (#212).
    /// - **The value can be one.** It is network-supplied and reaches
    ///   `URL(string:)`, which answers `nil` for a string containing a space.
    ///   ASCII digits only: `Character.isNumber` is true for `½` and for every
    ///   non-Latin numeral, so `١٢٣` once passed as a PubMed ID (#211).
    ///
    /// - Parameters:
    ///   - identifier: The raw primary identifier slot.
    ///   - declared: What is known about the slot — the record's stated kind, or
    ///     the answer of ``resolved(declared:accession:provider:)`` where a
    ///     provider had to vouch for it.
    /// - Returns: The trimmed PubMed ID, or `nil` for anything else.
    public static func pubmedID(
        in identifier: String?,
        declared: ArticleIdentifierKind?
    ) -> String? {
        guard let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              resolved(declared: declared, accession: value) == .pubmed,
              isAllASCIIDigits(value) else { return nil }
        return value
    }

    /// This kind as the Europe PMC token that names it, for storage.
    ///
    /// The stored form is Europe PMC's own vocabulary rather than one of ours,
    /// so writing a kind down invents nothing and reading one back needs no
    /// mapping table to stay in step.
    ///
    /// `nil` for ``unknown``: there is nothing to record, and recording one
    /// would turn "nobody told us" into a claim.
    public var europePMCSourceToken: String? {
        switch self {
        case .pubmed: return BioMedLitConstants.europePMCMedlineSource
        case .preprint: return BioMedLitConstants.europePMCPreprintSource
        case .pmc: return BioMedLitConstants.europePMCPMCSource
        case .europePMCSource(let token): return token
        case .unknown: return nil
        }
    }
}
