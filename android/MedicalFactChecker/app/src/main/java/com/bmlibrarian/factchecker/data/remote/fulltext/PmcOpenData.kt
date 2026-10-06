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
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import org.xmlpull.v1.XmlPullParserFactory
import java.io.IOException
import java.io.StringReader
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * These bytes as strict UTF-8, or null when they are not valid UTF-8.
 *
 * The services that name no charset decode with this, so nothing is guessed and
 * a replacement character never enters text that is then read as an answer.
 */
internal fun ByteArray.strictUtf8(): String? = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(this)).toString()
} catch (e: CharacterCodingException) {
    null
}

/** PMC's open-data bucket as a JATS source (#480); pinned by fulltext_parity/pmc_open_data.json. */
object PmcOpenData {
    private const val LISTING_ROOT = "ListBucketResult"
    private const val KEY_ELEMENT = "Key"
    private const val S3_SCHEME_PREFIX = "s3://"
    private const val METADATA_PREFIX = "metadata/"

    /**
     * The metadata key of the newest version of [pmcid] an S3 listing names, or null.
     *
     * Versions compare as numbers (`.10` is newer than `.2`, and a version beyond
     * 64 bits still compares); a key for a longer PMC ID is ignored. The root must
     * be `ListBucketResult` in the S3 namespace and only `Key` elements in that
     * namespace count. A key that is this article's (it starts `metadata/{pmcid}.`)
     * but whose version is not ASCII digits is an answer we cannot read: ignored
     * beside a version we can read, and on its own it makes the listing unreadable,
     * never an absence (Python's `latest_metadata_key`).
     *
     * @param listing A ListObjectsV2 answer for the prefix `metadata/{pmcid}.`
     * @param pmcid The PMC ID, in `PMC<digits>` form
     * @return The key, or null when the listing names no version of [pmcid]
     * @throws IllegalArgumentException when the body is not an S3 listing, or names
     *   [pmcid] only under versions we cannot read
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
        val prefix = "$METADATA_PREFIX$pmcid."
        // `[0-9]`, spelled out: only ASCII digits are a version, on every platform (a Unicode
        // `\d` would read other scripts' digits)
        val pattern = Regex("${Regex.escape(prefix)}([0-9]+)\\.json")
        val versions = keys.mapNotNull { key ->
            pattern.matchEntire(key)?.let { it.groupValues[1].toBigInteger() to key }
        }
        require(versions.isNotEmpty() || keys.none { it.startsWith(prefix) }) {
            "the listing names $pmcid only under versions we cannot read"
        }
        // Ties on the number (`.2` and `.02`) go to the larger key, as Python's max() of tuples does
        return versions
            .maxWithOrNull(compareBy<Pair<BigInteger, String>>({ it.first }, { it.second }))
            ?.second
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
 * What one bucket metadata record says; a flag of the wrong type says nothing.
 *
 * @property xmlUrl The JATS XML's HTTPS address, or null only when the record
 *   names no XML (`xml_url` missing or JSON null)
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
        private const val XML_URL_FIELD = "xml_url"

        /**
         * Read a metadata record from its JSON text.
         *
         * An `xml_url` that is missing or JSON null names no XML. One that is
         * there but is not a string, or is a string that is not an `s3://` address
         * of an object in this bucket, is an answer we cannot read: it throws, so
         * the fetch reports it as malformed, never as an absence (Python's
         * `PmcOpenDataRecord.from_metadata`).
         *
         * @param json The record, untrusted
         * @return The record
         * @throws IllegalArgumentException when [json] is not a JSON object, or its
         *   `xml_url` is there but names nothing in this bucket
         */
        fun fromMetadata(json: String): PmcOpenDataRecord {
            val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull() as? JsonObject
                ?: throw IllegalArgumentException("a metadata record is a JSON object")
            fun string(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun bool(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            val xmlUrl = when (val named = obj[XML_URL_FIELD]) {
                null, JsonNull -> null
                else -> {
                    val s3Url = (named as? JsonPrimitive)?.takeIf { it.isString }?.content
                        ?: throw IllegalArgumentException("the record's $XML_URL_FIELD is not a string")
                    PmcOpenData.httpsUrl(s3Url)
                        ?: throw IllegalArgumentException("the record's $XML_URL_FIELD names nothing in this bucket")
                }
            }
            return PmcOpenDataRecord(
                xmlUrl = xmlUrl,
                isOpenAccess = bool("is_pmc_openaccess"),
                isManuscript = bool("is_manuscript"),
                licenseCode = string("license_code")
            )
        }
    }
}

/** What asking the bucket for an article's JATS produced. */
sealed interface PmcOpenDataFetch {
    /**
     * The bucket served the article's JATS.
     *
     * @property xml The article's JATS; never blank (a blank body is an incomplete answer)
     */
    data class Served(val xml: String) : PmcOpenDataFetch {
        init {
            require(xml.isNotBlank()) { "a served article is never blank" }
        }
    }

    /** The bucket holds no XML for this article. */
    data object Absent : PmcOpenDataFetch

