//
//  DocumentFullTextTests.swift
//  Medical Fact CheckerTests
//
//  Unit tests for Document model full-text extensions.
//

import Testing
import Foundation
@testable import Medical_Fact_Checker

struct DocumentFullTextTests {
    // MARK: - Test Helpers

    /// Create a test document with minimal required fields.
    private func makeDocument(
        pmid: String = "12345678",
        title: String = "Test Article",
        abstract: String = "Test abstract content."
    ) -> Document {
        Document(
            pmid: pmid,
            title: title,
            abstract: abstract,
            authors: ["Smith J", "Jones K"],
            batchNumber: 1,
            resultPosition: 0
        )
    }

    // MARK: - hasFullText Tests

    @Test func hasFullTextWithMarkdownContent() {
        let doc = makeDocument()
        doc.fullTextContent = "# Full article content"

        #expect(doc.hasFullText == true)
    }

    @Test func hasFullTextWithPDFPath() {
        let doc = makeDocument()
        doc.fullTextPDFPath = "/path/to/article.pdf"

        #expect(doc.hasFullText == true)
    }

    @Test func hasFullTextWithBoth() {
        let doc = makeDocument()
        doc.fullTextContent = "# Content"
        doc.fullTextPDFPath = "/path/to/article.pdf"

        #expect(doc.hasFullText == true)
    }

    @Test func hasFullTextWhenEmpty() {
        let doc = makeDocument()

        #expect(doc.hasFullText == false)
    }

    // MARK: - fullTextAttempted Tests

    @Test func fullTextAttemptedWhenFetched() {
        let doc = makeDocument()
        doc.fullTextFetchedAt = Date()

        #expect(doc.fullTextAttempted == true)
    }

    @Test func fullTextAttemptedWhenUnavailable() {
        let doc = makeDocument()
        doc.fullTextUnavailable = true

        #expect(doc.fullTextAttempted == true)
    }

    @Test func fullTextAttemptedWhenNeverTried() {
        let doc = makeDocument()

        #expect(doc.fullTextAttempted == false)
    }

    // MARK: - fullTextSourceDisplay Tests

    @Test func fullTextSourceDisplayEuropePMC() {
        let doc = makeDocument()
        doc.fullTextSource = "europepmc"

        #expect(doc.fullTextSourceDisplay == "Europe PMC")
    }

    @Test func fullTextSourceDisplayUnpaywall() {
        let doc = makeDocument()
        doc.fullTextSource = "unpaywall"

        #expect(doc.fullTextSourceDisplay == "Unpaywall")
    }

    @Test func fullTextSourceDisplayDOI() {
        let doc = makeDocument()
        doc.fullTextSource = "doi"

        #expect(doc.fullTextSourceDisplay == "Publisher")
    }

    @Test func fullTextSourceDisplayCached() {
        let doc = makeDocument()
        doc.fullTextSource = "cached"

        #expect(doc.fullTextSourceDisplay == "Cached")
    }

    @Test func fullTextSourceDisplayUnknown() {
        let doc = makeDocument()
        doc.fullTextSource = "custom"

        #expect(doc.fullTextSourceDisplay == "Custom")
    }

    @Test func fullTextSourceDisplayNil() {
        let doc = makeDocument()

        #expect(doc.fullTextSourceDisplay == nil)
    }

    // MARK: - fullTextSourceEnum Tests

    @Test func fullTextSourceEnumMapping() {
        let doc = makeDocument()

        doc.fullTextSource = "europepmc"
        #expect(doc.fullTextSourceEnum == .europePMC)

        doc.fullTextSource = "unpaywall"
        #expect(doc.fullTextSourceEnum == .unpaywall)

        doc.fullTextSource = "doi"
        #expect(doc.fullTextSourceEnum == .doi)

        doc.fullTextSource = "cached"
        #expect(doc.fullTextSourceEnum == .cached)
    }

    @Test func fullTextSourceEnumUnknown() {
        let doc = makeDocument()
        doc.fullTextSource = "unknown"

        #expect(doc.fullTextSourceEnum == nil)
    }

