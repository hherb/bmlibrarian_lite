package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextAccession
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import org.xmlpull.v1.XmlPullParserFactory
import java.io.IOException
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import javax.inject.Inject
import javax.inject.Singleton

/** PMC's open-data bucket as a JATS source (#480); pinned by fulltext_parity/pmc_open_data.json. */
object PmcOpenData {
    private const val LISTING_ROOT = "ListBucketResult"
    private const val KEY_ELEMENT = "Key"
    private const val S3_SCHEME_PREFIX = "s3://"

    /**
     * The metadata key of the newest version of [pmcid] an S3 listing names, or null.
     *
     * Versions compare as numbers; a key for a longer PMC ID is ignored. The root
     * must be `ListBucketResult` in the S3 namespace and only `Key` elements in that
     * namespace count.
     *
     * @param listing A ListObjectsV2 answer for the prefix `metadata/{pmcid}.`
     * @param pmcid The PMC ID, in `PMC<digits>` form
     * @return The key, or null when the listing names no version of [pmcid]
     * @throws IllegalArgumentException when the body is not an S3 listing
     */
    fun latestMetadataKey(listing: String, pmcid: String): String? {
        val keys = mutableListOf<String>()
        var rootSeen = false
        try {
            val factory = XmlPullParserFactory.newInstance()
            factory.isNamespaceAware = true
            val parser = factory.newPullParser()
            parser.setInput(StringReader(listing))
            var inKey = false
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                when (parser.eventType) {
                    XmlPullParser.START_TAG -> {
                        val inS3 = parser.namespace == Constants.S3_LISTING_NAMESPACE
                        if (!rootSeen) {
                            rootSeen = true
                            require(inS3 && parser.name == LISTING_ROOT) {
                                "not an S3 listing: root ${parser.namespace}:${parser.name}"
                            }
                        }
                        inKey = inS3 && parser.name == KEY_ELEMENT
                    }
                    XmlPullParser.TEXT -> if (inKey) keys.add(parser.text.trim())
                    XmlPullParser.END_TAG -> inKey = false
                }
            }
        } catch (e: XmlPullParserException) {
            throw IllegalArgumentException("not an S3 listing", e)
        }
        require(rootSeen) { "not an S3 listing: empty" }
        val pattern = Regex("metadata/${Regex.escape(pmcid)}\\.(\\d+)\\.json")
        return keys
            .mapNotNull { key -> pattern.matchEntire(key)?.let { it.groupValues[1].toBigInteger() to key } }
            .maxByOrNull { it.first }?.second
    }

    /**
     * The public HTTPS address of an object in the bucket; the `?md5=` query is dropped.
     *
     * @param s3Url A metadata URL such as `s3://pmc-oa-opendata/PMC1.1/PMC1.1.xml?md5=...`
     * @return The HTTPS address, or null for anything that is not an object in this bucket
     */
    fun httpsUrl(s3Url: String): String? {
        val prefix = "$S3_SCHEME_PREFIX${Constants.PMC_OPEN_DATA_BUCKET}/"
        if (!s3Url.startsWith(prefix)) return null
        val key = s3Url.removePrefix(prefix).substringBefore('?')
        return if (key.isEmpty()) null else "${Constants.PMC_OPEN_DATA_BASE_URL}/$key"
    }
}

/**
 * What one bucket metadata record says; a field of the wrong type says nothing.
 *
 * @property xmlUrl The JATS XML's HTTPS address, or null
 * @property isOpenAccess Whether PMC lists it as open access, or null when not said
 * @property isManuscript Whether it is an author manuscript, or null when not said
 * @property licenseCode The licence, for example "CC BY", or null
 */
