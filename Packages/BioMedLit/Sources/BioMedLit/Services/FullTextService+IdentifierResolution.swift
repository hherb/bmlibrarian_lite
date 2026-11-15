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

extension FullTextService {
    // MARK: - Identifier Resolution

    /// What an identifier resolution learned, including what it could not learn.
    ///
    /// A bare `(pmcId:pdfRenderURL:)` tuple could not tell "Europe PMC has no
    /// record for this article" from "we could not ask Europe PMC" — opposite
    /// answers, the second of which skips the machine-readable source entirely
    /// (#186). It is the same collapse #183 corrected one layer up.
    ///
    /// Two facts are accumulated across the attempts rather than one, because
    /// "no attempt answered" and "an attempt answered about this article" are
    /// themselves opposite answers. A query that matched a record settles the
    /// question however the other queries went; a query that matched *nothing*
    /// only says that query did not match.
    struct PMCResolution {
        /// The PMC ID, when one was found.
        let pmcId: String?

        /// The preprint's `PPR` record ID, when a matched record was a preprint.
        ///
        /// A preprint has no PMC ID, so without this the XML tier had nothing
        /// to ask by, and a preprint Europe PMC serves in full reached only its
        /// PDF, or nothing (#434).
        let preprintAccession: String?

        /// The free PDF render URL from the search result, when one was offered.
        let pdfRenderURL: String?

        /// Why the first failed search failed, or `nil` when every attempted
        /// search answered.
        ///
        /// Kept across every attempt: one failing leaves us unable to say, on
        /// that attempt's evidence, that the article has no PMC record. Carried
        /// so a chain that ends without full text can say why Europe PMC did
        /// not settle it, rather than only that it did not. The only record of
        /// a failed search, so "a search failed" and "why" cannot disagree.
        let failure: RequestFailure?

        /// Whether any attempted search matched a record for this article.
        ///
        /// Europe PMC answering with a record that names no PMC ID *is* the
        /// absent-source answer: the article is indexed and has no PMC deposit,
        /// so there was never a machine-readable copy to lose. Without this bit
        /// that answer is indistinguishable from having asked nobody, and a
        /// transient failure on an earlier query would report an article that
        /// simply is not in PMC as one we could not reach — the misattribution
        /// this whole channel exists to prevent, inverted (#186).
        let matchedARecord: Bool

        /// Why the machine-readable source was lost because we could not ask,
        /// or `nil` when it was not.
        ///
        /// The rule the degradation is raised on, kept here rather than at the
        /// call site so the facts that decide it cannot be recombined
        /// differently by a second consumer.
        ///
        /// Both conditions are load-bearing: a search that never failed has
        /// nothing to report, and a record that was matched answers the question
        /// outright. `pmcId == nil` is deliberately *not* a third condition —
        /// only a matched record can carry an ID, so a non-nil `pmcId` already
        /// implies `matchedARecord`. Spelling it out anyway would add a check no
        /// test could ever fail, which is how a predicate starts to look
        /// defensive and stops being read.
        var sourceLostTo: RequestFailure? {
            matchedARecord ? nil : failure
        }

        /// The starting value of a resolution: nothing attempted, nothing learned.
        static let nothingAttempted = PMCResolution(
            pmcId: nil, preprintAccession: nil, pdfRenderURL: nil,
            failure: nil, matchedARecord: false
        )

        /// The answer when a search completed and matched nothing.
        ///
        /// Deliberately the same value as ``nothingAttempted``, not a coincidence
        /// to be tidied away: a query that matched nothing taught us nothing, so
        /// it must contribute nothing to the fold. It is named separately because
        /// the two say different things at the call site.
        static let noMatch = nothingAttempted

        /// The answer when a search threw.
        ///
        /// - Parameter failure: Why it threw, by kind.
        /// - Returns: A resolution that learned nothing but the failure.
        static func failed(_ failure: RequestFailure) -> PMCResolution {
            PMCResolution(
                pmcId: nil, preprintAccession: nil, pdfRenderURL: nil,
                failure: failure, matchedARecord: false
            )
        }

