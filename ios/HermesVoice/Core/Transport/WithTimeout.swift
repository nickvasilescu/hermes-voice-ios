import Foundation

/// Raised when a Realtime candidate does not finish its initialization
/// handshake before the coordinator deadline. The coordinator resumes its
/// continuation directly from an actor-confined timer. It deliberately does
/// not use a task-group race because task groups await non-cooperative
/// cancelled children before returning.
struct TimeoutError: Error {
    var seconds: TimeInterval
}
