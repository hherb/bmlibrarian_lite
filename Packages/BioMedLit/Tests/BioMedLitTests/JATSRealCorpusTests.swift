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

import XCTest
@testable import BioMedLit

/// Offline regression suite over real Europe PMC articles.
///
/// Every other JATS fixture in this repository is hand-written, and hand-written
/// XML encodes only the shapes its author already knew about. That is not a
/// hypothetical limitation here: the caption-host defect affected 86 of 386 real
/// articles while all 59 committed JATS tests passed throughout, and two of the
/// six defects fixed in #142 were found by surveying live PMC rather than by the
/// suite. The network-gated `JATSXMLParserIntegrationTests` do see real
/// documents, but they run nightly and never on a pull request.
///
/// So this suite parses five real articles committed verbatim under
/// `doc/cross_platform/jats_corpus/` and compares the result against a stored
/// structural digest. It needs no network and runs on every pull request.
///
/// **The digest is a characterisation, not a specification.** It records what the
/// parser does today, which includes behaviour known to be wrong — most visibly
/// #144, where `<supplementary-material>` and `<boxed-text>` captions are
/// deliberately excluded from prose because there is no model to capture them
/// into. The fields that are independently checkable against the source XML
/// (identifiers, title, author names, section titles) were verified by hand when
/// the corpus was committed; `README.md` records which is which. A digest change
/// is therefore a prompt to read the diff, never proof of a regression.
final class JATSRealCorpusTests: XCTestCase {

    // MARK: - Fixture location

    /// Name of the corpus directory, relative to the repository root.
    private static let corpusPath = "doc/cross_platform/jats_corpus"

    /// Name of the provenance manifest within the corpus directory.
    private static let manifestFilename = "corpus.json"

    /// Environment variable that rewrites the stored digests from the current
    /// parser output instead of asserting against them.
    ///
    /// Regenerating without reading the resulting diff is the failure mode this
    /// whole suite exists to prevent: it converts any regression into a committed
    /// expectation. `README.md` says so beside the command.
    private static let regenerateEnvironmentKey = "UPDATE_JATS_DIGESTS"

    /// Errors raised while locating or reading the corpus.
    enum FixtureError: Error, CustomStringConvertible {
        case directoryNotFound(origin: String)
        case digestMissing(pmcId: String, path: String)

        var description: String {
            switch self {
            case let .directoryNotFound(origin):
                return "could not locate \(JATSRealCorpusTests.corpusPath) above \(origin)"
            case let .digestMissing(pmcId, path):
                return """
                    no stored digest for \(pmcId) at \(path). Generate it with \
                    \(JATSRealCorpusTests.regenerateEnvironmentKey)=1 swift test \
                    --filter JATSRealCorpusTests, then read the diff before committing.
                    """
            }
        }
    }