        /// This resolution combined with a later attempt's.
        ///
        /// Every field accumulates, which is the whole point: returning the
        /// attempt that happened to succeed would drop what the earlier ones
        /// learned, and then `failure` would silently mean "the last search
        /// failed" rather than "a search failed". The two differ exactly when one
        /// query fails and a later one recovers — and a free PDF URL offered by a
        /// query that found no PMC ID is worth just as much as one offered by the
        /// query that did.
        ///
        /// - Parameter next: What a later attempt learned.
        /// - Returns: The two resolutions merged, preferring the earlier answer
        ///   for the values that can only be answered once.
        func merging(_ next: PMCResolution) -> PMCResolution {
            PMCResolution(
                pmcId: pmcId ?? next.pmcId,
                preprintAccession: preprintAccession ?? next.preprintAccession,
                pdfRenderURL: pdfRenderURL ?? next.pdfRenderURL,
                failure: failure ?? next.failure,
                matchedARecord: matchedARecord || next.matchedARecord
            )
        }
    }

    /// One identifier query, and the identifier it was built from.
    ///
    /// Paired so the log line can name what resolved the article without the
    /// loop having to know which identifier it is on.
    /// Internal rather than private so ``identifierQueries(pmid:pmcId:doi:primaryKind:)`` can be
    /// tested on the query it builds, which is the whole of its behaviour.
    struct PMCQuery {
        /// How to describe the identifier in a log line.
        let describedAs: String

        /// The Europe PMC query to run.
        let query: String
    }

    /// Resolve a PMC ID and PDF render URL from the identifiers a document
    /// carries, via Europe PMC search.
    ///
    /// Tries the primary slot, then the PMC ID, then the DOI — see
    /// ``identifierQueries(pmid:pmcId:doi:primaryKind:)`` — stopping at the first PMC ID.
    /// Also extracts the free PDF render URL from the `fullTextUrlList` in the
    /// search response.
    ///
    /// Written as a fold rather than as two blocks that each accumulate by hand.
    /// The hand-written version had the first attempt assign where the second
    /// OR-ed, which was correct only because the first ran first: a third query
    /// added above it would have silently discarded its failure — the very defect
    /// this accumulation exists to prevent (#186).
    ///
    /// - Parameters:
    ///   - pmid: The document's primary identifier slot.
    ///   - pmcId: PubMed Central ID, when the document already carries one.
    ///     Still worth querying: the record it names carries the free PDF
    ///     render URL this method also collects.
    ///   - doi: DOI to resolve.
    /// - Returns: What every attempted query learned, merged. A resolution that
    ///   merely matched nothing reports no `failure`.
    /// - Throws: `CancellationError` if the caller cancelled. Only cancellation
    ///   propagates, so the chain never reads "the caller stopped us" as "this
    ///   article has no PMC record".
    func resolvePMCIdAndPDFUrl(
        pmid: String?,
        pmcId: String?,
        doi: String?,
        primaryKind: ArticleIdentifierKind?
    ) async throws -> PMCResolution {
        var accumulated = PMCResolution.nothingAttempted

        for candidate in Self.identifierQueries(
            pmid: pmid, pmcId: pmcId, doi: doi, primaryKind: primaryKind
        ) {
            accumulated = accumulated.merging(
                try await searchForPMCIdAndPDFUrl(query: candidate.query)
            )
            if let pmcId = accumulated.pmcId {
                BioMedLitLib.logger?.info(
                    "Resolved \(candidate.describedAs) to \(pmcId)",
                    category: .fullText
                )
                return accumulated
            }
        }

        return accumulated
    }

