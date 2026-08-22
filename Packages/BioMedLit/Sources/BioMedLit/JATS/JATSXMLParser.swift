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

/// What a `JATSXMLParser` still had open when the document ended.
///
/// A parameter object for the audit that reads it, so that audit can be a pure
/// function (``JATSXMLParser/unwindDiagnostics(_:)``). Nothing else can
/// exercise it: a well-formed document cannot trip the audit, since `XMLParser`
/// refuses an unbalanced one and each guard in the parser tests the same
/// predicate at both ends of the range it brackets. A net that fires only on a
/// parser defect can only be tested by handing it the state a defect would
/// leave.
///
/// The first six count a stack or counter that decides *routing*: while one is
/// non-zero, content is being filed somewhere other than the article body, so an
/// imbalance is never cosmetic. ``depthUnderflows`` is the exception and is
/// documented as one — a tally of end tags that closed nothing, which is how the
/// other six are kept honest. Every field defaults to zero — the shape a correct
/// parse ends in — so a test names only the one imbalance it is about.
struct JATSParseUnwindState: Equatable {
    /// Depth of unclosed `<sub-article>`/`<response>` nesting.
    let subArticleDepth: Int

    /// `<fig>` elements that opened and never closed.
    let openFigures: Int

    /// `<table-wrap>` elements that opened and never closed.
    let openTables: Int

    /// Depth of unclosed `<table-wrap-foot>`/`<fn>` nesting inside an exhibit.
    ///
    /// The one imbalance that has actually occurred on master: a nested
    /// `<table-wrap>` cleared the then-stored `inTableWrap` while the outer table
    /// was still open, so `</fn>` skipped its decrement and every later `<p>`
    /// drained into the footnote branch and was discarded. That half was fixed in
    /// PR #171, before any release carried it; the table half is #173, fixed
    /// here. An assertion here would have surfaced either on the spot instead of
    /// leaving both for a review to find.
    let exhibitFootnoteDepth: Int

    /// `<caption>` elements that opened and never closed.
    let openCaptions: Int

    /// `<sec>` elements that opened and never closed.
    let openSections: Int

    /// End tags that arrived with nothing to close.
    ///
    /// The opposite imbalance to the six above, and the one the audit could not
    /// see (#180).
    ///
    /// Unlike them it is an event tally, not a live depth: a non-zero value says
    /// an end tag arrived that closed nothing, not that anything is still open
    /// when the document ends. It is on this type because it is read at the same
    /// moment and answers the same question — did this parse route content where
    /// it belonged — and because leaving it off is what let the other six lie.
    ///
    /// Every counter erases its own over-pop, in one of two ways. The two `Int`
    /// depths clamp with `max(0, n - 1)`; the four stack-backed counts pop an
    /// empty stack, which is a no-op. Both destroy the evidence before the audit
    /// reads it, and the clamped case is worse than blind: with a depth of 2 and
    /// three decrements, the third clamps to 0 and the counter reads "balanced"
    /// for the rest of the document, so the audit certifies a defective parse as
    /// clean. ``JATSXMLParser/decrementDepth(_:)`` and
    /// ``JATSXMLParser/popTrackingUnderflow(_:)`` are the two places that count
    /// it; `</fig>` and `</table-wrap>` count it at their collectors.
    ///
    /// The clamp still has to stay, because for `subArticleDepth` it is
    /// load-bearing: `inSubArticle` is `subArticleDepth > 0`, so an unclamped -1
    /// would be brought back to 0 by the next `<sub-article>` and a reviewer
    /// report would be emitted as the article's own body. Counting the underflow
    /// beside the clamp keeps both properties.
    ///
    /// It cannot false-positive: `XMLParser` refuses a document that delivers an
    /// unmatched end tag, so only a parser defect can produce one.
    let depthUnderflows: Int

    /// Whether the parse ended in the only shape a correct one can.
    ///
    /// Agrees with ``JATSXMLParser/unwindDiagnostics(_:)`` on every state the
    /// parser can produce, because the clamp below puts both on the same footing:
    /// "no field is non-zero" and "no field is positive" are the same statement
    /// once nothing can be negative.
    ///
    /// That the two cover the same *fields* is enforced by test rather than by
    /// the type — `testIsBalancedAgreesWithTheDiagnostics` builds a state per
    /// field from a `Mirror` of this struct, so a field added here and forgotten
    /// in `unwindDiagnostics` fails rather than diverging in silence.
    var isBalanced: Bool { self == JATSParseUnwindState() }

    /// Create an end-of-parse state, clamping every count at zero.
    ///
    /// - Parameters:
    ///   - subArticleDepth: Unclosed `<sub-article>`/`<response>` nesting.
    ///   - openFigures: `<fig>` elements that opened and never closed.
    ///   - openTables: `<table-wrap>` elements that opened and never closed.
    ///   - exhibitFootnoteDepth: Unclosed exhibit-footnote nesting.
    ///   - openCaptions: `<caption>` elements that opened and never closed.
    ///   - openSections: `<sec>` elements that opened and never closed.
    ///   - depthUnderflows: End tags that arrived with nothing to close.
    ///
    /// - Note: Every count is clamped at zero. The parser cannot produce a
    ///   negative — each source is a `max(0, ...)` counter, a `.count`, or a
    ///   monotonic tally — and reporting one as "still open" would be worse than
    ///   saying nothing, so the type declines to represent it at all.
    init(
        subArticleDepth: Int = 0,
        openFigures: Int = 0,
        openTables: Int = 0,
        exhibitFootnoteDepth: Int = 0,
        openCaptions: Int = 0,
        openSections: Int = 0,
        depthUnderflows: Int = 0
    ) {
        self.subArticleDepth = max(0, subArticleDepth)
        self.openFigures = max(0, openFigures)
        self.openTables = max(0, openTables)
        self.exhibitFootnoteDepth = max(0, exhibitFootnoteDepth)
        self.openCaptions = max(0, openCaptions)
        self.openSections = max(0, openSections)
        self.depthUnderflows = max(0, depthUnderflows)
    }
}

/// What a parse lost, in a form a caller can act on.
///
/// The audit that produces these has run on the production path since #175 and
/// still only reached the logger, so `FullTextService` had no way to say "this
/// article came back truncated" and the UI rendered a gutted article exactly as
/// it rendered a complete one (#181). A reader cannot tell a parser defect from a
/// publisher who deposited little; this is the channel that lets them.
///
/// Carries **facts, not copy**. The diagnostics are the lines written for a
/// developer reading a log; the sentence shown to a reader is composed by the
/// app, which is where user-facing wording can be localised with the rest of the
/// UI.
///
/// Deliberately narrower than everything `reportParseCompletion` emits: only
/// losses a reader can act on. A zero-author parse is a metadata gap, not a
/// truncation — editorials and corrections legitimately carry none — and a banner
/// that fires on those is worth nothing on the article where content really was
/// discarded. That warning stays in the log.
public struct JATSParseWarnings: Sendable, Equatable {
    /// One line per loss, each naming what it cost.
    public let diagnostics: [String]

    /// Whether the parse lost nothing a reader would want to know about.
    public var isClean: Bool { diagnostics.isEmpty }

    /// Create a set of warnings for a completed parse.
    ///
    /// - Parameter diagnostics: One line per loss, each naming what it cost.
    ///   Empty — the default — is a parse that lost nothing.
    public init(diagnostics: [String] = []) {
        self.diagnostics = diagnostics
    }
}

/// Parser for converting JATS (Journal Article Tag Suite) XML to markdown and HTML.
///
/// JATS is the standard XML format used by Europe PMC and many other
/// biomedical literature databases. This parser handles:
/// - Article metadata (title, authors, journal, dates)
/// - Abstract with labeled sections
/// - Full article body with nested sections
/// - Figures and tables (with captions)
/// - References and citations
/// - Inline formatting (bold, italic, subscript, superscript)
/// - Lists (ordered and unordered)
///
/// An instance parses once: it holds a single `XMLParser` built from the data it
/// was given, and that parser cannot be re-pointed. A second call throws
/// ``JATSParseError/alreadyParsed``, so construct one parser per output:
///
/// ```swift
/// let markdown = try JATSXMLParser(data: xmlData).parseToMarkdown()
/// let html = try JATSXMLParser(data: xmlData).parseToHTML()
/// ```
public final class JATSXMLParser: NSObject {
    // MARK: - Properties

    private let parser: XMLParser
    private var parseError: Error?

    /// Whether ``runParser()`` has already been called on this instance.
    ///
    /// After a *successful* parse a consumed `XMLParser` returns `false` from
    /// `parse()` with no error of its own, so the second call used to bottom out
    /// on "Unknown parsing error"; after a failed one it repeated the first
    /// failure. Either way the accumulated state from the first parse was still
    /// in place. The flag makes the rule explicit and the failure
    /// self-explaining (#168).
    private var hasParsed = false

    // MARK: - Parsed Content

    private var title = ""
    private var authors: [JATSAuthorInfo] = []
    private var journal = ""
    private var volume = ""
    private var issue = ""
    private var pages = ""
    private var year = ""
    private var doi = ""
    private var pmcId = ""
    private var pmid = ""

    /// Whether ``doi`` came from an explicit `pub-id-type="doi"`.
    ///
    /// A `<front>` carries several ids, and the ones with no recognised type
    /// fall through to pattern matching. Without this, SAGE's `publisher-id` —
    /// the DOI with its slash replaced by an underscore — overwrote the real one
    /// simply by appearing later in the document.
    private var doiIsAuthoritative = false

    /// Whether ``pmcId`` came from a caller-supplied id or `pub-id-type="pmc"`/`"pmcid"`.
    ///
    /// PMC emits `pmcid-ver` (the canonical id plus a version suffix) right after
    /// `pmcid`; only the first is the id anything else can be looked up by.
    private var pmcIdIsAuthoritative = false
    private var abstractSections: [JATSAbstractSection] = []
    private var bodySections: [JATSBodySection] = []

    /// Figures in document order.
    private var figures: [JATSFigureInfo] { figureCollector.completed }

    /// Tables in document order.
    private var tables: [JATSTableInfo] { tableCollector.completed }

    private var references: [JATSReferenceInfo] = []

    // MARK: - Parsing State

    private var elementStack: [String] = []

    /// Stack of text buffers for nested elements.
    /// Each text-accumulating element pushes its own buffer.
    private var textStack: [String] = [""]

    /// Elements that accumulate their own text content.
    private let textAccumulatingElements: Set<String> = [
        "p", "title", "article-title", "abstract", "sec",
        "surname", "given-names", "journal-title", "volume", "issue",
        "fpage", "lpage", "year", "article-id", "label",
        "mixed-citation", "element-citation", "caption",
        "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
        "xref", "ext-link", "uri", "email", "named-content",
        "list-item", "def", "term", "kwd", "alt-title",
        "inline-formula", "disp-formula", "tex-math",
        // Reference elements
        "source", "article-title", "person-group", "pub-id", "collab"
    ]

