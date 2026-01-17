// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

import Testing
import Foundation
import BioMedLit

// MARK: - JATSXMLParser Tests

struct JATSXMLParserTests {
    @Test func parseSimpleArticle() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Test Article Title</article-title>
                    <contrib-group>
                        <contrib contrib-type="author">
                            <name>
                                <surname>Smith</surname>
                                <given-names>John</given-names>
                            </name>
                        </contrib>
                    </contrib-group>
                </article-meta>
            </front>
            <body>
                <sec>
                    <title>Introduction</title>
                    <p>This is the introduction paragraph.</p>
                </sec>
            </body>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("# Test Article Title"))
        #expect(markdown.contains("John Smith"))
        #expect(markdown.contains("## Introduction"))
        #expect(markdown.contains("This is the introduction paragraph."))
    }

    @Test func parseAbstractWithSections() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Study Title</article-title>
                    <abstract>
                        <title>Background</title>
                        <p>Background content here.</p>
                        <title>Methods</title>
                        <p>Methods content here.</p>
                    </abstract>
                </article-meta>
            </front>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("## Abstract"))
        #expect(markdown.contains("Background"))
        #expect(markdown.contains("Background content here."))
    }

    @Test func parseMultipleAuthors() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Multi-Author Study</article-title>
                    <contrib-group>
                        <contrib contrib-type="author">
                            <name><surname>First</surname><given-names>A</given-names></name>
                        </contrib>
                        <contrib contrib-type="author">
                            <name><surname>Second</surname><given-names>B</given-names></name>
                        </contrib>
                        <contrib contrib-type="author">
                            <name><surname>Third</surname><given-names>C</given-names></name>
                        </contrib>
                        <contrib contrib-type="author">
                            <name><surname>Fourth</surname><given-names>D</given-names></name>
                        </contrib>
                    </contrib-group>
                </article-meta>
            </front>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        // Should show first 3 authors + "et al."
        #expect(markdown.contains("A First"))
        #expect(markdown.contains("B Second"))
        #expect(markdown.contains("C Third"))
        #expect(markdown.contains("et al."))
    }

    @Test func parseNestedSections() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Nested Sections</article-title>
                </article-meta>
            </front>
            <body>
                <sec>
                    <title>Methods</title>
                    <p>Methods overview.</p>
                    <sec>
                        <title>Study Design</title>
                        <p>Study design details.</p>
                    </sec>
                    <sec>
                        <title>Participants</title>
                        <p>Participant details.</p>
                    </sec>
                </sec>
            </body>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("## Methods"))
        #expect(markdown.contains("### Study Design"))
        #expect(markdown.contains("### Participants"))
    }

    @Test func parseJournalMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <journal-meta>
                    <journal-title>Journal of Testing</journal-title>
                </journal-meta>
                <article-meta>
                    <article-title>Test Article</article-title>
                    <volume>10</volume>
                    <issue>2</issue>
                    <fpage>100</fpage>
                    <lpage>110</lpage>
                    <pub-date>
                        <year>2024</year>
                    </pub-date>
                </article-meta>
            </front>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("Journal of Testing"))
        #expect(markdown.contains("10"))
        #expect(markdown.contains("(2)"))
        #expect(markdown.contains("100-110"))
        #expect(markdown.contains("2024"))
    }

    @Test func parseFigures() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Article with Figures</article-title>
                </article-meta>
            </front>
            <body>
                <sec>
                    <title>Results</title>
                    <fig id="fig1">
                        <label>Figure 1</label>
                        <caption>
                            <p>This is the figure caption.</p>
                        </caption>
                    </fig>
                </sec>
            </body>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("## Figures"))
        #expect(markdown.contains("Figure 1"))
        #expect(markdown.contains("This is the figure caption."))
    }

    @Test func parseTables() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Article with Tables</article-title>
                </article-meta>
            </front>
            <body>
                <sec>
                    <title>Results</title>
                    <table-wrap id="table1">
                        <label>Table 1</label>
                        <caption>
                            <p>Summary of results.</p>
                        </caption>
                    </table-wrap>
                </sec>
            </body>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("## Tables"))
        #expect(markdown.contains("Table 1"))
        #expect(markdown.contains("Summary of results."))
    }

    @Test func parseReferences() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Article with References</article-title>
                </article-meta>
            </front>
            <back>
                <ref-list>
                    <ref id="ref1">
                        <label>1</label>
                        <mixed-citation>Smith J. Important Study. Journal. 2023.</mixed-citation>
                    </ref>
                    <ref id="ref2">
                        <label>2</label>
                        <mixed-citation>Jones K. Another Study. Journal. 2024.</mixed-citation>
                    </ref>
                </ref-list>
            </back>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        #expect(markdown.contains("## References"))
        #expect(markdown.contains("1. Smith J. Important Study."))
        #expect(markdown.contains("2. Jones K. Another Study."))
    }

    @Test func parseBackMatterSections() throws {
        // Test that back matter sections (like Data availability, Ethics statement) are parsed
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
            <front>
                <article-meta>
                    <article-title>Article with Back Matter</article-title>
                </article-meta>
            </front>
            <body>
                <sec>
                    <title>Results</title>
                    <p>Main results here.</p>
                </sec>
            </body>
            <back>
                <sec sec-type="data-availability">
                    <title>Data availability statement</title>
                    <p>The datasets are available at FigShare repository.</p>
                </sec>
                <sec sec-type="ethics-statement">
                    <title>Ethics statement</title>
                    <p>This study was approved by the Ethics Committee.</p>
                </sec>
                <sec sec-type="author-contributions">
                    <title>Author contributions</title>
                    <p>JC: Investigation, Writing. MT: Supervision.</p>
                </sec>
            </back>
        </article>
        """

        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)
        let markdown = try parser.parseToMarkdown()

        // Check body section
        #expect(markdown.contains("## Results"))
        #expect(markdown.contains("Main results here."))

        // Check back matter sections are properly parsed
        #expect(markdown.contains("Data availability statement"))
        #expect(markdown.contains("The datasets are available at FigShare repository."))
        #expect(markdown.contains("Ethics statement"))
        #expect(markdown.contains("This study was approved by the Ethics Committee."))
        #expect(markdown.contains("Author contributions"))
        #expect(markdown.contains("JC: Investigation, Writing. MT: Supervision."))
    }

    @Test func emptyXMLThrowsError() {
        let xml = ""
        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)

        do {
            _ = try parser.parseToMarkdown()
            Issue.record("Expected JATSParseError")
        } catch {
            // Expected
        }
    }

    @Test func malformedXMLThrowsError() {
        let xml = "<article><unclosed>"
        let parser = JATSXMLParser(data: xml.data(using: .utf8)!)

        do {
            _ = try parser.parseToMarkdown()
            Issue.record("Expected JATSParseError")
        } catch {
            // Expected
        }
    }
}
