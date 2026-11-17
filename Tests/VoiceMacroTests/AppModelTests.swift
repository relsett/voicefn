import Foundation
import XCTest
@testable import VoiceMacro

@MainActor
final class AppModelTests: XCTestCase {
    func testSleepDuringStopConversionHoldsFileWithoutSending() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.effects.suspendStop = true
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.stopContinuation != nil }
        XCTAssertEqual(fixture.model.phase, .stopping)

        fixture.model.interrupt("Sleep during conversion")
        fixture.effects.finishStop()
        try await eventually { fixture.model.phase == .interrupted }

        XCTAssertTrue(fixture.model.canRetry)
        XCTAssertTrue(fixture.model.hasSavedRecording)
        XCTAssertEqual(fixture.model.message, "Sleep during conversion")
        XCTAssertTrue(fixture.effects.requests.isEmpty)
        XCTAssertTrue(fixture.effects.delivered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.effects.recordings.last).path))
    }

    func testDoubleRetryOnlyStartsOneRequestAndCancelReachesThatRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.interrupt("Hold for explicit send")
        try await eventually { fixture.model.canRetry }

        // Both calls happen before the main actor can execute the spawned network task.
        fixture.model.retry()
        fixture.model.retry()
        XCTAssertEqual(fixture.model.phase, .transcribing)
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.model.cancel()
        try await eventually { fixture.effects.cancellations == [0] }
        fixture.effects.finishRequest(0, with: .success("Must not reach clipboard"))
        try await eventually { fixture.effects.returnedRequests == [0] }
        await settle()

        XCTAssertEqual(fixture.effects.requests.count, 1)
        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertTrue(fixture.model.lastTranscript.isEmpty)
        XCTAssertTrue(fixture.effects.delivered.isEmpty)
        XCTAssertFalse(fixture.model.hasSavedRecording)
    }

    func testRetryUsesCorrectedModelAndModeWithoutRerecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.settings.model = "broken/model"
        fixture.model.settings.mode = .audioChat
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .failure(OpenRouterError.httpStatus(404)))
        try await eventually { fixture.model.phase == .failed }

        fixture.model.settings.model = "fixed/transcribe"
        fixture.model.settings.mode = .speechToText
        fixture.model.retry()
        try await eventually { fixture.effects.requests.count == 2 }

        XCTAssertEqual(fixture.effects.requests[0].model, "broken/model")
        XCTAssertEqual(fixture.effects.requests[1].model, "fixed/transcribe")
        XCTAssertEqual(fixture.effects.requests[1].mode, .speechToText)
        XCTAssertEqual(fixture.effects.requests[0].fileURL, fixture.effects.requests[1].fileURL)
        XCTAssertEqual(fixture.effects.startCount, 1)
        fixture.effects.finishRequest(1, with: .success(" Fixed transcript. "))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(fixture.effects.delivered, ["Fixed transcript."])
        XCTAssertEqual(fixture.model.lastTranscript, "Fixed transcript.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.effects.requests[1].fileURL.path))
    }

    func testCanceledLateResponseCannotDeliverOverNewSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.model.cancel()
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 2 }

        // Simulate a transport that still completes after cancellation.
        fixture.effects.finishRequest(0, with: .success("Old canceled transcript"))
        try await eventually { fixture.effects.returnedRequests.contains(0) }
        await settle()
        XCTAssertEqual(fixture.model.phase, .transcribing)
        XCTAssertTrue(fixture.effects.delivered.isEmpty)
        XCTAssertTrue(fixture.model.lastTranscript.isEmpty)

        fixture.effects.finishRequest(1, with: .success("Current transcript"))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(fixture.effects.delivered, ["Current transcript"])
        XCTAssertEqual(fixture.model.lastTranscript, "Current transcript")
    }

    func testMissingAuthorizationRetainsAudioAndRecoversAfterConnecting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.effects.authorized = false
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .failed }
        XCTAssertTrue(fixture.model.canRetry)
        XCTAssertTrue(fixture.effects.requests.isEmpty)

        fixture.effects.authorized = true
        fixture.model.retry()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .success("Authorized transcript"))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(fixture.effects.delivered, ["Authorized transcript"])
    }

    func testHotkeyAfterFailureStartsANewRecordingAndKeepsTheOldOne() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.interrupt("Limit reached")
        try await eventually { fixture.model.phase == .interrupted }
        let held = try XCTUnwrap(journal.entries.first)

        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        XCTAssertEqual(fixture.effects.startCount, 2, "The key starts a new recording")
        XCTAssertTrue(fixture.effects.requests.isEmpty, "The held recording is not resent")
        XCTAssertEqual(journal.entry(held.id)?.status, .failed)
        XCTAssertNotNil(journal.audioURL(held.id), "The held recording stays in history")
    }

    func testHotkeyAfterFailedStartBeginsANewRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.effects.startFailure = AudioRecordingError.permissionDenied
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .failed }
        XCTAssertFalse(fixture.model.canRetry)

        fixture.effects.startFailure = nil
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        XCTAssertEqual(fixture.effects.startCount, 2)
    }

    func testScreenLockDuringTranscriptionKeepsRequestButSkipsPaste() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }

        fixture.model.screenLocked()
        XCTAssertEqual(fixture.model.phase, .transcribing)
        XCTAssertTrue(fixture.effects.cancellations.isEmpty)
        fixture.effects.finishRequest(0, with: .success("Finished while locked"))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(fixture.effects.delivered, ["Finished while locked"])
        XCTAssertEqual(fixture.effects.autoPasteRequests, [false])
    }

    func testScreenLockWhileRecordingHoldsTheRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.screenLocked()
        try await eventually { fixture.model.phase == .interrupted }
        XCTAssertTrue(fixture.model.canRetry)
        XCTAssertTrue(fixture.effects.requests.isEmpty)
    }

    func testEachAttemptIsLoggedWithoutTranscriptText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.settings.model = "broken/model"
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .failure(OpenRouterError.httpStatus(504)))
        try await eventually { fixture.model.phase == .failed }

        fixture.model.settings.model = "fixed/transcribe"
        fixture.model.retry()
        try await eventually { fixture.effects.requests.count == 2 }
        fixture.effects.finishRequest(1, with: .success("Secret dictated words"))
        try await eventually { fixture.model.phase == .delivered }

        let lines = try fixture.logLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["attempt"] as? Int, 1)
        XCTAssertEqual(lines[0]["result"] as? String, "failed")
        XCTAssertEqual(lines[0]["error"] as? String, "http 504")
        XCTAssertEqual(lines[0]["model"] as? String, "broken/model")
        XCTAssertNotNil(lines[0]["recordingSeconds"])
        XCTAssertNotNil(lines[0]["stopMs"])
        XCTAssertEqual(lines[1]["attempt"] as? Int, 2)
        XCTAssertEqual(lines[1]["session"] as? String, lines[0]["session"] as? String)
        XCTAssertEqual(lines[1]["result"] as? String, "delivered")
        XCTAssertEqual(lines[1]["outcome"] as? String, "copied")
        XCTAssertEqual(lines[1]["transcriptChars"] as? Int, 21)
        XCTAssertNil(lines[1]["stopMs"], "Stop timing belongs to the first attempt only")
        XCTAssertNotNil(lines[1]["totalMs"])
        let raw = try String(contentsOf: fixture.log.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("Secret"))
        XCTAssertFalse(raw.contains("test-key"))
    }

    func testCancelDuringTranscriptionIsLogged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.model.cancel()
        try await eventually { fixture.effects.cancellations == [0] }
        fixture.effects.finishRequest(0, with: .failure(CancellationError()))
        try await eventually { fixture.effects.returnedRequests == [0] }
        await settle()

        let lines = try fixture.logLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["result"] as? String, "cancelled")
    }

    func testLogRotatesWhenFull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMacro-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DictationLog(directory: directory)
        let record = DictationRecord(time: Date(), session: "s", attempt: 1, model: "m", mode: "audioChat",
                                     autoPaste: false, result: "delivered")
        log.append(record)
        log.flush()
        let handle = try FileHandle(forWritingTo: log.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: DictationLog.maximumBytes))
        try handle.close()
        log.append(record)
        log.flush()

        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(current.split(separator: "\n").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dictations.1.jsonl").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testFailedRecordingSurvivesCancelAndNextRecordingAndCanBeTranscribedAgain() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .failure(OpenRouterError.httpStatus(500)))
        try await eventually { fixture.model.phase == .failed }

        let failed = try XCTUnwrap(journal.entries.first)
        XCTAssertEqual(failed.status, .failed)
        let audio = try XCTUnwrap(journal.audioURL(failed.id))
        XCTAssertEqual(fixture.effects.requests[0].fileURL, audio, "The request reads the journal's copy")

        // Dismissing the failure and dictating something else must not cost the old audio.
        fixture.model.cancel()
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 2 }
        fixture.effects.finishRequest(1, with: .success("Second dictation"))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(journal.entries.map(\.status), [.delivered, .failed])
        XCTAssertEqual(journal.entries.first?.text, "Second dictation")
        XCTAssertNil(journal.entries.first?.audioFile, "Delivered entries keep no audio")

        fixture.model.retranscribe(failed.id)
        try await eventually { fixture.effects.requests.count == 3 }
        XCTAssertEqual(fixture.effects.requests[2].fileURL, audio)
        fixture.effects.finishRequest(2, with: .success(" Recovered text "))
        try await eventually { journal.entry(failed.id)?.status == .delivered }
        XCTAssertEqual(journal.entry(failed.id)?.text, "Recovered text")
        XCTAssertEqual(fixture.effects.delivered.last, "Recovered text", "The recovered text is copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(journal.transcribing.isEmpty)
    }

    func testJournalCannotSendTheRecordingTwiceWhileItRetries() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .failure(OpenRouterError.httpStatus(500)))
        try await eventually { fixture.model.phase == .failed }
        let id = try XCTUnwrap(journal.entries.first?.id)
        fixture.model.retry()
        try await eventually { fixture.effects.requests.count == 2 }
        fixture.model.retranscribe(id)
        await settle()
        XCTAssertEqual(fixture.effects.requests.count, 2, "History must not start a parallel request")
    }

    func testStopBeforeAnyAudioEndsQuietly() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        fixture.effects.stopFailure = AudioRecordingError.noRecording
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .idle }
        XCTAssertTrue(fixture.effects.requests.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.journal).entries.isEmpty)
    }

    func testPastedTextKeepsNoControlCharacters() {
        XCTAssertEqual(TextDelivery.sanitized(" ls\u{1B}[201~\r\nrm -rf ~\u{0007} "), "ls[201~\nrm -rf ~")
        XCTAssertEqual(TextDelivery.sanitized("Привет,\tмир\nвторая строка"), "Привет,\tмир\nвторая строка")
        XCTAssertEqual(TextDelivery.sanitized("abc\u{202E}def\u{0085}"), "abcdef")
        XCTAssertEqual(TextDelivery.sanitized("می\u{200C}خواهم 👩\u{200D}💻"), "می\u{200C}خواهم 👩\u{200D}💻")
    }

    func testCancelWhileSendingKeepsRecordingInJournal() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        XCTAssertEqual(journal.entries.first?.status, .pending)

        fixture.model.cancel()
        let entry = try XCTUnwrap(journal.entries.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNotNil(journal.audioURL(entry.id))
    }

    func testRetryOfHeldRecordingCompletesItsJournalEntry() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.interrupt("Held")
        try await eventually { fixture.model.canRetry }
        let id = try XCTUnwrap(journal.entries.first?.id)
        XCTAssertEqual(journal.entry(id)?.detail, "Held")

        // From the journal, the held recording goes through the session's own retry.
        fixture.model.retranscribe(id)
        XCTAssertEqual(fixture.model.phase, .transcribing)
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .success("Held text"))
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(journal.entries.count, 1)
        XCTAssertEqual(journal.entry(id)?.text, "Held text")
        XCTAssertNil(journal.audioURL(id))
    }

    func testDeletingTheHeldEntryReleasesTheSession() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.interrupt("Held")
        try await eventually { fixture.model.canRetry }
        let id = try XCTUnwrap(journal.entries.first?.id)
        let audio = try XCTUnwrap(journal.audioURL(id))

        fixture.model.deleteJournalEntry(id)
        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertFalse(fixture.model.canRetry)
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testSecondPressWhileStartingStopsOnceLive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.effects.suspendStart = true
        fixture.model.toggle()
        try await eventually { fixture.effects.startContinuation != nil }
        XCTAssertEqual(fixture.model.phase, .starting)
        fixture.model.toggle()
        fixture.effects.startContinuation?.resume()
        try await eventually { fixture.effects.requests.count == 1 }
    }

    func testTapIsDroppedWithoutRequestOrHistory() async throws {
        let fixture = try Fixture(journaling: true, speechGate: .standard)
        defer { fixture.cleanUp() }
        fixture.effects.voiced = 0.02
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .idle }
        await settle()
        XCTAssertTrue(fixture.effects.requests.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.journal).entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.effects.recordings.last).path))
    }

    func testSilenceIsDroppedAndSpeechIsSent() async throws {
        let fixture = try Fixture(journaling: true, speechGate: .standard)
        defer { fixture.cleanUp() }
        fixture.effects.voiced = 0
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .idle }
        await settle()
        XCTAssertTrue(fixture.effects.requests.isEmpty)

        // A quick word: a short recording, but most of it is sound.
        fixture.effects.voiced = 0.25
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
    }

    func testEmptyTranscriptEndsQuietlyAndKeepsTheAudio() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        let journal = try XCTUnwrap(fixture.journal)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.effects.requests.count == 1 }
        fixture.effects.finishRequest(0, with: .success("  "))
        try await eventually { fixture.model.phase == .idle }
        XCTAssertFalse(fixture.model.canRetry)
        XCTAssertTrue(fixture.effects.delivered.isEmpty)
        let entry = try XCTUnwrap(journal.entries.first)
        XCTAssertEqual(entry.status, .failed)
        XCTAssertNotNil(journal.audioURL(entry.id))
    }

    func testOnDeviceEngineNeedsNoKeyAndRecordsTheModel() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        fixture.model.settings.engine = .local
        fixture.effects.authorized = false
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .delivered }
        XCTAssertEqual(fixture.effects.localTranscripts.count, 1)
        XCTAssertTrue(fixture.effects.requests.isEmpty, "Nothing goes to OpenRouter")
        XCTAssertEqual(fixture.effects.delivered, ["Local transcript"])
        XCTAssertEqual(fixture.journal?.entries.first?.model, LocalTranscriber.label)
    }

    func testOnDeviceModelNotReadyKeepsTheRecording() async throws {
        let fixture = try Fixture(journaling: true)
        defer { fixture.cleanUp() }
        fixture.model.settings.engine = .local
        fixture.effects.localResult = .failure(LocalTranscriberError.notReady)
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .recording }
        fixture.model.toggle()
        try await eventually { fixture.model.phase == .failed }
        XCTAssertTrue(fixture.model.canRetry)
        XCTAssertNotNil(fixture.journal?.audioURL(try XCTUnwrap(fixture.journal?.entries.first?.id)))
    }

    func testOnDeviceEngineNeverAsksToConnect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.settings.engine = .local
        fixture.effects.authorized = false
        XCTAssertFalse(fixture.model.needsSetup)
    }

    func testShortAudioIsPaddedForWhisper() {
        XCTAssertEqual(LocalTranscriber.padded([Float](repeating: 0.1, count: 8_000)).count, 32_000)
        XCTAssertEqual(LocalTranscriber.padded([Float](repeating: 0.1, count: 8_000)).prefix(8_000).allSatisfy { $0 == 0.1 }, true)
        XCTAssertEqual(LocalTranscriber.padded([Float](repeating: 0, count: 48_000)).count, 48_000)
    }

    func testLocalTranscriberDropsHallucinationsAndPicksLanguages() {
        XCTAssertEqual(LocalTranscriber.clean(" Продолжение следует... "), "")
        XCTAssertEqual(LocalTranscriber.clean("Thank you for watching!"), "")
        XCTAssertEqual(LocalTranscriber.clean("Закоммить в GitLab."), "Закоммить в GitLab.")
        XCTAssertEqual(LocalTranscriber.languages(preferred: ["ru-RU", "en-US", "ru"]), ["ru", "en"])
        XCTAssertEqual(LocalTranscriber.languages(preferred: []), ["en"])
        XCTAssertEqual(AppSettings.modelLabel(LocalTranscriber.label), LocalTranscriber.label)
    }

    func testSpeechGate() {
        let gate = SpeechGate.standard
        XCTAssertEqual(gate.reject(voicedSeconds: 0), "no_speech")
        XCTAssertEqual(gate.reject(voicedSeconds: 0.04), "no_speech", "a key click spanning two windows")
        XCTAssertNil(gate.reject(voicedSeconds: 0.08), "a quick word, as recorded in real use")
        XCTAssertNil(gate.reject(voicedSeconds: nil))
        XCTAssertNil(SpeechGate.off.reject(voicedSeconds: 0))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Coordinator did not reach expected state", file: file, line: line)
        throw TestFailure.timeout
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private enum TestFailure: Error { case timeout }
}

