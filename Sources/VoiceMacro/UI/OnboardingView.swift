import AppKit
import Combine
import SwiftUI

/// The dictation key drawn as a keyboard key: the app's whole instruction in one picture.
struct KeyCap: View {
    var label: String = "fn"
    var showsGlobe = true
    var size: CGFloat = 92
    var active = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: size * (label.count > 2 ? 0.17 : 0.24), weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            if showsGlobe {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.19))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(size * 0.14)
        .frame(width: size, height: size, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .shadow(color: .black.opacity(0.25), radius: size * 0.08, y: size * 0.04)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: active ? 1.5 : 1)
        )
        .background(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.accentColor.opacity(active ? 0.25 : 0))
                .padding(-size * 0.07)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label) key"))
    }
}

/// First launch: four screens, one action each, ending with a real dictation.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var connection: OpenRouterConnection
    @ObservedObject var localModel: LocalTranscriber
    var finish: () -> Void
    @State var step = 0
    @State private var sample = ""
    /// The trigger key has not reached the app for a while on the last step.
    @State private var keyLooksMissing = false
    @FocusState private var sampleFocused: Bool
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == step ? Color.accentColor : Color.primary.opacity(index < step ? 0.35 : 0.15))
                        .frame(width: index == step ? 22 : 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.2), value: step)
            .accessibilityHidden(true)
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 30)
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .frame(width: 520, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(permissionPoll) { _ in if step == 1 { model.refreshPermissions() } }
        // The model downloads while the user reads and grants permissions.
        .onAppear { if settings.engine == .local { localModel.prepare() } }
        .onChange(of: step) { _, step in Telemetry.shared.track("onboarding_step", ["step": .int(step)]) }
        .onChange(of: model.lastTranscript) { _, text in
            if step == 2 && !text.isEmpty { sample = text }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        page(title: "Press fn and speak",
             subtitle: "Press it again, and the text appears where your cursor is.") {
            HStack(spacing: 22) {
                KeyCap()
                HStack(spacing: 5) {
                    ForEach([14, 30, 44, 26, 12], id: \.self) { height in
                        Capsule().fill(Color.accentColor).frame(width: 5, height: CGFloat(height))
                    }
                }
                HStack(spacing: 2) {
                    Text("Hello, how are you?")
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 18)
                }
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityHidden(true)
        } actions: {
            primary("Get Started") { step = 1 }
        }
    }

    private var permissions: some View {
        VStack(spacing: 0) {
            Text("Two permissions")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 44)
            Text("macOS asks only once.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            VStack(spacing: 10) {
                permissionRow("Microphone", detail: "to hear you", symbol: "mic.fill",
                              granted: model.microphoneGranted) { model.requestMicrophone() }
                permissionRow("Keyboard", detail: "to catch fn and paste text", symbol: "keyboard.fill",
                              granted: model.accessibilityGranted,
                              action: model.accessNeedsRelaunch ? "Relaunch" : "Allow") {
                    if model.accessNeedsRelaunch { model.relaunch() } else { model.requestAccessibility() }
                }
            }
            .padding(.top, 32)
            Spacer()
            primary("Continue", enabled: model.microphoneGranted && model.accessibilityGranted) { step = 2 }
            Button("Later") { step = 2 }.buttonStyle(.link).font(.callout).padding(.top, 12)
        }
    }

    @ViewBuilder private var tryIt: some View {
        if settings.engine == .local && !localModel.isReady && sample.isEmpty { gettingReady } else { tryDictating }
    }

    /// Shown only if the speech model is still downloading when the user reaches the last step.
    private var gettingReady: some View {
        page(title: "Getting ready", subtitle: readinessText) {
            VStack(spacing: 22) {
                KeyCap(label: settings.keyCapLabel, showsGlobe: settings.trigger == .fn)
                if case .downloading(let fraction) = localModel.state {
                    ProgressView(value: fraction).frame(width: 240)
                } else if case .failed = localModel.state {
                    EmptyView()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } actions: {
            if case .failed = localModel.state {
                primary("Retry") { localModel.prepare() }
            } else {
                primary("Done", action: finish)
            }
        }
    }

    private var readinessText: LocalizedStringKey {
        switch localModel.state {
        case .downloading: return "The speech model downloads once."
        case .failed: return "The speech model didn’t download."
        default: return "Preparing the speech model…"
        }
    }

    private var tryDictating: some View {
        page(title: sample.isEmpty ? "Try it" : "It works",
             subtitle: sample.isEmpty ? (settings.trigger == .fn ? "Press fn, say something, then press fn again."
                                                                  : "Press \(settings.triggerName), say something, then press it again.")
                                      : "VoiceFn lives in the menu bar. You can close this window.") {
            VStack(spacing: 22) {
                KeyCap(label: settings.keyCapLabel, showsGlobe: settings.trigger == .fn, active: model.phase == .recording)
                TextField("Your text appears here", text: $sample, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(width: 360)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(sample.isEmpty ? 0.3 : 0.9)))
                    .focused($sampleFocused)
            }
        } actions: {
            primary("Done", action: finish)
            if sample.isEmpty { keyHelp }
        }
        .onAppear { sampleFocused = true }
        .task(id: settings.trigger) {
            keyLooksMissing = false
            try? await Task.sleep(for: .seconds(8))
            if !model.triggerKeySeen && sample.isEmpty {
                keyLooksMissing = true
                Telemetry.shared.track("trigger_key_not_seen", ["trigger": .string(settings.trigger.rawValue)])
            }
        }
        .onChange(of: model.triggerKeySeen) { _, seen in if seen { keyLooksMissing = false } }
    }

    /// Fn problems show up here, where the user is pressing it for the first time, and only once
    /// they actually happen.
    @ViewBuilder private var keyHelp: some View {
        if settings.trigger == .fn && model.fnSwitchesInputSource {
            hint("fn also switches your keyboard language")
        } else if settings.trigger == .fn && keyLooksMissing {
            hint("Nothing happens when you press fn?")
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keyboard Settings", action: model.openKeyboardSettings)
                Button("Use Right ⌥", action: model.useRightOption)
            }.controlSize(.small)
        }
    }

    // MARK: Building blocks

    private func page<Visual: View, Actions: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                                    @ViewBuilder visual: () -> Visual,
                                                    @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            visual()
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(spacing: 12) { actions() }
                .padding(.top, 28)
        }
    }

    private func primary(_ title: LocalizedStringKey, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).frame(width: 220, height: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
    }

    private func permissionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String,
                               granted: Bool, action: LocalizedStringKey = "Allow",
                               request: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(action, action: request).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
