// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

import Foundation

/// Constants for BioMedLit services.
public enum BioMedLitConstants {
    // MARK: - Europe PMC API

    /// Europe PMC REST API base URL.
    public static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    /// Europe PMC search endpoint.
    public static let europePMCSearchURL = "\(europePMCBaseURL)/search"

    /// Default page size for Europe PMC searches.
    public static let europePMCDefaultPageSize = 25

    /// Maximum page size for Europe PMC searches.
    public static let europePMCMaxPageSize = 1000

    /// Europe PMC ``availabilityCode`` values whose PDF may be downloaded.
    ///
    /// Europe PMC labels a ``fullTextUrl`` entry's access twice over: a display
    /// string (``availability``) and a short controlled code (``availabilityCode``).
    /// Both are read — the code decides when present, the string is the fallback
    /// for an entry carrying none.
    ///
    /// An allow-list, never a deny-list on "Subscription required": an unknown
    /// future value must under-credit, costing one retrieval, rather than send
    /// the app to download a paywalled PDF.
    ///
    /// bmlib issue #79 measured this over 600 recent MEDLINE records — of 1,263
    /// ``fullTextUrl`` entries, 326 were ``documentStyle=pdf``:
    ///
    /// | `availability` | code | entries | share |
    /// | --- | --- | --- | --- |
    /// | Open access | `OA` | 312 | 95.7% |
    /// | Free | `F` | 14 | 4.3% |
    /// | Subscription required | `S` | 0 | — |
    ///
    /// Both accepted labels are the identical `…?pdf=render` URL on the identical
    /// host, so accepting only "Free" discarded 95.7% of the free PDFs this tier
    /// exists to find.
    public static let europePMCFreePDFAvailabilityCodes: Set<String> = ["OA", "F"]

    /// Europe PMC ``availability`` display strings accepted for an entry with no code.
    ///
    /// Consulted only when ``availabilityCode`` is absent — a code that is present
    /// but unrecognised is rejected without reading the label, so a future code
    /// cannot be admitted on the strength of a display string.
    public static let europePMCFreePDFAvailabilityLabels: Set<String> = ["Open access", "Free"]

    /// Europe PMC ``availabilityCode`` values known to mean "not downloadable".
    ///
    /// Not consulted when deciding — ``europePMCFreePDFAvailabilityCodes`` is the
    /// allow-list and remains the only thing that admits an entry. This exists so
    /// the rejection can be *reported* accurately: a paywalled `S` entry is
    /// routine and belongs at debug, while a code in neither set means Europe PMC
    /// has published a value this build has never evaluated, which is how bmlib
    /// issue #79 recurs and belongs at warning.
    public static let europePMCKnownUnavailablePDFCodes: Set<String> = ["S"]

    /// Europe PMC ``documentStyle`` marking a PDF entry.
    public static let europePMCPDFDocumentStyle = "pdf"

    /// Prefix of a Europe PMC preprint accession, e.g. `PPR1287966`.
    ///
    /// A preprint carries no PMID and no PMC ID, so this accession is the only
    /// identifier it has besides its DOI. Recognising it is what lets the
    /// article be asked for under the source that can answer — see
    /// ``europePMCPreprintSource``.
    public static let europePMCPreprintAccessionPrefix = "PPR"

    /// Prefix of a PubMed Central accession, e.g. `PMC1082889`.
    public static let pmcAccessionPrefix = "PMC"

    /// Europe PMC `src` token for MEDLINE records, which an `ext_id` query
    /// must name to match a PubMed ID.
    public static let europePMCMedlineSource = "med"

    /// Europe PMC `src` token for preprint records.
    ///
    /// Measured against the live API on 2026-09-10:
    /// `ext_id:PPR1287966 src:ppr` matches, `ext_id:PPR1287966 src:med` does
    /// not.
    public static let europePMCPreprintSource = "ppr"

