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

import XCTest
@testable import BioMedLit

/// Unit tests for DataAvailabilityAnalyzer pure functions.
final class DataAvailabilityAnalyzerTests: XCTestCase {

    // MARK: - Main Analysis Tests

    /// Test analyzing nil statement returns notStated.
    func testAnalyzeNilStatement() {
        let result = DataAvailabilityAnalyzer.analyze(statement: nil)
        XCTAssertEqual(result.disclosureLevel, .notStated)
    }

    /// Test analyzing empty statement returns notStated.
    func testAnalyzeEmptyStatement() {
        let result = DataAvailabilityAnalyzer.analyze(statement: "")
        XCTAssertEqual(result.disclosureLevel, .notStated)
    }

    /// Test analyzing Zenodo repository statement.
    func testAnalyzeZenodoRepository() {
        let statement = "Data available at https://zenodo.org/record/12345"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Zenodo")
        XCTAssertNotNil(result.repositoryURL)
    }

    /// Test analyzing Figshare repository statement.
    func testAnalyzeFigshareRepository() {
        let statement = "All data is available on Figshare."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Figshare")
    }

    /// Test analyzing Dryad repository statement.
    func testAnalyzeDryadRepository() {
        let statement = "Dataset deposited in Dryad Digital Repository."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Dryad")
    }

    /// Test analyzing GEO repository statement.
    func testAnalyzeGEORepository() {
        let statement = "Data deposited in Gene Expression Omnibus under accession GSE12345"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Gene Expression Omnibus")
    }

