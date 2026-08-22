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

/// A parse-time accumulator that turns into the value the article carries.
///
/// The two JATS exhibits — `<fig>` and `<table-wrap>` — are both collected this
/// way, which is what lets ``ExhibitCollector`` hold the ordering rule once
/// instead of once per exhibit.
protocol ExhibitBuilder {
    /// What this builder produces at its element's end tag.
    associatedtype Built

    /// Freeze the accumulated state into the finished value.
    func build() -> Built
}

// `Built` is pinned rather than inferred. Left to inference, changing
// `build()` to return an optional silently re-infers `Built` as that optional
// and `completed` becomes `[JATSFigureInfo?]` — the parallel-array shape #170
// exists to delete, reintroduced without a word at the conformance. Named, the
// same edit fails here instead.
extension FigureBuilder: ExhibitBuilder {
    typealias Built = JATSFigureInfo
}

extension TableBuilder: ExhibitBuilder {
    typealias Built = JATSTableInfo
}

/// The open and finished exhibits of one kind, in document order.
///
/// JATS exhibits nest, in both directions: eLife wraps every figure supplement
/// in the figure it belongs to — 44 of 225 articles (19.6%) in the 2026-08
/// eLife-heavy draw, though a differently-mixed draw measured 0.3%, so
/// re-derive with `scripts/jats_survey.py` before quoting it — and
/// `%fn-model` admits a `<table-wrap>` inside another table's
/// `<table-wrap-foot>`. Held as a single builder slot, the inner open overwrote
/// the parent, the inner close cleared the slot while the parent was still
/// open, and the parent's own end tag found nothing to build: the parent was
/// lost outright and the content that followed it inside the parent was routed
/// as though no exhibit were open at all (#156 for figures, #173 for tables).
///
/// ## Why a type rather than two arrays
///
/// The fix for #156 kept a `[JATSFigureInfo?]` of reserved slots beside a
/// stack of `(slot:, builder:)` frames. That is correct, but five invariants
/// rode on the pair with nothing checking them — every frame's index is in
/// range, the slot it names is still empty, slots increase up the stack, each is
/// filled exactly once, the arrays grow in lockstep — maintained by two adjacent
/// lines in `didStartElement` and one about 375 lines away in `didEndElement`,
/// with nothing in between naming the contract they keep. `nil` also
/// meant two different things: "reserved, still open" during the parse and
/// "opened and never closed" after it, with `compactMap` — the canonical silent
/// drop — between them and the result (#170).
///
/// Here the stack *is* the tree. A closing exhibit hands itself and everything
/// that closed inside it up as one run, so document order falls out of the
/// nesting rather than out of an index, and an exhibit that never closed simply
/// stays on the stack, where ``openCount`` shows it to the end-of-parse audit
/// (#175) instead of a `compactMap` dropping it on the way out.
struct ExhibitCollector<Builder: ExhibitBuilder> {

    /// One open exhibit, with whatever has already closed inside it.
    private struct Frame {
        var builder: Builder

        /// Exhibits that opened *and closed* inside this one, in document order.
        ///
        /// Held here rather than emitted straight away because this exhibit is
        /// built at its own end tag, which arrives last: appending each child as
        /// it closes lists every eLife supplement ahead of the figure it belongs
        /// to.
        var nested: [Builder.Built] = []
    }

    /// Open exhibits, innermost last.
    private var stack: [Frame] = []

    /// Exhibits whose end tag has arrived, in the order their start tags did.
    private(set) var completed: [Builder.Built] = []

    /// Whether any exhibit of this kind is open, at any depth.
    ///
    /// The parser's `inFigure`/`inTableWrap` are this, derived rather than
    /// stored: a stored flag is what the inner close cleared while the parent
    /// was still open.
    var isOpen: Bool { !stack.isEmpty }

    /// How many exhibits are open. Zero at the end of a balanced parse.
    var openCount: Int { stack.count }

    /// Start collecting an exhibit whose start tag has just arrived.
    ///
    /// - Parameter builder: The accumulator for the new exhibit.
    mutating func begin(_ builder: Builder) {
        stack.append(Frame(builder: builder))
    }

    /// Mutate the innermost open exhibit.
    ///
    /// Innermost, not most recently opened: a `<label>`, `<caption>` or
    /// `<graphic>` belongs to the exhibit that encloses it, and the parent
    /// becomes current again the moment its child closes.
    ///
    /// - Parameter mutate: Applied to the innermost open builder.
    /// - Returns: `false` if nothing was open, so the caller can report it.
    ///   Callers route on the element stack and write here, so a disagreement
    ///   between the two means content is going missing.
    mutating func withCurrent(_ mutate: (inout Builder) -> Void) -> Bool {
        guard !stack.isEmpty else { return false }
        mutate(&stack[stack.count - 1].builder)
        return true
    }

    /// Finish the innermost open exhibit, listing it ahead of its children.
    ///
    /// - Returns: `false` if nothing was open, so the caller can report it.
    ///   `XMLParser` cannot deliver that for a well-formed document — but it
    ///   cannot deliver ``withCurrent(_:)``'s empty case either, and that one
    ///   says so out loud. Answering one impossible condition with a diagnostic
    ///   and its twin with silence is how the louder of the two ends up being
    ///   the one that loses less: this end drops a whole exhibit.
    @discardableResult
    mutating func end() -> Bool {
        guard let frame = stack.popLast() else { return false }
        let run = [frame.builder.build()] + frame.nested
        if stack.isEmpty {
            completed.append(contentsOf: run)
        } else {
            stack[stack.count - 1].nested.append(contentsOf: run)
        }
        return true
    }
}
