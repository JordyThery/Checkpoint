import Foundation
import Observation

/// Which device management product a connection talks to.
///
/// Products differ in what they can report, not only in how they are asked.
/// Jamf School is not a variant of Jamf Pro: no computer/mobile split,
/// locations instead of sites, and no source at all for FileVault, MDM
/// profile expiry, software update state or the recovery secrets. What a
/// product cannot report is hidden rather than shown empty, which is what
/// `capabilities` drives.
///
/// A further product is added as a case here, a capability set below, and a
/// client of its own. Nothing outside this file should ask which product it
/// is talking to in order to decide what to show — that is what the
/// capabilities are for.
nonisolated enum MDMProduct: String, Codable, CaseIterable, Identifiable, Sendable {
    // Raw values are persisted in every saved connection, so they keep the
    // spellings from when Jamf was the only kind of product there was.
    case jamfPro = "pro"
    case jamfSchool = "school"
    case intune = "intune"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jamfPro: "Jamf Pro"
        case .jamfSchool: "Jamf School"
        case .intune: "Intune"
        }
    }

    /// What one configured connection to this product is called, which is a
    /// server for Jamf and a tenant for Intune.
    var connectionNoun: String {
        switch self {
        case .jamfPro, .jamfSchool: "server"
        case .intune: "tenant"
        }
    }

    var capabilities: MDMCapabilities {
        switch self {
        case .jamfPro: [.sites, .prestageScope, .enrollmentDate, .inventoryDates,
                        .mdmProfileExpiry, .fileVault, .passcodeState, .softwareUpdate,
                        .declarations, .recoverySecrets, .deviceLink, .deviceGroups,
                        .enrollmentProfileName, .complianceOnDemand]
        case .jamfSchool: [.locations, .passcodeOnDemand, .deviceLink, .deviceGroups,
                           .enrollmentProfileName]
        // Intune reports one sync time rather than Jamf's four dates, so it
        // gets the enrollment date and the contact column and nothing else in
        // that family. `isEncrypted` is a bare boolean, which the encryption
        // state already handles as its fallback. No sites, no PreStage scope,
        // no declarative update reporting, and no recovery secrets: the
        // FileVault key is beta-only, so it is left out until it is not.
        case .intune: [.enrollmentDate, .mdmProfileExpiry, .fileVault, .passcodeState, .compliance, .deviceLink]
        }
    }

    /// Header for the column carrying the enrollment profile. Jamf School
    /// reports the Apple ADE profile rather than a Jamf PreStage, so the two
    /// are named for what they actually are.
    var enrollmentProfileLabel: String {
        switch self {
        case .jamfPro: "PreStage"
        case .jamfSchool: "ADE Profile"
        // Not shown: see `MDMCapabilities.enrollmentProfileName`.
        case .intune: "Enrollment Profile"
        }
    }

    /// Jamf Pro's Last Contact is a dedicated inventory attribute; Jamf
    /// School reports only when the device last checked in. Naming them apart
    /// keeps the column from implying the two are the same measurement.
    var lastContactLabel: String {
        switch self {
        case .jamfPro: "Last Contact"
        case .jamfSchool: "Last Check-in"
        case .intune: "Last Sync"
        }
    }

    /// Wording for removing a record, which differs by product in kind and
    /// not only in name: Jamf Pro and Intune delete it, Jamf School moves it
    /// to a trash it can be restored from. Kept together here so a new
    /// product cannot be added with half its wording missing.
    ///
    /// The button label, singular and plural.
    var removeRecordAction: String {
        switch self {
        case .jamfPro, .intune: "Delete Record"
        case .jamfSchool: "Move to Trash"
        }
    }

    var removeRecordActionPlural: String {
        switch self {
        case .jamfPro, .intune: "Delete Records"
        case .jamfSchool: "Move to Trash"
        }
    }

    /// Past tense, for the activity log.
    var removeRecordPastTense: String {
        switch self {
        case .jamfPro, .intune: "Deleted"
        case .jamfSchool: "Trashed"
        }
    }

    /// Confirmation title for one device and for several.
    func removeRecordPrompt(_ subject: String) -> String {
        switch self {
        case .jamfPro: "Delete the Jamf Pro record for \(subject)?"
        case .jamfSchool: "Move the Jamf School record for \(subject) to the trash?"
        case .intune: "Delete the Intune record for \(subject)?"
        }
    }

    /// What removing the record actually does, which is the part worth
    /// spelling out: only Jamf School's is reversible, and only Intune's
    /// leaves a device that will come back by itself.
    var removeRecordConsequence: String {
        switch self {
        case .jamfPro: "The record will be deleted from the selected Jamf Pro server."
        case .jamfSchool: "The record moves to the trash in Jamf School. It stops being managed, and can be restored there."
        case .intune: "The record will be deleted from Intune. The device itself stays enrolled and will reappear at its next check-in; Remove MDM Profile is what unmanages it."
        }
    }

    /// Shown in the inspector when no connection to this product exists.
    var missingConnectionHint: String {
        switch self {
        case .jamfPro: "Add a Jamf Pro server in Settings to see enrollment details and PreStage scope."
        case .jamfSchool: "Add a Jamf School server in Settings to see enrollment details and locations."
        case .intune: "Add an Intune tenant in Settings to see enrollment details and compliance."
        }
    }

    /// Shown when the product has no record for a serial.
    var noRecordHint: String {
        switch self {
        case .jamfPro: "No computer or mobile device record was found on the selected Jamf Pro server."
        case .jamfSchool: "No device record was found on the selected Jamf School server."
        case .intune: "No managed device record was found in the selected Intune tenant."
        }
    }

    /// Jamf School trashes a device rather than deleting it, and a trashed
    /// device can be restored, so the wording differs from Jamf Pro's delete.
    var removeRecordLabel: String {
        switch self {
        case .jamfPro: "Remove from Jamf Pro"
        case .jamfSchool: "Move to Trash in Jamf School"
        case .intune: "Delete from Intune"
        }
    }
}

