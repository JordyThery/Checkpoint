import Foundation
import JTKit

// Checkpoint's saved connections in JTKit's shared list: the Apple
// organizations (`abmOrgs`) and the MDM connections (`jamfServers`) stay in
// the two UserDefaults keys they have always used, in their own format, and
// are shown as one list.

/// Where Checkpoint keeps secrets: one Keychain service, one account per
/// connection.
nonisolated enum CheckpointSecrets {
    /// The pre-rename service name. Changing it would orphan every saved secret.
    static let service = "DeviceStatus.secrets"

    /// No accessibility or label is set, as Checkpoint's own Keychain code never did.
    static let keychain: any SecretStore = KeychainSecretStore(service: service)

    /// `abm.<UUID>` for an Apple organization's private key, `jamf.<UUID>`
    /// for an MDM connection's secret (Intune and Jamf School included: the
    /// prefix dates from when Jamf was the only product).
    static func account(for connection: Connection) -> String {
        let prefix = CheckpointConnection.appleServices.contains(connection.service) ? "abm" : "jamf"
        return "\(prefix).\(connection.id.uuidString)"
    }
}

/// One entry of the shared Connections list: an Apple organization or an
/// MDM connection, each kept as the record Checkpoint has always saved.
nonisolated enum CheckpointConnection: ConnectionRecord {
    case apple(ABMConfig)
    case mdm(MDMConnection)

    static let appleServices: Set<ConnectionService> = [.appleBusinessManager, .appleSchoolManager]
    static let mdmServices: Set<ConnectionService> = [.jamfPro, .jamfPlatform, .jamfSchool, .intune]
    /// The order of the + menu.
    static let services: [ConnectionService] = [.appleBusinessManager, .appleSchoolManager,
                                                .jamfPro, .jamfPlatform, .jamfSchool, .intune]
    /// A connection switches service only within its group: an Apple
    /// organization can't become an MDM connection, which is saved in the
    /// other list under another Keychain name.
    static let serviceGroups: [[ConnectionService]] = [[.appleBusinessManager, .appleSchoolManager],
                                                       [.jamfPro, .jamfPlatform, .jamfSchool, .intune]]
    /// Checkpoint signs in to Intune with an app registration only.
    static let signInMethods: [ConnectionService: [SignInMethod]] = [.intune: [.entraClientSecret]]

    var id: UUID {
        switch self {
        case .apple(let org): org.id
        case .mdm(let server): server.id
        }
    }

    /// The name in the toolbar and the menu, as Checkpoint has always shown it.
    var displayName: String {
        switch self {
        case .apple(let org): org.displayName
        case .mdm(let server): server.displayName
        }
    }

    nonisolated var connection: Connection {
        get {
            switch self {
            case .apple(let org): org.connection
            case .mdm(let server): server.connection
            }
        }
        set {
            switch self {
            case .apple(var org):
                org.connection = newValue
                self = .apple(org)
            case .mdm(var server):
                server.connection = newValue
                self = .mdm(server)
            }
        }
    }

    /// A new, unsaved entry for the service chosen with +.
    static func new(for service: ConnectionService) -> CheckpointConnection {
        switch service {
        case .appleBusinessManager: .apple(ABMConfig(name: "New Organization", kind: .business))
        case .appleSchoolManager: .apple(ABMConfig(name: "New Organization", kind: .school))
        case .jamfPlatform: .mdm(MDMConnection(name: "New Server", product: .jamfPro, authMethod: .platformGateway))
        case .jamfSchool: .mdm(MDMConnection(name: "New Server", product: .jamfSchool))
        case .intune: .mdm(MDMConnection(name: "New Tenant", product: .intune, authMethod: .entraApp))
        case .jamfPro: .mdm(MDMConnection(name: "New Server"))
        }
    }
}

// MARK: - Mapping to the shared fields
//
// Setting back the connection just read leaves the record unchanged; an
// edit changes only the fields of the edited service, and every other field
// keeps its saved value.

