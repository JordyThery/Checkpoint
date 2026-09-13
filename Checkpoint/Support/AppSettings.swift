import Foundation
import Observation

/// Which Jamf product a server is.
///
/// Jamf School is a different product with a much smaller API, not a variant
/// of Jamf Pro: no computer/mobile split, locations instead of sites, and no
/// source at all for FileVault, MDM profile expiry, software update state or
/// the recovery secrets. What it cannot report is hidden rather than shown
/// empty, which is what `capabilities` drives.
nonisolated enum JamfFlavor: String, Codable, CaseIterable, Identifiable, Sendable {
    case pro
    case school

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pro: "Jamf Pro"
        case .school: "Jamf School"
        }
    }

    var capabilities: JamfCapabilities {
        switch self {
        case .pro: [.sites, .prestageScope, .enrollmentDates, .mdmProfileExpiry,
                    .fileVault, .softwareUpdate, .declarations, .recoverySecrets, .deviceLink]
        case .school: [.locations, .passcodeOnDemand]
        }
    }

    /// Header for the column carrying the enrollment profile. Jamf School
    /// reports the Apple ADE profile rather than a Jamf PreStage, so the two
    /// are named for what they actually are.
    var enrollmentProfileLabel: String {
        switch self {
        case .pro: "PreStage"
        case .school: "ADE Profile"
        }
    }

    /// Jamf Pro's Last Contact is a dedicated inventory attribute; Jamf
    /// School reports only when the device last checked in. Naming them apart
    /// keeps the column from implying the two are the same measurement.
    var lastContactLabel: String {
        switch self {
        case .pro: "Last Contact"
        case .school: "Last Check-in"
        }
    }

    /// Jamf School trashes a device rather than deleting it, and a trashed
    /// device can be restored, so the wording differs from Jamf Pro's delete.
    var removeRecordLabel: String {
        switch self {
        case .pro: "Remove from Jamf Pro"
        case .school: "Move to Trash in Jamf School"
        }
    }
}

