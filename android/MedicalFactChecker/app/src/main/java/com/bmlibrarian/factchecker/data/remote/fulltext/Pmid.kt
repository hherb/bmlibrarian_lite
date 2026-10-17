/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.util.Constants

/**
 * What a caller's PMID value turned out to be (bmlib#470, bmlib#472, bmlib#478).
 *
 * @property pmid The canonical PMID (ASCII digits, no leading zeros), or null.
 * @property pmcId A PMC ID the caller passed as the PMID, or null.
 * @property refused Whether the value was given and is neither a PMID nor a PMC
 *   ID. A blank is no PMID, and is not refused.
 */
data class PmidReading(
    val pmid: String? = null,
    val pmcId: String? = null,
    val refused: Boolean = false
)

/**
 * A PMID is canonical ASCII digits, or it is not sent.
 *
 * A PMID reaches a Europe PMC `ext_id:` query, and Europe PMC finds nothing for
 * a padded `0033301246` while `1 OR 2` widens the query past its `src:med`
 * guard. The rules are Python's `identifiers.canonical_pmid`, and
 * `doc/cross_platform/fulltext_parity/pmid_canonical.json` is the contract all
 * three platforms' suites read.
 */
object Pmid {
    private val PMID_REGEX = Regex("[0-9]+")
    private const val PMC_PREFIX = "PMC"

    /**
     * Read a caller's PMID.
     *
     * Surrounding whitespace ([stripped]) is stripped and a blank is no PMID. ASCII digits
     * that are not all zeros are the PMID without their leading zeros; `PMC`
     * then ASCII digits is a PMC ID given as a PMID. Anything else is refused.
     * The digits are matched as `[0-9]`, never `\d` or `isDigit()`, which admit
     * Arabic-Indic and other digits.
     *
     * @param raw What the caller passed as the PMID.
     * @return The reading; it never throws.
     */
    fun canonical(raw: String): PmidReading {
        val text = stripped(raw)
        if (text.isEmpty()) return PmidReading()
        if (PMID_REGEX.matches(text)) {
            val stripped = text.trimStart('0')
            return if (stripped.isEmpty()) PmidReading(refused = true) else PmidReading(pmid = stripped)
        }
        if (text.startsWith(PMC_PREFIX) && PMID_REGEX.matches(text.removePrefix(PMC_PREFIX))) {
            return PmidReading(pmcId = text)
        }
        return PmidReading(refused = true)
    }

    /**
     * [raw] without the whitespace around it, as Python's `str.strip()` reads
     * whitespace: [Constants.PMID_STRIPPED_WHITESPACE], not `trim()`'s set, so
     * U+0085 is stripped and U+200B is not.
     *
     * @param raw The caller's value.
     * @return The value with surrounding whitespace removed.
     */
    fun stripped(raw: String): String = raw.trim { it.code in Constants.PMID_STRIPPED_WHITESPACE }

    /** Whether [value] is already a canonical PMID, as the Europe PMC lookup requires. */
    fun isCanonical(value: String): Boolean = canonical(value).pmid == value
}
