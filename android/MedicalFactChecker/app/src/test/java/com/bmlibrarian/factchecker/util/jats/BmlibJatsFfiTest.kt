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

package com.bmlibrarian.factchecker.util.jats

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.bmlib.ffi.JatsException
import org.bmlib.ffi.bmlibVersion
import org.bmlib.ffi.parseJats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * SPIKE (WP-2): bmlib's Rust JATS reader called from a JVM unit test through
 * UniFFI's Kotlin bindings and JNA, over the shared real corpus.
 *
 * The expected values come from `corpus.json`, which was read off the XML
 * independently of every parser, so this checks bmlib against the documents
 * rather than against another parser. The library is the host (darwin-aarch64
 * here) build of rust/bmlib-ffi that `cargoHostBmlib` puts on
 * `jna.library.path`; without a bmlib checkout configured the test skips.
 */
class BmlibJatsFfiTest {

    private lateinit var corpus: File

    @Before
    fun setUp() {
        val libraryPath = System.getProperty("jna.library.path")
        assumeTrue(
            "no bmlib checkout configured (bmlib.dir / BMLIB_DIR); see doc/cross_platform/bmlib_sync/uniffi_spike.md",
            libraryPath != null && File(libraryPath).isDirectory
        )
        var candidate: File? = File("").absoluteFile
        while (candidate != null && !File(candidate, "doc/cross_platform/jats_corpus").isDirectory) {
            candidate = candidate.parentFile
        }
        corpus = File(checkNotNull(candidate) { "no jats_corpus above the working directory" },
            "doc/cross_platform/jats_corpus")
    }

    @Test
    fun parseJatsIsCallableThroughUniFFI() {
        assertEquals("0.2.0", bmlibVersion())
        val article = parseJats(
            "<article><front><article-meta><title-group><article-title>T</article-title>" +
                "</title-group></article-meta></front><body><sec><title>S</title><p>P</p></sec></body></article>"
        )
        assertEquals("T", article.title)
        assertEquals(listOf("P"), article.bodySections.single().paragraphs)
        val thrown = runCatching { parseJats("<article><body>") }.exceptionOrNull()
        assertTrue("malformed XML must throw JatsException, got $thrown", thrown is JatsException)
    }

    @Test
    fun theCorpusAgreesWithTheManifest() {
        val manifest = Json.parseToJsonElement(File(corpus, "corpus.json").readText()).jsonObject
        val entries = manifest.getValue("articles").jsonArray
        assertEquals(7, entries.size)
        var totalNanos = 0L
        for (element in entries) {
            val entry = element.jsonObject
            fun text(key: String) = entry.getValue(key).jsonPrimitive.content
            fun count(key: String) = entry.getValue(key).jsonPrimitive.int
            val id = text("pmcId")
            val xml = File(corpus, text("file")).readText(Charsets.UTF_8)

            val start = System.nanoTime()
            val article = parseJats(xml)
            totalNanos += System.nanoTime() - start

            assertEquals("$id pmcId", id, article.pmcId)
            assertEquals("$id doi", text("doi"), article.doi)
            assertEquals("$id pmid", text("pmid"), article.pmid)
            assertEquals("$id journal", text("journal"), article.journal)
            assertEquals("$id year", text("year"), article.year)
            assertEquals("$id volume", text("volume"), article.volume)
            assertEquals("$id title", text("title"), article.title)
            assertEquals("$id authors", count("authorCount"), article.authors.size)
            assertEquals("$id figures", count("figureCount"), article.figures.size)
            assertEquals("$id tables", count("tableCount"), article.tables.size)
            assertEquals("$id references", count("referenceCount"), article.references.size)
            assertEquals(
                "$id table labels",
                entry.getValue("tableLabels").jsonArray.map { it.jsonPrimitive.content },
                article.tables.map { it.label }
            )
            entry["firstFigureGraphic"]?.takeIf { it !is JsonNull }?.let {
                assertEquals("$id first figure graphic", it.jsonPrimitive.content, article.figures.first().graphicUrl)
            }
            assertTrue("$id has body sections", article.bodySections.isNotEmpty())
        }
        println("[bmlib-ffi] 7 corpus articles parsed through JNA in %.1f ms".format(totalNanos / 1e6))
    }
}
