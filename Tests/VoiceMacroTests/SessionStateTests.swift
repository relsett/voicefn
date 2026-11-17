import XCTest
@testable import VoiceMacro

final class SessionStateTests: XCTestCase {
    func testOneRecordingAtATime() {
        var state = SessionState()
        let id = state.begin()!
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.transition(to: .recording, for: id))
        XCTAssertNil(state.begin())
        XCTAssertFalse(state.transition(to: .delivered, for: id))
    }

    func testLateResponseAfterCancelCannotDeliverIntoNewSession() {
        var state = SessionState()
        let old = state.begin()!
        state.transition(to: .recording, for: old)
        state.transition(to: .stopping, for: old)
        state.transition(to: .transcribing, for: old)
        state.reset()
        let current = state.begin()!
        XCTAssertFalse(state.transition(to: .delivered, for: old))
        XCTAssertFalse(state.accepts(old))
        XCTAssertTrue(state.accepts(current))
        XCTAssertEqual(state.phase, .starting)
    }

    func testInterruptionRequiresExplicitRetry() {
        var state = SessionState()
        let id = state.begin()!
        state.transition(to: .recording, for: id)
        state.transition(to: .stopping, for: id)
        XCTAssertTrue(state.transition(to: .interrupted, for: id))
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.transition(to: .transcribing, for: id))
        XCTAssertTrue(state.transition(to: .delivered, for: id))
        XCTAssertFalse(state.transition(to: .delivered, for: id))
    }

    func testLockDuringConversionHoldsAudioAndDoesNotAffectNewSession() {
        var state = SessionState()
        let old = state.begin()!
        state.transition(to: .recording, for: old)
        state.transition(to: .stopping, for: old)
        state.holdStoppedRecording(reason: "Locked", for: old)
        XCTAssertEqual(state.stopHoldReason, "Locked")
        state.reset()
        let current = state.begin()!
        state.transition(to: .recording, for: current)
        state.holdStoppedRecording(reason: "Late callback", for: old)
        XCTAssertNil(state.stopHoldReason)
    }
}
