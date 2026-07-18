# Android Data-Availability Transparency Classifier (Slice 1, #116) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the canonical (Python, Swift-mirrored) data-availability classifier to pure Kotlin so an identical statement classifies to the identical `DataDisclosureLevel` and restriction labels on Android, in a new `domain/transparency/` package with mirrored JUnit4 tests.

**Architecture:** Five focused Kotlin files in one package — an enum, a result data class, a regex helper `object`, a pattern-constants `object`, and a stateless analyzer `object`. The analyzer runs the same priority tiers as `analyze_data_availability`/`DataAvailabilityAnalyzer.analyze`. Pattern literals are copied verbatim from the Python source (and cross-checked against Swift), including the three #113 open-availability affirmations. No network, UI, Room, JATS, or DI changes.

**Tech Stack:** Kotlin (stdlib `Regex` only), Android Gradle module, JUnit4 (`org.junit`).

## Global Constraints

- **Depends on #113 (PR 1) landing first.** This port includes the three #113 open-availability affirmation patterns from the start and asserts the fixed behavior. Land PR 1 before finalizing this PR so the canonical reference already carries the fix.
- Byte-identical parity with the canonical Python `study_transparency_analyzer.py` (`DATA_REPOSITORIES`, `STRONG_REFUSAL_PATTERNS`, `_restriction_labels`); cross-check against Swift `DataRepositoryPatterns`. Kotlin string literals escape backslashes (`\\b`, `\\s`, `\\w`).
- **List order is significant** — it drives restriction-label ordering. Use `listOf`/`mapOf` preserving insertion order.
- Package: `com.bmlibrarian.factchecker.domain.transparency`.
- Main path: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/`. Test path: `android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/`.
- Tests: JUnit4, backtick method names, `org.junit.Assert.*`, `// ==== section ====` banners (matches `CostCalculatorTest`).
- Pure Kotlin stdlib only; no new dependencies.
- Classification matches the **lowercased** statement against lowercase patterns (no `IGNORE_CASE`), mirroring Python's `re.search(pattern, text_lower)`. URL extraction is case-sensitive group 0 on the original text; accession extraction is `IGNORE_CASE` group 1 on the original text.
- Run all Gradle commands from `android/MedicalFactChecker/`. Targeted test run: `./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.*"`.
- Branch: `feat/android-data-availability-classifier-116`. Spec: `docs/superpowers/specs/2026-07-17-android-data-availability-classifier-design.md`.

---

### Task 1: Enum + result model

**Files:**
- Create: `.../domain/transparency/DataDisclosureLevel.kt`
- Create: `.../domain/transparency/DataAvailabilityResult.kt`
- Test: `.../domain/transparency/DataAvailabilityModelsTest.kt`

**Interfaces:**
- Produces: `enum class DataDisclosureLevel(val rawValue: String, val displayName: String)` with cases `FULL_OPEN, AVAILABLE_ON_REQUEST, RESTRICTED, NOT_AVAILABLE, NOT_STATED, UNKNOWN`; `data class DataAvailabilityResult(statement: String?, disclosureLevel: DataDisclosureLevel, repositoryName: String?, repositoryUrl: String?, accessionNumber: String?, restrictions: List<String>)` with `DataAvailabilityResult.NOT_STATED`.

- [ ] **Step 1: Write the failing test**

Create `.../domain/transparency/DataAvailabilityModelsTest.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataAvailabilityModelsTest {

    @Test
    fun `disclosure level raw values match cross-platform contract`() {
        assertEquals("full_open", DataDisclosureLevel.FULL_OPEN.rawValue)
        assertEquals("on_request", DataDisclosureLevel.AVAILABLE_ON_REQUEST.rawValue)
        assertEquals("restricted", DataDisclosureLevel.RESTRICTED.rawValue)
        assertEquals("not_available", DataDisclosureLevel.NOT_AVAILABLE.rawValue)
        assertEquals("not_stated", DataDisclosureLevel.NOT_STATED.rawValue)
        assertEquals("unknown", DataDisclosureLevel.UNKNOWN.rawValue)
    }

    @Test
    fun `result defaults are unknown and empty`() {
        val result = DataAvailabilityResult()
        assertEquals(DataDisclosureLevel.UNKNOWN, result.disclosureLevel)
        assertTrue(result.restrictions.isEmpty())
    }

    @Test
    fun `not stated companion carries not stated level`() {
        assertEquals(DataDisclosureLevel.NOT_STATED, DataAvailabilityResult.NOT_STATED.disclosureLevel)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataAvailabilityModelsTest"`
