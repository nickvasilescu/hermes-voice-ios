import XCTest
@testable import HermesVoice

final class SSEClientTests: XCTestCase {
    func testHTTP401IsReportedAndNeverMarkedConnected() async {
        let disconnected = expectation(description: "401 delivered")
        let connected = expectation(description: "401 is never connected")
        connected.isInverted = true
        let client = SSEClient { _, _ in
            SSEStreamResponse(statusCode: 401, lines: Self.finishedStream())
        }

        await client.connect(
            to: URL(string: "https://bridge.invalid/v1/events")!,
            sessionToken: "st_rejected",
            onConnected: { connected.fulfill() },
            onEvent: { _ in XCTFail("401 response cannot produce events") },
            onDisconnect: { error in
                guard let error,
                      case BackendClientError.http(status: 401, code: _, detail: _) = error else {
                    return XCTFail("expected HTTP 401, got \(String(describing: error))")
                }
                disconnected.fulfill()
            }
        )

        await fulfillment(of: [disconnected, connected], timeout: 0.2)
    }

    func testParsesMultilineEventAndReportsCleanEOF() async {
        let connected = expectation(description: "connected")
        let eventReceived = expectation(description: "event")
        let disconnected = expectation(description: "EOF")
        let lines = Self.stream([
            ": keep-alive",
            "event: task.updated",
            "data: {\"line\":1}",
            "data: {\"line\":2}",
            "",
        ])
        let client = SSEClient { _, _ in SSEStreamResponse(statusCode: 200, lines: lines) }

        await client.connect(
            to: URL(string: "https://bridge.invalid/v1/events")!,
            sessionToken: "st_ok",
            onConnected: { connected.fulfill() },
            onEvent: { event in
                XCTAssertEqual(event, SSEEvent(name: "task.updated", data: "{\"line\":1}\n{\"line\":2}"))
                eventReceived.fulfill()
            },
            onDisconnect: { error in
                XCTAssertNil(error)
                disconnected.fulfill()
            }
        )

        await fulfillment(of: [connected, eventReceived, disconnected], timeout: 1)
    }

    func testReplacingConnectionSuppressesLateEventsAndDisconnectFromRetiredStream() async {
        let source = StreamSource()
        let newConnected = expectation(description: "new stream connected")
        let newEvent = expectation(description: "new event delivered")
        let staleEvent = expectation(description: "stale event suppressed")
        staleEvent.isInverted = true
        let staleDisconnect = expectation(description: "stale disconnect suppressed")
        staleDisconnect.isInverted = true
        let client = SSEClient { request, _ in
            await source.open(token: request.value(forHTTPHeaderField: "authorization") ?? "")
        }

        await client.connect(
            to: URL(string: "https://bridge.invalid/v1/events")!,
            sessionToken: "old",
            onEvent: { _ in staleEvent.fulfill() },
            onDisconnect: { _ in staleDisconnect.fulfill() }
        )
        await source.waitForOpenCount(1)

        await client.connect(
            to: URL(string: "https://bridge.invalid/v1/events")!,
            sessionToken: "new",
            onConnected: { newConnected.fulfill() },
            onEvent: { event in
                XCTAssertEqual(event.name, "task.updated")
                newEvent.fulfill()
            },
            onDisconnect: { _ in }
        )
        await source.waitForOpenCount(2)
        await source.sendEvent(index: 0, name: "task.updated", data: "old")
        await source.finish(index: 0)
        await source.sendEvent(index: 1, name: "task.updated", data: "new")

        await fulfillment(of: [newConnected, newEvent, staleEvent, staleDisconnect], timeout: 0.2)
        await client.disconnect()
    }

    private static func finishedStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func stream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

private actor StreamSource {
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    func open(token: String) -> SSEStreamResponse {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuations.append(continuation)
        }
        return SSEStreamResponse(statusCode: 200, lines: stream)
    }

    func waitForOpenCount(_ count: Int) async {
        while continuations.count < count { await Task.yield() }
    }

    func sendEvent(index: Int, name: String, data: String) {
        continuations[index].yield("event: \(name)")
        continuations[index].yield("data: \(data)")
        continuations[index].yield("")
    }

    func finish(index: Int) {
        continuations[index].finish()
    }
}
