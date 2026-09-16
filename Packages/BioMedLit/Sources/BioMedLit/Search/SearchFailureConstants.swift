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

/// The wording a search failure reaches the user in, fixed by the contract.
///
/// Every sentence, phrase and number format **the contract fixes** is here
/// rather than at the site that prints it, because all three platforms must
/// read alike: the contract
/// (`doc/cross_platform/search_failure_reporting.md`) fixes these strings, and
/// Python's `search_failures.py` and Android's `SearchFailureReporting` hold
/// the same ones.
enum SearchFailureConstants {
    // MARK: - The notice

    /// Opens the notice that precedes whatever an incomplete search produced.
    static let noticeOpening = "> **Incomplete search:** "

    /// The notice's opening as plain text, its block-quote and bold markup left out.
    static let plainNoticeOpening = "Incomplete search: "

    /// Closes the notice, after the clauses.
    static let noticeClosing = " Everything below rests only on the records that were retrieved."

    /// Separates the notice from the text it precedes.
    static let noticeSeparator = "\n\n"

    /// Separates the clauses of several shortfalls.
    static let clauseSeparator = "; "

    /// Heads the section that records the gap where the report has no Methodology of its own.
    static let methodologyHeading = "## Methodology"

    /// Names the gap inside that section.
    static let searchCompletenessLabel = "- **Search Completeness:** Incomplete: "

    /// Opens the message shown when failures left a search with nothing.
    static let searchFailedOpening = "The search could not be completed: "

    // MARK: - What to do next

    /// What to do about a source that is limiting how often it can be searched.
    static let rateLimitAdvice =
        "The service is limiting how often it can be searched: wait a minute and try again."

    /// What raises PubMed's own limit.
    static let pubMedKeyAdvice = "An NCBI API key, set in Settings, raises PubMed's limit."

    /// What to check when PubMed refused the request outright.
    static let pubMedRefusedKeyAdvice =
        "If an NCBI API key is set in Settings, check that it is correct: "
        + "PubMed refuses a request whose key it does not accept."

    /// What to do about a source that could not process the query.
    static let serviceErrorAdvice =
        "If it happens again, rephrase the question: the service may be unable to process the query."

    /// What to do about a request that never reached the source.
    static let connectivityAdvice = "Check the internet connection and try again."

    /// What to do when nothing more specific applies.
    static let fallbackAdvice = "Try again later."

    /// Separates the advice's sentences.
    static let adviceSeparator = " "

    // MARK: - HTTP statuses

    /// What NCBI answers a request whose API key it does not accept (400, checked
    /// live for #243); 401 and 403 are refusals of the same kind.
    static let refusedKeyStatuses: Set<Int> = [400, 401, 403]

    /// The reason phrases a clause names, in RFC 9110 wording.
    ///
    /// Fixed here rather than taken from a platform library, whose phrases
    /// differ: Foundation's are lowercase and localised, and Python renamed
    /// three of them in 3.13. Any other status reads as its number alone.
    static let httpReasonPhrases: [Int: String] = [
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        408: "Request Timeout",
        413: "Content Too Large",
        414: "URI Too Long",
        429: "Too Many Requests",
        500: "Internal Server Error",
        502: "Bad Gateway",
        503: "Service Unavailable",
        504: "Gateway Timeout",
    ]

    // MARK: - Numbers

    /// The locale whose grouping the contract's counts are written in.
    ///
    /// Fixed, not the reader's: the clause is one sentence shared with Python
    /// and Android, both of which group in this style, and a count that groups
    /// differently on each device is a parity difference no test would see.
    private static let countLocale = Locale(identifier: "en_US_POSIX")

    /// Formats a count with thousands separators.
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = countLocale
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter
    }()

    /// Write a count the way every clause writes one.
    ///
    /// - Parameter count: How many records.
    /// - Returns: The count with thousands separators, such as `"1,200"`.
    static func groupedNumber(_ count: Int) -> String {
        countFormatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}
