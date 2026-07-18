package com.bmlibrarian.factchecker.domain.transparency

/**
 * Data-availability pattern lists and restriction labels.
 *
 * Ported verbatim from the canonical Python reference (`DATA_REPOSITORIES`,
 * `STRONG_REFUSAL_PATTERNS`, `_restriction_labels` in
 * `study_transparency_analyzer.py`) and cross-checked against the Swift
 * `DataRepositoryPatterns` (BioMedLit), so a statement classifies identically
 * on all three platforms. List order is significant: it determines the order of
 * the human-readable restriction labels.
 */
object DataRepositoryPatterns {

    /** Full open indicators: repository names plus #113 open-availability affirmations. */
    val fullOpenPatterns: List<String> = listOf(
        "zenodo",
        "figshare",
        "dryad",
        "osf\\.io",
        "open science framework",
        "github",
        "gitlab",
        "dataverse",
        "mendeley data",
        "gene expression omnibus",
        "\\bgeo\\b",
        "arrayexpress",
        "protein data bank",
        "\\bpdb\\b",
        "genbank",
        "\\bsra\\b",
        "european nucleotide archive",
        "\\bena\\b",
        "clinicalstudydatarequest",
        "vivli",
        "yoda",
        // Open-availability affirmations (issue #113): genuinely-open statements
        // that name no repository but explicitly affirm open access. Deliberately
        // narrow — bare "available" is not matched. The (?<!not ) lookbehind
        // guards against a negated affirmation ("not openly accessible") falsely
        // matching FULL_OPEN (issue #113 review).
        "(?<!not )openly (?:available|shared|accessible)",
        "(?<!not )freely (?:available|shared|accessible)",
        "(?<!not )available (?:in|within|as|via|through) (?:the )?supplement",
    )

    /**
     * Negated open-availability affirmations (issue #117).
     *
     * The `(?<!not )` lookbehind carried by [fullOpenPatterns] is fixed-width, so
     * it only suppresses an *immediately* negated affirmation. Every detached
     * negator escaped it and produced a false FULL_OPEN — the dangerous
     * over-stating-openness direction:
     *
     *   "data are not currently openly available"  (intervening word)
     *   "data were never openly shared"            (alternate negator)
     *   "data are not  openly available"           (doubled whitespace)
     *   "the data could not be openly shared"      (modal outside the
     *                                               strong-refusal alternation)
     *
     * Python's `re` forbids variable-length lookbehind, and these patterns must
     * stay byte-identical across Python/Swift/Android, so widening the lookbehind
     * is not available. The guard is therefore expressed as a *forward* match: a
     * negator, then at most two intervening words, then the affirmation.
     *
     * The window is bounded rather than open-ended, and the
     * `(?!and\b|but\b|or\b)` barrier terminates the negation scope at a
     * coordinating conjunction. Both keep the check from reaching into an
     * affirmation the negator does not govern ("data were not embargoed **and**
     * were openly shared" stays FULL_OPEN), which would under-report genuinely
     * open data.
     *
     * Byte-identical to Python's `NEGATED_OPENNESS_PATTERNS` and the Swift
     * `DataRepositoryPatterns.negatedOpennessPatterns`. [RegexHelper] compiles
     * these with `(?U)`, so `\w` and `\b` match Unicode exactly as Python and
     * ICU do.
     *
     * Declared before [restrictedPatterns] because Kotlin initialises `object`
     * properties in declaration order — a forward reference would be null here.
     */
    val negatedOpennessPatterns: List<String> = listOf(
        "\\b(?:not|never|cannot)\\b(?:\\s+(?!and\\b|but\\b|or\\b)\\w+){0,2}\\s+" +
            "(?:openly|freely) (?:available|shared|accessible)",
        "\\b(?:not|never|cannot)\\b(?:\\s+(?!and\\b|but\\b|or\\b)\\w+){0,2}\\s+" +
            "available (?:in|within|as|via|through) (?:the )?supplement",
    )

    /** Restricted / on-request indicators. */
    val restrictedPatterns: List<String> = listOf(
        "upon (?:reasonable )?request",
        "available from (?:the )?(?:corresponding )?author",
        "contact (?:the )?(?:corresponding )?author",
        "data sharing agreement",
        "institutional review board",
        "irb approval",
        "ethics committee",
        "confidential(?:ity)?",
        "proprietary",
        "cannot be (?:\\w+ )?shared",
        "not (?:publicly )?available",
        "(?:would|will|shall) not be (?:\\w+ )?(?:released|shared|disclosed|provided)",
        "not be released to others",
        "requests?\\s+(?:for\\s+)?(?:such\\s+)?data\\s+should\\s+be\\s+made\\s+(?:directly\\s+)?to",
        "on the understanding that\\b.*\\bnot\\b",
        "used only for the purpose of\\b",
        "agreements?\\s+(?:with\\s+)?(?:the\\s+)?sponsors?\\s+prevent",
        "confidentiality\\s+agreements?\\s+(?:with\\s+)?sponsors?",
        "data\\s+custodians?\\b",
        "\\bgdpr\\b",
        "\\bhipaa\\b",
        "\\bprivacy\\b",
        "\\bpatient consent\\b",
        // Negated open-availability affirmations (issue #117). Listed here so a
        // bare negated affirmation ("data were never openly shared") carries an
        // explicit restriction label and classifies RESTRICTED, matching the
        // already-pinned adjacent form ("not openly accessible without IRB
        // approval"). See negatedOpennessPatterns for the rationale.
    ) + negatedOpennessPatterns

