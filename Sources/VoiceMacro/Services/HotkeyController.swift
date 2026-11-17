import AppKit
import ApplicationServices
import Carbon

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultBinding = ShortcutBinding(
        keyCode: 49, modifiers: UInt32(controlKey | optionKey)
    )

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        modifiers = flags
    }

    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    func validate() throws {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let required = UInt32(cmdKey | controlKey | optionKey)
        guard keyCode <= 127, !Self.modifierKeyCodes.contains(keyCode),
              modifiers & ~allowed == 0, modifiers & required != 0 else {
            throw HotkeyError.invalidShortcut
        }
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        // Hardware key labels remain stable when the active input source changes.
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
            7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
            15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return result + (names[keyCode] ?? "Key \(keyCode)")
    }
}

enum HotkeyError: LocalizedError {
    case invalidShortcut
    case eventHandler(OSStatus)
    case registration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            return String(localized: "Choose a key together with Control, Option, or Command.")
        case .eventHandler(let status):
            return String(localized: "Couldn’t listen for the shortcut (\(status)).")
        case .registration(let status):
            return String(localized: "This shortcut may already be in use (\(status)).")
        }
    }
}

/// A modifier key that starts and stops dictation when pressed and released on its own.
enum SoloKey: Equatable {
    case fn
    /// Every keyboard has it, including the many external ones whose Fn never reaches macOS.
    case rightOption

    // Device-dependent bits of the modifier flags (IOLLEvent.h): they tell left and right apart.
    private static let leftOptionMask: UInt = 0x20
    private static let rightOptionMask: UInt = 0x40

    var keyCode: UInt16 { UInt16(self == .fn ? kVK_Function : kVK_RightOption) }

    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.function)
        case .rightOption: return flags.rawValue & Self.rightOptionMask != 0
        }
    }

    /// Caps Lock is a latched state, not a held chord modifier.
    func otherModifiersDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn: return !flags.intersection([.command, .control, .option, .shift]).isEmpty
        case .rightOption:
            return !flags.intersection([.command, .control, .shift]).isEmpty
                || flags.rawValue & Self.leftOptionMask != 0
        }
    }
}

/// Pure gesture state, shared by local and global event monitors.
///
/// It deliberately keeps no list of held keys: macOS hides some key releases from background
/// apps (secure input, lock screen, shortcuts taken by other apps), and a key whose release
/// was missed would disqualify every later press. Keys held before the trigger key are
/// instead read from the system at the moment it goes down.
struct SoloKeyGesture {
    let key: SoloKey
    private(set) var isDown = false
    private var disqualified = false

    init(key: SoloKey = .fn) { self.key = key }

    mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                               otherKeysDown: () -> Bool = { false }) -> Bool {
        let otherModifiersDown = key.otherModifiersDown(modifiers)
        if keyCode == key.keyCode {
            let down = key.isDown(modifiers)
            return keyChanged(isDown: down, otherModifiersDown: otherModifiersDown,
                              otherKeysDown: down && !isDown && otherKeysDown())
        }
        if keyCode == UInt16(kVK_CapsLock), isDown { disqualified = true }
        otherModifiersChanged(areDown: otherModifiersDown)
        return false
    }

    /// A key pressed while the trigger is held makes it a chord such as Fn-arrow or ⌥-letter.
    mutating func keyDown() {
        if isDown { disqualified = true }
    }

    mutating func otherModifiersChanged(areDown: Bool) {
        if isDown && areDown { disqualified = true }
    }

    /// Returns true exactly once for an isolated press, on release.
    mutating func keyChanged(isDown next: Bool, otherModifiersDown: Bool, otherKeysDown: Bool = false) -> Bool {
        guard next != isDown else {
            if next && otherModifiersDown { disqualified = true }
            return false
        }
        if next {
            isDown = true
            disqualified = otherModifiersDown || otherKeysDown
            return false
        }
        let toggle = !disqualified && !otherModifiersDown
        isDown = false
        disqualified = false
        return toggle
    }
}

/// Filters auto-repeat of the Carbon shortcut without trusting that every release arrives:
/// a press more than `repeatWindow` after the previous press event is a new press even if
/// the release in between was lost.
struct ShortcutPressFilter {
    static let repeatWindow: TimeInterval = 0.7
    private var isDown = false
    private var lastPressAt: TimeInterval = -.infinity

    mutating func pressed(at time: TimeInterval) -> Bool {
        defer { lastPressAt = time }
        if isDown && time - lastPressAt < Self.repeatWindow { return false }
        isDown = true
        return true
    }

    mutating func released() { isDown = false }
}

enum KeyboardState {
    /// Hardware state of every non-modifier key. Without Input Monitoring access macOS
    /// reports keys as up, which only makes Fn more permissive, never unusable.
    static func nonModifierKeyIsDown() -> Bool {
        (0..<128).contains { code in
            !ShortcutBinding.modifierKeyCodes.contains(UInt32(code))
                && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        }
    }
}

@MainActor
final class HotkeyController {
    /// The solo key that toggled, or nil for the custom shortcut.
    var onToggle: ((SoloKey?) -> Void)?
    /// The solo key went down, whether or not the press ends up toggling: proof that macOS sees it.
    var onSoloKeyDown: (() -> Void)?

    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var gesture: SoloKeyGesture?
    private var shortcutPresses = ShortcutPressFilter()
    private static let signature: OSType = 0x564D4143 // VMAC

    static var accessibilityGranted: Bool { SystemAccess.granted }

    static func requestAccessibility() { SystemAccess.request() }

    /// A solo key uses NSEvent monitors; a shortcut is a Carbon hot key. Nil leaves either unregistered.
    func configure(soloKey: SoloKey?, shortcut: ShortcutBinding?) throws {
        stop()
        if let soloKey { installSoloKeyMonitors(soloKey) }
        guard let shortcut else { return }
        try shortcut.validate()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<HotkeyController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { controller.handleHotkey(event) }
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installStatus == noErr else {
            stopRegularShortcut()
            throw HotkeyError.eventHandler(installStatus)
        }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotkey
        )
        guard status == noErr else {
            stopRegularShortcut()
            throw HotkeyError.registration(status)
        }
    }

    private func installSoloKeyMonitors(_ key: SoloKey) {
        gesture = SoloKeyGesture(key: key)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleSoloKeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleSoloKeyEvent(event)
            return event
        }
    }

    func stop() {
        stopRegularShortcut()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        gesture = nil
    }

    private func stopRegularShortcut() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        shortcutPresses = ShortcutPressFilter()
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handleHotkey(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let result = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard result == noErr, identifier.signature == Self.signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            shortcutPresses.released()
        } else if shortcutPresses.pressed(at: ProcessInfo.processInfo.systemUptime) {
            onToggle?(nil)
        }
        return noErr
    }

    private func handleSoloKeyEvent(_ event: NSEvent) {
        guard var state = gesture else { return }
        defer { gesture = state }
        switch event.type {
        case .keyDown: state.keyDown()
        case .flagsChanged:
            if event.keyCode == state.key.keyCode && state.key.isDown(event.modifierFlags) { onSoloKeyDown?() }
            if state.flagsChanged(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                  otherKeysDown: KeyboardState.nonModifierKeyIsDown) { onToggle?(state.key) }
        default: break
        }
    }
}
