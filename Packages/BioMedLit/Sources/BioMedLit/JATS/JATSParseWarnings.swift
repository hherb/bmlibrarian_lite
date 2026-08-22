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

import Foundation

/// What a JATS parse lost, in a form a caller can act on.
///
/// Produced by the end-of-parse unwind audit and carried out through
/// ``FullTextResult`` so the UI can tell the reader that what they are looking
/// at is not the whole article (#181). Without it the app renders a gutted
/// article exactly as it renders a complete one, and a reader who cannot find
/// the table they came for cannot tell whether the publisher never deposited it
/// or this parser discarded it.
///
/// ## Facts, not copy
///
/// The losses are values, not sentences. The payload used to be `[String]` of
/// rendered English written for a log, which was shown to the reader, persisted
/// verbatim and compared by `Equatable` — so the UI could not be localised, the
/// banner could not count or filter, a rewording invalidated every stored
/// record, and tests could only substring-match (#184).
///
/// ``diagnostics`` renders the same English for the log, as a derived property.
/// The clinician-facing sentence is composed in the app, where it can be
/// localised with the rest of the interface.
///
/// ## Narrower than the log
///
/// Deliberately not everything `reportParseCompletion` emits: only losses a
/// reader can act on. A zero-author parse is a metadata gap, not a truncation —
/// editorials and corrections legitimately carry none — and a banner that fires
/// on those is worth nothing on the article where content really was discarded.
/// That warning stays in the log.
public struct JATSParseWarnings: Sendable, Equatable, Codable {

    /// One thing a parse lost.
    ///
    /// The seven counted cases mirror the fields of the end-of-parse audit
    /// state one for one; ``noContent`` and ``unspecified`` are the two that do
    /// not come from a counter.
    public enum Loss: Sendable, Equatable, Hashable {
        /// Unclosed `<sub-article>`/`<response>` nesting at the end of the parse.
        case subArticleDepth(Int)

        /// `<fig>` elements that opened and never closed.
        case openFigures(Int)

        /// `<table-wrap>` elements that opened and never closed.
        case openTables(Int)

        /// Unclosed `<table-wrap-foot>`/`<fn>` nesting inside an exhibit.
        case exhibitFootnoteDepth(Int)

        /// `<caption>` elements that opened and never closed.
        case openCaptions(Int)

        /// `<sec>` elements that opened and never closed.
        case openSections(Int)

        /// End tags that arrived with nothing to close.
        ///
        /// An event tally rather than a live depth, and the one imbalance the
        /// audit could not see before #180: every counter erased its own
        /// over-pop, either by clamping at zero or by popping an empty stack.
        case depthUnderflows(Int)

        /// The parse produced no title, no abstract and no body.
        ///
        /// Not an unwind imbalance — the audit reports it in the same breath
        /// because it is the same question asked of the output rather than of
        /// the element stack. A rendering carrying only the article's own
        /// identifiers is the most complete loss there is, and it is the one the
        /// UI should say the most about.
        case noContent

        /// Something was lost and this record can no longer say what.
        ///
        /// The answer a caller gives for a stored warnings payload it cannot
        /// decode. The field is only ever written when a parse lost something,
        /// so "we cannot read it" and "nothing was lost" are opposite answers,
        /// and collapsing them presents a truncated article as complete — the
        /// one failure this whole channel exists to prevent.
        ///
        /// It lives here rather than in the app because ``losses`` is `[Loss]`,
        /// so no caller can add a case of its own.
        case unspecified

        /// The developer-log rendering of this loss.
        ///
        /// The wording every line carried before the losses were typed,
        /// reproduced to the byte: it is what `BioMedLitLib.logger` receives,
        /// and the real-corpus suite reads that log's text. Keeping it identical
        /// meant the log, the corpus digests and that test all stayed still, so
        /// a later rewording is a visible change rather than a side effect.
        public var logLine: String {
            switch self {
            case .subArticleDepth(let depth):
                return "JATS sub-article depth ended at \(depth), not 0 — "
                    + "content after the imbalance was discarded"
            case .openFigures(let count):
                return "JATS parse ended with \(count) open <fig> — "
                    + "those figures and their content were discarded"
            case .openTables(let count):
                return "JATS parse ended with \(count) open <table-wrap> — "
                    + "those tables and their content were discarded"
            case .exhibitFootnoteDepth(let depth):
                return "JATS exhibit footnote depth ended at \(depth), not 0 — "
                    + "prose after the imbalance was routed into a footnote and discarded"
            case .openCaptions(let count):
                return "JATS parse ended with \(count) open <caption> — "
                    + "prose after the imbalance was read as caption text"
            case .openSections(let count):
                return "JATS parse ended with \(count) open <sec> — "
                    + "those sections and their prose were never emitted"
            case .depthUnderflows(let count):
                return "JATS parse saw \(count) end tag(s) with nothing to close — "
                    + "a counter closed an element it never opened, so any other "
                    + "imbalance reported here understates what was misrouted"
            case .noContent:
                return "JATS parse extracted no title, abstract or body — "
                    + "any rendered full text carries only its identifiers"
            case .unspecified:
                return "This article's parse diagnostics could not be read back — "
                    + "some content may be missing"
            }
        }
    }

