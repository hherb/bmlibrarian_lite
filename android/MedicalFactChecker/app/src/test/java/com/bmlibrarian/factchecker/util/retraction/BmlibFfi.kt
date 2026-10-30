// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import java.io.File
import org.junit.Assume.assumeTrue

/** For the tests that call bmlib's Rust: they skip without the host library, and CI requires that they ran. */
object BmlibFfi {
    /** Skip the calling test unless Gradle built the host library (`bmlib.dir` / `BMLIB_DIR`). */
    fun assumeAvailable() {
        val libraryPath = System.getProperty("jna.library.path")
        assumeTrue(
            "no bmlib checkout configured (bmlib.dir / BMLIB_DIR); see doc/cross_platform/bmlib_sync/uniffi_spike.md",
            libraryPath != null && File(libraryPath).isDirectory
        )
    }
}
