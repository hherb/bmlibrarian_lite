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
import XCTest
@testable import BioMedLit

/// SPIKE (WP-2): the real JATS corpus through **both** parsers — BioMedLit's
/// `JATSXMLParser` and bmlib's Rust reader over UniFFI, mapped by
/// ``BmlibJATS`` — compared on a stated subset of fields.
///
/// Fields the two must agree on are asserted. Fields where they are known to
/// differ — every difference classified in
/// `doc/cross_platform/bmlib_sync/uniffi_spike.md` — are reported, not
/// asserted, so the test states the divergence instead of hiding it. Set
/// `BMLIB_PARITY_REPORT=/path/report.json` to write the per-article report,
/// and `BMLIB_PARITY_TIMING=1` to time both parsers.
///
/// Body paragraphs are reported, never asserted: the 11 classified
/// differences are not yet encoded as an allowlist, so this test cannot
/// catch a new paragraph-level difference (see the spike record's
/// "Before any Phase 4 switch").
final class BmlibJATSParityTests: XCTestCase {

    private static let corpusPath = "doc/cross_platform/jats_corpus"

    /// Set to `1` to time both parsers over the corpus (off by default, so
    /// CI's `swift test` does not pay for it).
    private static let timingVariable = "BMLIB_PARITY_TIMING"

    /// Runs per article per parser when timing; the reported time is the mean.
    private static let timingRepetitions = 20

