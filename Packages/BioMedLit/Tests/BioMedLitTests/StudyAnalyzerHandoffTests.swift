// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import BioMedLit

/// The `.studyanalyzer` file this app writes is the one StudyAnalyzer reads:
/// each fixture StudyAnalyzer accepts (copied from its repository into
/// `Fixtures/Handoff/`) decodes to the same JSON object the encoder writes
/// from the same fields.
final class StudyAnalyzerHandoffTests: XCTestCase {
    /// Fixtures sit beside this file, located from `#filePath` as in
    /// `PDFTextExtractorTests`.
    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Handoff/\(name)"))
    }

    /// The JSON object `data` holds, for comparing two files by content.
    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// One fixture case: what StudyAnalyzer expects to read from its file.
    private struct Case: Decodable {
        let file: String
        let expect: String
        let pmid: String?
        let doi: String?
        let pmcid: String?
        let kind: String?
        let title: String?
        let file_name: String?
        let source: String?
        let bytes: String?
    }

    func testEachAcceptedFixtureIsWhatTheEncoderWrites() throws {
        struct Cases: Decodable { let cases: [Case] }
        let accepted = try JSONDecoder().decode(Cases.self, from: Self.fixture("cases.json"))
            .cases.filter { $0.expect == "ok" }
        XCTAssertEqual(accepted.count, 3)
        for c in accepted {
            var fullText: StudyAnalyzerHandoff.FullText?
            if let kind = c.kind {
                let format = try XCTUnwrap(StudyAnalyzerHandoff.Format(rawValue: kind), c.file)
                fullText = .init(format: format, data: try Self.fixture(try XCTUnwrap(c.bytes)),
                                 fileName: c.file_name, source: c.source)
            }
            let handoff = StudyAnalyzerHandoff(pmid: c.pmid, doi: c.doi, pmcid: c.pmcid,
                                               title: c.title, fullText: fullText)
            XCTAssertEqual(try object(handoff.encoded()), try object(Self.fixture(c.file)), c.file)
        }
    }

    func testBlankFieldsAreLeftOut() throws {
        let handoff = StudyAnalyzerHandoff(pmid: "1", doi: "", pmcid: nil, title: "  ", fullText: nil)
        let json = try object(handoff.encoded())
        XCTAssertNil(json["title"])
        XCTAssertNil(json["full_text"])
        XCTAssertEqual(json["identifiers"] as? NSDictionary, ["pmid": "1"] as NSDictionary)
        XCTAssertEqual(json["sender"] as? String, BioMedLitConstants.handoffSender)
    }

    func testHasContent() {
        XCTAssertFalse(StudyAnalyzerHandoff(pmid: nil, doi: " ", pmcid: nil, title: "T", fullText: nil).hasContent)
        XCTAssertTrue(StudyAnalyzerHandoff(pmid: "1", doi: nil, pmcid: nil, title: nil, fullText: nil).hasContent)
        let text = StudyAnalyzerHandoff.FullText(format: .text, data: Data("x".utf8))
        XCTAssertTrue(StudyAnalyzerHandoff(pmid: nil, doi: nil, pmcid: nil, title: nil, fullText: text).hasContent)
    }

    /// A field StudyAnalyzer would refuse the whole file over is left out:
    /// the title, file name and source are labels, never the paper's text.
    func testFieldsStudyAnalyzerWouldRefuseAreLeftOut() {
        let max = BioMedLitConstants.handoffMaxLabelChars
        let longTitle = String(repeating: "t", count: BioMedLitConstants.handoffMaxTitleChars + 1)
        XCTAssertNil(StudyAnalyzerHandoff(pmid: "1", doi: nil, pmcid: nil, title: longTitle, fullText: nil).title)
        let rtlTitle = "\u{202B}عنوان"  // a title may carry bidi characters
        XCTAssertEqual(StudyAnalyzerHandoff(pmid: "1", doi: nil, pmcid: nil, title: rtlTitle, fullText: nil).title,
                       rtlTitle)
        for refused in ["a/b.pdf", "a\\b.pdf", "a\u{0007}.pdf", "a\u{202E}fdp.exe", "a\u{200B}.pdf",
                        "a\u{FEFF}.pdf", String(repeating: "n", count: max + 1)] {
            let text = StudyAnalyzerHandoff.FullText(format: .pdf, data: Data(), fileName: refused, source: refused)
            XCTAssertNil(text.fileName, refused)
            if !refused.contains("/"), !refused.contains("\\") { XCTAssertNil(text.source, refused) }
        }
        let kept = StudyAnalyzerHandoff.FullText(format: .pdf, data: Data(),
                                                 fileName: String(repeating: "n", count: max), source: "Europe PMC")
        XCTAssertNotNil(kept.fileName)
        XCTAssertEqual(kept.source, "Europe PMC")
    }

    /// Slashes are written unescaped: `\/` would add about 2 MB to a 100 MiB
    /// PDF's base64, past StudyAnalyzer's whole-file limit.
    func testSlashesAreNotEscaped() throws {
        let bytes = Data([0xFF, 0xFF, 0xFF])  // base64 "////"
        let handoff = StudyAnalyzerHandoff(pmid: nil, doi: "10.1000/xyz", pmcid: nil, title: nil,
                                           fullText: .init(format: .pdf, data: bytes))
        let json = try XCTUnwrap(String(data: handoff.encoded(), encoding: .utf8))
        XCTAssertFalse(json.contains("\\/"), json)
        XCTAssertTrue(json.contains("10.1000/xyz"))
    }

    func testTheDataIsOneUnbrokenBase64String() throws {
        let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
        let handoff = StudyAnalyzerHandoff(pmid: "1", doi: nil, pmcid: nil, title: nil,
                                           fullText: .init(format: .pdf, data: bytes))
        let fullText = try XCTUnwrap(try object(handoff.encoded())["full_text"] as? NSDictionary)
        let data = try XCTUnwrap(fullText["data"] as? String)
        XCTAssertFalse(data.contains("\n") || data.contains("\r"))
        XCTAssertEqual(data, bytes.base64EncodedString())
    }
}
