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

/// What asking Europe PMC's `fullTextXML` for an article produced (#434).
///
/// Three outcomes, because they tell the reader three different things. A 404
/// is Europe PMC's own answer. A throttle, an outage, a timeout or a blank
/// 200 is our failure to get one. Folding them into one thrown "unavailable"
/// made a throttled Europe PMC read as an article with no full text, and the
/// apps then marked that article unavailable for good.
///
/// The type says what happened, not what it means. Whether a 404 settles the
/// article is the caller's call: `fullTextXML` serves open-access text only, so
/// for an article Europe PMC holds, a 404 may mean "not open access" rather
/// than "no full text" (#432).
///
/// Mirrors Python's `FullTextXmlFetch` in `europepmc.py`, the reference; the
/// contract is the "Retrieval" section of `doc/cross_platform/fulltext_retrieval.md`.
public enum FullTextXmlFetch: Sendable, Equatable {
    /// Europe PMC served the JATS XML. Never blank: the fetch reports a blank
    /// answer as ``unreachable(_:)`` with ``RequestFailure/incompleteResponse``.
    case served(Data)

    /// Europe PMC answered 404 for this accession.
    case absent

    /// Europe PMC's answer is missing, for the reason given: it could not be
    /// read, it held nothing, or it was never asked because the identifier was
    /// not an accession (``RequestFailure/requestFailed``).
    case unreachable(RequestFailure)
}

/// Turns an identifier into one `fullTextXML` can be asked about.
///
/// Europe PMC serves full text under a PMC accession, and a preprint's under its
/// own `PPR` record ID: a preprint has no PMC ID, and a normaliser that only
/// knew PMC IDs left every preprint's full text unfetched.
///
/// Pure and separate from the service so the accession rules can be tested on
/// their own. Mirrors Python's `fulltext_accession` in `europepmc.py`.
public enum FullTextAccession {
    /// Normalise an untrusted identifier to the accession Europe PMC expects.
    ///
    /// Accepts `PMC123`, `pmc123` and `123` (all become `PMC123`) and `PPR123`
    /// in any case (becomes `PPR123`), after trimming surrounding whitespace.
    /// The digits must be ASCII: the value goes into a URL path, and `isNumber`
    /// alone would admit `PMC١٢٣`. Anything else is refused, so the caller can
    /// record a request never made instead of sending a malformed one (#355).
    ///
    /// Before this, the prefix test was case-sensitive, so `pmc123` became
    /// `PMCpmc123`: a request Europe PMC answers 404, which read as an absence.
    ///
    /// - Parameter identifier: A PMC ID, with or without its prefix, or a
    ///   preprint's `PPR` record ID.
    /// - Returns: For example `"PMC12101959"` or `"PPR1316954"`, or `nil` when
    ///   `identifier` is neither.
    public static func normalized(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if ArticleIdentifierKind.isAllASCIIDigits(trimmed) {
            return BioMedLitConstants.pmcAccessionPrefix + trimmed
        }
        for prefix in [
            BioMedLitConstants.pmcAccessionPrefix,
            BioMedLitConstants.europePMCPreprintAccessionPrefix,
        ] {
            if let digits = digits(after: prefix, in: trimmed) {
                return prefix + digits
            }
        }
        return nil
    }

    /// An accession the value states by its own prefix, normalised.
    ///
    /// Stricter than ``normalized(_:)``, which reads bare digits as a PMC ID.
    /// That is right for a field that holds PMC IDs, and wrong for a slot that
    /// can hold a PubMed ID as well: there, `123` must not become `PMC123`.
    ///
    /// - Parameters:
    ///   - identifier: The identifier, untrusted.
    ///   - prefix: The upper-case prefix it must carry, such as `"PPR"`.
    /// - Returns: For example `"PPR1316954"`, or `nil` without that prefix.
    public static func prefixed(_ identifier: String, as prefix: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return digits(after: prefix, in: trimmed).map { prefix + $0 }
    }

    /// The ASCII digits that follow a case-insensitive prefix, if that is all
    /// the value holds.
    ///
    /// The prefix is compared only when it is ASCII: `uppercased()` changes the
    /// length of some characters (`ß` becomes `SS`), so comparing the case-mapped
    /// string could line up characters that were never the prefix.
    ///
    /// - Parameters:
    ///   - prefix: The upper-case ASCII prefix, such as `"PMC"`.
    ///   - value: The trimmed identifier.
    /// - Returns: The digits, or `nil` when `value` is not `prefix` + digits.
    private static func digits(after prefix: String, in value: String) -> String? {
        let head = value.prefix(prefix.count)
        guard head.allSatisfy(\.isASCII), head.uppercased() == prefix else { return nil }
        let digits = String(value.dropFirst(prefix.count))
        return ArticleIdentifierKind.isAllASCIIDigits(digits) ? digits : nil
    }
}
