import XCTest
import Carbon
@testable import VoiceMacro

final class InputTests: XCTestCase {
    func testIsolatedFnStillTogglesWhenCapsLockIsOn() {
        var state = SoloKeyGesture()
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function, .capsLock]))
        XCTAssertTrue(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.capsLock]))
    }

    func testCapsLockPressedDuringFnStillDisqualifiesTheChord() {
        var state = SoloKeyGesture()
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function]))
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_CapsLock), modifiers: [.function, .capsLock]))
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.capsLock]))
    }

    func testIsolatedFnTogglesOnlyOnceOnRelease() {
        var state = SoloKeyGesture()
        XCTAssertFalse(state.keyChanged(isDown: true, otherModifiersDown: false))
        XCTAssertFalse(state.keyChanged(isDown: true, otherModifiersDown: false))
        XCTAssertTrue(state.keyChanged(isDown: false, otherModifiersDown: false))
        XCTAssertFalse(state.keyChanged(isDown: false, otherModifiersDown: false))
    }

    func testFnChordDoesNotToggleAfterOtherKeyReleased() {
        var state = SoloKeyGesture()
        _ = state.keyChanged(isDown: true, otherModifiersDown: false)
        state.keyDown()
        XCTAssertFalse(state.keyChanged(isDown: false, otherModifiersDown: false))
        _ = state.keyChanged(isDown: true, otherModifiersDown: false)
        XCTAssertTrue(state.keyChanged(isDown: false, otherModifiersDown: false))
    }

    func testAlreadyHeldKeyDisqualifiesFn() {
        var state = SoloKeyGesture()
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function], otherKeysDown: { true }))
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: []))
    }

    func testKeyWhoseReleaseWasNeverSeenDoesNotDisableFn() {
        var state = SoloKeyGesture()
        // ⌘V typed before a password field hid the key release from background apps.
        state.keyDown()
        for _ in 0..<3 {
            XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function], otherKeysDown: { false }))
            XCTAssertTrue(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: []))
        }
    }

    func testHeldKeysAreQueriedOnlyWhenFnGoesDown() {
        var state = SoloKeyGesture()
        var queries = 0
        let query = { () -> Bool in queries += 1; return false }
        _ = state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function], otherKeysDown: query)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function], otherKeysDown: query)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [], otherKeysDown: query)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Shift), modifiers: [.shift], otherKeysDown: query)
        XCTAssertEqual(queries, 1)
    }

    func testRightOptionAloneToggles() {
        var state = SoloKeyGesture(key: .rightOption)
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: right))
        XCTAssertTrue(state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: []))
    }

    func testLeftOptionDoesNotToggleRightOption() {
        var state = SoloKeyGesture(key: .rightOption)
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Option), modifiers: left))
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Option), modifiers: []))
    }

    func testRightOptionChordsDoNotToggle() {
        var state = SoloKeyGesture(key: .rightOption)
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x60)
        // ⌥-letter types a special character.
        _ = state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: right)
        state.keyDown()
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: []))
        // Both Options together.
        _ = state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: right)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Option), modifiers: both)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Option), modifiers: right)
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_RightOption), modifiers: []))
        // Fn is ignored entirely when the trigger is right Option.
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: [.function]))
        XCTAssertFalse(state.flagsChanged(keyCode: UInt16(kVK_Function), modifiers: []))
    }

    func testInputSourceConflictNeedsTwoSwitchesAndClearsAfterThreeQuietPresses() {
        var detector = InputSourceConflictDetector()
        detector.inputSourceChanged(at: 10.1)
        XCTAssertFalse(detector.evaluatePress(at: 10))
        XCTAssertFalse(detector.conflict)
        detector.inputSourceChanged(at: 20.05)
        XCTAssertTrue(detector.evaluatePress(at: 20))
        XCTAssertTrue(detector.conflict)
        // A layout switch long before the press is not caused by it.
        XCTAssertFalse(detector.evaluatePress(at: 30))
        XCTAssertFalse(detector.evaluatePress(at: 40))
        XCTAssertTrue(detector.evaluatePress(at: 50))
        XCTAssertFalse(detector.conflict)
    }

    func testOneUnrelatedSwitchResetsTheConflictStreak() {
        var detector = InputSourceConflictDetector()
        detector.inputSourceChanged(at: 10.1)
        XCTAssertFalse(detector.evaluatePress(at: 10))
        XCTAssertFalse(detector.evaluatePress(at: 20))
        detector.inputSourceChanged(at: 30.1)
        XCTAssertFalse(detector.evaluatePress(at: 30))
        XCTAssertFalse(detector.conflict)
    }

    func testShortcutAutoRepeatIsIgnoredButLostReleaseRecovers() {
        var filter = ShortcutPressFilter()
        XCTAssertTrue(filter.pressed(at: 10))
        XCTAssertFalse(filter.pressed(at: 10.5), "auto-repeat while held")
        XCTAssertFalse(filter.pressed(at: 10.55))
        filter.released()
        XCTAssertTrue(filter.pressed(at: 10.8))
        // The release of this press is never delivered; the next real press still toggles.
        XCTAssertTrue(filter.pressed(at: 20))
    }

    func testModifierDuringFnDisqualifiesEvenAfterRelease() {
        var state = SoloKeyGesture()
        _ = state.keyChanged(isDown: true, otherModifiersDown: false)
        state.otherModifiersChanged(areDown: true)
        state.otherModifiersChanged(areDown: false)
        XCTAssertFalse(state.keyChanged(isDown: false, otherModifiersDown: false))
    }

    func testModifierAlreadyDownDisqualifiesFn() {
        var state = SoloKeyGesture()
        _ = state.keyChanged(isDown: true, otherModifiersDown: true)
        XCTAssertFalse(state.keyChanged(isDown: false, otherModifiersDown: false))
    }

    func testShortcutValidationProtectsPlainTyping() {
        XCTAssertNoThrow(try ShortcutBinding.defaultBinding.validate())
        XCTAssertThrowsError(try ShortcutBinding(keyCode: 0, modifiers: 0).validate())
        XCTAssertThrowsError(try ShortcutBinding(keyCode: 0, modifiers: UInt32(shiftKey)).validate())
        XCTAssertThrowsError(try ShortcutBinding(keyCode: 63, modifiers: UInt32(cmdKey)).validate())
        XCTAssertThrowsError(try ShortcutBinding(keyCode: 500, modifiers: UInt32(cmdKey)).validate())
        XCTAssertThrowsError(try ShortcutBinding(keyCode: 0, modifiers: UInt32(cmdKey) | (1 << 30)).validate())
        XCTAssertNoThrow(try ShortcutBinding(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey)).validate())
    }

    func testShortcutCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(ShortcutBinding.defaultBinding)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutBinding.self, from: data), .defaultBinding)
        XCTAssertEqual(ShortcutBinding.defaultBinding.displayName, "⌃⌥Space")
    }
}
