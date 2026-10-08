// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

/// The fingerprints a service asked with the user's own key remembers a refusal
/// by (#498, #480 stage C2): Python's `keyed_service_session.key_digest` and
/// `credentials_digest`. The key and the token themselves are never held for
/// that, and a digest is never logged.
enum KeyDigest {
    /// The fingerprint a refused key is remembered by: the SHA-256 digest of the
    /// trimmed key's UTF-8 bytes, as lower-case hex. Padding names the same key.
    ///
    /// - Parameter apiKey: The key, as the settings hold it.
    /// - Returns: 64 lower-case hex digits.
    static func key(_ apiKey: String) -> String {
        hex(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The fingerprint a refusal from this network is remembered by: the SHA-256
    /// digest of `trim(key) + "\n" + trim(token, or "")`, as lower-case hex. A
    /// token added in the settings makes other credentials, which are asked again.
    ///
    /// - Parameters:
    ///   - apiKey: The key, as the settings hold it.
    ///   - token: The institutional token, or `nil`; a blank one is no token.
    /// - Returns: 64 lower-case hex digits.
    static func credentials(key apiKey: String, token: String?) -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return hex("\(key)\n\(token)")
    }

    /// The SHA-256 digest of a text's UTF-8 bytes, as lower-case hex.
    private static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What one keyed service's fetches leave for the next, within this process
/// (Python's `KeyedServiceSession`).
///
/// CORE and Elsevier share the rules, each with its own instance, so a CORE 429
/// never pauses Elsevier. Consecutive fetches ending in 429 pause the service
/// until the process ends: its key buys a quota no pacing can express. A fetch
/// ending on the service's key-refused status refuses the key it was sent with,
/// held as its ``KeyDigest/key(_:)``: another key, such as one corrected in the
/// settings, is asked as usual. A refusal from this network refuses those
/// credentials, held as their ``KeyDigest/credentials(key:token:)``. A fetch
/// that makes no request (refused or paused) is recorded nowhere.
public class KeyedServiceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let serviceName: String
    private let keyRefusedStatus: Int
    private let pauseAfter: Int
    private var consecutive = 0
    private var paused = false
    private var refusedKeyDigest: String?
    private var refusedCredentialsDigest: String?

    /// Start unpaused, with nothing refused.
    ///
    /// - Parameters:
    ///   - serviceName: The service as log lines name it.
    ///   - keyRefusedStatus: The HTTP status that means the key is refused.
    ///   - pauseAfter: Consecutive 429 endings that pause the service.
    init(serviceName: String, keyRefusedStatus: Int, pauseAfter: Int) {
        self.serviceName = serviceName
        self.keyRefusedStatus = keyRefusedStatus
        self.pauseAfter = pauseAfter
    }

    /// Whether the service is paused for the rest of the session.
    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Whether the service refused this key this session; any other key is asked as usual.
    ///
    /// - Parameter keyDigest: The key's ``KeyDigest/key(_:)``.
    public func refuses(keyDigest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refusedKeyDigest == keyDigest
    }

    /// Whether the service refused these credentials from this network this session;
    /// any other key, or the same key with another token, is asked as usual.
    ///
    /// - Parameter credentialsDigest: The ``KeyDigest/credentials(key:token:)`` of the
    ///   key and the token.
    public func refusesNetwork(credentialsDigest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return refusedCredentialsDigest == credentialsDigest
    }

    /// Note how one fetch that made a request ended. The key-refused status marks the
    /// key it was sent with refused, in place of any key refused before; like any
    /// ending but a 429, it also resets the 429 count. A refusal is logged here, once,
    /// when it is new, and so is the pause, when this ending starts it. The articles
    /// skipped afterwards are not logged, and the key and its digest never are.
    ///
    /// - Parameters:
    ///   - status: Its HTTP status, or nil when it got none.
    ///   - keyDigest: The ``KeyDigest/key(_:)`` of the key it was sent with.
    func record(endedOn status: Int?, keyDigest: String) {
        let (newlyRefused, pausedAfter) = noteEnding(status, keyDigest: keyDigest)
        if newlyRefused {
            BioMedLitLib.logger?.warning(
                "\(serviceName) refused the configured API key (HTTP \(keyRefusedStatus)); "
                    + "it is not asked with that key again this session",
                category: .fullText
            )
        }
        if let pausedAfter {
            BioMedLitLib.logger?.warning(
                "\(serviceName) answered HTTP \(BioMedLitConstants.httpStatusRateLimited) "
                    + "\(pausedAfter) times in a row; it is not asked again this session",
                category: .fullText
            )
        }
    }

    /// Note a fetch the service refused from this network. It is an ending, so it
    /// resets the 429 count; those credentials are refused, in place of any before.
    /// Logged once, when new; the credentials and their digest never are.
    ///
    /// - Parameter credentialsDigest: The ``KeyDigest/credentials(key:token:)`` it was
    ///   sent with.
    func recordNetworkRefused(credentialsDigest: String) {
        if noteNetworkRefused(credentialsDigest) {
            BioMedLitLib.logger?.warning(
                "\(serviceName) refused the configured credentials from this network; "
                    + "it is not asked with them again this session",
                category: .fullText
            )
        }
    }

    /// The state change behind ``record(endedOn:keyDigest:)``, under the lock.
    ///
    /// - Returns: Whether this ending newly refused the key, and the count of
    ///   consecutive 429 endings when it started the pause (`nil` otherwise).
    private func noteEnding(_ status: Int?, keyDigest: String) -> (newlyRefused: Bool, pausedAfter: Int?) {
        lock.lock(); defer { lock.unlock() }
        var newlyRefused = false
        if status == keyRefusedStatus {
            newlyRefused = refusedKeyDigest != keyDigest
            refusedKeyDigest = keyDigest
        }
        guard status == BioMedLitConstants.httpStatusRateLimited else {
            consecutive = 0
            return (newlyRefused, nil)
        }
        consecutive += 1
        guard consecutive >= pauseAfter, !paused else { return (newlyRefused, nil) }
        paused = true
        return (newlyRefused, consecutive)
    }

    /// The state change behind ``recordNetworkRefused(credentialsDigest:)``, under the lock.
    private func noteNetworkRefused(_ credentialsDigest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        consecutive = 0
        let newlyRefused = refusedCredentialsDigest != credentialsDigest
        refusedCredentialsDigest = credentialsDigest
        return newlyRefused
    }
}
