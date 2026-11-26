import AppKit
import XCTest
@testable import VoiceMacro

@MainActor
final class OverlayControllerTests: XCTestCase {
    func testPersistentOffSpaceRecreatesNativePanelAndPreservesContent() async throws {
        var strandedWindow: Int?
        let fixture = Fixture(isOnActiveSpace: { $0.windowNumber != strandedWindow })
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        for _ in 0..<20 {
            if fixture.model.phase == .recording { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.model.phase, .recording)
        fixture.overlay.show()
        let oldPanel = try XCTUnwrap(fixture.overlay.panel)
        let content = oldPanel.contentView
        let wasActive = NSApp.isActive
        strandedWindow = oldPanel.windowNumber
        for _ in 0..<40 {
            if fixture.overlay.panel !== oldPanel { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let newPanel = try XCTUnwrap(fixture.overlay.panel)
        XCTAssertFalse(newPanel === oldPanel)
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertTrue(newPanel.contentView === content)
        XCTAssertTrue(newPanel.isVisible)
        XCTAssertEqual(newPanel.frame.size, oldPanel.frame.size)
        XCTAssertFalse(newPanel.isKeyWindow)
        if !wasActive { XCTAssertFalse(NSApp.isActive) }
        XCTAssertEqual(fixture.overlay.panelGeneration, 2)
        XCTAssertEqual(fixture.model.phase, .recording)
        XCTAssertGreaterThan(fixture.model.elapsed, 0)
    }

    func testNewDictationDoesNotReuseOldNativeWindow() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.overlay.show(preview: true)
        let previous = try XCTUnwrap(fixture.overlay.panel)
        fixture.overlay.hide()
        fixture.overlay.show(preview: true)
        XCTAssertFalse(fixture.overlay.panel === previous)
        XCTAssertFalse(previous.isVisible)
        XCTAssertTrue(try XCTUnwrap(fixture.overlay.panel).isVisible)
    }

    func testStartingDictationReplacesEvenAnAlreadyRequestedWindow() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.overlay.show(preview: true, previewPhase: .delivered)
        let previous = try XCTUnwrap(fixture.overlay.panel)
        fixture.model.toggle()
        XCTAssertEqual(fixture.model.phase, .starting)
        fixture.overlay.show()
        XCTAssertFalse(fixture.overlay.panel === previous)
        XCTAssertFalse(previous.isVisible)
    }

    func testRecreationRequiresPersistentFailureAndRespectsCooldown() {
        var recovery = OffSpaceRecovery()
        recovery.didReplace(at: 0)
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 0.5))
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 1))
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 1.5))
        XCTAssertTrue(recovery.shouldReplace(onActiveSpace: false, at: 2))
        recovery.didReplace(at: 2)
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 2.5))
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: true, at: 3))
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 4))
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 4.5))
        recovery.resetMisses()
        XCTAssertFalse(recovery.shouldReplace(onActiveSpace: false, at: 5))
    }

    func testUnexpectedOrderOutRecoversWithoutMakingPanelKey() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.overlay.show(preview: true)
        let panel = try XCTUnwrap(fixture.overlay.panel)
        panel.orderOut(nil)
        XCTAssertFalse(panel.isVisible)
        for _ in 0..<20 {
            if panel.isVisible { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(panel.isVisible)
        XCTAssertGreaterThan(fixture.overlay.recoveryCount, 0)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.canHide)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
    }

    func testExplicitHideDoesNotReappearOnSpaceChangeOrTimer() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.overlay.show(preview: true)
        fixture.overlay.hide()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(fixture.overlay.wantsVisible)
        XCTAssertFalse(try XCTUnwrap(fixture.overlay.panel).isVisible)
    }

    func testWakeDoesNotResumeWhileUserSessionRemainsInactive() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.overlay.show(preview: true)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(try XCTUnwrap(fixture.overlay.panel).isVisible)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try XCTUnwrap(fixture.overlay.panel).isVisible)
    }
}

@MainActor
private final class Fixture {
    let suite = "OverlayTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let overlay: OverlayController
    let model: AppModel

    init(isOnActiveSpace: @escaping @MainActor (StatusPanel) -> Bool = { $0.isOnActiveSpace }) {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suite)!
        let unexpected: () -> AppError = { .message("Unexpected side effect during overlay test") }
        let operations = AppModelOperations(
            startRecording: { _ in }, stopRecording: { throw unexpected() },
            cancelRecording: {}, apiKey: { throw unexpected() },
            transcribe: { _, _, _, _ in throw unexpected() }, captureTarget: { nil },
            deliver: { _, _, _, _ in XCTFail("Unexpected delivery"); return .copied }, copy: { _ in XCTFail("Unexpected copy") }
        )
        model = AppModel(systemIntegrationEnabled: false, defaults: defaults, operations: operations)
        overlay = OverlayController(model: model, isOnActiveSpace: isOnActiveSpace)
    }

    func cleanUp() {
        model.cancel()
        overlay.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}