@MainActor
private final class Fixture {
    let suite = "VoiceMacroTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let effects: MockEffects
    let model: AppModel
    let log: DictationLog
    let journal: DictationJournal?

    init(journaling: Bool = false, speechGate: SpeechGate = .off) throws {
        defaults = UserDefaults(suiteName: suite)!
        effects = try MockEffects()
        log = DictationLog(directory: effects.directory.appendingPathComponent("Logs", isDirectory: true))
        journal = journaling ? DictationJournal(directory: effects.directory.appendingPathComponent("Journal", isDirectory: true)) : nil
        model = AppModel(systemIntegrationEnabled: false, defaults: defaults, operations: effects.operations,
                         dictationLog: log, journal: journal, speechGate: speechGate)
        // These tests drive the OpenRouter path; the on-device path has its own tests.
        model.settings.engine = .openRouter
    }

    func logLines() throws -> [[String: Any]] {
        log.flush()
        guard FileManager.default.fileExists(atPath: log.fileURL.path) else { return [] }
        return try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func cleanUp() {
        model.cancel()
        effects.finishOutstanding()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: effects.directory)
    }
}

@MainActor
private final class MockEffects {
    struct Request {
        let fileURL: URL
        let model: String
        let mode: TranscriptionMode
    }

    let directory: URL
    var startCount = 0
    var suspendStop = false
    var suspendStart = false
    var stopFailure: Error?
    var startContinuation: CheckedContinuation<Void, Never>?
    var authorized = true
    var startFailure: Error?
    var autoPasteRequests: [Bool] = []
    var voiced: Double?
    var localTranscripts: [URL] = []
    var localResult: Result<String, Error> = .success("Local transcript")
    var stopContinuation: CheckedContinuation<URL, Error>?
    var recordings: [URL] = []
    var requests: [Request] = []
    var delivered: [String] = []
    var cancellations: [Int] = []
    var returnedRequests: [Int] = []
    private var responses: [Int: CheckedContinuation<String, Error>] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMacro-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var operations: AppModelOperations {
        AppModelOperations(
            startRecording: { [self] _ in
                startCount += 1
                if let startFailure { throw startFailure }
                if suspendStart { await withCheckedContinuation { startContinuation = $0 } }
            },
            stopRecording: { [self] in
                if let stopFailure { throw stopFailure }
                let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
                try Data("fixture audio, never uploaded".utf8).write(to: url)
                recordings.append(url)
                if suspendStop { return try await withCheckedThrowingContinuation { stopContinuation = $0 } }
                return url
            },
            recordingVoicedSeconds: { [self] in voiced },
            cancelRecording: {},
            apiKey: { [self] in
                guard authorized else { throw OpenRouterError.notConnected }
                return "test-key-not-a-credential"
            },
            transcribe: { [self] url, _, model, mode in
                let index = requests.count
                requests.append(Request(fileURL: url, model: model, mode: mode))
                defer { returnedRequests.append(index) }
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { responses[index] = $0 }
                } onCancel: {
                    Task { @MainActor [self] in self.cancellations.append(index) }
                }
            },
            transcribeLocally: { [self] url in
                localTranscripts.append(url)
                return try localResult.get()
            },
            captureTarget: { nil },
            deliver: { [self] text, _, autoPaste in
                delivered.append(text)
                autoPasteRequests.append(autoPaste)
                return .copied
            },
            copy: { [self] text in delivered.append(text) }
        )
    }

    func finishStop() {
        guard let continuation = stopContinuation, let url = recordings.last else { return }
        stopContinuation = nil
        continuation.resume(returning: url)
    }

    func finishRequest(_ index: Int, with result: Result<String, Error>) {
        responses.removeValue(forKey: index)?.resume(with: result)
    }

    func finishOutstanding() {
        stopContinuation?.resume(throwing: CancellationError())
        stopContinuation = nil
        let pending = responses.values
        responses.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}
