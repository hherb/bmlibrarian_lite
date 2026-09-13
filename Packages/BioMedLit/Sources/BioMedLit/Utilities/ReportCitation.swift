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

/// An `Author, Year` citation read from its text, for finding the document it
/// names when it carries no identity.
///
/// A citation with no target — written before references carried an identity,
/// or left behind when a malformed target was removed — can be resolved only
/// this way. Each report view carried its own lookup, which matched a surname
/// as a substring and took the first hit: `[Li, 2016]` opened a paper by
/// Williams, `[Smith & Jones, 2016]` searched for an author called
/// "smith & jones" and opened nothing, and `[Smith, 2016; Jones, 2019]` looked
/// up Smith in 2019 (#233).
///
/// Opening the wrong paper is worse than opening none, so
/// ``uniqueMatch(forCitationText:among:authors:year:)`` opens a document only
/// when exactly one fits.
public struct ReportCitation: Equatable, Sendable {
    /// Each author the citation names, as the folded words of their surname.
    let surnames: [[String]]

    /// The year the citation names, without any disambiguating letter.
    public let year: Int

    /// Reads a citation, or `nil` for text that is not one `Author, Year`
    /// citation.
    ///
    /// The year follows the last comma. Before it, `et al.` is ignored and the
    /// authors are separated by commas, `&` or `and`. A line break counts as a
    /// space, as it does in the paragraph the citation was wrapped in. A list of
    /// citations separated by `;` is refused: it names more than one document.
    ///
    /// - Parameter text: The text between a citation's brackets.
    public init?(citationText text: String) {
        guard !text.contains(BioMedLitConstants.citationListSeparator),
              let lastComma = text.lastIndex(of: ",") else {
            return nil
        }

        let yearText = text[text.index(after: lastComma)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = Self.year(in: yearText) else { return nil }

        let authorText = String(text[..<lastComma]).replacingOccurrences(
            of: BioMedLitConstants.citationEtAlPattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let surnames = authorText
            .replacingOccurrences(
                of: BioMedLitConstants.citationAuthorSeparatorPattern,
                with: ",",
                options: [.regularExpression, .caseInsensitive]
            )
            .split(separator: ",")
            .map { Self.foldedWords(in: String($0)) }
            .filter { !$0.isEmpty }
        guard !surnames.isEmpty else { return nil }

        self.surnames = surnames
        self.year = year
    }

    /// Whether a document with these authors and this year is one this citation
    /// could name.
    ///
    /// The year must be equal, and every surname the citation names must appear
    /// as whole words, in order, in one of the document's authors — in either
    /// stored form, `Smith J` or `Smith, John`. Case and diacritics are ignored.
    ///
    /// - Parameters:
    ///   - authors: The document's authors, as stored.
    ///   - year: The document's year, if known.
    /// - Returns: `true` when the citation fits the document.
    public func matches(authors: [String], year: Int?) -> Bool {
        guard year == self.year else { return false }
        let authorWords = authors.map(Self.foldedWords(in:))
        return surnames.allSatisfy { surname in
            authorWords.contains { Self.words($0, contain: surname) }
        }
    }

    /// The one document a citation names, or `nil` if its text is not a
    /// citation or it fits no document or several.
    ///
    /// Golden rule 8: a tap that opens nothing is logged with the citation's
    /// text and why, so a reader's "nothing happened" can be traced. Showing the
    /// reader why is the view's business (#224).
    ///
    /// - Parameters:
    ///   - text: The text between a citation's brackets.
    ///   - candidates: The documents the report was written from.
    ///   - authors: A candidate's authors.
    ///   - year: A candidate's year.
    /// - Returns: The only candidate the citation fits, or `nil`.
    public static func uniqueMatch<Candidate>(
        forCitationText text: String,
        among candidates: [Candidate],
        authors: (Candidate) -> [String],
        year: (Candidate) -> Int?
    ) -> Candidate? {
        guard let citation = ReportCitation(citationText: text) else {
            BioMedLitLib.logger?.warning(
                """
                A tapped citation could not be read as one Author, Year citation, \
                so no document was opened: [\(text)]
                """,
                category: .parsing
            )
            return nil
        }

        let fitting = candidates.filter { citation.matches(authors: authors($0), year: year($0)) }
        guard fitting.count == 1 else {
            BioMedLitLib.logger?.warning(
                """
                A tapped citation fits \(fitting.count) of the report's \
                \(candidates.count) documents, so none was opened rather than \
                risk the wrong one: [\(text)]
                """,
                category: .parsing
            )
            return nil
        }
        return fitting[0]
    }

    // MARK: - Words

    /// The year in text following a citation's last comma, or `nil`.
    private static func year(in text: String) -> Int? {
        guard let regex = yearRegex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let yearRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[yearRange])
    }

    /// ``BioMedLitConstants/citationYearPattern``, compiled once.
    private static let yearRegex: NSRegularExpression? = ReportInlineText.compiled(
        BioMedLitConstants.citationYearPattern,
        consequence: "no citation without a target will open its document"
    )

    /// A name's words, folded for comparison: letters, digits, apostrophes and
    /// hyphens kept together, everything else a separator.
    private static func foldedWords(in name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }
            .map(String.init)
    }

    /// Whether `words` contains `sequence` as consecutive words.
    private static func words(_ words: [String], contain sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= words.count else { return false }
        return (0...(words.count - sequence.count)).contains { start in
            Array(words[start..<(start + sequence.count)]) == sequence
        }
    }
}