Expected: FAIL — unresolved reference `DataDisclosureLevel` / `DataAvailabilityResult`.

- [ ] **Step 3: Write the enum**

Create `.../domain/transparency/DataDisclosureLevel.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

/**
 * Classification of how openly a study's underlying data is shared.
 *
 * Raw values and semantics mirror the canonical Python `DataDisclosureLevel`
 * (`study_transparency_analyzer.py`) and the Swift `DataDisclosureLevel`
 * (BioMedLit), so a statement classifies identically on all three platforms.
 */
enum class DataDisclosureLevel(val rawValue: String, val displayName: String) {
    /** Data deposited in a public repository or explicitly openly available. */
    FULL_OPEN("full_open", "Fully Open"),

    /**
     * Available upon reasonable request. Never emitted by
     * [DataAvailabilityAnalyzer.analyze] (on-request phrasing maps to
     * [RESTRICTED]); retained for later scoring and externally-constructed
     * results, matching Python/Swift.
     */
    AVAILABLE_ON_REQUEST("on_request", "Available on Request"),

    /** Significant access restrictions (IRB, ethics, privacy/legal, on request). */
    RESTRICTED("restricted", "Restricted"),

    /** Effectively unavailable — a sharing statement that amounts to a refusal. */
    NOT_AVAILABLE("not_available", "Not Available"),

    /** No data-availability statement present. */
    NOT_STATED("not_stated", "Not Stated"),

    /** A statement exists but no pattern matched. */
    UNKNOWN("unknown", "Unknown"),
}
```

