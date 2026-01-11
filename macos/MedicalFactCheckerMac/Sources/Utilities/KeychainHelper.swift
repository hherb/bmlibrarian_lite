//
//  KeychainHelper.swift
//  MedicalFactChecker
//
//  Secure storage for API keys using iOS Keychain.
//

import Foundation
import Security

/// Helper for secure storage of sensitive data in the iOS Keychain.
enum KeychainHelper {
    /// Save a string value to the Keychain.
    ///
    /// - Parameters:
    ///   - key: The key to store the value under.
    ///   - value: The string value to store.
    /// - Returns: True if successful, false otherwise.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Don't save empty values
        guard !value.isEmpty else { return true }

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.medicalfactchecker"
    }
}
