import AppKit
import Combine
import SwiftUI

@main
struct VoiceMacroMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var overlay: OverlayController!
    private var status: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var journalWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private static let onboardingKey = "onboardingCompleted"
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// Window and screenshot checks; never part of a release build.
    private var smokeMode: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--smoke-test")
        #else
        false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !smokeMode, let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
           !Self.waitForRelaunchedPredecessor(other) {
            other.activate()
            DistributedNotificationCenter.default().postNotificationName(.init("local.voicemacro.showSettings"), object: nil)
            NSApp.terminate(nil)
            return
        }
        if !smokeMode { AudioRecorder.removeExpiredRecordings(olderThan: 0) }
        model = AppModel(systemIntegrationEnabled: !smokeMode, defaults: smokeMode ? UserDefaults(suiteName: "local.voicemacro.preview")! : .standard)
        overlay = OverlayController(model: model)
        model.onShowOverlay = { [weak self] in self?.overlay.show() }
        model.onHideOverlay = { [weak self] in self?.overlay.hide() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        // The last onboarding step explains the conflict itself.
        model.onFnConflict = { [weak self] in if self?.onboardingWindow == nil { self?.showSettings() } }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshMenu()
        // Only what the menu shows: the recording clock must not rebuild it five times a second.
        let journalChanges = model.journal?.$entries.map { _ in }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
        Publishers.Merge3(model.$phase.map { _ in }, journalChanges,
                          model.settings.$trigger.combineLatest(model.settings.$shortcut).map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshMenu() }
            .store(in: &cancellables)
        observeSystemEvents()
        if !smokeMode {
            Telemetry.shared.start()
            if model.settings.engine == .local { LocalTranscriber.standard.prepare() }
            Telemetry.shared.track("app_started", [
                "engine": .string(model.settings.engine.rawValue),
                "trigger": .string(model.settings.trigger.rawValue),
                "model": .string(AppSettings.modelLabel(model.settings.model)),
                "connected": .bool(model.connection.isConnected),
                "onboarded": .bool(UserDefaults.standard.bool(forKey: Self.onboardingKey)),
            ])
        }
        if smokeMode {
            #if DEBUG
            runSmokeCheck()
            #endif
        } else if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            // Relaunched for keyboard access: back to the permissions step.
            showOnboarding(step: CommandLine.arguments.contains("--relaunched") ? 1 : 0)
        } else if CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--relaunched") {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: Self.onboardingKey) { showSettings() } else { showOnboarding() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Telemetry.shared.flush()
        model?.shutdown()
        overlay?.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func showSettings() {
        guard model != nil else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "VoiceFn"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                model: model, settings: model.settings, connection: model.connection,
                localModel: LocalTranscriber.standard
            ) { [weak self] in self?.showJournal() })
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Telemetry.shared.track("settings_opened")
        model.refreshPermissions()
    }

    private func showOnboarding(step: Int = 0) {
        guard model != nil else { return }
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "VoiceFn"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(
                model: model, settings: model.settings, connection: model.connection,
                localModel: LocalTranscriber.standard,
                finish: { [weak self] in self?.finishOnboarding() }, step: step
            ))
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        Telemetry.shared.track("onboarding_completed", ["connected": .bool(model.connection.isConnected),
                                                       "permissions": .bool(model.microphoneGranted && model.accessibilityGranted)])
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    @objc private func showJournal() {
        guard let model, let journal = model.journal else { return }
        if journalWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = String(localized: "Dictation History")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: JournalView(model: model, journal: journal))
            window.setFrameAutosaveName("VoiceMacroJournal")
            window.center()
            journalWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        journalWindow?.makeKeyAndOrderFront(nil)
        Telemetry.shared.track("history_opened")
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        model.copy(text)
        Telemetry.shared.track("recent_copied")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refreshMenu() {
        guard let status, let model else { return }
        let busy = model.phase == .starting || model.phase == .stopping || model.phase == .transcribing
        let image = Self.keyImage(label: busy ? "···" : "fn", fill: model.phase == .recording ? .systemRed : nil)
        image.accessibilityDescription = "VoiceFn: \(model.phase.title)"
        status.button?.image = image
        status.button?.contentTintColor = nil
        status.button?.toolTip = model.phase.title
        let menu = NSMenu()
        let hint = model.settings.trigger == .fn ? String(localized: "Press fn to dictate")
            : String(localized: "Press \(model.settings.triggerName) to dictate")
        add(model.phase == .idle || model.phase == .delivered ? hint : model.phase.title, to: menu, action: nil)
        menu.addItem(.separator())
        if let journal = model.journal {
            let recent = journal.entries.lazy.compactMap(\.text).prefix(3)
            if !recent.isEmpty {
                menu.addItem(.sectionHeader(title: String(localized: "Recent")))
                for text in recent {
                    let line = text.replacingOccurrences(of: "\n", with: " ")
                    let item = add(line.count > 48 ? String(line.prefix(47)) + "…" : line, to: menu, action: #selector(copyRecent(_:)))
                    item.representedObject = text
                    item.toolTip = String(localized: "Click to copy")
                }
                menu.addItem(.separator())
            }
            add(String(localized: "History"), to: menu, action: #selector(showJournal), key: "l")
        }
        add(String(localized: "Settings…"), to: menu, action: #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(String(localized: "Quit VoiceFn"), to: menu, action: #selector(quit), key: "q")
        menu.autoenablesItems = false
        status.menu = menu
    }

    /// The menu bar icon: an fn key. Outlined, it is a template image that follows the menu bar's
    /// appearance; filled (while recording), it keeps its own color so it reads on any background.
    static func keyImage(label: String, fill: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { _ in
            let key = NSRect(x: 1.5, y: 1, width: 16, height: 14)
            let path = NSBezierPath(roundedRect: key, xRadius: 3.6, yRadius: 3.6)
            let textColor: NSColor
            if let fill {
                fill.setFill()
                path.fill()
                textColor = .white
            } else {
                NSColor.black.setStroke()
                path.lineWidth = 1.3
                path.stroke()
                textColor = .black
            }
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: textColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: key.midX - size.width / 2, y: key.midY - size.height / 2 + 0.5))
            return true
        }
        image.isTemplate = fill == nil
        return image
    }

    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        menu.addItem(item)
        return item
    }

    private func observeSystemEvents() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.interrupt(String(localized: "Your Mac went to sleep. The recording is saved.")) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshPermissions(); self?.model.configureHotkeys(); self?.model.refreshDevices() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.appBecameActive() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.screenLocked() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("local.voicemacro.showSettings"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showSettings() }
        })
        #if DEBUG
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("local.voicemacro.checkPermissions"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.writePermissionStatus() }
        })
        #endif
    }

    /// A relaunch for keyboard access starts this process while the old one is still quitting;
    /// waiting for it keeps the new instance from mistaking it for a second copy and quitting too.
    private static func waitForRelaunchedPredecessor(_ other: NSRunningApplication) -> Bool {
        guard CommandLine.arguments.contains("--relaunched") else { return false }
        let deadline = Date().addingTimeInterval(5)
        while !other.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return other.isTerminated
    }

    #if DEBUG
    private func writePermissionStatus() {
        guard !smokeMode else { return }
        model.refreshPermissions()
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("VoiceMacro", isDirectory: true)
        let report: [String: Any] = ["accessibility": model.accessibilityGranted,
                                   "microphone": model.microphoneGranted,
                                   "inputMonitoring": CGPreflightListenEventAccess(),
                                   "phase": model.phase.rawValue,
                                   "engine": model.settings.engine.rawValue,
                                   "localModel": String(describing: LocalTranscriber.standard.state),
                                   "overlay": overlay.diagnosticStatus,
                                   "checkedAt": Date().timeIntervalSince1970]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("permission-status.json"), options: .atomic)
        } catch { /* A diagnostic request must not disrupt recording. */ }
    }

    /// Settings as a set-up user sees them, for the App Store screenshots.
    private func renderStoreScreens(to directory: URL) async throws {
        model.previewAsSetUp()
        let local = LocalTranscriber(directory: FileManager.default.temporaryDirectory)
        local.previewReady()
        for engine in [TranscriptionEngine.local] {
            model.settings.engine = engine
            let view = NSHostingView(rootView: SettingsView(
                model: model, settings: model.settings, connection: model.connection,
                localModel: local, openHistory: {}))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("store-settings-\(engine.rawValue).png"))
            }
        }
        model.settings.engine = .local
    }

    /// Exercises native window construction without recording, clipboard writes, or API requests.
    private func runSmokeCheck() {
        guard let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 else {
            NSApp.terminate(nil); return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let wasActive = NSApp.isActive
        overlay.show(preview: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, let panel = self.overlay.panel else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try self.overlay.renderPreview(to: directory.appendingPathComponent("overlay.png"))
                var report: [String: Any] = [
                    "panelVisible": panel.isVisible,
                    "panelOnActiveSpace": panel.isOnActiveSpace,
                    "panelUnoccluded": panel.occlusionState.contains(.visible),
                    "canBecomeKey": panel.canBecomeKey,
                    "canBecomeMain": panel.canBecomeMain,
                    "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                    "fullScreenAuxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary),
                    "allSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                    "appActivatedByOverlay": !wasActive && NSApp.isActive,
                    "microphoneStarted": self.model.recorder.isRecording
                ]
                // Reproduce losing the native window while the visibility request
                // remains active. No recording/network/clipboard is involved.
                panel.orderOut(nil)
                try? await Task.sleep(for: .milliseconds(800))
                report["recoversAfterExternalHide"] = panel.isVisible && self.overlay.recoveryCount > 0
                report["recoveryKeepsAppInactive"] = !wasActive && !NSApp.isActive
                self.overlay.hide()
                self.overlay.restoreVisibility(reposition: true)
                try? await Task.sleep(for: .milliseconds(600))
                report["explicitHideStaysHidden"] = !panel.isVisible
                self.overlay.show(preview: true)
                report["cannotHideWithApplication"] = !panel.canHide
                report["joinsAllApplications"] = panel.collectionBehavior.contains(.canJoinAllApplications)
                guard report["recoversAfterExternalHide"] as? Bool == true,
                      report["explicitHideStaysHidden"] as? Bool == true else {
                    throw AppError.message("Overlay recovery check failed.")
                }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("smoke.json"))
                for phase in [DictationPhase.transcribing, .delivered, .failed] {
                    self.overlay.show(preview: true, previewPhase: phase)
                    try? await Task.sleep(for: .milliseconds(200))
                    try self.overlay.renderPreview(to: directory.appendingPathComponent("overlay-\(phase.rawValue).png"))
                }
                for step in 0..<3 {
                    let view = NSHostingView(rootView: OnboardingView(
                        model: self.model, settings: self.model.settings, connection: self.model.connection,
                        localModel: LocalTranscriber(directory: FileManager.default.temporaryDirectory),
                        finish: {}, step: step))
                    view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("onboarding-\(step).png"))
                    }
                }
                if CommandLine.arguments.contains("--marketing") { try await self.renderStoreScreens(to: directory) }
                self.showSettings()
                try? await Task.sleep(for: .milliseconds(400))
                if let view = self.settingsWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings.png"))
                }
            } catch { fputs("Native preview check failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }
    #endif
}