    /** Strong-refusal indicators that escalate to NOT_AVAILABLE. Subset of restricted. */
    val strongRefusalPatterns: List<String> = listOf(
        "cannot be (?:\\w+ )?shared",
        "not (?:publicly )?available",
        "proprietary",
        "(?:would|will|shall) not be (?:\\w+ )?(?:released|shared|disclosed|provided)",
        "not be released to others",
        "agreements?\\s+(?:with\\s+)?(?:the\\s+)?sponsors?\\s+prevent",
        "confidentiality\\s+agreements?\\s+(?:with\\s+)?sponsors?",
    )

    /** Patterns indicating an effectively unavailable dataset. */
    val effectivelyUnavailablePatterns: List<String> = listOf(
        "(?:provided|available)\\s+to\\s+the\\s+\\w+\\s+(?:collaboration|consortium|group)\\s+on\\s+the\\s+understanding",
        "not be released.*(?:data custodians?|directly to)",
        "(?:confidentiality|agreement)\\s+(?:with\\s+)?(?:the\\s+)?(?:sponsor|industri|pharma|trial\\s+(?:owner|sponsor))",
    )

    /** Human-readable restriction labels keyed by pattern (insertion order preserved). */
    val restrictionLabels: Map<String, String> = linkedMapOf(
        "cannot be (?:\\w+ )?shared" to "Data cannot be shared",
        "not (?:publicly )?available" to "Data not publicly available",
        "proprietary" to "Data described as proprietary",
        "(?:would|will|shall) not be (?:\\w+ )?(?:released|shared|disclosed|provided)" to "Data will not be released",
        "not be released to others" to "Data will not be released to others",
        "agreements?\\s+(?:with\\s+)?(?:the\\s+)?sponsors?\\s+prevent" to "Sponsor agreements prevent disclosure",
        "confidentiality\\s+agreements?\\s+(?:with\\s+)?sponsors?" to "Confidentiality agreements with sponsors",
        "upon (?:reasonable )?request" to "Available upon request",
        "available from (?:the )?(?:corresponding )?author" to "Available from author",
        "contact (?:the )?(?:corresponding )?author" to "Contact corresponding author",
        "data sharing agreement" to "Requires data sharing agreement",
        "institutional review board" to "Requires IRB approval",
        "irb approval" to "Requires IRB approval",
        "ethics committee" to "Requires ethics committee approval",
        "confidential(?:ity)?" to "Confidentiality restrictions",
        "requests?\\s+(?:for\\s+)?(?:such\\s+)?data\\s+should\\s+be\\s+made\\s+(?:directly\\s+)?to" to "Data requests redirected to third party",
        "on the understanding that\\b.*\\bnot\\b" to "Data provided under restrictive understanding",
        "used only for the purpose of\\b" to "Data restricted to specific purpose",
        "data\\s+custodians?\\b" to "Data held by custodians (not authors)",
        "\\bgdpr\\b" to "GDPR restrictions",
        "\\bhipaa\\b" to "HIPAA restrictions",
        "\\bprivacy\\b" to "Privacy restrictions",
        "\\bpatient consent\\b" to "Patient consent required",
        negatedOpennessPatterns[0] to "Data not openly available",
        negatedOpennessPatterns[1] to "Data not openly available",
        "(?:provided|available)\\s+to\\s+the\\s+\\w+\\s+(?:collaboration|consortium|group)\\s+on\\s+the\\s+understanding" to "Data restricted to named collaboration",
        "not be released.*(?:data custodians?|directly to)" to "Data will not be released; requests redirected",
        "(?:confidentiality|agreement)\\s+(?:with\\s+)?(?:the\\s+)?(?:sponsor|industri|pharma|trial\\s+(?:owner|sponsor))" to "Sponsor confidentiality agreement restricts access",
    )

    /**
     * Repository display-name mapping. Swift-only display path (#107) with no
     * Python counterpart; short tokens word-anchored so an unrelated word cannot
     * mislabel the repository.
     */
    val repositoryMappings: List<Pair<String, String>> = listOf(
        "zenodo" to "Zenodo",
        "figshare" to "Figshare",
        "dryad" to "Dryad",
        "osf" to "Open Science Framework",
        "github" to "GitHub",
        "gitlab" to "GitLab",
        "dataverse" to "Dataverse",
        "gene expression omnibus" to "Gene Expression Omnibus",
        "\\bgeo\\b" to "GEO",
        "arrayexpress" to "ArrayExpress",
        "genbank" to "GenBank",
        "\\bsra\\b" to "Sequence Read Archive",
        "vivli" to "Vivli",
        "yoda" to "YODA Project",
        "mendeley data" to "Mendeley Data",
        "protein data bank" to "Protein Data Bank",
        "\\bpdb\\b" to "PDB",
        "european nucleotide archive" to "European Nucleotide Archive",
        "\\bena\\b" to "ENA",
        "clinicalstudydatarequest" to "ClinicalStudyDataRequest.com",
    )

    const val urlPattern: String = "https?://[^\\s<>\"]+"
    const val accessionPattern: String = "(?:accession|identifier)[:\\s]+([A-Z0-9]+)"

    /** Human-readable label for a matched restriction [pattern] (falls back to the pattern). */
    fun restrictionLabel(pattern: String): String = restrictionLabels[pattern] ?: pattern
}
