import XCTest
@testable import VoiceMacro

@MainActor
final class CredentialCacheTests: XCTestCase {
    func testStartupChecksExistenceWithoutReadingSecret() {
        let store = FakeCredentialStore()
        let connection = OpenRouterConnection(keychain: store)
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(store.existenceChecks, 1)
        XCTAssertEqual(store.reads, 0)
    }

    func testMultipleDictationsReadKeychainOnlyOnce() throws {
        let store = FakeCredentialStore()
        let connection = OpenRouterConnection(keychain: store)
        XCTAssertEqual(try connection.apiKey(), "test-credential")
        XCTAssertEqual(try connection.apiKey(), "test-credential")
        XCTAssertEqual(try connection.apiKey(), "test-credential")
        XCTAssertEqual(store.reads, 1)
    }

    func testDisconnectInvalidatesCachedCredential() throws {
        let store = FakeCredentialStore()
        let connection = OpenRouterConnection(keychain: store)
        _ = try connection.apiKey()
        try connection.disconnect()
        XCTAssertFalse(connection.isConnected)
        XCTAssertThrowsError(try connection.apiKey())
        XCTAssertEqual(store.deletes, 1)
        XCTAssertEqual(store.reads, 2)
    }

    func testDeniedReadIsNotCachedAndCanBeRetried() throws {
        let store = FakeCredentialStore()
        store.denyRead = true
        let connection = OpenRouterConnection(keychain: store)
        XCTAssertThrowsError(try connection.apiKey())
        store.denyRead = false
        XCTAssertEqual(try connection.apiKey(), "test-credential")
        XCTAssertEqual(store.reads, 2)
    }

    func testPreviewDoesNotEvenInspectKeychain() {
        let store = FakeCredentialStore()
        let connection = OpenRouterConnection(loadStoredConnection: false, keychain: store)
        XCTAssertFalse(connection.isConnected)
        XCTAssertEqual(store.existenceChecks, 0)
        XCTAssertEqual(store.reads, 0)
    }
}

private final class FakeCredentialStore: OpenRouterCredentialStore {
    var key: String? = "test-credential"
    var existenceChecks = 0
    var reads = 0
    var deletes = 0
    var denyRead = false

    func containsKey() throws -> Bool { existenceChecks += 1; return key != nil }
    func read() throws -> String? {
        reads += 1
        if denyRead { throw KeychainStore.StoreError(status: -25293) }
        return key
    }
    func save(_ key: String) throws { self.key = key }
    func delete() throws { deletes += 1; key = nil }
}
