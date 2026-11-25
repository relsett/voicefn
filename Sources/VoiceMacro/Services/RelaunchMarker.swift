import Foundation

/// The sandbox drops launch arguments when the app opens a new copy of itself, so a relaunch
/// leaves a note in the shared defaults instead. Without it the new copy took the quitting one
/// for a second instance and quit as well, leaving nothing running.
enum RelaunchMarker {
    static let key = "relaunchRequestedAt"
    /// Long enough for a slow launch, short enough that a stale note never counts.
    static let window: TimeInterval = 15

    static func set(_ defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
        defaults.synchronize()
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// True once, in the copy a relaunch started moments ago.
    static func consume(_ defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let requested = defaults.double(forKey: key)
        guard requested > 0 else { return false }
        clear(defaults)
        let age = now.timeIntervalSince1970 - requested
        return age >= 0 && age < window
    }
}
