package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** PMC's open-data bucket helpers against the shared contract (#480). */
class PmcOpenDataContractTest {
    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/pmc_open_data.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("pmc_open_data.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    private fun JsonObject.text(name: String): String? =
        this[name]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull

    @Test
    fun `the names are the contract's`() {
        assertEquals(contract.text("service_name"), Constants.PMC_OPEN_DATA_SERVICE_NAME)
        assertEquals(contract.text("source"), Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA)
        assertEquals(contract.text("base_url"), Constants.PMC_OPEN_DATA_BASE_URL)
    }

    @Test
    fun `latest metadata key`() {
        contract["latest_metadata_key"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val name = row.text("name")
            if (row.containsKey("error")) {
                assertEquals(name, "malformed", row.text("error"))
                assertThrows(name, IllegalArgumentException::class.java) {
                    PmcOpenData.latestMetadataKey(row.text("listing")!!, row.text("pmcid")!!)
                }
            } else {
                assertEquals(
                    name, row.text("key"),
                    PmcOpenData.latestMetadataKey(row.text("listing")!!, row.text("pmcid")!!)
                )
            }
        }
    }

    @Test
    fun `https url`() {
        contract["https_url"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            assertEquals(row.text("name"), row.text("https_url"), PmcOpenData.httpsUrl(row.text("s3_url")!!))
        }
    }

    @Test
    fun `the contract pins unreadable answers as well as readable ones`() {
        // Without these rows the error branches below would pass vacuously
        for (section in listOf("latest_metadata_key", "record")) {
            val rows = contract[section]!!.jsonArray.map { it.jsonObject }
            assertTrue(section, rows.any { it.text("error") == "malformed" })
            assertTrue(section, rows.any { !it.containsKey("error") })
        }
    }

    @Test
    fun record() {
        contract["record"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val name = row.text("name")
            if (row.containsKey("error")) {
                // An answer we cannot read: the fetch reports it as malformed, never as absent
                assertEquals(name, "malformed", row.text("error"))
                assertThrows(name, IllegalArgumentException::class.java) {
                    PmcOpenDataRecord.fromMetadata(row["metadata"].toString())
                }
                return@forEach
            }
            val record = PmcOpenDataRecord.fromMetadata(row["metadata"].toString())
            assertEquals(name, row.text("xml_url"), record.xmlUrl)
            assertEquals(name, row["is_open_access"]?.jsonPrimitive?.booleanOrNull, record.isOpenAccess)
            assertEquals(name, row["is_manuscript"]?.jsonPrimitive?.booleanOrNull, record.isManuscript)
            assertEquals(name, row.text("license_code"), record.licenseCode)
        }
    }

    @Test
    fun `not established sentences`() {
        contract["not_established_sentence"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val f = row["failure"]!!.jsonObject
            val kind = RequestFailureKind.fromPersisted(f.text("kind")!!)!!
            val failure = RequestFailure(kind, f["status_code"]?.jsonPrimitive?.contentOrNull?.toInt())
            assertEquals(row.text("sentence"), notEstablishedMessage(row.text("service")!!, failure))
        }
    }
}
