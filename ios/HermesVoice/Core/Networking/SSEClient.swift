import Foundation

/// A minimal Server-Sent Events reader for `GET /v1/events` (PROTOCOL.md
/// section 4). The URLSession-to-lines seam is injectable so response status,
/// EOF, transport failures, cancellation, and stale callbacks are covered by
/// deterministic unit tests rather than a live bridge.
struct SSEEvent: Equatable, Sendable {
    var name: String
    var data: String
}

struct SSEStreamResponse: Sendable {
    var statusCode: Int?
    var lines: AsyncThrowingStream<String, Error>
}

typealias SSEStreamOpener = @Sendable (URLRequest, URLSession) async throws -> SSEStreamResponse

actor SSEClient {
    private let openStream: SSEStreamOpener
    private var streamTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(openStream: @escaping SSEStreamOpener = { request, session in
        try await SSEClient.openURLSessionStream(request: request, session: session)
    }) {
        self.openStream = openStream
    }

    func connect(
        to url: URL,
        sessionToken: String,
        session: URLSession = .shared,
        onConnected: @escaping @Sendable () -> Void = {},
        onEvent: @escaping @Sendable (SSEEvent) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        generation &+= 1
        let connectionGeneration = generation
        streamTask?.cancel()

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "authorization")

        let opener = openStream
        streamTask = Task { [weak self] in
            do {
                let response = try await opener(request, session)
                guard let self, await self.isCurrent(connectionGeneration) else { return }
                guard let statusCode = response.statusCode else {
                    await self.finish(
                        generation: connectionGeneration,
                        error: BackendClientError.transport("SSE connect returned a non-HTTP response"),
                        onDisconnect: onDisconnect
                    )
                    return
                }
                guard (200..<300).contains(statusCode) else {
                    await self.finish(
                        generation: connectionGeneration,
                        error: BackendClientError.http(status: statusCode, code: nil, detail: nil),
                        onDisconnect: onDisconnect
                    )
                    return
                }

                onConnected()
                var eventName = "message"
                var dataLines: [String] = []

                for try await line in response.lines {
                    guard !Task.isCancelled, await self.isCurrent(connectionGeneration) else { return }
                    if line.isEmpty {
                        if !dataLines.isEmpty {
                            onEvent(SSEEvent(name: eventName, data: dataLines.joined(separator: "\n")))
                        }
                        eventName = "message"
                        dataLines = []
                        continue
                    }
                    // SSE comments are keep-alives and deliberately ignored.
                    if line.hasPrefix(":") { continue }
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                    }
                }

                guard !Task.isCancelled else { return }
                await self.finish(generation: connectionGeneration, error: nil, onDisconnect: onDisconnect)
            } catch {
                guard !Task.isCancelled, let self else { return }
                await self.finish(generation: connectionGeneration, error: error, onDisconnect: onDisconnect)
            }
        }
    }

    func disconnect() {
        generation &+= 1
        streamTask?.cancel()
        streamTask = nil
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    private func finish(
        generation candidate: UInt64,
        error: Error?,
        onDisconnect: @Sendable (Error?) -> Void
    ) {
        guard candidate == generation else { return }
        streamTask = nil
        onDisconnect(error)
    }

    nonisolated private static func openURLSessionStream(
        request: URLRequest,
        session: URLSession
    ) async throws -> SSEStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let producer = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
        return SSEStreamResponse(statusCode: statusCode, lines: lines)
    }
}
