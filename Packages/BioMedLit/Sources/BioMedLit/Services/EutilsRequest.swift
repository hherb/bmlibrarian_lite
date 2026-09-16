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

/// How a request to NCBI's E-utilities is put together.
///
/// Every parameter, the API key included, travels in a form-encoded POST body
/// and never in the URL. A query string is part of the URL, and a URL is what
/// gets printed: `URLError` carries it in its `userInfo`, HTTP logging writes
/// it, and ``PubMedService`` itself used to log it at debug level as a public
/// value, release builds included (#243, the Swift half of #196). Redacting
/// would mean finding every printer; keeping the key out of the URL covers all
/// of them. NCBI reads `api_key` from a POST body on `esearch` and `efetch`
/// exactly as it does from a query string.
///
/// The contract is in `doc/developer/europepmc_and_pubmed.md`.
enum EutilsRequest {
    /// Content type of the request body.
    static let formContentType = "application/x-www-form-urlencoded"

    /// Name of the HTTP header that states the body's content type.
    static let contentTypeHeader = "Content-Type"

    /// HTTP method every E-utilities request is sent with.
    static let method = "POST"

    /// Bytes the form serializer leaves as they are: ASCII letters and digits,
    /// and `*-._`. Everything else is percent-encoded, a space excepted.
    private static let unescapedBytes: Set<UInt8> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._".utf8
    )

    /// Build a POST to an E-utilities endpoint with the parameters in its body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint, such as ``BioMedLitConstants/pubmedSearchURL``.
    ///     It is sent as given, so it must not carry a query of its own.
    ///   - parameters: Name–value pairs, in the order they are sent.
    /// - Returns: A POST request with the form content type and the encoded body.
    static func post(to endpoint: URL, parameters: [(name: String, value: String)]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue(formContentType, forHTTPHeaderField: contentTypeHeader)
        request.httpBody = formEncodedBody(parameters)
        return request
    }

    /// Serialize name–value pairs as `application/x-www-form-urlencoded`.
    ///
    /// Follows the WHATWG URL Standard's serializer: ASCII letters, digits and
    /// `*-._` are kept, a space becomes `+`, and every other byte of the UTF-8
    /// encoding becomes `%XX`. `+`, `&` and `=` in particular must be escaped:
    /// unescaped, a query `a+b` reaches NCBI as `a b`, and `x&retmax=1` splits
    /// into a parameter nobody sent.
    ///
    /// - Parameter parameters: Name–value pairs, in order.
    /// - Returns: The UTF-8 bytes of the encoded body.
    static func formEncodedBody(_ parameters: [(name: String, value: String)]) -> Data {
        let pairs = parameters.map { "\(formEncode($0.name))=\(formEncode($0.value))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    /// Form-encode one name or value.
    ///
    /// - Parameter text: The raw text.
    /// - Returns: The text as it appears in a form-encoded body.
    static func formEncode(_ text: String) -> String {
        var encoded = ""
        for byte in text.utf8 {
            if unescapedBytes.contains(byte) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else if byte == UInt8(ascii: " ") {
                encoded.append("+")
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }
}

/// A task delegate that declines every HTTP redirect.
///
/// A redirect is a failed E-utilities request, never one to follow. A 307 or
/// 308 re-sends the POST body, API key included, to whatever host the redirect
/// names; a 301, 302 or 303 re-sends the request as a GET without its
/// parameters, which NCBI answers as a search for nothing. Declining leaves the
/// task to finish with the 3xx response itself, which the caller reports as
/// a refused redirect (``RequestFailureKind/redirectRefused``).
///
/// Not even a redirect to an NCBI host is followed. These endpoints never
/// legitimately redirect, following a 301, 302 or 303 can never yield a correct
/// answer, and a same-host redirect can still downgrade to `http://` and carry
/// the key in cleartext. Matching hosts would be logic to get wrong for no gain.
///
/// Passed per task (`URLSession.data(for:delegate:)`), so it applies whatever
/// session the service was given. Background sessions always follow redirects
/// and never ask, so a PubMed request must not run on one.
final class RedirectRefusingTaskDelegate: NSObject, URLSessionTaskDelegate {
    /// Decline the redirect.
    ///
    /// - Parameters:
    ///   - session: The session running the task.
    ///   - task: The task being redirected.
    ///   - response: The 3xx response naming the new location.
    ///   - request: The request that following would send.
    ///   - completionHandler: Called with `nil`, which delivers the 3xx response
    ///     as the task's result instead of following it.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
