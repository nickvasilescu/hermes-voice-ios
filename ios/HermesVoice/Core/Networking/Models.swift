import Foundation

// Mirrors docs/PROTOCOL.md §4 "Task object" exactly. If you change a field
// here, update PROTOCOL.md and bridge/src/types.ts in the same change.

enum HermesTaskStatus: String, Codable, Equatable {
    case queued
    case running
    case waitingApproval = "waiting_approval"
    case completed
    case failed
    case canceled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: return true
        case .queued, .running, .waitingApproval: return false
        }
    }
}

struct HermesTaskProgress: Codable, Equatable {
    var percent: Double?
    var message: String?
}

struct HermesTaskError: Codable, Equatable {
    var message: String
    var code: String?
}

struct HermesPendingApproval: Codable, Equatable {
    var approvalId: String
    var action: String
    var details: [String: AnyCodable]?
    var requestedAt: String
}

struct HermesTaskHistoryEntry: Codable, Equatable, Identifiable {
    var at: String
    var kind: String
    var message: String

    var id: String { at + kind }
}

struct HermesTask: Codable, Equatable, Identifiable {
    var id: String
    var hermesSessionId: String
    var status: HermesTaskStatus
    var instruction: String
    var summary: String?
    var progress: HermesTaskProgress?
    var result: AnyCodable?
    var error: HermesTaskError?
    var pendingApproval: HermesPendingApproval?
    var createdAt: String
    var updatedAt: String
    var history: [HermesTaskHistoryEntry]
}

struct RealtimeClientSecret: Codable, Equatable {
    var value: String
    var expiresAt: String
}

struct RealtimeSessionResponse: Codable, Equatable {
    var sessionId: String
    var model: String
    var clientSecret: RealtimeClientSecret
    var createdAt: String
    var expiresInSeconds: Int
}

/// Response of `POST /v1/session` (PROTOCOL.md §2/§4) — a freshly minted
/// client session. `sessionToken` is handed to `ClientSessionManager`,
/// which is the only thing that ever persists it (to Keychain).
struct MintedClientSession: Codable, Equatable, Sendable {
    var sessionToken: String
    var hermesSessionId: String
    var expiresAt: String
}

/// Minimal type-erased Codable box, since `Task.result`/`context` are
/// intentionally opaque JSON on the wire (see PROTOCOL.md — Hermes results
/// are provider-specific and the app never interprets them structurally,
/// only narrates `summary`).
///
/// `@unchecked Sendable`: the only values ever boxed here are the direct
/// output of decoding JSON (Bool/Double/String/NSNull/[String: AnyCodable]/
/// [AnyCodable]) — all immutable value types with no shared mutable
/// reference state — so concurrent reads of an already-constructed
/// `AnyCodable` are safe. Nothing in this codebase constructs one from a
/// reference type.
struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? container.decode([AnyCodable].self) { value = v; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