    /// Directory holding the shared article corpus.
    ///
    /// Located by walking up from this source file rather than by bundling the
    /// articles as SwiftPM test resources, for the same reason the transparency
    /// parity fixtures are: Android will read these same bytes once its parser is
    /// unit-testable (#121), and a per-platform resource copy is how transcribed
    /// fixtures drift apart.
    ///
    /// `nil` rather than a `fatalError` when the walk comes up empty, so a
    /// checkout without the corpus fails these tests individually instead of
    /// killing the whole test process.
    private static let corpusDirectory: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(corpusPath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// Resolve the corpus directory or throw a readable error.
    ///
    /// - Returns: The corpus directory URL.
    /// - Throws: ``FixtureError/directoryNotFound(origin:)`` if this checkout has
    ///   no corpus directory above this source file.
    private static func requireCorpusDirectory() throws -> URL {
        guard let directory = corpusDirectory else {
            throw FixtureError.directoryNotFound(origin: #filePath)
        }
        return directory
    }

    // MARK: - Provenance manifest

    /// One article's provenance record from `corpus.json`.
    ///
    /// Every field here is about where the bytes came from and why they were
    /// kept. Nothing derived from parsing belongs in this type — that is what the
    /// digest is for.
    struct CorpusEntry: Decodable, Equatable {
        /// PMC identifier, and the stem of both the XML and digest filenames.
        let pmcId: String
        /// XML filename within the corpus directory.
        let file: String
        /// Digest filename within the corpus directory.
        let digest: String
        /// SHA-256 of the XML file as retrieved, lowercase hex.
        let sha256: String
        /// Journal title as printed in the article.
        let journal: String
        /// Publisher name as printed in the article.
        let publisher: String
        /// Article DOI.
        let doi: String
        /// PubMed identifier.
        let pmid: String
        /// Publication year.
        let year: String
        /// SPDX-style licence code, for example `CC-BY-4.0`.
        let licence: String
        /// Canonical licence URL as carried in the article's `<license>`.
        let licenceURL: String
        /// Why this article earns its place, in terms of the shapes it exercises.
        let inCorpusBecause: String
    }

    /// The corpus provenance manifest.
    struct CorpusManifest: Decodable {
        /// What the corpus is for.
        let description: String
        /// ISO date the articles were retrieved.
        let retrieved: String
        /// Templated endpoint the articles came from.
        let sourceEndpoint: String
        /// One entry per committed article.
        let articles: [CorpusEntry]
    }

    /// The manifest, decoded once per test run.
    ///
    /// Stored as a `Result` because a static stored property cannot itself throw;
    /// the error is rethrown on access so an unreadable manifest fails each test
    /// individually rather than trapping the process.
    private static let manifest = Result<CorpusManifest, Error> {
        let data = try Data(
            contentsOf: try requireCorpusDirectory().appendingPathComponent(manifestFilename)
        )
        return try JSONDecoder().decode(CorpusManifest.self, from: data)
    }

    /// The decoded manifest.
    ///
    /// - Returns: The provenance manifest.
    /// - Throws: Whatever locating, reading or decoding it raised.
    private static func corpusManifest() throws -> CorpusManifest {
        try manifest.get()
    }

    // MARK: - Digest model

    /// One author, reduced to the parts a regression would move.
    struct AuthorDigest: Codable, Equatable {
        /// Author's full name as the parser assembles it.
        let name: String
        /// How many affiliations were attached to this author.
        let affiliationCount: Int
    }

    /// One abstract section.
    struct AbstractSectionDigest: Codable, Equatable {
        /// Section heading, empty for an unstructured abstract.
        let title: String
        /// Character count of the section content.
        let characterCount: Int
    }

    /// One body section and, recursively, its subsections.
    ///
    /// Paragraph and character counts rather than the paragraphs themselves:
    /// storing the prose would make this a full golden snapshot, which nobody can
    /// review and everybody regenerates. Counts still move whenever content is
    /// injected, dropped or re-routed, which is the defect class that matters —
    /// the caption-host bug renamed 51 sections and injected 417 paragraphs.
    struct SectionDigest: Codable, Equatable {
        /// Section heading.
        let title: String
        /// Number of paragraphs directly in this section.
        let paragraphCount: Int
        /// Total characters across those paragraphs.
        let characterCount: Int
        /// Nested subsections, in document order.
        let subsections: [SectionDigest]
    }

    /// One figure.
    ///
    /// Captions are stored in full, unlike body prose: there are only a handful
    /// per article, and caption text is exactly what the caption-host defect
    /// mis-routed. A `<media>` legend concatenated onto its enclosing figure's
    /// caption — 144 occurrences in the survey behind #142 — shows up here and
    /// nowhere else.
    struct FigureDigest: Codable, Equatable {
        /// Figure label, for example "Figure 1".
        let label: String
        /// Full caption text.
        let caption: String
        /// Whether a graphic URL was resolved.
        let hasGraphic: Bool
        /// Footnote paragraphs attached to the figure.
        let footnotes: [String]
    }

    /// One table.
    struct TableDigest: Codable, Equatable {
        /// Table label, for example "Table 1".
        let label: String
        /// Full caption text.
        let caption: String
        /// Lines in the rendered markdown table, including the header rule.
        let markdownRowCount: Int
        /// Footnote paragraphs from `<table-wrap-foot>`.
        ///
        /// Pinned because this branch once deleted them outright: routing every
        /// non-caption `<p>` to the cell branch dropped the abbreviation
        /// expansions and per-table funding notes the transparency regexes read.
        let footnotes: [String]
    }

    /// Aggregate reference statistics.
    ///
    /// Counts rather than the reference list, because a bibliography is long,
    /// uninteresting to read in a diff, and regresses in bulk: a parser that
    /// stops reading `<pub-id>` moves `withDOI` to zero and nothing else.
    struct ReferenceDigest: Codable, Equatable {
        /// Total references parsed.
        let count: Int
        /// How many carry a DOI.
        let withDOI: Int
        /// How many carry a PMID.
        let withPMID: Int
        /// How many carry at least one author.
        let withAuthors: Int
        /// How many carry a publication year.
        let withYear: Int
    }

    /// The stored structural summary of one parsed article.
    struct ArticleDigest: Codable, Equatable {
        /// PMC identifier as recovered from the XML, not as supplied by the test.
        let pmcId: String
        /// Article DOI.
        let doi: String
        /// PubMed identifier.
        let pmid: String
        /// Journal title.
        let journal: String
        /// Publication year.
        let year: String
        /// Volume, as printed.
        let volume: String
        /// Issue, as printed.
        let issue: String
        /// Page range, as printed.
        let pages: String
        /// Article title.
        let title: String
        /// Authors in document order.
        let authors: [AuthorDigest]
        /// Abstract sections in document order.
        let abstractSections: [AbstractSectionDigest]
        /// Top-level body sections in document order.
        let bodySections: [SectionDigest]
        /// Figures in document order.
        let figures: [FigureDigest]
        /// Tables in document order.
        let tables: [TableDigest]
        /// Aggregate reference statistics.
        let references: ReferenceDigest
    }

    // MARK: - Digest construction

    /// Reduce a parsed section tree to its digest form.
    ///
    /// - Parameter sections: Sections in document order.
    /// - Returns: The same tree with prose replaced by counts.
    private static func digest(sections: [JATSBodySection]) -> [SectionDigest] {
        sections.map { section in
            SectionDigest(
                title: section.title,
                paragraphCount: section.paragraphs.count,
                characterCount: section.paragraphs.reduce(0) { $0 + $1.count },
                subsections: digest(sections: section.subsections)
            )
        }
    }

    /// Reduce a parsed article to the structure this suite asserts on.
    ///
    /// - Parameter article: The parsed article.
    /// - Returns: Its structural digest.
    private static func digest(of article: JATSArticle) -> ArticleDigest {
        ArticleDigest(
            pmcId: article.pmcId,
            doi: article.doi,
            pmid: article.pmid,
            journal: article.journal,
            year: article.year,
            volume: article.volume,
            issue: article.issue,
            pages: article.pages,
            title: article.title,
            authors: article.authors.map {
                AuthorDigest(name: $0.fullName, affiliationCount: $0.affiliations.count)
            },
            abstractSections: article.abstractSections.map {
                AbstractSectionDigest(title: $0.title, characterCount: $0.content.count)
            },
            bodySections: digest(sections: article.bodySections),
            figures: article.figures.map {
                FigureDigest(
                    label: $0.label,
                    caption: $0.caption,
                    hasGraphic: $0.graphicURL?.isEmpty == false,
                    footnotes: $0.footnotes
                )
            },
            tables: article.tables.map {
                TableDigest(
                    label: $0.label,
                    caption: $0.caption,
                    markdownRowCount: $0.markdownContent
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .count,
                    footnotes: $0.footnotes
                )
            },
            references: ReferenceDigest(
                count: article.references.count,
                withDOI: article.references.filter { !$0.doi.isEmpty }.count,
                withPMID: article.references.filter { !$0.pmid.isEmpty }.count,
                withAuthors: article.references.filter { !$0.authors.isEmpty }.count,
                withYear: article.references.filter { !$0.year.isEmpty }.count
            )
        )
    }

    // MARK: - Reading the corpus

    /// Parse one corpus article from its committed bytes.
    ///
    /// Deliberately does **not** pass `knownPMCId`: recovering the PMC ID from
    /// the document is part of what this suite measures, and supplying it would
    /// make `ArticleDigest.pmcId` a copy of the test's own input.
    ///
    /// - Parameter entry: The manifest entry naming the file.
    /// - Returns: The parsed article.
    /// - Throws: A read error, or whatever the parser raised.
    private static func parse(_ entry: CorpusEntry) throws -> JATSArticle {
        let url = try requireCorpusDirectory().appendingPathComponent(entry.file)
        return try JATSXMLParser(data: try Data(contentsOf: url)).parseToArticle()
    }

    /// Read one article's stored digest.
    ///
    /// - Parameter entry: The manifest entry naming the digest file.
    /// - Returns: The stored digest.
    /// - Throws: ``FixtureError/digestMissing(pmcId:path:)`` when the file is
    ///   absent, or a decode error when it is malformed.
    private static func storedDigest(for entry: CorpusEntry) throws -> ArticleDigest {
        let url = try requireCorpusDirectory().appendingPathComponent(entry.digest)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.digestMissing(pmcId: entry.pmcId, path: url.path)
        }
        return try JSONDecoder().decode(ArticleDigest.self, from: try Data(contentsOf: url))
    }

    /// Write one article's digest back to the corpus directory.
    ///
    /// Only reached under ``regenerateEnvironmentKey``. Sorted keys and pretty
    /// printing so the committed file diffs line by line.
    ///
    /// - Parameters:
    ///   - digest: The digest to store.
    ///   - entry: The manifest entry naming the destination.
    /// - Throws: An encode or write error.
    private static func write(_ digest: ArticleDigest, for entry: CorpusEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = try requireCorpusDirectory().appendingPathComponent(entry.digest)
        try encoder.encode(digest).write(to: url)
    }

    // MARK: - Difference reporting

    /// Flatten a section tree to `Parent > Child` paths with their counts.
    ///
    /// `XCTAssertEqual` on a nested tree prints one unreadable blob. Flattening
    /// first means a failure names the section that moved.
    ///
    /// - Parameters:
    ///   - sections: The section tree.
    ///   - prefix: Accumulated ancestor titles.
    /// - Returns: One line per section, in document order.
    private static func flatten(_ sections: [SectionDigest], prefix: String = "") -> [String] {
        sections.flatMap { section -> [String] in
            let title = section.title.isEmpty ? "(untitled)" : section.title
            let path = prefix.isEmpty ? title : "\(prefix) > \(title)"
            let line = "\(path) [\(section.paragraphCount)p, \(section.characterCount)c]"
            return [line] + flatten(section.subsections, prefix: path)
        }
    }

    /// Describe how two section trees differ, as lines a reader can act on.
    ///
    /// - Parameters:
    ///   - expected: The stored tree.
    ///   - actual: The freshly parsed tree.
    /// - Returns: Removed and added lines, empty when the trees agree.
    private static func sectionDifferences(
        expected: [SectionDigest],
        actual: [SectionDigest]
    ) -> [String] {
        let expectedLines = flatten(expected)
        let actualLines = flatten(actual)
        guard expectedLines != actualLines else { return [] }
        let expectedSet = Set(expectedLines)
        let actualSet = Set(actualLines)
        return actualLines.filter { !expectedSet.contains($0) }.map { "  + \($0)" }
            + expectedLines.filter { !actualSet.contains($0) }.map { "  - \($0)" }
    }

    // MARK: - Corpus integrity

    func testEveryManifestEntryHasItsBytes() throws {
        let directory = try Self.requireCorpusDirectory()
        for entry in try Self.corpusManifest().articles {
            let url = directory.appendingPathComponent(entry.file)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(entry.pmcId): manifest names \(entry.file), which is not in the corpus"
            )
        }
    }

