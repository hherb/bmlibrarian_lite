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
import SwiftData
import CloudKit

/// Manages CloudKit sync configuration and state.
///
/// This enum provides centralized control over iCloud sync settings, including:
/// - User preference for sync enable/disable
/// - iCloud availability checking
/// - ModelConfiguration creation for SwiftData
/// - CloudKit account status monitoring
enum CloudKitConfiguration {

    // MARK: - Constants

    /// CloudKit container identifier (must match entitlements).
    static let containerIdentifier = "iCloud.com.hherb.MedicalFactChecker"

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let syncEnabled = "icloud_sync_enabled"
        static let pendingRestart = "icloud_pending_restart"
    }

    // MARK: - Sync Preference

    /// Whether iCloud sync is enabled by user preference.
    ///
    /// Defaults to `false` - sync is opt-in.
    static var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.syncEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.syncEnabled) }
    }

    /// Whether a restart is needed to apply sync changes.
    ///
    /// Set to `true` when sync preference changes, cleared at app launch.
    static var pendingConfigChange: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.pendingRestart) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pendingRestart) }
    }

    // MARK: - Availability

    /// Check if iCloud is available on this device.
    ///
    /// Returns `true` if the user is signed into iCloud.
    static var isCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    // MARK: - Configuration

    /// Create ModelConfiguration based on current settings.
    ///
    /// - Parameter schema: The SwiftData schema to use.
    /// - Returns: Configured ModelConfiguration for SwiftData container.
    ///
    /// If sync is enabled and iCloud is available, returns a configuration
    /// with CloudKit sync enabled. Otherwise, returns a local-only configuration.
    static func makeModelConfiguration(schema: Schema) -> ModelConfiguration {
        let useCloudKit = isSyncEnabled && isCloudAvailable

        if useCloudKit {
            // CloudKit-enabled configuration
            return ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
        } else {
            // Local-only configuration
            return ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }
    }

    // MARK: - Sync Control

    /// Request sync setting change (requires app restart to take effect).
    ///
    /// - Parameter enabled: Whether to enable or disable sync.
    ///
    /// Since the ModelContainer is created at app launch, changes to sync
    /// settings require an app restart to take effect.
    static func requestSyncChange(enabled: Bool) {
        guard enabled != isSyncEnabled else { return }
        isSyncEnabled = enabled
        pendingConfigChange = true
    }

    /// Clear pending change flag (called at app launch).
    ///
    /// Call this during app initialization to acknowledge that any pending
    /// configuration changes have been applied.
    static func clearPendingChange() {
        pendingConfigChange = false
    }

    // MARK: - Account Status

    /// Check CloudKit account status asynchronously.
    ///
    /// - Returns: Current CKAccountStatus indicating iCloud account state.
    ///
    /// Possible values:
    /// - `.available`: User is signed in and iCloud is accessible
    /// - `.noAccount`: User is not signed into iCloud
    /// - `.restricted`: iCloud access is restricted (e.g., parental controls)
    /// - `.temporarilyUnavailable`: iCloud is temporarily unavailable
    /// - `.couldNotDetermine`: Status could not be determined
    static func checkAccountStatus() async -> CKAccountStatus {
        do {
            let container = CKContainer(identifier: containerIdentifier)
            return try await container.accountStatus()
        } catch {
            print("Failed to check CloudKit account status: \(error)")
            return .couldNotDetermine
        }
    }
}
