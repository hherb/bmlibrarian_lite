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

/// Sources for full-text article content.
public enum FullTextSource: String, Sendable, Codable, CaseIterable {
    /// Europe PMC XML converted to HTML/markdown.
    case europePMC = "europepmc"

    /// PMC's open-data bucket's JATS converted to HTML/markdown (#480), asked
    /// when Europe PMC's XML gave no article (absent, unreachable or
    /// unparseable), not after a body-less Europe PMC deposit.
    case pmcOpenData = "pmc_open_data"

    /// Europe PMC PDF (when XML is unavailable but free PDF exists).
    case europePMCPDF = "europepmc_pdf"

    /// The PDF Elsevier's Article API served to a requestor entitled to it,
    /// asked with the user's own key after Europe PMC's render and before
    /// Unpaywall (#480, stage C2). Held only as a local file: its article URL
    /// needs the key, so it is never a link.
    case elsevier = "elsevier"

    /// Open access PDF via Unpaywall.
    case unpaywall = "unpaywall"

    /// Open access PDF an OpenAlex location names, Unpaywall having named
    /// none that served (#480, stage B).
    case openAlex = "openalex"

    /// The text CORE extracted from a repository copy, asked with the user's
    /// own key when no other source served the article (#480, stage C).
    case core = "core"

    /// DOI resolution (publisher website).
    case doi = "doi"

    /// Cached content (previously downloaded).
    case cached = "cached"

    /// Display name for the source.
    public var displayName: String {
        switch self {
        case .europePMC:
            return "Europe PMC"
        case .pmcOpenData:
            return "PMC Open-Access Collection"
        case .europePMCPDF:
            return "Europe PMC PDF"
        case .elsevier:
            return BioMedLitConstants.elsevierSourceLabel
        case .unpaywall:
            return "Unpaywall"
        case .openAlex:
            return "OpenAlex"
        case .core:
            return "CORE (extracted text)"
        case .doi:
            return "Publisher"
        case .cached:
            return "Cached"
        }
    }
}

/// Why a result is not the best source that existed for the article.
///
/// `fetchFullText` tries Europe PMC's machine-readable XML first and falls
/// through to a PDF or a publisher link when it cannot use it. That chain is
/// right — a reader who can be handed the publisher's PDF should get it rather
/// than an error — but without this the reader cannot tell the two outcomes
/// apart: "Europe PMC had no machine-readable text for this article", "Europe PMC
/// had it and this parser choked on it", and "we could not reach Europe PMC at
/// all" present identically (#183, #186). In a medical-literature tool the wrong
/// conclusion is a reader attributing our defect to the evidence base.
///
/// No payload on any case. The parser's typed ``JATSParseError`` is already
/// logged at error level with its own message, which is where a bug report gets
/// its detail; persisting that error's `String` payloads would repeat the
/// mistake ``JATSParseWarnings`` exists to correct (#184). An optional enum
/// rather than a `Bool` because the field names a *reason*.
///
/// The raw values are explicit because they are a *persisted* contract: a
/// compiler-derived name is a detail a rename silently changes, which is the
/// mistake ``JATSParseWarnings`` was rebuilt to avoid (#184, #163).
/// `jatsParseFailed` keeps the string it has shipped with since PR #185.
public enum FullTextDegradation: String, Sendable, Codable, Equatable {
    /// Europe PMC served machine-readable XML and this parser could not read it.
    case jatsParseFailed = "jatsParseFailed"