Create `.../domain/transparency/DataAvailabilityResult.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

/**
 * Result of analyzing a data-availability statement.
 *
 * Mirrors the canonical Python `DataAvailabilityInfo` and the Swift
 * `DataAvailabilityResult`. [repositoryUrl] is the raw matched [String] (as in
 * Python) rather than a parsed URL type.
 */
data class DataAvailabilityResult(
    val statement: String? = null,
    val disclosureLevel: DataDisclosureLevel = DataDisclosureLevel.UNKNOWN,
    val repositoryName: String? = null,
    val repositoryUrl: String? = null,
    val accessionNumber: String? = null,
    val restrictions: List<String> = emptyList(),
) {
    companion object {
        /** No data-availability statement present. */
        val NOT_STATED = DataAvailabilityResult(
            disclosureLevel = DataDisclosureLevel.NOT_STATED,
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataAvailabilityModelsTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/DataDisclosureLevel.kt android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/DataAvailabilityResult.kt android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/DataAvailabilityModelsTest.kt
git commit -m "feat(transparency): Android DataDisclosureLevel + DataAvailabilityResult (#116)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: RegexHelper

**Files:**
- Create: `.../domain/transparency/RegexHelper.kt`
- Test: `.../domain/transparency/RegexHelperTest.kt`

**Interfaces:**
- Produces: `object RegexHelper` with `fun anyMatch(patterns: List<String>, text: String): Boolean`, `fun firstMatch(pattern: String, text: String): String?`, `fun firstGroup(pattern: String, text: String, ignoreCase: Boolean = false): String?`.

- [ ] **Step 1: Write the failing test**

Create `.../domain/transparency/RegexHelperTest.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RegexHelperTest {

    @Test
    fun `anyMatch finds a pattern anywhere in text`() {
        assertTrue(RegexHelper.anyMatch(listOf("zenodo", "figshare"), "deposited in figshare today"))
        assertFalse(RegexHelper.anyMatch(listOf("zenodo"), "no repository named here"))
    }

    @Test
    fun `anyMatch respects word boundaries`() {
        assertTrue(RegexHelper.anyMatch(listOf("\\bgeo\\b"), "deposited in geo"))
        assertFalse(RegexHelper.anyMatch(listOf("\\bgeo\\b"), "across geographic regions"))
    }

    @Test
    fun `firstMatch returns the whole first match`() {
        assertEquals(
            "https://zenodo.org/record/42",
            RegexHelper.firstMatch("https?://[^\\s<>\"]+", "see https://zenodo.org/record/42 for data"),
        )
        assertNull(RegexHelper.firstMatch("https?://[^\\s<>\"]+", "no url here"))
    }

    @Test
    fun `firstGroup returns capture group one with optional ignore case`() {
        assertEquals(
            "GSE123",
            RegexHelper.firstGroup("(?:accession|identifier)[:\\s]+([A-Z0-9]+)", "under accession GSE123", ignoreCase = true),
        )
        assertNull(RegexHelper.firstGroup("(?:accession|identifier)[:\\s]+([A-Z0-9]+)", "no accession stated", ignoreCase = true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.RegexHelperTest"`
Expected: FAIL — unresolved reference `RegexHelper`.

- [ ] **Step 3: Write the implementation**

Create `.../domain/transparency/RegexHelper.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

/**
 * Small regex helpers shared by the transparency analyzers.
 *
 * Classification patterns are matched against text that has already been
 * lowercased (the patterns themselves are lowercase), mirroring the Python
 * reference's `re.search(pattern, text_lower)`. No compiled-pattern caching —
 * single-statement labeling is not a hot path (see the Swift #111 follow-up).
 */
object RegexHelper {

    /** True if any [patterns] entry occurs anywhere in [text]. */
    fun anyMatch(patterns: List<String>, text: String): Boolean =
        patterns.any { Regex(it).containsMatchIn(text) }

    /** The full first match of [pattern] in [text], or null. */
    fun firstMatch(pattern: String, text: String): String? =
        Regex(pattern).find(text)?.value

    /**
     * Capture group 1 of the first match of [pattern] in [text], or null.
     * [ignoreCase] mirrors Python's `re.I`, used for accession extraction.
     */
    fun firstGroup(pattern: String, text: String, ignoreCase: Boolean = false): String? {
        val regex = if (ignoreCase) Regex(pattern, RegexOption.IGNORE_CASE) else Regex(pattern)
        return regex.find(text)?.groupValues?.getOrNull(1)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.RegexHelperTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/RegexHelper.kt android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/RegexHelperTest.kt
git commit -m "feat(transparency): Android RegexHelper for pattern matching (#116)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: DataRepositoryPatterns

**Files:**
- Create: `.../domain/transparency/DataRepositoryPatterns.kt`
- Test: `.../domain/transparency/DataRepositoryPatternsTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces: `object DataRepositoryPatterns` with `val fullOpenPatterns: List<String>` (24), `val restrictedPatterns: List<String>` (23), `val strongRefusalPatterns: List<String>` (7), `val effectivelyUnavailablePatterns: List<String>` (3), `val restrictionLabels: Map<String, String>`, `val repositoryMappings: List<Pair<String, String>>` (20), `const val urlPattern: String`, `const val accessionPattern: String`, `fun restrictionLabel(pattern: String): String`.

- [ ] **Step 1: Write the failing test**

Create `.../domain/transparency/DataRepositoryPatternsTest.kt`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataRepositoryPatternsTest {

    // ==================== full-open ====================

    @Test
    fun `full open patterns include repositories and #113 affirmations`() {
        val p = DataRepositoryPatterns.fullOpenPatterns
        assertTrue(p.contains("zenodo"))
        assertTrue(p.contains("\\bgeo\\b"))
        assertTrue(p.contains("(?<!not )openly (?:available|shared|accessible)"))
        assertTrue(p.contains("(?<!not )freely (?:available|shared|accessible)"))
        assertTrue(p.contains("(?<!not )available (?:in|within|as|via|through) (?:the )?supplement"))
        assertEquals(24, p.size)
    }

    // ==================== restricted / refusal ====================

    @Test
    fun `restricted patterns include the #104 privacy legal set`() {
        val p = DataRepositoryPatterns.restrictedPatterns
        assertTrue(p.contains("\\bgdpr\\b"))
        assertTrue(p.contains("\\bhipaa\\b"))
        assertTrue(p.contains("\\bprivacy\\b"))
        assertTrue(p.contains("\\bpatient consent\\b"))
        assertEquals(23, p.size)
    }

    @Test
    fun `strong refusal is a subset of restricted`() {
        assertEquals(7, DataRepositoryPatterns.strongRefusalPatterns.size)
        assertTrue(
            DataRepositoryPatterns.restrictedPatterns
                .containsAll(DataRepositoryPatterns.strongRefusalPatterns),
        )
    }

    @Test
    fun `effectively unavailable has three patterns`() {
        assertEquals(3, DataRepositoryPatterns.effectivelyUnavailablePatterns.size)
    }

    // ==================== labels ====================

    @Test
    fun `restriction label lookup returns mapped labels`() {
        assertEquals("GDPR restrictions", DataRepositoryPatterns.restrictionLabel("\\bgdpr\\b"))
        assertEquals("Requires IRB approval", DataRepositoryPatterns.restrictionLabel("institutional review board"))
        assertEquals("Requires IRB approval", DataRepositoryPatterns.restrictionLabel("irb approval"))
    }

    @Test
    fun `restriction label falls back to the pattern when unmapped`() {
        assertEquals("unmapped-pattern", DataRepositoryPatterns.restrictionLabel("unmapped-pattern"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataRepositoryPatternsTest"`
Expected: FAIL — unresolved reference `DataRepositoryPatterns`.

- [ ] **Step 3: Write the implementation**

Create `.../domain/transparency/DataRepositoryPatterns.kt`. **Copy the pattern literals verbatim from the Python source; do not retype from memory.** Cross-check each list against `DATA_REPOSITORIES` / `STRONG_REFUSAL_PATTERNS` / `_restriction_labels` in `study_transparency_analyzer.py` and against Swift `DataRepositoryPatterns`.

```kotlin
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
    )

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataRepositoryPatternsTest"`
Expected: PASS. If a size assertion fails, a pattern was dropped/duplicated — diff the list against the Python source before changing the test.

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/DataRepositoryPatterns.kt android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/DataRepositoryPatternsTest.kt
git commit -m "feat(transparency): Android DataRepositoryPatterns (byte-parity, incl. #113) (#116)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: DataAvailabilityAnalyzer

**Files:**
- Create: `.../domain/transparency/DataAvailabilityAnalyzer.kt`
- Test: `.../domain/transparency/DataAvailabilityAnalyzerTest.kt`

**Interfaces:**
- Consumes: `DataDisclosureLevel`, `DataAvailabilityResult` (Task 1); `RegexHelper` (Task 2); `DataRepositoryPatterns` (Task 3).
- Produces: `object DataAvailabilityAnalyzer` with `fun analyze(statement: String?): DataAvailabilityResult`.

- [ ] **Step 1: Write the failing test**

Create `.../domain/transparency/DataAvailabilityAnalyzerTest.kt`. Statements mirror the canonical Python `TestAnalyzeDataAvailability` and Swift `DataAvailabilityAnalyzerTests`:

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataAvailabilityAnalyzerTest {

    private fun analyze(statement: String?) = DataAvailabilityAnalyzer.analyze(statement)

    // ==================== classification tiers ====================

    @Test
    fun `empty statement is not stated`() {
        assertEquals(DataDisclosureLevel.NOT_STATED, analyze(null).disclosureLevel)
        assertEquals(DataDisclosureLevel.NOT_STATED, analyze("").disclosureLevel)
    }

    @Test
    fun `public repository is full open`() {
        assertEquals(DataDisclosureLevel.FULL_OPEN, analyze("Data deposited in Zenodo.").disclosureLevel)
    }

    @Test
    fun `on request is restricted not available on request`() {
        val result = analyze("Data available upon reasonable request from the corresponding author.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertTrue(result.restrictions.isNotEmpty())
    }

    @Test
    fun `ethics committee is restricted`() {
        assertEquals(
            DataDisclosureLevel.RESTRICTED,
            analyze("Data access requires ethics committee approval.").disclosureLevel,
        )
    }

    @Test
    fun `strong refusal is not available`() {
        val result = analyze("Individual patient data will not be released to others.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertTrue(result.restrictions.isNotEmpty())
    }

    @Test
    fun `sponsor confidentiality is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Confidentiality agreements with sponsors prevent data disclosure.").disclosureLevel,
        )
    }

    @Test
    fun `named collaboration lock is not available with ordered restrictions`() {
        val result = analyze(
            "Data are provided to the CORE consortium on the understanding that they are not shared.",
        )
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertEquals(
            listOf(
                "Data restricted to named collaboration",
                "Data provided under restrictive understanding",
            ),
            result.restrictions,
        )
    }

    @Test
    fun `ambiguous statement is unknown`() {
        assertEquals(
            DataDisclosureLevel.UNKNOWN,
            analyze("The study data is maintained by the research team.").disclosureLevel,
        )
    }

    // ==================== #113 open-availability affirmations ====================

    @Test
    fun `open affirmation without repository is full open`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("De-identified data are openly shared; no HIPAA-protected identifiers remain.").disclosureLevel,
        )
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("All data are available in the supplementary materials; patient privacy was protected throughout.").disclosureLevel,
        )
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("The complete dataset is freely available to all researchers.").disclosureLevel,
        )
    }

    @Test
    fun `open affirmation with strong refusal is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Data are freely available in summary form but the individual-level data cannot be shared.").disclosureLevel,
        )
    }

    @Test
    fun `negated affirmation does not trigger full open`() {
        // Immediate "not " before the affirmation adverb is blocked by (?<!not ),
        // so these fall through to the normal tiers (#113 review).
        val irb = analyze("Raw data are not openly accessible without IRB approval.")
        assertEquals(DataDisclosureLevel.RESTRICTED, irb.disclosureLevel)
        assertEquals(listOf("Requires IRB approval"), irb.restrictions)

        val author = analyze("Data are not freely shared; available from the corresponding author.")
        assertEquals(DataDisclosureLevel.RESTRICTED, author.disclosureLevel)

        val notOpen = analyze("The data are not openly available.")
        assertNotEquals(DataDisclosureLevel.FULL_OPEN, notOpen.disclosureLevel)
    }

    @Test
    fun `non-adjacent negated affirmation is not available`() {
        // One intervening adverb ("will not be openly shared", "cannot be openly
        // shared") is caught by the (?:\w+ )?-broadened strong-refusal patterns
        // → NOT_AVAILABLE (#113 review).
        val willNot = analyze("The data will not be openly shared with third parties.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, willNot.disclosureLevel)
        assertEquals(listOf("Data will not be released"), willNot.restrictions)

        val cannot = analyze("Raw data cannot be openly shared.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, cannot.disclosureLevel)
        assertEquals(listOf("Data cannot be shared"), cannot.restrictions)
    }

    // ==================== privacy/legal restricted-tier (#104) ====================

    @Test
    fun `gdpr restriction is restricted`() {
        val result = analyze("Individual patient data are restricted under GDPR.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("GDPR restrictions"), result.restrictions)
    }

    @Test
    fun `hipaa restriction is restricted`() {
        val result = analyze("Access to the dataset is limited by HIPAA.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("HIPAA restrictions"), result.restrictions)
    }

    @Test
    fun `privacy restriction is restricted`() {
        val result = analyze("Sharing is constrained by participant privacy considerations.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Privacy restrictions"), result.restrictions)
    }

    @Test
    fun `patient consent restriction is restricted`() {
        val result = analyze("Data access requires patient consent.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Patient consent required"), result.restrictions)
    }

    @Test
    fun `privacy does not override full open repository`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze("Data are deposited in Zenodo; no privacy concerns were identified.").disclosureLevel,
        )
    }

    @Test
    fun `gdpr with strong refusal is not available`() {
        val result = analyze("The data are not publicly available owing to GDPR.")
        assertEquals(DataDisclosureLevel.NOT_AVAILABLE, result.disclosureLevel)
        assertTrue(result.restrictions.contains("Data not publicly available"))
        assertTrue(result.restrictions.contains("GDPR restrictions"))
    }

    // ==================== short-token over-match guards (#106/#108) ====================

    @Test
    fun `geographic word does not trigger full open`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Geographic data underlying this study are not publicly available.").disclosureLevel,
        )
    }

    @Test
    fun `phenomena word does not trigger full open`() {
        assertEquals(
            DataDisclosureLevel.RESTRICTED,
            analyze("The phenomena studied are described; data available upon request from the corresponding author.").disclosureLevel,
        )
    }

    @Test
    fun `standalone short tokens still full open`() {
        for (token in listOf("GEO", "SRA", "ENA", "PDB")) {
            assertEquals(
                "token $token",
                DataDisclosureLevel.FULL_OPEN,
                analyze("Raw data have been deposited in $token under accession XYZ123.").disclosureLevel,
            )
        }
    }

    @Test
    fun `short tokens embedded in words are not full open`() {
        for (word in listOf("misranked", "compdb")) {
            assertNotEquals(
                "word $word",
                DataDisclosureLevel.FULL_OPEN,
                analyze("The $word results are summarized in the manuscript text.").disclosureLevel,
            )
        }
    }

    // ==================== repository name overridden by refusal (#106/#108) ====================

    @Test
    fun `repository named but access refused is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze(
                "Sequencing data could not be deposited in GEO for privacy reasons; the individual patient data cannot be shared.",
            ).disclosureLevel,
        )
    }

    @Test
    fun `repository named but not publicly available is not available`() {
        assertEquals(
            DataDisclosureLevel.NOT_AVAILABLE,
            analyze("Although GenBank was used during analysis, the data are not publicly available.").disclosureLevel,
        )
    }

    @Test
    fun `repository with soft request stays full open`() {
        assertEquals(
            DataDisclosureLevel.FULL_OPEN,
            analyze(
                "Processed data are available in GEO under accession GSE12345. " +
                    "Raw individual-level data are available from the corresponding author upon reasonable request.",
            ).disclosureLevel,
        )
    }

    // ==================== label dedup (#114) ====================

    @Test
    fun `restricted label sharing patterns deduplicated`() {
        val result = analyze("Access to the data requires institutional review board review and IRB approval.")
        assertEquals(DataDisclosureLevel.RESTRICTED, result.disclosureLevel)
        assertEquals(listOf("Requires IRB approval"), result.restrictions)
    }

    // ==================== extraction (repository name / url / accession) ====================

    @Test
    fun `full open detects repository name`() {
        assertEquals("GenBank", analyze("Sequences were deposited in GenBank.").repositoryName)
    }

    @Test
    fun `repository name not overmatched by geographic`() {
        val result = analyze("Geographic sequences were deposited in GenBank.")
        assertEquals(DataDisclosureLevel.FULL_OPEN, result.disclosureLevel)
        assertEquals("GenBank", result.repositoryName)
    }

    @Test
    fun `url and accession extracted for full open`() {
        val result = analyze("Data are in Zenodo at https://zenodo.org/record/42 under accession GSE99.")
        assertEquals("https://zenodo.org/record/42", result.repositoryUrl)
        assertEquals("GSE99", result.accessionNumber)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataAvailabilityAnalyzerTest"`
Expected: FAIL — unresolved reference `DataAvailabilityAnalyzer`.

- [ ] **Step 3: Write the implementation**

Create `.../domain/transparency/DataAvailabilityAnalyzer.kt`:

```kotlin
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
 *  5. Empty/blank input -> NOT_STATED.
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
            if (RegexHelper.anyMatch(listOf(pattern), lower)) {
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
            if (RegexHelper.anyMatch(listOf(pattern), lower)) return name
        }
        return null
    }

    private fun extractRestrictions(lower: String): List<String> =
        orderedRestrictionLabels(DataRepositoryPatterns.restrictedPatterns, lower)

    /** Labels for matched [patterns], in pattern order, order-preserving deduplicated. */
    private fun orderedRestrictionLabels(patterns: List<String>, lower: String): List<String> {
        val labels = mutableListOf<String>()
        for (pattern in patterns) {
            if (RegexHelper.anyMatch(listOf(pattern), lower)) {
                val label = DataRepositoryPatterns.restrictionLabel(pattern)
                if (label !in labels) labels.add(label)
            }
        }
        return labels
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests "com.bmlibrarian.factchecker.domain.transparency.DataAvailabilityAnalyzerTest"`
Expected: PASS (all classification, guard, extraction, and dedup cases).

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/DataAvailabilityAnalyzer.kt android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/DataAvailabilityAnalyzerTest.kt
git commit -m "feat(transparency): Android DataAvailabilityAnalyzer (byte-parity classifier) (#116)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full module test run, HANDOVER, PR

**Files:**
- Modify: `HANDOVER.md`

- [ ] **Step 1: Run the whole Android unit-test suite (no regressions)**

Run: `cd android/MedicalFactChecker && ./gradlew test`
Expected: BUILD SUCCESSFUL; the new `domain.transparency` tests and all pre-existing tests pass.

- [ ] **Step 2: Update HANDOVER.md**

Under "Recently landed", add an entry: Android data-availability classifier Slice 1 landed (#116) — `domain/transparency/` package with `DataDisclosureLevel`, `DataAvailabilityResult`, `RegexHelper`, `DataRepositoryPatterns`, `DataAvailabilityAnalyzer`, byte-parity with Python/Swift incl. the #113 affirmations, mirrored JUnit4 tests. Update the "Android transparency classifier" follow-up to note Slice 1 done and list the remaining slices (COI, scorer + risk indicators, funding/trial, JATS extraction, Room + UI) still tracked in #116.

- [ ] **Step 3: Commit HANDOVER**

```bash
git add HANDOVER.md
git commit -m "docs(handover): record Android data-availability classifier Slice 1 (#116)"
```

- [ ] **Step 4: Push and open the PR (Slice 1 of #116)**

```bash
git push -u origin feat/android-data-availability-classifier-116
gh pr create --base master --title "feat(transparency): Android data-availability classifier, Slice 1 (#116)" --body "Slice 1 of #116. Ports the canonical (Python, Swift-mirrored) data-availability classifier to pure Kotlin in a new domain/transparency package: DataDisclosureLevel, DataAvailabilityResult, RegexHelper, DataRepositoryPatterns, DataAvailabilityAnalyzer, with byte-identical pattern lists (including the #113 open-availability affirmations) and mirrored JUnit4 tests. No network/UI/Room/JATS. Builds on the #113 fix (PR 1). Later slices (COI, scorer + risk indicators, funding/trial, JATS extraction, Room + DocumentCard UI) tracked in #116.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

## Self-Review

- **Spec coverage:** package layout (Tasks 1–4 create the five files in `domain/transparency/`); enum + model with exact raw values (Task 1); RegexHelper with Python-mirroring semantics (Task 2); byte-parity pattern lists incl. #113 affirmations (Task 3); analyzer tiers + extraction (Task 4); mirrored test set covering every case listed in the spec's Testing section (Task 4 Step 1); the #113 dependency stated (Global Constraints); non-goals honored (no scoring/risk/COI/funding/trial/JATS/Room/UI). Verification via `./gradlew test` (Task 5). Covered.
- **Placeholder scan:** none — every step carries full code or an exact command with expected output. The one non-code instruction ("copy verbatim from the Python source", Task 3 Step 3) is deliberate parity guidance and the code block is still provided in full.
- **Type consistency:** `analyze(statement: String?)` return type `DataAvailabilityResult` consistent across Tasks 1/4; `DataDisclosureLevel` cases and raw values consistent between Task 1 (definition) and Tasks 3/4 (usage); `RegexHelper.anyMatch/firstMatch/firstGroup` signatures consistent between Task 2 (definition) and Task 4 (usage); `DataRepositoryPatterns` member names consistent between Task 3 (definition) and Task 4 (usage: `fullOpenPatterns`, `restrictedPatterns`, `strongRefusalPatterns`, `effectivelyUnavailablePatterns`, `repositoryMappings`, `urlPattern`, `accessionPattern`, `restrictionLabel`).
