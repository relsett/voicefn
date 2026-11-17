import Foundation
import XCTest
@testable import VoiceMacro

@MainActor
final class DictationJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMacro-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recording() throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).flac")
        try Data("audio".utf8).write(to: url)
        return url
    }

    func testEntriesPersistNewestFirstWithPrivatePermissions() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let first = journal.begin(recording: try recording(), appName: "Notes", appBundleID: "com.apple.Notes", seconds: 2)
        journal.complete(first.id, text: "Первый")
        let second = journal.begin(recording: try recording(), appName: "Safari", appBundleID: nil, seconds: 1)
        journal.fail(second.id, reason: "Нет сети")
        journal.flush()

        let reloaded = DictationJournal(directory: journal.directory)
        XCTAssertEqual(reloaded.entries.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.entries.last?.text, "Первый")
        XCTAssertEqual(reloaded.entries.first?.detail, "Нет сети")
        XCTAssertNotNil(reloaded.audioURL(second.id))
        let file = journal.directory.appendingPathComponent("journal.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testUnreadableJournalIsSetAsideNotOverwritten() throws {
        let folder = directory.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"from\": \"a newer version\"}".utf8).write(to: folder.appendingPathComponent("journal.json"))

        let journal = DictationJournal(directory: folder)
        XCTAssertTrue(journal.entries.isEmpty)
        journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: 1)
        journal.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("journal-unreadable-") })
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside), encoding: .utf8), "{\"from\": \"a newer version\"}")
    }

    func testBeginMovesTheRecordingAndCompleteDeletesIt() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let source = try recording()
        let started = journal.begin(recording: source, appName: nil, appBundleID: nil, seconds: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(journal.audioURL(started.id), started.url)
        XCTAssertEqual(started.url.pathExtension, "flac")

        journal.complete(started.id, text: "Готово")
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.url.path))
        XCTAssertNil(journal.entry(started.id)?.audioFile)
    }

    func testCompleteKeepsAudioAndModelWhenAsked() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let started = journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: nil)
        journal.complete(started.id, text: "Сохранено", model: "google/gemini-3.5-flash-lite", keepAudio: true)
        journal.flush()

        let reloaded = DictationJournal(directory: journal.directory)
        XCTAssertEqual(reloaded.entry(started.id)?.status, .delivered)
        XCTAssertEqual(reloaded.entry(started.id)?.model, "google/gemini-3.5-flash-lite")
        XCTAssertEqual(reloaded.audioURL(started.id), started.url)
    }

    func testFailureNeverOverwritesADeliveredEntry() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let started = journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: nil)
        journal.complete(started.id, text: "Текст")
        journal.fail(started.id, reason: "Поздняя ошибка")
        XCTAssertEqual(journal.entry(started.id)?.status, .delivered)
        XCTAssertEqual(journal.entry(started.id)?.text, "Текст")
    }

    func testPendingEntryFromAPreviousLaunchBecomesFailedWithItsAudio() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let started = journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: nil)
        journal.flush()

        let reloaded = DictationJournal(directory: journal.directory)
        XCTAssertEqual(reloaded.entry(started.id)?.status, .failed)
        XCTAssertNotNil(reloaded.audioURL(started.id))
    }

    func testDeleteAndClearRemoveAudio() throws {
        let journal = DictationJournal(directory: directory.appendingPathComponent("Journal"))
        let one = journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: nil)
        let two = journal.begin(recording: try recording(), appName: nil, appBundleID: nil, seconds: nil)
        journal.delete(one.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.url.path))
        XCTAssertEqual(journal.entries.map(\.id), [two.id])
        journal.clear()
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: two.url.path))
        journal.flush()
        XCTAssertTrue(DictationJournal(directory: journal.directory).entries.isEmpty)
    }

    func testTriggerMigratesFromTheFnToggle() {
        let suite = "VoiceMacroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).trigger, .fn)
        defaults.set(false, forKey: "fnEnabled")
        XCTAssertEqual(AppSettings(defaults: defaults).trigger, .shortcut)
        AppSettings(defaults: defaults).trigger = .fn
        XCTAssertEqual(AppSettings(defaults: defaults).trigger, .fn)
        AppSettings(defaults: defaults).trigger = .rightOption
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.trigger, .rightOption)
        XCTAssertEqual(settings.trigger.soloKey, .rightOption)
        XCTAssertEqual(settings.keyCapLabel, "⌥")
    }

    func testRemovedCloudEngineFallsBackToThisMac() {
        let suite = "VoiceMacroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cloud", forKey: "engine")
        XCTAssertEqual(AppSettings(defaults: defaults).engine, .local)
    }
}
