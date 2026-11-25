import XCTest
@testable import VoiceMacro

final class RelaunchMarkerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "RelaunchMarkerTests")!
        defaults.removePersistentDomain(forName: "RelaunchMarkerTests")
    }

    func testFreshMarkerCountsOnce() {
        let now = Date()
        RelaunchMarker.set(defaults, now: now)
        XCTAssertTrue(RelaunchMarker.consume(defaults, now: now.addingTimeInterval(1)))
        XCTAssertFalse(RelaunchMarker.consume(defaults, now: now.addingTimeInterval(2)))
    }

    func testStaleMarkerIsIgnoredAndCleared() {
        let now = Date()
        RelaunchMarker.set(defaults, now: now)
        XCTAssertFalse(RelaunchMarker.consume(defaults, now: now.addingTimeInterval(60)))
        XCTAssertEqual(defaults.double(forKey: RelaunchMarker.key), 0)
    }

    func testNoMarkerMeansOrdinaryLaunch() {
        XCTAssertFalse(RelaunchMarker.consume(defaults))
    }
}
