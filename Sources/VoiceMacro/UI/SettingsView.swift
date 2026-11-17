import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var connection: OpenRouterConnection
    @ObservedObject var localModel: LocalTranscriber
    var openHistory: () -> Void
    @State private var editingCustomModel = false
    @State private var confirmingConnect = false
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static let presets = AppSettings.modelPresets
    @AppStorage(Telemetry.enabledKey) private var shareStatistics = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                KeyCap(label: settings.keyCapLabel, showsGlobe: settings.trigger == .fn, size: 64,
                       active: model.phase == .recording)
                Text(settings.trigger == .fn ? "Press fn to dictate" : "Press \(settings.triggerName) to dictate")
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 34)
            .padding(.bottom, 6)
            if let missing = missingPermission {
                warning {
                    Text(missing.text).font(.callout)
                    Spacer()
                    Button(missing.action, action: missing.request).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if model.fnSwitchesInputSource {
                warning {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("fn also switches your keyboard language").font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            Button("Keyboard Settings", action: model.openKeyboardSettings).buttonStyle(.borderedProminent)
                            Button("Use Right ⌥", action: model.useRightOption)
                        }.controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    Button { model.dismissFnConflict() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help(Text("Don’t Show Again"))
                }
            }
            Form {
                Section {
                    Picker("Key", selection: $settings.trigger) {
                        Text(verbatim: "fn").tag(DictationTrigger.fn)
                        Text("Right ⌥").tag(DictationTrigger.rightOption)
                        Text("Custom Shortcut").tag(DictationTrigger.shortcut)
                    }
                    if settings.trigger == .shortcut {
                        LabeledContent("Shortcut") { ShortcutRecorder(model: model, settings: settings) }
                    }
                    Picker("Microphone", selection: $settings.microphoneUID) {
                        Text("System Default").tag("")
                        ForEach(model.devices) { Text(verbatim: $0.name).tag($0.id) }
                        if !settings.microphoneUID.isEmpty && !model.devices.contains(where: { $0.id == settings.microphoneUID }) {
                            Text("Unavailable Microphone").tag(settings.microphoneUID)
                        }
                    }
                    Picker("Recognition", selection: Binding(get: { recognition }, set: chooseRecognition)) {
                        Text("On This Mac").tag("local")
                        Divider()
                        ForEach(Self.presets, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                        Text("Other…").tag("custom")
                    }
                    if settings.engine == .local { localStatus }
                    if recognition == "custom" {
                        TextField("Model ID", text: $settings.model, prompt: Text(verbatim: "provider/model"))
                        Picker("API", selection: $settings.mode) {
                            Text("Audio in Chat").tag(TranscriptionMode.audioChat)
                            Text("Speech to Text").tag(TranscriptionMode.speechToText)
                        }
                    }
                }
                .disabled(model.phase.busy)
                Section {
                    if settings.engine == .openRouter { openRouterRow }
                    Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Toggle("Share Anonymous Usage Statistics", isOn: $shareStatistics)
                }
                Section {
                    Button(action: openHistory) {
                        HStack {
                            Text("Dictation History").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle("Keep Audio Recordings", isOn: $settings.keepRecordings)
                }
                if let error = connection.errorMessage ?? model.settingsError ?? model.shortcutError {
                    Section { Text(verbatim: error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 460, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(permissionPoll) { _ in if missingPermission != nil { model.refreshPermissions() } }
        .onAppear {
            model.refreshDevices()
            model.refreshPermissions()
            editingCustomModel = !Self.presets.contains { $0.id == settings.model }
        }
    }

    private var height: CGFloat {
        var height: CGFloat = 530
        if missingPermission != nil { height += 60 }
        if model.fnSwitchesInputSource { height += 80 }
        if settings.engine == .local { height += localModel.isReady ? -44 : 0 }
        if recognition == "custom" { height += 88 }
        return height
    }

    /// Only while the on-device model is not usable yet.
    @ViewBuilder private var localStatus: some View {
        switch localModel.state {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            LabeledContent("Downloading Model") { ProgressView(value: fraction).frame(width: 140) }
        case .preparing:
            LabeledContent("Preparing Model…") { ProgressView().controlSize(.small) }
        case .notDownloaded:
            LabeledContent("Model Not Downloaded") { Button("Download") { localModel.prepare() } }
        case .failed:
            LabeledContent("Model Didn’t Load") { Button("Retry") { localModel.prepare() } }
        }
    }

    private var openRouterRow: some View {
        LabeledContent {
            if connection.isConnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { connection.cancel() }.buttonStyle(.link)
                }
            } else if connection.isConnected {
                Button("Disconnect") { model.disconnect() }.buttonStyle(.link)
            } else {
                // Apple requires consent before voice goes to a third-party AI service.
                Button("Connect") { confirmingConnect = true }.buttonStyle(.borderedProminent)
                    .confirmationDialog("Your voice is sent to OpenRouter and the model’s provider to become text.",
                                        isPresented: $confirmingConnect) {
                        Button("Connect") { Task { await connection.connect() } }
                    }
            }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: "OpenRouter")
                Circle().fill(connection.isConnected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            }
        }
    }

    private func warning<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var missingPermission: (text: LocalizedStringKey, action: LocalizedStringKey, request: () -> Void)? {
        if !model.microphoneGranted { return ("VoiceFn needs microphone access", "Allow", model.requestMicrophone) }
        if !model.accessibilityGranted {
            return model.accessNeedsRelaunch
                ? ("VoiceFn needs keyboard access", "Relaunch", model.relaunch)
                : ("VoiceFn needs keyboard access", "Allow", model.requestAccessibility)
        }
        return nil
    }

    private var recognition: String {
        switch settings.engine {
        case .local: return "local"
        case .openRouter: return preset
        }
    }

    private func chooseRecognition(_ value: String) {
        if value == "local" {
            settings.engine = .local
            editingCustomModel = false
        } else {
            settings.engine = .openRouter
            choosePreset(value)
        }
    }

    private var preset: String {
        editingCustomModel || !Self.presets.contains { $0.id == settings.model } ? "custom" : settings.model
    }

    /// "Other…" only reveals the ID field; the current model stays as the starting value.
    private func choosePreset(_ value: String) {
        editingCustomModel = value == "custom"
        if !editingCustomModel { settings.chooseModel(value) }
    }
}

struct ShortcutRecorder: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var monitor: Any?

    var body: some View {
        Button {
            if model.isCapturingShortcut { stop() } else { begin() }
        } label: {
            if model.isCapturingShortcut { Text("Press keys… Esc cancels") } else { Text(verbatim: settings.shortcut.displayName) }
        }
        .onDisappear { stop() }
    }

    private func begin() {
        model.isCapturingShortcut = true
        model.hotkeys.stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            do {
                let binding = ShortcutBinding(event: event)
                try binding.validate()
                settings.shortcut = binding
                model.settingsError = nil
                stop()
            } catch { model.settingsError = error.localizedDescription }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard model.isCapturingShortcut else { return }
        model.isCapturingShortcut = false
        model.configureHotkeys()
    }
}