    /// The bytes must be exactly what Europe PMC served.
    ///
    /// An edited fixture is a synthetic fixture wearing a real article's name,
    /// and it would quietly undo the only property this corpus has that the
    /// hand-written suites do not. Trimming one to save space counts as editing.
    func testCorpusBytesAreUnmodified() throws {
        let directory = try Self.requireCorpusDirectory()
        for entry in try Self.corpusManifest().articles {
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
            XCTAssertEqual(
                calculateChecksum(data), entry.sha256,
                """
                \(entry.pmcId): the committed XML no longer hashes to the value \
                recorded in \(Self.manifestFilename). These files are third-party \
                articles kept verbatim; if this article was deliberately re-fetched, \
                update the manifest hash and say so in the commit.
                """
            )
        }
    }

    /// No article may sit in the corpus without a manifest entry.
    ///
    /// The transparency parity work found `funder_names.json` committed and read
    /// by nothing at all. An unreferenced fixture costs repository weight and
    /// buys no coverage, and nobody notices because nothing fails.
    func testEveryCorpusFileIsInTheManifest() throws {
        let directory = try Self.requireCorpusDirectory()
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".xml") }
            .sorted()
        let inManifest = try Self.corpusManifest().articles.map(\.file).sorted()
        XCTAssertEqual(
            onDisk, inManifest,
            "every .xml in \(Self.corpusPath) must have a \(Self.manifestFilename) entry"
        )
    }

    /// Provenance is the licence record, so it may not be left blank.
    func testEveryEntryRecordsItsProvenance() throws {
        for entry in try Self.corpusManifest().articles {
            XCTAssertFalse(entry.licence.isEmpty, "\(entry.pmcId): no licence code")
            XCTAssertTrue(
                entry.licenceURL.hasPrefix("https://creativecommons.org/"),
                "\(entry.pmcId): licence URL is not a Creative Commons deed: \(entry.licenceURL)"
            )
            XCTAssertFalse(entry.publisher.isEmpty, "\(entry.pmcId): no publisher")
            XCTAssertFalse(
                entry.inCorpusBecause.isEmpty,
                """
                \(entry.pmcId): no reason recorded. An article nobody can justify \
                is an article nobody will know how to replace.
                """
            )
        }
    }

    // MARK: - The regression suite

    /// Parse every corpus article and compare it against its stored digest.
    ///
    /// This is the test the corpus exists for. Under
    /// ``regenerateEnvironmentKey`` it rewrites the digests instead of asserting.
    func testEveryArticleMatchesItsStoredDigest() throws {
        let regenerating =
            ProcessInfo.processInfo.environment[Self.regenerateEnvironmentKey] == "1"

        for entry in try Self.corpusManifest().articles {
            let actual = Self.digest(of: try Self.parse(entry))

            if regenerating {
                try Self.write(actual, for: entry)
                continue
            }

            let expected = try Self.storedDigest(for: entry)

            XCTAssertEqual(actual.pmcId, expected.pmcId, "\(entry.pmcId): PMC ID")
            XCTAssertEqual(actual.doi, expected.doi, "\(entry.pmcId): DOI")
            XCTAssertEqual(actual.pmid, expected.pmid, "\(entry.pmcId): PMID")
            XCTAssertEqual(actual.journal, expected.journal, "\(entry.pmcId): journal")
            XCTAssertEqual(actual.year, expected.year, "\(entry.pmcId): year")
            XCTAssertEqual(actual.volume, expected.volume, "\(entry.pmcId): volume")
            XCTAssertEqual(actual.issue, expected.issue, "\(entry.pmcId): issue")
            XCTAssertEqual(actual.pages, expected.pages, "\(entry.pmcId): pages")
            XCTAssertEqual(actual.title, expected.title, "\(entry.pmcId): title")
            XCTAssertEqual(actual.authors, expected.authors, "\(entry.pmcId): authors")
            XCTAssertEqual(
                actual.abstractSections, expected.abstractSections,
                "\(entry.pmcId): abstract sections"
            )
            XCTAssertEqual(actual.figures, expected.figures, "\(entry.pmcId): figures")
            XCTAssertEqual(actual.tables, expected.tables, "\(entry.pmcId): tables")
            XCTAssertEqual(actual.references, expected.references, "\(entry.pmcId): references")

            let differences = Self.sectionDifferences(
                expected: expected.bodySections, actual: actual.bodySections
            )
            XCTAssertTrue(
                differences.isEmpty,
                """
                \(entry.pmcId): the body section tree moved.
                \(differences.joined(separator: "\n"))
                """
            )
        }
    }

    /// A stored digest must exist for every article before the suite means anything.
    ///
    /// Separated from the comparison above so that a missing digest reads as
    /// "the corpus is incomplete" rather than as a parser regression.
    func testEveryArticleHasAStoredDigest() throws {
        for entry in try Self.corpusManifest().articles {
            XCTAssertNoThrow(
                try Self.storedDigest(for: entry),
                "\(entry.pmcId): stored digest missing or unreadable"
            )
        }
    }

}