    // Article metadata state
    private var inFront = false
    private var inArticleMeta = false
    /// `content-type` of each open `<contrib-group>`, lowercased, innermost last.
    ///
    /// JATS allows the contributor role to be declared once on the group instead
    /// of on every `<contrib>`. PLOS uses that form — `<contrib-group
    /// content-type="author">` with bare `<contrib>` children — so requiring
    /// `contrib-type="author"` on the child dropped every author it publishes.
    ///
    /// A stack rather than a single value: JATS permits a `<contrib-group>` nested
    /// inside `<collab>` for consortium authorship, and clearing on the inner
    /// `</contrib-group>` left the outer group typeless — which ``isAuthorContrib``
    /// reads as "author", admitting the very editors the group type excludes.
    private var contribGroupTypeStack: [String?] = []

    /// `content-type` of the innermost open `<contrib-group>`, if any.
    private var currentContribGroupType: String? { contribGroupTypeStack.last ?? nil }
    private var inContrib = false
    private var inAff = false

    // Abstract state
    private var inAbstract = false
    private var currentAbstractLabel = ""
    private var currentAbstractTitle = ""
    private var currentAbstractText: [String] = []

    // Body and back matter state
    private var inBody = false
    private var inBack = false
    private var sectionStack: [SectionBuilder] = []

    /// Pending prose from an unsectioned `<body>`.
    ///
    /// `<sec>` is optional in JATS: a `<body>` may hold `<p>` directly. Without
    /// this, `case "p"` required a non-empty `sectionStack` and every word of
    /// such an article was silently dropped (bmlib issue #30).
    private var implicitBodySection: SectionBuilder?

    // Figure/Table state

    /// Open and finished `<fig>` elements, in document order.
    ///
    /// A stack rather than a single slot for the reason `subArticleDepth` is a
    /// counter: JATS permits a `<fig>` inside a `<fig>` and eLife uses it for
    /// every figure supplement, in a fifth of one surveyed draw — see
    /// ``ExhibitCollector`` for the figure and its caveat. A
    /// single slot was overwritten when the inner figure opened and cleared when
    /// it closed, so the parent was discarded and the rest of its content was
    /// read as though no figure were open at all (#156).
    private var figureCollector = ExhibitCollector<FigureBuilder>()

    /// Open and finished `<table-wrap>` elements, in document order.
    ///
    /// The same type for the same reason one element over: `%fn-model` admits a
    /// `<table-wrap>`, so a table opens inside another table's footnote, and a
    /// single slot lost the outer table outright (#173). Figures got the stack
    /// in #156 and tables kept the slot until #173 was filed, which is what
    /// having one type for both is meant to prevent.
    private var tableCollector = ExhibitCollector<TableBuilder>()

    /// Whether the parser is inside a `<table-wrap>` at any depth.
    private var inTableWrap: Bool { tableCollector.isOpen }

    /// How deep the parser is inside `<sub-article>` / `<response>` elements.
    ///
    /// JATS lets either carry a complete `<front>`/`<article-meta>` and `<body>`
    /// of its own. PLOS deposits its whole peer-review history that way — one
    /// sub-article per round, each with its own DOI, title, authors and prose —
    /// so without this the last of each silently replaced the real article's, and
    /// hundreds of paragraphs of reviewer correspondence landed in `bodySections`
    /// where scoring, citation extraction and the transparency regexes then read
    /// them as article text.
    ///
    /// A depth rather than a flag: JATS permits a sub-article inside a
    /// sub-article, and a flag cleared by the inner `</sub-article>` would let the
    /// remainder of the outer one back in.
    private var subArticleDepth = 0

    /// Whether the parser is currently inside a sub-article or response.
    private var inSubArticle: Bool { subArticleDepth > 0 }

    /// What the innermost open `<caption>` belongs to.
    ///
    /// Read from the caption's own parent element rather than from an ambient
    /// "a figure is open" test: a `<media>` inside a `<fig>` carries a caption of
    /// its own, and the enclosing figure is still open, so reading that
    /// concatenated the inner caption onto the outer one.
    private enum CaptionOwner {
        /// A `<fig>` caption; the text belongs to that figure.
        case figure
        /// A `<table-wrap>` caption; the text belongs to that table.
        case table
        /// Any other caption host — `<supplementary-material>`, `<media>`,
        /// `<boxed-text>`, `<fig-group>`, `<disp-formula-group>`. The parser has
        /// no model for these, so the text is not captured; the point of naming
        /// them is that it must not reach the enclosing section either.
        case unmodelled
    }

    /// A figure or a table — the two exhibits the parser models.
    ///
    /// `CaptionOwner` one level up is the same question asked of a `<caption>`,
    /// and it needs a third case because a caption on an unmodelled host must not
    /// fall through to the enclosing section. A `<label>` or a footnote has no
    /// such hazard, so two cases are enough here.
    ///
    /// Both arms address the innermost open exhibit of their kind, through an
    /// `ExhibitCollector` apiece. They were asymmetric until #173 was fixed —
    /// the table side kept a single builder slot, so a `<table-wrap>` inside a
    /// `<table-wrap>` lost the outer table outright.
    private enum Exhibit {
        case figure
        case table
    }

    /// Open `<caption>` owners, innermost last.
    ///
    /// `<caption>` carries `<title>` and `<p>` — the same element names a section
    /// uses. Routing them on "a figure is open" plus `sectionStack` alone renamed
    /// the enclosing `<sec>` after the figure and spilled caption prose into the
    /// article text.
    /// Any open caption now decides, whatever element it hangs off, and it is a
    /// stack because JATS permits a captioned element inside a caption.
    private var captionStack: [CaptionOwner] = []

    /// How deep the parser is inside a footnote belonging to a figure or table.
    ///
    /// `<table-wrap-foot>` prose is neither caption nor cell: the rendered table
    /// does not carry it, so routing it with the cell furniture would drop
    /// abbreviation expansions, significance markers and per-table funding notes
    /// that the transparency analysis reads.
    ///
    /// A counter and not a flag: `<table-wrap-foot>` and the `<fn>` inside it both
    /// increment, so a flag cleared on the inner `</fn>` would strand the prose
    /// publishers routinely put *after* the last footnote — the general "Values
    /// are mean (SD)" note — outside the footnotes, where it is dropped as cell
    /// furniture. Pinned by `JATSContentRetentionTests`.
    ///
    /// It no longer decides routing — `inInnermostExhibitFootnote` does, because
    /// one parser-wide counter cannot answer a question about the *innermost*
    /// exhibit once exhibits nest (#173). What it still does is measure whether
    /// the parser's own footnote bookkeeping balances, which is the one thing a
    /// derived predicate cannot check: the end-of-parse audit reads it, and a
    /// non-zero result means an increment and its decrement stopped testing the
    /// same predicate — the defect shape this file has now produced twice.
    private var exhibitFootnoteDepth = 0

    /// End tags that arrived with nothing to close.
    ///
    /// Every counter the audit reads discards its own over-pop. The two depths
    /// above are decremented as `max(0, n - 1)`; the caption and section stacks
    /// pop an empty array, and the figure and table collectors refuse the close
    /// and carry on. All four throw away the one observation the audit needs, so
    /// the audit was left certifying a defective parse as clean (#180). Every
    /// one of them now routes through here — the two depths via
    /// ``decrementDepth(_:)``, the two stacks via ``popTrackingUnderflow(_:)``,
    /// and the collectors at their own call sites.
    ///
    /// The clamp stays anyway, because for `subArticleDepth` it decides routing:
    /// `inSubArticle` is `subArticleDepth > 0`, so an unclamped -1 would be
    /// brought back to 0 by the *next* `<sub-article>`, and a reviewer report
    /// would be emitted as the article's own body — a live content defect,
    /// strictly worse than a missing diagnostic. Pinned by
    /// `testAnOverDecrementedSubArticleDepthStillExcludesTheNextSubArticle`.
    /// `exhibitFootnoteDepth` no longer routes anything (that moved to
    /// `inInnermostExhibitFootnote` in #173), so its clamp is uniformity, not
    /// necessity.
    ///
    /// Counting the underflow beside the clamp keeps both properties. It cannot
    /// false-positive — `XMLParser` refuses a document with an unmatched end tag,
    /// so only a parser defect reaches here — which is why it is counted rather
    /// than asserted on.
    private var depthUnderflows = 0

    /// Decrement a depth counter, keeping the evidence if it had nothing to drop.
    ///
    /// - Parameter depth: The counter to decrement, clamped at zero.
    private func decrementDepth(_ depth: inout Int) {
        if depth == 0 { depthUnderflows += 1 }
        depth = max(0, depth - 1)
    }

    /// Pop a routing stack, keeping the evidence if it had nothing to drop.
    ///
    /// The stack twin of ``decrementDepth(_:)``. `popLast()` on an empty stack
    /// returns `nil` and changes nothing, which reads to the audit as "balanced"
    /// for precisely the reason the clamp did (#180) — a `.count` cannot go
    /// negative, so the over-pop leaves no trace behind it. "Cannot underflow"
    /// and "cannot hide an over-pop" are different properties, and only the
    /// first one is true of a stack.
    ///
    /// Counting it here is what makes the end-tag-with-nothing-to-close
    /// diagnostic true of every counter rather than only of the two `Int`
    /// depths. The defect shape it guards against is the one #171 and #173
    /// actually were: a start-side guard drifting from its end-side twin, so
    /// that the pop closes a frame that was never opened.
    ///
    /// - Parameter stack: The stack to pop.
    /// - Returns: The popped element, or `nil` when there was nothing to pop.
    private func popTrackingUnderflow<Element>(_ stack: inout [Element]) -> Element? {
        guard let popped = stack.popLast() else {
            depthUnderflows += 1
            return nil
        }
        return popped
    }

    /// The element that most closely encloses the one being handled.
    ///
    /// `elementStack` holds the current element itself in both delegate
    /// callbacks — `didStartElement` appends before it dispatches, and
    /// `didEndElement` pops in a `defer` — so the enclosing element is the entry
    /// below it. This is the question every piece of exhibit furniture has to
    /// answer: `<label>`, `<title>` and `<caption>` all appear on more than one
    /// kind of parent, and the ambient `in*` flags cannot tell them apart.
    ///
    /// The off-by-one is Swift's alone. `doc/cross_platform/jats_parsing.md` and
    /// the Kotlin port both pop before dispatching the end tag, so the parent is
    /// their stack's *last* entry, not the one below it.
    private var enclosingElement: String? {
        elementStack.dropLast().last
    }

    /// The exhibit that most closely encloses the markup being handled.
    ///
    /// Both collectors are open for a `<table-wrap>` inside a `<fig>`, so asking
    /// them in a fixed order — as the `inFigure`/`inTableWrap` flags invited —
    /// answered with whichever was asked first rather than with the nearer one:
    /// the table's `<label>` and its `<table-wrap-foot>` were both filed under the
    /// enclosing figure (#169).
    /// The element stack knows which is nearer, and it is the same question
    /// `enclosingElement` answers one step out.
    ///
    /// It reads a stack that keeps recording inside `<sub-article>`, where the
    /// two exhibit collectors deliberately do not, so they can disagree there.
    /// Every call site sits below the `guard !inSubArticle` in `didEndElement`,
    /// which is what keeps that harmless — moving one above it would route
    /// excluded content into the enclosing article.
    private var innermostExhibit: Exhibit? {
        for element in elementStack.reversed() {
            switch element {
            case "fig": return .figure
            case "table-wrap": return .table
            default: continue
            }
        }
        return nil
    }