extension ABMConfig {
    nonisolated var connection: Connection {
        get {
            Connection(id: id, name: name,
                       service: kind == .school ? .appleSchoolManager : .appleBusinessManager,
                       signIn: .applePrivateKey, clientID: clientID, keyID: keyID)
        }
        set {
            guard newValue != connection else { return }
            name = newValue.name
            switch newValue.service {
            case .appleBusinessManager: kind = .business
            case .appleSchoolManager: kind = .school
            default: break
            }
            // trimmed on save, as Checkpoint's own editor did
            clientID = newValue.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            keyID = newValue.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension MDMConnection {
    /// The server URL fills both the Jamf Pro server and the Platform API's
    /// Jamf Pro web address, and the account both the client ID and the
    /// username, so switching between them keeps what was typed, as the
    /// old editor did.
    nonisolated var connection: Connection {
        get {
            var shared = Connection(id: id, name: name, service: .jamfPro)
            switch product {
            case .jamfPro where authMethod == .platformGateway:
                shared.service = .jamfPlatform
                shared.signIn = .apiClient
            case .jamfPro:
                shared.signIn = authMethod == .usernamePassword ? .usernamePassword : .apiClient
            case .jamfSchool:
                shared.service = .jamfSchool
                shared.signIn = .schoolAPIKey
            case .intune:
                shared.service = .intune
                shared.signIn = .entraClientSecret
            }
            shared.serverURL = baseURL
            shared.jamfProWebURL = baseURL
            // JTKit's region, named by inference: Checkpoint has its own `JamfRegion`
            shared.region = .init(rawValue: region.rawValue) ?? .us
            shared.environmentID = environmentID
            shared.clientID = account
            shared.username = account
            shared.tenantID = tenantID
            return shared
        }
        set {
            guard newValue != connection else { return }
            name = newValue.name
            switch newValue.service {
            case .jamfPlatform:
                product = .jamfPro
                authMethod = .platformGateway
                baseURL = newValue.jamfProWebURL
                account = newValue.clientID
                region = JamfRegion(rawValue: newValue.region.rawValue) ?? .us
                environmentID = newValue.environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
            case .jamfSchool:
                product = .jamfSchool
                if !MDMAuthMethod.methods(for: .jamfSchool).contains(authMethod) {
                    authMethod = MDMAuthMethod.methods(for: .jamfSchool)[0]
                }
                baseURL = newValue.serverURL
                account = newValue.clientID
            case .intune:
                product = .intune
                authMethod = .entraApp
                account = newValue.clientID
                tenantID = newValue.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                product = .jamfPro
                let usesPassword = newValue.signIn == .usernamePassword
                authMethod = usesPassword ? .usernamePassword : .apiClient
                baseURL = newValue.serverURL
                account = usesPassword ? newValue.username : newValue.clientID
            }
        }
    }
}

// MARK: - Storage

/// The two lists where they have always been: `abmOrgs` and `jamfServers` in
/// UserDefaults, JSON-encoded as Checkpoint always wrote them. Apple
/// organizations come first in the shared list.
@MainActor
final class CheckpointConnectionStorage: ConnectionStorage {
    nonisolated static let appleKey = "abmOrgs"
    // The original key, from when Jamf was the only product.
    nonisolated static let mdmKey = "jamfServers"

    private let apple: UserDefaultsConnectionStorage<ABMConfig>
    private let mdm: UserDefaultsConnectionStorage<MDMConnection>

    init(defaults: UserDefaults = .standard) {
        apple = UserDefaultsConnectionStorage(key: Self.appleKey, defaults: defaults)
        mdm = UserDefaultsConnectionStorage(key: Self.mdmKey, defaults: defaults)
    }

    func load() throws -> [CheckpointConnection] {
        try apple.load().map(CheckpointConnection.apple) + mdm.load().map(CheckpointConnection.mdm)
    }

    /// Each entry goes back to its own list, in the order of the shared list.
    /// A list whose entries didn't change is left exactly as it is.
    func save(_ records: [CheckpointConnection]) throws {
        var orgs = [ABMConfig]()
        var servers = [MDMConnection]()
        for record in records {
            switch record {
            case .apple(let org): orgs.append(org)
            case .mdm(let server): servers.append(server)
            }
        }
        if (try? apple.load()) != orgs { try apple.save(orgs) }
        if (try? mdm.load()) != servers { try mdm.save(servers) }
    }

    func backUpOnce() throws {
        try apple.backUpOnce()
        try mdm.backUpOnce()
    }

    /// Copies only the list that can't be read.
    func keepUnreadableCopy() -> String? {
        var copies = [String]()
        if (try? apple.load()) == nil, let copy = apple.keepUnreadableCopy() { copies.append(copy) }
        if (try? mdm.load()) == nil, let copy = mdm.keepUnreadableCopy() { copies.append(copy) }
        return copies.isEmpty ? nil : copies.joined(separator: " and ")
    }
}

// MARK: - Legacy single-organization setup

/// Single-organization Apple Business layout used before multi-organization
/// support. Decoded only to carry it into `abmOrgs`.
private nonisolated struct LegacyABMConfig: Codable {
    var clientID = ""
    var keyID = ""
}

nonisolated enum LegacyABMMigration {
    static let configKey = "abmConfig"

    /// Carries a pre-multi-organization Apple Business setup into `abmOrgs`,
    /// moving its keychain item to the new per-organization key. The old item
    /// is removed only once the copy reads back, so a failed write can never
    /// lose a private key that cannot be downloaded from Apple again.
    ///
    /// Runs only while no organization is saved. Saved organizations that
    /// can't be read count as saved: they are never written over.
    static func run(defaults: UserDefaults, secrets: any SecretStore) {
        if let saved = defaults.data(forKey: CheckpointConnectionStorage.appleKey) {
            guard let orgs = try? JSONDecoder().decode([ABMConfig].self, from: saved), orgs.isEmpty else { return }
        }
        guard let data = defaults.data(forKey: configKey),
              let legacy = try? JSONDecoder().decode(LegacyABMConfig.self, from: data) else { return }
        let legacyPEM = secrets.secret(for: ABMConfig.legacyPrivateKeyKeychainKey)
        guard !legacy.clientID.isEmpty || !(legacyPEM ?? "").isEmpty else {
            defaults.removeObject(forKey: configKey)
            return
        }
        let org = ABMConfig(name: "Apple Business", clientID: legacy.clientID, keyID: legacy.keyID)
        if let legacyPEM, !legacyPEM.isEmpty {
            secrets.setSecret(legacyPEM, for: org.privateKeyKeychainKey)
            if secrets.secret(for: org.privateKeyKeychainKey) == legacyPEM {
                secrets.setSecret(nil, for: ABMConfig.legacyPrivateKeyKeychainKey)
            }
        }
        if let encoded = try? JSONEncoder().encode([org]) {
            defaults.set(encoded, forKey: CheckpointConnectionStorage.appleKey)
        }
        defaults.removeObject(forKey: configKey)
    }
}

// MARK: - The connection chosen per role

/// The single connection last chosen for each role, saved so it survives a
/// relaunch. "All" is never saved (JTKit's `AllConnectionsChoice`).
nonisolated enum ConnectionChoiceKeys {
    static let apple = "appleConnectionChoice"
    static let mdm = "mdmConnectionChoice"
}

nonisolated enum ConnectionChoiceResolver {
    /// The saved connection while it exists, else the first one.
    static func single(saved: UUID?, among ids: [UUID]) -> UUID? {
        if let saved, ids.contains(saved) { return saved }
        return ids.first
    }
}
