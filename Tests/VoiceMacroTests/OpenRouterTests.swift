import Foundation
import XCTest
@testable import VoiceMacro

final class OpenRouterTests: XCTestCase {
    private var wav: Data {
        var bytes = Data(repeating: 0, count: 48)
        bytes.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        bytes.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        return bytes
    }

    func testPKCEUsesRFC7636Vector() {
        XCTAssertEqual(OpenRouterPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationURLPreservesCallbackStateAndUsesS256() throws {
        let callback = URL(string: "http://127.0.0.1:12345/callback/token?state=token")!
        let url = OpenRouterPKCE.authorizationURL(callback: callback, verifier: "verifier")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "openrouter.ai")
        XCTAssertEqual(items.first { $0.name == "callback_url" }?.value, callback.absoluteString)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(url.absoluteString.contains("code_verifier"))
        let token = try OpenRouterPKCE.randomToken()
        XCTAssertEqual(token.count, 43)
        XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").inverted))
    }

    func testCallbackRejectsWrongPathMissingStateAndDuplicateValues() throws {
        XCTAssertEqual(try OpenRouterPKCE.callbackCode(target: "/callback/token?state=token&code=a%2Bb", path: "/callback/token", state: "token"), "a+b")
        for target in ["/wrong?state=token&code=a", "/callback/token?code=a",
                       "/callback/token?state=wrong&code=a", "/callback/token?state=token&code=",
                       "/callback/token?state=token&code=a&code=b", "/callback/token?state=token&state=token&code=a",
                       "//evil.test/callback/token?state=token&code=a",
                       "/callback/token?state=token&code=a&error=denied"] {
            XCTAssertThrowsError(try OpenRouterPKCE.callbackCode(target: target, path: "/callback/token", state: "token"), target)
        }
    }

    func testExchangeUsesVerifierInJSONOnly() throws {
        let request = try OpenRouterPKCE.exchangeRequest(code: "fake-code", verifier: "fake-verifier")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/auth/keys")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(body["code_verifier"], "fake-verifier")
        XCTAssertEqual(body["code_challenge_method"], "S256")
    }

    func testChatAndSTTUseDifferentEnvelopesForSameWAV() throws {
        let chat = try OpenRouterTranscriptionClient.makeRequest(audio: wav, apiKey: "fake-key", model: "google/test", mode: .audioChat)
        let chatBody = try XCTUnwrap(JSONSerialization.jsonObject(with: chat.httpBody!) as? [String: Any])
        XCTAssertEqual(chat.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(chat.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
        let messages = try XCTUnwrap(chatBody["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let chatAudio = try XCTUnwrap(content[0]["input_audio"] as? [String: String])
        XCTAssertEqual(chatAudio["format"], "wav")
        XCTAssertEqual(chatAudio["data"], wav.base64EncodedString())

        let stt = try OpenRouterTranscriptionClient.makeRequest(audio: wav, apiKey: "fake-key", model: "openai/test", mode: .speechToText)
        let sttBody = try XCTUnwrap(JSONSerialization.jsonObject(with: stt.httpBody!) as? [String: Any])
        XCTAssertEqual(stt.url?.path, "/api/v1/audio/transcriptions")
        XCTAssertEqual(sttBody["input_audio"] as? [String: String], chatAudio)
        XCTAssertEqual(sttBody["response_format"] as? String, "json")
        XCTAssertNil(sttBody["messages"])
    }

    func testFLACPayloadIsSplicedIntoValidJSONWithoutEscapedSlashes() throws {
        // Base64 of 0xFF bytes is all "/", which JSONSerialization would otherwise escape.
        var flac = Data("fLaC".utf8)
        flac.append(Data(repeating: 0xFF, count: 60))
        let request = try OpenRouterTranscriptionClient.makeRequest(audio: flac, apiKey: "fake-key", model: "google/test", mode: .audioChat)
        let raw = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(#"\/"#))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(body["temperature"] as? Int, 0)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let audio = try XCTUnwrap(content[0]["input_audio"] as? [String: String])
        XCTAssertEqual(audio["format"], "flac")
        XCTAssertEqual(audio["data"], flac.base64EncodedString())
    }

    func testOnlyFailuresBeforeModelOutputAreRetried() {
        for status in [429, 500, 502, 503, 504] { XCTAssertTrue(OpenRouterHTTP.isTransient(OpenRouterError.httpStatus(status))) }
        for status in [400, 401, 402, 404] { XCTAssertFalse(OpenRouterHTTP.isTransient(OpenRouterError.httpStatus(status))) }
        XCTAssertTrue(OpenRouterHTTP.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(OpenRouterHTTP.isTransient(URLError(.timedOut)))
        XCTAssertFalse(OpenRouterHTTP.isTransient(CancellationError()))
    }

    func testInvalidAudioAndMissingCredentialsAreRejectedBeforeSending() {
        XCTAssertThrowsError(try OpenRouterTranscriptionClient.makeRequest(audio: Data(), apiKey: "fake", model: "test", mode: .audioChat))
        XCTAssertThrowsError(try OpenRouterTranscriptionClient.makeRequest(audio: wav, apiKey: "", model: "test", mode: .audioChat))
        XCTAssertThrowsError(try OpenRouterTranscriptionClient.makeRequest(audio: wav, apiKey: "fake", model: "  ", mode: .audioChat))
    }

    func testParseTranscriptAndRejectEmptyMalformedAndTruncatedResponses() throws {
        XCTAssertEqual(try OpenRouterTranscriptionClient.parseResponse(Data(#"{"choices":[{"message":{"content":" Привет. "},"finish_reason":"stop"}]}"#.utf8), mode: .audioChat), "Привет.")
        XCTAssertEqual(try OpenRouterTranscriptionClient.parseResponse(Data(#"{"text":"Hello."}"#.utf8), mode: .speechToText), "Hello.")
        XCTAssertEqual(try OpenRouterTranscriptionClient.parseResponse(Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"Hello."}]}}]}"#.utf8), mode: .audioChat), "Hello.")
        for json in [#"{"choices":[]}"#, #"{"error":{"message":"oops"}}"#, #"{"choices":[{"message":{"content":" "}}]}"#,
                     #"{"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}"#] {
            XCTAssertThrowsError(try OpenRouterTranscriptionClient.parseResponse(Data(json.utf8), mode: .audioChat))
        }
        XCTAssertThrowsError(try OpenRouterTranscriptionClient.parseResponse(Data(#"{"text":" "}"#.utf8), mode: .speechToText))
    }

    @MainActor
    func testLoopbackRejectsInvalidStateThenAcceptsValidCode() async throws {
        let server = OpenRouterCallbackServer(state: "test-state", timeout: 5)
        let callback = try await server.start()
        defer { server.cancel() }
        XCTAssertEqual(callback.host, "127.0.0.1")
        var invalid = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        invalid.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "wrong-code")]
        let (_, rejectedResponse) = try await URLSession.shared.data(from: invalid.url!)
        XCTAssertEqual((rejectedResponse as? HTTPURLResponse)?.statusCode, 400)
        var valid = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        valid.queryItems!.append(URLQueryItem(name: "code", value: "test-code"))
        let (_, acceptedResponse) = try await URLSession.shared.data(from: valid.url!)
        XCTAssertEqual((acceptedResponse as? HTTPURLResponse)?.statusCode, 200)
        let code = try await server.waitForCode()
        XCTAssertEqual(code, "test-code")
    }

    @MainActor
    func testLoopbackCancellationFinishesWaiter() async throws {
        let server = OpenRouterCallbackServer(state: "test-state", timeout: 5)
        _ = try await server.start()
        let waiter = Task { try await server.waitForCode() }
        await Task.yield()
        server.cancel()
        server.cancel()
        do { _ = try await waiter.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testLoopbackTimesOutWithoutCallback() async throws {
        let server = OpenRouterCallbackServer(state: "test-state", timeout: 0.1)
        _ = try await server.start()
        do { _ = try await server.waitForCode(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? OpenRouterError, .connectionTimeout) }
    }
}
