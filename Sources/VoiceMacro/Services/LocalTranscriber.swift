import Combine
import Foundation
import WhisperKit

/// Speech recognition on this Mac with Whisper Large v3 Turbo through WhisperKit (Core ML).
///
/// The model (about 600 MB) is downloaded once into the app's container; the first load also
/// compiles it for the Neural Engine, which takes a minute or two and is cached afterwards.
@MainActor
final class LocalTranscriber: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        /// Downloaded; loading or compiling for this Mac.
        case preparing
        case ready
        case failed(String)
    }

    static let model = "large-v3-v20240930_626MB"
    /// How the journal and telemetry name this engine.
    static let label = "local/whisper-large-v3-turbo"

    @Published private(set) var state: State = .notDownloaded

    private let directory: URL
    private let defaults: UserDefaults
    private var pipe: WhisperKit?
    private var preparation: Task<Void, Never>?
    /// The transcription in flight. WhisperKit keeps per-call state on the shared pipeline, so a
    /// dictation and a History re-transcription must take turns instead of running together.
    private var running: Task<String, Error>?
    private static let folderKey = "localModelFolder"

    static let standard = LocalTranscriber(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMacro/Models", isDirectory: true))

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        if modelFolder != nil { state = .preparing }
    }

    var isReady: Bool { state == .ready }

    #if DEBUG
    /// App Store screenshots only.
    func previewReady() { state = .ready }
    #endif

    private var modelFolder: URL? {
        guard let path = defaults.string(forKey: Self.folderKey) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads the model if needed and loads it. Safe to call repeatedly.
    func prepare() {
        guard preparation == nil, pipe == nil else { return }
        // Set now, so a dictation waiting on the model never sees a stale failure.
        state = modelFolder == nil ? .downloading(0) : .preparing
        preparation = Task { [weak self] in
            await self?.runPreparation()
            self?.preparation = nil
        }
    }

    private func runPreparation() async {
        do {
            let folder: URL
            if let existing = modelFolder {
                folder = existing
            } else {
                state = .downloading(0)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                folder = try await WhisperKit.download(variant: Self.model, downloadBase: directory) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
                defaults.set(folder.path, forKey: Self.folderKey)
            }
            state = .preparing
            let config = WhisperKitConfig(model: Self.model, downloadBase: directory, modelFolder: folder.path,
                                          verbose: false, logLevel: .error, load: true, download: false)
            pipe = try await WhisperKit(config)
            state = .ready
        } catch is CancellationError {
            state = modelFolder == nil ? .notDownloaded : .preparing
        } catch {
            // A model that downloaded but won't load is likely damaged; the next attempt
            // downloads it again instead of failing on the same files forever.
            if let broken = modelFolder, state == .preparing {
                defaults.removeObject(forKey: Self.folderKey)
                try? FileManager.default.removeItem(at: broken)
            }
            state = .failed(error.localizedDescription)
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        let previous = running
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await self.transcribeNow(fileURL: fileURL)
        }
        running = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func transcribeNow(fileURL: URL) async throws -> String {
        // Right after launch the model is still loading: the recording waits for it instead of failing.
        if pipe == nil {
            prepare()
            for await state in $state.values {
                if case .downloading = state { continue }
                if state == .preparing { continue }
                break
            }
            try Task.checkCancellation()
        }
        guard let pipe else { throw LocalTranscriberError.notReady }
        // Decoding and resampling minutes of audio must not block the hotkey or the overlay.
        let path = fileURL.path
        let audio = try await Task.detached(priority: .userInitiated) {
            Self.padded(try AudioProcessor.loadAudioAsFloatArray(fromPath: path))
        }.value
        let languages = Self.languages()
        // One system language: always use it. Several: detect, but only among them; detection on
        // short clips can mistake Russian with English terms for English and then translate it.
        var results = try await pipe.transcribe(audioArray: audio,
                                                decodeOptions: Self.options(language: languages.count == 1 ? languages[0] : nil))
        if languages.count > 1, let detected = results.first?.language, !languages.contains(detected) {
            results = try await pipe.transcribe(audioArray: audio, decodeOptions: Self.options(language: languages[0]))
        }
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// WhisperKit leaves the last second of a clip undecoded to avoid hallucinating on a cut-off
    /// word, so a recording under a second came back empty. Trailing silence makes room for it.
    nonisolated static func padded(_ audio: [Float], minimumSeconds: Double = 2) -> [Float] {
        let minimum = Int(Double(WhisperKit.sampleRate) * minimumSeconds)
        guard audio.count < minimum else { return audio }
        return audio + [Float](repeating: 0, count: minimum - audio.count)
    }

    private static func options(language: String?) -> DecodingOptions {
        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0,
                                      usePrefillPrompt: true, detectLanguage: language == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        options.noSpeechThreshold = 0.6
        return options
    }

    /// The user's preferred languages as Whisper codes, most preferred first, without repeats.
    static func languages(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var seen: [String] = []
        for identifier in preferred {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                  !seen.contains(code) else { continue }
            seen.append(code)
        }
        return seen.isEmpty ? ["en"] : seen
    }

    /// Whisper invents these on silence or noise; they are never what was said.
    static let hallucinations: Set<String> = [
        "продолжение следует", "субтитры сделал dimatorzok", "субтитры создавал dimatorzok",
        "спасибо за просмотр", "редактор субтитров а синецкая корректор а егорова",
        "thank you for watching", "thanks for watching", "you", "sigh", "music", "музыка",
    ]

    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return hallucinations.contains(key) ? "" : trimmed
    }
}

enum LocalTranscriberError: LocalizedError {
    case notReady

    var errorDescription: String? {
        String(localized: "Model Didn’t Load")
    }
}