    /// The identifier queries worth running, most specific first.
    ///
    /// Internal rather than private so the queries can be tested directly: the
    /// query string *is* this method's behaviour, and asking Europe PMC for an
    /// identifier under a source that cannot hold it fails by matching nothing,
    /// which is indistinguishable from the article not existing.
    ///
    /// Rungs are climbed in the same order ``ArticleCacheKey`` climbs them, so
    /// the most specific identifier is asked for first. The PMC rung matters on
    /// its own: an article can carry a PMC ID and nothing else, and until that
    /// was asked for it resolved no render URL, so such an article reached no
    /// PDF tier at all however the cache was keyed (#202).
    ///
    /// - Parameters:
    ///   - pmid: The document's primary identifier slot, if any. Not only ever
    ///     a PubMed ID — see ``primaryIdentifierQuery(for:kind:)``.
    ///   - pmcId: PubMed Central ID to resolve, if any.
    ///   - doi: DOI to resolve, if any.
    /// - Returns: A query per identifier that is present and not blank, with
    ///   duplicates removed. A PMC-only Europe PMC record arrives with the same
    ///   accession in both the primary slot and `pmcId` — `result.pmid ?? result.id`
    ///   yields the PMC ID when there is no PMID — and both rungs then build the
    ///   byte-identical `PMCID:` query. Left in, that asks Europe PMC the same
    ///   question twice, and on the failure path pays the retry backoff twice,
    ///   for exactly the record class this ladder was added to serve.
    static func identifierQueries(
        pmid: String?,
        pmcId: String?,
        doi: String?,
        primaryKind: ArticleIdentifierKind? = nil
    ) -> [PMCQuery] {
        var queries: [PMCQuery] = []
        // Stripped as the PMID contract strips: a trailing U+200B is kept, and refused
        if let identifier = pmid.map(PMID.stripped), !identifier.isEmpty,
           let query = primaryIdentifierQuery(for: identifier, kind: primaryKind) {
            queries.append(query)
        }
        if let pmcId = trimmed(pmcId) {
            queries.append(
                PMCQuery(
                    describedAs: "PMC ID \(pmcId)",
                    query: "\(BioMedLitConstants.europePMCPMCIDField):\(pmcId)"
                )
            )
        }
        if let doi = trimmed(doi) {
            queries.append(PMCQuery(describedAs: "DOI \(doi)", query: "DOI:\"\(doi)\""))
        }

        // Keeps the first of each query string, so the surviving rung is the
        // more specific one and its `describedAs` is the one that names the
        // article in the log.
        var seen: Set<String> = []
        return queries.filter { seen.insert($0.query).inserted }
    }

