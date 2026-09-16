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

/// Reads JSON a source sends that a strict parser would refuse (#255).
///
/// E-utilities writes a raw newline into some `ERROR` texts (checked live
/// 2026-09-15, past the 9,999-record cap), which RFC 8259 forbids inside a
/// string and `JSONSerialization` therefore rejects. That answer is a service
/// error, not an unreadable one, so refusing it would report the wrong reason
/// and hide the one NCBI gave. Python reads the same answers with
/// `json.loads(strict=False)`.
enum LenientJSON {
    /// The first byte value JSON allows unescaped inside a string.
    private static let firstAllowedInString: UInt8 = 0x20

    /// A double quote, which opens and closes a JSON string.
    private static let quote: UInt8 = 0x22

    /// A backslash, which escapes the byte after it.
    private static let backslash: UInt8 = 0x5C

    /// Decode JSON, accepting raw control characters inside its strings.
    ///
    /// The decoder's own error is never kept: it quotes the input, and an
    /// E-utilities answer can repeat the request, API key included.
    ///
    /// - Parameter data: The answer's body.
    /// - Returns: The decoded value, or `nil` when the body is not JSON even
    ///   with its control characters escaped.
    static func value(from data: Data) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return value
        }
        return try? JSONSerialization.jsonObject(
            with: escapingControlCharacters(in: data), options: [.fragmentsAllowed]
        )
    }

    /// Escape every control character that appears inside a JSON string.
    ///
    /// Only bytes inside a string are rewritten: a newline between two tokens
    /// is JSON's own whitespace, and escaping it would break the document it
    /// was meant to repair. Multi-byte UTF-8 sequences are untouched, since
    /// every byte of one is `0x80` or above.
    ///
    /// - Parameter data: The answer's body.
    /// - Returns: The same document with each raw control character inside a
    ///   string written as `\u00xx`.
    static func escapingControlCharacters(in data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        var insideString = false
        var afterBackslash = false

        for byte in data {
            guard insideString else {
                if byte == quote { insideString = true }
                output.append(byte)
                continue
            }
            if afterBackslash {
                afterBackslash = false
                output.append(byte)
                continue
            }
            switch byte {
            case backslash:
                afterBackslash = true
                output.append(byte)
            case quote:
                insideString = false
                output.append(byte)
            case ..<firstAllowedInString:
                output.append(contentsOf: Array(String(format: "\\u%04x", Int(byte)).utf8))
            default:
                output.append(byte)
            }
        }
        return output
    }
}
