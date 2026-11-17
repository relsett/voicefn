import AppKit
import Combine
import SwiftUI

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    private(set) var panel: StatusPanel?
    private let model: AppModel
    private var screenID: NSNumber?
    private var observers: [NSObjectProtocol] = []
    private var phaseSubscription: AnyCancellable?
    private var showingPreview = false
    private var currentPreviewPhase: DictationPhase = .recording
    private(set) var panelGeneration = 0
    private var offSpaceRecovery = OffSpaceRecovery()
    private let isOnActiveSpace: @MainActor (StatusPanel) -> Bool
    private(set) var wantsVisible = false
    private(set) var recoveryCount = 0
    private var visibilityTimer: Timer?
    private var suspensionReasons: Set<String> = []
    private var sessionSuspended: Bool { !suspensionReasons.isEmpty }

    init(model: AppModel, isOnActiveSpace: @escaping @MainActor (StatusPanel) -> Bool = { $0.isOnActiveSpace }) {
        self.model = model
        self.isOnActiveSpace = isOnActiveSpace
        phaseSubscription = model.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self, !self.showingPreview else { return }
            self.resize(for: phase)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restoreVisibility(reposition: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.restoreVisibility(reposition: true) } })
        for (name, reason) in [(NSWorkspace.willSleepNotification, "sleep"), (NSWorkspace.sessionDidResignActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendVisibility(reason: reason) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, "sleep"), (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeVisibility(reason: reason) }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendVisibility(reason: "lock") }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeVisibility(reason: "lock") }
        })
    }

    func show(preview: Bool = false, previewPhase: DictationPhase = .recording) {
        showingPreview = preview
        let wasRequested = wantsVisible
        wantsVisible = true
        currentPreviewPhase = previewPhase
        if panel == nil || !wasRequested || (!preview && model.phase == .starting) { replacePanel() }
        if !wasRequested {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }
        let content = OverlayHostingView(rootView: RecordingOverlay(model: model, recorder: model.recorder, preview: preview, previewPhase: previewPhase))
        content.sizingOptions = []
        panel?.contentView = content
        resize(for: preview ? previewPhase : model.phase)
        if !sessionSuspended { panel?.orderFrontRegardless() }
        startVisibilityChecks()
    }

    private func replacePanel() {
        let oldPanel = panel
        let existingContent = oldPanel?.contentView
        oldPanel?.orderOut(nil)
        oldPanel?.contentView = nil
        oldPanel?.close()
        let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 88, height: 46),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityLabel(String(localized: "VoiceFn dictation status"))
        self.panel = panel
        panelGeneration += 1
        offSpaceRecovery.didReplace(at: ProcessInfo.processInfo.systemUptime)
        if let existingContent {
            panel.contentView = existingContent
        } else {
            let content = OverlayHostingView(rootView: RecordingOverlay(
                model: model, recorder: model.recorder, preview: showingPreview, previewPhase: currentPreviewPhase
            ))
            content.sizingOptions = []
            panel.contentView = content
        }
        resize(for: showingPreview ? currentPreviewPhase : model.phase)
    }

    func hide() {
        wantsVisible = false
        offSpaceRecovery.resetMisses()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        panel?.orderOut(nil)
    }

    private func startVisibilityChecks() {
        guard visibilityTimer == nil else { return }
        // Fullscreen/Space transitions can finish after their notification. Also
        // recover if AppKit orders the panel out without changing dictation state.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restoreVisibility() }
        }
        visibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func restoreVisibility(reposition: Bool = false) {
        guard wantsVisible, !sessionSuspended, let panel else { return }
        let intersectsScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        let onActiveSpace = isOnActiveSpace(panel)
        let needsRecovery = !panel.isVisible || !onActiveSpace ||
            !panel.occlusionState.contains(.visible) || !intersectsScreen
        if offSpaceRecovery.shouldReplace(onActiveSpace: onActiveSpace, at: ProcessInfo.processInfo.systemUptime) {
            // Reordering cannot repair every stale WindowServer Space association.
            // A new native window joins the current Space without touching recording.
            replacePanel()
            self.panel?.orderFrontRegardless()
            recoveryCount += 1
            return
        }
        guard reposition || needsRecovery else { return }
        position()
        // Reorder off-Space windows after a transition instead of trusting isVisible,
        // which describes window ordering and does not guarantee on-screen visibility.
        if !onActiveSpace { panel.orderOut(nil) }
        panel.orderFrontRegardless()
        if needsRecovery { recoveryCount += 1 }
    }

    private func suspendVisibility(reason: String) {
        suspensionReasons.insert(reason)
        offSpaceRecovery.resetMisses()
        panel?.orderOut(nil)
    }

    private func resumeVisibility(reason: String) {
        let wasSuspended = sessionSuspended
        suspensionReasons.remove(reason)
        if wasSuspended && !sessionSuspended && wantsVisible { replacePanel() }
        restoreVisibility(reposition: true)
    }

    var diagnosticStatus: [String: Any] {
        ["requested": wantsVisible, "suspended": sessionSuspended,
         "visible": panel?.isVisible ?? false,
         "onActiveSpace": panel?.isOnActiveSpace ?? false,
         "unoccluded": panel?.occlusionState.contains(.visible) ?? false,
         "frame": panel.map { NSStringFromRect($0.frame) } ?? "none",
         "recoveries": recoveryCount, "generation": panelGeneration,
         "windowNumber": panel?.windowNumber ?? -1, "appHidden": NSApp.isHidden,
         "suspensionReasons": suspensionReasons.sorted()]
    }


    private func resize(for phase: DictationPhase) {
        panel?.setContentSize(NSSize(width: RecordingOverlay.width(for: phase) + 16, height: RecordingOverlay.height + 16))
        position()
        panel?.invalidateShadow()
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 30))
    }

    func renderPreview(to url: URL) throws {
        guard let view = panel?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AppError.message("Overlay render failed.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.message("Overlay image write failed.")
        }
        try data.write(to: url)
    }

    func stop() {
        hide()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        phaseSubscription?.cancel()
        panel?.close()
        panel = nil
    }
}