    /// Europe PMC could not be reached, so we never learned whether it had
    /// machine-readable text for this article.
    ///
    /// Distinct from no degradation at all, which means the source answered and
    /// had nothing. These are all *losses* — the machine-readable copy may well
    /// have been there, and the reader is looking at a substitute because of us
    /// rather than because of the evidence base (#186):
    ///
    /// - a throttle or server error that outlasted its retries;
    /// - a transport failure;
    /// - a status we do not model;
    /// - a blank 200, which told us nothing about the article;
    /// - an identifier that is not an accession, so nothing was sent;
    /// - an identifier search that threw **and left us without a PMC ID**, no
    ///   later query having matched a record for the article. A search that
    ///   answered — even with a record naming no PMC ID — settles the question,
    ///   and a query a later one recovered from cost the reader nothing. So does
    ///   a fetch by the document's own accession that then got Europe PMC's
    ///   answer (served, or 404).
    ///
    /// This list is the canonical one. `FullTextService.fetchFullText` and
    /// `doc/cross_platform/jats_parsing.md` restate it; they must not diverge.
    ///
    /// It deliberately does not claim the copy exists. A PMC record can hold an
    /// abstract-only deposit, which `fullTextXML` serves as body-less XML (seen
    /// live on 2026-09-29: PMC9788864 answers 200 with no `<body>`), and it can
    /// be a non-open-access article, which `fullTextXML` does not serve at all
    /// (#432). So an unreachable endpoint tells us at most that Europe PMC holds
    /// a record, and nothing about whether we could have had its full text.
    ///
    /// Not raised for `fullTextXML`'s 404: that is Europe PMC's answer, not
    /// our loss. The chain still refuses to call the article's full text
    /// absent on it (see ``FullTextError/absenceNotEstablished(_:)``).
    case europePMCUnreachable = "europePMCUnreachable"

    /// A better source was lost and this build cannot say why.
    ///
    /// No producer in this package emits it, and
    /// ``FullTextResult/init(content:warnings:degradation:)`` asserts as much —
    /// in debug builds, which is where a new producer gets written.
    ///
    /// A *reader* does produce it, which is the point: a persisted raw value
    /// this build does not recognise decodes to it (see the app's
    /// `Document.storedDegradation`). The field is only ever written when
    /// something was lost, so an unrecognised value still means a loss, and
    /// naming a specific reason we do not have would be the overclaim this whole
    /// channel exists to prevent.
    ///
    /// Note the sibling channel takes the opposite line with the same word:
    /// ``JATSParseWarnings/Loss/unspecified`` is deliberately written and
    /// round-tripped, because a warning with no detail is still a warning. Here
    /// a *reason* with no detail is a reason we do not have.
    case unspecified = "unspecified"
}

/// What a retrieval's text actually is.
///
/// A retrieval can hand back an article body, the abstract of a body-less
/// deposit, prose recovered from a PDF, or no text at all, and until this
/// existed all four looked alike to a caller: `html` was either set or it was
/// not. So an abstract-only Europe PMC deposit was cached, displayed and handed
/// to the transparency analyzer as though it were an article.
///
/// Callers that must not analyse an abstract as if it were an article branch on
/// this rather than on the text being non-nil.
///
/// The four raw values are bmlib's `ContentKind` verbatim, so a stored value
/// means the same thing on both sides. They are explicit literals because they
/// are a *persisted* contract — the rule ``FullTextDegradation`` records.
public enum FullTextContentKind: String, Sendable, Codable, CaseIterable {
    /// A JATS document that had a `<body>`.
    case fulltext = "fulltext"

    /// A body-less JATS rendering. There is no article text in it, and it is
    /// returned only when nothing better was found.
    case abstract = "abstract"

    /// Text recovered from a PDF. Prose only: no figures, tables or layout, and
    /// possibly not every page, which is why the PDF itself stays worth
    /// offering alongside it.
    case extracted = "extracted"

    /// No text was recovered.
    ///
    /// Never read this as "there is no file". A PDF that downloaded and cached
    /// fine but yielded no prose — a scan — is stored under this kind *with a
    /// real file on disk*, and reading the kind as "only a link" is precisely
    /// what sent such a record down the remote-URL branch, where `URL(string:)`
    /// turned an absolute path into a schemeless URL. Ask
    /// ``FullTextResult/localPDFPath`` — or, in the app,
    /// `Document.fullTextPDFPathIsLocalFile` — which knows.
    case none = "none"
}

