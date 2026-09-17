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
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// A store written by an earlier build keeps its fact checks (#285).
///
/// Every schema version in this app is built from the live model classes, so
/// adding a property moves them all at once and a store written before it
/// matches none of them. Staged migration then refuses, and the automatic
/// lightweight migration behind it is what carries the user's data — which is
/// the strategy nothing tested when it was the only thing standing between a
/// user's history and the third strategy.
final class StoreMigrationTests: XCTestCase {
    /// A session as an earlier build stored it: the same entity, fewer properties.
    ///
    /// Standing in for every past shape of the store, including the one before
    /// the search-failure properties arrived.
    enum EarlierBuildSchema: VersionedSchema {
        static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
        static var models: [any PersistentModel.Type] { [FactCheckSession.self] }

        @Model
        final class FactCheckSession {
            var id: UUID = UUID()
            var claim: String = ""
            var createdAt: Date = Date()
            var statusRaw: String = "pending"
            init(claim: String) { self.claim = claim }
        }
    }

    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StringArrayTransformer.register()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent(StoreRecovery.storeFileNames[0])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Write a store the way a build before these properties would have.
    private func writeEarlierBuildStore(claim: String) throws {
        let schema = Schema(versionedSchema: EarlierBuildSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        context.insert(EarlierBuildSchema.FactCheckSession(claim: claim))
        try context.save()
    }

    /// The schema and store this build opens, pointed at the test's own file.
    private func todaysConfiguration() -> (Schema, ModelConfiguration) {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return (schema, ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none))
    }

    /// The fact checks survive, and nothing is set aside.
    func testAStoreFromAnEarlierBuildKeepsItsFactChecks() throws {
        try writeEarlierBuildStore(claim: "a claim from an earlier build")
        var setAsideRan = false
        let (schema, configuration) = todaysConfiguration()

        let container = try CloudKitConfiguration.makeContainer(
            schema: schema,
            configuration: configuration,
            setAsideUnreadableStore: { setAsideRan = true; return .noStoreFound }
        )

        let sessions = try ModelContext(container).fetch(FetchDescriptor<FactCheckSession>())
        XCTAssertEqual(sessions.map(\.claim), ["a claim from an earlier build"])
        XCTAssertFalse(setAsideRan, "A store that migrates must never reach the last resort")
    }

