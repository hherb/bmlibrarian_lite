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

/// What a transport error a search request raised is reduced to (#256).
///
/// The error itself is never kept: a `URLError` carries the failing URL in its
/// user info, and an E-utilities URL is one this app must not print (#196).
/// Only the kind survives, so a clause can say "the request timed out" without
/// naming what timed out.
enum SearchTransport {
    /// The `URLError` codes that mean the request never reached the source, or
    /// the connection to it broke.
    private static let connectionCodes: Set<URLError.Code> = [
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .secureConnectionFailed,
        .cannotLoadFromNetwork,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
    ]

    /// Classify an error a request raised, keeping nothing of the error itself.
    ///
    /// A cancelled request is not a failure and must be told apart by the
    /// caller first (`Error.isCancellation`). `URLError.cancelled` is not one of
    /// the codes below, so classified here it would read as a failed request and
    /// be recorded as a shortfall the user never caused.
    ///
    /// - Parameter error: What the request raised.
    /// - Returns: The failure, by kind only.
    static func failure(for error: Error) -> RequestFailure {
        guard let urlError = error as? URLError else { return .requestFailed }
        if urlError.code == .timedOut { return .timeout }
        return connectionCodes.contains(urlError.code) ? .connection : .requestFailed
    }
}
