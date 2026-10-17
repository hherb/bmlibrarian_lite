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
/// `BMLIB_PARITY_REPORT=/path/report.json` to write the per-article report.
final class BmlibJATSParityTests: XCTestCase {

    private static let corpusPath = "doc/cross_platform/jats_corpus"

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
            authors: a.authors.map { "\($0.fullName)|\($0.affiliations.count)" },
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
        XCTAssertEqual(BmlibJATS.bmlibVersion, "0.2.0")
        let xml = """
            <article><front><article-meta><title-group><article-title>T</article-title>\
            </title-group></article-meta></front><body><sec><title>S</title><p>P</p></sec></body></article>
            """
        let article = try BmlibJATS.parse(data: Data(xml.utf8))
        XCTAssertEqual(article.title, "T")
        XCTAssertEqual(article.bodySections.first?.paragraphs, ["P"])
        XCTAssertThrowsError(try BmlibJATS.parse(data: Data("<article><body>".utf8)))
    }

    /// Acceptance criterion 2: the corpus through both parsers.
    func testCorpusThroughBothParsers() throws {
        let files = try Self.corpusFiles()
        XCTAssertEqual(files.count, 7, "the corpus has seven articles")
        var report: [[String: Any]] = []
        var swiftSeconds = 0.0, rustSeconds = 0.0
        let repetitions = 20

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: file)

            let swift = try JATSXMLParser(data: data).parseToArticle()
            let rust = try BmlibJATS.parse(data: data)

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
            let missing = Set(swiftReport.sectionPaths).subtracting(rustReport.sectionPaths)
            XCTAssertTrue(missing.isEmpty, "\(name): sections only Swift has: \(missing.sorted())")

            var swiftTime = 0.0, rustTime = 0.0
            for _ in 0..<repetitions {
                var start = Date()
                _ = try JATSXMLParser(data: data).parseToArticle()
                swiftTime += Date().timeIntervalSince(start)
                start = Date()
                _ = try BmlibJATS.parse(data: data)
                rustTime += Date().timeIntervalSince(start)
            }
            swiftSeconds += swiftTime / Double(repetitions)
            rustSeconds += rustTime / Double(repetitions)

            let line = String(
                format: "%@: swift %.2f ms, rust %.2f ms; paragraphs swift %d rust %d; "
                    + "sections swift %d rust %d; refs with citation swift %d rust %d",
                name, swiftTime / Double(repetitions) * 1000, rustTime / Double(repetitions) * 1000,
                swiftReport.paragraphCount, rustReport.paragraphCount,
                swiftReport.sectionPaths.count, rustReport.sectionPaths.count,
                swiftReport.referencesWithCitation, rustReport.referencesWithCitation
            )
            print("[bmlib-parity] \(line)")
            report.append([
                "article": name,
                "swiftMs": swiftTime / Double(repetitions) * 1000,
                "rustMs": rustTime / Double(repetitions) * 1000,
                "swift": try JSONSerialization.jsonObject(with: JSONEncoder().encode(swiftReport)),
                "rust": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rustReport)),
                "swiftParagraphs": Self.paragraphs(swift.bodySections),
                "rustParagraphs": Self.paragraphs(rust.bodySections),
            ])
        }
        print(String(format: "[bmlib-parity] corpus total: swift %.2f ms, rust %.2f ms",
                     swiftSeconds * 1000, rustSeconds * 1000))

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
