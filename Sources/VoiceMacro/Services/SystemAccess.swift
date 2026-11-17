import ApplicationServices
import CoreGraphics
import Foundation

/// The macOS permission behind the Fn hotkey and automatic paste.
///
/// Outside the App Sandbox this is full Accessibility. A sandboxed app cannot add
/// itself to the Accessibility list (the prompt option is ignored), so it asks for
/// the two narrower permissions macOS provides for sandboxed apps instead: posting
/// events (the Cmd-V paste) and listening to events (the global Fn monitor).
enum SystemAccess {
    static let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static var granted: Bool {
        sandboxed ? CGPreflightPostEventAccess() && CGPreflightListenEventAccess() : AXIsProcessTrusted()
    }

    static var canPostEvents: Bool {
        sandboxed ? CGPreflightPostEventAccess() : AXIsProcessTrusted()
    }

    /// The System Settings pane where the missing permission is switched on.
    static var settingsPane: String {
        sandboxed && CGPreflightPostEventAccess() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
    }

    static func request() {
        if sandboxed {
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