    /// Whether the markup being handled is footnote matter of the *innermost*
    /// open exhibit.
    ///
    /// Walks outward from the current element and answers with whichever it
    /// meets first: a `<table-wrap-foot>`/`<fn>` on the way to an enclosing
    /// `<fig>` or `<table-wrap>` means yes; reaching the exhibit without one, or
    /// reaching the bottom of the stack, means no.
    ///
    /// Both halves of that walk are load-bearing. Stopping at the exhibit is
    /// what keeps a `<back><fn-group><fn>` — competing-interest and funding
    /// prose that belongs to no exhibit — from being routed into one. Requiring
    /// the footnote to be met *before* the exhibit is what keeps an exhibit
    /// nested inside another's footnote from inheriting that footnote: a
    /// `<table-wrap>` inside a `<table-wrap-foot>` is exhibit internals of its
    /// own, so its cells belong to its own rendered table and nowhere else.
    ///
    /// Derived rather than read off `exhibitFootnoteDepth`, which is a single
    /// parser-wide counter and therefore still standing at the outer exhibit's
    /// depth while an inner one is being parsed. That is the same sentence as
    /// every other stored-flag defect in this file, one noun over (#173).
    private var inInnermostExhibitFootnote: Bool {
        var sawFootnote = false
        for element in elementStack.reversed() {
            switch element {
            case "table-wrap-foot", "fn":
                sawFootnote = true
            case "fig", "table-wrap":
                return sawFootnote
            default:
                continue
            }
        }
        return false
    }

    /// Mutate the innermost open figure, if there is one.
    ///
    /// Every `<graphic>`, `<label>` and caption belongs to the figure that
    /// encloses it most closely, never to whichever figure happens to be last.
    private func withCurrentFigure(_ mutate: (inout FigureBuilder) -> Void) {
        if !figureCollector.withCurrent(mutate) {
            // The callers all test `enclosingElement`, `innermostExhibit` or a
            // `captionStack` entry first — all three read `elementStack` — so
            // reaching here means the element stack and the collector disagree
            // about whether a figure is open. Logged rather than ignored: the
            // symptom is figure content quietly going missing, with nothing else
            // to go on.
            BioMedLitLib.logger?.error(
                "JATS figure content routed with no open <fig> for \(articleIdentifier)",
                category: .parsing
            )
        }
    }

    /// Mutate the open table, if there is one.
    ///
    /// The table-side counterpart of `withCurrentFigure`, and it earns its place
    /// for the same reason: the routing answers from `elementStack` while the
    /// write lands on the collector, so the two can disagree. Where they used to
    /// — a `<table-wrap>` nested inside a `<table-wrap>` cleared the single slot
    /// while the outer one was still open (#173) — the collector now keeps the
    /// outer table addressable, so this branch is the same formality the figure
    /// side already was.
    private func withCurrentTable(_ mutate: (inout TableBuilder) -> Void) {
        if !tableCollector.withCurrent(mutate) {
            BioMedLitLib.logger?.error(
                "JATS table content routed with no open <table-wrap> for \(articleIdentifier)",
                category: .parsing
            )
        }
    }

    /// Elements a `<graphic>` may sit inside without ceasing to be the enclosing
    /// exhibit's own image.
    ///
    /// `<alternatives>` is a "choose one of these" wrapper around several
    /// encodings of a single image, so it is transparent for ownership — 2 of the
    /// 7 corpus articles deposit a figure's images inside one. Every other
    /// container — `<fn>`, `<supplementary-material>`, `<media>`, `<boxed-text>`
    /// — owns the image it holds, and needs no enumeration: anything absent from
    /// this set simply is not transparent.
    private static let graphicTransparentWrappers: Set<String> = ["alternatives"]

    /// The element a `<graphic>` being opened belongs to.
    ///
    /// `elementStack` already holds the `<graphic>` itself, so the walk starts one
    /// above it and skips only the wrappers that do not take ownership. This is
    /// `enclosingElement` with that one exception, and it is why `<graphic>` gets
    /// its own accessor rather than reusing either of the others: a parent test
    /// would drop the `<alternatives>` deposits, and `innermostExhibit` would hand
    /// a `<supplementary-material>`'s image to the figure around it.
    ///
    /// Ported from `_graphic_owner` in bmlib's parser, which is the reference
    /// implementation for this file.
    private var graphicOwner: String? {
        elementStack.dropLast().last { !Self.graphicTransparentWrappers.contains($0) }
    }

    /// `mime-subtype` values naming an archival master rather than a web image.
    private static let archivalMimeSubtypes: Set<String> = ["tiff", "tif", "eps", "postscript"]

    /// How suitable a `<graphic>` is as the image shown for its figure.
    ///
    /// Two publisher conventions mark a thumbnail and both appear in the wild:
    /// `content-type="thumb"`, which PLOS and Springer deposit and which is the
    /// only spelling in `doc/cross_platform/jats_corpus/`, and
    /// `specific-use="thumbnail"`, covered here only by hand-written fixtures.
    /// Read as a substring so `thumb`, `thumbnail` and the hyphenated compounds a
    /// deposit may carry all count, and lowercased because neither attribute is
    /// case-controlled. Both are open-valued in JATS — the tag set defines no
    /// vocabulary for them — so a third spelling is possible.
    ///
    /// Nothing is inferred from the file extension, which carries no rank of its
    /// own: PLOS and Springer both deposit their thumbnail as `.gif`, but a `.gif`
    /// elsewhere may be the only image the figure has.
    ///
    /// - Parameter attributes: The element's attributes as reported by the parser.
    /// - Returns: How good a fit the graphic is.
    private static func graphicSuitability(_ attributes: [String: String]) -> GraphicSuitability {
        let isThumbnail = ["content-type", "specific-use"].contains { key in
            attributes[key]?.lowercased().contains("thumb") ?? false
        }
        if isThumbnail {
            return .thumbnail
        }
        if let subtype = attributes["mime-subtype"]?.lowercased(),
           archivalMimeSubtypes.contains(subtype) {
            return .archival
        }
        return .full
    }

    // Reference state
    private var inRefList = false
    private var inRef = false
    private var inRefCitation = false
    private var inRefPersonGroup = false
    private var currentReference: ReferenceBuilder?

    // Article ID tracking
    private var currentArticleIdType: String?

    // Author state
    private var currentAuthor: AuthorBuilder?
    private var currentAffiliations: [String: String] = [:]  // id -> text

    // Inline formatting state
    private var inlineFormattingStack: [InlineFormat] = []

    // Cross-reference state (for figure/table links)
    private var currentXrefType: String?
    private var currentXrefRid: String?

    // MARK: - Initialization

    /// Initialize the parser with XML data.
    ///
    /// - Parameters:
    ///   - data: Raw JATS XML data.
    ///   - knownPMCId: Optional PMC ID if known from external source (e.g., search results).
    ///                 Used for building figure URLs when the XML doesn't contain the PMC ID.
    public init(data: Data, knownPMCId: String? = nil) {
        self.parser = XMLParser(data: data)
        // Pre-populate PMC ID if provided
        if let knownId = knownPMCId, !knownId.isEmpty {
            self.pmcId = knownId.hasPrefix("PMC") ? knownId : "PMC\(knownId)"
            self.pmcIdIsAuthoritative = true
        }
        super.init()
        parser.delegate = self
    }

    // MARK: - Text Stack Helpers

    /// Get the current accumulated text.
    private var currentText: String {
        textStack.last ?? ""
    }

    /// Append text to the current buffer.
    private func appendText(_ text: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += text
    }

    /// Push a new text buffer for a nested element.
    private func pushTextBuffer() {
        textStack.append("")
    }

    /// Pop and return the text buffer, merging it with parent if needed.
    private func popTextBuffer(mergeWithParent: Bool = false) -> String {
        guard textStack.count > 1 else {
            let text = textStack.first ?? ""
            if !textStack.isEmpty {
                textStack[0] = ""
            }
            return text
        }

        let text = textStack.removeLast()

        if mergeWithParent && !text.isEmpty && !textStack.isEmpty {
            textStack[textStack.count - 1] += text
        }

        return text
    }

    // MARK: - Parsing

    /// What this parse lost, for a caller that wants to tell the reader.
    ///
    /// Empty until the parse completes. Populated by `reportParseCompletion()`
    /// from the same audit that writes the log, so on the lines they share the
    /// two cannot silently diverge. The log is deliberately the wider of the
    /// two: the zero-author warning goes only there, and this carries the
    /// no-content line, which is not an unwind diagnostic at all.
    public private(set) var parseWarnings = JATSParseWarnings()

    /// What the parser still had open when the document ended, and what it saw
    /// close something that was never opened.
    ///
    /// The first six fields each count a stack or counter that decides
    /// *routing*: while one is non-zero, content is being filed somewhere other
    /// than the article body, so an imbalance is never cosmetic.
    /// `depthUnderflows` is the tally that stops the other six from reading
    /// clean after an over-pop. Zero across the board is the only shape a
    /// correct parse can end in.
    var unwindState: JATSParseUnwindState {
        JATSParseUnwindState(
            subArticleDepth: subArticleDepth,
            openFigures: figureCollector.openCount,
            openTables: tableCollector.openCount,
            exhibitFootnoteDepth: exhibitFootnoteDepth,
            openCaptions: captionStack.count,
            openSections: sectionStack.count,
            depthUnderflows: depthUnderflows
        )
    }

    /// Whether the parse produced anything at all.
    ///
    /// The predicate `parseToArticle` refuses on, shared with the audit so that
    /// a parse which produced nothing is reported once — as `.noContent` — and
    /// not also as an article that happens to have no authors.
    private var producedContent: Bool {
        !title.isEmpty || !abstractSections.isEmpty || !bodySections.isEmpty
    }

    /// The best name this parse can put on itself, for diagnostics.
    ///
    /// Every line `reportParseCompletion` emits carries it. Without one the
    /// diagnostics are unactionable in the place they are meant to be read: the
    /// full-text path builds two parsers over the same document — `XMLParser` is
    /// consumed by its first parse — so each line appears twice per article, and
    /// two identical lines with no identifier cannot be told from two genuinely
    /// broken articles.
    private var articleIdentifier: String {
        if !pmcId.isEmpty { return pmcId }
        return doi.isEmpty ? "an unidentified article" : doi
    }

