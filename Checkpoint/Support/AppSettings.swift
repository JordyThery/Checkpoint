import Foundation
import Observation

nonisolated enum JamfAuthMethod: String, Codable, CaseIterable, Identifiable {
    case apiClient
    case usernamePassword

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API Client (ID + Secret)"
        case .usernamePassword: "Username + Password"
        }
    }
}

nonisolated struct JamfServerConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var baseURL = ""
    var authMethod: JamfAuthMethod = .apiClient
    /// Client ID or username depending on `authMethod`. The matching secret
    /// (client secret or password) lives in the keychain under `secretKeychainKey`.
    var account = ""

    var secretKeychainKey: String { "jamf.\(id.uuidString)" }

    var displayName: String {
        if !name.isEmpty { return name }
        return normalizedBaseURL.isEmpty ? "Unnamed server" : normalizedBaseURL
    }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.isEmpty && !url.contains("://") { url = "https://" + url }
        return url
    }
}

struct ABMConfig: Codable {
    var clientID = ""
    var keyID = ""

    static let privateKeyKeychainKey = "abm.privateKey"

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var jamfServers: [JamfServerConfig] { didSet { save() } }
    var abm: ABMConfig { didSet { save() } }

    private init() {
        let defaults = UserDefaults.standard
        jamfServers = defaults.data(forKey: "jamfServers")
            .flatMap { try? JSONDecoder().decode([JamfServerConfig].self, from: $0) } ?? []
        abm = defaults.data(forKey: "abmConfig")
            .flatMap { try? JSONDecoder().decode(ABMConfig.self, from: $0) } ?? ABMConfig()
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(jamfServers) { defaults.set(data, forKey: "jamfServers") }
        if let data = try? JSONEncoder().encode(abm) { defaults.set(data, forKey: "abmConfig") }
    }
}
