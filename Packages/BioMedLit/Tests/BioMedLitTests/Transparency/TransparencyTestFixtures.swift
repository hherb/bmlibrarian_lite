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
@testable import BioMedLit

/// Test fixtures for transparency analysis tests.
///
/// Provides sample data structures and JSON responses for mocking API calls
/// and testing transparency analysis functionality.
enum TransparencyTestFixtures {

    // MARK: - CrossRef Fixtures

    /// Sample CrossRef work response for an industry-funded study.
    static let industryFundedWorkJSON: [String: Any] = [
        "title": ["A Randomized, Double-Blind, Placebo-Controlled Study"],
        "container-title": ["New England Journal of Medicine"],
        "author": [
            ["family": "Smith", "given": "John"],
            ["family": "Doe", "given": "Jane"],
        ],
        "funder": [
            [
                "name": "Pfizer Inc.",
                "DOI": "10.13039/100004319",
                "award": ["GRANT-2024-001"],
            ],
        ],
        "published-print": [
            "date-parts": [[2024, 3, 15]],
        ],
    ]

    /// Sample CrossRef work response for an NIH-funded study.
    static let academicFundedWorkJSON: [String: Any] = [
        "title": ["Effects of Exercise on Cardiovascular Health"],
        "container-title": ["JAMA Internal Medicine"],
        "author": [
            ["family": "Johnson", "given": "Mary"],
        ],
        "funder": [
            [
                "name": "National Institutes of Health",
                "award": ["R01-HL123456"],
            ],
        ],
        "published-online": [
            "date-parts": [[2024, 1, 10]],
        ],
    ]

    /// Sample CrossRef work response with mixed funding.
    static let mixedFundedWorkJSON: [String: Any] = [
        "title": ["Collaborative Research Initiative"],
        "container-title": ["The Lancet"],
        "funder": [
            [
                "name": "Novartis AG",
                "DOI": "10.13039/100004336",
                "award": ["NVS-2024"],
            ],
            [
                "name": "National Science Foundation",
                "award": ["NSF-2024-789"],
            ],
        ],
    ]

    /// Sample CrossRef work response with no funders.
    static let workNoFundersJSON: [String: Any] = [
        "title": ["Observational Study Without Disclosed Funding"],
        "container-title": ["PLoS ONE"],
    ]

    // MARK: - ClinicalTrials.gov Fixtures

    /// Sample ClinicalTrials.gov study response for an industry-sponsored trial.
    static let industryTrialStudyJSON: [String: Any] = [
        "protocolSection": [
            "identificationModule": [
                "nctId": "NCT01234567",
                "officialTitle": "A Phase III Study of Drug X vs Placebo",
                "briefTitle": "Drug X Study",
            ],
            "sponsorCollaboratorsModule": [
                "leadSponsor": [
                    "name": "Pfizer Inc.",
                    "class": "INDUSTRY",
                ],
            ],
            "outcomesModule": [
                "primaryOutcomes": [
                    ["measure": "Change in blood pressure from baseline"],
                    ["measure": "Time to first cardiovascular event"],
                ],
                "secondaryOutcomes": [
                    ["measure": "Quality of life score"],
                ],
            ],
            "statusModule": [
                "completionDateStruct": [
                    "date": "2023-06-30",
                ],
            ],
        ],
        "hasResults": true,
    ]

    /// Sample ClinicalTrials.gov study response for an NIH-sponsored trial.
    static let nihTrialStudyJSON: [String: Any] = [
        "protocolSection": [
            "identificationModule": [
                "nctId": "NCT87654321",
                "officialTitle": "Community-Based Exercise Intervention",
            ],
            "sponsorCollaboratorsModule": [
                "leadSponsor": [
                    "name": "National Heart, Lung, and Blood Institute",
                    "class": "NIH",
                ],
            ],
            "outcomesModule": [
                "primaryOutcomes": [
                    ["measure": "Improvement in VO2 max"],
                ],
            ],
            "statusModule": [
                "completionDateStruct": [
                    "date": "2024-01-15",
                ],
            ],
        ],
        "hasResults": false,
    ]

    /// Sample ClinicalTrials.gov study response without results.
    static let trialWithoutResultsJSON: [String: Any] = [
        "protocolSection": [
            "identificationModule": [
                "nctId": "NCT99999999",
                "officialTitle": "Ongoing Study",
            ],
            "sponsorCollaboratorsModule": [
                "leadSponsor": [
                    "name": "Test Pharma Corp.",
                    "class": "INDUSTRY",
                ],
            ],
            "statusModule": [
                "completionDateStruct": [
                    "date": "2022-01-01",
                ],
            ],
        ],
        "hasResults": false,
    ]

    // MARK: - COI Statement Fixtures

    /// COI statement with disclosed industry ties.
    static let coiStatementWithTies = """
    Dr. Smith reports personal fees from Pfizer, grants from Novartis,
    and serves on the advisory board for AstraZeneca. Dr. Doe reports
    consultant fees from Johnson & Johnson.
    """

    /// COI statement declaring no conflicts.
    static let coiStatementNoConflicts = """
    The authors declare no conflict of interest. All authors have completed
    the ICMJE uniform disclosure form.
    """

    /// COI statement that is ambiguous.
    static let coiStatementAmbiguous = """
    The authors have disclosed all potential conflicts of interest.
    """

