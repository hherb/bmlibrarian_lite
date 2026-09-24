package com.bmlibrarian.factchecker.domain.transparency

import java.io.File
import kotlinx.serialization.json.Json

/**
 * Locates the shared cross-platform transparency fixtures.
 *
 * Read from the repository tree, never copied into test resources: every
 * platform must read the same bytes (see
 * `doc/cross_platform/transparency_parity/README.md`).
 */
internal object ParityFixtures {

    /** Lenient JSON for fixture files, which carry `_readme` and similar keys. */
    val json: Json = Json { ignoreUnknownKeys = true }

    /** The fixture directory, found by walking up from the Gradle working directory. */
    val directory: File by lazy {
        val relative = "doc/cross_platform/transparency_parity"
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val found = File(candidate, relative)
            if (found.isDirectory) return@lazy found
            candidate = candidate.parentFile
        }
        error("could not locate $relative above ${File("").absolutePath}")
    }

    /** The text of one fixture file. */
    fun read(name: String): String = File(directory, name).readText()

    /**
     * Assert a pattern list equals the contract, reporting only the indices that drifted.
     *
     * @param actual The list as Kotlin declares it.
     * @param expected The list as the contract declares it.
     * @param tier The contract key, named in the failure.
     */
    fun assertPatternsMatch(actual: List<String>, expected: List<String>, tier: String) {
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
}