/// What a Jamf connection can report and do. Every capability is a gate on a
/// column, a row or an action, so a flavour that lacks one shows nothing in
/// its place rather than an empty value.
nonisolated struct JamfCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let sites = JamfCapabilities(rawValue: 1 << 0)
    static let locations = JamfCapabilities(rawValue: 1 << 1)
    static let prestageScope = JamfCapabilities(rawValue: 1 << 2)
    /// Last enrollment date, last inventory update and Last Contact.
    static let enrollmentDates = JamfCapabilities(rawValue: 1 << 3)
    static let mdmProfileExpiry = JamfCapabilities(rawValue: 1 << 4)
    static let fileVault = JamfCapabilities(rawValue: 1 << 5)
    static let softwareUpdate = JamfCapabilities(rawValue: 1 << 6)
    static let recoverySecrets = JamfCapabilities(rawValue: 1 << 7)
    /// Passcode state is not in the bulk device list, only in the per-device
    /// record, so it is read when a device is selected.
    static let passcodeOnDemand = JamfCapabilities(rawValue: 1 << 9)
    /// Links from a device to its record in the web interface. Jamf School
    /// publishes no URL for one.
    static let deviceLink = JamfCapabilities(rawValue: 1 << 10)
    /// Declarative management status: which declarations a device has
    /// processed, and whether it accepted them. Jamf School has no DDM.
    static let declarations = JamfCapabilities(rawValue: 1 << 11)
    /// Blueprint names. A platform feature with no endpoint on a Jamf Pro
    /// instance, so only the gateway can resolve an identifier to a name.
    static let blueprintNames = JamfCapabilities(rawValue: 1 << 12)
}

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
    /// Which Jamf product this is. Absent from servers saved before Jamf
    /// School was supported, which were all Jamf Pro.
    var flavor: JamfFlavor = .pro
    /// The Jamf Pro server URL. API requests go here directly, except in
    /// Platform API mode where the regional gateway takes them. Links into the
    /// Jamf Pro web interface are always built from this, since the gateway
    /// host cannot serve them.
    var baseURL = ""
    /// Jamf Pro only. Jamf School authenticates with HTTP Basic, using the
    /// Network ID as the user and the API key as the password.
    var authMethod: JamfAuthMethod = .apiClient
    /// Client ID or username depending on `authMethod`. The matching secret
    /// (client secret or password) lives in the keychain under `secretKeychainKey`.
    var account = ""
    /// Platform API only: which regional gateway to talk to.
    var region: JamfRegion = .us
    /// Platform API only: the environment to act on, sent as `X-Environment-Id`.
    /// Environment scope is required rather than tenant scope, because the
    /// platform device actions accept no other.
    var environmentID = ""

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
        // Jamf School has no gateway, so the server URL is always the host,
        // whatever an authentication method left over from Jamf Pro says.
        guard flavor == .pro else { return normalizedBaseURL }
        return authMethod == .platformGateway ? region.gatewayHost : normalizedBaseURL
    }

    /// What this connection can do, which is the product's capabilities plus
    /// anything only the gateway reaches. Blueprints are a platform feature,
    /// so a direct Jamf Pro connection cannot name one.
    var capabilities: JamfCapabilities {
        var result = flavor.capabilities
        if isUsingPlatformGateway { result.insert(.blueprintNames) }
        return result
    }

    /// True only for a Jamf Pro server on the Platform API gateway. Jamf
    /// School can never be on it, whatever `authMethod` holds.
    var isUsingPlatformGateway: Bool {
        flavor == .pro && authMethod == .platformGateway
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
        // Added with Jamf School support, so absent from servers saved by
        // earlier versions. Those were all Jamf Pro; without a default the
        // whole list fails to decode and every configured server disappears.
        flavor = try container.decodeIfPresent(JamfFlavor.self, forKey: .flavor) ?? .pro
        // Added with Platform API support, so absent from servers saved by
        // earlier versions. Without defaults the whole list fails to decode
        // and silently disappears.
        region = try container.decodeIfPresent(JamfRegion.self, forKey: .region) ?? .us
        // Servers saved before the move to environment scope carry a tenant ID
        // instead. It is a different identifier, so it is not carried over and
        // the environment ID has to be entered again.
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID) ?? ""
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

/// Which of Apple's two sibling organization services an account belongs to.
///
/// The APIs are the same one with two front doors: identical paths, identical
/// device attributes, and the same OAuth flow differing only in scope. Only
/// the set of device activities differs, which `supportsRelease` covers.
nonisolated enum AppleOrgKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case business
    case school

    var id: String { rawValue }

    var label: String {
        switch self {
        case .business: "Apple Business"
        case .school: "Apple School Manager"
        }
    }

    var host: URL {
        switch self {
        case .business: URL(string: "https://api-business.apple.com")!
        case .school: URL(string: "https://api-school.apple.com")!
        }
    }

    /// OAuth scope. The token endpoint is shared; only this value differs.
    var scope: String {
        switch self {
        case .business: "business.api"
        case .school: "school.api"
        }
    }

    /// Apple School Manager has no RELEASE_DEVICES activity, so devices
    /// cannot be released from the organization there.
    var supportsRelease: Bool { self == .business }
}

nonisolated struct ABMConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    /// Which service this account is for. Absent from configurations saved
    /// before Apple School Manager was supported, which were all Business.
    var kind: AppleOrgKind = .business
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

// Declared in an extension so the memberwise initialiser is still synthesised.
extension ABMConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        clientID = try container.decode(String.self, forKey: .clientID)
        keyID = try container.decode(String.self, forKey: .keyID)
        // Added with Apple School Manager support, so absent from
        // organizations saved by earlier versions. Those were all Apple
        // Business; without a default the whole list fails to decode and
        // every configured organization silently disappears.
        kind = try container.decodeIfPresent(AppleOrgKind.self, forKey: .kind) ?? .business
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
