import AppKit
import AVFoundation
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    private(set) lazy var connection = OpenRouterConnection(loadStoredConnection: systemIntegrationEnabled)
    let recorder = AudioRecorder()
    let hotkeys = HotkeyController()
    let delivery = TextDelivery()
    private let injectedOperations: AppModelOperations?
    private lazy var operations: AppModelOperations = injectedOperations ?? AppModelOperations(
        startRecording: { [unowned self] uid in try await self.recorder.start(deviceUID: uid) },
        stopRecording: { [unowned self] in try await self.recorder.stop() },
        recordingVoicedSeconds: { [unowned self] in self.recorder.voicedSeconds },
        cancelRecording: { [unowned self] in self.recorder.cancel() },
        apiKey: { [unowned self] in try self.connection.apiKey() },
        transcribe: { url, key, model, mode in
            try await OpenRouterTranscriptionClient().transcribe(fileURL: url, apiKey: key, model: model, mode: mode)
        },
        transcribeLocally: { url in try await LocalTranscriber.standard.transcribe(fileURL: url) },
        captureTarget: { [unowned self] in await self.delivery.captureTarget() },
        deliver: { [unowned self] text, target, autoPaste in await self.delivery.deliver(text, to: target, autoPaste: autoPaste) },
        copy: { [unowned self] text in self.delivery.copy(text) }
    )

    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var message = ""
    @Published private(set) var lastTranscript = ""
    @Published private(set) var deliveryOutcome: DeliveryOutcome?
    @Published private(set) var hasSavedRecording = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var shortcutError: String?
    @Published var settingsError: String?
    @Published var isCapturingShortcut = false
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var launchAtLogin = false
    /// Fn also switches the keyboard layout, so every dictation changes the language too.
    @Published private(set) var fnSwitchesInputSource = false
    /// macOS has delivered at least one press of the trigger key since it was chosen.
    @Published private(set) var triggerKeySeen = false

    var onShowOverlay: (() -> Void)?
    var onHideOverlay: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Fn turned out to switch the keyboard layout; the app explains it once dictation is over.
    var onFnConflict: (() -> Void)?

    private var state = SessionState()
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var fileURL: URL?
    private var target: TextTarget?
    private var capturedModel = ""
    private var capturedEngine: TranscriptionEngine = .local
    private var capturedMode: TranscriptionMode = .audioChat
    private var capturedAutoPaste = false
    private var cancellables: Set<AnyCancellable> = []

    private let systemIntegrationEnabled: Bool
    private let speechGate: SpeechGate
    private let dictationLog: DictationLog?
    let journal: DictationJournal?
    private let telemetry: Telemetry?
    private var inputSourceConflict: InputSourceConflictMonitor?
    /// Settings should open to explain the conflict once the current dictation is over.
    private var showConflictWhenIdle = false
    private static let conflictDismissedKey = "fnInputSourceWarningDismissed"
    /// The journal entry of the current session's recording.
    private var journalID: UUID?
    /// The journal took over the recording file; the session must not delete it.
    private var journalOwnsFile = false
    private var logSession = ""
    private var logAttempts = 0
    private var recordingBegan: ContinuousClock.Instant?
    private var recordingStats = RecordingStats()
    /// The stop key or the retry that began the current attempt.
    private var sendOrigin: ContinuousClock.Instant?

    private var stopWhenLive = false

    private struct RecordingStats {
        var startMs: Int?
        var voicedSeconds: Double?
        var seconds: Double?
        var stopMs: Int?
        var captureMs: Int?
    }

    init(systemIntegrationEnabled: Bool = true, defaults: UserDefaults = .standard,
         operations: AppModelOperations? = nil, dictationLog: DictationLog? = nil,
         journal: DictationJournal? = nil, telemetry: Telemetry? = nil, speechGate: SpeechGate? = nil) {
        self.speechGate = speechGate ?? (systemIntegrationEnabled ? .standard : .off)
        injectedOperations = operations
        // A developer's timing log, off unless `defaults write … dictationLog -bool true`.
        self.dictationLog = dictationLog
            ?? (systemIntegrationEnabled && defaults.bool(forKey: "dictationLog") ? DictationLog.standard : nil)
        self.journal = journal ?? (systemIntegrationEnabled ? DictationJournal.standard : nil)
        self.telemetry = telemetry ?? (systemIntegrationEnabled ? Telemetry.shared : nil)
        settings = AppSettings(defaults: defaults)
        self.systemIntegrationEnabled = systemIntegrationEnabled
        recorder.onInterruption = { [weak self] reason in self?.interrupt(reason) }
        hotkeys.onToggle = { [weak self] key in
            guard let self, !self.isCapturingShortcut else { return }
            if key == .fn { self.inputSourceConflict?.fnPressed() }
            self.toggle()
        }
        hotkeys.onSoloKeyDown = { [weak self] in
            if self?.triggerKeySeen == false { self?.triggerKeySeen = true }
        }
        if systemIntegrationEnabled {
            settings.$engine.dropFirst().filter { $0 == .local }
                .sink { _ in LocalTranscriber.standard.prepare() }.store(in: &cancellables)
        }
        settings.$trigger.combineLatest(settings.$shortcut)
            .dropFirst()
            .sink { [weak self] trigger, shortcut in
                self?.configureHotkeys(trigger: trigger, shortcut: shortcut)
            }.store(in: &cancellables)
        if systemIntegrationEnabled {
            let monitor = InputSourceConflictMonitor()
            monitor.onChange = { [weak self] conflict in self?.inputSourceConflictChanged(conflict) }
            inputSourceConflict = monitor
        }
        if operations == nil {
            connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
            refreshPermissions()
            refreshDevices()
            configureHotkeys()
        }
    }

    var canRetry: Bool { hasSavedRecording && [.failed, .interrupted].contains(phase) }
    var durationLabel: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        switch phase {
        case .idle, .delivered: start()
        case .recording: finishRecording(send: true)
        // The key always starts a new dictation. A held recording stays in history, where it
        // (or the capsule's Retry) can send it again; resending it on the key looped on
        // recordings that can never transcribe.
        case .failed, .interrupted:
            cancel()
            start()
        // A quick second press before the microphone is live stops the recording once it is.
        case .starting: stopWhenLive = true
        case .stopping, .transcribing: break
        }
    }

    private func start() {
        guard let session = state.begin() else { return }
        dismissTask?.cancel()
        discardFile()
        message = ""
        deliveryOutcome = nil
        elapsed = 0
        captureEngine()
        capturedAutoPaste = true
        target = nil
        journalID = nil
        logSession = String(UUID().uuidString.prefix(8))
        logAttempts = 0
        recordingBegan = nil
        recordingStats = RecordingStats()
        stopWhenLive = false
        sendOrigin = nil
        publishPhase()
        onShowOverlay?()
        let uid = settings.microphoneUID.isEmpty ? nil : settings.microphoneUID
        let pressed = ContinuousClock.now
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.operations.startRecording(uid)
                guard self.state.accepts(session), !Task.isCancelled else { return }
                self.recordingStats.startMs = (ContinuousClock.now - pressed).milliseconds
                self.microphoneGranted = true
                self.transition(.recording, session)
                self.recordingBegan = .now
                self.startClock()
                if self.stopWhenLive {
                    self.stopWhenLive = false
                    self.finishRecording(send: true)
                    return
                }
                // Primes the focused app's accessibility tree once the microphone is live, and
                // is the paste target for a recording that is held instead of sent.
                let captured = await self.operations.captureTarget()
                if self.state.accepts(session), self.target == nil { self.target = captured }
            } catch {
                guard self.state.accepts(session), !Task.isCancelled else { return }
                self.fail(error.localizedDescription, session: session)
            }
        }
    }

    private func finishRecording(send: Bool, interruption: String? = nil) {
        guard phase == .recording else { return }
        let session = state.id
        if !send { state.holdStoppedRecording(reason: interruption ?? String(localized: "Recording saved. Send it or delete it."), for: session) }
        let stopPressed = ContinuousClock.now
        recordingStats.seconds = recordingBegan.map { Double((stopPressed - $0).milliseconds) / 1_000 }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        sendOrigin = send ? stopPressed : nil
        transition(.stopping, session)
        stopClock()
        task = Task { [weak self] in
            guard let self else { return }
            // Capture where the user stopped speaking, never the window opened for a later retry.
            // It runs while the recorder closes the file.
            let capture = send ? Task { () -> (TextTarget?, Int) in
                let began = ContinuousClock.now
                let target = await self.operations.captureTarget()
                return (target, (ContinuousClock.now - began).milliseconds)
            } : nil
            do {
                let url = try await self.operations.stopRecording()
                self.recordingStats.stopMs = (ContinuousClock.now - stopPressed).milliseconds
                let capturedResult = await capture?.value
                let captured = capturedResult?.0
                self.recordingStats.captureMs = capturedResult?.1
                guard self.state.accepts(session), !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.recordingStats.voicedSeconds = self.operations.recordingVoicedSeconds()
                if send && self.state.stopHoldReason == nil,
                   let reason = self.speechGate.reject(voicedSeconds: self.recordingStats.voicedSeconds) {
                    // A tap or silence: nothing to transcribe, so nothing to report or pay for.
                    var entry = self.makeLogEntry(fileURL: url, origin: stopPressed)
                    entry.result = "discarded"
                    entry.error = reason
                    self.dictationLog?.append(entry)
                    try? FileManager.default.removeItem(at: url)
                    self.telemetry?.track("recording_discarded", ["reason": .string(reason)])
                    self.dismissQuietly()
                    return
                }
                if send { self.target = captured }
                self.fileURL = url
                if let journal = self.journal {
                    let journaled = journal.begin(recording: url, appName: app?.localizedName,
                                                  appBundleID: app?.bundleIdentifier, seconds: self.recordingStats.seconds)
                    self.journalID = journaled.id
                    self.journalOwnsFile = journaled.url != url
                    self.fileURL = journaled.url
                }
                self.hasSavedRecording = true
                if send && self.state.stopHoldReason == nil {
                    await self.sendRecording(session: session)
                } else {
                    self.message = self.state.stopHoldReason ?? String(localized: "Recording saved. Send it or delete it.")
                    self.recordJournalFailure(self.message)
                    self.transition(.interrupted, session)
                    self.onShowOverlay?()
                }
            } catch AudioRecordingError.noRecording {
                // Stopped before the microphone delivered any audio: a tap, not a failure.
                guard self.state.accepts(session), !Task.isCancelled else { return }
                self.telemetry?.track("recording_discarded", ["reason": .string("empty")])
                self.dismissQuietly()
            } catch {
                guard self.state.accepts(session), !Task.isCancelled else { return }
                self.fail(error.localizedDescription, session: session)
            }
        }
    }

    func retry() {
        guard canRetry else { return }
        let session = state.id
        guard state.transition(to: .transcribing, for: session) else { return }
        publishPhase()
        message = ""
        captureEngine()
        sendOrigin = .now
        telemetry?.track("retry")
        task = Task { [weak self] in await self?.sendRecording(session: session) }
    }

    private func sendRecording(session: UUID) async {
        guard state.accepts(session), let fileURL else { return }
        let origin = sendOrigin ?? .now
        let trace = TranscriptionTrace()
        var entry = makeLogEntry(fileURL: fileURL, origin: origin)
        defer { writeLog(entry, trace: trace, origin: origin) }
        do {
            let request = try transcriptionRequest(engine: capturedEngine, model: capturedModel, mode: capturedMode)
            if phase != .transcribing {
                guard state.transition(to: .transcribing, for: session) else { return }
                publishPhase()
            }
            startClock()
            let requested = ContinuousClock.now
            entry.beforeSendMs = (requested - origin).milliseconds
            let text = try await TranscriptionTrace.$current.withValue(trace) {
                try await request(fileURL)
            }
            entry.transcribeMs = (ContinuousClock.now - requested).milliseconds
            guard state.accepts(session), !Task.isCancelled else { return }
            stopClock()
            let clean = TextDelivery.sanitized(text)
            entry.transcriptChars = clean.count
            guard !clean.isEmpty else {
                entry.result = "failed"
                entry.error = "empty transcript"
                telemetry?.track("dictation_failed", ["reason": .string("empty"), "model": .string(AppSettings.modelLabel(capturedModel))])
                // Not an error to show: most often nothing was said. The audio stays in the
                // journal in case there was speech after all.
                recordJournalFailure(String(localized: "No speech recognized."))
                dismissQuietly()
                return
            }
            // Claim completion before invoking the one external side effect.
            guard state.transition(to: .delivered, for: session) else { return }
            lastTranscript = clean
            if let journalID {
                journal?.complete(journalID, text: clean, model: capturedModel, keepAudio: settings.keepRecordings)
            }
            let delivering = ContinuousClock.now
            let outcome = await operations.deliver(clean, target, capturedAutoPaste)
            entry.deliverMs = (ContinuousClock.now - delivering).milliseconds
            entry.outcome = String(describing: outcome)
            entry.result = "delivered"
            telemetry?.track("dictation_completed", [
                "seconds": .double(((recordingStats.seconds ?? 0) * 10).rounded() / 10),
                "transcribe_ms": .int(entry.transcribeMs ?? 0),
                "outcome": .string(String(describing: outcome)),
                "model": .string(AppSettings.modelLabel(capturedModel)),
                "attempt": .int(entry.attempt),
            ])
            telemetry?.trackActiveDay()
            // Cancelled while the paste target was being verified.
            guard state.accepts(session) else { return }
            deliveryOutcome = outcome
            switch outcome {
            case .copied: message = String(localized: "Copied. Press ⌘V to paste.")
            case .accessibilityRequired:
                accessibilityGranted = false
                message = String(localized: "Copied. Allow keyboard access in Settings to paste automatically.")
            case .unsupportedTarget: message = String(localized: "Copied. Press ⌘V to paste.")
            case .eventUnavailable: message = String(localized: "Copied. Press ⌘V to paste.")
            case .pasted: message = String(localized: "Pasted")
            case .targetChanged: message = String(localized: "Copied. Press ⌘V to paste.")
            }
            discardFile()
            publishPhase()
            scheduleDismiss(session: session)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            entry.result = cancelled ? "cancelled" : "failed"
            entry.error = TranscriptionTrace.describe(error)
            if !cancelled {
                telemetry?.track("dictation_failed", ["reason": .string(Telemetry.reason(for: error)),
                                                      "model": .string(AppSettings.modelLabel(capturedModel))])
            }
            guard state.accepts(session), !Task.isCancelled else { return }
            // Missing authorization can fail before entering the transcribing state.
            fail(error.localizedDescription, session: session)
        }
    }

    private func makeLogEntry(fileURL: URL, origin: ContinuousClock.Instant) -> DictationRecord {
        logAttempts += 1
        let firstAttempt = logAttempts == 1
        let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return DictationRecord(
            time: Date(), session: logSession, attempt: logAttempts,
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            model: capturedModel, mode: capturedMode.rawValue, autoPaste: capturedAutoPaste,
            startMs: firstAttempt ? recordingStats.startMs : nil,
            recordingSeconds: recordingStats.seconds,
            voicedSeconds: firstAttempt ? recordingStats.voicedSeconds : nil, audioBytes: size,
            stopMs: firstAttempt ? recordingStats.stopMs : nil,
            captureMs: firstAttempt ? recordingStats.captureMs : nil,
            // Overwritten on every exit; a return without one means the session moved on.
            result: "cancelled")
    }

    private func writeLog(_ entry: DictationRecord, trace: TranscriptionTrace, origin: ContinuousClock.Instant) {
        guard let dictationLog else { return }
        var entry = entry
        let response = trace.response
        entry.requests = trace.requests
        entry.generationId = response.generationId
        entry.provider = response.provider
        entry.promptTokens = response.promptTokens
        entry.completionTokens = response.completionTokens
        entry.totalMs = (ContinuousClock.now - origin).milliseconds
        dictationLog.append(entry)
    }

    func cancel() {
        if phase == .recording { telemetry?.track("recording_cancelled") }
        if let journalID, journal?.entry(journalID)?.status == .pending {
            journal?.fail(journalID, reason: String(localized: "Cancelled."))
        }
        journalID = nil
        state.reset()
        task?.cancel()
        task = nil
        dismissTask?.cancel()
        stopClock()
        operations.cancelRecording()
        discardFile()
        target = nil
        message = ""
        deliveryOutcome = nil
        elapsed = 0
        publishPhase()
        onHideOverlay?()
    }

    func interrupt(_ reason: String) {
        if phase == .recording {
            finishRecording(send: false, interruption: reason)
        } else if phase == .starting {
            cancel()
        } else if phase == .stopping {
            state.holdStoppedRecording(reason: reason, for: state.id)
        } else if phase == .transcribing {
            task?.cancel()
            task = nil
            stopClock()
            transition(.interrupted, state.id)
            message = String(localized: "Sending stopped. The recording is saved.")
            recordJournalFailure(message)
        }
    }

    /// A locked screen cannot receive a paste, but an upload already under way can still finish:
    /// the transcript then stays on the clipboard instead of being thrown away.
    func screenLocked() {
        let sending = phase == .transcribing || (phase == .stopping && state.stopHoldReason == nil)
        if sending { capturedAutoPaste = false } else { interrupt(String(localized: "Screen locked. The recording is saved.")) }
    }

    func copy(_ text: String) { operations.copy(text) }

    /// Transcribes a failed journal entry again with the current model and copies the result.
    /// The current session's held recording goes through the regular retry instead.
    func retranscribe(_ id: UUID) {
        guard let journal, journal.entry(id)?.status == .failed, !journal.transcribing.contains(id) else { return }
        // The current session's recording goes through its own retry, never a second request.
        if id == journalID {
            if canRetry { retry() }
            return
        }
        guard let url = journal.audioURL(id) else { return }
        let engine = settings.engine
        let model = modelName(engine)
        let mode = settings.mode
        journal.setTranscribing(id, true)
        Task { [weak self] in
            defer { journal.setTranscribing(id, false) }
            guard let self else { return }
            do {
                let request = try self.transcriptionRequest(engine: engine, model: model, mode: mode)
                let text = TextDelivery.sanitized(try await request(url))
                guard !text.isEmpty else { throw AppError.message(String(localized: "No speech recognized.")) }
                journal.complete(id, text: text, model: model, keepAudio: self.settings.keepRecordings)
                self.operations.copy(text)
                self.telemetry?.track("retranscribe", ["result": .string("ok")])
            } catch {
                journal.fail(id, reason: error.localizedDescription)
                self.telemetry?.track("retranscribe", ["result": .string(Telemetry.reason(for: error))])
            }
        }
    }

    func deleteJournalEntry(_ id: UUID) {
        if id == journalID { cancel() }
        journal?.delete(id)
    }

    func clearJournal() {
        guard !phase.busy else { return }
        if journalID != nil { cancel() }
        journal?.clear()
    }

    private func captureEngine() {
        capturedEngine = settings.engine
        capturedModel = modelName(capturedEngine)
        capturedMode = settings.mode
    }

    /// The model as the journal records it.
    private func modelName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .local: return LocalTranscriber.label
        case .openRouter: return settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The chosen engine can't work until the user connects OpenRouter.
    var needsSetup: Bool {
        settings.engine == .openRouter && !connection.isConnected
    }

    /// Resolves credentials up front, so a missing key fails before the indicator says "transcribing".
    private func transcriptionRequest(engine: TranscriptionEngine, model: String,
                                      mode: TranscriptionMode) throws -> (URL) async throws -> String {
        switch engine {
        case .local:
            return { [operations] url in try await operations.transcribeLocally(url) }
        case .openRouter:
            let key = try operations.apiKey()
            guard !model.isEmpty else { throw AppError.message(String(localized: "Choose a model in Settings.")) }
            return { [operations] url in try await operations.transcribe(url, key, model, mode) }
        }
    }

    private func recordJournalFailure(_ reason: String) {
        if let journalID { journal?.fail(journalID, reason: reason) }
    }

    func disconnect() {
        cancel()
        connection.cancel()
        do { try connection.disconnect() } catch { settingsError = error.localizedDescription }
    }

    private var previewing = false
    #if DEBUG
    /// App Store screenshots show the app set up, whatever this Mac has granted.
    func previewAsSetUp() {
        previewing = true
        microphoneGranted = true
        accessibilityGranted = true
        fnSwitchesInputSource = false
    }
    #endif

    func refreshPermissions() {
        guard !previewing else { return }
        let granted = HotkeyController.accessibilityGranted
        let changed = granted != accessibilityGranted
        accessibilityGranted = granted
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if granted { awaitingAccess = false; accessNeedsRelaunch = false }
        // Monitors installed before the grant never receive events; reinstall them once it arrives.
        if changed || !hotkeysConfigured { configureHotkeys() }
    }

    /// The user asked for keyboard access and went to System Settings.
    private var awaitingAccess = false
    private var hotkeysConfigured = false
    /// macOS may only apply a fresh keyboard grant to a new process. Once the user is back from
    /// System Settings and access still reads as missing, the fix is a relaunch.
    @Published private(set) var accessNeedsRelaunch = false

    /// The app is frontmost again, typically after System Settings.
    func appBecameActive() {
        refreshPermissions()
        if awaitingAccess && !accessibilityGranted { accessNeedsRelaunch = true }
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--relaunched"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// macOS shows its permission prompt once; after that, the button opens the right pane.
    func requestAccessibility() {
        let key = "keyboardAccessRequested"
        awaitingAccess = true
        if UserDefaults.standard.bool(forKey: key) {
            openPrivacySettings(SystemAccess.settingsPane)
        } else {
            UserDefaults.standard.set(true, forKey: key)
            HotkeyController.requestAccessibility()
        }
        refreshPermissions()
    }

    func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestMicrophone() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self?.microphoneGranted = granted
            if !granted { self?.openPrivacySettings("Privacy_Microphone") }
        }
    }

    func refreshDevices() { devices = AudioRecorder.availableDevices() }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { SMAppService.openSystemSettingsLoginItems() }
        } catch { settingsError = String(localized: "Couldn’t change Open at Login: \(error.localizedDescription)") }
    }

    func configureHotkeys() { configureHotkeys(trigger: settings.trigger, shortcut: settings.shortcut) }

    private func configureHotkeys(trigger: DictationTrigger, shortcut: ShortcutBinding) {
        guard systemIntegrationEnabled, !isCapturingShortcut else { return }
        do {
            try hotkeys.configure(soloKey: trigger.soloKey, shortcut: trigger == .shortcut ? shortcut : nil)
            hotkeysConfigured = true
            triggerKeySeen = false
            if trigger != .fn { fnSwitchesInputSource = false }
            shortcutError = nil
        } catch { shortcutError = error.localizedDescription }
    }

    func shutdown() {
        cancel()
        connection.cancel()
        hotkeys.stop()
    }

    /// Ends the session as if it never happened, without the failure capsule.
    private func dismissQuietly() {
        journalID = nil
        discardFile()
        stopClock()
        target = nil
        message = ""
        state.reset()
        publishPhase()
        onHideOverlay?()
    }

    private func fail(_ detail: String, session: UUID) {
        stopClock()
        message = detail
        recordJournalFailure(detail)
        // A retry may fail to load credentials while already in failed/interrupted state.
        if phase != .failed && phase != .interrupted { transition(.failed, session) }
        onShowOverlay?()
    }

    private func transition(_ phase: DictationPhase, _ session: UUID) {
        if state.transition(to: phase, for: session) { publishPhase() }
    }

    private func publishPhase() {
        phase = state.phase
        if phase == .idle && showConflictWhenIdle {
            showConflictWhenIdle = false
            onFnConflict?()
        }
    }

    // MARK: Fn conflicts

    private func inputSourceConflictChanged(_ conflict: Bool) {
        let dismissed = UserDefaults.standard.bool(forKey: Self.conflictDismissedKey)
        fnSwitchesInputSource = conflict && settings.trigger == .fn && !dismissed
        guard fnSwitchesInputSource else { return }
        telemetry?.track("fn_switches_input_source")
        // Opening a window mid-dictation would take focus from the app the text goes to.
        if phase == .idle { onFnConflict?() } else { showConflictWhenIdle = true }
    }

    func dismissFnConflict() {
        UserDefaults.standard.set(true, forKey: Self.conflictDismissedKey)
        fnSwitchesInputSource = false
        showConflictWhenIdle = false
    }

    func useRightOption() {
        settings.trigger = .rightOption
        fnSwitchesInputSource = false
        showConflictWhenIdle = false
        telemetry?.track("trigger_fallback", ["trigger": .string(DictationTrigger.rightOption.rawValue)])
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    private func startClock() {
        stopClock()
        startedAt = Date()
        elapsed = 0
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                if self.phase == .recording && self.elapsed >= 300 {
                    self.finishRecording(send: false, interruption: String(localized: "5-minute limit reached. The recording is saved."))
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopClock() { timer?.invalidate(); timer = nil; startedAt = nil }

    private func scheduleDismiss(session: UUID) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.state.accepts(session), self.phase == .delivered else { return }
            self.state.reset()
            self.publishPhase()
            self.onHideOverlay?()
        }
    }

    private func discardFile() {
        if let fileURL, !journalOwnsFile { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        journalOwnsFile = false
        hasSavedRecording = false
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

/// The coordinator's side effects are injectable so race tests never access user audio or credentials.
@MainActor
struct AppModelOperations {
    let startRecording: (String?) async throws -> Void
    let stopRecording: () async throws -> URL
    /// How long the recording that just stopped held sound louder than silence, if known.
    var recordingVoicedSeconds: () -> Double? = { nil }
    let cancelRecording: () -> Void
    let apiKey: () throws -> String
    let transcribe: (URL, String, String, TranscriptionMode) async throws -> String
    var transcribeLocally: (URL) async throws -> String = { _ in throw LocalTranscriberError.notReady }
    let captureTarget: () async -> TextTarget?
    let deliver: (String, TextTarget?, Bool) async -> DeliveryOutcome
    let copy: (String) -> Void
}

/// Recordings without speech (a tap of the key, silence, a key click) are dropped before they
/// reach the network. Only how long the recording held sound matters, not how long it ran,
/// so a quick word still goes through.
struct SpeechGate: Equatable {
    var minimumVoicedSeconds: Double

    static let standard = SpeechGate(minimumVoicedSeconds: 0.05)
    static let off = SpeechGate(minimumVoicedSeconds: 0)

    /// The reason to drop the recording, or nil to send it. An unknown measure never drops it.
    func reject(voicedSeconds: Double?) -> String? {
        guard let voicedSeconds, voicedSeconds < minimumVoicedSeconds else { return nil }
        return "no_speech"
    }
}
