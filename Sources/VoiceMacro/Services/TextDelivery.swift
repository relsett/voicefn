import AppKit
import ApplicationServices

/// AXUIElement references are immutable CF handles and are safe to pass between threads.
struct TextTarget: @unchecked Sendable {
    fileprivate let processID: pid_t
    /// Nil in the App Sandbox, which cannot read other applications' interface:
    /// there the target is only the frontmost application.
    fileprivate let window: AXUIElement?
    fileprivate let element: AXUIElement?
}

enum DeliveryOutcome: Equatable {
    case copied
    case accessibilityRequired
    case unsupportedTarget
    case eventUnavailable
    /// The paste event was sent. Applications do not acknowledge consuming it.
    case pasted
    case targetChanged
}

@MainActor
final class TextDelivery {
    let clipboard = DictationClipboard()
    private var captureDiagnostic: [String: String] = [:]

    /// Text from a model is pasted into whatever app is in front, a terminal included, so it
    /// keeps only printable characters, line breaks and tabs: an escape sequence spoken into
    /// the audio or produced by a model must never reach a shell as keystrokes.
    nonisolated static func sanitized(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            // Joiners are part of the text: Persian and Indic spelling, emoji sequences.
            if scalar == "\u{200C}" || scalar == "\u{200D}" { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accessibility IPC blocks until the other application answers, so it never runs on
    /// the main thread: a hung frontmost app must not freeze the hotkey or the overlay.
    func captureTarget(prepareAccessibility: Bool = true) async -> TextTarget? {
        let trusted = SystemAccess.canPostEvents
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            captureDiagnostic = ["trusted": String(trusted)]
            return nil
        }
        let processID = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "unknown"
        if SystemAccess.sandboxed {
            captureDiagnostic = ["trusted": "true", "application": bundleID, "sandboxed": "true"]
            return TextTarget(processID: processID, window: nil, element: nil)
        }
        let probe = await Task.detached(priority: .userInitiated) {
            AccessibilityProbe.capture(processID: processID, prepareAccessibility: prepareAccessibility)
        }.value
        captureDiagnostic = probe.diagnostic.merging(["trusted": "true", "application": bundleID]) { $1 }
        return probe.target
    }

    func deliver(_ text: String, to target: TextTarget?, autoPaste: Bool,
                 restoring snapshot: DictationClipboard.Snapshot?) async -> DeliveryOutcome {
        let originalCapture = captureDiagnostic
        var outcome = DeliveryOutcome.copied
        defer {
            if outcome != .pasted && !Task.isCancelled { clipboard.copy(text) }
            saveDiagnostic(outcome: outcome, autoPaste: autoPaste, originalCapture: originalCapture)
        }
        guard autoPaste else { return outcome }
        guard SystemAccess.canPostEvents else { outcome = .accessibilityRequired; return outcome }
        guard let target else { outcome = .unsupportedTarget; return outcome }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
              let current = await captureTarget(prepareAccessibility: false), current.processID == target.processID,
              Self.same(current.window, target.window), Self.same(current.element, target.element) else {
            outcome = .targetChanged
            return outcome
        }
        // The dictation was cancelled while the target was being verified.
        guard !Task.isCancelled else { return outcome }
        // An isolated source prevents the still-held dictation shortcut modifiers
        // from changing Cmd-V into another command in the receiving application.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            outcome = .eventUnavailable
            return outcome
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let clipboardToRestore = clipboard.snapshotForPaste(snapshot)
        // AX IPC and clipboard reads can take time; recheck the foreground before posting.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            outcome = .targetChanged
            return outcome
        }
        guard clipboard.writeForPaste(text, restoring: clipboardToRestore) else {
            outcome = .eventUnavailable
            return outcome
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        outcome = .pasted
        return outcome
    }

    private static func same(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (first?, second?): return CFEqual(first, second)
        default: return false
        }
    }

    private func saveDiagnostic(outcome: DeliveryOutcome, autoPaste: Bool, originalCapture: [String: String]) {
        #if DEBUG
        // Only the latest technical outcome: never text, window titles, AXValue, or keys.
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("VoiceMacro", isDirectory: true)
        let report: [String: Any] = ["autoPaste": autoPaste, "trusted": SystemAccess.canPostEvents,
                                   "outcome": String(describing: outcome),
                                   "captured": originalCapture, "current": captureDiagnostic]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("paste-diagnostic.json")
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Diagnostics must never affect delivery. */ }
        #endif
    }
}

/// Synchronous accessibility queries, run off the main thread by `TextDelivery`.
private enum AccessibilityProbe {
    /// Applied to every element: a timeout set on the application element does not
    /// carry over to the window and field elements obtained from it.
    static let timeout: Float = 0.25

    static func capture(processID: pid_t, prepareAccessibility: Bool) -> (target: TextTarget?, diagnostic: [String: String]) {
        var diagnostic: [String: String] = [:]
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, timeout)
        // Electron documents this opt-in; unsupported native apps simply ignore it.
        // Prime the tree at recording start so it is available when recording ends.
        if prepareAccessibility {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute, &diagnostic),
              let element = elementAttribute(application, kAXFocusedUIElementAttribute, &diagnostic),
              isSafeTextElement(element, &diagnostic) else { return (nil, diagnostic) }
        return (TextTarget(processID: processID, window: window, element: element), diagnostic)
    }

    private static func attribute(_ element: AXUIElement, _ name: String, _ diagnostic: inout [String: String]) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else {
            if name == kAXFocusedWindowAttribute || name == kAXFocusedUIElementAttribute {
                diagnostic[name + "Error"] = String(result.rawValue)
            }
            return nil
        }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String, _ diagnostic: inout [String: String]) -> AXUIElement? {
        guard let value = attribute(element, name, &diagnostic), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, timeout)
        return result
    }

    private static func isSafeTextElement(_ element: AXUIElement, _ diagnostic: inout [String: String]) -> Bool {
        let role = attribute(element, kAXRoleAttribute, &diagnostic) as? String
        let subrole = attribute(element, kAXSubroleAttribute, &diagnostic) as? String
        let enabled = attribute(element, kAXEnabledAttribute, &diagnostic) as? Bool
        let editable = attribute(element, "AXEditable", &diagnostic) as? Bool
        let readOnly = attribute(element, "AXReadOnly", &diagnostic) as? Bool
        let protected = attribute(element, "AXProtectedContent", &diagnostic) as? Bool ?? false
        // Direct AXValue mutation and keyboard paste are different capabilities.
        // Web editors can accept Cmd-V without exposing a writable AXValue.
        var settable = DarwinBoolean(false)
        let writable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        diagnostic["role"] = role ?? "unknown"
        diagnostic["enabled"] = enabled.map(String.init) ?? "unknown"
        diagnostic["editable"] = editable.map(String.init) ?? "unknown"
        diagnostic["valueWritable"] = String(writable)
        return TextPastePolicy.allows(role: role, subrole: subrole, enabled: enabled,
                                      editable: editable, readOnly: readOnly,
                                      protected: protected, valueWritable: writable)
    }
}

enum TextPastePolicy {
    static func allows(role: String?, subrole: String?, enabled: Bool?, editable: Bool?,
                       readOnly: Bool?, protected: Bool, valueWritable: Bool) -> Bool {
        guard enabled != false, editable != false, readOnly != true, !protected,
              subrole != kAXSecureTextFieldSubrole else { return false }
        if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
        if role == kAXComboBoxRole { return editable == true || valueWritable }
        return role == kAXGroupRole && editable == true
    }
}
