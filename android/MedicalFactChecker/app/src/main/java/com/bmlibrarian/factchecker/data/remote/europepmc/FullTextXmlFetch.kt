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

package com.bmlibrarian.factchecker.data.remote.europepmc

import com.bmlibrarian.factchecker.domain.model.RequestFailure

/**
 * What asking Europe PMC's `fullTextXML` for an article produced (#434).
 *
 * Three outcomes, because they tell the reader three different things. A 404 is
 * Europe PMC's own answer. A throttle, an outage, a timeout or a blank 200 is our
 * failure to get one. All of these used to fail as one `FullTextUnavailableError`,
 * and the chain then marked the article unavailable for good.
 *
 * The type says what happened, not what it means: `fullTextXML` serves
 * open-access text only, so for an article Europe PMC holds, a 404 may mean "not
 * open access" rather than "no full text" (#432). Whether it settles the article
 * is the caller's call.
 *
 * Mirrors Python's `FullTextXmlFetch` in `europepmc.py`, the reference; the
 * contract is the "Retrieval" section of `doc/cross_platform/fulltext_retrieval.md`.
 */
sealed class FullTextXmlFetch {
    /**
     * Europe PMC served the JATS XML.
     *
     * @property xml The XML, never blank: a blank answer is [Unreachable] with
     *   an incomplete response
     * @throws IllegalArgumentException if [xml] is blank
     */
    data class Served(val xml: String) : FullTextXmlFetch() {
        init {
            require(xml.isNotBlank()) { "A blank full text is an incomplete answer, not an absence" }
        }
    }

    /** Europe PMC answered 404 for this accession. */
    data object Absent : FullTextXmlFetch()

    /**
     * Europe PMC's answer is missing: it could not be read, it held nothing, or
     * it was never asked because the identifier was not an accession.
     *
     * @property failure Why, of its real kind
     */
    data class Unreachable(val failure: RequestFailure) : FullTextXmlFetch()
}

/**
 * Turns an identifier into one `fullTextXML` can be asked about.
 *
 * Europe PMC serves full text under a PMC accession, and a preprint's under its
 * own `PPR` record ID: a preprint has no PMC ID, and a normaliser that only knew
 * PMC IDs left every preprint's full text unfetched. Mirrors Python's
 * `fulltext_accession`.
 */
object FullTextAccession {
    /** Prefix of a PubMed Central accession, e.g. `PMC1082889`. */
    const val PMC_PREFIX = "PMC"

    /** Prefix of a Europe PMC preprint record ID, e.g. `PPR1316954`. */
    const val PREPRINT_PREFIX = "PPR"

    // ASCII digits only: the value goes into a URL path, and \d would admit "PMC١٢٣".
    private val BARE_DIGITS = Regex("[0-9]+")

    /**
     * Normalise an untrusted identifier to the accession Europe PMC expects.
     *
     * Accepts `PMC123`, `pmc123` and `123` (all become `PMC123`) and `PPR123` in
     * any case (becomes `PPR123`), after trimming whitespace. Anything else is
     * refused, so the caller can record a request never made instead of sending a
     * malformed one (#355). The prefix test used to be case-sensitive, so `pmc123`
     * became `PMCpmc123`: a request Europe PMC answers 404, which read as an absence.
     *
     * @param identifier A PMC ID, with or without its prefix, or a preprint's record ID
     * @return For example "PMC12101959" or "PPR1316954", or null when it is neither
     */
    fun normalized(identifier: String): String? {
        val trimmed = identifier.trim()
        if (BARE_DIGITS.matches(trimmed)) return PMC_PREFIX + trimmed
        return prefixed(trimmed, PMC_PREFIX) ?: prefixed(trimmed, PREPRINT_PREFIX)
    }

    /**
     * An accession the value states by its own prefix, normalised.
     *
     * Stricter than [normalized], which reads bare digits as a PMC ID. That is
     * right for a field that holds PMC IDs, and wrong for an identifier that can
     * be a PubMed ID: there, `123` must not become `PMC123`.
     *
     * @param identifier The identifier, untrusted
     * @param prefix The upper-case ASCII prefix it must carry, such as [PREPRINT_PREFIX]
     * @return For example "PPR1316954", or null without that prefix
     */
    fun prefixed(identifier: String, prefix: String): String? {
        val trimmed = identifier.trim()
        if (trimmed.length <= prefix.length) return null
        val head = trimmed.substring(0, prefix.length)
        // Compared only when ASCII: case-mapping some characters changes their length
        if (!head.all { it.code < ASCII_LIMIT } || !head.equals(prefix, ignoreCase = true)) return null
        val digits = trimmed.substring(prefix.length)
        return if (BARE_DIGITS.matches(digits)) prefix + digits else null
    }

    /** Code points below this are ASCII. */
    private const val ASCII_LIMIT = 128
}
