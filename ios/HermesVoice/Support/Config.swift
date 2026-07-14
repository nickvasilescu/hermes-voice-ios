import Foundation

/// Reads deploy-time configuration from Info.plist (populated via an
/// .xcconfig at build time — see project.yml). No secrets live here: just
/// where to find the bridge. [IMPLEMENTED]
///
/// There is deliberately no bundled bearer token / bootstrap credential
/// here anymore. The client session token that authenticates every
/// protected bridge call is minted at runtime by `POST /v1/session` and
/// held only by `ClientSessionManager` (in-memory) and `KeychainSessionStore`
/// (on disk) — see docs/SECURITY.md. Shipping a shared secret in the app
/// bundle (Info.plist/xcconfig) would defeat the point of per-client
/// session tokens, since anyone who extracts the IPA gets it too.
enum Config {
    static var bridgeBaseURL: URL {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "BridgeBaseURL") as? String,
            let url = URL(string: raw)
        else {
            return URL(string: "http://localhost:8787")!
        }
        return url
    }
}
