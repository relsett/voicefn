import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class OpenRouterConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?

    private let keychain: any OpenRouterCredentialStore
    private var cachedKey: String?
    private var attemptID: UUID?
    private var connectionTask: Task<Void, Never>?
    private var browserSession: ASWebAuthenticationSession?
    private var callbackServer: OpenRouterCallbackServer?
    private var anchor: NSWindow?

    init(loadStoredConnection: Bool = true, keychain: any OpenRouterCredentialStore = KeychainStore()) {
        self.keychain = keychain
        super.init()
        guard loadStoredConnection else { return }
        do { isConnected = try keychain.containsKey() }
        catch { errorMessage = error.localizedDescription }
    }

    func apiKey() throws -> String {
        if let cachedKey { return cachedKey }
        guard let key = try keychain.read() else { throw OpenRouterError.notConnected }
        cachedKey = key
        isConnected = true
        errorMessage = nil
        return key
    }

    func connect() async {
        guard !isConnecting else { return }
        let id = UUID()
        attemptID = id
        isConnecting = true
        errorMessage = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performConnection(id: id)
        }
        connectionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard self?.attemptID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        attemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        callbackServer?.cancel()
        callbackServer = nil
        browserSession?.cancel()
        browserSession = nil
        anchor = nil
        isConnecting = false
    }

    func disconnect() throws {
        cancel()
        try keychain.delete()
        cachedKey = nil
        isConnected = false
        errorMessage = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor = window
        return window
    }

    private func performConnection(id: UUID) async {
        defer {
            if attemptID == id {
                attemptID = nil
                callbackServer?.cancel()
                callbackServer = nil
                browserSession?.cancel()
                browserSession = nil
                anchor = nil
                connectionTask = nil
                isConnecting = false
            }
        }
        do {
            try checkActive(id)
            let verifier = try OpenRouterPKCE.randomToken()
            let state = try OpenRouterPKCE.randomToken()
            let server = OpenRouterCallbackServer(state: state)
            callbackServer = server
            let callback = try await server.start()
            try checkActive(id)
            let url = OpenRouterPKCE.authorizationURL(callback: callback, verifier: verifier)
            let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.attemptID == id, self.browserSession != nil else { return }
                    if let error {
                        if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            self.cancel()
                        } else {
                            self.errorMessage = OpenRouterError.browserUnavailable.localizedDescription
                            self.cancel()
                        }
                    }
                }
            }
            browser.presentationContextProvider = self
            browserSession = browser
            guard browser.start() else { throw OpenRouterError.browserUnavailable }
            let code = try await server.waitForCode()
            try checkActive(id)
            // Ignore the browser's cancellation callback once loopback has supplied the code.
            browserSession = nil
            browser.cancel()
            let request = try OpenRouterPKCE.exchangeRequest(code: code, verifier: verifier)
            let data = try await OpenRouterHTTP.perform(request, maximumBytes: 64 * 1_024)
            try checkActive(id)
            struct KeyResponse: Decodable { let key: String }
            let response = try JSONDecoder().decode(KeyResponse.self, from: data)
            guard !response.key.isEmpty, response.key.count <= 4_096 else { throw OpenRouterError.invalidResponse }
            // No suspension between this check and the atomic Keychain update.
            try checkActive(id)
            try keychain.save(response.key)
            cachedKey = response.key
            isConnected = true
        } catch is CancellationError {
        } catch {
            if attemptID == id { errorMessage = error.localizedDescription }
        }
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard attemptID == id else { throw CancellationError() }
    }
}

enum OpenRouterPKCE {
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenRouterError.invalidCallback
        }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(callback: URL, verifier: String) -> URL {
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [URLQueryItem(name: "callback_url", value: callback.absoluteString),
                          URLQueryItem(name: "code_challenge", value: challenge(verifier)),
                          URLQueryItem(name: "code_challenge_method", value: "S256"),
                          URLQueryItem(name: "key_label", value: "VoiceFn")]
        return url.url!
    }

    static func exchangeRequest(code: String, verifier: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256"
        ])
        return request
    }

    static func callbackCode(target: String, path: String, state: String) throws -> String {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let url = URLComponents(string: "http://127.0.0.1\(target)"), url.path == path,
              url.fragment == nil else { throw OpenRouterError.invalidCallback }
        let states = url.queryItems?.filter { $0.name == "state" } ?? []
        let codes = url.queryItems?.filter { $0.name == "code" } ?? []
        guard states.count == 1, states.first?.value == state,
              codes.count == 1, let code = codes.first?.value, !code.isEmpty, code.count <= 4_096,
              !(url.queryItems?.contains { $0.name == "error" } ?? false) else {
            throw OpenRouterError.invalidCallback
        }
        return code
    }
}

@MainActor
final class OpenRouterCallbackServer {
    private let state: String
    private let path: String
    private let timeout: TimeInterval
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var readTimers: [UUID: Task<Void, Never>] = [:]
    private var deadline: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var accepted = false
    private let queue = DispatchQueue(label: "app.voicemacro.oauth-loopback")

    init(state: String, timeout: TimeInterval = 180) {
        self.state = state
        self.path = "/callback/\(state)"
        self.timeout = timeout
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, self?.timeout ?? 180) * 1_000_000_000)) }
            catch { return }
            self?.finish(.failure(OpenRouterError.connectionTimeout))
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] listenerState in
            Task { @MainActor in
                guard let self, self.result == nil else { return }
                switch listenerState {
                case .ready:
                    guard let port = listener?.port else { return }
                    var url = URLComponents()
                    url.scheme = "http"
                    url.host = "127.0.0.1"
                    url.port = Int(port.rawValue)
                    url.path = self.path
                    url.queryItems = [URLQueryItem(name: "state", value: self.state)]
                    self.startContinuation?.resume(returning: url.url!)
                    self.startContinuation = nil
                case .failed:
                    self.finish(.failure(OpenRouterError.invalidCallback))
                default: break
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func waitForCode() async throws -> String {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { codeContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func accept(_ connection: NWConnection) {
        guard result == nil, !accepted, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        readTimers[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.close(id)
        }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil, self.result == nil else { return }
                var combined = buffer
                if let data { combined.append(data) }
                guard combined.count <= 16_384, error == nil else { self.close(id); return }
                if combined.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(combined, connection: connection, id: id)
                } else if complete {
                    self.close(id)
                } else {
                    self.receive(connection, id: id, buffer: combined)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let code: String?
        if parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", !accepted {
            code = try? OpenRouterPKCE.callbackCode(target: String(parts[1]), path: path, state: state)
        } else { code = nil }
        if code != nil { accepted = true }
        let body = code == nil ? "Invalid callback." : "Authorization received. You can return to VoiceFn."
        let status = code == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(id)
                if let code { self?.finish(.success(code)) }
            }
        })
    }

    private func close(_ id: UUID) {
        readTimers.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        if let continuation = startContinuation {
            startContinuation = nil
            switch result {
            case .success: continuation.resume(throwing: OpenRouterError.invalidCallback)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        codeContinuation?.resume(with: result)
        codeContinuation = nil
    }
}
