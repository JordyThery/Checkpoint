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
    /// Whether this launch is under tests.
    static let isActive: Bool = isUnitTestHost
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        || isSandboxLaunch()

    /// Started with `-JTKitSandbox YES` (UI tests), read as JTKit's
    /// `DemoMode.isSandbox` reads it: YES, true or 1. `-JTKitSandbox NO` is
    /// an ordinary launch, with the saved settings and the update check.
    static func isSandboxLaunch(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.lastIndex(of: DemoMode.sandboxArgument), arguments.indices.contains(index + 1) else {
            return false
        }
        return ["yes", "true", "1"].contains(arguments[index + 1].lowercased())
    }

    /// Whether this process is the host of the unit tests.
    static var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    /// Where refused attempts are written: the container's temporary folder,
    /// the same for the test host and the app the UI tests launch. The
    /// release check empties it before every run.
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "Checkpoint-under-test", directoryHint: .isDirectory)

    /// The message a refused attempt gives.
    static let refusal = "Refused under tests: the release check never sends a device command, an Apple write, a secret read or a request to a saved connection."

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
nonisolated final class AttemptLog: Sendable {
    static let commands = AttemptLog(name: "command-attempts")
    static let appleWrites = AttemptLog(name: "apple-write-attempts")
    static let secretReads = AttemptLog(name: "secret-read-attempts")
    /// Method, host and path only, never the query.
    static let savedConnections = AttemptLog(name: "saved-connection-requests")

    nonisolated struct Attempt: Codable, Sendable, Equatable {
        var time: Date
        var process: String
        var what: String
    }

    let fileURL: URL
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "be.jordythery.checkpoint", category: "UnderTest")

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    convenience init(name: String) {
        self.init(fileURL: UnderTest.folder.appending(path: "\(name).jsonl"))
    }

    func record(_ what: String) {
        Self.logger.error("Refused under tests: \(what, privacy: .private)")
        let attempt = Attempt(time: Date(), process: ProcessInfo.processInfo.processName, what: what)
        guard let line = try? JSONEncoder().encode(attempt) else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O_APPEND: the test host and the app the UI tests launch may both write.
            let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let data = line + Data("\n".utf8)
            _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    func attempts() -> [Attempt] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Attempt.self, from: Data($0.utf8)) }
    }
}

/// Refuses one kind of action under tests and writes it down; does nothing
/// otherwise.
nonisolated struct ActionGuard: Sendable {
    let isActive: Bool
    let log: AttemptLog

    static let off = ActionGuard(isActive: false, log: .commands)

    /// Throws (and records) when active.
    func check(_ what: String) throws {
        guard isActive else { return }
        log.record(what)
        throw UnderTestRefusal()
    }
}

/// The error of a refused attempt.
nonisolated struct UnderTestRefusal: LocalizedError, Sendable {
    var errorDescription: String? { UnderTest.refusal }
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

/// The network of settings holding the saved connections while under tests:
/// every request, sign-in included, is refused before it's sent and written
/// down. Nothing leaves the Mac.
nonisolated enum SavedConnectionGuard {
    static func refusingSession(log: AttemptLog = .savedConnections) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        configuration.httpAdditionalHeaders = [RefusingURLProtocol.logHeader: log.fileURL.path]
        return URLSession(configuration: configuration)
    }

    final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
        static let logHeader = "X-Checkpoint-Under-Test-Log"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.value(forHTTPHeaderField: Self.logHeader)
            let log = path.map { AttemptLog(fileURL: URL(filePath: $0)) } ?? .savedConnections
            log.record("\(request.httpMethod ?? "GET") \(request.url?.host() ?? "")\(request.url?.path() ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled, userInfo: [NSLocalizedDescriptionKey: UnderTest.refusal]))
        }

        override func stopLoading() {}
    }
}
