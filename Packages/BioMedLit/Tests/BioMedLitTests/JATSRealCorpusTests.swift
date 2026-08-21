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
/// articles while the whole hand-written JATS suite passed throughout, and two
/// of the six defects fixed in #142 were found by surveying live PMC rather than
/// by the suite. The network-gated `JATSXMLParserIntegrationTests` do see real
/// documents, but they run nightly and never on a pull request.
///
/// So this suite parses the articles committed verbatim under
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
///
/// Because a characterisation can only ever say "this changed", the digest
/// comparison sits on top of a small **specification floor** —
/// ``testEveryArticleClearsTheSpecificationFloor`` — asserting the handful of
/// things that must hold for any real article whatever the stored digest says.
/// Without it a total collapse to zero could be regenerated into the
/// expectations and would then read as correct forever.
final class JATSRealCorpusTests: XCTestCase {

    // MARK: - Fixture location

    /// Name of the corpus directory, relative to the repository root.
    private static let corpusPath = "doc/cross_platform/jats_corpus"

    /// Name of the provenance manifest within the corpus directory.
    private static let manifestFilename = "corpus.json"

    /// How many articles the corpus is expected to hold.
    ///
    /// Pinned because every loop in this suite iterates the manifest, so an
    /// emptied or shrunken corpus would otherwise assert nothing and report
    /// success — measured, before this test existed: six tests, zero failures,
    /// in two milliseconds, with the whole corpus deleted. Adding an article is
    /// fine, raise this. Removing one needs a replacement covering the same
    /// shapes; see the corpus `README.md`.
    private static let expectedArticleCount = 7

    /// Environment variable that rewrites the stored digests from the current
    /// parser output instead of asserting against them.
    ///
    /// Regenerating without reading the resulting diff is the failure mode this
    /// whole suite exists to prevent: it converts any regression into a committed
    /// expectation. A regeneration run therefore always **fails**, so it can
    /// never be mistaken for a verification — see
    /// ``testEveryArticleMatchesItsStoredDigest``.
    private static let regenerateEnvironmentKey = "UPDATE_JATS_DIGESTS"