/// What a full-text retrieval produced, and what it cost.
///
/// A struct rather than an enum of cases each carrying their own extras. The
/// content is the enum; the two facts *about the retrieval* sit beside it,
/// because that is what they describe. Burying them in the cases would make
/// every `case .europePMC(let html, let markdown, ...)` in a caller change
/// whenever a new fact is learned about a fetch — which is the reasoning the
/// app's own `AppFullTextResult` was already written down with, and which the
/// enum form of this type contradicted.
public struct FullTextResult: Sendable, Equatable {
    /// Whether the content is parsed JATS (Europe PMC's or PMC's bucket).
    private static func isParsedJATS(_ source: FullTextSource) -> Bool {
        source == .europePMC || source == .pmcOpenData
    }

    /// The content retrieved, in whichever form its source gave it.
    public let content: FullTextContent

    /// What the JATS parse of this content lost.
    ///
    /// Travels with the text because the audit that produces it only reached the
    /// logger, so the UI rendered a gutted article exactly as it rendered a
    /// complete one (#181). Clean for every source that involves no parse.
    public let warnings: JATSParseWarnings

    /// Why this is not the best source that existed, or `nil` when it is.
    public let degradation: FullTextDegradation?

    /// What ``extractedText`` or ``content``'s text actually is.
    ///
    /// See ``FullTextContentKind``. Defaults to ``FullTextContentKind/none``,
    /// which is what a link-only result holds.
    public let contentKind: FullTextContentKind

    /// Prose recovered from a PDF, or `nil` when none was.
    ///
    /// Separate from ``content`` because it is not what the source handed over:
    /// the source handed over a PDF, and this is what we got out of it. Kept
    /// beside the PDF's own URL and path rather than replacing them, because
    /// extraction recovers the prose and loses the figures, tables and layout.
    public let extractedText: String?

    /// Where the downloaded PDF now is on disk, or `nil` when none was cached.
    ///
    /// Distinct from ``pdfURL``, which is where it came from. Both are worth
    /// having: the remote URL is what a re-download would use, and this is what
    /// a viewer opens.
    public let localPDFPath: String?

    /// How much of the PDF yielded text, or `nil` when no extraction was run —
    /// or when the document could not be opened to count its pages at all.
    ///
    /// Travels with the text for the same reason ``warnings`` does, and to stop
    /// the same failure recurring on a new channel. The extractor already
    /// computed this; before it was carried here it reached the logger and
    /// nothing else, so a ten-of-fourteen-page extraction was handed to the
    /// transparency analyzer and rendered to the reader exactly as a whole
    /// article was (#181). The pages that fail to extract are disproportionately
    /// the last ones, which is where funding, competing-interest and data-
    /// availability statements live — so "we read all of it" and "we read most
    /// of it" produce opposite conclusions about the same paper.
    ///
    /// Present for a scan too, where it reads `0` of however many pages and
    /// ``extractedText`` is `nil`. That combination is the point rather than an
    /// edge case: a scan renders as an ordinary document, so without it the
    /// reader has no way to learn that every analysis of the article ran on no
    /// text whatsoever.
    public let extractionCoverage: PDFExtractionCoverage?

    /// Why the copy Elsevier's API, Unpaywall or OpenAlex may hold went
    /// unassessed, or `nil` when they settled it (a copy served, or answers
    /// naming none) or were never reached because an earlier tier served the
    /// article.
    ///
    /// Set only on a fallback returned after the copies the render precedes
    /// (Elsevier's API, then Unpaywall's and OpenAlex's PDFs): a caller that
    /// already holds a PDF link must not trade it for a fallback the chain
    /// settled on only because the copy went unassessed (#464), and the reader
    /// is told what it leaves open (``OpenAccessShortfall/notice``, #466). Not a
    /// ``degradation``: that names a lost machine-readable source, and the two
    /// can both be true of one fetch. A copy that yielded no text carries
    /// CORE's entry alone, when CORE, asked after it, left its text
    /// unassessed (#499).
    public let openAccessShortfall: OpenAccessShortfall?