    /// The same in-checkout walk `JATSRealCorpusTests` uses (stops at `.git`).
    private static let corpusDirectory: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(corpusPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private static func corpusFiles() throws -> [URL] {
        let directory = try XCTUnwrap(corpusDirectory, "no jats_corpus above \(#filePath)")
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - The compared subset

    /// Fields both parsers must agree on.
    private struct Agreed: Equatable, Codable {
        let pmcId, doi, pmid, journal, year, volume, issue, pages, title: String
        let authors: [String]
        let figures: [String]
        let tables: [String]
        let referenceCount: Int
        let referenceIdentities: [String]
        let referenceFieldCounts: [Int]
        let abstract: [String]
    }

    /// Fields reported but not asserted.
    private struct Reported: Equatable, Codable {
        let sectionPaths: [String]
        let paragraphCount: Int
        let scalarCount: Int
        let referencesWithCitation: Int
    }

    private static func agreed(_ a: JATSArticle, droppingTitleOnlyAbstractSections: Bool) -> Agreed {
        let refs = a.references
        let abstract = a.abstractSections
            .filter { !droppingTitleOnlyAbstractSections || !$0.content.isEmpty }
            .map { "\($0.title)|\($0.content)" }
        return Agreed(
            pmcId: a.pmcId, doi: a.doi, pmid: a.pmid, journal: a.journal, year: a.year,
            volume: a.volume, issue: a.issue, pages: a.pages, title: a.title,
            // Names only: BioMedLit captures no affiliations (#154), bmlib does.
            authors: a.authors.map(\.fullName),
            figures: a.figures.map {
                "\($0.label)|\($0.caption)|\($0.graphicURL ?? "<nil>")|\($0.footnotes.joined(separator: "¶"))"
            },
            tables: a.tables.map { "\($0.label)|\($0.caption)|\($0.footnotes.joined(separator: "¶"))" },
            referenceCount: refs.count,
            referenceIdentities: refs.map { "\($0.label)|\($0.year)|\($0.doi)|\($0.pmid)" },
            referenceFieldCounts: [
                refs.filter { !$0.authors.isEmpty }.count,
                refs.filter { !$0.articleTitle.isEmpty }.count,
                refs.filter { !$0.source.isEmpty }.count,
                refs.filter { !$0.volume.isEmpty }.count,
                refs.filter { !$0.firstPage.isEmpty }.count,
            ],
            abstract: abstract
        )
    }

    private static func paths(_ sections: [JATSBodySection], prefix: String = "") -> [String] {
        sections.flatMap { section -> [String] in
            let path = "\(prefix)>\(section.title)"
            return [path] + paths(section.subsections, prefix: path)
        }
    }

    private static func paragraphs(_ sections: [JATSBodySection]) -> [String] {
        sections.flatMap { $0.paragraphs + paragraphs($0.subsections) }
    }

    private static func reported(_ a: JATSArticle) -> Reported {
        let paras = paragraphs(a.bodySections)
        return Reported(
            sectionPaths: paths(a.bodySections),
            paragraphCount: paras.count,
            scalarCount: paras.reduce(0) { $0 + $1.unicodeScalars.count },
            referencesWithCitation: a.references.filter { !$0.citation.isEmpty }.count
        )
    }

    // MARK: - Tests

    /// Acceptance criterion 1: `parse_jats` is callable from BioMedLit.
    func testParseJatsIsCallableThroughUniFFI() throws {
        XCTAssertEqual(BmlibJATS.bmlibVersion, "0.3.0")
        let xml = """
            <article><front><article-meta><title-group><article-title>T</article-title>\
            </title-group></article-meta></front><body><sec><title>S</title><p>P</p></sec></body></article>
            """
        let article = try BmlibJATS.parse(data: Data(xml.utf8))
        XCTAssertEqual(article.title, "T")
        XCTAssertEqual(article.bodySections.first?.paragraphs, ["P"])
    }

    /// Malformed XML is a ``JATSParseError/parsingFailed(_:)`` carrying the
    /// XML reader's reason, not the debug spelling of BmlibCore's error.
    func testMalformedXMLThrowsParsingFailedWithTheReadersReason() {
        XCTAssertThrowsError(try BmlibJATS.parse(data: Data("<article><body>".utf8))) { error in
            guard case JATSParseError.parsingFailed(let reason) = error else {
                return XCTFail("expected JATSParseError.parsingFailed, got \(type(of: error)): \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("JatsError"), "debug text leaked: \(reason)")
            XCTAssertFalse(reason.contains("Xml(reason:"), "debug text leaked: \(reason)")
        }
    }

    /// A document in a declared non-UTF-8 encoding is refused with a message
    /// that says why (bmlib reads UTF-8 only), not parsed as mojibake.
    func testNonUTF8DocumentIsRefusedWithAClearMessage() {
        var latin1 = Data(#"<?xml version="1.0" encoding="ISO-8859-1"?><article><front>"#.utf8)
        latin1.append(contentsOf: [0x3C, 0x70, 0x3E, 0xE9, 0x3C, 0x2F, 0x70, 0x3E]) // <p>é</p> in Latin-1
        latin1.append(Data("</front></article>".utf8))
        XCTAssertThrowsError(try BmlibJATS.parse(data: latin1)) { error in
            guard case JATSParseError.parsingFailed(let reason) = error else {
                return XCTFail("expected JATSParseError.parsingFailed, got \(error)")
            }
            XCTAssertEqual(reason, BmlibJATS.notUTF8Message)
        }
    }

    /// The adapter keeps every contributor bmlib names, and reads its full
    /// name exactly: a mononym (given names only) without a trailing space, a
    /// group author and an undivided `<string-name>` whole, and a structured
    /// name field for field.
    func testContributorsWithoutASurnameAreKeptWithBmlibsFullName() throws {
        let xml = """
            <article><front><article-meta><title-group><article-title>T</article-title></title-group>\
            <contrib-group>\
            <contrib contrib-type="author"><name><surname>Smith</surname><given-names>Jane</given-names></name></contrib>\
            <contrib contrib-type="author"><name><given-names>Sukarno</given-names></name></contrib>\
            <contrib contrib-type="author"><collab>The Writing Group</collab></contrib>\
            <contrib contrib-type="author"><string-name>A. B. Undivided</string-name></contrib>\
            </contrib-group></article-meta></front></article>
            """
        let authors = try BmlibJATS.parse(data: Data(xml.utf8)).authors
        XCTAssertEqual(
            authors.map(\.fullName),
            ["Jane Smith", "Sukarno", "The Writing Group", "A. B. Undivided"]
        )
        XCTAssertEqual(authors.first?.surname, "Smith")
        XCTAssertEqual(authors.first?.givenNames, "Jane")
        XCTAssertEqual(authors.dropFirst().map(\.givenNames), ["", "", ""])
    }

    /// Acceptance criterion 2: the corpus through both parsers.
    func testCorpusThroughBothParsers() throws {
        let files = try Self.corpusFiles()
        XCTAssertEqual(files.count, 7, "the corpus has seven articles")
        var report: [[String: Any]] = []
        var swiftSeconds = 0.0, rustSeconds = 0.0
        // Authors are compared by name only, so affiliations need their own check.
        var articlesWithAffiliations = 0
        // The timing loop parses every article 2 × timingRepetitions more
        // times, so it runs only on request (BMLIB_PARITY_TIMING=1); otherwise
        // each article is parsed once by each parser and no time is reported.
        let timed = ProcessInfo.processInfo.environment[Self.timingVariable] == "1"
        let repetitions = timed ? Self.timingRepetitions : 0

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: file)

            let swift = try JATSXMLParser(data: data).parseToArticle()
            let rust = try BmlibJATS.parse(data: data)
            if rust.authors.contains(where: { !$0.affiliations.isEmpty }) { articlesWithAffiliations += 1 }

            // bmlib keeps an abstract section deposited as a title alone (BMJ's
            // `<sec><title> Abstract</title></sec>`); BioMedLit drops it.
            // Classified (b) in the spike record; compared with it removed.
            XCTAssertEqual(
                Self.agreed(swift, droppingTitleOnlyAbstractSections: false),
                Self.agreed(rust, droppingTitleOnlyAbstractSections: true),
                "\(name): the agreed subset differs"
            )

            // Nothing BioMedLit titles is lost: every section path the Swift
            // parser produces also exists in bmlib's tree.
            let swiftReport = Self.reported(swift), rustReport = Self.reported(rust)
            // Except Europe PMC's injected associated-data block, a copy of the
            // supplementary legends and the data statement, which bmlib drops
            // (bmlib#497) and BioMedLit still prints (#587).
            let missing = Set(swiftReport.sectionPaths.filter { !$0.hasPrefix(">Associated Data") })
                .subtracting(rustReport.sectionPaths)
            XCTAssertTrue(missing.isEmpty, "\(name): sections only Swift has: \(missing.sorted())")
            // The exemption holds only while bmlib really drops the block.
            XCTAssertFalse(
                rustReport.sectionPaths.contains { $0.hasPrefix(">Associated Data") },
                "\(name): bmlib kept the associated-data block; drop the exemption above"
            )

            var entry: [String: Any] = [
                "article": name,
                "swift": try JSONSerialization.jsonObject(with: JSONEncoder().encode(swiftReport)),
                "rust": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rustReport)),
                "swiftParagraphs": Self.paragraphs(swift.bodySections),
                "rustParagraphs": Self.paragraphs(rust.bodySections),
            ]
            var line = String(
                format: "%@: paragraphs swift %d rust %d; "
                    + "sections swift %d rust %d; refs with citation swift %d rust %d",
                name,
                swiftReport.paragraphCount, rustReport.paragraphCount,
                swiftReport.sectionPaths.count, rustReport.sectionPaths.count,
                swiftReport.referencesWithCitation, rustReport.referencesWithCitation
            )
            if timed {
                var swiftTime = 0.0, rustTime = 0.0
                for _ in 0..<repetitions {
                    var start = Date()
                    _ = try JATSXMLParser(data: data).parseToArticle()
                    swiftTime += Date().timeIntervalSince(start)
                    start = Date()
                    _ = try BmlibJATS.parse(data: data)
                    rustTime += Date().timeIntervalSince(start)
                }
                let swiftMean = swiftTime / Double(repetitions), rustMean = rustTime / Double(repetitions)
                swiftSeconds += swiftMean
                rustSeconds += rustMean
                entry["swiftMs"] = swiftMean * 1000
                entry["rustMs"] = rustMean * 1000
                line += String(format: "; swift %.2f ms, rust %.2f ms", swiftMean * 1000, rustMean * 1000)
            }
            print("[bmlib-parity] \(line)")
            report.append(entry)
        }
        XCTAssertGreaterThan(articlesWithAffiliations, 0, "bmlib linked no affiliations in the corpus")
        if timed {
            print(String(format: "[bmlib-parity] corpus total (mean of %d runs): swift %.2f ms, rust %.2f ms",
                         repetitions, swiftSeconds * 1000, rustSeconds * 1000))
        }

        if let path = ProcessInfo.processInfo.environment["BMLIB_PARITY_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Swift 6 concurrency: bmlib's records are `Sendable` value types and the
    /// free functions hold no state, so a parse may run off the main actor.
    func testParseRunsConcurrentlyOffTheMainActor() async throws {
        let files = try Self.corpusFiles()
        let titles = try await withThrowingTaskGroup(of: String.self) { group in
            for file in files {
                group.addTask {
                    try BmlibJATS.parse(data: try Data(contentsOf: file)).title
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(titles.count, files.count)
        XCTAssertFalse(titles.contains(""))
    }
}