    /// Errors raised while locating or reading the corpus.
    private enum FixtureError: Error, CustomStringConvertible, LocalizedError {
        case directoryNotFound(origin: String)
        case digestMissing(pmcId: String, path: String)
        case unrecognisedRegenerationValue(String)

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
            case let .unrecognisedRegenerationValue(value):
                return """
                    \(JATSRealCorpusTests.regenerateEnvironmentKey)=\(value) is not a value \
                    this suite understands. Use 1, true or yes to regenerate, or unset it \
                    to assert. Left as-is it would quietly assert instead of regenerating, \
                    which surfaces as a digest mismatch and reads as a parser regression.
                    """
            }
        }

        /// Mirrors ``description`` so `localizedDescription` does not fall back to
        /// the opaque `NSError` text, as `JATSParseError` already avoids.
        var errorDescription: String? { description }
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
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
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
    /// digest is for. The identifiers are the deliberate exception: they were
    /// transcribed from the article by hand, so
    /// ``testTheManifestAgreesWithTheParsedArticle`` can use them as an
    /// independent check on the digest rather than a copy of it.
    private struct CorpusEntry: Decodable {
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
    private struct CorpusManifest: Decodable {
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
    private struct AuthorDigest: Codable, Equatable {
        /// Author's full name as the parser assembles it.
        let name: String
        /// How many affiliations were attached to this author.
        ///
        /// `0` for every author of every corpus article today — see #154, where
        /// affiliations are never captured at all. Kept so that fixing #154 shows
        /// up here as a diff rather than passing unnoticed.
        let affiliationCount: Int
    }

    /// One abstract section.
    ///
    /// Content in full, unlike body prose: there is at most a handful per
    /// article, an abstract is what scoring consumes, and a length alone cannot
    /// tell real prose from same-length filler.
    private struct AbstractSectionDigest: Codable, Equatable {
        /// Section heading. Empty when `<abstract>` carries no `<title>`.
        let title: String
        /// The section's text.
        let content: String
    }

    /// One body section and, recursively, its subsections.
    ///
    /// Paragraph and scalar counts rather than the paragraphs themselves:
    /// storing the prose would make this a full golden snapshot, which nobody can
    /// review and everybody regenerates. Counts still move whenever content is
    /// injected, dropped or re-routed, which is the defect class that matters —
    /// the caption-host bug renamed 51 sections and injected 417 paragraphs.
    private struct SectionDigest: Codable, Equatable {
        /// Section heading.
        let title: String
        /// Number of paragraphs directly in this section.
        let paragraphCount: Int
        /// Total Unicode scalars across those paragraphs.
        ///
        /// Scalars rather than `String.count`, which counts grapheme clusters: a
        /// grapheme count is a Swift-specific number that Kotlin and Python
        /// cannot reproduce, and these bytes are meant to be read by Android too
        /// once #121 lands. Scalars match Python's `len`. The corpus is pure NFC
        /// today, so this keeps the contract portable rather than fixing a live
        /// divergence.
        let scalarCount: Int
        /// Nested subsections, in document order.
        let subsections: [SectionDigest]
    }

    /// One figure.
    ///
    /// Captions are stored in full, unlike body prose: there are only a handful
    /// per article, and caption text is exactly what the caption-host defect
    /// mis-routed.
    private struct FigureDigest: Codable, Equatable {
        /// Figure label, for example "Figure 1".
        let label: String
        /// Full caption text.
        let caption: String
        /// The resolved graphic URL, or `nil` when the figure has none.
        ///
        /// The URL rather than a `hasGraphic` flag: every figure in the corpus
        /// has one, so the flag discriminated nothing, and it could not tell a
        /// correct href from a wrong one. PLOS emits both an image and a thumb
        /// `<graphic>` per figure, so which one the parser resolves is real
        /// behaviour worth pinning.
        let graphicURL: String?
        /// Footnote paragraphs attached to the figure.
        let footnotes: [String]
    }

    /// One table.
    private struct TableDigest: Codable, Equatable {
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

    /// Reference list statistics, plus enough per-reference identity to pin order.
    ///
    /// The aggregates alone left reference *ordering* unguarded, and citation
    /// markers index into this list, so a reversed bibliography would silently
    /// mis-attribute every citation while all five counts stayed identical. One
    /// short ordered line per reference closes that without storing whole
    /// citations.
    private struct ReferenceDigest: Codable, Equatable {
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
        /// One `label|year|doi` line per reference, in document order.
        ///
        /// Not the label alone: eLife emits no `<label>` at all, so a label-only
        /// list is 50 identical empty strings and pins nothing for that article.
        /// Year and DOI are short, stable, and differ between neighbours, which
        /// is all this needs to do.
        let identities: [String]
    }

    /// The stored structural summary of one parsed article.
    private struct ArticleDigest: Codable, Equatable {
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
        /// Reference statistics and ordering.
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
                scalarCount: section.paragraphs.reduce(0) { $0 + $1.unicodeScalars.count },
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
                AbstractSectionDigest(title: $0.title, content: $0.content)
            },
            bodySections: digest(sections: article.bodySections),
            figures: article.figures.map {
                FigureDigest(
                    label: $0.label,
                    caption: $0.caption,
                    graphicURL: $0.graphicURL,
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
                withYear: article.references.filter { !$0.year.isEmpty }.count,
                identities: article.references.map { "\($0.label)|\($0.year)|\($0.doi)" }
            )
        )
    }

    // MARK: - Capturing what the parser reports

    /// Collects the library's diagnostics so a test can assert on them.
    ///
    /// `parseToArticle` reports two kinds of content loss — an unbalanced
    /// `<sub-article>` nesting, and an article that parsed with no authors — by
    /// logging rather than throwing. `BioMedLitLib.logger` is `nil` until the
    /// library is configured, and no test configured it, so those diagnostics
    /// went nowhere: a parse that said in as many words that it had discarded
    /// content still produced a green test.
    ///
    /// `@unchecked Sendable` with a lock because `BioMedLitLogger` requires
    /// `Sendable` and this is mutable; the lock is what makes that claim true.
    private final class RecordingLogger: BioMedLitLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func debug(_ message: String, category: BioMedLitLogCategory) {}
        func info(_ message: String, category: BioMedLitLogCategory) {}

        func warning(_ message: String, category: BioMedLitLogCategory) {
            lock.lock(); defer { lock.unlock() }
            messages.append("WARNING: \(message)")
        }

        func error(_ message: String, category: BioMedLitLogCategory) {
            lock.lock(); defer { lock.unlock() }
            messages.append("ERROR: \(message)")
        }

        /// Everything logged at warning or error since the last ``reset()``.
        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }

        /// Forget everything recorded so far.
        func reset() {
            lock.lock(); defer { lock.unlock() }
            messages.removeAll()
        }
    }

    /// The logger installed for the duration of each test.
    private let logger = RecordingLogger()

    override func setUp() {
        super.setUp()
        logger.reset()
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: logger
        ))
    }

    override func tearDown() {
        // The library cannot be un-configured, so restore what the rest of the
        // package's tests have always run with: configured, but no logger.
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: nil
        ))
        super.tearDown()
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
    /// printing so the committed file diffs line by line; a trailing newline so
    /// an editor or pre-commit hook adding one cannot masquerade as a content
    /// change; an atomic write so an interrupted regeneration cannot leave a
    /// half-written digest behind.
    ///
    /// - Parameters:
    ///   - digest: The digest to store.
    ///   - entry: The manifest entry naming the destination.
    /// - Throws: An encode or write error.
    private static func write(_ digest: ArticleDigest, for entry: CorpusEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(digest)
        data.append(0x0A)
        let url = try requireCorpusDirectory().appendingPathComponent(entry.digest)
        try data.write(to: url, options: .atomic)
    }

    /// Whether this run should rewrite the digests rather than assert against them.
    ///
    /// - Returns: `true` when the environment asks for regeneration.
    /// - Throws: ``FixtureError/unrecognisedRegenerationValue(_:)`` for a value
    ///   that reads like an attempt to regenerate but is not one, so a typo fails
    ///   loudly instead of quietly asserting.
    private static func isRegenerating() throws -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[regenerateEnvironmentKey] else {
            return false
        }
        switch raw.lowercased() {
        case "1", "true", "yes":
            return true
        case "", "0", "false", "no":
            return false
        default:
            throw FixtureError.unrecognisedRegenerationValue(raw)
        }
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
            let line = "\(path) [\(section.paragraphCount)p, \(section.scalarCount)c]"
            return [line] + flatten(section.subsections, prefix: path)
        }
    }

    /// Describe how two flattened section trees differ, as lines a reader can act on.
    ///
    /// Membership changes are reported as `+`/`-`. When the sequences differ but
    /// their *contents* match — a pure reordering, or a duplicate moved around —
    /// there is nothing to add or remove, so the first disagreeing position is
    /// reported instead. This function used to return an empty list in that case
    /// and the caller asserted on emptiness, so a reordered or duplicated tree
    /// passed silently in the one field this corpus exists to guard. The caller
    /// now compares the sequences directly; this only builds the message, and it
    /// must still never come back empty once the sequences are known to differ.
    ///
    /// - Parameters:
    ///   - expectedLines: The stored tree, flattened.
    ///   - actualLines: The freshly parsed tree, flattened.
    /// - Returns: Human-readable difference lines; empty only when the two
    ///   sequences are identical.
    private static func sectionDifferences(
        expectedLines: [String],
        actualLines: [String]
    ) -> [String] {
        guard expectedLines != actualLines else { return [] }

        let expectedSet = Set(expectedLines)
        let actualSet = Set(actualLines)
        let added = actualLines.filter { !expectedSet.contains($0) }.map { "  + \($0)" }
        let removed = expectedLines.filter { !actualSet.contains($0) }.map { "  - \($0)" }
        if !added.isEmpty || !removed.isEmpty {
            return added + removed
        }

        if let divergence = zip(expectedLines, actualLines)
            .enumerated()
            .first(where: { $0.element.0 != $0.element.1 }) {
            return [
                "  the same sections in a different order",
                "  first difference at position \(divergence.offset):",
                "    expected: \(divergence.element.0)",
                "    actual:   \(divergence.element.1)",
            ]
        }
        return [
            "  the same sections, repeated a different number of times",
            "  expected \(expectedLines.count) sections, got \(actualLines.count)",
        ]
    }

    // MARK: - Corpus integrity

    /// The corpus must not quietly lose articles.
    ///
    /// Every other test here loops over the manifest, so an emptied one asserts
    /// nothing and reports success. `README.md` invites replacing the one
    /// non-CC-BY article but says it must not simply be deleted; this is what
    /// makes that more than a request.
    func testTheCorpusHasNotShrunk() throws {
        let articles = try Self.corpusManifest().articles

        XCTAssertEqual(
            articles.count, Self.expectedArticleCount,
            """
            the corpus changed size. Adding an article is fine — raise \
            expectedArticleCount. Removing one needs a replacement covering the same \
            shapes; see \(Self.corpusPath)/README.md.
            """
        )
        XCTAssertEqual(
            Set(articles.map(\.pmcId)).count, articles.count,
            "duplicate pmcId in \(Self.manifestFilename)"
        )
    }

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
            // Per entry, so one unreadable article cannot mask the rest.
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
                XCTAssertEqual(
                    calculateChecksum(data), entry.sha256,
                    """
                    \(entry.pmcId): the committed XML no longer hashes to the value \
                    recorded in \(Self.manifestFilename). These files are third-party \
                    articles kept verbatim; if this one was deliberately re-fetched, \
                    update the manifest hash and say so in the commit.
                    """
                )
            } catch {
                XCTFail("\(entry.pmcId): could not read \(entry.file) — \(error)")
            }
        }
    }

    /// No article and no digest may sit in the corpus unreferenced.
    ///
    /// The transparency parity work found `funder_names.json` committed and, at
    /// that time, read by nothing at all — it has had tests since. An
    /// unreferenced fixture costs repository weight and buys no coverage, and
    /// nobody notices because nothing fails. Checked for
    /// both file kinds: a stale `.digest.json` left behind after an article is
    /// removed is exactly as invisible as a stale `.xml`.
    func testEveryCorpusFileIsInTheManifest() throws {
        let directory = try Self.requireCorpusDirectory()
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let articles = try Self.corpusManifest().articles

        let xmlOnDisk = contents.filter { $0.lowercased().hasSuffix(".xml") }.sorted()
        XCTAssertEqual(
            xmlOnDisk, articles.map(\.file).sorted(),
            "every .xml in \(Self.corpusPath) must have a \(Self.manifestFilename) entry"
        )

        let digestsOnDisk = contents.filter { $0.lowercased().hasSuffix(".digest.json") }.sorted()
        XCTAssertEqual(
            digestsOnDisk, articles.map(\.digest).sorted(),
            "every .digest.json in \(Self.corpusPath) must belong to a manifest entry"
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
            XCTAssertEqual(
                entry.file, "\(entry.pmcId).xml",
                "\(entry.pmcId): filename does not follow the corpus convention"
            )
            XCTAssertEqual(
                entry.digest, "\(entry.pmcId).digest.json",
                "\(entry.pmcId): digest name does not follow the corpus convention"
            )
        }
    }

    // MARK: - The regression suite

    /// Parse every corpus article and compare it against its stored digest.
    ///
    /// This is the test the corpus exists for. Under
    /// ``regenerateEnvironmentKey`` it rewrites the digests and then **fails**,
    /// so a regeneration run can never be mistaken for a verification.
    func testEveryArticleMatchesItsStoredDigest() throws {
        let regenerating = try Self.isRegenerating()
        if regenerating {
            XCTAssertNil(
                ProcessInfo.processInfo.environment["CI"],
                """
                \(Self.regenerateEnvironmentKey) is set in CI. It disables the digest \
                comparison, so the run would report success having checked nothing.
                """
            )
        }

        var rewritten: [String] = []

        for entry in try Self.corpusManifest().articles {
            // Per entry: a parser change that breaks the first article must not
            // hide what it did to the other six. That is the whole argument for a
            // corpus of real documents rather than one worked example.
            do {
                let actual = Self.digest(of: try Self.parse(entry))

                if regenerating {
                    try Self.write(actual, for: entry)
                    rewritten.append(entry.digest)
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
                XCTAssertEqual(
                    actual.references, expected.references, "\(entry.pmcId): references"
                )

                // Ordered comparison, with the readable diff only as the message.
                // A set difference here let a reordered or duplicated tree pass.
                let expectedLines = Self.flatten(expected.bodySections)
                let actualLines = Self.flatten(actual.bodySections)
                XCTAssertEqual(
                    actualLines, expectedLines,
                    """
                    \(entry.pmcId): the body section tree moved.
                    \(Self.sectionDifferences(
                        expectedLines: expectedLines, actualLines: actualLines
                    ).joined(separator: "\n"))
                    """
                )
            } catch {
                XCTFail("\(entry.pmcId): \(error)")
            }
        }

        if regenerating {
            XCTFail("""
                Regenerated \(rewritten.count) digest(s): \(rewritten.joined(separator: ", ")).
                This run asserted nothing about the parser. Read the diff line by line, \
                then re-run without \(Self.regenerateEnvironmentKey) to verify.
                """)
        }
    }

    /// What must hold for any real article, whatever the stored digest says.
    ///
    /// A characterisation can only report "this changed". It cannot tell a known
    /// defect that still reads zero from a fresh collapse that now reads zero —
    /// and #154 and #155 mean this corpus already stores zeros. Combined with a
    /// regeneration, a collapse could be laundered into the expectations and
    /// would read as correct forever. These assertions hold independently of the
    /// stored digest.
    func testEveryArticleClearsTheSpecificationFloor() throws {
        for entry in try Self.corpusManifest().articles {
            do {
                let article = try Self.parse(entry)

                XCTAssertFalse(article.title.isEmpty, "\(entry.pmcId): no title")
                XCTAssertFalse(article.authors.isEmpty, "\(entry.pmcId): no authors")
                XCTAssertFalse(article.abstractSections.isEmpty, "\(entry.pmcId): no abstract")
                XCTAssertFalse(article.bodySections.isEmpty, "\(entry.pmcId): no body sections")
                XCTAssertFalse(article.references.isEmpty, "\(entry.pmcId): no references")
                XCTAssertEqual(
                    article.pmcId, entry.pmcId, "\(entry.pmcId): PMC ID not recovered"
                )
            } catch {
                XCTFail("\(entry.pmcId): \(error)")
            }
        }
    }

    /// The hand-transcribed manifest identifiers must agree with the parse.
    ///
    /// These four values were read off the article by hand, so they are the only
    /// independently-sourced facts in the corpus. Without this test they were
    /// decoded and never read — the same "committed and read by nothing" failure
    /// the orphan check above exists to prevent — and they are the one guard that
    /// survives a blind regeneration: break DOI extraction, regenerate, and every
    /// digest agrees with itself while `corpus.json` still holds the right answer.
    func testTheManifestAgreesWithTheParsedArticle() throws {
        for entry in try Self.corpusManifest().articles {
            do {
                let article = try Self.parse(entry)

                XCTAssertEqual(article.doi, entry.doi, "\(entry.pmcId): DOI")
                XCTAssertEqual(article.pmid, entry.pmid, "\(entry.pmcId): PMID")
                XCTAssertEqual(article.journal, entry.journal, "\(entry.pmcId): journal")
                XCTAssertEqual(article.year, entry.year, "\(entry.pmcId): year")
            } catch {
                XCTFail("\(entry.pmcId): \(error)")
            }
        }
    }

    /// A stored reference count cannot be smaller than the things it counts.
    ///
    /// Cheap protection against the likeliest way a digest goes wrong: someone
    /// hand-edits one to turn a red test green.
    func testStoredReferenceCountsAreInternallyConsistent() throws {
        for entry in try Self.corpusManifest().articles {
            do {
                let references = try Self.storedDigest(for: entry).references
                let named = [
                    ("withDOI", references.withDOI), ("withPMID", references.withPMID),
                    ("withAuthors", references.withAuthors), ("withYear", references.withYear),
                ]
                for (name, value) in named {
                    XCTAssertTrue(
                        (0...references.count).contains(value),
                        """
                        \(entry.pmcId): \(name)=\(value) is impossible against \
                        count=\(references.count)
                        """
                    )
                }
                XCTAssertEqual(
                    references.identities.count, references.count,
                    """
                    \(entry.pmcId): stored \(references.identities.count) identities \
                    for \(references.count) references
                    """
                )
            } catch {
                XCTFail("\(entry.pmcId): \(error)")
            }
        }
    }

    /// Parsing a corpus article must not report content loss.
    ///
    /// `parseToArticle` reports an unbalanced `<sub-article>` nesting and a
    /// zero-author parse by logging, not by throwing. No test had ever installed
    /// a logger, so those diagnostics went nowhere — a parse that announced it
    /// had discarded content still produced a green test.
    func testParsingReportsNoContentLoss() throws {
        for entry in try Self.corpusManifest().articles {
            logger.reset()
            do {
                _ = try Self.parse(entry)
                XCTAssertEqual(
                    logger.recorded, [],
                    """
                    \(entry.pmcId): the parser reported a problem while reading an \
                    article known to be well-formed
                    """
                )
            } catch {
                XCTFail("\(entry.pmcId): \(error)")
            }
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