    /// The PDF a source served that could not be saved on this device (#480):
    /// a fault of ours, told as a note of its own, never as a shortfall
    /// (`OpenAccessShortfall.notSavedNote`). `nil` when none was.
    ///
    /// Always the `absoluteString` of the `URL` the PDF was fetched by, the
    /// one a link-only result's content carries, never the address as the
    /// source gave it (which a shortfall entry keeps): `URL(string:)` may
    /// re-encode that (a space, a non-ASCII letter). The app tells "only its
    /// link is kept" by comparing this with the stored link
    /// (`AppFullTextResult.pdfNotSavedNote`, `Document.storedPDFNotSavedNote`),
    /// so the two must stay one string.
    public let pdfNotSavedFrom: String?

    /// Create a retrieval result.
    ///
    /// - Parameters:
    ///   - content: The content retrieved.
    ///   - warnings: What the JATS parse lost. Clean — the default — for PDFs,
    ///     publisher links and anything else that was not parsed.
    ///   - degradation: Why this is not the best source that existed for the
    ///     article. `nil` — the default — when it is.
    ///   - contentKind: What the text actually is. ``FullTextContentKind/none``
    ///     — the default — for a result that holds no text.
    ///   - extractedText: Prose recovered from a PDF, or `nil` — the default —
    ///     when none was.
    ///   - localPDFPath: Where a downloaded PDF now is on disk, or `nil` — the
    ///     default — when none was cached.
    ///   - extractionCoverage: How much of the PDF `extractedText` came from,
    ///     or `nil` — the default — when no extraction was run.
    ///   - openAccessShortfall: Why the open-access copy went unassessed, or
    ///     `nil` — the default — when nothing was left unsettled.
    ///   - pdfNotSavedFrom: The PDF a source served that could not be saved,
    ///     or `nil` — the default — when none was.
    public init(
        content: FullTextContent,
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil,
        contentKind: FullTextContentKind = .none,
        extractedText: String? = nil,
        localPDFPath: String? = nil,
        extractionCoverage: PDFExtractionCoverage? = nil,
        openAccessShortfall: OpenAccessShortfall? = nil,
        pdfNotSavedFrom: String? = nil
    ) {
        // Three combinations the fallback chain never emits, and which the reader
        // would be shown as fact if it ever did. They were unspellable while
        // this type was an enum with `warnings` buried in the `.europePMC` case;
        // the struct that let the degradation travel also made them compile, so
        // they are asserted rather than left to the one producer's good conduct.
        //
        // Only a parsed source can have lost anything to a parse: warnings on a
        // PDF would put a truncation banner over a complete document, which is
        // the false alarm that teaches a reader to dismiss the banner on the
        // article where text really was discarded.
        assert(
            warnings.isClean || Self.isParsedJATS(content.source),
            "parse warnings on \(content.source), which involves no parse"
        )
        // And a parse that succeeded is not a degradation: this flag means the
        // machine-readable source was lost, so it cannot travel with that
        // source's own content.
        assert(
            degradation == nil || !Self.isParsedJATS(content.source),
            "\(content.source) content marked as a degradation from itself"
        )
        // The one case with no producer. Asserted rather than trusted, because
        // the type system cannot say "readable but not writable" and a future
        // caller reaching for a vague-sounding case would silently tell every
        // reader we do not know why their article is a substitute.
        assert(
            degradation != .unspecified,
            "no producer emits .unspecified; it names a value read back from a newer build"
        )
        // The kind and the text are one fact stored twice. A caller that
        // branches on `.extracted` and finds no text, or holds text under any
        // other kind, has two answers to one question and no rule for which
        // wins.
        assert(
            (extractedText != nil) == (contentKind == .extracted),
            "extractedText and .extracted must agree; got \(String(describing: extractedText?.count)) chars under \(contentKind)"
        )
        // `.fulltext` and `.abstract` name what a *parse* found, and JATS XML
        // (Europe PMC's or PMC's bucket's) is the only thing this service parses.
        assert(
            (contentKind != .fulltext && contentKind != .abstract) || Self.isParsedJATS(content.source),
            "\(contentKind) claims a parse, but \(content.source) involves none"
        )
        // And the converse: a parsed source's text is its own. Extracted text
        // on it would mean two texts with no rule for which the analyzer reads.
        assert(
            extractedText == nil || !Self.isParsedJATS(content.source),
            "extracted text on \(content.source), which is parsed rather than extracted"
        )
        // A path on a publisher link hands the viewer a file that is not there.
        assert(
            localPDFPath == nil || content.pdfURL != nil,
            "localPDFPath on \(content.source), which carries no PDF"
        )
        // Text without coverage is the silence this field was added to end: the
        // banner would have no figure to show and would fall back to presenting
        // a partial extraction as a whole article.
        //
        // The converse is allowed, and deliberately so. A scan reports coverage
        // with no text — `0 of 12 pages` — because "we read a document and got
        // nothing out of it" is the fact the reader most needs, and pairing the
        // two strictly would have made it the one fact we could not state.
        //
        // CORE's text is the exception: it was extracted by CORE, not from a
        // PDF this service read, so there are no pages to count.
        assert(
            extractedText == nil || extractionCoverage != nil || content.source == .core,
            "extracted text with no coverage; the reader cannot be told how much was recovered"
        )
        // CORE's text is the result in full: no file was downloaded, and text
        // in hand settles the open-access question (#480, stage C).
        assert(
            content.source != .core
                || (contentKind == .extracted && extractedText != nil && localPDFPath == nil
                    && openAccessShortfall == nil),
            "CORE's text is extracted text, with no PDF and no shortfall"
        )
        // And it is one text, stored twice: the content's and the analyser's.
        if case .core(let text) = content {
            assert(extractedText == text, "CORE's content and extractedText must be one text")
        }
        // Elsevier's PDF is held only as the local file it names: its article
        // URL needs the key, so the file is all a viewer may be handed.
        if case .elsevier(let path) = content {
            assert(localPDFPath == path, "Elsevier's PDF is its local file, and only that")
        }
        // Coverage describes reading a PDF, so there has to be one.
        assert(
            extractionCoverage == nil || content.pdfURL != nil,
            "extraction coverage on \(content.source), which carries no PDF"
        )
        // An open-access shortfall rides only on a fallback. A copy's own
        // PDF (Elsevier's, Unpaywall's or OpenAlex's) settles the question it
        // would raise, and text in hand (parsed or extracted) is no fallback
        // the reader needs warning about. But a copy that yielded no text is
        // no text obtained: CORE's unsettled entry rides on it, and only
        // CORE's (#499).
        assert(
            openAccessShortfall == nil
                || (content.source != .unpaywall && content.source != .openAlex
                    && content.source != .elsevier)
                || (contentKind == .none && localPDFPath != nil
                    && openAccessShortfall?.entries.allSatisfy { $0.source == .core } == true),
            "an open-access shortfall on Elsevier's, Unpaywall's or OpenAlex's own PDF, which settles it"
        )
        assert(
            openAccessShortfall == nil || (contentKind != .fulltext && contentKind != .extracted),
            "an open-access shortfall on \(contentKind) text, which is no fallback"
        )
        self.content = content
        self.warnings = warnings
        self.degradation = degradation
        self.contentKind = contentKind
        self.extractedText = extractedText
        self.localPDFPath = localPDFPath
        self.extractionCoverage = extractionCoverage
        self.openAccessShortfall = openAccessShortfall
        self.pdfNotSavedFrom = pdfNotSavedFrom
    }

