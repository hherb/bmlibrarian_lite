// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// A key store whose saves can be made to fail, standing in for the Keychain,
/// which a test has no entitlement to write.
private final class StubSecretStore: SecretStore {
    /// What is stored, by account.
    var stored: [String: String] = [:]

    /// Whether every save fails, leaving what was stored.
    var failsSaves = false

    func load(key: String) -> String? { stored[key] }

    func save(key: String, value: String) -> Bool {
        guard !failsSaves else { return false }
        stored[key] = value.isEmpty ? nil : value
        return true
    }

    func delete(key: String) -> Bool {
        stored[key] = nil
        return true
    }
}

/// An API key reads as saved only once it is stored: a failed save keeps the
/// key in use, and the settings say it was not saved.
final class APIKeySaveTests: XCTestCase {
    private var store = StubSecretStore()
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        store = StubSecretStore()
        settings = AppSettings(secretStore: store)
    }

    func testASavedCOREKeyIsTheKeyInUse() {
        XCTAssertTrue(settings.saveCOREAPIKey("core-key"))
        XCTAssertEqual(settings.coreAPIKey, "core-key")
        XCTAssertEqual(Array(store.stored.values), ["core-key"])
    }

    func testAFailedCORESaveKeepsTheKeyInUse() {
        XCTAssertTrue(settings.saveCOREAPIKey("old-key"))
        store.failsSaves = true

        XCTAssertFalse(settings.saveCOREAPIKey("new-key"))

        XCTAssertEqual(settings.coreAPIKey, "old-key", "the cache follows the store, not the attempt")
        XCTAssertEqual(Array(store.stored.values), ["old-key"])
    }

    func testAFailedCORESaveBeforeAnyReadReadsTheStoredKey() {
        XCTAssertTrue(AppSettings(secretStore: store).saveCOREAPIKey("old-key"))
        store.failsSaves = true

        XCTAssertFalse(settings.saveCOREAPIKey("new-key"))

        XCTAssertEqual(settings.coreAPIKey, "old-key")
    }

    func testAFailedNCBISaveKeepsTheKeyInUse() {
        XCTAssertTrue(settings.saveNCBIAPIKey("old-key"))
        store.failsSaves = true

        XCTAssertFalse(settings.saveNCBIAPIKey("new-key"))

        XCTAssertEqual(settings.ncbiAPIKey, "old-key")
    }

    /// The control: a save that succeeds replaces the key, an empty one clears it.
    func testASavedNCBIKeyReplacesAndAnEmptyOneClears() {
        XCTAssertTrue(settings.saveNCBIAPIKey("old-key"))
        XCTAssertTrue(settings.saveNCBIAPIKey("new-key"))
        XCTAssertEqual(settings.ncbiAPIKey, "new-key")
        XCTAssertTrue(settings.saveNCBIAPIKey(""))
        XCTAssertEqual(settings.ncbiAPIKey, "")
        XCTAssertTrue(store.stored.isEmpty)
    }

    func testASavedElsevierKeyAndTokenAreTheOnesInUse() {
        XCTAssertTrue(settings.saveElsevierAPIKey("els-key"))
        XCTAssertTrue(settings.saveElsevierInstToken("els-token"))
        XCTAssertEqual(settings.elsevierAPIKey, "els-key")
        XCTAssertEqual(settings.elsevierInstToken, "els-token")
        XCTAssertEqual(store.stored["elsevier_api_key"], "els-key")
        XCTAssertEqual(store.stored["elsevier_insttoken"], "els-token")
    }

    func testAFailedElsevierKeySaveKeepsTheKeyInUse() {
        XCTAssertTrue(settings.saveElsevierAPIKey("old-key"))
        store.failsSaves = true

        XCTAssertFalse(settings.saveElsevierAPIKey("new-key"))

        XCTAssertEqual(settings.elsevierAPIKey, "old-key", "the cache follows the store, not the attempt")
        XCTAssertEqual(AppSettings(secretStore: store).elsevierAPIKey, "old-key")
    }

    func testAFailedElsevierTokenSaveKeepsTheTokenInUse() {
        XCTAssertTrue(settings.saveElsevierInstToken("old-token"))
        store.failsSaves = true

        XCTAssertFalse(settings.saveElsevierInstToken("new-token"))

        XCTAssertEqual(settings.elsevierInstToken, "old-token", "the cache follows the store, not the attempt")
        XCTAssertEqual(AppSettings(secretStore: store).elsevierInstToken, "old-token")
    }

    func testResetClearsTheElsevierKeyAndToken() {
        XCTAssertTrue(settings.saveElsevierAPIKey("els-key"))
        XCTAssertTrue(settings.saveElsevierInstToken("els-token"))

        settings.resetToDefaults()

        XCTAssertEqual(settings.elsevierAPIKey, "")
        XCTAssertEqual(settings.elsevierInstToken, "")
        XCTAssertNil(store.stored["elsevier_api_key"])
        XCTAssertNil(store.stored["elsevier_insttoken"])
    }

    func testTheServiceAsksElsevierWithTheSavedKey() {
        XCTAssertFalse(BMLFullTextService.create(from: settings).asksElsevier, "no key, no request")
        XCTAssertTrue(settings.saveElsevierInstToken("els-token"))
        XCTAssertFalse(BMLFullTextService.create(from: settings).asksElsevier, "a token alone asks nothing")
        XCTAssertTrue(settings.saveElsevierAPIKey("els-key"))
        XCTAssertTrue(BMLFullTextService.create(from: settings).asksElsevier)
    }

    func testATokenFailureNamesTheToken() {
        let message = AppSettings.tokenSaveFailureMessage(tokenName: "Elsevier institutional")
        XCTAssertTrue(message.hasPrefix("The Elsevier institutional token could not be saved"))
        XCTAssertTrue(message.contains("the token in use is unchanged"))
    }

    func testTheFailureSaysNotSavedAndNamesTheKey() {
        let message = AppSettings.keySaveFailureMessage(keyName: "CORE")
        XCTAssertTrue(message.hasPrefix("The CORE API key could not be saved"))
        XCTAssertTrue(message.contains("the key in use is unchanged"))
    }
}