    /// An identifier with surrounding whitespace removed, or `nil` if nothing
    /// is left. A slot holding only spaces must contribute no query rather than
    /// one asking Europe PMC for the empty string.
    ///
    /// - Parameter identifier: The raw slot value.
    /// - Returns: The trimmed identifier, or `nil` when it holds nothing.
    static func trimmed(_ identifier: String?) -> String? {
        guard let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// The Europe PMC query that can match the document's primary identifier.
    ///
    /// The slot does not hold one kind of thing. `EuropePMCService` fills it as
    /// `result.pmid ?? result.id ?? ""`, so it carries a PubMed ID for a MEDLINE
    /// record, a `PPR…` accession for a preprint, a PMC ID for a PMC-only
    /// record, and — through that `?? ""` — nothing at all for a record with
    /// neither. Europe PMC answers for each only when asked in its own terms.
    /// Every value was previously asked for as `ext_id:<id> src:med`, which only
    /// a PubMed ID can match.
    ///
    /// The cost fell on preprints. One reached its full text only if it also
    /// carried a DOI, through the rung below, and never by its own accession;
    /// one without a DOI was unreachable despite Europe PMC holding an
    /// open-access PDF for it.
    ///
    /// Routed on the kind the record stated, and only on the accession's shape
    /// where it stated none — see ``ArticleIdentifierKind``. Europe PMC sends
    /// each record's kind and we used to discard it, so every route here was
    /// once a guess from a string (#209). A guess cannot name the sources it
    /// does not know about, and each of those matches nothing when asked as
    /// `src:med`.
    ///
    /// - Parameters:
    ///   - identifier: The trimmed, non-empty primary identifier.
    ///   - kind: What the record said it is, when it said.
    /// - Returns: The query, paired with how to name the identifier in a log,
    ///   or `nil` when the identifier is a PMID that is not canonical digits
    ///   (bmlib#470, bmlib#472, bmlib#478): it is logged and not sent.
    private static func primaryIdentifierQuery(
        for identifier: String,
        kind: ArticleIdentifierKind?
    ) -> PMCQuery? {
        switch ArticleIdentifierKind.resolved(declared: kind, accession: identifier) {
        case .preprint:
            return PMCQuery(
                describedAs: "preprint \(identifier)",
                query: "ext_id:\(identifier) src:\(BioMedLitConstants.europePMCPreprintSource)"
            )

        case .pmc:
            return PMCQuery(
                describedAs: "PMC ID \(identifier)",
                query: "\(BioMedLitConstants.europePMCPMCIDField):\(identifier)"
            )

        case .europePMCSource(let source):
            return PMCQuery(
                describedAs: "\(source.uppercased()) record \(identifier)",
                query: "ext_id:\(identifier) src:\(source)"
            )

        case .pubmed:
            // A PMID is sent canonical or not at all (bmlib#470, bmlib#472, bmlib#478)
            return medlineQuery(for: identifier, describedAs: "PMID")

        // Nothing named this identifier's kind and its shape does not settle it.
        // Bare digits, which is how a PMID arrives from a record that stated
        // nothing, are asked of `src:med`, canonical. Anything else is not
        // sent: `src:med` holds only PubMed records, so a patent or AGRICOLA
        // accession (`CN101548780`) can match nothing there, and an unchecked
        // value can widen the query (`1 OR 2`; bmlib#470). It is logged rather
        // than asked, so the dead end is visible rather than silent (#202),
        // and named for what it is: an identifier of unstated kind, not a
        // malformed PMID.
        case .unknown:
            guard PMID.canonical(identifier).pmid != nil else {
                BioMedLitLib.logger?.info(
                    "An identifier of unstated kind is not a PubMed ID, so Europe PMC's "
                        + "PubMed source was not asked about it: \(PMID.logQuoted(identifier))",
                    category: .fullText
                )
                return nil
            }
            return medlineQuery(for: identifier, describedAs: "identifier")
        }
    }

    /// The `src:med` query for a slot that should hold a PMID, or `nil`.
    ///
    /// A PMID is sent canonical or not at all (bmlib#470, bmlib#472, bmlib#478). A PMC ID
    /// given where a PMID was expected is asked for as the PMC ID it is.
    private static func medlineQuery(for identifier: String, describedAs label: String) -> PMCQuery? {
        let reading = PMID.canonical(identifier)
        if let pmcId = reading.pmcId {
            // As Python's read_caller_ids and Kotlin log it
            BioMedLitLib.logger?.warning(
                "The PMID \(PMID.logQuoted(identifier)) is a PMC ID, so it is read as one",
                category: .fullText
            )
            return PMCQuery(
                describedAs: "PMC ID \(pmcId)",
                query: "\(BioMedLitConstants.europePMCPMCIDField):\(pmcId)"
            )
        }
        guard let pmid = canonicalPMIDOrLog(identifier) else { return nil }
        return PMCQuery(
            describedAs: "\(label) \(pmid)",
            query: "ext_id:\(pmid) src:\(BioMedLitConstants.europePMCMedlineSource)"
        )
    }

    /// The canonical PMID a `src:med` query may carry, or `nil` after logging.
    ///
    /// Padded digits come back without their zeros, which Europe PMC finds
    /// where it finds nothing for the padded form. Anything that is not ASCII
    /// digits is not sent: it would widen the query (`1 OR 2`) or name no
    /// record. The value is logged quoted and escaped (``PMID/logQuoted(_:)``),
    /// so a newline in it cannot start a log line of its own.
    private static func canonicalPMIDOrLog(_ identifier: String) -> String? {
        if let pmid = PMID.canonical(identifier).pmid { return pmid }
        BioMedLitLib.logger?.warning(
            "Not a usable PMID, so Europe PMC was not asked about it: \(PMID.logQuoted(identifier))",
            category: .fullText
        )
        return nil
    }

    /// The primary slot's value, when it really is a PubMed ID.
    ///
    /// Only a PubMed ID may be pasted after the PubMed base URL. The slot also
    /// holds `PPR…` and `PMC…` accessions and can hold nothing at all, and each
    /// of those builds a URL that names no article — see the final fallback in
    /// ``fetchFullText(pmcId:doi:pmid:primaryKind:title:)`` for what that cost the reader.
    ///
    /// Delegated rather than decided here. Every link and citation surface in
    /// the apps asks the same question, and a rule this consequential answered
    /// separately per surface is how #186 came to be fixed on one of four.
    ///
    /// - Parameters:
    ///   - identifier: The raw primary identifier slot.
    ///   - kind: What is known about the slot — stated by the record, or
    ///     resolved by the caller where a provider had to vouch for it.
    /// - Returns: The trimmed PubMed ID, or `nil` if the slot holds anything else.
    static func pubmedIdentifier(
        in identifier: String?,
        kind: ArticleIdentifierKind?
    ) -> String? {
        ArticleIdentifierKind.pubmedID(in: identifier, declared: kind)
    }

    /// Search Europe PMC and extract PMC ID and PDF render URL from the first result.
    ///
    /// - Parameter query: The Europe PMC query to run.
    /// - Returns: What the first result carried, `noMatch` when the search
    ///   matched nothing, and `failed` when it threw anything but cancellation.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func searchForPMCIdAndPDFUrl(query: String) async throws -> PMCResolution {
        do {
            // `lookup` sends the query as it is, which is required, not
            // cosmetic. `search` appends ` NOT SRC:PPR` to any query that does
            // not already contain that literal, so this ladder once asked
            // `DOI:"…" NOT SRC:PPR` — a filter that cannot match a preprint by
            // construction, which is the one record class the DOI rung is the
            // recovery path for. Verified against the live API: the DOI of a
            // `SRC:PPR` record returns one hit, and none once the exclusion is
            // appended. The accession rung only ever worked because `src:ppr`
            // happens to contain `SRC:PPR` as a substring.
            //
            // A preprint filter belongs to discovery, where the reader is asking
            // what the literature holds. This is a lookup of one known article
            // by its own identifier, and the answer is not ours to filter.
            //
            // Sending the query unchanged is also what lets the `noMatch` line
            // below name the string that was actually sent.
            let records = try await europePMCService.lookup(query: query, pageSize: 1)
            if let firstArticle = records.first {
                let pmcId = firstArticle.pmcId?.isEmpty == false ? firstArticle.pmcId : nil
                // The record's own ID, not the primary slot: a preprint that also
                // has a PubMed ID fills the slot with that. Taken only in its
                // prefixed form, so nothing else is asked for as a preprint.
                let preprintAccession = firstArticle.identifierKind == .preprint
                    ? firstArticle.europePMCRecordID.flatMap {
                        FullTextAccession.prefixed(
                            $0, as: BioMedLitConstants.europePMCPreprintAccessionPrefix
                        )
                    }
                    : nil
                // `matchedARecord` regardless of whether it named a PMC ID: the
                // record is Europe PMC's answer about this article either way.
                return PMCResolution(
                    pmcId: pmcId,
                    preprintAccession: preprintAccession,
                    pdfRenderURL: firstArticle.pdfRenderURL,
                    failure: nil,
                    matchedARecord: true
                )
            }
        } catch where error.isCancellation {
            // As above: cancelling the search must not be read as "this article
            // has no PMC record", which would skip the Europe PMC branch whole.
            throw CancellationError()
        } catch {
            // Warning rather than debug: "Europe PMC has nothing for this
            // article" and "we could not ask Europe PMC" are opposite answers,
            // and this one skips the machine-readable source entirely. The
            // returned flag is what carries that distinction to the reader; the
            // log line only ever carried it to us.
            BioMedLitLib.logger?.warning(
                "PMC ID resolution failed for query '\(query)': \(error.localizedDescription)",
                category: .fullText
            )
            return .failed(
                (error as? SourceRequestError)?.failure ?? SearchTransport.failure(for: error)
            )
        }

        // Names the query that matched nothing. A zero-hit search is the one
        // outcome that says nothing to the reader — `noMatch` merges as
        // `nothingAttempted`, no degradation is recorded, and both PDF tiers are
        // then skipped — so without this line, a query aimed at a source that
        // cannot answer it is indistinguishable from an article Europe PMC has
        // never heard of. That indistinguishability *is* #202, and the routing
        // above still falls through to `src:med` for any accession shape it does
        // not yet recognise.
        BioMedLitLib.logger?.info(
            "Europe PMC matched no record for query '\(query)'",
            category: .fullText
        )
        return .noMatch
    }
}
