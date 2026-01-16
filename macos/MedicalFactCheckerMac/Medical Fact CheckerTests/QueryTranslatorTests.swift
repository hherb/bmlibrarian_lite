//
//  QueryTranslatorTests.swift
//  MedicalFactCheckerMacTests
//
//  Tests for QueryTranslator and QueryValidator.
//

import Testing
import Foundation
@testable import Medical_Fact_Checker

// MARK: - PubMed to Europe PMC: MeSH Terms

struct QueryTranslatorMeSHTests {
    @Test func meshTermTranslation() {
        let pubmed = #""Diabetes Mellitus"[MeSH]"#
        let expected = #"MeSH_TERM:"Diabetes Mellitus""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func meshTermTranslationLowercase() {
        let pubmed = #""Diabetes Mellitus"[mesh]"#
        let expected = #"MeSH_TERM:"Diabetes Mellitus""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func meshTermTranslationMixedCase() {
        let pubmed = #""Diabetes Mellitus"[Mesh]"#
        let expected = #"MeSH_TERM:"Diabetes Mellitus""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func reverseMeshTermTranslation() {
        let epmc = #"MeSH_TERM:"Diabetes Mellitus""#
        let expected = #""Diabetes Mellitus"[MeSH]"#
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }
}

// MARK: - PubMed to Europe PMC: Field Tags