    /// Europe PMC `src` token for PubMed Central records.
    ///
    /// Names the kind of a record, which is what the `source` field carries and
    /// what ``ArticleIdentifierKind`` stores. It is deliberately *not* used to
    /// build an `ext_id` query: measured on 2026-09-10, `ext_id:PMC1082889
    /// src:pmc` returns no hits, while ``europePMCPMCIDField`` matches — see
    /// that constant.
    public static let europePMCPMCSource = "pmc"

    /// Europe PMC query field that matches a PMC accession.
    ///
    /// A PMC ID is not reachable as an `ext_id` under the sources we tried:
    /// measured on 2026-09-10, `src:pmc` and `src:med` both return no hits for
    /// one, with or without the `PMC` prefix, while `PMCID:PMC1082889` matches.
    public static let europePMCPMCIDField = "PMCID"

    // MARK: - PubMed API

    /// NCBI E-utilities base URL.
    public static let pubmedBaseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    /// PubMed search endpoint.
    public static let pubmedSearchURL = "\(pubmedBaseURL)/esearch.fcgi"

    /// PubMed fetch endpoint.
    public static let pubmedFetchURL = "\(pubmedBaseURL)/efetch.fcgi"

    /// Default batch size for PubMed searches.
    public static let pubmedDefaultBatchSize = 100

    /// Maximum offset for PubMed searches.
    public static let pubmedMaxOffset = 9999

    /// Rate limit for PubMed without API key (requests per second).
    public static let pubmedRateLimitNoKey = 3

    /// Rate limit for PubMed with API key (requests per second).
    public static let pubmedRateLimitWithKey = 10

    // MARK: - Unpaywall API

    /// Unpaywall API base URL.
    public static let unpaywallBaseURL = "https://api.unpaywall.org/v2"

    // MARK: - DOI Resolution

    /// DOI resolution base URL.
    public static let doiBaseURL = "https://doi.org"

    // MARK: - PubMed Web

    /// PubMed web base URL.
    public static let pubmedWebBaseURL = "https://pubmed.ncbi.nlm.nih.gov"

    // MARK: - Europe PMC Figure URLs

    /// Europe PMC figure/graphic base URL.
    public static let europePMCFigureBaseURL = "https://europepmc.org/articles"

    // MARK: - Timeouts

    /// Default request timeout in seconds.
    public static let defaultRequestTimeout: TimeInterval = 45

    /// PDF download timeout in seconds.
    public static let pdfDownloadTimeout: TimeInterval = 180

    /// Search request timeout in seconds.
    public static let searchRequestTimeout: TimeInterval = 60

    // MARK: - HTTP Status Codes

    /// HTTP 200 OK.
    public static let httpStatusOK = 200

    /// HTTP 404 Not Found.
    public static let httpStatusNotFound = 404

    /// HTTP 429 Too Many Requests.
    public static let httpStatusRateLimited = 429

    /// Retryable HTTP status codes.
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    // MARK: - File Management

    /// Default email for API identification when none configured.
    public static let defaultEmail = "user@example.com"

    /// Application support folder name.
    public static let appSupportFolderName = "BioMedLit"

    /// PDF cache folder name.
    public static let pdfCacheFolderName = "PDFCache"

    /// PDF file extension.
    public static let pdfExtension = "pdf"

    /// Extension a cache entry is renamed to when it fails validation.
    ///
    /// Quarantined rather than deleted so the bytes stay inspectable, which is
    /// only useful while "clear cache" also removes them.
    public static let quarantinedPDFExtension = "corrupt"

