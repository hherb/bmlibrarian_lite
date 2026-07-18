package com.bmlibrarian.factchecker.domain.transparency

/**
 * Classifies a data-availability statement into a [DataDisclosureLevel] and a
 * list of human-readable restriction labels.
 *
 * Uses the same priority-ordered tiers as the canonical Python
 * `analyze_data_availability` and the Swift `DataAvailabilityAnalyzer.analyze`,
 * so a given statement classifies identically on all three platforms:
 *  1. Full open (repository name or open-availability affirmation) — unless the
 *     statement also refuses access.
 *  2. Effectively unavailable / strong refusal -> NOT_AVAILABLE.
 *  3. Restricted / on-request -> RESTRICTED.
 *  4. A statement with no matching pattern -> UNKNOWN.
 *  5. Empty/null input -> NOT_STATED. (A whitespace-only statement is *not*
 *     treated as empty: it matches no pattern and falls through to UNKNOWN,
 *     mirroring Python's `if not text` and Swift's `!statement.isEmpty` guards.)
 */
object DataAvailabilityAnalyzer {

    fun analyze(statement: String?): DataAvailabilityResult {
        if (statement.isNullOrEmpty()) return DataAvailabilityResult.NOT_STATED

        val lower = statement.lowercase()

        // A refusal/unavailability signal anywhere overrides a co-occurring
        // repository/affirmation mention, so detect it up front and skip Step 1.
        val hasUnavailabilitySignal = RegexHelper.anyMatch(
            DataRepositoryPatterns.effectivelyUnavailablePatterns +
                DataRepositoryPatterns.strongRefusalPatterns,
            lower,
        )

        // --- Step 1: full open access ---
        if (!hasUnavailabilitySignal) {
            checkFullOpenAccess(statement, lower)?.let { return it }
        }

        // --- Step 2: effectively unavailable ---
        val effectivelyUnavailableSignals =
            orderedRestrictionLabels(DataRepositoryPatterns.effectivelyUnavailablePatterns, lower)
        val strongRefusalFound =
            RegexHelper.anyMatch(DataRepositoryPatterns.strongRefusalPatterns, lower)

        if (effectivelyUnavailableSignals.isNotEmpty() || strongRefusalFound) {
            val restrictions = effectivelyUnavailableSignals.toMutableList()
            for (label in extractRestrictions(lower)) {
                if (label !in restrictions) restrictions.add(label)
            }
            return DataAvailabilityResult(
                statement = statement,
                disclosureLevel = DataDisclosureLevel.NOT_AVAILABLE,
                restrictions = restrictions,
            )
        }

        // --- Step 3: restricted / on-request ---
        val restrictions = extractRestrictions(lower)
        if (restrictions.isNotEmpty()) {
            return DataAvailabilityResult(
                statement = statement,
                disclosureLevel = DataDisclosureLevel.RESTRICTED,
                restrictions = restrictions,
            )
        }

        // --- Step 4: unknown ---
        return DataAvailabilityResult(
            statement = statement,
            disclosureLevel = DataDisclosureLevel.UNKNOWN,
        )
    }

    private fun checkFullOpenAccess(statement: String, lower: String): DataAvailabilityResult? {
        for (pattern in DataRepositoryPatterns.fullOpenPatterns) {
            if (RegexHelper.matches(pattern, lower)) {
                return DataAvailabilityResult(
                    statement = statement,
                    disclosureLevel = DataDisclosureLevel.FULL_OPEN,
                    repositoryName = detectRepositoryName(lower),
                    repositoryUrl = extractUrl(statement),
                    accessionNumber = extractAccessionNumber(statement),
                )
            }
        }
        return null
    }

    private fun extractUrl(text: String): String? =
        RegexHelper.firstMatch(DataRepositoryPatterns.urlPattern, text)

    private fun extractAccessionNumber(text: String): String? =
        RegexHelper.firstGroup(DataRepositoryPatterns.accessionPattern, text, ignoreCase = true)

    private fun detectRepositoryName(lower: String): String? {
        for ((pattern, name) in DataRepositoryPatterns.repositoryMappings) {
            if (RegexHelper.matches(pattern, lower)) return name
        }
        return null
    }

    private fun extractRestrictions(lower: String): List<String> =
        orderedRestrictionLabels(DataRepositoryPatterns.restrictedPatterns, lower)

    /** Labels for matched [patterns], in pattern order, order-preserving deduplicated. */
    private fun orderedRestrictionLabels(patterns: List<String>, lower: String): List<String> {
        val labels = mutableListOf<String>()
        for (pattern in patterns) {
            if (RegexHelper.matches(pattern, lower)) {
                val label = DataRepositoryPatterns.restrictionLabel(pattern)
                if (label !in labels) labels.add(label)
            }
        }
        return labels
    }
}
