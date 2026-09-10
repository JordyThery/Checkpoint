import Foundation
import Observation

nonisolated enum JamfAuthMethod: String, Codable, CaseIterable, Identifiable {
    case apiClient
    case usernamePassword
    case platformGateway

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API Client (ID + Secret)"
        case .usernamePassword: "Username + Password"
        case .platformGateway: "Platform API (Jamf Account)"
        }
    }
}

/// Regions the Platform API gateway is hosted in. Gateway tokens are
/// region-locked: a token must be requested from the same host the subsequent
/// requests are sent to.
nonisolated enum JamfRegion: String, Codable, CaseIterable, Identifiable {
    case us
    case eu
    case apac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .us: "United States (us)"
        case .eu: "Europe (eu)"
        case .apac: "Asia Pacific (apac)"
        }
    }

    var gatewayHost: String { "https://\(rawValue).api.jamfcloud.com" }
}

nonisolated struct JamfServerConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    /// The Jamf Pro server URL. API requests go here directly, except in
    /// Platform API mode where the regional gateway takes them. Links into the
    /// Jamf Pro web interface are always built from this, since the gateway
    /// host cannot serve them.
    var baseURL = ""
    var authMethod: JamfAuthMethod = .apiClient
    /// Client ID or username depending on `authMethod`. The matching secret
    /// (client secret or password) lives in the keychain under `secretKeychainKey`.
    var account = ""
    /// Platform API only: which regional gateway to talk to.
    var region: JamfRegion = .us
    /// Platform API only: the tenant to act on, sent as `X-Tenant-Id`. Copy it
    /// from the tenant pill in the integration's details in Jamf Account.
    var tenantID = ""

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

    /// Host that API requests are sent to.
    var apiBaseURL: String {
        authMethod == .platformGateway ? region.gatewayHost : normalizedBaseURL
    }
}

// Declared in an extension so the memberwise initialiser is still synthesised.
extension JamfServerConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        authMethod = try container.decode(JamfAuthMethod.self, forKey: .authMethod)
        account = try container.decode(String.self, forKey: .account)
        // Added with Platform API support, so absent from servers saved by
        // earlier versions. Without defaults the whole list fails to decode
        // and silently disappears.
        region = try container.decodeIfPresent(JamfRegion.self, forKey: .region) ?? .us
        tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID) ?? ""
    }
}

nonisolated enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

nonisolated struct ABMConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var clientID = ""
    var keyID = ""

    /// The ES256 private key lives in the keychain under this per-organization key.
    var privateKeyKeychainKey: String { "abm.\(id.uuidString)" }

    /// Key used while the app supported a single organization. Only read during
    /// migration; see `AppSettings.migrateLegacyABMOrg`.
    static let legacyPrivateKeyKeychainKey = "abm.privateKey"

    var displayName: String {
        if !name.isEmpty { return name }
        return clientID.isEmpty ? "Unnamed organization" : clientID
    }

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Single-organization Apple Business layout used before multi-organization
/// support. Decoded only to migrate it into `AppSettings.abmOrgs`.
private struct LegacyABMConfig: Codable {
    var clientID = ""
    var keyID = ""
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var jamfServers: [JamfServerConfig] { didSet { save() } }
    var abmOrgs: [ABMConfig] { didSet { save() } }
    var appearance: AppAppearance { didSet { save() } }

    private init() {
        let defaults = UserDefaults.standard
        jamfServers = defaults.data(forKey: "jamfServers")
            .flatMap { try? JSONDecoder().decode([JamfServerConfig].self, from: $0) } ?? []
        abmOrgs = defaults.data(forKey: "abmOrgs")
            .flatMap { try? JSONDecoder().decode([ABMConfig].self, from: $0) } ?? []
        appearance = defaults.string(forKey: "appearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        if abmOrgs.isEmpty { migrateLegacyABMOrg() }
    }

    /// Carries a pre-multi-organization Apple Business setup into `abmOrgs`,
    /// moving its keychain item to the new per-organization key. The old item
    /// is removed only once the copy reads back, so a failed write can never
    /// lose a private key that cannot be downloaded from Apple again.
    private func migrateLegacyABMOrg() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "abmConfig"),
              let legacy = try? JSONDecoder().decode(LegacyABMConfig.self, from: data) else { return }
        let legacyPEM = Keychain.get(ABMConfig.legacyPrivateKeyKeychainKey)
        guard !legacy.clientID.isEmpty || !(legacyPEM ?? "").isEmpty else {
            defaults.removeObject(forKey: "abmConfig")
            return
        }
        let org = ABMConfig(name: "Apple Business", clientID: legacy.clientID, keyID: legacy.keyID)
        if let legacyPEM, !legacyPEM.isEmpty {
            Keychain.set(legacyPEM, for: org.privateKeyKeychainKey)
            if Keychain.get(org.privateKeyKeychainKey) == legacyPEM {
                Keychain.delete(ABMConfig.legacyPrivateKeyKeychainKey)
            }
        }
        abmOrgs = [org]
        defaults.removeObject(forKey: "abmConfig")
        // Property observers don't fire inside an initializer, so persist here.
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(jamfServers) { defaults.set(data, forKey: "jamfServers") }
        if let data = try? JSONEncoder().encode(abmOrgs) { defaults.set(data, forKey: "abmOrgs") }
        defaults.set(appearance.rawValue, forKey: "appearance")
    }
}