/// What a connection can report and do. Every capability is a gate on a
/// column, a row or an action, so a product that lacks one shows nothing in
/// its place rather than an empty value.
///
/// Capabilities are deliberately finer-grained than products: some are
/// granted by the connection rather than the product, and a capability a
/// vendor withdraws should cost one line here rather than a hunt through the
/// views.
nonisolated struct MDMCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let sites = MDMCapabilities(rawValue: 1 << 0)
    static let locations = MDMCapabilities(rawValue: 1 << 1)
    static let prestageScope = MDMCapabilities(rawValue: 1 << 2)
    /// The date the device enrolled.
    static let enrollmentDate = MDMCapabilities(rawValue: 1 << 3)
    static let mdmProfileExpiry = MDMCapabilities(rawValue: 1 << 4)
    static let fileVault = MDMCapabilities(rawValue: 1 << 5)
    static let softwareUpdate = MDMCapabilities(rawValue: 1 << 6)
    static let recoverySecrets = MDMCapabilities(rawValue: 1 << 7)
    /// Passcode state is not in the bulk device list, only in the per-device
    /// record, so it is read when a device is selected.
    static let passcodeOnDemand = MDMCapabilities(rawValue: 1 << 9)
    /// The enrollment profile a device is assigned. Jamf Pro reports its
    /// PreStage scope and Jamf School the Apple ADE profile; Intune's v1.0 API
    /// reports only what a device enrolled with, which is not the same
    /// question and reads as "None" for a device whose assignment the console
    /// shows. The assignment itself is beta-only, so nothing is shown there.
    static let enrollmentProfileName = MDMCapabilities(rawValue: 1 << 17)
    /// Passcode state arrives with the lookup, so it can be filtered on.
    /// Distinct from reading it on demand, as Jamf School does. Intune's is
    /// derived: iPhone and iPad enable data protection exactly when a
    /// passcode is set, and that flag comes with the tenant read.
    static let passcodeState = MDMCapabilities(rawValue: 1 << 16)
    /// Links from a device to its record in the web interface. Built from
    /// the server URL, or from Intune's fixed console host, rather than
    /// published by any of the APIs — so it is a capability of the product's
    /// console rather than of its API.
    static let deviceLink = MDMCapabilities(rawValue: 1 << 10)
    /// Declarative management status: which declarations a device has
    /// processed, and whether it accepted them. Jamf School has no DDM.
    static let declarations = MDMCapabilities(rawValue: 1 << 11)
    /// Blueprint names. A platform feature with no endpoint on a Jamf Pro
    /// instance, so only the gateway can resolve an identifier to a name.
    static let blueprintNames = MDMCapabilities(rawValue: 1 << 12)
    /// Last inventory report and the Jamf binary check-in, as measurements
    /// separate from last contact. Split from the enrollment date because
    /// Intune reports one sync time and nothing that corresponds to either.
    static let inventoryDates = MDMCapabilities(rawValue: 1 << 13)
    /// Device compliance reported with the lookup. Intune only: it comes in
    /// the tenant read, so every row has it.
    static let compliance = MDMCapabilities(rawValue: 1 << 14)
    /// Device compliance served per device, so it is read when one is
    /// selected. Jamf Pro only, and only through its Device Compliance
    /// integration — Jamf Pro relays a vendor's verdict rather than
    /// evaluating one.
    static let complianceOnDemand = MDMCapabilities(rawValue: 1 << 18)
    /// Looking a device group up and loading its members. Both Jamf products
    /// serve one; Intune's equivalent is an Entra group, which is not a
    /// device group and is not read.
    static let deviceGroups = MDMCapabilities(rawValue: 1 << 15)
}

