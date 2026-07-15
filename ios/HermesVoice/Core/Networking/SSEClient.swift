import Foundation

/// A minimal Server-Sent Events reader for `GET /v1/events` (PROTOCOL.md
/// §4). [IMPLEMENTED] using `URLSession.bytes(for:)`, which is available on
/// iOS 15+. This is intentionally not a general-purpose SSE library — it
/// parses exactly the `event:`/`data:` framing the bridge emits.
struct SSEEvent: Equatable {
    var name: String
    var data: String
}

actor SSEClient {
    private var streamTask: Task<Void, Never>?

    func connect(
        to url: URL,
        sessionToken: String,
        session: URLSession = .shared,
        onEvent: @escaping @Sendable (SSEEvent) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        streamTask?.cancel()
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "authorization")

        streamTask = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    onDisconnect(BackendClientError.transport("SSE connect failed"))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    onDisconnect(BackendClientError.http(status: http.statusCode, code: nil, detail: nil))
                    return
                }

                var eventName = "message"
                var dataLines: [String] = []

                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.isEmpty {
                        if !dataLines.isEmpty {
                            onEvent(SSEEvent(name: eventName, data: dataLines.joined(separator: "\n")))
                        }
                        eventName = "message"
                        dataLines = []
                        continue
                    }
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                    }
                }
                onDisconnect(nil)
            } catch {
                if Task.isCancelled { return }
                onDisconnect(error)
            }
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
    }
}
