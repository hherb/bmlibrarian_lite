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

import io.mockk.coEvery
import io.mockk.mockk

/**
 * A PMC open-data bucket that holds nothing, for chain tests about other tiers.
 *
 * Stubbed explicitly: a relaxed MockK answers a suspend call returning a sealed
 * type with null, which the chain's exhaustive `when` would not survive.
 *
 * @return A bucket that answers [PmcOpenDataFetch.Absent] for every PMC ID
 */
internal fun absentBucket(): PmcOpenDataService = mockk {
    coEvery { fetchXml(any()) } returns PmcOpenDataFetch.Absent
}
