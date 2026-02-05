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

import Foundation

/// Main service for analyzing study transparency.
///
/// Orchestrates data fetching from multiple APIs (PubMed, CrossRef, ClinicalTrials.gov)
/// and applies pure analysis functions to generate a comprehensive transparency report.
///
/// Usage:
/// ```swift
/// let service = TransparencyAnalysisService(email: "user@example.com")
/// let result = try await service.analyze(pmid: "33301246")
/// // or
/// let result = try await service.analyze(doi: "10.1056/NEJMoa2034577")
/// print("Score: \(result.transparencyScore)")
/// print("Risk: \(result.riskLevel)")
/// ```
public actor TransparencyAnalysisService {

    // MARK: - Properties

    /// Contact email for API identification (required by CrossRef polite pool).
    private let email: String

    /// Optional NCBI API key for higher PubMed rate limits.
    private let pubmedApiKey: String?

    /// URLSession used for network requests.
    private let session: URLSession

    // Services (lazily initialized to avoid overhead when not needed)
    private var crossRefService: CrossRefService?
    private var clinicalTrialsService: ClinicalTrialsService?
    private var pubmedService: PubMedService?
    private var europePMCService: EuropePMCService?

    // MARK: - Initialization

    /// Initialize the transparency analysis service.
    ///
    /// - Parameters:
    ///   - email: Contact email (required for API access, used for CrossRef polite pool
    ///     identification and PubMed E-utilities).
    ///   - pubmedApiKey: Optional NCBI API key for higher PubMed rate limits.
    ///   - session: URLSession for network requests. If nil, creates a new session
    ///     with default timeout configuration.
    public init(email: String, pubmedApiKey: String? = nil, session: URLSession? = nil) {
        self.email = email
        self.pubmedApiKey = pubmedApiKey

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.defaultRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Main Analysis

    /// Analyze a study for transparency indicators.
    ///
    /// Fetches metadata from multiple sources and applies transparency analysis functions
    /// to generate a comprehensive result. The analysis includes:
    /// - Funding source classification (industry vs non-industry)
    /// - Trial registration verification
    /// - Conflict of interest statement analysis
    /// - Data availability assessment
    /// - Results compliance checking for clinical trials
    ///
    /// - Parameters:
    ///   - doi: Digital Object Identifier (optional if PMID provided).
    ///   - pmid: PubMed ID (optional if DOI provided).
    ///   - fullText: Optional full text for enhanced analysis of data availability
    ///     and COI statements embedded in the article.
    /// - Returns: TransparencyResult with complete analysis including score and risk level.
    /// - Throws: TransparencyAnalysisError if analysis fails (e.g., no identifiers provided).
    public func analyze(
        doi: String? = nil,
        pmid: String? = nil,
        fullText: String? = nil
    ) async throws -> TransparencyResult {
        guard doi != nil || pmid != nil else {
            throw TransparencyAnalysisError.noIdentifiers
        }

        var builder = TransparencyResultBuilder(doi: doi, pmid: pmid)

        BioMedLitLib.logger?.info(
            "Starting transparency analysis for DOI: \(doi ?? "nil"), PMID: \(pmid ?? "nil")",
            category: .transparency
        )

        // Step 1: Fetch basic metadata from PubMed and CrossRef
        await fetchBasicMetadata(builder: &builder)

        // Step 2: Fetch and analyze funder information
        await fetchFunderInfo(builder: &builder)

        // Step 3: Fetch clinical trial registration info
        await fetchTrialInfo(builder: &builder)

        // Step 4: Analyze COI statement
        analyzeCOI(builder: &builder, fullText: fullText)

        // Step 5: Analyze data availability
        analyzeDataAvailability(builder: &builder, fullText: fullText)

        // Step 6: Check for discrepancies and generate warnings
        checkDiscrepancies(builder: &builder)

        let result = builder.build()

        BioMedLitLib.logger?.info(
            "Transparency analysis complete: score=\(result.transparencyScore), risk=\(result.riskLevel.rawValue)",
            category: .transparency
        )

        return result
    }

    // MARK: - Analysis Steps

    /// Fetch basic article metadata from PubMed and CrossRef.
    ///
    /// Attempts to retrieve article metadata from multiple sources to ensure
    /// comprehensive coverage. PubMed is tried first for articles with PMID,
    /// then CrossRef is used to fill in any missing information.
    ///
    /// - Parameter builder: The result builder to populate with metadata.
    private func fetchBasicMetadata(builder: inout TransparencyResultBuilder) async {
        // Try PubMed first if we have a PMID
        if let pmid = builder.pmid {
            do {
                let pubmed = getPubMedService()
                let results = try await pubmed.search(query: pmid, maxResults: 1)
                if let article = results.articles.first {
                    builder.title = article.title
                    builder.journal = article.journal
                    builder.authors = formatAuthorsToArray(article.authors)
                    builder.pmcid = article.pmcId

                    // Get DOI if not provided
                    if builder.doi == nil {
                        builder.doi = article.doi
                    }

                    builder.dataSourcesUsed.append("PubMed")

                    BioMedLitLib.logger?.debug(
                        "PubMed metadata retrieved for PMID: \(pmid)",
                        category: .transparency
                    )
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "PubMed fetch failed for PMID \(pmid): \(error.localizedDescription)",
                    category: .network
                )
            }
        }

        // Try CrossRef if we have a DOI
        if let doi = builder.doi {
            do {
                let crossRef = getCrossRefService()
                let work = try await crossRef.getWork(doi: doi)

                if let work = work {
                    builder.dataSourcesUsed.append("CrossRef")

                    // Fill in missing data from CrossRef
                    if builder.title == nil {
                        builder.title = crossRef.extractTitle(from: work)
                    }
                    if builder.journal == nil {
                        builder.journal = crossRef.extractJournal(from: work)
                    }
                    if builder.authors.isEmpty {
                        builder.authors = crossRef.extractAuthors(from: work)
                    }
                    if builder.publicationDate == nil {
                        builder.publicationDate = crossRef.extractPublicationDate(from: work)
                    }

                    // Extract funders from CrossRef for later analysis
                    let crossRefFunders = crossRef.extractFunders(from: work)
                    builder.funders = FundingAnalyzer.mergeFunders(builder.funders, crossRefFunders)

                    BioMedLitLib.logger?.debug(
                        "CrossRef metadata retrieved for DOI: \(doi)",
                        category: .transparency
                    )
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "CrossRef fetch failed for DOI \(doi): \(error.localizedDescription)",
                    category: .network
                )
            }
        }
    }

    /// Fetch and analyze funder information.
    ///
    /// Uses the funders already populated from CrossRef (in fetchBasicMetadata)
    /// to determine sponsor type and industry funding status.
    ///
    /// - Parameter builder: The result builder to populate with funding analysis.
    private func fetchFunderInfo(builder: inout TransparencyResultBuilder) async {
        // Funders may already be populated from CrossRef in fetchBasicMetadata

        // Determine sponsor type from collected funders
        builder.sponsorType = FundingAnalyzer.determineSponsorType(from: builder.funders)

        // Determine industry funding status
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: builder.funders)
        builder.industryFundingDetected = detected
        builder.industryFundingConfidence = confidence

        BioMedLitLib.logger?.debug(
            "Funding analysis: sponsorType=\(builder.sponsorType), " +
            "industryDetected=\(detected), confidence=\(confidence)",
            category: .transparency
        )
    }

    /// Fetch clinical trial registration information.
    ///
    /// Searches for NCT IDs in the article title and fetches trial details
    /// from ClinicalTrials.gov API. Updates sponsor type based on trial
    /// sponsor information and checks results compliance.
    ///
    /// - Parameter builder: The result builder to populate with trial info.
    private func fetchTrialInfo(builder: inout TransparencyResultBuilder) async {
        // Extract NCT IDs from title
        var nctIds: [String] = []

        if let title = builder.title {
            nctIds.append(contentsOf: TrialComplianceAnalyzer.extractNCTIds(from: title))
        }

        // Skip if no NCT IDs found
        guard !nctIds.isEmpty else {
            BioMedLitLib.logger?.debug(
                "No NCT IDs found in article",
                category: .transparency
            )
            return
        }

        BioMedLitLib.logger?.debug(
            "Found \(nctIds.count) NCT ID(s): \(nctIds.joined(separator: ", "))",
            category: .transparency
        )

        // Fetch each trial from ClinicalTrials.gov
        let clinicalTrials = getClinicalTrialsService()

        for nctId in nctIds {
            do {
                if let study = try await clinicalTrials.getStudy(nctId: nctId),
                   let registration = clinicalTrials.extractTrialInfo(from: study) {

                    builder.trialRegistrations.append(registration)
                    if !builder.dataSourcesUsed.contains("ClinicalTrials.gov") {
                        builder.dataSourcesUsed.append("ClinicalTrials.gov")
                    }

                    // Update sponsor type based on trial sponsor
                    if TrialComplianceAnalyzer.isIndustrySponsor(registration.sponsorClass) {
                        builder.industryFundingDetected = true
                        builder.sponsorType = FundingAnalyzer.updateSponsorType(
                            builder.sponsorType,
                            withTrialSponsorClass: registration.sponsorClass
                        )
                    }

                    BioMedLitLib.logger?.debug(
                        "Trial info retrieved for \(nctId): sponsor=\(registration.leadSponsor ?? "unknown")",
                        category: .transparency
                    )
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "ClinicalTrials.gov fetch failed for \(nctId): \(error.localizedDescription)",
                    category: .network
                )
            }
        }

        // Check results compliance for first trial
        if let firstTrial = builder.trialRegistrations.first {
            builder.resultsCompliance = TrialComplianceAnalyzer.checkResultsCompliance(
                trial: firstTrial,
                publicationDate: builder.publicationDate
            )
        }
    }

    /// Analyze conflict of interest statement.
    ///
    /// Extracts and analyzes COI information from the full text if available.
    /// Currently marks COI as not available if no full text is provided.
    ///
    /// - Parameters:
    ///   - builder: The result builder to populate with COI analysis.
    ///   - fullText: Optional full text of the article.
    private func analyzeCOI(builder: inout TransparencyResultBuilder, fullText: String?) {
        // Try to extract COI statement from full text
        var coiStatement: String?

        if let fullText = fullText {
            coiStatement = extractCOISection(from: fullText)
        }

        builder.coiAnalysis = COIAnalyzer.analyze(statement: coiStatement)

        BioMedLitLib.logger?.debug(
            "COI analysis: hasStatement=\(coiStatement != nil), " +
            "hasIndustryTies=\(builder.coiAnalysis.hasIndustryTies)",
            category: .transparency
        )
    }

    /// Analyze data availability statement.
    ///
    /// Extracts and analyzes data availability information from the full text
    /// if available. Falls back to marking as "not stated" if no full text
    /// or no data availability section is found.
    ///
    /// - Parameters:
    ///   - builder: The result builder to populate with data availability analysis.
    ///   - fullText: Optional full text of the article.
    private func analyzeDataAvailability(builder: inout TransparencyResultBuilder, fullText: String?) {
        var dataStatement: String?

        // Try to extract from full text if provided
        if let fullText = fullText {
            dataStatement = extractDataAvailabilitySection(from: fullText)
        }

        builder.dataAvailability = DataAvailabilityAnalyzer.analyze(statement: dataStatement)

        BioMedLitLib.logger?.debug(
            "Data availability analysis: level=\(builder.dataAvailability.disclosureLevel)",
            category: .transparency
        )
    }

    /// Check for discrepancies between funding and disclosure.
    ///
    /// Validates consistency between industry funding detection and COI disclosure,
    /// and checks for missing trial registration on clinical trials.
    ///
    /// - Parameter builder: The result builder to populate with warnings.
    private func checkDiscrepancies(builder: inout TransparencyResultBuilder) {
        // Check COI vs funding discrepancy
        if let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: builder.coiAnalysis,
            industryFundingDetected: builder.industryFundingDetected
        ) {
            builder.warnings.append(warning)
            BioMedLitLib.logger?.debug(
                "Discrepancy detected: \(warning)",
                category: .transparency
            )
        }

        // Check for missing trial registration
        if let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: builder.title,
            registrations: builder.trialRegistrations
        ) {
            builder.warnings.append(warning)
            BioMedLitLib.logger?.debug(
                "Missing registration warning: \(warning)",
                category: .transparency
            )
        }
    }

    // MARK: - Text Extraction Helpers

    /// Extract data availability section from full text.
    ///
    /// Searches for common data availability section headers and extracts
    /// the surrounding text.
    ///
    /// - Parameter fullText: The full text of the article.
    /// - Returns: The extracted data availability statement, or nil if not found.
    private func extractDataAvailabilitySection(from fullText: String) -> String? {
        let patterns = [
            #"(?i)data\s+availability[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)availability\s+of\s+data[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)data\s+sharing[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)data\s+access[:\s]+([^§]+?)(?=\n\n|\z)"#,
        ]

        for pattern in patterns {
            if let extracted = RegexHelper.extractFirst(pattern: pattern, from: fullText) {
                let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    /// Extract conflict of interest section from full text.
    ///
    /// Searches for common COI section headers and extracts the surrounding text.
    ///
    /// - Parameter fullText: The full text of the article.
    /// - Returns: The extracted COI statement, or nil if not found.
    private func extractCOISection(from fullText: String) -> String? {
        let patterns = [
            #"(?i)conflict(?:s)?\s+of\s+interest[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)competing\s+interest(?:s)?[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)disclosure(?:s)?[:\s]+([^§]+?)(?=\n\n|\z)"#,
            #"(?i)financial\s+disclosure(?:s)?[:\s]+([^§]+?)(?=\n\n|\z)"#,
        ]

        for pattern in patterns {
            if let extracted = RegexHelper.extractFirst(pattern: pattern, from: fullText) {
                let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    // MARK: - Helper Functions

    /// Format authors string to array.
    ///
    /// Converts a comma-separated author string to an array of author names.
    ///
    /// - Parameter authors: Comma-separated author string.
    /// - Returns: Array of author names.
    private func formatAuthorsToArray(_ authors: String) -> [String] {
        authors.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Service Accessors

    /// Get or create the CrossRef service.
    private func getCrossRefService() -> CrossRefService {
        if crossRefService == nil {
            crossRefService = CrossRefService(email: email, session: session)
        }
        return crossRefService!
    }

    /// Get or create the ClinicalTrials.gov service.
    private func getClinicalTrialsService() -> ClinicalTrialsService {
        if clinicalTrialsService == nil {
            clinicalTrialsService = ClinicalTrialsService(session: session)
        }
        return clinicalTrialsService!
    }

    /// Get or create the PubMed service.
    private func getPubMedService() -> PubMedService {
        if pubmedService == nil {
            pubmedService = PubMedService(email: email, apiKey: pubmedApiKey, session: session)
        }
        return pubmedService!
    }

    /// Get or create the Europe PMC service.
    private func getEuropePMCService() -> EuropePMCService {
        if europePMCService == nil {
            europePMCService = EuropePMCService()
        }
        return europePMCService!
    }
}

// MARK: - Errors

/// Errors that can occur during transparency analysis.
public enum TransparencyAnalysisError: LocalizedError, Sendable {
    /// No identifiers (DOI or PMID) were provided for analysis.
    case noIdentifiers

    /// Analysis failed with a specific reason.
    case analysisFailure(String)

    public var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Must provide either DOI or PMID for analysis"
        case .analysisFailure(let message):
            return "Analysis failed: \(message)"
        }
    }
}