    // MARK: - Data Availability Fixtures

    /// Data availability statement with open repository.
    static let dataAvailabilityOpen = """
    All data are available in the Zenodo repository at
    https://zenodo.org/record/12345 under accession number 12345.
    Code is available on GitHub at https://github.com/example/study.
    """

    /// Data availability statement with request-only access.
    static let dataAvailabilityOnRequest = """
    Data available upon reasonable request from the corresponding author.
    Due to privacy concerns, individual patient data cannot be shared publicly.
    """

    /// Data availability statement with restricted access.
    static let dataAvailabilityRestricted = """
    Data are available to qualified researchers who complete a data sharing
    agreement and obtain IRB approval. Contact the corresponding author
    for details.
    """

    /// Data availability statement indicating data is not available.
    static let dataAvailabilityNotAvailable = """
    The data that support the findings of this study are proprietary and
    cannot be shared due to confidentiality agreements.
    """

    // MARK: - Full Text Fixtures

    /// Sample full text with data availability section.
    static let fullTextWithDataAvailability = """
    Introduction
    This study examines the effects of intervention X on outcome Y.

    Methods
    We conducted a randomized controlled trial...

    Results
    The intervention group showed significant improvement...

    Discussion
    Our findings suggest that intervention X is effective...

    Data Availability: All data are available in the Zenodo repository at
    https://zenodo.org/record/12345 under accession number 12345.

    Conflict of Interest: Dr. Smith reports grants from Pfizer.
    Dr. Doe has no conflicts to declare.

    References
    1. Previous study...
    """

    /// Sample full text without data availability section.
    static let fullTextWithoutDataAvailability = """
    Introduction
    This study examines the effects of intervention X.

    Methods
    Standard methodology was used...

    Results
    Significant findings were observed...

    Discussion
    The implications are discussed...

    References
    1. Reference one...
    """

    // MARK: - FunderInfo Fixtures

    /// Create a sample industry funder.
    static func makeIndustryFunder(
        name: String = "Pfizer Inc.",
        doi: String? = "10.13039/100004319",
        confidence: Double = 1.0
    ) -> FunderInfo {
        FunderInfo(
            name: name,
            funderDOI: doi,
            awardNumbers: ["GRANT-001"],
            isIndustry: true,
            confidence: confidence
        )
    }

    /// Create a sample government funder.
    static func makeGovernmentFunder(
        name: String = "National Institutes of Health",
        confidence: Double = 0.9
    ) -> FunderInfo {
        FunderInfo(
            name: name,
            funderDOI: nil,
            awardNumbers: ["R01-123456"],
            isIndustry: false,
            confidence: confidence
        )
    }

    /// Create a sample academic funder.
    static func makeAcademicFunder(
        name: String = "Harvard University",
        confidence: Double = 0.8
    ) -> FunderInfo {
        FunderInfo(
            name: name,
            funderDOI: nil,
            awardNumbers: [],
            isIndustry: false,
            confidence: confidence
        )
    }

    // MARK: - TrialRegistration Fixtures

    /// Number of days for "six months ago" completion date in test fixtures.
    private static let sixMonthsInDays = 180

    /// Create a sample industry trial registration.
    ///
    /// - Parameters:
    ///   - nctId: NCT identifier for the trial.
    ///   - resultsPosted: Whether results have been posted.
    /// - Returns: A configured TrialRegistration instance.
    static func makeIndustryTrialRegistration(
        nctId: String = "NCT01234567",
        resultsPosted: Bool = true
    ) -> TrialRegistration {
        let oneYearAgo = -Double(TransparencyConstants.resultsComplianceDeadlineDays)
            * TransparencyConstants.secondsPerDay
        return TrialRegistration(
            registry: TransparencyConstants.clinicalTrialsRegistryName,
            registrationId: nctId,
            title: "Industry-Sponsored Trial",
            sponsorClass: "INDUSTRY",
            leadSponsor: "Pfizer Inc.",
            resultsPosted: resultsPosted,
            completionDate: Date().addingTimeInterval(oneYearAgo),
            primaryOutcomesRegistered: ["Primary Outcome 1"],
            secondaryOutcomesRegistered: ["Secondary Outcome 1"]
        )
    }

    /// Create a sample NIH trial registration.
    ///
    /// - Parameters:
    ///   - nctId: NCT identifier for the trial.
    ///   - resultsPosted: Whether results have been posted.
    /// - Returns: A configured TrialRegistration instance.
    static func makeNIHTrialRegistration(
        nctId: String = "NCT87654321",
        resultsPosted: Bool = false
    ) -> TrialRegistration {
        let sixMonthsAgo = -Double(sixMonthsInDays) * TransparencyConstants.secondsPerDay
        return TrialRegistration(
            registry: TransparencyConstants.clinicalTrialsRegistryName,
            registrationId: nctId,
            title: "NIH-Sponsored Trial",
            sponsorClass: "NIH",
            leadSponsor: "National Heart, Lung, and Blood Institute",
            resultsPosted: resultsPosted,
            completionDate: Date().addingTimeInterval(sixMonthsAgo),
            primaryOutcomesRegistered: ["Exercise capacity"],
            secondaryOutcomesRegistered: []
        )
    }
}
