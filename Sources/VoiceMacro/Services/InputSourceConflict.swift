import Carbon
import Foundation

/// Decides whether Fn also switches the keyboard layout ("Press 🌐 key to: Change Input Source").
///
/// The app cannot read that system setting from the sandbox, so it watches the effect instead:
/// a layout switch right around an Fn press. Two such presses in a row raise the conflict, so
/// one unrelated ⌘Space does not; three quiet presses in a row clear it once the user fixes it.
struct InputSourceConflictDetector {
    /// Seconds around the moment the press toggled (its release) in which a switch counts.
    static let window: ClosedRange<TimeInterval> = -0.5...1.0
    private(set) var conflict = false
    /// Consecutive presses that disagree with `conflict`.
    private var streak = 0
    private var lastChange: TimeInterval = -.infinity

    mutating func inputSourceChanged(at time: TimeInterval) { lastChange = time }

    /// Call once `window` has passed after the press. Returns true when `conflict` changed.
    mutating func evaluatePress(at press: TimeInterval) -> Bool {
        let switched = Self.window.contains(lastChange - press)
        guard switched != conflict else { streak = 0; return false }
        streak += 1
        guard streak >= (conflict ? 3 : 2) else { return false }
        conflict.toggle()
        streak = 0
        return true
    }
}

@MainActor
final class InputSourceConflictMonitor {
    var onChange: ((Bool) -> Void)?
    private var detector = InputSourceConflictDetector()
    private var observer: NSObjectProtocol?

    init() {
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { self?.detector.inputSourceChanged(at: now) }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// An isolated Fn press just toggled dictation.
    func fnPressed() {
        let press = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(InputSourceConflictDetector.window.upperBound + 0.1))
            guard let self, self.detector.evaluatePress(at: press) else { return }
            self.onChange?(self.detector.conflict)
        }
    }
}