    /// This result, noting why the open-access copy went unassessed and which
    /// PDF was served and not saved.
    ///
    /// - Parameters:
    ///   - openAccessShortfall: The failure, or `nil` for none.
    ///   - pdfNotSavedFrom: The PDF served and not saved, or `nil` for none.
    /// - Returns: The same result with ``openAccessShortfall`` and
    ///   ``pdfNotSavedFrom`` set.
    func noting(
        openAccessShortfall: OpenAccessShortfall?, pdfNotSavedFrom: String?
    ) -> FullTextResult {
        FullTextResult(
            content: content,
            warnings: warnings,
            degradation: degradation,
            contentKind: contentKind,
            extractedText: extractedText,
            localPDFPath: localPDFPath,
            extractionCoverage: extractionCoverage,
            openAccessShortfall: openAccessShortfall,
            pdfNotSavedFrom: pdfNotSavedFrom
        )
    }

    /// The source of this full-text content.
    public var source: FullTextSource { content.source }

    /// HTML content if available (parsed JATS: Europe PMC or PMC's bucket).
    public var html: String? { content.html }

    /// Markdown content if available (parsed JATS: Europe PMC or PMC's bucket).
    public var markdown: String? { content.markdown }

    /// PDF URL if available (Europe PMC PDF, Unpaywall, OpenAlex, or cached),
    /// or the local file of Elsevier's PDF, never its article URL.
    public var pdfURL: URL? { content.pdfURL }

