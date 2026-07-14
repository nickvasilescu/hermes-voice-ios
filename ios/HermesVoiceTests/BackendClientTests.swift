import XCTest
@testable import HermesVoice

/// See SessionReducerTests.swift for the note on why these are written but
/// not run in this repo's environment. Uses a `URLProtocol` stub so it
/// never touches the network, matching bridge/test's fake-fetch approach.
final class BackendClientTests: XCTestCase {
    func testBootstrapSessionSendsNoAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let body = """
            {"sessionToken":"st_abc123","hermesSessionId":"hs_1","expiresAt":"2026-01-01T00:00:00.000Z"}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = makeClient()
        let minted = try await client.bootstrapSession()

        XCTAssertEqual(minted.sessionToken, "st_abc123")
        XCTAssertEqual(minted.hermesSessionId, "hs_1")
        XCTAssertEqual(capturedRequest?.url?.path, "/v1/session")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "authorization"), "bootstrap must not require a prior session token")
    }

    func testCreateTaskSendsExpectedHeadersAndBody() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let body = """
            {"id":"task_1","hermesSessionId":"hs_1","status":"queued","instruction":"book a table",
             "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","history":[]}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = makeClient()
        let task = try await client.createTask(sessionToken: "st_test", instruction: "book a table", context: nil, clientRequestId: "req-1")

        XCTAssertEqual(task.id, "task_1")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/v1/tasks")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "authorization"), "Bearer st_test")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "x-hermes-session-id"), "hermesSessionId must never be client-supplied — see docs/SECURITY.md")
    }

    func testNonSuccessStatusThrowsHTTPErrorWithParsedEnvelope() async {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data("{\"error\":\"task_not_found\"}".utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.getTask(sessionToken: "st_test", taskId: "task_missing")
            XCTFail("expected an error")
        } catch let BackendClientError.http(status, code, _) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(code, "task_not_found")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testListTasksUnwrapsTasksEnvelope() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.query, "status=running")
            let body = """
            {"tasks":[{"id":"task_1","hermesSessionId":"hs_1","status":"running","instruction":"x",
             "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","history":[]}]}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = makeClient()
        let tasks = try await client.listTasks(sessionToken: "st_test", status: .running)
        XCTAssertEqual(tasks.map(\.id), ["task_1"])
    }

    private func makeClient() -> BackendClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = BridgeConfig(baseURL: URL(string: "http://localhost:8787")!)
        return BackendClient(config: config, session: session)
    }
}

private final class StubURLProtocol: URLProtocol {
    /// `nonisolated(unsafe)`: `URLProtocol`'s class methods are invoked by
    /// `URLSession`'s internal machinery on threads Swift concurrency
    /// doesn't know about — this predates structured concurrency entirely.
    /// The escape hatch is scoped to just this property (not the whole
    /// type) and is safe in practice because each test sets `handler`,
    /// awaits its request to complete, then the next test overwrites it —
    /// XCTest runs test methods sequentially within a test case by
    /// default, so there is no actual concurrent access here, just no way
    /// to express that fact to the type system through `URLProtocol`'s
    /// pre-concurrency API.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
