import Foundation

/// A run ended with Stop (a wait before a retry ended, JTKit's
/// `RequestWaits.cancelAll()`), said as one plain sentence everywhere:
/// lookups, actions and the status bar. Swift's own text for a cancellation
/// ("The operation couldn’t be completed. (Swift.CancellationError error 1.)")
/// is never shown.
nonisolated enum Stopping {
    /// For a read or an action stopped part of the way.
    static let sentence = "Stopped before it finished."

    /// Whether the error is a stop, not a failure.
    static func isStop(_ error: any Error) -> Bool {
        error is CancellationError || error is StoppedRun || (error as? URLError)?.code == .cancelled
    }
}

/// A command run that was stopped: what was sent and what wasn't. Shown in
/// the status bar, not as a failure: the devices sent to received it.
nonisolated struct StoppedRun: LocalizedError, Equatable {
    let sent: Int
    let notSent: Int

    var errorDescription: String? { "Stopped: \(sent) sent, \(notSent) not sent." }
}

/// An error as the app says it: the plain sentence for a stop, else its own text.
nonisolated func describe(_ error: any Error) -> String {
    if let stopped = error as? StoppedRun { return stopped.errorDescription ?? Stopping.sentence }
    return Stopping.isStop(error) ? Stopping.sentence : error.localizedDescription
}
