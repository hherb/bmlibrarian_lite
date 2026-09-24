package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * Sample data for the transparency tests (port of the Swift `TransparencyTestFixtures`).
 */
internal object TransparencyTestFixtures {

    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    // ==================== CrossRef works (the `message` object) ====================

    val industryFundedWorkJson: JsonObject = obj(
        """
        {
          "title": ["A Randomized, Double-Blind, Placebo-Controlled Study"],
          "container-title": ["New England Journal of Medicine"],
          "author": [{"family": "Smith", "given": "John"}, {"family": "Doe", "given": "Jane"}],
          "funder": [{"name": "Pfizer Inc.", "DOI": "10.13039/100004319", "award": ["GRANT-2024-001"]}],
          "published-print": {"date-parts": [[2024, 3, 15]]}
        }
        """,
    )

    val academicFundedWorkJson: JsonObject = obj(
        """
        {
          "title": ["Effects of Exercise on Cardiovascular Health"],
          "container-title": ["JAMA Internal Medicine"],
          "author": [{"family": "Johnson", "given": "Mary"}],
          "funder": [{"name": "National Institutes of Health", "award": ["R01-HL123456"]}],
          "published-online": {"date-parts": [[2024, 1, 10]]}
        }
        """,
    )

    val mixedFundedWorkJson: JsonObject = obj(
        """
        {
          "title": ["Collaborative Research Initiative"],
          "container-title": ["The Lancet"],
          "funder": [
            {"name": "Novartis AG", "DOI": "10.13039/100004336", "award": ["NVS-2024"]},
            {"name": "National Science Foundation", "award": ["NSF-2024-789"]}
          ]
        }
        """,
    )

    val workNoFundersJson: JsonObject = obj(
        """
        {"title": ["Observational Study Without Disclosed Funding"], "container-title": ["PLoS ONE"]}
        """,
    )

    // ==================== ClinicalTrials.gov studies ====================

    const val INDUSTRY_TRIAL_STUDY: String = """
        {
          "protocolSection": {
            "identificationModule": {
              "nctId": "NCT01234567",
              "officialTitle": "A Phase III Study of Drug X vs Placebo",
              "briefTitle": "Drug X Study"
            },
            "sponsorCollaboratorsModule": {"leadSponsor": {"name": "Pfizer Inc.", "class": "INDUSTRY"}},
            "outcomesModule": {
              "primaryOutcomes": [
                {"measure": "Change in blood pressure from baseline"},
                {"measure": "Time to first cardiovascular event"}
              ],
              "secondaryOutcomes": [{"measure": "Quality of life score"}]
            },
            "statusModule": {"completionDateStruct": {"date": "2023-06-30"}}
          },
          "hasResults": true
        }
        """

    const val NIH_TRIAL_STUDY: String = """
        {
          "protocolSection": {
            "identificationModule": {"nctId": "NCT87654321", "officialTitle": "Community-Based Exercise Intervention"},
            "sponsorCollaboratorsModule": {
              "leadSponsor": {"name": "National Heart, Lung, and Blood Institute", "class": "NIH"}
            },
            "outcomesModule": {"primaryOutcomes": [{"measure": "Improvement in VO2 max"}]},
            "statusModule": {"completionDateStruct": {"date": "2024-01-15"}}
          },
          "hasResults": false
        }
        """

    const val TRIAL_WITHOUT_RESULTS_STUDY: String = """
        {
          "protocolSection": {
            "identificationModule": {"nctId": "NCT99999999", "officialTitle": "Ongoing Study"},
            "sponsorCollaboratorsModule": {"leadSponsor": {"name": "Test Pharma Corp.", "class": "INDUSTRY"}},
            "statusModule": {"completionDateStruct": {"date": "2022-01-01"}}
          },
          "hasResults": false
        }
        """

    val industryTrialStudyJson: JsonObject = obj(INDUSTRY_TRIAL_STUDY)
    val nihTrialStudyJson: JsonObject = obj(NIH_TRIAL_STUDY)
    val trialWithoutResultsJson: JsonObject = obj(TRIAL_WITHOUT_RESULTS_STUDY)

    // ==================== Full text ====================

    val fullTextWithDataAvailability: String = """
        Introduction
        This study examines the effects of intervention X on outcome Y.

        Methods
        We conducted a randomized controlled trial...

        Data Availability: All data are available in the Zenodo repository at
        https://zenodo.org/record/12345 under accession number 12345.

        Conflict of Interest: Dr. Smith reports grants from Pfizer.
        Dr. Doe has no conflicts to declare.

        References
        1. Previous study...
    """.trimIndent()

    val fullTextWithoutDataAvailability: String = """
        Introduction
        This study examines the effects of intervention X.

        Methods
        Standard methodology was used...

        References
        1. Reference one...
    """.trimIndent()

    // ==================== Registrations ====================

    /** An industry trial completed a year ago. */
    fun makeIndustryTrialRegistration(nctId: String = "NCT01234567", resultsPosted: Boolean = true): TrialRegistration =
        TrialRegistration(
            registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
            registrationId = nctId,
            title = "Industry-Sponsored Trial",
            sponsorClass = "INDUSTRY",
            leadSponsor = "Pfizer Inc.",
            resultsPosted = resultsPosted,
            completionDate = Instant.now().minusSeconds(
                TransparencyConstants.RESULTS_COMPLIANCE_DEADLINE_DAYS * TransparencyConstants.SECONDS_PER_DAY,
            ),
            primaryOutcomesRegistered = listOf("Primary Outcome 1"),
            secondaryOutcomesRegistered = listOf("Secondary Outcome 1"),
        )

    /** An NIH trial completed six months ago. */
    fun makeNIHTrialRegistration(nctId: String = "NCT87654321", resultsPosted: Boolean = false): TrialRegistration =
        TrialRegistration(
            registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
            registrationId = nctId,
            title = "NIH-Sponsored Trial",
            sponsorClass = "NIH",
            leadSponsor = "National Heart, Lung, and Blood Institute",
            resultsPosted = resultsPosted,
            completionDate = Instant.now().minusSeconds(SIX_MONTHS_IN_DAYS * TransparencyConstants.SECONDS_PER_DAY),
            primaryOutcomesRegistered = listOf("Exercise capacity"),
        )

    private const val SIX_MONTHS_IN_DAYS = 180L
}