data class PmcOpenDataRecord(
    val xmlUrl: String?,
    val isOpenAccess: Boolean?,
    val isManuscript: Boolean?,
    val licenseCode: String?
) {
    companion object {
        /**
         * Read a metadata record from its JSON text.
         *
         * @param json The record, untrusted
         * @return The record
         * @throws IllegalArgumentException when [json] is not a JSON object
         */
        fun fromMetadata(json: String): PmcOpenDataRecord {
            val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull() as? JsonObject
                ?: throw IllegalArgumentException("a metadata record is a JSON object")
            fun string(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun bool(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            return PmcOpenDataRecord(
                xmlUrl = string("xml_url")?.let(PmcOpenData::httpsUrl),
                isOpenAccess = bool("is_pmc_openaccess"),
                isManuscript = bool("is_manuscript"),
                licenseCode = string("license_code")
            )
        }
    }
}

/** What asking the bucket for an article's JATS produced. */
sealed interface PmcOpenDataFetch {
    /** The bucket served the article's JATS; never blank. */
    data class Served(val xml: String) : PmcOpenDataFetch

    /** The bucket holds no XML for this article. */
    data object Absent : PmcOpenDataFetch

    /** The bucket's answer is missing, of its real kind. */
    data class Unreachable(val failure: RequestFailure) : PmcOpenDataFetch
}

/**
 * Asks PMC's open-data bucket for an article's JATS, paced to 5 requests a second.
 *
 * @property httpClient The shared HTTP client
 * @property baseUrl The bucket's address; tests point it at a local server
 * @property pacer Spaces requests out
 * @property maxRetries Retries for a 429 or 5xx; tests pass 0
 */
@Singleton
class PmcOpenDataService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val pacer: RequestPacer,
    private val maxRetries: Int
) {
    @Inject
    constructor(httpClient: OkHttpClient) : this(
        httpClient,
        Constants.PMC_OPEN_DATA_BASE_URL,
        RequestPacer(Constants.PMC_OPEN_DATA_MIN_INTERVAL_MS),
        Constants.PMC_OPEN_DATA_MAX_RETRIES
    )

    /** A response's status and its raw bytes: the bucket names no charset, so nothing is guessed. */
    private class Answer(val code: Int, val bytes: ByteArray) {
        /** The body as strict UTF-8, or null when it is not valid UTF-8. */
        fun text(): String? = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (e: CharacterCodingException) {
            null
        }
    }

    private suspend fun get(url: String): Answer {
        val request = Request.Builder().url(url).build()
        return NetworkRetry.withExponentialBackoff(
            maxRetries = maxRetries,
            shouldRetry = { NetworkRetry.isRetryableException(it) }
        ) {
            pacer.awaitTurn() // every attempt takes its own slot
            withContext(Dispatchers.IO) {
                httpClient.newCall(request).execute().use { response ->
                    if (response.code in Constants.PMC_OPEN_DATA_RETRYABLE_STATUSES) {
                        throw RetryableStatusException(response.code)
                    }
                    Answer(response.code, response.body?.bytes() ?: ByteArray(0))
                }
            }
        }
    }

    /**
     * Ask for the newest version of an article's JATS.
     *
     * A listing 404 or a record naming no XML is absence; any other failure is
     * unreachable, of its real kind. A preprint or DOI is never asked.
     *
     * @param pmcid A PMC ID, with or without its prefix
     * @return Served XML, absent, or unreachable
     */
    suspend fun fetchXml(pmcid: String): PmcOpenDataFetch {
        val accession = FullTextAccession.normalized(pmcid)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) } ?: return PmcOpenDataFetch.Absent
        return try {
            val listingUrl = "$baseUrl/".toHttpUrl().newBuilder()
                .addQueryParameter("list-type", "2")
                .addQueryParameter("prefix", "metadata/$accession.")
                .build().toString()
            val listing = get(listingUrl)
            if (listing.code == Constants.HTTP_NOT_FOUND) return PmcOpenDataFetch.Absent
            if (listing.code != HTTP_OK) return unreachableStatus(listing.code)
            val listingText = listing.text() ?: return malformed()
            val key = try {
                PmcOpenData.latestMetadataKey(listingText, accession)
            } catch (e: IllegalArgumentException) {
                return malformed()
            } ?: return PmcOpenDataFetch.Absent

            val record = get("$baseUrl/$key")
            if (record.code != HTTP_OK) return unreachableStatus(record.code)
            val recordText = record.text() ?: return malformed()
            val xmlUrl = try {
                PmcOpenDataRecord.fromMetadata(recordText).xmlUrl
            } catch (e: IllegalArgumentException) {
                return malformed()
            } ?: return PmcOpenDataFetch.Absent

            val article = get(xmlUrl.replaceFirst(Constants.PMC_OPEN_DATA_BASE_URL, baseUrl))
            if (article.code != HTTP_OK) return unreachableStatus(article.code)
            val xml = article.text() ?: return malformed()
            if (xml.isBlank()) {
                return PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
            }
            PmcOpenDataFetch.Served(xml)
        } catch (e: RetryableStatusException) {
            unreachableStatus(e.statusCode)
        } catch (e: IOException) {
            PmcOpenDataFetch.Unreachable(RequestFailure.fromException(e))
        } catch (e: IllegalArgumentException) {
            // A bucket-controlled key that is not a valid URL: an unreadable answer.
            malformed()
        }
    }

    private fun unreachableStatus(code: Int) = PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(code))

    private fun malformed() = PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    private companion object {
        const val HTTP_OK = 200
    }
}