    /// Report anything the parse left open, and any content it lost.
    ///
    /// Runs from ``runParser()`` so that every entry point audits: it used to
    /// live in `parseToArticle`, which **production never calls**. The full-text
    /// path is `parseToHTML` then `parseToMarkdown`, so the safety net for the
    /// whole class of unbalanced-stack defects — the class #156, #157, #169 and
    /// #173 all came from — was installed only in the test harness, which is
    /// where a defect is least likely to go unnoticed (#175).
    ///
    /// Deliberately not reached when `XMLParser` rejects the document: whatever
    /// was open at the point it gave up stays open, so auditing would emit a
    /// fistful of guaranteed imbalances on every malformed feed and train the
    /// reader to ignore the category. The parse error already says the document
    /// died.
    private func reportParseCompletion() {
        // Collected, not just logged. The unwind lines become `parseWarnings`
        // verbatim, so on the lines they share, what the caller can act on and
        // what a developer reads in the log cannot drift apart (#181). The two
        // are not equal: the zero-author warning below is logged only, and the
        // no-content line is added to both.
        var readerFacing = Self.unwindDiagnostics(unwindState)
        for line in readerFacing {
            BioMedLitLib.logger?.error("\(articleIdentifier): \(line)", category: .parsing)
        }

        if !producedContent {
            // Reported here rather than left to the caller because only
            // `parseToArticle` turns this into `.noContent`. `parseToHTML` and
            // `parseToMarkdown` measure their own output, and `buildHTML` emits
            // the identifiers line before anything else — which is never empty
            // in production, where `FullTextService` always supplies a known PMC
            // ID. Both paths therefore returned an article stripped to its own
            // accession number without a word, which is the shape #175 exists to
            // stop. The author warning is suppressed in the same breath: a parse
            // that produced nothing is one defect, not two.
            let line = "JATS parse extracted no title, abstract or body — "
                + "any rendered full text carries only its identifiers"
            BioMedLitLib.logger?.error("\(articleIdentifier): \(line)", category: .parsing)
            readerFacing.append(line)
        } else if authors.isEmpty {
            // Log only, and deliberately not in `parseWarnings`. A metadata gap
            // is not a truncation: editorials, corrections and errata carry no
            // authors legitimately, and a reader-facing banner that fires on
            // those is worth nothing on the article where content really was
            // discarded.
            BioMedLitLib.logger?.warning(
                "\(articleIdentifier): JATS parse produced zero authors",
                category: .parsing
            )
        }

        parseWarnings = JATSParseWarnings(diagnostics: readerFacing)
    }

    /// One line per stack or counter that did not unwind, naming what it cost.
    ///
    /// A pure function of the end state, and a static one, because that is the
    /// only way to exercise it: no well-formed document can trip it. `XMLParser`
    /// refuses an unbalanced document before the parse returns, and every guard
    /// inside the parser now tests the same predicate at both ends of the range
    /// it brackets — which is exactly the property this exists to notice the
    /// loss of.
    ///
    /// - Parameter state: What was still open when the document ended.
    /// - Returns: A diagnostic per imbalance, empty for a clean parse.
    static func unwindDiagnostics(_ state: JATSParseUnwindState) -> [String] {
        var lines: [String] = []

        if state.subArticleDepth > 0 {
            lines.append(
                "JATS sub-article depth ended at \(state.subArticleDepth), not 0 — "
                    + "content after the imbalance was discarded"
            )
        }
        if state.openFigures > 0 {
            lines.append(
                "JATS parse ended with \(state.openFigures) open <fig> — "
                    + "those figures and their content were discarded"
            )
        }
        if state.openTables > 0 {
            lines.append(
                "JATS parse ended with \(state.openTables) open <table-wrap> — "
                    + "those tables and their content were discarded"
            )
        }
        if state.exhibitFootnoteDepth > 0 {
            lines.append(
                "JATS exhibit footnote depth ended at \(state.exhibitFootnoteDepth), not 0 — "
                    + "prose after the imbalance was routed into a footnote and discarded"
            )
        }
        if state.openCaptions > 0 {
            lines.append(
                "JATS parse ended with \(state.openCaptions) open <caption> — "
                    + "prose after the imbalance was read as caption text"
            )
        }
        if state.openSections > 0 {
            lines.append(
                "JATS parse ended with \(state.openSections) open <sec> — "
                    + "those sections and their prose were never emitted"
            )
        }
        if state.depthUnderflows > 0 {
            lines.append(
                "JATS parse saw \(state.depthUnderflows) end tag(s) with nothing to close — "
                    + "a counter closed an element it never opened, so any other "
                    + "imbalance reported here understates what was misrouted"
            )
        }

        return lines
    }

    /// Run the underlying `XMLParser` exactly once.
    ///
    /// - Throws: ``JATSParseError/alreadyParsed`` if this instance has already
    ///   parsed, or ``JATSParseError/parsingFailed(_:)`` if the XML is not
    ///   well-formed.
    private func runParser() throws {
        guard !hasParsed else { throw JATSParseError.alreadyParsed }
        // Set before the parse, not after. A failed parse consumes the
        // `XMLParser` just as a successful one does, and `parseError` is never
        // cleared once `parser(_:parseErrorOccurred:)` has recorded it, so a
        // retry would re-report the *first* attempt's failure as though it were
        // its own — on top of the half-filled accumulators the first pass left
        // behind.
        hasParsed = true

        guard parser.parse() else {
            let errorMessage = parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "Unknown parsing error"
            throw JATSParseError.parsingFailed(errorMessage)
        }

        reportParseCompletion()
    }

    // MARK: - Public API

    /// Parse the XML and return markdown-formatted content.
    ///
    /// - Returns: Markdown string representation of the article.
    /// - Throws: `JATSParseError` if parsing fails, or
    ///   ``JATSParseError/alreadyParsed`` if this instance has already parsed —
    ///   an instance parses once, whichever entry point is used.
    public func parseToMarkdown() throws -> String {
        try runParser()

        let markdown = buildMarkdown()
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JATSParseError.noContent
        }

