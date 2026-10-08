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
import OSLog
import Security

/// Where the app keeps its API keys: the Keychain in the app, a stand-in in
/// tests, which have no Keychain entitlement to save with.
protocol SecretStore {
    /// The value stored under `key`, or nil when none is.
    func load(key: String) -> String?

    /// Store `value` under `key`; an empty value removes it. A failure leaves
    /// what was stored before.
    ///
    /// - Returns: Whether it was stored (or removed).
    func save(key: String, value: String) -> Bool

    /// Remove the value under `key`.
    ///
    /// - Returns: Whether it is gone (or never was).
    func delete(key: String) -> Bool
}

/// The Keychain, as a ``SecretStore``.
struct KeychainSecretStore: SecretStore {
    /// See ``KeychainHelper/load(key:)``.
    func load(key: String) -> String? { KeychainHelper.load(key: key) }

    /// See ``KeychainHelper/save(key:value:)``.
    func save(key: String, value: String) -> Bool { KeychainHelper.save(key: key, value: value) }

    /// See ``KeychainHelper/delete(key:)``.
    func delete(key: String) -> Bool { KeychainHelper.delete(key: key) }
}

/// Helper for secure storage of sensitive data in the iOS Keychain.
enum KeychainHelper {
    /// Where a failed save or delete is logged, by the account name and the
    /// `OSStatus`; never the value.
    private static let logger = Logger(subsystem: bundleIdentifier, category: "Keychain")

    /// Save a string value to the Keychain, in place: the stored item is
    /// updated, or added when there is none, so a failed save never loses the
    /// value stored before. An empty value deletes the item.
    ///
    /// - Parameters:
    ///   - key: The key to store the value under.
    ///   - value: The string value to store.
    /// - Returns: True if successful, false otherwise (logged).
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard !value.isEmpty else { return delete(key: key) }
        let data = Data(value.utf8)
        let query = itemQuery(key)

        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Keychain update of \(key, privacy: .public) failed: OSStatus \(updateStatus)")
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("Keychain add of \(key, privacy: .public) failed: OSStatus \(addStatus)")
            return false
        }
        return true
    }

    /// Load a string value from the Keychain.
    ///
    /// - Parameter key: The key to load the value for.
    /// - Returns: The stored string value, or nil if not found.
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Delete a value from the Keychain.
    ///
    /// - Parameter key: The key to delete.
    /// - Returns: True if successful or item didn't exist, false on error.
    @discardableResult
    static func delete(key: String) -> Bool {
        let status = SecItemDelete(itemQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete of \(key, privacy: .public) failed: OSStatus \(status)")
            return false
        }
        return true
    }

    /// Check if a key exists in the Keychain.
    ///
    /// - Parameter key: The key to check.
    /// - Returns: True if the key exists, false otherwise.
    static func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Private

    /// The query naming one item: this app's generic password for `key`.
    ///
    /// - Parameter key: The account the item is stored under.
    /// - Returns: The query's attributes.
    private static func itemQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
        ]
    }

    /// The Keychain service items are stored under: the bundle identifier.
    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.medicalfactchecker"
    }
}
