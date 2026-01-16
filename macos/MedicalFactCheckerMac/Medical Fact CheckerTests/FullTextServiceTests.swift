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
@testable import MedicalFactCheckerMac

// MARK: - FullTextSource Tests

struct FullTextSourceTests {
    @Test func displayNames() {
        #expect(FullTextSource.europePMC.displayName == "Europe PMC")
        #expect(FullTextSource.unpaywall.displayName == "Unpaywall")
        #expect(FullTextSource.doi.displayName == "Publisher")
        #expect(FullTextSource.cached.displayName == "Cached")
    }

    @Test func iconNames() {
        #expect(FullTextSource.europePMC.iconName == "building.columns")
        #expect(FullTextSource.unpaywall.iconName == "lock.open")
        #expect(FullTextSource.doi.iconName == "link")
        #expect(FullTextSource.cached.iconName == "arrow.down.circle")
    }

    @Test func canDisplayInApp() {
        #expect(FullTextSource.europePMC.canDisplayInApp == true)
        #expect(FullTextSource.unpaywall.canDisplayInApp == true)
        #expect(FullTextSource.doi.canDisplayInApp == false)
        #expect(FullTextSource.cached.canDisplayInApp == true)
    }

    @Test func rawValueRoundTrip() {
        for source in FullTextSource.allCases {
            let rawValue = source.rawValue
            let decoded = FullTextSource(rawValue: rawValue)
            #expect(decoded == source)
        }
    }
}

// MARK: - FullTextContentType Tests

struct FullTextContentTypeTests {
    @Test func markdownCanDisplayInApp() {
        let content = FullTextContentType.markdown("# Test")
        #expect(content.canDisplayInApp == true)
    }

    @Test func pdfURLCanDisplayInApp() {
        let url = URL(string: "https://example.com/test.pdf")!
        let content = FullTextContentType.pdfURL(url)
        #expect(content.canDisplayInApp == true)
    }

    @Test func webURLCannotDisplayInApp() {
        let url = URL(string: "https://example.com/article")!
        let content = FullTextContentType.webURL(url)
        #expect(content.canDisplayInApp == false)
    }

    @Test func markdownContentExtraction() {
        let markdown = "# Test Article\n\nContent here."
        let content = FullTextContentType.markdown(markdown)
        #expect(content.markdownContent == markdown)
        #expect(content.pdfURL == nil)
        #expect(content.webURL == nil)
    }

    @Test func pdfURLExtraction() {
        let url = URL(string: "https://example.com/test.pdf")!
        let content = FullTextContentType.pdfURL(url)
        #expect(content.pdfURL == url)
        #expect(content.markdownContent == nil)
        #expect(content.webURL == nil)
    }

    @Test func webURLExtraction() {
        let url = URL(string: "https://example.com/article")!
        let content = FullTextContentType.webURL(url)
        #expect(content.webURL == url)
        #expect(content.markdownContent == nil)
        #expect(content.pdfURL == nil)
    }
}

// MARK: - FullTextResult Tests

struct FullTextResultTests {
    @Test func europePMCFactoryMethod() {
        let markdown = "# Article"
        let result = FullTextResult.europePMC(markdown: markdown)

        #expect(result.source == .europePMC)
        #expect(result.canDisplayInApp == true)
        if case .markdown(let content) = result.content {
            #expect(content == markdown)
        } else {
            Issue.record("Expected markdown content")
        }
    }

    @Test func unpaywallFactoryMethod() {
        let url = URL(string: "https://example.com/pdf")!
        let result = FullTextResult.unpaywall(pdfURL: url)

        #expect(result.source == .unpaywall)
        #expect(result.canDisplayInApp == true)
        if case .pdfURL(let pdfURL) = result.content {
            #expect(pdfURL == url)
        } else {
            Issue.record("Expected PDF URL content")
        }
    }

    @Test func doiFactoryMethod() {
        let url = URL(string: "https://doi.org/10.1234/test")!
        let result = FullTextResult.doi(webURL: url)

        #expect(result.source == .doi)
        #expect(result.canDisplayInApp == false)
        if case .webURL(let webURL) = result.content {
            #expect(webURL == url)
        } else {
            Issue.record("Expected web URL content")
        }
    }

    @Test func cachedFactoryMethod() {
        let markdown = "# Cached Article"
        let result = FullTextResult.cached(content: .markdown(markdown))

        #expect(result.source == .cached)
        #expect(result.canDisplayInApp == true)
    }
}

// MARK: - RetryHelper Tests