/// How a connection authenticates. The three cases are Jamf's; another
/// product's method is added here, and the editor shows only the ones its
/// product accepts. Raw values are persisted.
nonisolated enum MDMAuthMethod: String, Codable, CaseIterable, Identifiable {
    case apiClient
    case usernamePassword
    case platformGateway
    case entraApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API Client (ID + Secret)"
        case .usernamePassword: "Username + Password"
        case .platformGateway: "Platform API (Jamf Account)"
        case .entraApp: "Entra App Registration (Client Secret)"
        }
    }

    /// The methods a product accepts, so the editor cannot offer a Jamf
    /// method for an Intune tenant or the other way round.
    static func methods(for product: MDMProduct) -> [MDMAuthMethod] {
        switch product {
        case .jamfPro: [.apiClient, .usernamePassword, .platformGateway]
        case .jamfSchool: [.apiClient]
        case .intune: [.entraApp]
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

/// One configured device management connection.
///
/// Fields only one product uses are kept rather than split into per-product
/// types: a connection is edited as a single form, and a stored type that
/// changes shape by product would have to be versioned to stay decodable.
/// Each such field says which product it belongs to.
nonisolated struct MDMConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    /// Which product this connection talks to. Absent from connections saved
    /// before Jamf School was supported, which were all Jamf Pro.
    var product: MDMProduct = .jamfPro
    /// The Jamf Pro server URL. API requests go here directly, except in
    /// Platform API mode where the regional gateway takes them. Links into the
    /// Jamf Pro web interface are always built from this, since the gateway
    /// host cannot serve them.
    var baseURL = ""
    /// Jamf Pro only. Jamf School authenticates with HTTP Basic, using the
    /// Network ID as the user and the API key as the password.
    var authMethod: MDMAuthMethod = .apiClient
    /// Client ID or username depending on `authMethod`. The matching secret
    /// (client secret or password) lives in the keychain under `secretKeychainKey`.
    var account = ""
    /// Platform API only: which regional gateway to talk to.
    var region: JamfRegion = .us
    /// Platform API only: the environment to act on, sent as `X-Environment-Id`.
    /// Environment scope is required rather than tenant scope, because the
    /// platform device actions accept no other.
    var environmentID = ""
    /// Intune only: the Entra tenant the app registration lives in, which is
    /// part of the token URL rather than a header. A GUID or a verified
    /// domain name; Microsoft accepts either.
    var tenantID = ""

    /// Keychain account for this connection's secret. The prefix is part of
    /// the stored item's name, so it stays as it was written: changing it
    /// would leave every saved secret unreadable and unfindable.
    var secretKeychainKey: String { "jamf.\(id.uuidString)" }

    var displayName: String {
        if !name.isEmpty { return name }
        if product == .intune { return tenantID.isEmpty ? "Unnamed tenant" : tenantID }
        return normalizedBaseURL.isEmpty ? "Unnamed server" : normalizedBaseURL
    }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.isEmpty && !url.contains("://") { url = "https://" + url }
        return url
    }

    /// Host that API requests are sent to. Empty for Intune, whose client
    /// addresses Microsoft Graph directly and needs no URL configured.
    var apiBaseURL: String {
        // Jamf School has no gateway, so the server URL is always the host,
        // whatever an authentication method left over from Jamf Pro says.
        guard product == .jamfPro else { return normalizedBaseURL }
        return authMethod == .platformGateway ? region.gatewayHost : normalizedBaseURL
    }

    /// What this connection can do, which is the product's capabilities plus
    /// anything only the gateway reaches. Blueprints are a platform feature,
    /// so a direct Jamf Pro connection cannot name one.
    var capabilities: MDMCapabilities {
        var result = product.capabilities
        if isUsingPlatformGateway { result.insert(.blueprintNames) }
        return result
    }

    /// True only for a Jamf Pro server on the Platform API gateway. Jamf
    /// School can never be on it, whatever `authMethod` holds.
    var isUsingPlatformGateway: Bool {
        product == .jamfPro && authMethod == .platformGateway
    }
}

