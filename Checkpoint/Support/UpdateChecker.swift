import SwiftUI

/// Checks GitHub for a newer Checkpoint release.
///
/// This is a notifier and a downloader, not an installer. The app is
/// sandboxed, so it cannot replace itself in /Applications; the update is
/// saved where the user chooses and swapped in by hand. GitHub is the only
/// address this talks to, it sends nothing but the request itself, and the
/// automatic check can be turned off in Settings.
@MainActor
@Observable
final class UpdateChecker {
    /// A published release, reduced to what the update sheet shows.
    nonisolated struct Release: Sendable, Equatable {
        let version: String
        let name: String
        /// GitHub's release notes, as written (Markdown).
        let notes: String
        /// The release's .zip asset, when it has one.
        let downloadURL: URL?
        let pageURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Whether the update sheet is on screen. Set by a manual check at once,
    /// and by the automatic one only when it found something new.
    var isPresented = false

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/JordyThery/Checkpoint/releases/latest")!
    /// At most one automatic check per day.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks in the background at most once a day, and only interrupts when
    /// there is a release it has not offered before. Failures stay silent: a
    /// missed check is not worth an alert.
    func checkAutomatically() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "checksForUpdates") == nil || defaults.bool(forKey: "checksForUpdates") else { return }
        let lastCheck = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval else { return }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        guard let release = try? await fetchLatestRelease() else { return }
        guard Self.isNewer(release.version, than: currentVersion),
              release.version != defaults.string(forKey: "lastOfferedUpdate") else { return }
        defaults.set(release.version, forKey: "lastOfferedUpdate")
        status = .available(release)
        isPresented = true
    }

    /// Checks now and shows the result either way.
    func checkManually() {
        isPresented = true
        status = .checking
        Task {
            do {
                let release = try await fetchLatestRelease()
                status = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        struct Response: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String?
            let assets: [Asset]?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(message: "GitHub did not answer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let release = try JSONDecoder().decode(Response.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return Release(
            version: version,
            name: release.name ?? "Checkpoint \(version)",
            notes: release.body ?? "",
            downloadURL: release.assets?.first { $0.name.hasSuffix(".zip") }
                .flatMap { URL(string: $0.browser_download_url) },
            pageURL: release.html_url.flatMap(URL.init(string:))
        )
    }

    /// Numeric component comparison, so 2.10 is newer than 2.9 and a missing
    /// component counts as zero.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
