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
@testable import MedicalFactChecker

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

// Note: RetryHelper, FullTextError, and RetryConfiguration tests have been removed
// as these types are now part of the BioMedLit package and should be tested there.
// JATSXMLParser tests have been moved to JATSXMLParserTests.swift