    @Test func fullTextSourceEnumNil() {
        let doc = makeDocument()

        #expect(doc.fullTextSourceEnum == nil)
    }

    // MARK: - fullTextSourceIcon Tests

    @Test func fullTextSourceIconValues() {
        let doc = makeDocument()

        doc.fullTextSource = "europepmc"
        #expect(doc.fullTextSourceIcon == "building.columns")

        doc.fullTextSource = "unpaywall"
        #expect(doc.fullTextSourceIcon == "lock.open")

        doc.fullTextSource = "doi"
        #expect(doc.fullTextSourceIcon == "link")

        doc.fullTextSource = "cached"
        #expect(doc.fullTextSourceIcon == "arrow.down.circle")
    }

    @Test func fullTextSourceIconNil() {
        let doc = makeDocument()

        #expect(doc.fullTextSourceIcon == nil)
    }

    // MARK: - applyFullTextResult Tests

    @Test func applyMarkdownResult() {
        let doc = makeDocument()
        let result = FullTextResult.europePMC(markdown: "# Article Content")

        doc.applyFullTextResult(result)

        #expect(doc.fullTextSource == "europepmc")
        #expect(doc.fullTextContent == "# Article Content")
        #expect(doc.fullTextPDFPath == nil)
        #expect(doc.fullTextFetchedAt != nil)
        #expect(doc.fullTextUnavailable == false)
    }

    @Test func applyPDFResult() {
        let doc = makeDocument()
        let url = URL(string: "https://example.com/article.pdf")!
        let result = FullTextResult.unpaywall(pdfURL: url)

        doc.applyFullTextResult(result)

        #expect(doc.fullTextSource == "unpaywall")
        #expect(doc.fullTextContent == nil)
        // PDF path is set separately after download
        #expect(doc.fullTextFetchedAt != nil)
        #expect(doc.fullTextUnavailable == false)
    }

    @Test func applyWebURLResult() {
        let doc = makeDocument()
        let url = URL(string: "https://doi.org/10.1234/test")!
        let result = FullTextResult.doi(webURL: url)

        doc.applyFullTextResult(result)

        #expect(doc.fullTextSource == "doi")
        #expect(doc.fullTextContent == nil)
        #expect(doc.fullTextPDFPath == nil)
        #expect(doc.fullTextFetchedAt != nil)
        #expect(doc.fullTextUnavailable == false)
    }

    // MARK: - markFullTextUnavailable Tests

    @Test func markFullTextUnavailable() {
        let doc = makeDocument()
        // Pre-populate some values
        doc.fullTextContent = "Some content"
        doc.fullTextPDFPath = "/some/path.pdf"
        doc.fullTextSource = "europepmc"
        doc.fullTextFetchedAt = Date()

        doc.markFullTextUnavailable()

        #expect(doc.fullTextUnavailable == true)
        #expect(doc.fullTextFetchedAt == nil)
        #expect(doc.fullTextContent == nil)
        #expect(doc.fullTextPDFPath == nil)
        #expect(doc.fullTextSource == nil)
    }

    // MARK: - clearFullTextCache Tests

    @Test func clearFullTextCache() {
        let doc = makeDocument()
        // Pre-populate
        doc.fullTextContent = "Content"
        doc.fullTextPDFPath = "/path.pdf"
        doc.fullTextSource = "europepmc"
        doc.fullTextFetchedAt = Date()
        doc.fullTextUnavailable = true

        doc.clearFullTextCache()

        #expect(doc.fullTextContent == nil)
        #expect(doc.fullTextPDFPath == nil)
        #expect(doc.fullTextSource == nil)
        #expect(doc.fullTextFetchedAt == nil)
        #expect(doc.fullTextUnavailable == false)
    }

    // MARK: - Initial State Tests

    @Test func initialStateHasNoFullText() {
        let doc = makeDocument()

        #expect(doc.fullTextContent == nil)
        #expect(doc.fullTextPDFPath == nil)
        #expect(doc.fullTextSource == nil)
        #expect(doc.fullTextFetchedAt == nil)
        #expect(doc.fullTextUnavailable == false)
        #expect(doc.hasFullText == false)
        #expect(doc.fullTextAttempted == false)
    }
}
