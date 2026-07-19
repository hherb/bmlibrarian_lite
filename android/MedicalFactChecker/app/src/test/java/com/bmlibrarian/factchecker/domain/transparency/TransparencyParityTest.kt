package com.bmlibrarian.factchecker.domain.transparency

import java.io.File
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform parity drift guard for the data-availability classifier (#105).
 *
 * Kotlin, Python and Swift each carry their own transcription of the same pattern
 * lists and restriction labels. Before this guard existed, parity was maintained by
 * convention: each platform asserted only its *own* literals, so an edit to one
 * language could silently diverge from the other two.
 *
 * The contract lives in two language-neutral fixtures under
 * `doc/cross_platform/transparency_parity/`, loaded here and by the Python
 * (`tests/test_transparency_parity.py`) and Swift (`TransparencyParityTests.swift`)
 * suites:
 *  - `data_availability_patterns.json` — the pattern lists and label map, asserted
 *    string-for-string.
 *  - `data_availability_cases.json` — worked `statement -> (level, restrictions)`
 *    cases, asserted behaviourally. Catches divergence a string comparison cannot
 *    see, notably a [RegexHelper] that has lost its `(?U)` flag: the patterns still
 *    read identically but `\w` stops matching non-ASCII, and a negated openness
 *    affirmation with an accented intervening word escapes to FULL_OPEN.
 *
 * The fixtures are read from the repository tree rather than copied into
 * `src/test/resources`: all three platforms must read the *same* bytes, and a copy
 * would reintroduce exactly the divergence this guard exists to prevent.
 */
class TransparencyParityTest {

    @Serializable
    private data class LabelEntry(val pattern: String, val label: String)

    @Serializable
    private data class PatternManifest(
        val patterns: Map<String, List<String>>,
        @SerialName("restriction_labels") val restrictionLabels: List<LabelEntry>,
    )

    @Serializable
    private data class ParityCase(
        val id: String,
        val statement: String? = null,
        @SerialName("disclosure_level") val disclosureLevel: String,
        val restrictions: List<String>,
        val why: String? = null,
    )

    @Serializable
    private data class CaseFixture(val cases: List<ParityCase>)

    private companion object {
        val json = Json { ignoreUnknownKeys = true }

        /** Shared fixture directory, located by walking up from the Gradle working directory. */
        val fixtureDirectory: File by lazy {
            val relative = "doc/cross_platform/transparency_parity"
            var directory: File? = File("").absoluteFile
            while (directory != null) {
                val candidate = File(directory, relative)
                if (candidate.isDirectory) return@lazy candidate
                directory = directory.parentFile
            }
            error("could not locate $relative above ${File("").absolutePath}")
        }

        val manifest: PatternManifest by lazy {
            json.decodeFromString(
                File(fixtureDirectory, "data_availability_patterns.json").readText(),
            )
        }

        val cases: List<ParityCase> by lazy {
            json.decodeFromString<CaseFixture>(
                File(fixtureDirectory, "data_availability_cases.json").readText(),
            ).cases
        }
    }

    /**
     * Assert a pattern tier equals the shared contract, reporting only what drifted.
     *
     * A plain [assertEquals] on these lists dumps both in full — 27 patterns of dense
     * regex — which buries the one entry that actually changed. Pointing at the
     * differing index is what makes the failure actionable.
     */
    private fun assertTierMatchesContract(actual: List<String>, tier: String) {
        val expected = requireNotNull(manifest.patterns[tier]) {
            "shared contract has no '$tier' tier"
        }
        if (actual == expected) return

        val header = buildString {
            append("'$tier' has drifted from the shared contract")
            if (actual.size != expected.size) {
                append(" (Kotlin has ${actual.size} patterns, contract has ${expected.size})")
            }
        }
        val differences = actual.zip(expected).withIndex()
            .filter { (_, pair) -> pair.first != pair.second }
            .joinToString("\n") { (index, pair) ->
                "  [$index] Kotlin:   ${pair.first}\n       contract: ${pair.second}"
            }
        throw AssertionError(if (differences.isEmpty()) header else "$header:\n$differences")
    }

    // ==================== pattern manifest parity ====================

    @Test
    fun `full open patterns match the shared contract`() {
        assertTierMatchesContract(DataRepositoryPatterns.fullOpenPatterns, "full_open")
    }

    @Test
    fun `negated openness patterns match the shared contract`() {
        assertTierMatchesContract(
            DataRepositoryPatterns.negatedOpennessPatterns,
            "negated_openness",
        )
    }

    @Test
    fun `restricted patterns match the shared contract`() {
        assertTierMatchesContract(DataRepositoryPatterns.restrictedPatterns, "restricted")
    }

    @Test
    fun `strong refusal patterns match the shared contract`() {
        assertTierMatchesContract(DataRepositoryPatterns.strongRefusalPatterns, "strong_refusal")
    }

    @Test
    fun `effectively unavailable patterns match the shared contract`() {
        assertTierMatchesContract(
            DataRepositoryPatterns.effectivelyUnavailablePatterns,
            "effectively_unavailable",
        )
    }

    @Test
    fun `restriction labels match the shared contract`() {
        val expected = manifest.restrictionLabels.associate { it.pattern to it.label }
        val actual = DataRepositoryPatterns.restrictionLabels
        if (actual == expected) return

        val differences = (actual.keys + expected.keys).sorted().mapNotNull { pattern ->
            val kotlin = actual[pattern]
            val contract = expected[pattern]
            when {
                kotlin == contract -> null
                kotlin == null -> "  $pattern\n    contract only: $contract"
                contract == null -> "  $pattern\n      Kotlin only: $kotlin"
                else -> "  $pattern\n       Kotlin: $kotlin\n     contract: $contract"
            }
        }
        throw AssertionError(
            "restriction labels have drifted from the shared contract:\n" +
                differences.joinToString("\n"),
        )
    }

    // ==================== behavioural case parity ====================

    @Test
    fun `every shared fixture case classifies as specified`() {
        assertTrue("behavioural fixture is empty", cases.isNotEmpty())

        for (case in cases) {
            val context = listOfNotNull(case.id, case.why).joinToString(": ")
            val result = DataAvailabilityAnalyzer.analyze(case.statement)

            assertEquals(
                "disclosure level — $context",
                case.disclosureLevel,
                result.disclosureLevel.rawValue,
            )
            assertEquals("restrictions — $context", case.restrictions, result.restrictions)
        }
    }
}
