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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.util.Constants

/**
 * Which email, if any, Unpaywall can be asked with.
 *
 * Unpaywall identifies every caller by an email address and refuses the app's own
 * placeholder ([Constants.UNPAYWALL_DEFAULT_EMAIL]) with HTTP 422 for every
 * article. Sent anyway, that refusal read to the reader as "Unpaywall did not
 * serve it", blaming the article for our configuration and giving them no
 * advice. Treated as no email, the lookup is skipped and the reader is told
 * Unpaywall was not configured ([OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED]).
 * Python's `pdf_discovery.usable_unpaywall_email`.
 */
object UnpaywallContact {

    /**
     * The first candidate that is a usable address.
     *
     * @param candidates Configured addresses in order of preference; any may be
     *   blank, null or the placeholder
     * @return That address, trimmed, or null when none is usable
     */
    fun usableEmail(vararg candidates: String?): String? =
        candidates.firstNotNullOfOrNull { candidate ->
            candidate?.trim()?.takeIf { it.isNotEmpty() && it != Constants.UNPAYWALL_DEFAULT_EMAIL }
        }

    /**
     * The address to ask Unpaywall with: the Unpaywall email, or failing that the
     * NCBI email, the one the settings screen offers (iOS and macOS also ask
     * Unpaywall with it).
     *
     * @param settings The reader's settings
     * @return The address, or null when neither is usable
     */
    fun emailFor(settings: AppSettings): String? =
        usableEmail(settings.unpaywallEmail, settings.ncbiEmail)
}
