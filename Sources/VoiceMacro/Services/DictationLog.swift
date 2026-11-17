import Foundation

/// One line of `dictations.jsonl`: a single attempt to transcribe a recording.
/// Timings, sizes and identifiers only — never the transcript, audio, window titles or keys.
struct DictationRecord: Encodable, Sendable {
    var time: Date
    var session: String
    var attempt: Int
    var app: String?
    var model: String
    var mode: String
    var autoPaste: Bool
    /// From the start key until the microphone was live; speech before that is not recorded.
    var startMs: Int?
    var recordingSeconds: Double?
    /// How much of the recording was louder than silence.
    var voicedSeconds: Double?
    var audioBytes: Int?
    /// Closing the recording file after the stop key.
    var stopMs: Int?
    /// Locating the paste target after the stop key; runs in parallel with `stopMs`.
    var captureMs: Int?
    /// From the stop key (or the retry) until the request is handed to the network.
    var beforeSendMs: Int?
    var transcribeMs: Int?
    var requests: [DictationRequestRecord] = []
    var generationId: String?
    var provider: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var transcriptChars: Int?
    var deliverMs: Int?
    var outcome: String?
    /// From the stop key (or the retry) until the text was delivered or the attempt ended.
    var totalMs: Int?
    var result: String
    var error: String?
}

/// One HTTP request to OpenRouter; a transient failure is retried once and logged separately.
struct DictationRequestRecord: Encodable, Sendable {
    var startMs: Int
    var bytesSent: Int
    var status: Int?
    var error: String?
    /// Until the response headers arrived: upload plus the model's work.
    var headersMs: Int?
    var totalMs: Int?
    // Phases of the final network transaction, from URLSessionTaskMetrics.
    var reusedConnection: Bool?
    var networkProtocol: String?
    var dnsMs: Int?
    var connectMs: Int?
    var tlsMs: Int?
    var uploadMs: Int?
    /// Request fully sent → first response byte: time spent at OpenRouter and the model.
    var serverMs: Int?
    var downloadMs: Int?
}

/// Collects what the network layer learns during one transcription attempt. The coordinator
/// binds it as a task local, so the operations' signatures stay unchanged.
final class TranscriptionTrace: @unchecked Sendable {
    @TaskLocal static var current: TranscriptionTrace?

    struct ResponseMetadata: Sendable {
        var generationId: String?
        var provider: String?
        var promptTokens: Int?
        var completionTokens: Int?
    }

    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var _requests: [DictationRequestRecord] = []
    private var _response = ResponseMetadata()

    var requests: [DictationRequestRecord] { lock.withLock { _requests } }
    var response: ResponseMetadata { lock.withLock { _response } }

    func beginRequest(bytesSent: Int) -> Int {
        let start = (ContinuousClock.now - origin).milliseconds
        return lock.withLock {
            _requests.append(DictationRequestRecord(startMs: start, bytesSent: bytesSent))
            return _requests.count - 1
        }
    }

    func updateRequest(_ index: Int, _ change: (inout DictationRequestRecord) -> Void) {
        lock.withLock {
            guard _requests.indices.contains(index) else { return }
            change(&_requests[index])
        }
    }

    func recordResponse(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let usage = object["usage"] as? [String: Any]
        lock.withLock {
            _response = ResponseMetadata(generationId: object["id"] as? String,
                                         provider: object["provider"] as? String,
                                         promptTokens: usage?["prompt_tokens"] as? Int,
                                         completionTokens: usage?["completion_tokens"] as? Int)
        }
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "URLError(\(error.code.rawValue))" }
        if let error = error as? OpenRouterError {
            if case .httpStatus(let status) = error { return "http \(status)" }
            return "\(error)"
        }
        let error = error as NSError
        return "\(error.domain)(\(error.code))"
    }
}

/// Fills the network phases of one request once URLSession has measured them.
final class TranscriptionMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trace: TranscriptionTrace
    private let index: Int

    init(trace: TranscriptionTrace, index: Int) {
        self.trace = trace
        self.index = index
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func span(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return Int((end.timeIntervalSince(start) * 1_000).rounded())
        }
        trace.updateRequest(index) { record in
            record.reusedConnection = transaction.isReusedConnection
            record.networkProtocol = transaction.networkProtocolName
            record.dnsMs = span(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
            record.connectMs = span(transaction.connectStartDate, transaction.connectEndDate)
            record.tlsMs = span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
            record.uploadMs = span(transaction.requestStartDate, transaction.requestEndDate)
            record.serverMs = span(transaction.requestEndDate, transaction.responseStartDate)
            record.downloadMs = span(transaction.responseStartDate, transaction.responseEndDate)
        }
    }

    // A task delegate is asked first; keep the session's no-redirect policy for these requests.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Appends records to `~/Library/Logs/VoiceMacro/dictations.jsonl` off the main thread.
/// The file is rotated once to `dictations.1.jsonl` when it exceeds `maximumBytes`.
final class DictationLog: Sendable {
    static let maximumBytes = 5 * 1_024 * 1_024
    static let standard: DictationLog? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        .map { DictationLog(directory: $0.appendingPathComponent("Logs/VoiceMacro", isDirectory: true)) }

    let fileURL: URL
    private let queue = DispatchQueue(label: "local.voicemacro.dictation-log", qos: .utility)

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("dictations.jsonl")
    }

    func append(_ record: DictationRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        queue.async { [fileURL] in Self.write(line, to: fileURL) }
    }

    /// Waits for queued writes; used by tests.
    func flush() { queue.sync {} }

    private static func write(_ line: Data, to url: URL) {
        let manager = FileManager.default
        do {
            let directory = url.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > maximumBytes {
                let previous = directory.appendingPathComponent("dictations.1.jsonl")
                try? manager.removeItem(at: previous)
                try manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch { /* Diagnostics must never affect dictation. */ }
    }
}

extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
