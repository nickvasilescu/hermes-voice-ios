import Foundation

/// Talks to `bridge/` per docs/PROTOCOL.md §4. [IMPLEMENTED]
///
/// Everything here is a thin, testable HTTP client: no business logic, no
/// retry policy beyond what's documented, no secrets baked in.
/// `BridgeConfig` supplies only the base URL — there is no client-chosen
/// `hermesSessionId` and no bundled bearer token; every authenticated call
/// attaches whatever `ClientSessionManager` currently holds. See
/// docs/SECURITY.md.
protocol BackendClientProtocol: Sendable {
    /// `POST /v1/session`. Production bridges may require the operator-entered
    /// bootstrap credential; it is sent only in the Authorization header.
    func bootstrapSession(bootstrapCredential: String? = nil) async throws -> MintedClientSession
    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse
    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask
    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask
    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask]
    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask
    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask
    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask
}

enum ApprovalDecision: String, Codable {
    case approve
    case reject
}

enum BackendClientError: Error, Equatable {
    case transport(String)
    case http(status: Int, code: String?, detail: String?)
    case decoding(String)
}

struct BridgeConfig: Sendable {
    var baseURL: URL
}

/// An actor, not a class: proven-safe concurrent access to `URLSession`/
/// `JSONDecoder`/`JSONEncoder` needs no `@unchecked Sendable` escape hatch
/// when every method is already `async` and the type has no mutable
/// stored state to race on.
actor BackendClient: BackendClientProtocol {
    private let config: BridgeConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(config: BridgeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func bootstrapSession(bootstrapCredential: String? = nil) async throws -> MintedClientSession {
        try await send(path: "/v1/session", method: "POST", body: [:], sessionToken: bootstrapCredential)
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        var body: [String: Any] = [:]
        if let voice { body["voice"] = voice }
        return try await send(path: "/v1/realtime/session", method: "POST", body: body, sessionToken: sessionToken)
    }

    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask {
        var body: [String: Any] = ["instruction": instruction]
        if let context { body["context"] = context.mapValues { $0.value } }
        if let clientRequestId { body["clientRequestId"] = clientRequestId }
        return try await send(path: "/v1/tasks", method: "POST", body: body, sessionToken: sessionToken)
    }

    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask {
        try await send(path: "/v1/tasks/\(taskId)", method: "GET", body: nil, sessionToken: sessionToken)
    }

    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] {
        var path = "/v1/tasks"
        if let status { path += "?status=\(status.rawValue)" }
        let wrapper: TaskListResponse = try await send(path: path, method: "GET", body: nil, sessionToken: sessionToken)
        return wrapper.tasks
    }

    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask {
        try await send(path: "/v1/tasks/\(taskId)/followup", method: "POST", body: ["message": message], sessionToken: sessionToken)
    }

    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask {
        var body: [String: Any] = [:]
        if let reason { body["reason"] = reason }
        return try await send(path: "/v1/tasks/\(taskId)/cancel", method: "POST", body: body, sessionToken: sessionToken)
    }

    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask {
        var body: [String: Any] = ["approvalId": approvalId, "decision": decision.rawValue]
        if let note { body["note"] = note }
        return try await send(path: "/v1/tasks/\(taskId)/approve", method: "POST", body: body, sessionToken: sessionToken)
    }

    // MARK: - Plumbing

    private func send<T: Decodable>(path: String, method: String, body: [String: Any]?, sessionToken: String?) async throws -> T {
        guard let url = URL(string: path, relativeTo: config.baseURL) else {
            throw BackendClientError.transport("invalid URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw BackendClientError.http(status: http.statusCode, code: errorBody?.error, detail: errorBody?.detail)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BackendClientError.decoding(String(describing: error))
        }
    }
}

private struct TaskListResponse: Decodable {
    var tasks: [HermesTask]
}

private struct ErrorEnvelope: Decodable {
    var error: String
    var detail: String?
}