    /// Characters a PDF cache filename may take from an article identifier.
    ///
    /// Everything else is replaced, so an identifier carrying `/` or `..`
    /// cannot walk the written file out of the cache directory.
    public static let cacheKeyAllowedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    )

    /// Tag for a cache filename whose identifier has no kind to name it by.
    ///
    /// These tags define the on-disk cache format, and they are the whole
    /// mechanism keeping two identifier kinds apart: an article whose primary
    /// slot holds `PMC7654321` must not name the entry a different article
    /// reached by a PubMed ID of `PMC7654321`. They are mutually non-prefixing,
    /// and `_` joins a tag to its identifier because `-` is absent from
    /// ``cacheKeyAllowedCharacters`` and so stays free to separate the article
    /// component from the source-URL fingerprint.
    ///
    /// This one is the bucket for an identifier no record classified and whose
    /// shape settles nothing — a `CN…` patent or `IND…` accession, say. Filing such a
    /// value under ``pubmedCacheKeyTag`` would be a label that lies.
    public static let primaryCacheKeyTag = "id"

    /// Tag for a cache filename keyed on a PubMed ID. See ``primaryCacheKeyTag``.
    public static let pubmedCacheKeyTag = "pmid"

    /// Tag for a cache filename keyed on a preprint accession. See
    /// ``primaryCacheKeyTag``.
    public static let preprintCacheKeyTag = "ppr"

    /// Tag for a cache filename keyed on a PMC ID. See ``primaryCacheKeyTag``.
    ///
    /// Shared by both rungs that can carry a PMC accession, which is what stops
    /// a PMC-only record — whose accession arrives in the primary slot *and* in
    /// `pmcId` — from being downloaded and cached twice (#209).
    public static let pmcCacheKeyTag = "pmc"

    /// Tag for a cache filename keyed on an accession whose source Europe PMC
    /// stated but this build does not model — a thesis, a case report, a patent.
    /// See ``primaryCacheKeyTag``.
    ///
    /// Separate from ``primaryCacheKeyTag`` because the two now describe
    /// genuinely different situations, and one of them is a bare number. Since
    /// #212 an unvouched decimal accession is ``ArticleIdentifierKind/unknown``
    /// rather than a PubMed ID, so without this tag a stated `ETH` accession and
    /// an unclassified identifier with the same digits would share a filename
    /// and be served each other's bytes — the collision the tagging exists to
    /// prevent, reintroduced by the repair.
    ///
    /// A single closed tag rather than the source token itself: the token is
    /// network-supplied, and the filename format needs a fixed vocabulary. Two
    /// *different* unmodelled sources whose accessions are byte-identical still
    /// share a name, which is the same residual ``primaryCacheKeyTag`` carries.
    public static let europePMCSourceCacheKeyTag = "src"

    /// Tag for a cache filename keyed on a DOI. See ``primaryCacheKeyTag``.
    public static let doiCacheKeyTag = "doi"

    /// Bytes of the DOI digest kept in a PDF cache filename.
    ///
    /// Longer than the source-URL fingerprint below, because the two are
    /// separating different populations. The fingerprint distinguishes the two
    /// or three PDF URLs one article is offered; this distinguishes one article
    /// from every other article the user ever fetches, and a collision there
    /// serves the wrong paper's bytes.
    public static let doiCacheKeyDigestBytes = 16

    /// Bytes of the source-URL digest kept in a PDF cache filename.
    ///
    /// Eight bytes is sixteen hex characters: far more than enough to separate
    /// the two or three PDF URLs one article is ever offered, and short enough
    /// to leave the filename readable.
    public static let cacheKeyFingerprintBytes = 8

    /// Per-page extraction warnings included in a single log line.
    ///
    /// A scan warns once per page, so an unbounded list turns one event into a
    /// log entry the length of the document.
    public static let loggedPageWarningLimit = 3

    /// PDF filename prefix.
    public static let pdfFilenamePrefix = "article_"

    // MARK: - iCloud Sync

    /// Polling interval for iCloud download status checks (in nanoseconds).
    public static let iCloudPollingIntervalNanoseconds: UInt64 = 1_000_000_000

    // MARK: - Retry Configuration

    /// Short retry delay (0.5 seconds) in nanoseconds for first retry attempt.
    public static let retryDelayShortNanoseconds: UInt64 = 500_000_000

    /// Standard retry delay (1 second) in nanoseconds for subsequent retry attempts.
    public static let retryDelayStandardNanoseconds: UInt64 = 1_000_000_000

    /// Nanoseconds per second, for converting delay calculations.
    public static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    // MARK: - Formatting Constants

    /// Maximum authors to display before using "et al."
    public static let maxAuthorsBeforeEtAl = 3

    /// Maximum heading level for markdown/HTML (h1-h6).
    public static let maxHeadingLevel = 6

    /// Minimum PMID length for pattern matching.
    public static let minPMIDLength = 7

    /// PDF magic bytes ("%PDF").
    public static let pdfMagicBytes: [UInt8] = [0x25, 0x50, 0x44, 0x46]

    /// The URL scheme a report uses to point a reference at its document.
    ///
    /// Written by this app's report prompt — ``PromptTemplates`` spells it out
    /// literally — and read back by this app alone, so a parenthetical opening
    /// with it is machine syntax rather than an article's prose. That is what
    /// licenses the tolerances below.
    ///
    /// Interpolated unescaped into ``markdownLinkPattern`` and
    /// ``residualDocumentReferencePattern``. It carries no regular expression
    /// metacharacter today; one introduced here would change what both patterns
    /// mean without producing a compile error.
    public static let documentReferenceScheme = "doc:"

    /// The characters a document's identity is built from.
    ///
    /// An identity is a `UUID` string or a legacy `pmid-<digits>`, so it is
    /// alphanumerics, hyphen and underscore and nothing else. Bounding an
    /// unterminated target by this set rather than by "not whitespace" is what
    /// keeps a sentence's own punctuation out of a removed run: `(doc:abc, and`
    /// gives up the identity and leaves the comma standing.
    public static let documentIdentityCharacterClass = "[A-Za-z0-9_-]"

    /// An ordinary link's target: any run that does not cross a line break,
    /// nesting at most one level of parentheses.
    ///
    /// Not used for a document target, which is confined to an identity's own
    /// characters: within one line, a run like this still reaches a later `)`
    /// and swallows the prose before it (#233). An ordinary target has no
    /// character set to confine it to.
    ///
    /// The line break is the load-bearing part. An unterminated target that
    /// could cross one would run to whatever `)` a later paragraph happened to
    /// offer and delete everything in between — silently, because from the
    /// pattern's point of view that parses, so no sweep ever sees it.
    private static let linkTargetRun = "(?:[^()\\n]|\\([^()\\n]*\\))*"

    /// Markdown link syntax: `[display text](target)`.
    ///
    /// Capture group 1 is the display text. Exactly one of the other two
    /// participates in a match: group 2 is the run after a
    /// ``documentReferenceScheme``, which names a document; group 3 is any other
    /// target. Neither is inspected beyond that: a report's link target is a
    /// document's identity, and a renderer that cannot see the documents may not
    /// decide what it names. See ``ReportInlineText``, the one reader of these
    /// groups.
    ///
    /// Shapes the first version of this pattern got wrong, each leaving text a
    /// reader keeps in a state it should not be in (#230). Two it refused
    /// outright, leaving a raw target on the page; two it matched and damaged.
    ///
    /// - **A leading `!`** is consumed with the link it belongs to, so an image
    ///   does not leave its marker stranded against the caption. A `!` preceded
    ///   by a word character belongs to the sentence and is left alone.
    /// - **Display text may nest one level of brackets**, so an author's
    ///   bracketed aside does not end the display text early.
    /// - **A target may nest one level of parentheses**, because a Wiley DOI
    ///   embeds one — `10.1002/(SICI)1097-0258` — and stopping at the first `)`
    ///   left the tail of the URL in the prose.
    /// - **Whitespace, including one line break, may separate `]` from a
    ///   ``documentReferenceScheme`` target.** A language model writes the report
    ///   body and soft-wraps it, so a stray space or a wrap mid-reference is
    ///   ordinary output. The tolerance stops at that scheme deliberately: were
    ///   it general, `a 12% [sic] (95% CI 4-19) reduction` would lose its
    ///   confidence interval.
    ///
    /// Each alternative in the two nested runs is distinguished by its first
    /// character, and each has exactly one possible match length because the
    /// inner run excludes its own closing delimiter. Both conditions are
    /// load-bearing against catastrophic backtracking: rewriting
    /// `\[[^\[\]]*\]` as `\[.*?\]` would preserve the first and destroy the
    /// second.
    ///
    /// ## A document target is an identity, not a run of text (#233)
    ///
    /// Group 2 is confined to one run of
    /// ``documentIdentityCharacterClass``, with whitespace allowed around it but
    /// not inside it. It was ``linkTargetRun``, which accepted anything up to a
    /// closing parenthesis: an unterminated `(doc:abc` then found the `)` that
    /// closed a later confidence interval, and every word between became the
    /// "identity" — removed from the page, and reported nowhere, because from
    /// this pattern's point of view that parsed. A target that is not
    /// identity-shaped is left to ``residualDocumentReferencePattern``, which
    /// removes the target and reports it.
    ///
    /// The ordinary branch refuses a target opening with the scheme, so such a
    /// target cannot fall through and become a link to `doc:…`, which the app
    /// does not intercept and the system cannot open. Whitespace is tolerated
    /// between `(` and the scheme for the same reason.
    ///
    /// The run between `]` and a document target is written
    /// `[ \t]*(?:\n[ \t]*)?` rather than `[ \t]*\n?[ \t]*`: the second divides a
    /// run of spaces between its two halves in every possible way before
    /// failing, which took seconds on a long one.
    public static let markdownLinkPattern =
        "(?<!\\w)!?\\[((?:[^\\[\\]]|\\[[^\\[\\]]*\\])*)\\]"
        + "(?:[ \\t]*(?:\\n[ \\t]*)?\\([ \\t]*\(documentReferenceScheme)"
        + "([ \\t]*\(documentIdentityCharacterClass)+[ \\t]*)\\)"
        + "|\\((?![ \\t]*\(documentReferenceScheme))(\(linkTargetRun))\\))"

    /// A citation in `Author, Year` form carrying no target: `[Smith et al., 2016a]`.
    ///
    /// Reports written before references carried a document's identity cite
    /// this way, and a reference whose unparseable target was removed is left
    /// in this form. A renderer able to find a document by author and year may
    /// offer it as a link; one that is not shows it exactly as written.
    ///
    /// Capture group 1 is the text between the brackets. It must end in a comma,
    /// optional whitespace, a four-digit year and an optional one-letter
    /// disambiguator, which is what keeps `[sic]` and `[1]` from being taken for
    /// citations. Unlike ``markdownLinkPattern``'s display text it may not
    /// contain a bracket at all: with no target anchoring the far end, a stray
    /// `[` earlier in the sentence would otherwise join the citation, and the
    /// lookup would search for `also [Smith`.
    ///
    /// Once private to each on-screen report view, where it also decided what
    /// counted as a reference *with* a target — so `[the WHO guideline](doc:…)`
    /// was not one (#233). It is consulted only where no target exists.
    public static let untargetedCitationPattern = "\\[([^\\[\\]]+,\\s*\\d{4}[a-z]?)\\]"

    /// A document reference left behind once every link has been flattened.
    ///
    /// Whatever ``markdownLinkPattern`` does not match reaches here: a target
    /// with no closing parenthesis, a target with no preceding link, display
    /// text nested deeper than that pattern allows. The set is that pattern's
    /// complement and shifts whenever it changes, so it is not enumerated.
    ///
    /// None of it may be printed. A target is a row's identity, which means
    /// nothing to a reader, and a legacy `pmid-889149` identity pasted into
    /// PubMed is a real 1977 paper on mouse courtship rather than the article
    /// cited (#212).
    ///
    /// Two branches, because what safely bounds a removal differs by shape:
    ///
    /// - **Terminated.** The whole parenthetical goes, whatever it holds short
    ///   of a parenthesis, a bracket or a line break, because the closing
    ///   parenthesis establishes where it ends. Since #233 this branch receives
    ///   every closed target that is not one identity — `(doc:pmid 889149)`,
    ///   `(doc:pmid-889149; doc:pmid-123456)`, `(doc:pmid:889149)` — and each
    ///   leaves nothing behind. Bounded by the identity's characters instead, it
    ///   removed the first identity and printed the rest, `pmid-123456`
    ///   included. Refusing a nested `(` is what keeps an unterminated target
    ///   from reaching a later parenthetical's `)` through this branch.
    /// - **Unterminated.** Nothing establishes where the target was meant to
    ///   end, so the run is bounded by ``documentIdentityCharacterClass``. A run
    ///   bounded only by whitespace swallowed the full stop after
    ///   `(doc:pmid-889149.` and fused two sentences.
    ///
    /// The terminated branch can still take words: in
    /// `[Smith, 2016](doc:abc, and rose) later`, the target was never closed and
    /// `, and rose` goes with it. Nothing in the text can tell that from a list
    /// of identities. It is reported, where the link pattern before #233 took
    /// the same words silently.
    ///
    /// Whitespace after the scheme is tolerated in both. ``markdownLinkPattern``
    /// already accepts it on a well-formed reference, and refusing it here is
    /// what let `(doc: pmid-889149` remove its scheme and print its identity.
    /// Whitespace between `(` and the scheme is tolerated for the same reason:
    /// that pattern accepts it too.
    ///
    /// One preceding space or tab is absorbed so a removed reference does not
    /// leave a double gap mid-sentence.
    ///
    /// Only a *parenthesised* target is matched. A scheme that lost its opening
    /// parenthesis survives this sweep and is reported instead (#236).
    public static let residualDocumentReferencePattern =
        "[ \\t]?\\([ \\t]*\(documentReferenceScheme)"
        + "(?:[^()\\[\\]\\n]*\\)"
        + "|[ \\t]*\(documentIdentityCharacterClass)*)"

    /// Markdown emphasis markers, removed for a renderer that shows text verbatim.
    ///
    /// Only the paired markers are listed. A single `*` or `_` is far more often
    /// a literal character in a biomedical title than an emphasis marker, so
    /// stripping it would corrupt the text it is meant to clean.
    public static let markdownEmphasisMarkers = ["**", "__"]

    // MARK: - Scoring Constants

    /// Minimum valid relevance score.
    public static let minRelevanceScore = 1

    /// Maximum valid relevance score.
    public static let maxRelevanceScore = 5
}

// MARK: - PubMed Filters

/// PubMed publication type filters for clinical relevance.
///
/// Use these filters to narrow search results to specific publication types
/// commonly considered high-quality evidence in evidence-based medicine.
public enum PubMedFilters {
    /// Filter for high-quality clinical publication types.
    ///
    /// Includes: Randomized Controlled Trials, Meta-Analyses, Systematic Reviews,
    /// Clinical Trials, Reviews, Guidelines, and Practice Guidelines.
    public static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR \
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR \
        Guideline[pt] OR Practice Guideline[pt])
        """

    /// Filter for human studies only.
    public static let humanFilter = "AND humans[MeSH]"

    /// Filter for English language articles.
    public static let englishFilter = "AND English[lang]"

    /// Combined filter for clinical human studies in English.
    public static let combinedClinicalFilter = """
        \(clinicalPublicationFilter) \(humanFilter) \(englishFilter)
        """
}
