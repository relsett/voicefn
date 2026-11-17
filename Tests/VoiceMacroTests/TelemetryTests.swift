import Foundation
import XCTest
@testable import VoiceMacro

@MainActor
final class TelemetryTests: XCTestCase {
    private actor Recorder {
        var requests: [URLRequest] = []
        var statuses: [Int] = []
        func record(_ request: URLRequest) -> Int {
            requests.append(request)
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        func respond(with statuses: [Int]) { self.statuses = statuses }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "VoiceMacroTests.telemetry.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ recorder: Recorder) -> Telemetry {
        Telemetry(defaults: defaults) { request in await recorder.record(request) }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testEndpointFollowsTheAppKeyRegion() {
        XCTAssertEqual(Telemetry.endpoint(appKey: "A-EU-1234567890", host: nil)?.absoluteString,
                       "https://eu.aptabase.com/api/v0/events")
        XCTAssertEqual(Telemetry.endpoint(appKey: "A-US-1234567890", host: nil)?.absoluteString,
                       "https://us.aptabase.com/api/v0/events")
        XCTAssertEqual(Telemetry.endpoint(appKey: "A-SH-1234567890", host: "https://stats.example.com/")?.absoluteString,
                       "https://stats.example.com/api/v0/events")
        XCTAssertNil(Telemetry.endpoint(appKey: "A-SH-1234567890", host: nil))
        XCTAssertNil(Telemetry.endpoint(appKey: "", host: nil))
        XCTAssertNil(Telemetry.endpoint(appKey: "not-a-key", host: nil))
    }

    func testNothingIsQueuedWithoutAKeyOrWhenTurnedOff() async {
        let recorder = Recorder()
        let telemetry = make(recorder)
        telemetry.track("app_started")
        XCTAssertTrue(telemetry.queue.isEmpty)

        telemetry.configure(appKey: "A-EU-1234567890", host: nil)
        defaults.set(false, forKey: Telemetry.enabledKey)
        telemetry.track("app_started")
        telemetry.flush()
        await settle()
        XCTAssertTrue(telemetry.queue.isEmpty)
        let sent = await recorder.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testBatchIsPostedInAptabaseFormat() async throws {
        let recorder = Recorder()
        let telemetry = make(recorder)
        telemetry.configure(appKey: "A-EU-1234567890", host: nil)
        telemetry.track("dictation_completed", ["outcome": .string("pasted"), "seconds": .double(2.5), "attempt": .int(1)])
        telemetry.flush()
        await settle()

        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "App-Key"), "A-EU-1234567890")
        let body = try XCTUnwrap(request.httpBody)
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event["eventName"] as? String, "dictation_completed")
        XCTAssertNotNil(event["sessionId"] as? String)
        let timestamp = try XCTUnwrap(event["timestamp"] as? String)
        XCTAssertNotNil(timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression))
        let props = try XCTUnwrap(event["props"] as? [String: Any])
        XCTAssertEqual(props["outcome"] as? String, "pasted")
        XCTAssertEqual(props["seconds"] as? Double, 2.5)
        let system = try XCTUnwrap(event["systemProps"] as? [String: Any])
        XCTAssertEqual(system["osName"] as? String, "macOS")
        XCTAssertTrue(telemetry.queue.isEmpty)
    }

    func testServerErrorKeepsTheBatchAndRejectionDropsIt() async {
        let recorder = Recorder()
        await recorder.respond(with: [503, 400])
        let telemetry = make(recorder)
        telemetry.configure(appKey: "A-EU-1234567890", host: nil)
        telemetry.track("app_started")

        telemetry.flush()
        await settle()
        XCTAssertEqual(telemetry.queue.map(\.eventName), ["app_started"], "A 5xx response is retried later")

        telemetry.flush()
        await settle()
        XCTAssertTrue(telemetry.queue.isEmpty, "A 4xx response is not retried")
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testFailureReasonsAreCoarse() {
        XCTAssertEqual(Telemetry.reason(for: OpenRouterError.httpStatus(402)), "http_402")
        XCTAssertEqual(Telemetry.reason(for: OpenRouterError.notConnected), "not_connected")
        XCTAssertEqual(Telemetry.reason(for: URLError(.notConnectedToInternet)), "network")
        XCTAssertEqual(Telemetry.reason(for: AppError.message("Anything the user said")), "other")
        XCTAssertEqual(AppSettings.modelLabel("someone/private-model"), "custom")
        XCTAssertEqual(AppSettings.modelLabel("google/gemini-3.5-flash-lite"), "google/gemini-3.5-flash-lite")
    }
}

@MainActor
final class TelemetryActiveDayTests: XCTestCase {
    func testActiveDayIsSentOncePerDayWithInstallAge() {
        let suite = "VoiceMacroTests.activeDay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let telemetry = Telemetry(defaults: defaults) { _ in 200 }
        telemetry.configure(appKey: "A-EU-1234567890", host: nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: 1_790_000_000)

        telemetry.trackActiveDay(now: day0, calendar: calendar)
        telemetry.trackActiveDay(now: day0.addingTimeInterval(3_600), calendar: calendar)
        telemetry.trackActiveDay(now: day0.addingTimeInterval(86_400 * 3), calendar: calendar)
        telemetry.trackActiveDay(now: day0.addingTimeInterval(86_400 * 40), calendar: calendar)

        let sent = telemetry.queue.filter { $0.eventName == "active_day" }
        XCTAssertEqual(sent.map { $0.props["install_age"] }, [.string("0"), .string("2-7"), .string("30+")])
    }

    func testAgeBuckets() {
        XCTAssertEqual([0, 1, 2, 7, 8, 30, 31].map(Telemetry.ageBucket(days:)), ["0", "1", "2-7", "2-7", "8-30", "8-30", "30+"])
    }
}