struct RetryHelperTests {
    @Test func successfulOperationNoRetry() async throws {
        var attempts = 0
        let result = try await RetryHelper.retry(config: .quick) {
            attempts += 1
            return "success"
        }

        #expect(result == "success")
        #expect(attempts == 1)
    }

    @Test func retryOnTransientError() async throws {
        var attempts = 0
        let result = try await RetryHelper.retry(
            config: RetryConfiguration(
                maxAttempts: 3,
                initialDelay: 0.01,
                maxDelay: 0.1,
                backoffMultiplier: 2.0,
                jitterFactor: 0.0
            )
        ) {
            attempts += 1
            if attempts < 3 {
                throw URLError(.timedOut)
            }
            return "success"
        }

        #expect(result == "success")
        #expect(attempts == 3)
    }

    @Test func exhaustedAfterMaxAttempts() async {
        var attempts = 0

        do {
            _ = try await RetryHelper.retry(
                config: RetryConfiguration(
                    maxAttempts: 2,
                    initialDelay: 0.01,
                    maxDelay: 0.1,
                    backoffMultiplier: 2.0,
                    jitterFactor: 0.0
                )
            ) {
                attempts += 1
                throw URLError(.timedOut)
            }
            Issue.record("Expected RetryError.exhausted")
        } catch let error as RetryError {
            if case .exhausted(let count, _) = error {
                #expect(count == 2)
            } else {
                Issue.record("Expected exhausted error")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(attempts == 2)
    }

    @Test func noRetryWhenPredicateReturnsFalse() async {
        var attempts = 0

        do {
            _ = try await RetryHelper.retry(
                config: .quick,
                shouldRetry: { _ in false }
            ) {
                attempts += 1
                throw URLError(.timedOut)
            }
            Issue.record("Expected error to be thrown")
        } catch {
            // Expected
        }

        #expect(attempts == 1)
    }

    @Test func isTransientErrorDetection() {
        // Transient errors
        #expect(RetryHelper.isTransientError(URLError(.timedOut)) == true)
        #expect(RetryHelper.isTransientError(URLError(.networkConnectionLost)) == true)
        #expect(RetryHelper.isTransientError(URLError(.notConnectedToInternet)) == true)

        // Non-transient errors
        #expect(RetryHelper.isTransientError(URLError(.badURL)) == false)
        #expect(RetryHelper.isTransientError(URLError(.unsupportedURL)) == false)
    }
}

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

// MARK: - FullTextError Tests

struct FullTextErrorTests {
    @Test func errorDescriptions() {
        #expect(FullTextError.noIdentifiers.errorDescription?.contains("no DOI") == true)
        #expect(FullTextError.noFullTextAvailable.errorDescription?.contains("No full text") == true)
        #expect(FullTextError.pdfDownloadFailed("timeout").errorDescription?.contains("timeout") == true)
        #expect(FullTextError.xmlParseError("invalid").errorDescription?.contains("invalid") == true)
        #expect(FullTextError.cachingFailed("disk full").errorDescription?.contains("disk full") == true)
        #expect(FullTextError.invalidResponse("404").errorDescription?.contains("404") == true)
    }
}

// MARK: - RetryConfiguration Tests

struct RetryConfigurationTests {
    @Test func defaultConfigurations() {
        let network = RetryConfiguration.networkDefault
        #expect(network.maxAttempts == 3)
        #expect(network.initialDelay == 1.0)

        let pdf = RetryConfiguration.pdfDownload
        #expect(pdf.maxAttempts == 4)
        #expect(pdf.initialDelay == 2.0)

        let quick = RetryConfiguration.quick
        #expect(quick.maxAttempts == 2)
        #expect(quick.initialDelay == 0.5)
    }

    @Test func configurationBounds() {
        // maxAttempts should be at least 1
        let config1 = RetryConfiguration(
            maxAttempts: 0,
            initialDelay: 1.0,
            maxDelay: 10.0,
            backoffMultiplier: 2.0,
            jitterFactor: 0.1
        )
        #expect(config1.maxAttempts >= 1)

        // jitterFactor should be clamped to 0-1
        let config2 = RetryConfiguration(
            maxAttempts: 3,
            initialDelay: 1.0,
            maxDelay: 10.0,
            backoffMultiplier: 2.0,
            jitterFactor: 2.0  // Too high
        )
        #expect(config2.jitterFactor <= 1.0)

        // backoffMultiplier should be at least 1
        let config3 = RetryConfiguration(
            maxAttempts: 3,
            initialDelay: 1.0,
            maxDelay: 10.0,
            backoffMultiplier: 0.5,  // Too low
            jitterFactor: 0.1
        )
        #expect(config3.backoffMultiplier >= 1.0)
    }
}