    /// Web URL if available (DOI resolution).
    public var webURL: URL? { content.webURL }
}

/// The content a full-text retrieval produced, by the source that gave it.
public enum FullTextContent: Sendable, Equatable {
    /// Europe PMC XML converted to HTML and markdown.
    case europePMC(html: String, markdown: String)

    /// PMC's open-data bucket's JATS converted to HTML and markdown (#480).
    case pmcOpenData(html: String, markdown: String)

    /// Europe PMC PDF URL (when XML is unavailable but free PDF exists).
    case europePMCPDF(pdfURL: URL)

    /// The PDF Elsevier's Article API served, saved at this local path (#480,
    /// stage C2). Never its article URL, which needs the key: ``pdfURL`` is the
    /// file's URL, so no viewer, link or re-download is ever handed the API.
    case elsevier(localPath: String)

    /// Open access PDF URL from Unpaywall.
    case unpaywall(pdfURL: URL)

    /// A PDF an OpenAlex location names, Unpaywall having named none that
    /// served (#480, stage B).
    case openAlex(pdfURL: URL)

    /// The text CORE extracted from a repository copy (#480, stage C): plain
    /// text, no PDF, and the poorest form the chain serves, so asked last.
    case core(text: String)

    /// DOI resolution URL (opens publisher website).
    case doi(webURL: URL)

    /// Cached PDF file path.
    case cached(filePath: String)

    /// The source this content came from.
    public var source: FullTextSource {
        switch self {
        case .europePMC:
            return .europePMC
        case .pmcOpenData:
            return .pmcOpenData
        case .europePMCPDF:
            return .europePMCPDF
        case .elsevier:
            return .elsevier
        case .unpaywall:
            return .unpaywall
        case .openAlex:
            return .openAlex
        case .core:
            return .core
        case .doi:
            return .doi
        case .cached:
            return .cached
        }
    }

    /// HTML content if available (parsed JATS: Europe PMC or PMC's bucket).
    public var html: String? {
        switch self {
        case .europePMC(let html, _), .pmcOpenData(let html, _):
            return html
        default:
            return nil
        }
    }

    /// Markdown content if available (parsed JATS: Europe PMC or PMC's bucket).
    public var markdown: String? {
        switch self {
        case .europePMC(_, let markdown), .pmcOpenData(_, let markdown):
            return markdown
        default:
            return nil
        }
    }

