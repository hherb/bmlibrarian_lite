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
            setAsideUnreadableStore: { setAsideRan = true }
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
            setAsideUnreadableStore: { }
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
            setAsideUnreadableStore: { _ = StoreRecovery.setAsideStore(in: self.directory) }
        )

        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<FactCheckSession>()).count, 0)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("unreadable") }
        XCTAssertEqual(kept.count, 1, "The unreadable store must still be on disk")
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(kept[0])), as: UTF8.self),
            "not a database"
        )
    }
}
