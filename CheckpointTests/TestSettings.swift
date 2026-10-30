import Foundation

/// Settings domains for tests, kept out of Preferences. A named domain
/// (`UserDefaults(suiteName: "CheckpointTests.<UUID>")`) left one file per
/// test in the container's Preferences folder, thousands over time, even when
/// emptied: macOS writes the empty file back. Here a domain is a file path in
/// this test process's own folder in the temporary folder (UserDefaults stores
/// it there), and the folder is removed when the process ends. Folders of
/// processes that ended without removing theirs (a crash, or a late write by
/// the settings daemon) are removed by the next test run.
nonisolated enum TestSettings {
    static let root = FileManager.default.temporaryDirectory
        .appending(path: "CheckpointTests-settings", directoryHint: .isDirectory)

    /// This process's folder, made once; the first use also removes the
    /// folders of ended test processes and arranges removal of this one.
    static let folder: URL = {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let pid = Int32(name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? fileManager.removeItem(at: root.appending(path: name))
        }
        let folder = root.appending(path: "\(getpid())", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit {
            try? FileManager.default.removeItem(at: TestSettings.root.appending(path: "\(getpid())"))
        }
        return folder
    }()

    /// A new, empty domain.
    static func makeDefaults(_ purpose: String = "settings") -> (domain: String, defaults: UserDefaults) {
        let domain = folder.appending(path: "\(purpose)-\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        defaults.removePersistentDomain(forName: domain)
        return (domain, defaults)
    }

    /// The app's Preferences folder in its container (the test host's home).
    static var preferencesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences", directoryHint: .isDirectory)
    }
}