    /// The version of the persisted representation this build writes.
    ///
    /// Present so that a payload from a future build fails to decode and is
    /// reported as an unspecified loss, instead of being half-read. The corpus
    /// digest format shipped without one and #163 exists to add it after the
    /// fact; the same mistake costs one `enum CodingKeys` to avoid here.
    public static let schemaVersion = 1

    /// What the parse lost, in the order the audit found it.
    public let losses: [Loss]

    /// Whether the parse lost nothing a reader would want to know about.
    public var isClean: Bool { losses.isEmpty }

    /// The developer-log rendering, one line per loss.
    ///
    /// A derived property rather than the stored payload, which is what let the
    /// banner, the log loop and the persistence path carry on unchanged when the
    /// losses were typed.
    public var diagnostics: [String] { losses.map(\.logLine) }

    /// Create a set of warnings for a completed parse.
    ///
    /// - Parameter losses: What the parse lost. Empty — the default — is a parse
    ///   that lost nothing.
    public init(losses: [Loss] = []) {
        self.losses = losses
    }

    // MARK: - Persisted form

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case losses
    }

    /// Write the versioned, explicitly named form.
    ///
    /// - Parameter encoder: The encoder to write into.
    /// - Throws: Whatever the encoder throws.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(losses, forKey: .losses)
    }

    /// Read a stored payload, refusing anything this build cannot read exactly.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` for a payload written by a newer
    ///   build, and whatever the decoder throws for a malformed one. Failing is
    ///   the point: the caller turns a failure into ``Loss/unspecified``, and a
    ///   payload read approximately would be reported as fact.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription:
                    "parse warnings schema \(version) is newer than \(Self.schemaVersion)"
            )
        }
        self.losses = try container.decode([Loss].self, forKey: .losses)
    }
}

// MARK: - Loss persistence

extension JATSParseWarnings.Loss: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case count
    }

    /// The stored spelling of each case.
    ///
    /// Named rather than synthesised: Swift's synthesis for an enum with
    /// associated values emits `{"openFigures":{"_0":2}}`, and `_0` is an
    /// implementation detail of the synthesis — not something to write into a
    /// user's database and then be obliged to keep reading.
    private enum Kind: String, Codable {
        case subArticleDepth, openFigures, openTables, exhibitFootnoteDepth
        case openCaptions, openSections, depthUnderflows, noContent, unspecified
    }

    /// This loss's stored kind, and its count where it has one.
    private var stored: (kind: Kind, count: Int?) {
        switch self {
        case .subArticleDepth(let n): return (.subArticleDepth, n)
        case .openFigures(let n): return (.openFigures, n)
        case .openTables(let n): return (.openTables, n)
        case .exhibitFootnoteDepth(let n): return (.exhibitFootnoteDepth, n)
        case .openCaptions(let n): return (.openCaptions, n)
        case .openSections(let n): return (.openSections, n)
        case .depthUnderflows(let n): return (.depthUnderflows, n)
        case .noContent: return (.noContent, nil)
        case .unspecified: return (.unspecified, nil)
        }
    }

    /// Write this loss as its kind plus, where it has one, its count.
    ///
    /// - Parameter encoder: The encoder to write into.
    /// - Throws: Whatever the encoder throws.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let (kind, count) = stored
        try container.encode(kind, forKey: .kind)
        // Absent rather than zero for the count-free cases: a stored `0` invites
        // a reader to treat "no figures were lost" as a thing this type says.
        try container.encodeIfPresent(count, forKey: .count)
    }

    /// Read a stored loss.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError` for an unknown kind, and for a counted kind
    ///   stored without its count — a loss of unknown size read as zero would be
    ///   reported to the reader as no loss at all.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        /// The count this kind requires, or a decoding failure naming what is missing.
        func count() throws -> Int {
            try container.decode(Int.self, forKey: .count)
        }

        switch kind {
        case .subArticleDepth: self = .subArticleDepth(try count())
        case .openFigures: self = .openFigures(try count())
        case .openTables: self = .openTables(try count())
        case .exhibitFootnoteDepth: self = .exhibitFootnoteDepth(try count())
        case .openCaptions: self = .openCaptions(try count())
        case .openSections: self = .openSections(try count())
        case .depthUnderflows: self = .depthUnderflows(try count())
        case .noContent: self = .noContent
        case .unspecified: self = .unspecified
        }
    }
}
