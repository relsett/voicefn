import Foundation

/// Anonymous usage counts, sent in batches to Aptabase or a self-hosted Aptabase server.
///
/// Only event names and small enumerated or numeric properties ever leave the Mac: never a
/// transcript, audio, window title, app name or key. There is no user or device identifier;
/// a session is a random number that changes after an hour of inactivity, as in Aptabase's SDK.
/// The App Key comes from Info.plist (`VoiceFnTelemetryKey`); without one nothing is sent.
/// A self-hosted key (`A-SH-…`) also needs `VoiceFnTelemetryHost`.
@MainActor
final class Telemetry {
    static let shared = Telemetry()
    static let enabledKey = "shareUsageStatistics"
    private static let installDateKey = "telemetryInstallDate"
    private static let lastActiveDayKey = "telemetryLastActiveDay"

    enum Value: Encodable, Equatable, Sendable {
        case string(String), int(Int), double(Double), bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    struct Event: Encodable, Equatable, Sendable {
        struct System: Encodable, Equatable, Sendable {
            var isDebug: Bool
            var locale: String
            var osName = "macOS"
            var osVersion: String
            var appVersion: String
            var appBuildNumber: String
            var sdkVersion = "voicefn-telemetry@1"
            var deviceModel: String
        }

        var timestamp: Date
        var sessionId: String
        var eventName: String
        var systemProps: System
        var props: [String: Value]
    }

    static let batchSize = 25
    static let queueLimit = 500
    private static let sessionTimeout: TimeInterval = 60 * 60

    private(set) var endpoint: URL?
    private var appKey = ""
    private(set) var queue: [Event] = []
    private var sending = false
    private var timer: Timer?
    private var sessionId = Telemetry.newSessionId()
    private var lastEvent = Date()
    private let defaults: UserDefaults
    private let send: @Sendable (URLRequest) async throws -> Int

    init(defaults: UserDefaults = .standard,
         send: @escaping @Sendable (URLRequest) async throws -> Int = { request in
             let (_, response) = try await URLSession.shared.data(for: request)
             return (response as? HTTPURLResponse)?.statusCode ?? 0
         }) {
        self.defaults = defaults
        self.send = send
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Reads the key from the bundle; a missing or malformed key leaves telemetry off.
    func start(bundle: Bundle = .main) {
        recordInstallDate()
        let key = (bundle.object(forInfoDictionaryKey: "VoiceFnTelemetryKey") as? String) ?? ""
        let host = bundle.object(forInfoDictionaryKey: "VoiceFnTelemetryHost") as? String
        configure(appKey: key, host: host)
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func configure(appKey: String, host: String?) {
        endpoint = Self.endpoint(appKey: appKey, host: host)
        self.appKey = endpoint == nil ? "" : appKey
    }

    static func endpoint(appKey: String, host: String?) -> URL? {
        let parts = appKey.split(separator: "-")
        guard parts.count == 3, parts[0] == "A" else { return nil }
        let base: String?
        switch parts[1] {
        case "EU": base = "https://eu.aptabase.com"
        case "US": base = "https://us.aptabase.com"
        case "SH": base = host?.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        default: base = nil
        }
        guard let base, !base.isEmpty else { return nil }
        return URL(string: base + "/api/v0/events")
    }

    func track(_ name: String, _ props: [String: Value] = [:]) {
        guard endpoint != nil, isEnabled else { return }
        let now = Date()
        if now.timeIntervalSince(lastEvent) > Self.sessionTimeout { sessionId = Self.newSessionId() }
        lastEvent = now
        queue.append(Event(timestamp: now, sessionId: sessionId, eventName: name, systemProps: Self.system, props: props))
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        if queue.count >= Self.batchSize { flush() }
    }

    /// Daily and weekly active users without any identifier: each Mac reports `active_day` at most
    /// once per calendar day, remembered only locally, with a coarse age since installation, so
    /// the count of these events per day, week or month is the number of active Macs, and the age
    /// buckets show whether people keep coming back.
    func trackActiveDay(now: Date = Date(), calendar: Calendar = .current) {
        guard endpoint != nil, isEnabled else { return }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        let stamp = String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
        guard defaults.string(forKey: Self.lastActiveDayKey) != stamp else { return }
        let installed = recordInstallDate(now: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: installed),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        defaults.set(stamp, forKey: Self.lastActiveDayKey)
        track("active_day", ["install_age": .string(Self.ageBucket(days: days))])
    }

    nonisolated static func ageBucket(days: Int) -> String {
        switch days {
        case ..<1: return "0"
        case 1: return "1"
        case 2...7: return "2-7"
        case 8...30: return "8-30"
        default: return "30+"
        }
    }

    @discardableResult
    private func recordInstallDate(now: Date = Date()) -> Date {
        if let date = defaults.object(forKey: Self.installDateKey) as? Date { return date }
        defaults.set(now, forKey: Self.installDateKey)
        return now
    }

    /// Sends what is queued. A server error or a lost connection puts the batch back;
    /// a rejected request (4xx) is dropped, as Aptabase's SDK does.
    func flush() {
        guard !sending, let endpoint, !queue.isEmpty else { return }
        guard isEnabled else { queue.removeAll(); return }
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "App-Key")
        guard let body = try? Self.encoder.encode(batch) else { return }
        request.httpBody = body
        sending = true
        let send = self.send
        Task { [weak self] in
            let status = try? await send(request)
            guard let self else { return }
            self.sending = false
            if status.map({ $0 >= 500 }) ?? true {
                self.queue.insert(contentsOf: batch, at: 0)
                if self.queue.count > Self.queueLimit { self.queue.removeLast(self.queue.count - Self.queueLimit) }
            } else if !self.queue.isEmpty {
                self.flush()
            }
        }
    }

    /// A coarse reason for a failed dictation; never the message text.
    nonisolated static func reason(for error: Error) -> String {
        if let error = error as? OpenRouterError {
            switch error {
            case .notConnected: return "not_connected"
            case .httpStatus(let status): return "http_\(status)"
            case .emptyTranscript: return "empty"
            case .audioTooLarge, .invalidAudio: return "audio"
            case .invalidModel: return "model"
            default: return "openrouter"
            }
        }
        if error is URLError { return "network" }
        if error is AudioRecordingError { return "microphone" }
        return "other"
    }

    private static let system: Event.System = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return Event.System(
            isDebug: debug,
            locale: Locale.current.language.languageCode?.identifier ?? "",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuildNumber: info["CFBundleVersion"] as? String ?? "",
            deviceModel: hardwareModel())
    }()

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: model)
    }

    private static func newSessionId() -> String {
        String(UInt64(Date().timeIntervalSince1970) * 100_000_000 + UInt64.random(in: 0...99_999_999))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }()
}
