import Foundation

enum DictationPhase: String, Equatable {
    case idle, starting, recording, stopping, transcribing, delivered, failed, interrupted

    var busy: Bool { [.starting, .recording, .stopping, .transcribing].contains(self) }
    var title: String {
        switch self {
        case .idle: return String(localized: "Ready")
        case .starting: return String(localized: "Starting…")
        case .recording: return String(localized: "Recording")
        case .stopping: return String(localized: "Transcribing")
        case .transcribing: return String(localized: "Transcribing")
        case .delivered: return String(localized: "Done")
        case .failed: return String(localized: "Not transcribed")
        case .interrupted: return String(localized: "Recording saved")
        }
    }
}

/// A session identifier prevents cancelled network or permission callbacks from delivering text.
struct SessionState {
    private(set) var id = UUID()
    private(set) var phase: DictationPhase = .idle
    private(set) var stopHoldReason: String?

    mutating func begin() -> UUID? {
        guard phase == .idle || phase == .delivered else { return nil }
        id = UUID()
        stopHoldReason = nil
        phase = .starting
        return id
    }

    @discardableResult
    mutating func transition(to next: DictationPhase, for session: UUID) -> Bool {
        guard session == id else { return false }
        let allowed: [DictationPhase: Set<DictationPhase>] = [
            .idle: [],
            .starting: [.recording, .failed],
            .recording: [.stopping, .failed],
            .stopping: [.transcribing, .failed, .interrupted],
            .transcribing: [.delivered, .failed, .interrupted],
            .failed: [.transcribing],
            .interrupted: [.transcribing],
            .delivered: []
        ]
        guard allowed[phase, default: []].contains(next) else { return false }
        phase = next
        return true
    }

    mutating func reset() {
        id = UUID()
        phase = .idle
        stopHoldReason = nil
    }

    mutating func holdStoppedRecording(reason: String, for session: UUID) {
        guard session == id, phase == .recording || phase == .stopping else { return }
        stopHoldReason = reason
    }

    func accepts(_ session: UUID) -> Bool { session == id }
}