/// The dictation indicator: one small dark capsule with a single mark in its centre.
/// Only recording has a colour; text appears only when the user has to act.
struct RecordingOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: AudioRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var preview = false
    var previewPhase: DictationPhase = .recording

    static let paper = Color(red: 0.949, green: 0.941, blue: 0.922)
    static let done = Color(red: 0.48, green: 0.9, blue: 0.69)
    static let height: CGFloat = 30
    static let barCount = 7
    static let coral = Color(red: 1, green: 0.38, blue: 0.43)

    private var phase: DictationPhase { preview ? previewPhase : model.phase }
    private var warning: Bool { phase == .failed || phase == .interrupted }
    private var manualPaste: Bool { !preview && model.deliveryOutcome != .pasted }
    private var time: String { preview ? "0:12" : model.durationLabel }
    /// The last 30 seconds before the 5-minute limit show the clock instead of the bars.
    private var nearLimit: Bool { !preview && phase == .recording && model.elapsed >= 270 }

    static func width(for phase: DictationPhase) -> CGFloat {
        phase == .failed || phase == .interrupted ? 156 : 52
    }

    var body: some View {
        ZStack {
            mark
                .offset(x: warning && hovering ? -10 : 0)
                .opacity(!warning && hovering ? 0 : 1)
            if warning {
                HStack { Spacer(); closeButton }.padding(.trailing, 3).opacity(hovering ? 1 : 0)
            } else {
                closeButton.opacity(hovering ? 1 : 0)
            }
        }
        .frame(width: Self.width(for: phase), height: Self.height)
        // The window draws the shadow from this shape; a SwiftUI shadow here would leave a
        // translucent halo around the capsule.
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
        .help(preview ? phase.title : (model.message.isEmpty ? phase.title : model.message))
        .accessibilityElement(children: .contain)
        .environment(\.colorScheme, .dark)
        .padding(8)
    }

    @ViewBuilder private var mark: some View {
        switch phase {
        case .idle, .starting, .recording:
            if nearLimit {
                Text(verbatim: time)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.coral)
                    .accessibilityLabel(Text("Recording, \(time)"))
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        Capsule().fill(Self.coral).frame(width: 2.5, height: barHeight(index))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: recorder.level)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Recording, \(time)"))
            }
        case .stopping, .transcribing:
            spinner.accessibilityElement(children: .ignore).accessibilityLabel(Text("Transcribing"))
        case .delivered:
            Image(systemName: manualPaste ? "doc.on.clipboard" : "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.done)
                .accessibilityLabel(manualPaste ? Text("Copied") : Text("Pasted"))
        case .failed, .interrupted:
            failure
        }
    }

    @ViewBuilder private var spinner: some View {
        if reduceMotion {
            Image(systemName: "hourglass").foregroundStyle(.white.opacity(0.8))
        } else {
            SpinnerRing().frame(width: 15, height: 15)
        }
    }

    @ViewBuilder private var failure: some View {
        let content = HStack(spacing: 8) {
            Circle().fill(Self.coral).frame(width: 6, height: 6)
            if !preview && model.canRetry {
                Text(model.needsSetup ? "Connect" : "Retry")
            } else {
                Text("Not transcribed")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Self.paper)
        .lineLimit(1)
        if !preview && model.canRetry {
            Button {
                if model.needsSetup { model.onOpenSettings?() } else { model.retry() }
            } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Recording: discards it. Afterwards: hides the capsule; a held recording stays in the journal.
    private var closeButton: some View {
        Button { if !preview { model.cancel() } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Self.paper.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(hovering)
        .accessibilityHidden(!hovering)
        .accessibilityLabel(phase == .recording ? Text("Cancel recording") : Text("Close"))
        .help(phase == .recording ? Text("Cancel recording") : Text("Close"))
    }


    /// The original wave: seven bars of fixed proportions that rise and fall with the voice.
    private func barHeight(_ index: Int) -> CGFloat {
        let weights: [Double] = [0.3, 0.6, 0.85, 1, 0.75, 0.5, 0.25]
        return CGFloat(4 + (preview ? 0.8 : recorder.level) * 20 * weights[index])
    }
}

/// Ignore brief Space animations; recreate only after repeated failures, with a cooldown.
struct OffSpaceRecovery {
    private var consecutiveMisses = 0
    private var lastReplacement: TimeInterval = -.infinity

    mutating func shouldReplace(onActiveSpace: Bool, at uptime: TimeInterval) -> Bool {
        if onActiveSpace { consecutiveMisses = 0; return false }
        consecutiveMisses = min(consecutiveMisses + 1, 3)
        return consecutiveMisses >= 3 && uptime - lastReplacement >= 2
    }

    mutating func resetMisses() { consecutiveMisses = 0 }

    mutating func didReplace(at uptime: TimeInterval) {
        lastReplacement = uptime
        consecutiveMisses = 0
    }
}

/// The transcribing ring. Core Animation turns it on the render server at the display's refresh
/// rate, so it stays smooth while the main thread is busy.
private struct SpinnerRing: NSViewRepresentable {
    func makeNSView(context: Context) -> SpinnerRingView { SpinnerRingView() }
    func updateNSView(_ view: SpinnerRingView, context: Context) {}
}

private final class SpinnerRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = 1.8
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        arc.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        arc.lineCap = .round
        arc.strokeEnd = 0.65
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(ellipseIn: bounds.insetBy(dx: 0.9, dy: 0.9), transform: nil)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        track.contentsScale = scale
        arc.contentsScale = scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        guard window != nil, arc.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi // clockwise
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        turn.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        arc.add(turn, forKey: "turn")
    }
}
