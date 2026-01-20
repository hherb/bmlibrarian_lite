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
import os.log

// MARK: - Sync Scope Manager

/// Manages sync scope configuration for a device.
///
/// The sync scope determines what data this device downloads and keeps locally.
/// Different devices can have different scopes based on their storage constraints
/// and usage patterns.
///
/// Supports multiple sync modes:
/// - `full`: Sync all data (default for desktops)
/// - `selective`: Only sync whitelisted sessions
/// - `recent`: Only sync sessions from last N days
/// - `minimal`: Only sync metadata, fetch content on-demand
///
/// Thread Safety: This is an actor with isolated state.
///
/// Example:
/// ```swift
/// let manager = SyncScopeManager(storage: storage, deviceConfig: config)
///
/// // Set to selective mode
/// try await manager.setSyncMode(.selective)
///
/// // Add session to whitelist
/// try await manager.addToWhitelist("session-id")
///
/// // Check if session should be synced
/// let inScope = await manager.isInScope("session-id")
/// ```
public actor SyncScopeManager {
    // MARK: - Properties

    /// Storage backend for persisting configuration.
    private let storage: SyncStorageProtocol

    /// Device configuration (mutable for scope changes).
    private var deviceConfig: DeviceConfig

    /// Local exclusions (sessions excluded on this device only).
    private var exclusions: LocalExclusions

    /// JSON encoder for saving configuration.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Logger for scope operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.sync",
        category: "SyncScope"
    )

    // MARK: - Initialization

    /// Creates a sync scope manager.
    ///
    /// - Parameters:
    ///   - storage: Storage backend for configuration persistence.
    ///   - deviceConfig: Initial device configuration.
    public init(storage: SyncStorageProtocol, deviceConfig: DeviceConfig) {
        self.storage = storage
        self.deviceConfig = deviceConfig
        self.exclusions = LocalExclusions()
    }

    /// Creates a sync scope manager with existing exclusions.
    ///
    /// - Parameters:
    ///   - storage: Storage backend for configuration persistence.
    ///   - deviceConfig: Initial device configuration.
    ///   - exclusions: Existing local exclusions.
    public init(
        storage: SyncStorageProtocol,
        deviceConfig: DeviceConfig,
        exclusions: LocalExclusions
    ) {
        self.storage = storage
        self.deviceConfig = deviceConfig
        self.exclusions = exclusions
    }

    // MARK: - Sync Mode

    /// Gets the current sync mode.
    ///
    /// - Returns: Current sync mode (full, selective, recent, or minimal).
    public func getSyncMode() -> SyncMode {
        deviceConfig.syncScope.mode
    }

    /// Sets the sync mode.
    ///
    /// Persists the change to storage for consistency across app launches.
    ///
    /// - Parameter mode: New sync mode.
    /// - Throws: If configuration cannot be saved.
    public func setSyncMode(_ mode: SyncMode) async throws {
        deviceConfig.syncScope.mode = mode
        try await saveDeviceConfig()
        logger.info("Sync mode changed to: \(mode.rawValue)")
    }

    // MARK: - Session Filter

    /// Gets the session filter configuration.
    ///
    /// - Returns: Session filter, or nil if no filter is set.
    public func getSessionFilter() -> SessionFilter? {
        deviceConfig.syncScope.sessionFilter
    }

    /// Sets the session filter.
    ///
    /// - Parameter filter: New session filter, or nil to clear.
    /// - Throws: If configuration cannot be saved.
    public func setSessionFilter(_ filter: SessionFilter?) async throws {
        deviceConfig.syncScope.sessionFilter = filter
        try await saveDeviceConfig()
    }

    /// Adds a session to the whitelist.
    ///
    /// If no filter exists, creates one in whitelist mode.
    ///
    /// - Parameter sessionId: Session identifier to add.
    /// - Throws: If configuration cannot be saved.
    public func addToWhitelist(_ sessionId: String) async throws {
        if deviceConfig.syncScope.sessionFilter == nil {
            deviceConfig.syncScope.sessionFilter = SessionFilter(mode: .whitelist)
        }

        // Avoid duplicates
        if deviceConfig.syncScope.sessionFilter?.ids.contains(sessionId) == false {
            deviceConfig.syncScope.sessionFilter?.ids.append(sessionId)
            try await saveDeviceConfig()
            logger.info("Added session to whitelist: \(sessionId)")
        }
    }

    /// Removes a session from the whitelist.
    ///
    /// - Parameter sessionId: Session identifier to remove.
    /// - Throws: If configuration cannot be saved.
    public func removeFromWhitelist(_ sessionId: String) async throws {
        deviceConfig.syncScope.sessionFilter?.ids.removeAll { $0 == sessionId }
        try await saveDeviceConfig()
        logger.info("Removed session from whitelist: \(sessionId)")
    }

    /// Gets all whitelisted session IDs.
    ///
    /// - Returns: Array of whitelisted session IDs, or empty if no whitelist.
    public func getWhitelistedSessions() -> [String] {
        deviceConfig.syncScope.sessionFilter?.ids ?? []
    }

    // MARK: - Scope Checking

    /// Checks if a session is in scope for syncing.
    ///
    /// Takes into account:
    /// - Local exclusions (excluded sessions are out of scope)
    /// - Sync mode (full, selective, recent, minimal)
    /// - Session filter (whitelist or recent days)
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session should be synced to this device.
    public func isInScope(_ sessionId: String) -> Bool {
        // Check local exclusions first
        if exclusions.isExcluded(sessionId) {
            return false
        }

        switch deviceConfig.syncScope.mode {
        case .full:
            // Full mode syncs everything
            return true

        case .selective:
            // Selective mode uses whitelist
            guard let filter = deviceConfig.syncScope.sessionFilter else {
                return true // No filter = include all
            }
            return filter.ids.contains(sessionId)

        case .recent:
            // Recent mode would check creation/modification date
            // For now, delegate to filter if present
            if let filter = deviceConfig.syncScope.sessionFilter,
               filter.mode == .recent {
                // Would need session date to check against recentDays
                // For now, return true (filter at sync time)
                return true
            }
            return true

        case .minimal:
            // Minimal mode only syncs stubs
            return false
        }
    }

    /// Checks if a session is in scope with date consideration.
    ///
    /// For recent mode, checks if the session date is within the configured
    /// recent days threshold.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - sessionDate: Session's creation or last modification date.
    /// - Returns: True if session should be synced to this device.
    public func isInScope(_ sessionId: String, sessionDate: Date) -> Bool {
        // Check local exclusions first
        if exclusions.isExcluded(sessionId) {
            return false
        }

        switch deviceConfig.syncScope.mode {
        case .full:
            return true

        case .selective:
            guard let filter = deviceConfig.syncScope.sessionFilter else {
                return true
            }
            return filter.ids.contains(sessionId)

        case .recent:
            // Check if within recent days threshold
            if let filter = deviceConfig.syncScope.sessionFilter,
               let recentDays = filter.recentDays {
                let cutoffDate = Calendar.current.date(
                    byAdding: .day,
                    value: -recentDays,
                    to: Date()
                ) ?? Date.distantPast
                return sessionDate >= cutoffDate
            }
            // Default to 90 days if not configured
            let defaultCutoff = Calendar.current.date(
                byAdding: .day,
                value: -SyncConstants.defaultAutoEvictDays,
                to: Date()
            ) ?? Date.distantPast
            return sessionDate >= defaultCutoff

        case .minimal:
            return false
        }
    }

    // MARK: - Local Exclusions

    /// Excludes a session locally (without affecting cloud).
    ///
    /// Excluded sessions won't be synced to this device even if they're
    /// in scope. The session remains in the cloud for other devices.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - reason: Reason for exclusion.
    public func excludeLocally(_ sessionId: String, reason: ExclusionReason) {
        exclusions.exclude(sessionId, reason: reason)
        logger.info("Excluded session locally: \(sessionId), reason: \(reason.rawValue)")
    }

    /// Includes a previously excluded session.
    ///
    /// Removes the local exclusion so the session can be synced again.
    ///
    /// - Parameter sessionId: Session identifier.
    public func includeLocally(_ sessionId: String) {
        exclusions.include(sessionId)
        logger.info("Included session locally: \(sessionId)")
    }

    /// Gets all local exclusions.
    ///
    /// - Returns: Current local exclusions.
    public func getExclusions() -> LocalExclusions {
        exclusions
    }

    /// Checks if a session is locally excluded.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: True if session is excluded locally.
    public func isExcluded(_ sessionId: String) -> Bool {
        exclusions.isExcluded(sessionId)
    }

    /// Gets the exclusion reason for a session.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: Exclusion reason, or nil if not excluded.
    public func getExclusionReason(_ sessionId: String) -> ExclusionReason? {
        exclusions.reason(for: sessionId)
    }

    // MARK: - Storage Limits

    /// Sets the maximum local storage.
    ///
    /// - Parameter maxMB: Maximum storage in megabytes.
    /// - Throws: If configuration cannot be saved.
    public func setMaxLocalStorage(_ maxMB: Int) async throws {
        deviceConfig.syncScope.maxLocalStorageMB = maxMB
        try await saveDeviceConfig()
        logger.info("Max local storage set to: \(maxMB) MB")
    }

    /// Gets the maximum local storage limit.
    ///
    /// - Returns: Storage limit in megabytes.
    public func getMaxLocalStorage() -> Int {
        deviceConfig.syncScope.maxLocalStorageMB
    }

    // MARK: - Auto-Eviction Configuration

    /// Configures auto-eviction.
    ///
    /// - Parameter config: Auto-eviction configuration, or nil to disable.
    /// - Throws: If configuration cannot be saved.
    public func setAutoEviction(_ config: AutoEvictionConfig?) async throws {
        deviceConfig.syncScope.autoEviction = config
        try await saveDeviceConfig()
        logger.info("Auto-eviction configured: \(config?.enabled ?? false ? "enabled" : "disabled")")
    }

    /// Gets auto-eviction configuration.
    ///
    /// - Returns: Auto-eviction config, or nil if not configured.
    public func getAutoEviction() -> AutoEvictionConfig? {
        deviceConfig.syncScope.autoEviction
    }

    /// Checks if auto-eviction is enabled.
    ///
    /// - Returns: True if auto-eviction is enabled.
    public func isAutoEvictionEnabled() -> Bool {
        deviceConfig.syncScope.autoEviction?.enabled ?? false
    }

    // MARK: - Device Configuration

    /// Gets the current device configuration.
    ///
    /// - Returns: Current device configuration.
    public func getDeviceConfig() -> DeviceConfig {
        deviceConfig
    }

    /// Updates the device's last seen timestamp.
    ///
    /// Should be called after successful sync operations.
    ///
    /// - Throws: If configuration cannot be saved.
    public func updateLastSeen() async throws {
        deviceConfig.lastSeen = Date()
        try await saveDeviceConfig()
    }

    // MARK: - Persistence

    /// Saves the device configuration to storage.
    ///
    /// Creates an integrity envelope around the configuration for
    /// verification on load.
    private func saveDeviceConfig() async throws {
        let envelope = try createIntegrityEnvelope(deviceConfig)
        let data = try encoder.encode(envelope)
        let path = SyncFileNaming.deviceFilePath(deviceId: deviceConfig.deviceId)
        try await storage.writeFile(data, at: path)
        logger.debug("Device config saved to: \(path)")
    }

    /// Reloads device configuration from storage.
    ///
    /// Useful after another process may have modified the configuration.
    ///
    /// - Throws: If configuration cannot be loaded or verified.
    public func reloadDeviceConfig() async throws {
        let path = SyncFileNaming.deviceFilePath(deviceId: deviceConfig.deviceId)
        let data = try await storage.readFile(at: path)
        let loadedConfig: DeviceConfig = try verifyAndExtract(from: data)
        deviceConfig = loadedConfig
        logger.debug("Device config reloaded from: \(path)")
    }
}
