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

import BmlibCore
import Foundation

/// SPIKE (WP-2): parse JATS with bmlib's Rust reader and map the result into
/// BioMedLit's own ``JATSArticle``.
///
/// Nothing in the app calls this yet; it exists so the corpus can be read by
/// both parsers and compared (`BmlibJATSParityTests`). The decision record is
/// `doc/cross_platform/bmlib_sync/uniffi_spike.md`.
///
/// ## What the mapping does not carry
///
/// - **Table bodies.** bmlib carries a table as HTML (`htmlContent`), BioMedLit
///   as markdown (`markdownContent`). The adapter leaves `markdownContent`
///   empty rather than putting HTML in a field that promises markdown; a real
///   adoption either renders markdown from bmlib's HTML or moves the apps to
///   bmlib's HTML.
/// - **Fields BioMedLit's model has no slot for**: `elocationId`, `hasBody`,
///   `suppressedNestedArticles`, `fundingStatements`, `fundingAwards`, a
///   reference's `elocationId`, an author's `collab`/`stringName` as separate
///   fields, and the parse audit's warnings. Funding is WP-4.4's subject.
public enum BmlibJATS {
    /// The bmlib crate version the linked binary was built from.
    public static var bmlibVersion: String { BmlibCore.bmlibVersion() }

    /// Parse a JATS document with bmlib and map it into ``JATSArticle``.
    ///
    /// - Parameter data: The JATS XML bytes (UTF-8).
    /// - Returns: The mapped article.
    /// - Throws: ``JATSParseError/parsingFailed(_:)`` when the bytes are not
    ///   UTF-8 or bmlib's reader refuses the document as malformed XML.
    public static func parse(data: Data) throws -> JATSArticle {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw JATSParseError.parsingFailed("document is not UTF-8")
        }
        do {
            return map(try parseJats(xml: xml))
        } catch let error as JatsError {
            throw JATSParseError.parsingFailed(error.localizedDescription)
        }
    }

    /// Map bmlib's article into BioMedLit's.
    ///
    /// - Parameter article: bmlib's parse.
    /// - Returns: The same article in BioMedLit's model.
    public static func map(_ article: JatsArticle) -> JATSArticle {
        JATSArticle(
            title: article.title,
            authors: article.authors.map(map),
            journal: article.journal,
            volume: article.volume,
            issue: article.issue,
            pages: article.pages,
            year: article.year,
            doi: article.doi,
            pmcId: article.pmcId,
            pmid: article.pmid,
            abstractSections: article.abstractSections.map {
                JATSAbstractSection(title: $0.title, content: $0.content)
            },
            bodySections: article.bodySections.map(map),
            figures: article.figures.map {
                JATSFigureInfo(
                    id: $0.id,
                    label: $0.label,
                    caption: $0.caption,
                    graphicURL: $0.graphicUrl,
                    footnotes: $0.footnotes
                )
            },
            tables: article.tables.map {
                JATSTableInfo(
                    id: $0.id,
                    label: $0.label,
                    caption: $0.caption,
                    markdownContent: "",
                    footnotes: $0.footnotes
                )
            },
            references: article.references.map(map)
        )
    }

    /// A contributor. bmlib names a group (`<collab>`) or an undivided
    /// `<string-name>` contributor too, where BioMedLit's builder drops any
    /// contributor without a surname; such a contributor is carried whole in
    /// `surname` so ``JATSAuthorInfo/fullName`` reads bmlib's `fullName`.
    private static func map(_ author: JatsAuthor) -> JATSAuthorInfo {
        let structured = !author.surname.isEmpty || !author.givenNames.isEmpty
        return JATSAuthorInfo(
            surname: structured ? author.surname : author.fullName,
            givenNames: structured ? author.givenNames : "",
            affiliations: author.affiliations
        )
    }

    private static func map(_ section: JatsBodySection) -> JATSBodySection {
        JATSBodySection(
            title: section.title,
            paragraphs: section.paragraphs,
            subsections: section.subsections.map(map)
        )
    }

    /// A reference. bmlib writes `citation` only for a deposited string (a
    /// mixed-content or typeset citation) and leaves it empty for an
    /// element-only one, so a non-empty citation *is* a deposit.
    private static func map(_ reference: JatsReference) -> JATSReferenceInfo {
        JATSReferenceInfo(
            id: reference.id,
            label: reference.label,
            citation: reference.citation,
            authors: reference.authors,
            articleTitle: reference.articleTitle,
            source: reference.source,
            year: reference.year,
            volume: reference.volume,
            issue: reference.issue,
            firstPage: reference.firstPage,
            lastPage: reference.lastPage,
            doi: reference.doi,
            pmid: reference.pmid,
            citationIsDeposit: !reference.citation.isEmpty
        )
    }
}