extension MDMConnection {
    /// Spelled out so that `product` keeps the key it was first saved under.
    /// The synthesised keys follow the property names, so renaming the
    /// property alone would write a key nothing reads and read one nothing
    /// writes — every Jamf School connection would come back as Jamf Pro.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case product = "product"
        case baseURL
        case authMethod
        case account
        case region
        case environmentID
        case tenantID
    }
}

// Declared in an extension so the memberwise initialiser is still synthesised.
extension MDMConnection {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        authMethod = try container.decode(MDMAuthMethod.self, forKey: .authMethod)
        account = try container.decode(String.self, forKey: .account)
        // Added with Jamf School support, so absent from servers saved by
        // earlier versions. Those were all Jamf Pro; without a default the
        // whole list fails to decode and every configured server disappears.
        product = try container.decodeIfPresent(MDMProduct.self, forKey: .product) ?? .jamfPro
        // Added with Platform API support, so absent from servers saved by
        // earlier versions. Without defaults the whole list fails to decode
        // and silently disappears.
        region = try container.decodeIfPresent(JamfRegion.self, forKey: .region) ?? .us
        // Servers saved before the move to environment scope carry a tenant ID
        // instead. It is a different identifier, so it is not carried over and
        // the environment ID has to be entered again.
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID) ?? ""
        // Added with Intune support, so absent from every connection saved
        // before it. Jamf connections never carry one.
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

    var mdmConnections: [MDMConnection] { didSet { save() } }
    var abmOrgs: [ABMConfig] { didSet { save() } }
    var appearance: AppAppearance { didSet { save() } }
    /// Whether the hint about an unconfigured service has been dismissed.
    /// Kept, rather than shown again each launch, because running against one
    /// service is a deliberate setup for some people.
    var configurationHintDismissed: Bool { didSet { save() } }
    /// Whether Checkpoint asks GitHub for a newer release once a day. The one
    /// request the app makes to anything other than a configured service,
    /// which is why it has an off switch.
    var checksForUpdates: Bool { didSet { save() } }

    private init() {
        let defaults = UserDefaults.standard
        // Stored under its original key. Renaming it would orphan every
        // connection already configured, and the app would come up empty.
        mdmConnections = defaults.data(forKey: "jamfServers")
            .flatMap { try? JSONDecoder().decode([MDMConnection].self, from: $0) } ?? []
        abmOrgs = defaults.data(forKey: "abmOrgs")
            .flatMap { try? JSONDecoder().decode([ABMConfig].self, from: $0) } ?? []
        appearance = defaults.string(forKey: "appearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        configurationHintDismissed = defaults.bool(forKey: "configurationHintDismissed")
        // Defaults to on; `bool(forKey:)` alone would read absent as off.
        checksForUpdates = defaults.object(forKey: "checksForUpdates") == nil
            || defaults.bool(forKey: "checksForUpdates")
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
        if let data = try? JSONEncoder().encode(mdmConnections) { defaults.set(data, forKey: "jamfServers") }
        if let data = try? JSONEncoder().encode(abmOrgs) { defaults.set(data, forKey: "abmOrgs") }
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(configurationHintDismissed, forKey: "configurationHintDismissed")
        defaults.set(checksForUpdates, forKey: "checksForUpdates")
    }
}