    /** The bucket's answer is missing, of its real kind. */
    data class Unreachable(val failure: RequestFailure) : PmcOpenDataFetch
}

/**
 * Asks PMC's open-data bucket for an article's JATS, paced to 5 requests a second.
 *
 * @param httpClient The client the bucket is asked with. The injected constructor
 *   derives it from the shared client with [bucketClient]
 * @param baseUrl The bucket's address; tests point it at a local server. Read once
 *   here, so a malformed one fails at construction (a defect in us) and is never
 *   mistaken for an answer from the bucket
 * @property pacer Spaces requests out; every attempt, retries included, takes a slot
 * @property maxRetries Further attempts after the first for a transport failure
 *   (an [IOException], a timeout included) or a 429, 500, 502, 503 or 504
 *   ([Constants.PMC_OPEN_DATA_RETRYABLE_STATUSES]); tests pass 0
 * @property initialBackoffMs The wait before the first retry, doubling on each later one
 */
@Singleton
class PmcOpenDataService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long
) {
    @Inject
    constructor(httpClient: OkHttpClient) : this(
        bucketClient(httpClient, Constants.PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS),
        Constants.PMC_OPEN_DATA_BASE_URL,
        RequestPacer(Constants.PMC_OPEN_DATA_MIN_INTERVAL_MS),
        Constants.PMC_OPEN_DATA_MAX_RETRIES,
        Constants.PMC_OPEN_DATA_INITIAL_BACKOFF_MS
    )

    /** Where listings are asked; parsed here so a bad [baseUrl] throws at construction. */
    private val listingBase: HttpUrl = "$baseUrl/".toHttpUrl()

    /** A response's status and its raw bytes: the bucket names no charset, so nothing is guessed. */
    private class Answer(val code: Int, val bytes: ByteArray) {
        /** The body as strict UTF-8, or null when it is not valid UTF-8. */
        fun text(): String? = bytes.strictUtf8()
    }

    private suspend fun get(url: HttpUrl): Answer {
        val request = Request.Builder().url(url).build()
        return NetworkRetry.withExponentialBackoff(
            maxRetries = maxRetries,
            initialDelayMs = initialBackoffMs,
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
     * Absent only when the bucket answered that it holds no XML for the article:
     * a 200 listing naming no version of it, or a record naming no XML (`xml_url`
     * missing or null). A listing 404 is S3's NoSuchBucket (or something in
     * between), not an article missing from the collection, so it is unreachable
     * like every other failure, of its real kind; an answer we cannot read (a
     * version that is not ASCII digits, an `xml_url` that is not this bucket's
     * `s3://` address, a body that is not UTF-8) is malformed. A preprint or DOI
     * is never asked.
     *
     * @param pmcid A PMC ID, with or without its prefix
     * @return Served XML, absent, or unreachable
     * @throws kotlinx.coroutines.CancellationException if the caller cancelled
     */
    suspend fun fetchXml(pmcid: String): PmcOpenDataFetch {
        val accession = FullTextAccession.normalized(pmcid)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) } ?: return PmcOpenDataFetch.Absent
        return try {
            val listingUrl = listingBase.newBuilder()
                .addQueryParameter("list-type", "2")
                .addQueryParameter("prefix", "metadata/$accession.")
                .build()
            val listing = get(listingUrl)
            if (listing.code != HTTP_OK) return unreachableStatus(listing.code)
            val listingText = listing.text() ?: return malformed()
            val key = try {
                PmcOpenData.latestMetadataKey(listingText, accession)
            } catch (e: IllegalArgumentException) {
                return malformed()
            } ?: return PmcOpenDataFetch.Absent

            // From here every address is built from the bucket's own answer
            val recordUrl = "$baseUrl/$key".toHttpUrlOrNull() ?: return malformed()
            val record = get(recordUrl)
            if (record.code != HTTP_OK) return unreachableStatus(record.code)
            val recordText = record.text() ?: return malformed()
            val xmlUrl = try {
                PmcOpenDataRecord.fromMetadata(recordText).xmlUrl
            } catch (e: IllegalArgumentException) {
                return malformed()
            } ?: return PmcOpenDataFetch.Absent

            // A test seam: tests point baseUrl at a local server. In production
            // baseUrl is PMC_OPEN_DATA_BASE_URL, so this replaces it with itself
            val articleUrl = xmlUrl.replaceFirst(Constants.PMC_OPEN_DATA_BASE_URL, baseUrl)
                .toHttpUrlOrNull() ?: return malformed()
            val article = get(articleUrl)
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
        }
    }

    private fun unreachableStatus(code: Int) = PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(code))

    private fun malformed() = PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    internal companion object {
        private const val HTTP_OK = 200

        /**
         * The client the bucket is asked with, derived from the shared one.
         *
         * The shared client waits [com.bmlibrarian.factchecker.di.NetworkModule]'s
         * LLM read timeout and replays failed connections, and a 408, on its own,
         * outside the pacer. The bucket's client gives each request Python's
         * per-request timeout (connect and read) and leaves every retry to
         * [fetchXml]'s own, paced, policy.
         *
         * @param shared The app's shared client, whose pool and dispatcher are reused
         * @param timeoutSeconds The connect and read timeout for one request
         * @return The bucket's client
         */
        fun bucketClient(shared: OkHttpClient, timeoutSeconds: Long): OkHttpClient =
            shared.newBuilder()
                .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()
    }
}
