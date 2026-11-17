import Combine
import Foundation

/// One dictation as the user sees it in the journal.
struct JournalEntry: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Recorded; transcription has not finished yet.
        case pending
        case delivered
        /// Not transcribed. The audio is kept so it can be transcribed again.
        case failed
    }

    let id: UUID
    let date: Date
    var appName: String?
    var appBundleID: String?
    var seconds: Double?
    var text: String?
    var status: Status
    /// Why a failed entry was not transcribed.
    var detail: String?
    /// File name inside the journal's audio directory. Failed and pending entries always keep
    /// audio; delivered ones keep it only when the user chose to keep recordings.
    var audioFile: String?
    /// The model that produced `text`.
    var model: String?
}

/// Every transcript and every failed recording, kept on this Mac until the user deletes it.
///
/// Entries live in `journal.json`; the audio of recordings that were not transcribed lives
/// next to it, so a failure never costs the user what they said. The directory is in
/// Application Support, not Caches: macOS may purge caches, and startup clears the
/// recorder's own folder.
@MainActor
final class DictationJournal: ObservableObject {
    /// Newest first.
    @Published private(set) var entries: [JournalEntry] = []
    /// Entries being transcribed again from the journal.
    @Published private(set) var transcribing: Set<UUID> = []

    let directory: URL
    private var audioDirectory: URL { directory.appendingPathComponent("Audio", isDirectory: true) }
    private var fileURL: URL { directory.appendingPathComponent("journal.json") }
    private let writer = DispatchQueue(label: "VoiceMacro.journal", qos: .utility)

    static let standard: DictationJournal? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        .map { DictationJournal(directory: $0.appendingPathComponent("VoiceMacro/Journal", isDirectory: true)) }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    func entry(_ id: UUID) -> JournalEntry? { entries.first { $0.id == id } }

    func audioURL(_ id: UUID) -> URL? {
        guard let name = entry(id)?.audioFile else { return nil }
        let url = audioDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Adds a pending entry and moves the recording into the journal, which owns it from then on.
    /// Returns the recording's new location, or the original one if it could not be moved.
    func begin(recording: URL, appName: String?, appBundleID: String?, seconds: Double?) -> (id: UUID, url: URL) {
        let id = UUID()
        var entry = JournalEntry(id: id, date: Date(), appName: appName, appBundleID: appBundleID,
                                 seconds: seconds, status: .pending)
        var url = recording
        do {
            try prepare(audioDirectory)
            let name = "\(id.uuidString).\(recording.pathExtension.isEmpty ? "audio" : recording.pathExtension)"
            let destination = audioDirectory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: recording, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            entry.audioFile = name
            url = destination
        } catch { /* The entry still records the attempt; the session keeps the original file. */ }
        entries.insert(entry, at: 0)
        save()
        return (id, url)
    }

    /// The transcript arrived: keep the text and drop the audio, unless the user keeps recordings
    /// (for example, to build a set of their own dictations for comparing models).
    func complete(_ id: UUID, text: String, model: String? = nil, keepAudio: Bool = false) {
        update(id) { entry in
            entry.text = text
            entry.model = model
            entry.status = .delivered
            entry.detail = nil
            if !keepAudio { removeAudio(of: &entry) }
        }
    }

    func fail(_ id: UUID, reason: String) {
        update(id) { entry in
            guard entry.status != .delivered else { return }
            entry.status = .failed
            entry.detail = reason
        }
    }

    func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeAudio(of: &entries[index])
        entries.remove(at: index)
        save()
    }

    func clear() {
        for index in entries.indices { removeAudio(of: &entries[index]) }
        entries.removeAll()
        save()
    }

    func setTranscribing(_ id: UUID, _ active: Bool) {
        if active { transcribing.insert(id) } else { transcribing.remove(id) }
    }

    func flush() { writer.sync {} }

    private func update(_ id: UUID, _ change: (inout JournalEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[index]
        change(&entries[index])
        if entries[index] != before { save() }
    }

    private func removeAudio(of entry: inout JournalEntry) {
        guard let name = entry.audioFile else { return }
        try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
        entry.audioFile = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var loaded = try? decoder.decode([JournalEntry].self, from: data) else {
            // An unreadable journal (say, written by a newer version) is set aside, never overwritten.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(at: fileURL, to: directory.appendingPathComponent("journal-unreadable-\(stamp).json"))
            return
        }
        var changed = false
        for index in loaded.indices {
            // The app quit before this recording was transcribed.
            if loaded[index].status == .pending {
                loaded[index].status = .failed
                loaded[index].detail = String(localized: "VoiceFn quit before transcribing.")
                changed = true
            }
            if let name = loaded[index].audioFile,
               !FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent(name).path) {
                loaded[index].audioFile = nil
                changed = true
            }
        }
        entries = loaded
        if changed { save() }
    }

    private func save() {
        let snapshot = entries
        let directory = directory
        let fileURL = fileURL
        writer.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try Self.prepareDirectory(directory)
                try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch { /* The in-memory journal stays usable; the next change retries the write. */ }
        }
    }

    private func prepare(_ directory: URL) throws { try Self.prepareDirectory(directory) }

    nonisolated private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