        return markdown
    }

    /// Parse the XML and return HTML-formatted content.
    ///
    /// HTML output provides better table rendering and semantic structure
    /// compared to markdown.
    ///
    /// - Returns: HTML string representation of the article (body content only, no wrapper).
    /// - Throws: `JATSParseError` if parsing fails, or
    ///   ``JATSParseError/alreadyParsed`` if this instance has already parsed —
    ///   an instance parses once, whichever entry point is used.
    public func parseToHTML() throws -> String {
        try runParser()

        let html = buildHTML()
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JATSParseError.noContent
        }

        return html
    }

    /// Parse the XML and return the structured article data.
    ///
    /// - Returns: `JATSArticle` containing all parsed data.
    /// - Throws: `JATSParseError` if parsing fails, or
    ///   ``JATSParseError/alreadyParsed`` if this instance has already parsed —
    ///   an instance parses once, whichever entry point is used.
    public func parseToArticle() throws -> JATSArticle {
        try runParser()

        // parseToMarkdown and parseToHTML both refuse an empty result; without the
        // same guard here a failed parse returned an empty-but-well-formed article,
        // indistinguishable from one the publisher deposited as a stub.
        //
        // The unwind audit and the zero-author warning that used to sit here run
        // from `runParser` now, so the two output paths production actually uses
        // hear them too — see `reportParseCompletion`.
        guard producedContent else {
            throw JATSParseError.noContent
        }

        return JATSArticle(
            title: title,
            authors: authors,
            journal: journal,
            volume: volume,
            issue: issue,
            pages: pages,
            year: year,
            doi: doi,
            pmcId: pmcId,
            pmid: pmid,
            abstractSections: abstractSections,
            bodySections: bodySections,
            figures: figures,
            tables: tables,
            references: references
        )
    }

    // MARK: - Markdown Builder

    /// Build the final markdown string from parsed content.
    private func buildMarkdown() -> String {
        var lines: [String] = []

        // Title
        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }

        // Authors
        if !authors.isEmpty {
            let authorString = formatAuthors()
            lines.append("**Authors:** \(authorString)")
            lines.append("")
        }

        // Journal info
        let journalInfo = formatJournalInfo()
        if !journalInfo.isEmpty {
            lines.append(journalInfo)
            lines.append("")
        }

        // Identifiers
        let identifiers = formatIdentifiers()
        if !identifiers.isEmpty {
            lines.append(identifiers)
            lines.append("")
        }

        // Abstract
        if !abstractSections.isEmpty {
            lines.append("## Abstract")
            lines.append("")
            for section in abstractSections {
                if !section.title.isEmpty {
                    lines.append("**\(section.title):** \(section.content)")
                } else {
                    lines.append(section.content)
                }
                lines.append("")
            }
        }

        // Body sections
        for section in bodySections {
            lines.append(contentsOf: formatBodySection(section, level: 2))
        }

        // Figures
        if !figures.isEmpty {
            lines.append("## Figures")
            lines.append("")
            for (index, figure) in figures.enumerated() {
                let figNum = figure.label.isEmpty ? "Figure \(index + 1)" : figure.label
                // Add anchor for linking from xrefs - blank line needed for parser to detect
                let anchorId = figure.id.isEmpty ? "fig\(index + 1)" : figure.id
                lines.append("<!-- anchor:\(anchorId) -->")
                lines.append("")
                lines.append("### \(figNum)")
                lines.append("")
                // Include figure image if URL is available
                if let graphicURL = figure.graphicURL {
                    // Build full URL for Europe PMC graphics
                    let fullURL = buildFigureURL(graphicURL)
                    lines.append("![Figure](\(fullURL))")
                    lines.append("")
                }
                if !figure.caption.isEmpty {
                    lines.append(figure.caption)
                    lines.append("")
                }
                for footnote in figure.footnotes {
                    lines.append(footnote)
                    lines.append("")
                }
            }
        }

        // Tables
        if !tables.isEmpty {
            lines.append("## Tables")
            lines.append("")
            for (index, table) in tables.enumerated() {
                let tableNum = table.label.isEmpty ? "Table \(index + 1)" : table.label
                // Add anchor for linking from xrefs - blank line needed for parser to detect
                let anchorId = table.id.isEmpty ? "table\(index + 1)" : table.id
                lines.append("<!-- anchor:\(anchorId) -->")
                lines.append("")
                lines.append("### \(tableNum)")
                if !table.caption.isEmpty {
                    lines.append("")
                    lines.append(table.caption)
                }
                lines.append("")
                // Include markdown table content if available
                if !table.markdownContent.isEmpty {
                    lines.append(table.markdownContent)
                    lines.append("")
                }
                for footnote in table.footnotes {
                    lines.append(footnote)
                    lines.append("")
                }
            }
        }

        // References
        if !references.isEmpty {
            lines.append("## References")
            lines.append("")
            for (index, ref) in references.enumerated() {
                let refNum = ref.label.isEmpty ? String(index + 1) : ref.label
                // Use formatted citation with full structured data
                lines.append("\(refNum). \(ref.formattedCitation)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Format authors for display.
    private func formatAuthors() -> String {
        let authorNames = authors.map { author -> String in
            var name = author.surname
            if !author.givenNames.isEmpty {
                name = "\(author.givenNames) \(name)"
            }
            return name
        }

        let maxAuthors = BioMedLitConstants.maxAuthorsBeforeEtAl
        if authorNames.count <= maxAuthors {
            return authorNames.joined(separator: ", ")
        } else {
            let firstAuthors = authorNames.prefix(maxAuthors).joined(separator: ", ")
            return "\(firstAuthors) et al."
        }
    }

    /// Format journal information.
    private func formatJournalInfo() -> String {
        var parts: [String] = []

        if !journal.isEmpty {
            parts.append("*\(journal)*")
        }

        var volumeInfo: [String] = []
        if !volume.isEmpty {
            volumeInfo.append(volume)
        }
        if !issue.isEmpty {
            volumeInfo.append("(\(issue))")
        }
        if !pages.isEmpty {
            volumeInfo.append(": \(pages)")
        }
        if !volumeInfo.isEmpty {
            parts.append(volumeInfo.joined())
        }

        if !year.isEmpty {
            parts.append("(\(year))")
        }

        return parts.joined(separator: " ")
    }

    /// Format document identifiers.
    private func formatIdentifiers() -> String {
        var ids: [String] = []

        if !doi.isEmpty {
            ids.append("DOI: \(doi)")
        }
        if !pmcId.isEmpty {
            ids.append("PMC: \(pmcId)")
        }
        if !pmid.isEmpty {
            ids.append("PMID: \(pmid)")
        }

        return ids.joined(separator: " | ")
    }

    /// Build a complete URL for a figure graphic.
    ///
    /// Europe PMC graphics use relative paths like "13023_2014_170_Fig1_HTML"
    /// which need to be prefixed with the base URL. The XML often doesn't include
    /// the file extension, so we build a URL pattern that the viewer can try
    /// with different extensions (.gif, .jpg).
    ///
    /// - Parameter path: The graphic path or href from the XML.
    /// - Returns: Complete URL string for the figure (without extension if unknown).
    private func buildFigureURL(_ path: String) -> String {
        // If already a full URL, return as-is
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }

        // If path already has an image extension, keep it
        let hasExtension = [".gif", ".jpg", ".jpeg", ".png", ".svg"]
            .contains { path.lowercased().hasSuffix($0) }

        // Europe PMC figure URL pattern
        // Use europepmc.org which properly serves images (NCBI returns 403)
        // Pattern: https://europepmc.org/articles/PMC{id}/bin/{filename}
        if !pmcId.isEmpty {
            let normalizedPMCId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"
            let baseURL = "https://europepmc.org/articles/\(normalizedPMCId)/bin/\(path)"

            // If no extension, add .jpg as default (most common)
            // AsyncFigureView will try other extensions if this fails
            if !hasExtension {
                return baseURL + ".jpg"
            }
            return baseURL
        }

        // Return path as-is if we can't build a full URL
        return path
    }

    /// Format a body section recursively.
    private func formatBodySection(_ section: JATSBodySection, level: Int) -> [String] {
        var lines: [String] = []
        let headingPrefix = String(repeating: "#", count: min(level, BioMedLitConstants.maxHeadingLevel))

        if !section.title.isEmpty {
            lines.append("\(headingPrefix) \(section.title)")
            lines.append("")
        }

        for paragraph in section.paragraphs {
            if !paragraph.isEmpty {
                lines.append(paragraph)
                lines.append("")
            }
        }

        for subsection in section.subsections {
            lines.append(contentsOf: formatBodySection(subsection, level: level + 1))
        }

        return lines
    }

    // MARK: - HTML Builder

    /// Build the final HTML string from parsed content.
    ///
    /// Generates semantic HTML with proper table structure, figure elements,
    /// and anchor IDs for navigation.
    private func buildHTML() -> String {
        var html: [String] = []

        // Title
        if !title.isEmpty {
            html.append("<h1>\(escapeHTML(title))</h1>")
        }

        // Authors
        if !authors.isEmpty {
            let authorString = formatAuthors()
            html.append("<p class=\"authors\"><strong>Authors:</strong> \(escapeHTML(authorString))</p>")
        }

        // Journal info
        let journalInfo = formatJournalInfoHTML()
        if !journalInfo.isEmpty {
            html.append("<p class=\"journal-info\">\(journalInfo)</p>")
        }

        // Identifiers
        let identifiers = formatIdentifiersHTML()
        if !identifiers.isEmpty {
            html.append("<p class=\"identifiers\">\(identifiers)</p>")
        }

        // Abstract
        if !abstractSections.isEmpty {
            html.append("<h2>Abstract</h2>")
            for section in abstractSections {
                if !section.title.isEmpty {
                    html.append("<p><strong>\(escapeHTML(section.title)):</strong> \(escapeHTML(section.content))</p>")
                } else {
                    html.append("<p>\(escapeHTML(section.content))</p>")
                }
            }
        }

        // Body sections
        for section in bodySections {
            html.append(contentsOf: formatBodySectionHTML(section, level: 2))
        }

        // Figures
        if !figures.isEmpty {
            html.append("<h2>Figures</h2>")
            for (index, figure) in figures.enumerated() {
                let figNum = figure.label.isEmpty ? "Figure \(index + 1)" : figure.label
                let anchorId = figure.id.isEmpty ? "fig\(index + 1)" : figure.id

                html.append("<figure id=\"\(escapeHTML(anchorId))\">")
                if let graphicURL = figure.graphicURL {
                    let fullURL = buildFigureURL(graphicURL)
                    // Use onerror to try alternative extensions
                    html.append("  <img src=\"\(escapeHTML(fullURL))\" alt=\"\(escapeHTML(figNum))\" " +
                        "onerror=\"this.onerror=null; tryAlternativeExtensions(this);\" loading=\"lazy\">")
                }
                html.append("  <figcaption>")
                html.append("    <strong>\(escapeHTML(figNum))</strong>")
                if !figure.caption.isEmpty {
                    html.append("    <p>\(escapeHTML(figure.caption))</p>")
                }
                for footnote in figure.footnotes {
                    html.append("    <p class=\"footnote\">\(escapeHTML(footnote))</p>")
                }
                html.append("  </figcaption>")
                html.append("</figure>")
            }
        }

        // Tables
        if !tables.isEmpty {
            html.append("<h2>Tables</h2>")
            for (index, table) in tables.enumerated() {
                let tableNum = table.label.isEmpty ? "Table \(index + 1)" : table.label
                let anchorId = table.id.isEmpty ? "table\(index + 1)" : table.id

                html.append("<div class=\"table-container\" id=\"\(escapeHTML(anchorId))\">")
                html.append("  <h3>\(escapeHTML(tableNum))</h3>")
                if !table.caption.isEmpty {
                    html.append("  <p class=\"table-caption\">\(escapeHTML(table.caption))</p>")
                }
                // Build HTML table from rows
                html.append(buildHTMLTable(table))
                for footnote in table.footnotes {
                    html.append("  <p class=\"table-footnote\">\(escapeHTML(footnote))</p>")
                }
                html.append("</div>")
            }
        }

        // References
        if !references.isEmpty {
            html.append("<h2>References</h2>")
            html.append("<ol class=\"references\">")
            for ref in references {
                html.append("  <li id=\"ref-\(escapeHTML(ref.id))\">\(formatReferenceHTML(ref))</li>")
            }
            html.append("</ol>")
        }

        return html.joined(separator: "\n")
    }

    /// Format journal information as HTML.
    private func formatJournalInfoHTML() -> String {
        var parts: [String] = []

        if !journal.isEmpty {
            parts.append("<em>\(escapeHTML(journal))</em>")
        }

        var volumeInfo: [String] = []
        if !volume.isEmpty {
            volumeInfo.append(volume)
        }
        if !issue.isEmpty {
            volumeInfo.append("(\(issue))")
        }
        if !pages.isEmpty {
            volumeInfo.append(": \(pages)")
        }
        if !volumeInfo.isEmpty {
            parts.append(escapeHTML(volumeInfo.joined()))
        }

        if !year.isEmpty {
            parts.append("(\(escapeHTML(year)))")
        }

        return parts.joined(separator: " ")
    }

    /// Format document identifiers as HTML.
    private func formatIdentifiersHTML() -> String {
        var ids: [String] = []

        if !doi.isEmpty {
            ids.append("DOI: <a href=\"https://doi.org/\(escapeHTML(doi))\">\(escapeHTML(doi))</a>")
        }
        if !pmcId.isEmpty {
            let pmcNum = pmcId.hasPrefix("PMC") ? String(pmcId.dropFirst(3)) : pmcId
            ids.append("PMC: <a href=\"https://europepmc.org/article/PMC/\(escapeHTML(pmcNum))\">\(escapeHTML(pmcId))</a>")
        }
        if !pmid.isEmpty {
            ids.append("PMID: <a href=\"https://pubmed.ncbi.nlm.nih.gov/\(escapeHTML(pmid))/\">\(escapeHTML(pmid))</a>")
        }

        return ids.joined(separator: " | ")
    }

    /// Format a body section recursively as HTML.
    private func formatBodySectionHTML(_ section: JATSBodySection, level: Int) -> [String] {
        var html: [String] = []
        let headingLevel = min(level, BioMedLitConstants.maxHeadingLevel)

        if !section.title.isEmpty {
            html.append("<h\(headingLevel)>\(escapeHTML(section.title))</h\(headingLevel)>")
        }

        for paragraph in section.paragraphs {
            if !paragraph.isEmpty {
                // Convert markdown-style links to HTML links
                let htmlParagraph = convertInlineLinksToHTML(paragraph)
                html.append("<p>\(htmlParagraph)</p>")
            }
        }

        for subsection in section.subsections {
            html.append(contentsOf: formatBodySectionHTML(subsection, level: level + 1))
        }

        return html
    }

    /// Build an HTML table from TableInfo.
    private func buildHTMLTable(_ table: JATSTableInfo) -> String {
        var html: [String] = []

        // Parse the markdown table back into rows for HTML generation
        // This is a workaround since we currently store markdown format
        let tableRows = parseMarkdownTableRows(table.markdownContent)

        guard !tableRows.isEmpty else {
            return "<p><em>Table content unavailable</em></p>"
        }

        html.append("  <table>")

        // First row is header if we have more than one row
        let hasHeader = tableRows.count > 1
        if hasHeader {
            html.append("    <thead>")
            html.append("      <tr>")
            for cell in tableRows[0] {
                html.append("        <th>\(escapeHTML(cell))</th>")
            }
            html.append("      </tr>")
            html.append("    </thead>")
        }

        // Body rows
        let bodyRows = hasHeader ? Array(tableRows.dropFirst()) : tableRows
        if !bodyRows.isEmpty {
            html.append("    <tbody>")
            for row in bodyRows {
                html.append("      <tr>")
                for cell in row {
                    html.append("        <td>\(escapeHTML(cell))</td>")
                }
                html.append("      </tr>")
            }
            html.append("    </tbody>")
        }

        html.append("  </table>")
        return html.joined(separator: "\n")
    }

    /// Parse markdown table content back into rows.
    private func parseMarkdownTableRows(_ markdown: String) -> [[String]] {
        var rows: [[String]] = []

        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and separator lines (| --- | --- |)
            if trimmed.isEmpty { continue }
            if trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) { continue }

            // Parse cells from pipe-separated line
            var cells: [String] = []
            var content = trimmed

            // Remove leading/trailing pipes
            if content.hasPrefix("|") { content = String(content.dropFirst()) }
            if content.hasSuffix("|") { content = String(content.dropLast()) }

            // Split by pipe and trim
            let parts = content.components(separatedBy: "|")
            for part in parts {
                // Unescape any escaped pipes
                let cell = part.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\|", with: "|")
                cells.append(cell)
            }

            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        return rows
    }

    /// Format a reference as HTML.
    private func formatReferenceHTML(_ ref: JATSReferenceInfo) -> String {
        var parts: [String] = []

        // Authors
        let maxAuthors = BioMedLitConstants.maxAuthorsBeforeEtAl
        if !ref.authors.isEmpty {
            if ref.authors.count <= maxAuthors {
                parts.append(escapeHTML(ref.authors.joined(separator: ", ")))
            } else {
                let firstAuthors = ref.authors.prefix(maxAuthors - 1).joined(separator: ", ")
                parts.append(escapeHTML("\(firstAuthors), et al."))
            }
        }

        // Article title
        if !ref.articleTitle.isEmpty {
            parts.append(escapeHTML(ref.articleTitle))
        }

        // Journal name (italicized)
        if !ref.source.isEmpty {
            parts.append("<em>\(escapeHTML(ref.source))</em>")
        }

        // Year
        if !ref.year.isEmpty {
            parts.append("(\(escapeHTML(ref.year)))")
        }

        // Volume and pages
        var volumeInfo = ""
        if !ref.volume.isEmpty {
            volumeInfo = ref.volume
            if !ref.issue.isEmpty {
                volumeInfo += "(\(ref.issue))"
            }
        }
        if !ref.firstPage.isEmpty {
            if !volumeInfo.isEmpty {
                volumeInfo += ":"
            }
            volumeInfo += ref.firstPage
            if !ref.lastPage.isEmpty {
                volumeInfo += "-\(ref.lastPage)"
            }
        }
        if !volumeInfo.isEmpty {
            parts.append(escapeHTML(volumeInfo))
        }

        // DOI link
        if !ref.doi.isEmpty {
            parts.append("<a href=\"https://doi.org/\(escapeHTML(ref.doi))\">doi:\(escapeHTML(ref.doi))</a>")
        }

        if parts.isEmpty {
            return escapeHTML(ref.citation)
        }

        return parts.joined(separator: ". ")
    }

    /// Convert markdown-style anchor links to HTML links.
    ///
    /// Converts `[text](#anchor)` to `<a href="#anchor">text</a>`.
    private func convertInlineLinksToHTML(_ text: String) -> String {
        var result = ""
        var remaining = text

        // Pattern: [link text](#anchor-id)
        while let bracketStart = remaining.firstIndex(of: "[") {
            // Add text before the bracket
            result += escapeHTML(String(remaining[..<bracketStart]))

            // Find closing bracket
            var depth = 0
            var bracketEnd: String.Index?
            var index = bracketStart

            while index < remaining.endIndex {
                if remaining[index] == "[" {
                    depth += 1
                } else if remaining[index] == "]" {
                    depth -= 1
                    if depth == 0 {
                        bracketEnd = index
                        break
                    }
                }
                index = remaining.index(after: index)
            }

            guard let bracketEnd = bracketEnd,
                  remaining.index(after: bracketEnd) < remaining.endIndex,
                  remaining[remaining.index(after: bracketEnd)] == "(" else {
                // Not a valid link, add the bracket and continue
                result += "["
                remaining = String(remaining[remaining.index(after: bracketStart)...])
                continue
            }

            let linkText = String(remaining[remaining.index(after: bracketStart)..<bracketEnd])

            // Find the href
            let parenStart = remaining.index(after: bracketEnd)
            guard let parenEnd = remaining[parenStart...].firstIndex(of: ")") else {
                result += "[\(escapeHTML(linkText))]"
                remaining = String(remaining[remaining.index(after: bracketEnd)...])
                continue
            }

            let href = String(remaining[remaining.index(after: parenStart)..<parenEnd])
            result += "<a href=\"\(escapeHTML(href))\">\(escapeHTML(linkText))</a>"
            remaining = String(remaining[remaining.index(after: parenEnd)...])
        }

        // Add any remaining text
        result += escapeHTML(remaining)

        return result
    }

    /// Escape HTML special characters.
    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - XMLParserDelegate

extension JATSXMLParser: XMLParserDelegate {
    // MARK: - Contributor Helpers

    /// Whether a `<contrib>` is an author.
    ///
    /// An explicit `contrib-type` decides on its own — that is the contributor's
    /// own claim, and it must be able to say "editor" inside a group of authors.
    /// A `<contrib>` carrying none inherits the group: an author group, or a
    /// `<contrib-group>` with no `content-type` at all, which JATS treats as
    /// authors by convention.
    ///
    /// - Parameter attributes: Attributes of the `<contrib>` element.
    /// - Returns: True if this contributor should be collected as an author.
    private func isAuthorContrib(_ attributes: [String: String]) -> Bool {
        if let type = attributes["contrib-type"]?.lowercased() {
            return type == "author"
        }
        guard let groupType = currentContribGroupType else { return true }
        return groupType == "author" || groupType == "authors"
    }

    // MARK: - Section and Caption Helpers

    /// Append caption prose to whichever of the figure or table is open.
    ///
    /// A `<caption>` carries a `<title>` lead and one or more `<p>` elements,
    /// which arrive in document order, so they are joined with a single space
    /// into the one `caption` string the models expose.
    ///
    /// - Parameters:
    ///   - text: Whitespace-normalised text of the caption child element.
    ///   - owner: What the innermost open `<caption>` hangs off.
    private func appendCaptionText(_ text: String, to owner: CaptionOwner) {
        guard !text.isEmpty else { return }

        switch owner {
        case .figure:
            withCurrentFigure { figure in
                if !figure.caption.isEmpty {
                    figure.caption += " "
                }
                figure.caption += text
            }
        case .table:
            withCurrentTable { table in
                if !table.caption.isEmpty {
                    table.caption += " "
                }
                table.caption += text
            }
        case .unmodelled:
            // No model to put it in, but it is emphatically not section prose.
            // Logged so the omission is discoverable rather than silent.
            BioMedLitLib.logger?.debug(
                "Dropped caption text from an unmodelled caption host: \(text)",
                category: .parsing
            )
        }
    }

    /// Append footnote prose to whichever of the figure or table is open.
    ///
    /// `<table-wrap-foot>` carries the abbreviation expansions, significance
    /// markers and per-table funding notes that the rendered table itself does
    /// not reproduce, so they are kept rather than discarded with the cell
    /// furniture.
    ///
    /// - Parameter text: Whitespace-normalised text of the footnote paragraph.
    private func appendFootnoteText(_ text: String) {
        guard !text.isEmpty else { return }

        switch innermostExhibit {
        case .figure:
            withCurrentFigure { $0.appendFootnote(text) }
        case .table:
            withCurrentTable { $0.appendFootnote(text) }
        case nil:
            break
        }
    }

    /// Hold a `<fn>`'s own marker on the exhibit that owns the footnote.
    ///
    /// The marker is written when `</label>` closes and consumed by the first
    /// footnote paragraph after it; `</fn>` clears any that went unused by
    /// passing an empty string.
    ///
    /// - Parameter marker: The footnote's `<label>` text, or `""` to clear.
    private func setPendingFootnoteLabel(_ marker: String) {
        switch innermostExhibit {
        case .figure:
            withCurrentFigure { $0.pendingFootnoteLabel = marker }
        case .table:
            withCurrentTable { $0.pendingFootnoteLabel = marker }
        case nil:
            break
        }
    }

    /// Emit any pending unsectioned `<body>` prose as a body section.
    ///
    /// Called when a real `<sec>` opens and again at `</body>`, so loose
    /// paragraphs keep their position in document order. The section carries no
    /// title — JATS gave it none, and inventing one would put a heading in the
    /// rendered article that the publisher never wrote.
    private func flushImplicitBodySection() {
        guard let pending = implicitBodySection else { return }
        bodySections.append(pending.build())
        implicitBodySection = nil
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)

        // Push a new text buffer for text-accumulating elements
        if textAccumulatingElements.contains(elementName) {
            pushTextBuffer()
        }

        // Sub-article content belongs to the sub-article, not to this one. The
        // stack and the text buffers above are still maintained, so the two stay
        // balanced across the skipped region and `</sub-article>` lands correctly.
        if elementName == "sub-article" || elementName == "response" {
            subArticleDepth += 1
            return
        }
        guard !inSubArticle else { return }

        switch elementName {
        // Document structure
        case "front":
            inFront = true
        case "article-meta":
            inArticleMeta = true
        case "contrib-group":
            contribGroupTypeStack.append(attributeDict["content-type"]?.lowercased())
        case "contrib":
            if isAuthorContrib(attributeDict) {
                inContrib = true
                currentAuthor = AuthorBuilder()
            }
        case "aff":
            inAff = true
            if let id = attributeDict["id"] {
                currentAffiliations[id] = ""
            }
        case "abstract":
            inAbstract = true
            currentAbstractLabel = attributeDict["abstract-type"] ?? ""
            currentAbstractTitle = ""
            currentAbstractText = []
        case "body":
            inBody = true
        case "back":
            inBack = true
        case "sec":
            // An <abstract> may be structured with <sec>. Those belong to the
            // abstract, which has its own accumulator — pushing a builder for them
            // appended an empty section to bodySections at every </sec>, ahead of
            // the real ones. The pop below carries the same guard, so the stack
            // stays balanced.
            if !inAbstract {
                // Flush first, so prose that preceded this <sec> becomes its own
                // body section rather than being folded in after the sectioned content.
                flushImplicitBodySection()
                let builder = SectionBuilder()
                sectionStack.append(builder)
            }
        case "caption":
            // The caption's own parent decides, not the ambient figure/table
            // flags — see `CaptionOwner`.
            switch enclosingElement {
            case "fig":
                captionStack.append(.figure)
            case "table-wrap":
                captionStack.append(.table)
            default:
                captionStack.append(.unmodelled)
            }
        case "fig":
            // The collector lists a figure from where it opened, not from where
            // it closed, so a nested figure cannot precede the one containing it.
            var builder = FigureBuilder()
            builder.id = attributeDict["id"] ?? ""
            figureCollector.begin(builder)
        case "graphic":
            // The image belongs to the element that holds it, not to whichever
            // exhibit happens to be open. `<graphic>` is a child of `<table-wrap>`
            // too — all 8 tables in
            // `doc/cross_platform/jats_corpus/PMC12759138.xml` are deposited as
            // images that way — so a table inside a `<fig>` offered its picture to
            // the enclosing figure, displacing the figure's own or losing the
            // ranking below. The same defect as `<label>` one element over (#169);
            // the ambient flag is what made it invisible.
            //
            // A table's own image is still not captured — `JATSTableInfo` has
            // nowhere to put it (#172). Not routing it to the figure is the point:
            // a wrong image is worse than none.
            if graphicOwner == "fig" {
                let href = attributeDict["xlink:href"]
                    ?? attributeDict["href"]
                    ?? attributeDict["xlink-href"]
                if let href = href {
                    // A figure commonly deposits the same image more than once —
                    // a thumbnail beside the full picture, or an archival master
                    // ahead of the web derivative in <alternatives>. Assigning
                    // unconditionally kept whichever came last, which is the
                    // thumbnail at PLOS and Springer (#161). Ranking them keeps
                    // the best deposit whatever order they arrive in, since the
                    // two conventions disagree about which end is which.
                    let suitability = Self.graphicSuitability(attributeDict)
                    withCurrentFigure { figure in
                        let held = figure.graphicHref
                        figure.offerGraphic(href, suitability: suitability)
                        if figure.graphicHref != href, !held.isEmpty {
                            // Only one href fits in JATSFigureInfo, so a genuine
                            // second image — a multi-panel figure deposited panel
                            // by panel — is lost here. Logged for the reason the
                            // unmodelled caption host is: the omission should be
                            // discoverable rather than silent.
                            BioMedLitLib.logger?.debug(
                                "Figure \(figure.id.isEmpty ? "(unidentified)" : figure.id) "
                                    + "has another <graphic>; kept \(held), dropped \(href)",
                                category: .parsing
                            )
                        }
                    }
                }
            }
        case "table-wrap":
            // A stack, for the reason `<fig>` has one: a `<table-wrap>` inside
            // another table's `<table-wrap-foot>` used to overwrite the outer
            // table's builder, and the outer end tag then found nothing to
            // build (#173).
            var builder = TableBuilder()
            builder.id = attributeDict["id"] ?? ""
            tableCollector.begin(builder)
        case "table-wrap-foot":
            exhibitFootnoteDepth += 1
        case "fn":
            // Only footnotes belonging to a figure or table. A <fn> in <back>'s
            // <fn-group> is article back matter and routes as ordinary prose.
            //
            // Asked of the element stack, not of the ambient flags, so that the
            // increment, the matching decrement at `</fn>` and the routing in
            // `appendFootnoteText` all answer the same question. Only the
            // decrement is load-bearing today — see there — but a counter whose
            // two ends test different predicates is a defect waiting for a shape
            // that separates them.
            if innermostExhibit != nil {
                exhibitFootnoteDepth += 1
            }
        case "thead":
            if inTableWrap {
                withCurrentTable { $0.startHeader() }
            }
        case "tbody":
            if inTableWrap {
                withCurrentTable { $0.startBody() }
            }
        case "tr":
            if inTableWrap {
                withCurrentTable { $0.startRow() }
            }
        case "th":
            if inTableWrap {
                let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
                withCurrentTable { $0.startCell(isHeader: true, colspan: colspan) }
            }
        case "td":
            if inTableWrap {
                let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
                withCurrentTable { $0.startCell(isHeader: false, colspan: colspan) }
            }
        case "list":
            if inTableWrap {
                // Check if ordered list (list-type="order" or "ordered")
                let listTypeAttr = attributeDict["list-type"] ?? ""
                let isOrdered = listTypeAttr.hasPrefix("order")
                withCurrentTable { $0.startList(ordered: isOrdered) }
            }
        case "list-item":
            if inTableWrap {
                withCurrentTable { $0.startListItem() }
            }
        case "ref-list":
            inRefList = true
        case "ref":
            inRef = true
            currentReference = ReferenceBuilder()
            currentReference?.id = attributeDict["id"] ?? ""
        case "mixed-citation", "element-citation":
            if inRef {
                inRefCitation = true
            }
        case "person-group":
            if inRefCitation {
                inRefPersonGroup = true
            }
        case "name":
            // Start of an author name within reference - handled in didEndElement
            break
        case "pub-id":
            // Handled in didEndElement with pub-id-type attribute
            break
        case "article-id":
            // Capture the pub-id-type attribute for proper ID classification
            currentArticleIdType = attributeDict["pub-id-type"]

        // Inline formatting
        case "bold", "b":
            inlineFormattingStack.append(.bold)
        case "italic", "i":
            inlineFormattingStack.append(.italic)
        case "sub":
            inlineFormattingStack.append(.subscript)
        case "sup":
            inlineFormattingStack.append(.superscript)
        case "monospace", "code":
            inlineFormattingStack.append(.monospace)

        // Cross-references (figure/table links)
        case "xref":
            currentXrefType = attributeDict["ref-type"]
            currentXrefRid = attributeDict["rid"]

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
        // Also append to table cell if we're in a table cell
        if inTableWrap {
            withCurrentTable { $0.appendCellText(string) }
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        // Pop text buffer if this was a text-accumulating element
        let elementText: String
        if textAccumulatingElements.contains(elementName) {
            // Inline elements merge their text with parent, EXCEPT for xrefs
            // to figures/tables which we handle specially (replacing text with link)
            let isInlineElement = isInlineTextElement(elementName)
            let isFigureOrTableXref = elementName == "xref" &&
                (currentXrefType == "fig" || currentXrefType == "figure" ||
                 currentXrefType == "table" || currentXrefType == "table-wrap")
            elementText = popTextBuffer(mergeWithParent: isInlineElement && !isFigureOrTableXref)
        } else {
            elementText = currentText
        }

        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalizeWhitespace(elementText)

        defer {
            _ = elementStack.popLast()
        }

        // See didStartElement. Handled before the guard, or `</sub-article>` would
        // be skipped by the very depth it is supposed to clear.
        if elementName == "sub-article" || elementName == "response" {
            decrementDepth(&subArticleDepth)
            return
        }
        guard !inSubArticle else { return }

        switch elementName {
        // Document structure
        case "front":
            inFront = false
        case "article-meta":
            inArticleMeta = false
        case "contrib-group":
            _ = contribGroupTypeStack.popLast()
        case "contrib":
            if inContrib, let author = currentAuthor?.build() {
                authors.append(author)
            }
            inContrib = false
            currentAuthor = nil
        case "aff":
            inAff = false

        // Metadata fields
        case "journal-title":
            if inFront {
                journal = text
            }
        case "article-id":
            if let parent = enclosingElement {
                if parent == "article-meta" || inFront {
                    // Use the pub-id-type attribute if available
                    if let idType = currentArticleIdType {
                        switch idType.lowercased() {
                        case "doi":
                            // An empty typed element must not latch: it would store
                            // an empty DOI and then stop classifyArticleIdByPattern
                            // recovering a real one later in the document.
                            guard !text.isEmpty else { break }
                            doi = text
                            doiIsAuthoritative = true
                        case "pmc", "pmcid":
                            // See "doi": an empty element must not latch either.
                            guard !text.isEmpty else { break }
                            // A caller-supplied id wins: the two should agree, and
                            // if they do not, the caller knows which article it asked for.
                            if pmcId.isEmpty {
                                pmcId = text
                            } else if pmcId != text {
                                // A disagreement is not just a choice of value: it
                                // says this XML may be for a different article than
                                // the one that was requested.
                                BioMedLitLib.logger?.warning(
                                    "JATS PMC ID mismatch: caller supplied \(pmcId), "
                                        + "document declares \(text). This XML may be "
                                        + "for a different article.",
                                    category: .parsing
                                )
                            }
                            pmcIdIsAuthoritative = true
                        case "pmcid-ver", "pmcaid", "pmcaiid":
                            // PMC-related but not the canonical id: `pmcid-ver` carries a
                            // version suffix, `pmcaid`/`pmcaiid` are PMC's internal numeric
                            // article ids. Recognised so they do not reach pattern matching,
                            // where the first would replace the canonical PMC ID and the
                            // others would be mistaken for a PMID.
                            break
                        case "pmid", "pubmed":
                            pmid = text
                        default:
                            // Fall back to pattern matching
                            classifyArticleIdByPattern(text)
                        }
                    } else {
                        // No type attribute, use pattern matching
                        classifyArticleIdByPattern(text)
                    }
                    currentArticleIdType = nil
                }
            }

        // Abstract
        case "abstract":
            if !currentAbstractText.isEmpty {
                let content = currentAbstractText.joined(separator: " ")
                abstractSections.append(JATSAbstractSection(
                    title: currentAbstractTitle,
                    content: content
                ))
            }
            inAbstract = false
        case "title":
            if let owner = captionStack.last {
                // <caption><title> is the caption's lead, not a section heading —
                // but it is the same element name as one, so without this it
                // would rename the enclosing <sec> after the figure. Tested before
                // every prose branch, and for every caption host rather than only
                // <fig>/<table-wrap>: JATS allows a caption on
                // <supplementary-material>, <media>, <boxed-text> and more.
                appendCaptionText(normalizedText, to: owner)
            } else if inAbstract {
                // If we had previous content, save it before starting new section
                if !currentAbstractText.isEmpty {
                    let content = currentAbstractText.joined(separator: " ")
                    abstractSections.append(JATSAbstractSection(
                        title: currentAbstractTitle,
                        content: content
                    ))
                    currentAbstractText = []
                }
                currentAbstractTitle = text
            } else if enclosingElement == "sec", !sectionStack.isEmpty {
                // A section is named by its own <title>, not by any title that
                // happens to close while it is open. `<fn-group>`, `<ref-list>`,
                // `<glossary>` and `<app>` all carry one, and asking nothing but
                // "is a section open?" let an eLife back-matter section report
                // "Author contributions" — the last of the two `<fn-group>`
                // titles inside it — instead of "Additional information" (#167,
                // live in `doc/cross_platform/jats_corpus/PMC8754430.xml`).
                //
                // `<sec>` is the only element that pushes a builder, so the
                // parent test *is* the "does this title own that builder?" test.
                //
                // The converse needs the branch order to hold: a `<sec>` inside
                // an `<abstract>` pushes nothing, so "parent is `<sec>`" would not
                // imply an owned builder if `inAbstract` above did not claim those
                // titles first. The emptiness check guards the subscript either
                // way.
                sectionStack[sectionStack.count - 1].title = normalizedText
            }
        case "p":
            if let owner = captionStack.last {
                // See case "title": any open <caption> owns its prose.
                appendCaptionText(normalizedText, to: owner)
            } else if inInnermostExhibitFootnote {
                // <table-wrap-foot> is not reproduced by the rendered table, so it
                // is captured rather than dropped with the cell furniture below.
                // Tested ahead of the exhibit-internals branch below for the
                // reason the "label" case reads its parent, though to the opposite
                // end: this branch keeps the footnote's prose where that one keeps
                // the footnote's marker away from the exhibit's own label.
                appendFootnoteText(normalizedText)
            } else if innermostExhibit != nil {
                // Remaining figure and table internals — cell <p>, mostly — tested
                // before every prose branch because a <fig> or <table-wrap> usually
                // sits inside a <sec>: asking about the section first would reprint
                // the cells as article prose. The rendered table already carries
                // them, so there is deliberately nothing to do here.
            } else if inAbstract {
                if !normalizedText.isEmpty {
                    currentAbstractText.append(normalizedText)
                }
            } else if (inBody || inBack), !sectionStack.isEmpty {
                // Capture paragraphs in both body and back matter sections
                sectionStack[sectionStack.count - 1].paragraphs.append(normalizedText)
            } else if inBody || inBack, !normalizedText.isEmpty {
                // An unsectioned <body> or <back> child. <sec> is optional in both,
                // and <ack>/<notes>/<fn-group> routinely hold <p> directly — which
                // is where funding acknowledgements and competing-interest
                // statements live, so dropping them blinded the transparency
                // analysis. Empty paragraphs are dropped rather than opening a
                // section, so a body holding nothing but whitespace stays
                // section-less.
                if implicitBodySection == nil {
                    implicitBodySection = SectionBuilder()
                }
                implicitBodySection?.paragraphs.append(normalizedText)
            }

        // Body and back matter sections
        case "body":
            flushImplicitBodySection()
            inBody = false
        case "back":
            // Mirrors </body>: flush before the flag clears, or unsectioned back
            // matter would never be emitted.
            flushImplicitBodySection()
            inBack = false
        case "sec":
            // Guarded to match the push in didStartElement — see the comment there.
            // `</sec>` inside an abstract fires before `</abstract>` clears the flag,
            // so the two guards see the same state.
            if !inAbstract, let builder = popTrackingUnderflow(&sectionStack) {
                let section = builder.build()
                if sectionStack.isEmpty {
                    bodySections.append(section)
                } else {
                    sectionStack[sectionStack.count - 1].subsections.append(section)
                }
            }

        // Figures
        case "fig":
            if !figureCollector.end() {
                // Counted, not only logged. This is the same event as an
                // over-decrement, and reaching the log alone is what #181 exists
                // to stop: a loss the parser noticed and the reader never heard.
                depthUnderflows += 1
                BioMedLitLib.logger?.error(
                    "JATS </fig> with no open <fig> for \(articleIdentifier) — "
                        + "the figure and its content were discarded",
                    category: .parsing
                )
            }
        case "label":
            // Routed by the element it hangs off, never by which exhibit happens
            // to be open. `<label>` appears on `<fn>`, `<fig>`, `<table-wrap>`
            // and `<ref>` alike, and the ambient flags cannot tell those apart:
            // a footnote marker — "a", "b", "*" — overwrote its exhibit's own
            // number (#157, 27 of 225 surveyed articles carry a labelled
            // `<table-wrap-foot><fn>`; `PMC12661592`'s only table reported "a"),
            // and a `<table-wrap>` inside a `<fig>` handed the figure its number
            // (#169). Reading the parent settles both, and settles them for the
            // nested cases the depth guard it replaces had to enumerate: a
            // `<fig>` opened *inside* a footnote is a `<fig>`, whatever the
            // depth.
            switch enclosingElement {
            case "fn":
                // Held rather than dropped: `<sup>` is flattened into the cell
                // text around it, so the table body still reads `12.3a` and the
                // footnote has to say which one it is.
                setPendingFootnoteLabel(text)
            case "fig":
                withCurrentFigure { $0.label = text }
            case "table-wrap":
                withCurrentTable { $0.label = text }
            case "ref":
                currentReference?.label = text
            default:
                // Hosts the parser has no model for. Two groups, which reached
                // this branch by different routes.
                //
                // `<aff>`, `<corresp>`, `<disp-formula>` and
                // `<supplementary-material>` — 43 across the committed corpus —
                // were dropped before this switch too, since all 43 fall outside
                // any exhibit and any `<ref>`. What the parent test adds is that a
                // `<supplementary-material>` label *inside* a `<fig>` no longer
                // becomes the figure's. Capturing them properly is #144 (the
                // supplement's own furniture) and #154 (affiliation markers).
                //
                // `<element-citation>` and `<mixed-citation>` are new here, and
                // the drop is deliberate. The old branch asked the ambient
                // `inRef`, so it caught these too — and got them wrong: in a
                // grouped citation each child carries its own `(a)`, `(b)`, `(c)`
                // sub-marker, and last-sibling-wins wrote `(g)` into the field
                // that holds the reference *number*. Across 150 surveyed
                // articles, 631 such labels in 158 refs were every one a
                // parenthesised letter — `(a)`, `(b)`, or the digit-suffixed
                // `(b1)` that subdivides one — and not one was a reference
                // number; no enclosing `<ref>` carried a direct `<label>` that a
                // first-wins rule could have preferred. A blank label the
                // renderer can see beats a confidently wrong number.
                //
                // Grouped citations are an RSC chemistry convention, and they
                // occur in `review-article` and `brief-report` rather than
                // research articles — which is why a generic sample finds none
                // and says so. Re-derive with
                // `scripts/jats_survey.py --measure grouped-citations`; the
                // survey names what would falsify this, and every observation so
                // far is RSC-family, so publisher spread is the open weakness.
                //
                // Neither behaviour captures the marker, and the members after
                // the first are lost either way: one `JATSReference` per
                // `<element-citation>` is #177.
                BioMedLitLib.logger?.debug(
                    "Dropped <label> from unmodelled host "
                        + "<\(enclosingElement ?? "none")>: \(text)",
                    category: .parsing
                )
            }
        case "caption":
            _ = popTrackingUnderflow(&captionStack)
        case "table-wrap-foot":
            decrementDepth(&exhibitFootnoteDepth)
        case "fn":
            // The element stack, not the ambient flags. When `inTableWrap` was a
            // stored flag, a `<table-wrap>` opening and closing *inside* this
            // footnote cleared it while the outer table was still open: the
            // decrement was skipped, the counter stayed above zero for the rest of
            // the document, and every later `<p>` drained into the footnote branch
            // and was discarded — the whole body after a nested table, silently.
            // The flag is derived from `tableCollector` now (#173), so it no longer
            // lies; the element-stack test still earns its place, because a counter
            // whose two ends test a different predicate from the routing between
            // them is a defect waiting for a shape that separates them.
            if innermostExhibit != nil {
                // A marker whose <fn> deposited no prose has nothing left to
                // disambiguate; clearing it here stops it prefixing the *next*
                // footnote instead.
                setPendingFootnoteLabel("")
                decrementDepth(&exhibitFootnoteDepth)
            }

        // Tables
        case "thead":
            if inTableWrap {
                withCurrentTable { $0.endHeader() }
            }
        case "tbody":
            if inTableWrap {
                withCurrentTable { $0.endBody() }
            }
        case "tr":
            if inTableWrap {
                withCurrentTable { $0.endRow() }
            }
        case "th", "td":
            if inTableWrap {
                withCurrentTable { $0.endCell() }
            }
        case "list":
            if inTableWrap {
                withCurrentTable { $0.endList() }
            }
        case "list-item":
            if inTableWrap {
                withCurrentTable { $0.endListItem() }
            }
        case "table-wrap":
            if !tableCollector.end() {
                // Counted, not only logged — see the `</fig>` twin above.
                depthUnderflows += 1
                BioMedLitLib.logger?.error(
                    "JATS </table-wrap> with no open <table-wrap> for \(articleIdentifier) — "
                        + "the table and its content were discarded",
                    category: .parsing
                )
            }

        // References
        case "ref-list":
            inRefList = false
        case "ref":
            // Finish any pending author
            currentReference?.finishCurrentAuthor()
            if let reference = currentReference?.build() {
                references.append(reference)
            }
            inRef = false
            inRefCitation = false
            inRefPersonGroup = false
            currentReference = nil
        case "mixed-citation", "element-citation":
            if inRef {
                currentReference?.citation = normalizedText
                inRefCitation = false
            }
        case "person-group":
            if inRefCitation {
                // Finish any pending author when exiting person-group
                currentReference?.finishCurrentAuthor()
                inRefPersonGroup = false
            }
        case "surname":
            if inRefPersonGroup {
                currentReference?.currentAuthorSurname = text
            } else if inContrib {
                currentAuthor?.surname = text
            }
        case "given-names":
            if inRefPersonGroup {
                currentReference?.currentAuthorGivenNames = text
            } else if inContrib {
                currentAuthor?.givenNames = text
            }
        case "name":
            // Complete one author when closing <name> element
            if inRefPersonGroup {
                currentReference?.finishCurrentAuthor()
            }
        case "collab":
            // Collaborative author (organization name)
            if inRefCitation && !text.isEmpty {
                currentReference?.authors.append(text)
            }
        case "article-title":
            if inRefCitation {
                currentReference?.articleTitle = normalizedText
            } else if inFront && inArticleMeta {
                title = normalizedText
            }
        case "source":
            if inRefCitation {
                currentReference?.source = text
            }
        case "year":
            if inRefCitation {
                currentReference?.year = text
            } else if inFront && inArticleMeta && year.isEmpty {
                year = text
            }
        case "volume":
            if inRefCitation {
                currentReference?.volume = text
            } else if inFront && inArticleMeta {
                volume = text
            }
        case "issue":
            if inRefCitation {
                currentReference?.issue = text
            } else if inFront && inArticleMeta {
                issue = text
            }
        case "fpage":
            if inRefCitation {
                currentReference?.firstPage = text
            } else if inFront && inArticleMeta && pages.isEmpty {
                pages = text
            }
        case "lpage":
            if inRefCitation {
                currentReference?.lastPage = text
            } else if inFront && inArticleMeta && !pages.isEmpty && !text.isEmpty {
                pages += "-\(text)"
            }
        case "pub-id":
            if inRefCitation {
                // Determine type from content pattern since we don't have attribute access here
                if text.hasPrefix("10.") {
                    currentReference?.doi = text
                } else if text.allSatisfy({ $0.isNumber }) && text.count >= 7 {
                    currentReference?.pmid = text
                }
            }

        // Inline formatting - these merge with parent, nothing else to do
        case "bold", "b":
            _ = inlineFormattingStack.popLast()
        case "italic", "i":
            _ = inlineFormattingStack.popLast()
        case "sub":
            _ = inlineFormattingStack.popLast()
        case "sup":
            _ = inlineFormattingStack.popLast()
        case "monospace", "code":
            _ = inlineFormattingStack.popLast()

        // Cross-references - convert figure/table refs to anchor links
        case "xref":
            if let refType = currentXrefType, let rid = currentXrefRid {
                // Convert to markdown anchor link for figures and tables
                switch refType {
                case "fig", "figure":
                    // Format: [Figure 1](#fig-id)
                    let linkText = text.isEmpty ? "Figure" : text
                    let anchorLink = "[\(linkText)](#\(rid))"
                    appendText(anchorLink)
                case "table", "table-wrap":
                    // Format: [Table 1](#table-id)
                    let linkText = text.isEmpty ? "Table" : text
                    let anchorLink = "[\(linkText)](#\(rid))"
                    appendText(anchorLink)
                default:
                    // Other ref types (bibr, aff, etc.) - just use the text
                    break
                }
            }
            currentXrefType = nil
            currentXrefRid = nil

        // ext-link and other inline elements - already merged with parent
        case "ext-link", "uri", "email", "named-content":
            break

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
        BioMedLitLib.logger?.error("JATS XML parse error: \(parseError.localizedDescription)", category: .parsing)
    }

    // MARK: - Helper Methods

    /// Check if an element is an inline text element that should merge with parent.
    ///
    /// - Parameter elementName: The element name to check.
    /// - Returns: True if the element's text should be merged with its parent.
    private func isInlineTextElement(_ elementName: String) -> Bool {
        switch elementName {
        case "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
             "xref", "ext-link", "uri", "email", "named-content",
             "inline-formula":
            return true
        default:
            return false
        }
    }

    /// Normalize whitespace in text (collapse multiple spaces/newlines).
    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Classify an article ID by its content pattern when type attribute is unavailable.
    private func classifyArticleIdByPattern(_ text: String) {
        if text.hasPrefix("10.") {
            // A DOI is a `10.NNNN` prefix *and* a slash. Without the shape check
            // any id starting "10." is taken as one — which is how SAGE's
            // `publisher-id`, the DOI with the slash replaced by an underscore,
            // became the stored DOI for every article it publishes.
            guard !doiIsAuthoritative, text.contains("/") else { return }
            doi = text
        } else if text.hasPrefix("PMC") {
            guard !pmcIdIsAuthoritative else { return }
            pmcId = text
        } else if text.allSatisfy({ $0.isNumber }) && text.count >= BioMedLitConstants.minPMIDLength {
            // Pure numeric ID - could be PMID or PMC ID
            // Store in both if empty (PMC ID detection takes priority for figures)
            if pmid.isEmpty {
                pmid = text
            }
        }
    }
}
