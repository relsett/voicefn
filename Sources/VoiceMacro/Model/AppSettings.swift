import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var engine: TranscriptionEngine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var trigger: DictationTrigger { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var mode: TranscriptionMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    /// Keep the audio of transcribed dictations in the journal instead of deleting it.
    @Published var keepRecordings: Bool { didSet { defaults.set(keepRecordings, forKey: "keepRecordings") } }
    @Published var shortcut: ShortcutBinding {
        didSet { if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "shortcut") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = TranscriptionEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .local
        // Earlier versions stored only whether Fn was on; the shortcut was always active.
        let fnEnabled = defaults.object(forKey: "fnEnabled") as? Bool ?? true
        trigger = DictationTrigger(rawValue: defaults.string(forKey: "trigger") ?? "") ?? (fnEnabled ? .fn : .shortcut)
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        model = defaults.string(forKey: "model") ?? "google/gemini-3.5-flash-lite"
        mode = TranscriptionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .audioChat
        keepRecordings = defaults.bool(forKey: "keepRecordings")
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) } ?? .defaultBinding
    }

    static let modelPresets: [(id: String, name: String)] = [
        ("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite"),
        ("openai/gpt-transcribe", "GPT Transcribe"),
    ]

    /// The model as telemetry reports it: a preset ID, or "custom" for anything typed in.
    static func modelLabel(_ model: String) -> String {
        model == LocalTranscriber.label || modelPresets.contains { $0.id == model }
            ? model : "custom"
    }

    /// The trigger as it reads inside a sentence: "Press … to dictate".
    var triggerName: String {
        switch trigger {
        case .fn: return "fn"
        case .rightOption: return String(localized: "right ⌥")
        case .shortcut: return shortcut.displayName
        }
    }

    /// The label drawn on the key picture.
    var keyCapLabel: String {
        switch trigger {
        case .fn: return "fn"
        case .rightOption: return "⌥"
        case .shortcut: return shortcut.displayName
        }
    }

    func chooseModel(_ value: String) {
        model = value
        mode = value.hasPrefix("google/") ? .audioChat : .speechToText
    }
}

/// What starts and stops dictation: Fn alone (recommended), right Option alone for keyboards
/// whose Fn macOS never sees, or a custom shortcut.
enum DictationTrigger: String, CaseIterable {
    case fn
    case rightOption
    case shortcut

    var soloKey: SoloKey? {
        switch self {
        case .fn: return .fn
        case .rightOption: return .rightOption
        case .shortcut: return nil
        }
    }
}

/// Where speech becomes text: on this Mac (the default, free and private) or through the user's
/// own OpenRouter account.
enum TranscriptionEngine: String, CaseIterable {
    case local
    case openRouter
}