    /// What such a store has never recorded reads as "not recorded", not as a
    /// damaged record that would stop the session.
    func testAMigratedSessionRecordsNoShortfalls() throws {
        try writeEarlierBuildStore(claim: "a claim from an earlier build")
        let (schema, configuration) = todaysConfiguration()

        let container = try CloudKitConfiguration.makeContainer(
            schema: schema,
            configuration: configuration,
            setAsideUnreadableStore: { .noStoreFound }
        )

        let session = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<FactCheckSession>()).first)
        XCTAssertEqual(try session.retrievalShortfalls(), [])
        XCTAssertNil(session.europePMCRecordsReceived)
    }

    /// A store that cannot be opened at all is kept, and the app still starts.
    func testAStoreThatCannotBeOpenedIsKeptRatherThanDeleted() throws {
        // Not a database at all: no migration can read it.
        try Data("not a database".utf8).write(to: storeURL)
        let (schema, configuration) = todaysConfiguration()

        let container = try CloudKitConfiguration.makeContainer(
            schema: schema,
            configuration: configuration,
            setAsideUnreadableStore: { StoreRecovery.setAsideStore(in: self.directory) }
        )

        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FactCheckSession>()).count, 0)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("unreadable-") }
        XCTAssertEqual(kept.count, 1, "The unreadable store must still be on disk")
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: directory
                        .appendingPathComponent(kept[0])
                        .appendingPathComponent("default.store")
                ),
                as: UTF8.self
            ),
            "not a database"
        )
    }

    /// A store still lying where SwiftData writes must not be written over.
    ///
    /// A fresh database beside an old write-ahead log is how the bytes this
    /// whole path exists to keep stop being recoverable, so the app stops
    /// instead, with the reason in the error rather than in SwiftData's.
    func testAStoreThatCouldNotBeMovedAsideStopsTheApp() throws {
        try Data("not a database".utf8).write(to: storeURL)
        let (schema, configuration) = todaysConfiguration()
        let leftInPlace = SetAsideStore.leftInPlace(
            fileNames: ["default.store"],
            reason: "the volume is read-only"
        )

        XCTAssertThrowsError(
            try CloudKitConfiguration.makeContainer(
                schema: schema,
                configuration: configuration,
                setAsideUnreadableStore: { leftInPlace }
            )
        ) { error in
            XCTAssertEqual(error as? StoreSetAsideFailure, StoreSetAsideFailure(outcome: leftInPlace))
            XCTAssertTrue(
                (error as? StoreSetAsideFailure)?.errorDescription?.contains("Nothing was deleted") == true,
                "The reason the app stopped must say the data is still there"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "The store must still be exactly where it was"
        )
    }

    /// The last resort the shipped app actually calls moves the store and tells
    /// the user — not only the one the other tests inject.
    func testTheAppsOwnLastResortKeepsTheStoreAndSaysSo() throws {
        try Data("not a database".utf8).write(to: storeURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-migration-\(UUID().uuidString)"))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).count

        let outcome = CloudKitConfiguration.setAsideApplicationSupportStore(
            in: directory,
            defaults: defaults
        )

        guard case .keptWhole(let folder, _) = outcome else {
            return XCTFail("The store should have been kept whole, got \(outcome)")
        }
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: directory.appendingPathComponent(folder).appendingPathComponent("default.store")
                ),
                as: UTF8.self
            ),
            "not a database",
            "Every byte the user had must still be on disk"
        )
        XCTAssertGreaterThanOrEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
            before,
            "Nothing may be removed from the store's directory"
        )
        let message = try XCTUnwrap(
            StoreRecovery.pendingMessage(in: defaults),
            "An empty History is news the user is owed (#285)"
        )
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
    }

    /// Reaching the last resort with nothing to move still owes the user a word:
    /// their History is empty and they are entitled to know why.
    func testALastResortThatFindsNoStoreStillTellsTheUser() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-migration-\(UUID().uuidString)"))

        let outcome = CloudKitConfiguration.setAsideApplicationSupportStore(
            in: directory,
            defaults: defaults
        )

        XCTAssertEqual(outcome, .noStoreFound)
        let message = try XCTUnwrap(StoreRecovery.pendingMessage(in: defaults))
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
    }

    // MARK: - Which errors another strategy might survive

    /// The error every upgrade past a model change raises is one to carry on from.
    func testTheOrdinaryUpgradeIsAMigrationError() {
        XCTAssertTrue(CloudKitConfiguration.isMigrationError(
            SwiftDataTestError(description: "SwiftDataError(_error: SwiftData.SwiftDataError._Error.unknownDataStoreSchema)")
        ))
        XCTAssertTrue(CloudKitConfiguration.isMigrationError(
            SwiftDataTestError(description: "Cannot use staged migration with an unknown model version")
        ))
    }

    /// An error that is not about the schema is the caller's to raise: setting a
    /// healthy store aside for a passing fault is the #285 harm by another door.
    func testAnErrorThatIsNotAboutTheSchemaIsNotAMigrationError() {
        XCTAssertFalse(CloudKitConfiguration.isMigrationError(
            NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        ))
        XCTAssertFalse(CloudKitConfiguration.isMigrationError(
            SwiftDataTestError(description: "The file could not be opened because there is no such file.")
        ))
    }
}

/// An error whose description is what the test is about.
///
/// `SwiftDataError` cannot be built outside SwiftData, and `isMigrationError`
/// reads an error as text, so this stands in for one.
private struct SwiftDataTestError: Error, CustomStringConvertible {
    let description: String
}
