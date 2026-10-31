import Foundation
import JTKit
import os

/// Under tests the app sends no MDM command, makes no Apple Business or
/// School Manager write, reads no device secret and makes no request to a
/// saved connection (JTKit ROADMAP step 11, decided by Jordy). "Under tests"
/// is the host of the unit tests and a sandbox launch (`-JTKitSandbox`, which
/// the UI tests use). Every attempt is refused before anything is sent and
/// written down, so the release check can show it in its report and fail.
/// Demo connections are not tenants: their commands reach the in-app demo
/// servers only and are never refused.
nonisolated enum UnderTest {
    /// Whether this launch is under tests (JTKit's `TestRun.isActive`).
    static let isActive: Bool = TestRun.isActive

    /// Where refused attempts are written: the container's temporary folder,
    /// the same for the test host and the app the UI tests launch. The
    /// release check empties it before every run.
    static let folder = TestRun.attemptsFolder(named: "Checkpoint-under-test")

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: the release check never sends a device command, an Apple write, a secret read or a request to a saved connection."

    /// The network of settings holding the saved connections while under
    /// tests: every request, sign-in included, is refused before it's sent
    /// and written down. Nothing leaves the Mac.
    static func refusingSession(log: TestRun.AttemptLog = .savedConnections) -> URLSession {
        TestRun.refusingSession(log: log, message: refusal)
    }

    /// The settings of the unit-test host: a throwaway domain in the
    /// temporary folder (never the saved settings, and no file in
    /// Preferences) and no Keychain.
    @MainActor static func unitTestHostSettings() -> AppSettings {
        let domain = FileManager.default.temporaryDirectory.appending(path: "Checkpoint-unit-test-host").path
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        defaults.removePersistentDomain(forName: domain)
        return AppSettings(defaults: defaults, secrets: SandboxSecretStore())
    }
}

/// The attempts of one kind refused under tests, one JSON line each. What is
/// written names the action and the product, never a serial number, host
/// query or secret.
extension TestRun.AttemptLog {
    nonisolated static let commands = TestRun.AttemptLog(name: "command-attempts")
    nonisolated static let appleWrites = TestRun.AttemptLog(name: "apple-write-attempts")
    nonisolated static let secretReads = TestRun.AttemptLog(name: "secret-read-attempts")
    /// Method, host and path only, never the query.
    nonisolated static let savedConnections = TestRun.AttemptLog(name: "saved-connection-requests")

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.checkpoint", category: "UnderTest")

    nonisolated convenience init(name: String) {
        self.init(fileURL: UnderTest.folder.appending(path: "\(name).jsonl"), logger: Self.logger)
    }
}

/// Refuses one kind of action under tests and writes it down; does nothing
/// otherwise.
nonisolated struct ActionGuard: Sendable {
    let isActive: Bool
    let log: TestRun.AttemptLog

    static let off = ActionGuard(isActive: false, log: .commands)

    /// Throws (and records) when active.
    func check(_ what: String) throws {
        guard isActive else { return }
        log.record(what)
        throw TestRun.Refusal(UnderTest.refusal)
    }
}

/// The guards a lookup model applies to its saved (non-demo) connections.
nonisolated struct UnderTestGuards: Sendable {
    /// MDM commands: erase, unmanage, lock, restart, clear passcode, remove
    /// MDM profile and every other command, on every product.
    var commands: ActionGuard
    /// Apple Business / School Manager writes: assign, unassign, release,
    /// migration and its deadline.
    var appleWrites: ActionGuard
    /// FileVault key, Recovery Lock, lock PIN and local admin password.
    var secretReads: ActionGuard

    /// On under tests, off otherwise.
    static let shared = UnderTestGuards(
        commands: ActionGuard(isActive: UnderTest.isActive, log: .commands),
        appleWrites: ActionGuard(isActive: UnderTest.isActive, log: .appleWrites),
        secretReads: ActionGuard(isActive: UnderTest.isActive, log: .secretReads))

    /// For unit tests whose requests go to a mock server only.
    static let off = UnderTestGuards(commands: .off, appleWrites: .off, secretReads: .off)
}