    /// Test analyzing GitHub repository statement.
    func testAnalyzeGitHubRepository() {
        let statement = "Code and data available at https://github.com/user/repo"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "GitHub")
        XCTAssertNotNil(result.repositoryURL)
    }

    /// Test analyzing OSF repository statement.
    func testAnalyzeOSFRepository() {
        let statement = "All materials available on OSF at osf.io/abc123"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Open Science Framework")
    }

    /// Test analyzing GenBank repository statement.
    func testAnalyzeGenBankRepository() {
        let statement = "Sequences deposited in GenBank."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "GenBank")
    }

    /// Test analyzing SRA repository statement.
    func testAnalyzeSRARepository() {
        let statement = "Raw sequencing data deposited in SRA."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .fullOpen)
        XCTAssertEqual(result.repositoryName, "Sequence Read Archive")
    }

    /// Test analyzing available on request statement.
    ///
    /// On-request access classifies as `.restricted` to match the Python
    /// reference (which never emits `.availableOnRequest` from this classifier).
    func testAnalyzeAvailableOnRequest() {
        let statement = "Data available upon reasonable request from the corresponding author"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertFalse(result.restrictions.isEmpty)
    }

    /// Test analyzing available from author statement.
    func testAnalyzeAvailableFromAuthor() {
        let statement = "Data available from the corresponding author on request."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .restricted)
    }

    /// Test analyzing proprietary data statement.
    func testAnalyzeProprietaryData() {
        let statement = "Data is proprietary and cannot be shared"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    /// Test analyzing not publicly available statement.
    func testAnalyzeNotPubliclyAvailable() {
        let statement = "Data is not publicly available due to privacy restrictions"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    /// Test analyzing cannot be shared statement.
    func testAnalyzeCannotBeShared() {
        let statement = "The data underlying this study cannot be shared publicly."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    /// Test analyzing IRB restriction statement.
    func testAnalyzeIRBRestriction() {
        let statement = "Data available from authors pending IRB approval"
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertTrue(result.restrictions.contains { $0.contains("IRB") })
    }

    /// Test analyzing data sharing agreement requirement.
    func testAnalyzeDataSharingAgreement() {
        let statement = "Data available subject to a data sharing agreement."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertTrue(result.restrictions.contains { $0.contains("data sharing agreement") })
    }

    /// Test analyzing ethics committee requirement.
    func testAnalyzeEthicsCommittee() {
        let statement = "Data access requires ethics committee approval."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertTrue(result.restrictions.contains { $0.contains("ethics") })
    }

    /// Test that a sharing statement amounting to a refusal is not available.
    ///
    /// "Will not be released to others" reads like a policy but is effectively
    /// a refusal, so it escalates to `.notAvailable` (Python parity).
    func testAnalyzeEffectivelyUnavailableRefusal() {
        let statement = "Individual patient data will not be released to others."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
        XCTAssertFalse(result.restrictions.isEmpty)
    }

    /// Test that sponsor confidentiality escalates to not available.
    func testAnalyzeSponsorConfidentiality() {
        let statement = "Confidentiality agreements with sponsors prevent data disclosure."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }

    /// Test that data locked to a named collaboration is not available.
    ///
    /// Also pins the restriction ordering for a `.notAvailable` result:
    /// effectively-unavailable labels come first (in their pattern order),
    /// followed by restricted-pattern labels, mirroring the Python reference.
    func testAnalyzeNamedCollaborationLock() {
        let statement =
            "Data are provided to the CORE consortium on the understanding that they are not shared."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .notAvailable)
        XCTAssertEqual(
            result.restrictions,
            [
                "Data restricted to named collaboration",
                "Data provided under restrictive understanding",
            ]
        )
    }

    /// Test analyzing ambiguous statement.
    func testAnalyzeAmbiguousStatement() {
        let statement = "The study data is maintained by the research team."
        let result = DataAvailabilityAnalyzer.analyze(statement: statement)

        XCTAssertEqual(result.disclosureLevel, .unknown)
    }

    // MARK: - URL Extraction Tests

    /// Test extracting HTTPS URL.
    func testExtractURLHttps() {
        let text = "Available at https://github.com/user/repo"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://github.com/user/repo")
    }

    /// Test extracting HTTP URL.
    func testExtractURLHttp() {
        let text = "Available at http://example.com/data"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://example.com/data")
    }

    /// Test extracting URL with path components.
    func testExtractURLWithPath() {
        let text = "Data at https://zenodo.org/record/12345/files/data.zip"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("zenodo.org"))
    }

    /// Test no URL in text.
    func testExtractURLNoURL() {
        let text = "Data available upon request"
        let url = DataAvailabilityAnalyzer.extractURL(from: text)

        XCTAssertNil(url)
    }

    // MARK: - Accession Extraction Tests

    /// Test extracting GSE accession number.
    func testExtractAccessionNumberGSE() {
        let text = "Deposited under accession GSE12345"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNotNil(accession)
    }

    /// Test extracting identifier.
    func testExtractIdentifier() {
        let text = "Data identifier: SRR12345678"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNotNil(accession)
    }

    /// Test extracting accession with colon.
    func testExtractAccessionWithColon() {
        let text = "GEO accession: GSE98765"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNotNil(accession)
    }

    /// Test no accession in text.
    func testExtractAccessionNumberNone() {
        let text = "Data available in public repository"
        let accession = DataAvailabilityAnalyzer.extractAccessionNumber(from: text)

        XCTAssertNil(accession)
    }

    // MARK: - Repository Detection Tests

    /// Test detecting Zenodo repository.
    func testDetectRepositoryZenodo() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "data in zenodo"),
            "Zenodo"
        )
    }

    /// Test detecting GitHub repository.
    func testDetectRepositoryGitHub() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "code on github"),
            "GitHub"
        )
    }

    /// Test detecting GitLab repository.
    func testDetectRepositoryGitLab() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "hosted on gitlab"),
            "GitLab"
        )
    }

    /// Test detecting GEO repository.
    func testDetectRepositoryGEO() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "deposited in geo"),
            "GEO"
        )
    }

    /// Test detecting Gene Expression Omnibus repository.
    func testDetectRepositoryGeneExpressionOmnibus() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "in gene expression omnibus"),
            "Gene Expression Omnibus"
        )
    }

    /// Test detecting no repository.
    func testDetectRepositoryNone() {
        XCTAssertNil(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "available from author")
        )
    }

    /// Test detecting Vivli repository.
    func testDetectRepositoryVivli() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "shared through vivli platform"),
            "Vivli"
        )
    }

    /// Test detecting YODA repository.
    func testDetectRepositoryYODA() {
        XCTAssertEqual(
            DataAvailabilityAnalyzer.detectRepositoryName(in: "available through yoda project"),
            "YODA Project"
        )
    }

    // MARK: - Restriction Extraction Tests

    /// Test extracting single restriction.
    func testExtractRestrictionsSingle() {
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(
            from: "available upon request"
        )
        XCTAssertEqual(restrictions.count, 1)
        XCTAssertTrue(restrictions.first?.contains("request") ?? false)
    }

    /// Test extracting multiple restrictions.
    func testExtractRestrictionsMultiple() {
        let text = "available upon request pending irb approval and data sharing agreement"
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(from: text)

        XCTAssertGreaterThanOrEqual(restrictions.count, 2)
    }

    /// Test extracting confidentiality restriction.
    func testExtractRestrictionsConfidential() {
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(
            from: "data is confidential and cannot be disclosed"
        )
        XCTAssertTrue(restrictions.contains { $0.contains("Confidentiality") })
    }

    /// Test restriction labels preserve pattern order without duplicates.
    func testExtractRestrictionsOrderedAndDeduplicated() {
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(
            from: "available upon request; contact the corresponding author; irb approval required"
        )
        // Order follows restrictedPatterns: request before author-contact before IRB.
        XCTAssertEqual(
            restrictions,
            ["Available upon request", "Contact corresponding author", "Requires IRB approval"]
        )
        XCTAssertEqual(Set(restrictions).count, restrictions.count)
    }

    /// Test no restrictions in text.
    func testExtractRestrictionsNone() {
        let restrictions = DataAvailabilityAnalyzer.extractRestrictions(
            from: "data freely available"
        )
        XCTAssertTrue(restrictions.isEmpty)
    }

    // MARK: - Clinical Trial Data Availability Tests

    /// Test clinical trial with unavailable data.
    func testCheckClinicalTrialDataAvailabilityNotAvailable() {
        let result = DataAvailabilityResult(
            statement: "Data not available",
            disclosureLevel: .notAvailable
        )
        let warning = DataAvailabilityAnalyzer.checkClinicalTrialDataAvailability(
            result: result,
            isClinicalTrial: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("not available"))
    }

    /// Test clinical trial with no data statement.
    func testCheckClinicalTrialDataAvailabilityNoStatement() {
        let warning = DataAvailabilityAnalyzer.checkClinicalTrialDataAvailability(
            result: .notStated,
            isClinicalTrial: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("no data availability statement"))
    }

    /// Test clinical trial with data available on request.
    func testCheckClinicalTrialDataAvailabilityOnRequest() {
        let result = DataAvailabilityResult(
            statement: "Available upon request",
            disclosureLevel: .availableOnRequest
        )
        let warning = DataAvailabilityAnalyzer.checkClinicalTrialDataAvailability(
            result: result,
            isClinicalTrial: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("only available on request"))
    }

    /// Test clinical trial with full open data.
    func testCheckClinicalTrialDataAvailabilityFullOpen() {
        let result = DataAvailabilityResult(
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo"
        )
        let warning = DataAvailabilityAnalyzer.checkClinicalTrialDataAvailability(
            result: result,
            isClinicalTrial: true
        )
        XCTAssertNil(warning)
    }

    /// Test non-clinical trial - no warning.
    func testCheckClinicalTrialDataAvailabilityNonTrial() {
        let result = DataAvailabilityResult(
            statement: "Data not available",
            disclosureLevel: .notAvailable
        )
        let warning = DataAvailabilityAnalyzer.checkClinicalTrialDataAvailability(
            result: result,
            isClinicalTrial: false
        )
        XCTAssertNil(warning)
    }

    // MARK: - Summary Tests

    /// Test formatSummary for full open.
    func testFormatSummaryFullOpen() {
        let result = DataAvailabilityResult(
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo"
        )
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("Zenodo"))
    }

    /// Test formatSummary for full open without repo name.
    func testFormatSummaryFullOpenNoRepo() {
        let result = DataAvailabilityResult(disclosureLevel: .fullOpen)
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("publicly available"))
    }

    /// Test formatSummary for available on request.
    func testFormatSummaryOnRequest() {
        let result = DataAvailabilityResult(disclosureLevel: .availableOnRequest)
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("upon request"))
    }

    /// Test formatSummary for restricted.
    func testFormatSummaryRestricted() {
        let result = DataAvailabilityResult(
            disclosureLevel: .restricted,
            restrictions: ["IRB approval required"]
        )
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("restricted"))
    }

    /// Test formatSummary for not available.
    func testFormatSummaryNotAvailable() {
        let result = DataAvailabilityResult(disclosureLevel: .notAvailable)
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("not available"))
    }

    /// Test formatSummary for not stated.
    func testFormatSummaryNotStated() {
        let summary = DataAvailabilityAnalyzer.formatSummary(.notStated)
        XCTAssertTrue(summary.contains("No data availability"))
    }

    /// Test formatSummary for unknown.
    func testFormatSummaryUnknown() {
        let result = DataAvailabilityResult(disclosureLevel: .unknown)
        let summary = DataAvailabilityAnalyzer.formatSummary(result)
        XCTAssertTrue(summary.contains("unclear"))
    }

    // MARK: - Detailed Info Tests

    /// Test formatDetailedInfo with full data.
    func testFormatDetailedInfoFull() {
        let result = DataAvailabilityResult(
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo",
            repositoryURL: URL(string: "https://zenodo.org/record/12345"),
            accessionNumber: "12345",
            restrictions: []
        )
        let info = DataAvailabilityAnalyzer.formatDetailedInfo(result)

        XCTAssertTrue(info.contains("Fully Open"))
        XCTAssertTrue(info.contains("Zenodo"))
        XCTAssertTrue(info.contains("zenodo.org"))
        XCTAssertTrue(info.contains("12345"))
    }

    /// Test formatDetailedInfo with restrictions.
    func testFormatDetailedInfoWithRestrictions() {
        let result = DataAvailabilityResult(
            disclosureLevel: .availableOnRequest,
            restrictions: ["IRB approval required", "Data sharing agreement"]
        )
        let info = DataAvailabilityAnalyzer.formatDetailedInfo(result)

        XCTAssertTrue(info.contains("Restrictions:"))
        XCTAssertTrue(info.contains("IRB"))
    }

    /// Test formatDetailedInfo minimal.
    func testFormatDetailedInfoMinimal() {
        let result = DataAvailabilityResult(disclosureLevel: .notStated)
        let info = DataAvailabilityAnalyzer.formatDetailedInfo(result)

        XCTAssertTrue(info.contains("Not Stated"))
    }
}
