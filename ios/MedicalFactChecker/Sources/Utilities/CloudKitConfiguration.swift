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

import CloudKit
import Foundation
import OSLog
import SwiftData

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

    /// Logger for what becomes of the store.
    ///
    /// Built here rather than through `AppLogger`, which exists twice — once
    /// behind `#if os(iOS)` and once in the macOS-only sources — so a file
    /// shared by both platforms can use neither (#290). Same subsystem as
    /// `FactCheckWorkflow`'s.
    private static let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "Persistence"
    )

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

    /// Create a ModelContainer with migration support.
    ///
    /// - Returns: Configured ModelContainer with schema migration enabled.
    /// - Throws: SwiftData errors if container creation fails.
    ///
    /// Uses the `MedicalFactCheckerMigrationPlan` to handle schema upgrades
    /// from previous versions, preserving user data during updates. A store that
    /// survives none of the strategies is set aside rather than deleted, and
    /// what happened waits in ``StoreRecovery`` for the next launch to tell the
    /// user (#285).
    static func makeModelContainerWithMigration() throws -> ModelContainer {
        let useCloudKit = isSyncEnabled && isCloudAvailable

        // Create schema from the current version's models
        let schema = Schema(versionedSchema: SchemaV2.self)

        let configuration: ModelConfiguration
        if useCloudKit {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }

        return try makeContainer(
            schema: schema,
            configuration: configuration,
            setAsideUnreadableStore: { setAsideApplicationSupportStore() }
        )
    }

    /// Open a store, trying every way to keep what it holds.
    ///
    /// - Parameters:
    ///   - schema: The schema of the models to store.
    ///   - configuration: Where and how the store is kept.
    ///   - setAsideUnreadableStore: Called at most once, as the last resort, to
    ///     move a store no migration could read out of the way. It must not
    ///     delete it: what the user saved is kept, whether or not this app can
    ///     read it. What it returns decides whether a fresh store may be opened.
    /// - Returns: The container. It holds what the store held, unless the store
    ///   was set aside — or there was no store yet, as on a first launch.
    /// - Throws: Whatever SwiftData raised, for anything that is not a migration
    ///   failure; ``StoreSetAsideFailure`` when the store could not be moved out
    ///   of the way, because a fresh database beside an old write-ahead log
    ///   would put the data still on disk beyond recovery; and whatever a fresh
    ///   store raised when it could not be created either.
    ///
    /// ## The three strategies
    ///
    /// 1. Staged migration with the full plan. A store written by a build whose
    ///    models differed matches no version in the plan — see the
    ///    "Why there is no Schema Version 3" note in `SchemaVersions.swift` — so
    ///    this fails with "unknown model version" for exactly the upgrade it
    ///    looks like it is for.
    /// 2. Automatic lightweight migration, which is what actually carries a
    ///    user's fact checks across a property being added.
    /// 3. Set the store aside and start empty. The user's data is not lost, but
    ///    it is out of the app, so it is reported rather than logged alone.
    static func makeContainer(
        schema: Schema,
        configuration: ModelConfiguration,
        setAsideUnreadableStore: () -> SetAsideStore
    ) throws -> ModelContainer {
        // Strategy 1: Try staged migration with full plan
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: MedicalFactCheckerMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            guard isMigrationError(error) else { throw error }
            logger.error(
                "Staged migration failed, attempting automatic migration: \(String(describing: error), privacy: .public)"
            )
        }

        // Strategy 2: Try without migration plan (automatic lightweight migration)
        do {
            return try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            guard isMigrationError(error) else { throw error }
            logger.error(
                "Automatic migration failed, setting the store aside: \(String(describing: error), privacy: .public)"
            )
        }

        // Strategy 3: Keep the store the app cannot read, and start fresh
        let outcome = setAsideUnreadableStore()
        guard outcome.isSafeToStartFresh else {
            // Some of the store is still where SwiftData writes. Opening a fresh
            // database next to an old write-ahead log is what would destroy the
            // bytes this whole path exists to keep, so the app stops instead.
            throw StoreSetAsideFailure(outcome: outcome)
        }

        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    // MARK: - Private Helpers

    /// Whether an error is one another way of opening the store might survive.
    ///
    /// Anything else is the caller's to raise: it is not a store this app can
    /// decide about.
    ///
    /// ## Why this reads the error as text
    ///
    /// `SwiftDataError` carries its case in a private enum and drops the Cocoa
    /// error behind it (`_underlyingCocoaError` is `nil`), so the code
    /// underneath — 134504 for a store no version in the plan matches — never
    /// reaches a caller. Its public `unknownDataStoreSchema` exists only from
    /// macOS 27 and iOS 27, far above this app's minimum, so the case name in
    /// the error's own description is what there is to match on.
    ///
    /// `unknownDataStoreSchema` is the ordinary upgrade: every store written by a
    /// build whose model classes differed from these raises it, because a
    /// schema's checksum is computed from the live model classes and any added
    /// property moves it. (A release that leaves every `@Model` alone is not
    /// affected, which is why the migration plan is not dead code.) Missing it
    /// made the app raise that error out of container creation, where both entry
    /// points end in `fatalError` — a crash at launch for exactly the users
    /// whose data the strategies exist to keep (found by `StoreMigrationTests`).
    ///
    /// Measured on macOS 27; the wording of the underlying diagnostic may differ
    /// on the older systems this app still supports, which is why the numeric
    /// codes and "unknown model version" stay in the list beside it.
    ///
    /// - Parameter error: What opening the store raised.
    /// - Returns: `true` when another strategy is worth trying.
    static func isMigrationError(_ error: Error) -> Bool {
        let errorDescription = String(describing: error)

        let migrationIndicators = [
            "134110",   // NSMigrationError
            "134120",   // NSMigrationManagerSourceStoreError
            "134130",   // NSMigrationMissingSourceModelError
            "134140",   // NSMigrationMissingMappingModelError
            "134504",   // Staged migration unknown version
            "unknown model version",
            "unknownDataStoreSchema",   // What SwiftData raises for that same 134504
            "migration",
            "loadIssueModelContainer",
        ]

        return migrationIndicators.contains { errorDescription.localizedCaseInsensitiveContains($0) }
    }

    /// Move the app's own store out of the way, keeping every byte of it.
    ///
    /// The last resort when no migration could read it. Nothing is deleted: the
    /// files are moved into a folder of their own, what happened is logged, and
    /// the sentence the user is owed waits for the first view that can show it
    /// (#285, golden rule 8).
    ///
    /// - Parameters:
    ///   - directory: Where the store lives. The default is Application
    ///     Support, which is where `ModelConfiguration` puts `default.store`;
    ///     tests pass their own.
    ///   - defaults: Where the pending message waits.
    ///   - fileManager: The file manager to look and move with.
    /// - Returns: What became of the store, which decides whether the caller may
    ///   open a fresh one.
    static func setAsideApplicationSupportStore(
        in directory: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> SetAsideStore {
        guard let storeDirectory = directory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            logger.error(
                "The store could not be read and this device has no Application Support directory to set it aside in"
            )
            StoreRecovery.recordPendingMessage(StoreRecovery.unreachableStoreMessage, in: defaults)
            return .noStoreFound
        }

        let outcome = StoreRecovery.setAsideStore(in: storeDirectory, fileManager: fileManager)
        logger.error(
            """
            A store that could not be read was set aside in \(storeDirectory.path, privacy: .public): \
            \(String(describing: outcome), privacy: .public)
            """
        )
        // Reaching here at all means a store failed to open, so an empty History
        // is news the user is owed even when this app found no file to move.
        StoreRecovery.recordPendingMessage(
            StoreRecovery.message(for: outcome) ?? StoreRecovery.unreachableStoreMessage,
            in: defaults
        )
        return outcome
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