struct QueryTranslatorFieldTagTests {
    @Test func titleAbstractTranslation() {
        let pubmed = "metformin[tiab]"
        let expected = "TITLE_ABS:metformin"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func quotedTitleAbstractTranslation() {
        let pubmed = #""insulin resistance"[tiab]"#
        let expected = #"TITLE_ABS:"insulin resistance""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func titleOnlyTranslation() {
        let pubmed = "diabetes[ti]"
        let expected = "TITLE:diabetes"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func abstractOnlyTranslation() {
        let pubmed = "treatment[ab]"
        let expected = "ABSTRACT:treatment"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func authorTranslation() {
        let pubmed = #""Smith J"[au]"#
        let expected = #"AUTH:"Smith J""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func journalTranslation() {
        let pubmed = #""Nature Medicine"[ta]"#
        let expected = #"JOURNAL:"Nature Medicine""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func reverseTitleAbstractTranslation() {
        let epmc = "TITLE_ABS:metformin"
        let expected = "metformin[tiab]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseQuotedTitleAbstractTranslation() {
        let epmc = #"TITLE_ABS:"insulin resistance""#
        let expected = #""insulin resistance"[tiab]"#
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseTitleOnlyTranslation() {
        let epmc = "TITLE:diabetes"
        let expected = "diabetes[ti]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseAbstractOnlyTranslation() {
        let epmc = "ABSTRACT:treatment"
        let expected = "treatment[ab]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseAuthorTranslation() {
        let epmc = #"AUTH:"Smith J""#
        let expected = #""Smith J"[au]"#
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }
}

// MARK: - PubMed to Europe PMC: Date Filters

struct QueryTranslatorDateFilterTests {
    @Test func singleYearTranslation() {
        let pubmed = "2023[dp]"
        let expected = "PUB_YEAR:2023"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func dateRangeTranslation() {
        let pubmed = "2020:2024[dp]"
        let expected = "PUB_YEAR:[2020 TO 2024]"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func dateRangeWithSpacesTranslation() {
        let pubmed = "2020 : 2024[dp]"
        let expected = "PUB_YEAR:[2020 TO 2024]"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func reverseSingleYearTranslation() {
        let epmc = "PUB_YEAR:2023"
        let expected = "2023[dp]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseDateRangeTranslation() {
        let epmc = "PUB_YEAR:[2020 TO 2024]"
        let expected = "2020:2024[dp]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }
}

// MARK: - PubMed to Europe PMC: Special Filters

struct QueryTranslatorSpecialFilterTests {
    @Test func hasAbstractTranslation() {
        let pubmed = "diabetes AND hasabstract"
        let expected = "diabetes AND HAS_ABSTRACT:y"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func freeFullTextTranslation() {
        let pubmed = "cancer AND free full text[sb]"
        let expected = "cancer AND OPEN_ACCESS:y"
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func englishLanguageTranslation() {
        let pubmed = "diabetes AND english[la]"
        let expected = #"diabetes AND LANG:"eng""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func systematicReviewTranslation() {
        let pubmed = #""Systematic Review"[pt]"#
        let expected = #"PUB_TYPE:"systematic-review""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func clinicalTrialTranslation() {
        let pubmed = #""Clinical Trial"[pt]"#
        let expected = #"PUB_TYPE:"clinical-trial""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func metaAnalysisTranslation() {
        let pubmed = #""Meta-Analysis"[pt]"#
        let expected = #"PUB_TYPE:"meta-analysis""#
        #expect(QueryTranslator.pubmedToEuropePMC(pubmed) == expected)
    }

    @Test func reverseHasAbstractTranslation() {
        let epmc = "diabetes AND HAS_ABSTRACT:y"
        let expected = "diabetes AND hasabstract"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func reverseOpenAccessTranslation() {
        let epmc = "cancer AND OPEN_ACCESS:y"
        let expected = "cancer AND free full text[sb]"
        #expect(QueryTranslator.europePMCToPubMed(epmc) == expected)
    }

    @Test func preprintFilterRemoval() {
        let epmc = "diabetes AND NOT SRC:PPR"
        let result = QueryTranslator.europePMCToPubMed(epmc)
        #expect(!result.contains("SRC:PPR"))
        #expect(result.contains("diabetes"))
    }

    @Test func preprintSourceRemoval() {
        let epmc = "diabetes AND SRC:PPR"
        let result = QueryTranslator.europePMCToPubMed(epmc)
        #expect(!result.contains("SRC:PPR"))
        #expect(result.contains("diabetes"))
    }
}

// MARK: - Complex Query Tests

struct QueryTranslatorComplexQueryTests {
    @Test func complexQueryTranslation() {
        let pubmed = #"("Amlodipine"[MeSH] OR amlodipine[tiab]) AND ("Vascular Stiffness"[MeSH] OR "arterial stiffness"[tiab]) AND hasabstract"#
        let result = QueryTranslator.pubmedToEuropePMC(pubmed)

        #expect(result.contains("MeSH_TERM:\"Amlodipine\""))
        #expect(result.contains("TITLE_ABS:amlodipine"))
        #expect(result.contains("MeSH_TERM:\"Vascular Stiffness\""))
        #expect(result.contains("TITLE_ABS:\"arterial stiffness\""))
        #expect(result.contains("HAS_ABSTRACT:y"))
    }

    @Test func complexQueryWithDateRange() {
        let pubmed = #""Diabetes Mellitus"[MeSH] AND metformin[tiab] AND 2020:2024[dp]"#
        let result = QueryTranslator.pubmedToEuropePMC(pubmed)

        #expect(result.contains("MeSH_TERM:\"Diabetes Mellitus\""))
        #expect(result.contains("TITLE_ABS:metformin"))
        #expect(result.contains("PUB_YEAR:[2020 TO 2024]"))
    }
}

// MARK: - Round-Trip Tests

struct QueryTranslatorRoundTripTests {
    @Test func roundTripMeSH() {
        let original = #""Diabetes Mellitus"[MeSH]"#
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        #expect(roundTrip == original)
    }

    @Test func roundTripTitleAbstract() {
        let original = "metformin[tiab]"
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        #expect(roundTrip == original)
    }

    @Test func roundTripQuotedTitleAbstract() {
        let original = #""insulin resistance"[tiab]"#
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        #expect(roundTrip == original)
    }

    @Test func roundTripDateRange() {
        let original = "2020:2024[dp]"
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        #expect(roundTrip == original)
    }

    @Test func roundTripSingleYear() {
        let original = "2023[dp]"
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        #expect(roundTrip == original)
    }
}

// MARK: - Edge Cases

struct QueryTranslatorEdgeCaseTests {
    @Test func plainTextPassthrough() {
        let plainText = "diabetes treatment outcomes"
        #expect(QueryTranslator.pubmedToEuropePMC(plainText) == plainText)
        #expect(QueryTranslator.europePMCToPubMed(plainText) == plainText)
    }

    @Test func emptyQueryHandling() {
        #expect(QueryTranslator.pubmedToEuropePMC("") == "")
        #expect(QueryTranslator.europePMCToPubMed("") == "")
    }

    @Test func whitespaceCleanup() {
        let messy = "diabetes  AND   metformin"
        let result = QueryTranslator.pubmedToEuropePMC(messy)
        #expect(!result.contains("  "))
    }

    @Test func trailingBooleanRemoval() {
        let trailing = "diabetes AND metformin AND"
        let result = QueryTranslator.pubmedToEuropePMC(trailing)
        #expect(!result.hasSuffix("AND"))
    }

    @Test func leadingBooleanRemoval() {
        let leading = "AND diabetes AND metformin"
        let result = QueryTranslator.pubmedToEuropePMC(leading)
        #expect(!result.hasPrefix("AND"))
    }

    @Test func emptyParenthesesRemoval() {
        let withEmpty = "diabetes () AND metformin"
        let result = QueryTranslator.pubmedToEuropePMC(withEmpty)
        #expect(!result.contains("()"))
    }
}

// MARK: - Syntax Detection Tests

struct QueryTranslatorSyntaxDetectionTests {
    @Test func isPubMedSyntaxWithMeSH() {
        #expect(QueryTranslator.isPubMedSyntax(#""Term"[MeSH]"#))
    }

    @Test func isPubMedSyntaxWithTiab() {
        #expect(QueryTranslator.isPubMedSyntax("term[tiab]"))
    }

    @Test func isPubMedSyntaxWithDp() {
        #expect(QueryTranslator.isPubMedSyntax("2020[dp]"))
    }

    @Test func isPubMedSyntaxWithHasAbstract() {
        #expect(QueryTranslator.isPubMedSyntax("diabetes AND hasabstract"))
    }

    @Test func isPubMedSyntaxPlainText() {
        #expect(!QueryTranslator.isPubMedSyntax("plain text query"))
    }

    @Test func isPubMedSyntaxEuropePMC() {
        #expect(!QueryTranslator.isPubMedSyntax("MeSH_TERM:diabetes"))
    }

    @Test func isEuropePMCSyntaxWithMeSHTerm() {
        #expect(QueryTranslator.isEuropePMCSyntax("MeSH_TERM:\"Term\""))
    }

    @Test func isEuropePMCSyntaxWithTitleAbs() {
        #expect(QueryTranslator.isEuropePMCSyntax("TITLE_ABS:term"))
    }

    @Test func isEuropePMCSyntaxWithPubYear() {
        #expect(QueryTranslator.isEuropePMCSyntax("PUB_YEAR:2020"))
    }

    @Test func isEuropePMCSyntaxWithHasAbstract() {
        #expect(QueryTranslator.isEuropePMCSyntax("HAS_ABSTRACT:y"))
    }

    @Test func isEuropePMCSyntaxPlainText() {
        #expect(!QueryTranslator.isEuropePMCSyntax("plain text query"))
    }

    @Test func isEuropePMCSyntaxPubMed() {
        #expect(!QueryTranslator.isEuropePMCSyntax("term[tiab]"))
    }
}

// MARK: - Query Validator Tests

struct QueryValidatorEuropePMCTests {
    @Test func validEuropePMCQuery() {
        let query = #"MeSH_TERM:"Diabetes" AND TITLE_ABS:metformin"#
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(result.isValid)
        #expect(result.warnings.isEmpty)
        #expect(!result.isPlainText)
    }

    @Test func plainTextQuery() {
        let query = "diabetes treatment outcomes"
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(result.isPlainText)
    }

    @Test func unbalancedParenthesesDetection() {
        let query = "(diabetes AND metformin"
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.isValid)
        #expect(result.warnings.contains { $0.contains("parentheses") })
    }

    @Test func balancedParentheses() {
        let query = "(diabetes AND metformin)"
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.warnings.contains { $0.contains("parentheses") })
    }

    @Test func unbalancedQuotesDetection() {
        let query = #""diabetes AND metformin"#
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.isValid)
        #expect(result.warnings.contains { $0.contains("quotes") })
    }

    @Test func balancedQuotes() {
        let query = #""diabetes" AND "metformin""#
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.warnings.contains { $0.contains("quotes") })
    }

    @Test func untranslatedPubMedTagDetection() {
        let query = "diabetes[tiab] AND MeSH_TERM:\"Cancer\""
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.isValid)
        #expect(result.untranslatedComponents.contains("[tiab]"))
    }
}

struct QueryValidatorPubMedTests {
    @Test func validPubMedQuery() {
        let query = #""Diabetes"[MeSH] AND metformin[tiab]"#
        let result = QueryValidator.validatePubMedQuery(query)
        #expect(result.isValid)
        #expect(result.warnings.isEmpty)
        #expect(!result.isPlainText)
    }

    @Test func plainTextQuery() {
        let query = "diabetes treatment outcomes"
        let result = QueryValidator.validatePubMedQuery(query)
        #expect(result.isPlainText)
    }

    @Test func untranslatedEuropePMCPrefixDetection() {
        let query = "TITLE_ABS:diabetes AND cancer[MeSH]"
        let result = QueryValidator.validatePubMedQuery(query)
        #expect(!result.isValid)
        #expect(result.untranslatedComponents.contains("TITLE_ABS:"))
    }

    @Test func multipleIssuesDetection() {
        let query = "(diabetes[tiab] AND \"metformin"
        let result = QueryValidator.validateEuropePMCQuery(query)
        #expect(!result.isValid)
        #expect(result.warnings.count >= 2)
    }
}