    /// PDF URL if available (Europe PMC PDF, Unpaywall, OpenAlex, or cached),
    /// or the local file of Elsevier's PDF, never its article URL.
    public var pdfURL: URL? {
        switch self {
        case .europePMCPDF(let url):
            return url
        case .unpaywall(let url), .openAlex(let url):
            return url
        case .elsevier(let path), .cached(let path):
            return URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    /// Web URL if available (DOI resolution).
    public var webURL: URL? {
        if case .doi(let url) = self {
            return url
        }
        return nil
    }
}

/// Errors that can occur during full-text retrieval.
public enum FullTextError: LocalizedError, RetryableError, Sendable {
    /// Document has no identifiers suitable for full-text lookup.
    case noIdentifiers

    /// Network error during retrieval.
    case networkError(String)

    /// No full text available from any source.
    ///
    /// A claim about the world: every rung was tried and the article genuinely
    /// has nothing to show. Distinct from ``identifierKindUnresolved(_:)``,
    /// which is a claim about *us*.
    ///
    /// Not yet true after a JATS parse failure, which still ends here when no
    /// later rung serves anything (#436).
    case noFullTextAvailable

    /// Every source was exhausted and the primary identifier's kind was never
    /// established, so the PubMed last resort could not be authorised.
    ///
    /// **Not the same as ``noFullTextAvailable``**, and the difference is the
    /// whole reason this case exists. Gating that last resort on a stated kind
    /// (#212) made an internal refusal look identical to a fact about the
    /// literature: the app said "no full text available", the caller recorded
    /// it on the document, and the fetch control disappeared for good. A reader
    /// who knows the paper is on PubMed would conclude the app is broken, and be
    /// right — the record may well be reachable, we just cannot prove which one
    /// it is.
    ///
    /// Carries the identifier so the reader can be handed the one thing still
    /// known to be true about the record, and callers must **not** mark the
    /// document permanently unavailable on it.
    case identifierKindUnresolved(String)

    /// Every source was exhausted, but Europe PMC did not settle the question.
    ///
    /// Carries what Europe PMC's side of the chain got instead of the
    /// article's text. That is either an answer — an HTTP status such as
    /// `fullTextXML`'s 404 for an article Europe PMC holds but does not serve
    /// as open access (#432), from the fetch or the identifier search — or no
    /// answer at all: a throttle (429), a 5xx that outlasted its retries
    /// (#445), a timeout, a dropped connection, a blank body, an identifier
    /// never sent. Either way the article may have a full text we did not
    /// reach (#434). The reader's sentence follows the same
    /// split, by ``RequestFailure/isAnswer`` (see `errorDescription`).
    ///
    /// Like ``identifierKindUnresolved(_:)``, a claim about *us*, and callers
    /// must **not** mark the document permanently unavailable on it: that
    /// took the retry away from articles whose only fault was a busy Europe
    /// PMC.
    case absenceNotEstablished(RequestFailure)

    /// Every source was exhausted, Europe PMC settled its side, but PMC's
    /// open-data bucket could not be read (#480).
    ///
    /// Carries what the bucket's side got instead of the article's JATS: any
    /// status but 200 (a listing 404, and a 404 for a record the listing
    /// named, included), a body that is not UTF-8 or did not parse, an
    /// `xml_url` that is not the bucket's, a blank XML, or no answer at all.
    /// A listing naming nothing under the article's prefix, or a record
    /// naming no XML, is the bucket's answer that it holds nothing, and never
    /// lands here. Named only when Europe PMC left no shortfall of its own,
    /// so the reader is given one sentence. Like ``absenceNotEstablished(_:)``, a claim about
    /// *us*, and callers must **not** mark the document permanently
    /// unavailable on it.
    case pmcOpenDataNotEstablished(RequestFailure)

    /// Every source was exhausted, but the open-access PDFs (Unpaywall's, then
    /// OpenAlex's) did not settle whether a free copy exists, and no link was
    /// left to fall back on.
    ///
    /// Every fallback the chain returns after the tier (the abstract, a PDF
    /// link it could not download, the DOI link, the PubMed record) carries
    /// the ``OpenAccessShortfall`` instead, so the chain reaches this only when
    /// none of them could be built: no abstract or PDF link was held, the DOI
    /// link would not build (#475), and the slot holds no PubMed ID. Like
    /// ``absenceNotEstablished(_:)``, a claim about *us*, and callers must
    /// **not** mark the document permanently unavailable on it.
    case openAccessNotEstablished(OpenAccessShortfall)

    /// PDF download failed: the status, the transport failure, or
    /// `malformedResponse` for a body that is not a PDF.
    ///
    /// Typed, so the chain can tell the reader why an open-access PDF went
    /// unobtained (#478) without parsing a sentence.
    case pdfDownloadFailed(RequestFailure)

    /// JATS parsing failed, with the parser's own error preserved.
    ///
    /// Keeps `.noContent`, `.alreadyParsed` and `.parsingFailed` distinguishable
    /// rather than flattening them to one string. There is deliberately no
    /// string-carrying twin: a second case that rendered identically only gave a
    /// future edit somewhere to put an error it had not classified, and silently
    /// stole the pattern matches aimed at this one.
    case jatsParseFailure(JATSParseError)

    /// PDF caching failed.
    case cachingFailed(String)

    /// Invalid response from API.
    case invalidResponse(String)

    /// Server error (5xx) - retryable.
    case serverError(statusCode: Int)

    /// The not-established sentence, naming the source that left it so.
    ///
    /// The verb follows #435's decision: an HTTP status other than a throttle
    /// or a 5xx (#445) was an answer, so the source "did not serve it"; those
    /// and every other kind read "could not be asked". Shared by
    /// ``absenceNotEstablished(_:)`` and ``pmcOpenDataNotEstablished(_:)``, and
    /// pinned by `fulltext_parity/pmc_open_data.json`
    /// ("not_established_sentence").
    ///
    /// - Parameters:
    ///   - service: The source as the reader knows it, such as "Europe PMC".
    ///   - failure: What that source's side got instead of the text.
    /// - Returns: The sentence shown to the reader.
    static func notEstablishedSentence(service: String, failure: RequestFailure) -> String {
        let lead = "No source provided this article's full text."
        let tail = "so it may still exist. Try again later."
        return failure.isAnswer
            ? "\(lead) \(service) (\(failure.describe())) did not serve it, \(tail)"
            : "\(lead) \(service) could not be asked (\(failure.describe())), \(tail)"
    }

    public var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let message):
            return "Network error: \(message)"
        case .noFullTextAvailable:
            return "No full text available from any source"
        case .identifierKindUnresolved(let identifier):
            return """
                Could not confirm \(identifier) is a PubMed ID, so this \
                article's PubMed record was not opened. Search PubMed or \
                Europe PMC for \(identifier).
                """
        case .absenceNotEstablished(let failure):
            return Self.notEstablishedSentence(
                service: BioMedLitConstants.europePMCServiceName, failure: failure)
        case .pmcOpenDataNotEstablished(let failure):
            return Self.notEstablishedSentence(
                service: BioMedLitConstants.pmcOpenDataServiceName, failure: failure)
        case .openAccessNotEstablished(let shortfall):
            // The shortfall's own sentence, Python's, so the reader of this
            // error and of a stored notice is told the same thing (#466)
            return "No source provided this article's full text. \(shortfall.notice)"
        case .pdfDownloadFailed(let failure):
            return "Failed to download PDF: \(failure.describe())"
        case .jatsParseFailure(let error):
            return "Failed to parse XML: \(error.localizedDescription)"
        case .cachingFailed(let reason):
            return "Failed to cache PDF: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid API response: \(reason)"
        case .serverError(let statusCode):
            return "Server temporarily unavailable (HTTP \(statusCode)). Try again later."
        }
    }

    /// Whether this error is transient and should be retried.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .serverError:
            return true
        case .noIdentifiers, .noFullTextAvailable, .pdfDownloadFailed,
             .jatsParseFailure, .cachingFailed, .invalidResponse,
             .identifierKindUnresolved, .absenceNotEstablished, .pmcOpenDataNotEstablished,
             .openAccessNotEstablished:
            // A parse failure is deterministic: retrying spends the network
            // budget to reach the same result. So is an unresolved kind — the
            // stored record will not name itself on a second attempt — but
            // unlike the others it must not be recorded as a permanent state of
            // the article; see the case's own note. An unsettled Europe PMC,
            // PMC bucket or Unpaywall has already had whatever retries its
            // tier allows inside the chain; the reader may try again later, so
            // it is not permanent either.
            return false
        }
    }
}
