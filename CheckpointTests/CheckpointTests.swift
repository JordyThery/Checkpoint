import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Checkpoint's saved connections in JTKit's shared list.
// Every test uses its own settings domain and an in-memory Keychain, never
// the real ones.

/// Saved data as Checkpoint writes it today.
nonisolated enum SavedData {
    static let businessID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000A001")!
    static let schoolID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000A002")!
    static let olderOrgID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000A003")!

    static let proPasswordID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000B001")!
    static let platformID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000B002")!
    static let schoolServerID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000B003")!
    static let intuneID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000B004")!
    static let proClientID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000B005")!
    static let flavorID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// The third organization was saved before Apple School Manager support: no `kind`.
    static let abmOrgs = """
    [{"kind":"business","clientID":"BUSINESSAPI.abc","keyID":"key-1","id":"\(businessID)","name":"Apple Business Manager"},\
    {"kind":"school","clientID":"SCHOOLAPI.def","keyID":"key-2","id":"\(schoolID)","name":"Apple School Manager"},\
    {"clientID":"","keyID":"","id":"\(olderOrgID)","name":"Empty"}]
    """

    /// One of each kind, plus a Jamf School server saved by 2.0.0–2.2.0
    /// under `flavor`, before region, environment and tenant existed.
    static let jamfServers = """
    [{"id":"\(proPasswordID)","baseURL":"https://jamf.example.com","name":"Example Password Jamf Pro","region":"us","environmentID":"","account":"admin","tenantID":"","authMethod":"usernamePassword","product":"pro"},\
    {"id":"\(platformID)","baseURL":"https://jamf.example.com","name":"Example Gateway","region":"eu","environmentID":"EEEEEEEE-1111-4000-8000-00000000E001","account":"platform-client","tenantID":"","authMethod":"platformGateway","product":"pro"},\
    {"id":"\(schoolServerID)","baseURL":"https://example-school.jamfcloud.com","name":"Jamf School","region":"us","environmentID":"","account":"999001","tenantID":"","authMethod":"apiClient","product":"school"},\
    {"id":"\(intuneID)","baseURL":"","name":"Example Intune","region":"us","environmentID":"","account":"EEEEEEEE-2222-4000-8000-00000000C001","tenantID":"contoso.onmicrosoft.com","authMethod":"entraApp","product":"intune"},\
    {"id":"\(proClientID)","baseURL":"https://example.jamfcloud.com/","name":"Example Jamf Pro","region":"us","environmentID":"","account":"client-1","tenantID":"","authMethod":"apiClient","product":"pro"},\
    {"id":"\(flavorID)","baseURL":"https://old.example.jamfcloud.com","name":"Old School","authMethod":"apiClient","account":"1234","flavor":"school"}]
    """
}

/// Its own settings domain and Keychain, filled with today's saved data.
@MainActor
final class Fixture {
    let defaults: UserDefaults
    /// A file path in the temporary folder, never a file in Preferences (`TestSettings`).
    let domain: String
    let secrets = InMemorySecretStore()

    init(apple: String? = SavedData.abmOrgs, mdm: String? = SavedData.jamfServers) {
        (domain, defaults) = TestSettings.makeDefaults("fixture")
        if let apple { defaults.set(Data(apple.utf8), forKey: "abmOrgs") }
        if let mdm { defaults.set(Data(mdm.utf8), forKey: "jamfServers") }
    }

    func settings() -> AppSettings {
        AppSettings(defaults: defaults, secrets: secrets)
    }

    func data(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }

    /// Decoded with Checkpoint's own types, as the previous version reads them.
    func savedOrgs() throws -> [ABMConfig] {
        try JSONDecoder().decode([ABMConfig].self, from: #require(data("abmOrgs")))
    }

    func savedServers() throws -> [MDMConnection] {
        try JSONDecoder().decode([MDMConnection].self, from: #require(data("jamfServers")))
    }
}

// MARK: - The two lists as one

@MainActor
@Suite("Combining abmOrgs and jamfServers")
struct CombinedListTests {

    @Test func bothListsLoadAsOneAppleFirst() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        #expect(settings.connections.problem == nil)
        #expect(settings.connections.records.map(\.id) == [
            SavedData.businessID, SavedData.schoolID, SavedData.olderOrgID,
            SavedData.proPasswordID, SavedData.platformID, SavedData.schoolServerID,
            SavedData.intuneID, SavedData.proClientID, SavedData.flavorID,
        ])
        #expect(settings.abmOrgs == (try fixture.savedOrgs()))
        #expect(settings.mdmConnections == (try fixture.savedServers()))
    }

    @Test func olderFieldsAreStillRead() throws {
        let settings = Fixture().settings()
        #expect(settings.abmOrgs.first { $0.id == SavedData.olderOrgID }?.kind == .business)
        let old = try #require(settings.mdmConnections.first { $0.id == SavedData.flavorID })
        #expect(old.product == .jamfSchool)
        #expect(old.region == .us)
        #expect(old.environmentID.isEmpty)
    }

    @Test func savingAnMDMConnectionLeavesTheAppleListUntouched() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        let appleBefore = fixture.data("abmOrgs")
        var record = try #require(settings.connections.record(id: SavedData.proClientID))
        record.connection.name = "Renamed"
        try settings.connections.save(record)

        #expect(fixture.data("abmOrgs") == appleBefore)
        let servers = try fixture.savedServers()
        #expect(servers.map(\.id) == settings.mdmConnections.map(\.id))
        #expect(servers.first { $0.id == SavedData.proClientID }?.name == "Renamed")
        // the others read back exactly as before
        let before = try JSONDecoder().decode([MDMConnection].self, from: Data(SavedData.jamfServers.utf8))
        #expect(servers.filter { $0.id != SavedData.proClientID } == before.filter { $0.id != SavedData.proClientID })
    }

    @Test func savingAnOrganizationLeavesTheMDMListUntouched() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        let mdmBefore = fixture.data("jamfServers")
        var record = try #require(settings.connections.record(id: SavedData.schoolID))
        record.connection.keyID = " key-3 "
        try settings.connections.save(record)

        #expect(fixture.data("jamfServers") == mdmBefore)
        let orgs = try fixture.savedOrgs()
        #expect(orgs.map(\.id) == [SavedData.businessID, SavedData.schoolID, SavedData.olderOrgID])
        #expect(orgs[1].keyID == "key-3")
        #expect(orgs[1].kind == .school)
    }

    @Test func aNewConnectionGoesToItsOwnList() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        try settings.connections.save(CheckpointConnection.new(for: .appleSchoolManager))
        try settings.connections.save(CheckpointConnection.new(for: .intune))
        #expect(try fixture.savedOrgs().count == 4)
        #expect(try fixture.savedOrgs().last?.kind == .school)
        #expect(try fixture.savedServers().count == 7)
        #expect(try fixture.savedServers().last?.product == .intune)
    }

    @Test func nothingSavedMeansAnEmptyList() {
        let settings = Fixture(apple: nil, mdm: nil).settings()
        #expect(settings.connections.records.isEmpty)
        #expect(settings.connections.problem == nil)
    }

    @Test func anUnreadableListIsKeptCopiedAndNeverSavedOver() throws {
        let fixture = Fixture(apple: "not a list")
        let settings = fixture.settings()
        #expect(settings.connections.problem != nil)
        #expect(settings.connections.records.isEmpty)

        #expect(throws: ConnectionStoreError.self) {
            try settings.connections.save(CheckpointConnection.new(for: .jamfPro))
        }
        #expect(fixture.data("abmOrgs") == Data("not a list".utf8))
        #expect(fixture.data("jamfServers") == Data(SavedData.jamfServers.utf8))
        let keys = fixture.defaults.dictionaryRepresentation().keys
        #expect(keys.contains { $0.hasPrefix("abmOrgs.unreadable-") })
        #expect(!keys.contains { $0.hasPrefix("jamfServers.unreadable-") })
    }

    @Test func theFirstSaveBacksUpBothListsOnce() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        var record = try #require(settings.connections.record(id: SavedData.intuneID))
        record.connection.name = "First"
        try settings.connections.save(record)
        record.connection.name = "Second"
        try settings.connections.save(record)

        #expect(fixture.data("abmOrgs.backup") == Data(SavedData.abmOrgs.utf8))
        #expect(fixture.data("jamfServers.backup") == Data(SavedData.jamfServers.utf8))
        // a relaunch doesn't replace the backup either
        var again = try #require(fixture.settings().connections.record(id: SavedData.intuneID))
        again.connection.name = "Third"
        try fixture.settings().connections.save(again)
        #expect(fixture.data("jamfServers.backup") == Data(SavedData.jamfServers.utf8))
    }
}

// MARK: - Each kind of connection

@MainActor
@Suite("Mapping each kind of connection")
struct MappingTests {

    @Test func eachKindShowsAsItsService() throws {
        let settings = Fixture().settings()
        func shared(_ id: UUID) throws -> Connection { try #require(settings.connections.record(id: id)).connection }

        #expect(try shared(SavedData.businessID).service == .appleBusinessManager)
        #expect(try shared(SavedData.schoolID).service == .appleSchoolManager)
        #expect(try shared(SavedData.schoolID).signIn == .applePrivateKey)
        #expect(try shared(SavedData.schoolID).keyID == "key-2")

        let password = try shared(SavedData.proPasswordID)
        #expect(password.service == .jamfPro)
        #expect(password.signIn == .usernamePassword)
        #expect(password.username == "admin")
        #expect(password.serverURL == "https://jamf.example.com")

        let platform = try shared(SavedData.platformID)
        #expect(platform.service == .jamfPlatform)
        #expect(platform.signIn == .apiClient)
        #expect(platform.region == .eu)
        #expect(platform.environmentID == "EEEEEEEE-1111-4000-8000-00000000E001")
        #expect(platform.clientID == "platform-client")
        #expect(platform.jamfProWebURL == "https://jamf.example.com")

        let school = try shared(SavedData.schoolServerID)
        #expect(school.service == .jamfSchool)
        #expect(school.signIn == .schoolAPIKey)
        #expect(school.clientID == "999001")

        let intune = try shared(SavedData.intuneID)
        #expect(intune.service == .intune)
        #expect(intune.signIn == .entraClientSecret)
        #expect(intune.tenantID == "contoso.onmicrosoft.com")

        let client = try shared(SavedData.proClientID)
        #expect(client.service == .jamfPro)
        #expect(client.signIn == .apiClient)
        #expect(client.clientID == "client-1")
        #expect(client.issues.isEmpty)
    }

    @Test func settingBackAnUnchangedConnectionChangesNothing() {
        let settings = Fixture().settings()
        // and two records with leftovers the editor never offers
        let leftovers: [CheckpointConnection] = [
            .mdm(MDMConnection(name: "School", product: .jamfSchool, baseURL: "https://s.example.com",
                               authMethod: .usernamePassword, account: "1", region: .apac, environmentID: "x")),
            .mdm(MDMConnection(name: "Pro", product: .jamfPro, authMethod: .entraApp, tenantID: "t")),
        ]
        for record in settings.connections.records + leftovers {
            var copy = record
            copy.connection = copy.connection
            #expect(copy == record)
        }
    }

    @Test func switchingBetweenJamfProAndThePlatformAPIKeepsWhatWasTyped() throws {
        let settings = Fixture().settings()
        var record = try #require(settings.connections.record(id: SavedData.platformID))
        record.connection.service = .jamfPro
        guard case .mdm(let direct) = record else { Issue.record("not MDM"); return }
        #expect(direct.product == .jamfPro)
        #expect(direct.authMethod == .apiClient)
        #expect(direct.baseURL == "https://jamf.example.com")
        #expect(direct.account == "platform-client")

        record.connection.service = .jamfPlatform
        record.connection.region = .apac
        record.connection.environmentID = " EEEEEEEE-1111-4000-8000-00000000E001 "
        guard case .mdm(let gateway) = record else { Issue.record("not MDM"); return }
        #expect(gateway.authMethod == .platformGateway)
        #expect(gateway.region == JamfRegion.apac)
        #expect(gateway.environmentID == "EEEEEEEE-1111-4000-8000-00000000E001")
        #expect(gateway.baseURL == "https://jamf.example.com")
    }

    @Test func switchingBetweenJamfProAndIntuneKeepsWhatApplies() throws {
        let settings = Fixture().settings()
        var record = try #require(settings.connections.record(id: SavedData.proClientID))
        record.connection.service = .intune
        record.connection.tenantID = " fabrikam.onmicrosoft.com "
        guard case .mdm(let intune) = record else { Issue.record("not MDM"); return }
        #expect(intune.product == .intune)
        #expect(intune.authMethod == .entraApp)
        #expect(intune.account == "client-1")
        #expect(intune.tenantID == "fabrikam.onmicrosoft.com")
        // Intune has no server address; the saved one is kept for a switch back.
        #expect(intune.baseURL == "https://example.jamfcloud.com/")

        record.connection.service = .jamfPro
        guard case .mdm(let pro) = record else { Issue.record("not MDM"); return }
        #expect(pro.product == .jamfPro)
        #expect(pro.authMethod == .apiClient)
        #expect(pro.baseURL == "https://example.jamfcloud.com/")
        #expect(pro.account == "client-1")
        #expect(record.connection.service == .jamfPro)
        #expect(record.connection.signIn == .apiClient)
    }

    @Test func switchingBetweenJamfSchoolAndJamfProKeepsWhatApplies() throws {
        let settings = Fixture().settings()
        var record = try #require(settings.connections.record(id: SavedData.schoolServerID))
        record.connection.service = .jamfPro
        guard case .mdm(let pro) = record else { Issue.record("not MDM"); return }
        #expect(pro.product == .jamfPro)
        #expect(pro.authMethod == .apiClient)
        #expect(pro.baseURL == "https://example-school.jamfcloud.com")
        #expect(pro.account == "999001")
        #expect(record.connection.signIn == .apiClient)

        record.connection.service = .jamfSchool
        guard case .mdm(let school) = record else { Issue.record("not MDM"); return }
        #expect(school.product == .jamfSchool)
        #expect(school.authMethod == .apiClient)
        #expect(school.baseURL == "https://example-school.jamfcloud.com")
        #expect(school.account == "999001")
        #expect(record.connection.signIn == .schoolAPIKey)
    }

    @Test func aJamfProPasswordConnectionBecomesJamfSchoolWithAnAPIKey() throws {
        let settings = Fixture().settings()
        var record = try #require(settings.connections.record(id: SavedData.proPasswordID))
        record.connection.service = .jamfSchool
        guard case .mdm(let school) = record else { Issue.record("not MDM"); return }
        #expect(school.product == .jamfSchool)
        // Jamf School has no username-and-password sign-in.
        #expect(school.authMethod == .apiClient)
        #expect(school.baseURL == "https://jamf.example.com")
        #expect(school.account == "admin")
    }

    @Test func editsWriteTheFieldsCheckpointSaves() throws {
        let settings = Fixture().settings()
        var password = try #require(settings.connections.record(id: SavedData.proPasswordID))
        password.connection.signIn = .apiClient
        password.connection.clientID = "new-client"
        guard case .mdm(let server) = password else { Issue.record("not MDM"); return }
        #expect(server.authMethod == .apiClient)
        #expect(server.account == "new-client")

        var intune = try #require(settings.connections.record(id: SavedData.intuneID))
        intune.connection.tenantID = " fabrikam.onmicrosoft.com "
        guard case .mdm(let tenant) = intune else { Issue.record("not MDM"); return }
        #expect(tenant.tenantID == "fabrikam.onmicrosoft.com")
        #expect(tenant.authMethod == .entraApp)

        var org = try #require(settings.connections.record(id: SavedData.businessID))
        org.connection.service = .appleSchoolManager
        org.connection.clientID = " SCHOOLAPI.xyz "
        guard case .apple(let changed) = org else { Issue.record("not Apple"); return }
        #expect(changed.kind == .school)
        #expect(changed.clientID == "SCHOOLAPI.xyz")
    }

    @Test func newConnectionsMatchWhatCheckpointCreated() {
        guard case .mdm(let platform) = CheckpointConnection.new(for: .jamfPlatform),
              case .mdm(let intune) = CheckpointConnection.new(for: .intune),
              case .apple(let school) = CheckpointConnection.new(for: .appleSchoolManager) else {
            Issue.record("wrong list"); return
        }
        #expect(platform.authMethod == .platformGateway)
        #expect(platform.product == .jamfPro)
        #expect(intune.authMethod == .entraApp)
        #expect(school.kind == .school)
        #expect(school.name == "New Organization")
    }
}

// MARK: - Addresses saved without https://

/// 2.8.1 accepted a server URL without a scheme and added `https://` itself;
/// 2.9.0 handed the address to JTKit as saved, which refused it.
@MainActor
@Suite("Server URLs saved without https://")
struct SchemeLessAddressTests {
    /// JTKit 1.1 adds https:// to an address without a scheme and refuses http://.
    static let message = "Use an https:// address."

    /// A Jamf Pro and a Jamf School server as 2.8.1 saved them, and one on http://.
    static let jamfServers = """
    [{"id":"\(SavedData.proClientID)","baseURL":"myorg.example.com","name":"Pro","region":"us","environmentID":"","account":"client-1","tenantID":"","authMethod":"apiClient","product":"pro"},\
    {"id":"\(SavedData.schoolServerID)","baseURL":"school.example.com","name":"School","region":"us","environmentID":"","account":"999001","tenantID":"","authMethod":"apiClient","product":"school"},\
    {"id":"\(SavedData.proPasswordID)","baseURL":"http://plain.example.com","name":"Plain","region":"us","environmentID":"","account":"admin","tenantID":"","authMethod":"usernamePassword","product":"pro"}]
    """

    private func server(_ settings: AppSettings, _ id: UUID) throws -> MDMConnection {
        guard case .mdm(let server) = try #require(settings.connections.record(id: id)) else {
            throw CancellationError()
        }
        return server
    }

    @Test("A Jamf Pro address without a scheme reads with https:// and its requests go to https://")
    func jamfPro() async throws {
        let settings = Fixture(apple: nil, mdm: Self.jamfServers).settings()
        let pro = try server(settings, SavedData.proClientID)
        #expect(pro.connection.serverURL == "https://myorg.example.com")
        #expect(pro.connection.issues.isEmpty)

        let mock = readServer { request in
            request.path.hasSuffix("/v3/computer-prestages") ? .json(200, #"{"totalCount":0,"results":[]}"#) : nil
        }
        let client = try #require(JamfClient(config: pro, secret: { "SECRET-client" }, session: mock.session))
        _ = try await client.prestages(family: .computer)
        #expect(!mock.requests.isEmpty)
        #expect(mock.requests.allSatisfy { $0.url.scheme == "https" && $0.url.host() == "myorg.example.com" })
    }

    @Test("A Jamf School address without a scheme reads with https:// and its requests go to https://")
    func jamfSchool() async throws {
        let settings = Fixture(apple: nil, mdm: Self.jamfServers).settings()
        let school = try server(settings, SavedData.schoolServerID)
        #expect(school.connection.serverURL == "https://school.example.com")
        #expect(school.connection.issues.isEmpty)

        let mock = MockServer { request in
            request.path == "/api/devices" ? .json(200, #"{"devices":[]}"#) : .json(200, "{}")
        }
        let client = try #require(JamfSchoolClient(config: school, secret: "SECRET-api-key", session: mock.session))
        _ = try await client.fleet()
        #expect(!mock.requests.isEmpty)
        #expect(mock.requests.allSatisfy { $0.url.scheme == "https" && $0.url.host() == "school.example.com" })
    }

    @Test("Nothing is written until an edit, which saves https:// and keeps the secret")
    func savedWithSchemeAtTheNextEdit() throws {
        let fixture = Fixture(apple: nil, mdm: Self.jamfServers)
        fixture.secrets.setSecret("SECRET-client", for: "jamf.\(SavedData.proClientID.uuidString)")
        let settings = fixture.settings()
        var record = try #require(settings.connections.record(id: SavedData.proClientID))
        record.connection = record.connection
        #expect(record == settings.connections.record(id: SavedData.proClientID))

        record.connection.name = "Renamed"
        try settings.connections.save(record)
        #expect(try fixture.savedServers().first { $0.id == SavedData.proClientID }?.baseURL == "https://myorg.example.com")
        #expect(fixture.secrets.secret(for: "jamf.\(SavedData.proClientID.uuidString)") == "SECRET-client")
    }

    @Test("An address with https:// is read and saved exactly as before")
    func httpsUnchanged() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        var record = try #require(settings.connections.record(id: SavedData.proClientID))
        #expect(record.connection.serverURL == "https://example.jamfcloud.com/")
        #expect(record.connection.jamfProWebURL == "https://example.jamfcloud.com/")
        record.connection.name = "Renamed"
        try settings.connections.save(record)
        #expect(try fixture.savedServers().first { $0.id == SavedData.proClientID }?.baseURL == "https://example.jamfcloud.com/")
    }

    @Test("An http:// address is refused before any request")
    func httpRefused() async throws {
        let settings = Fixture(apple: nil, mdm: Self.jamfServers).settings()
        let plain = try server(settings, SavedData.proPasswordID)
        #expect(plain.connection.serverURL == "http://plain.example.com")
        let mock = readServer { _ in .json(200, #"{"totalCount":0,"results":[]}"#) }
        let client = try #require(JamfClient(config: plain, secret: { "SECRET-password" }, session: mock.session))
        await #expect(throws: (any Error).self) { _ = try await client.prestages(family: .computer) }
        #expect(mock.requests.isEmpty, "nothing is sent over http://")
    }

    @Test("Settings asks for https:// for an http:// address; fixing only the scheme keeps the secret")
    func httpAsksForHTTPS() throws {
        let fixture = Fixture(apple: nil, mdm: Self.jamfServers)
        fixture.secrets.setSecret("SECRET-password", for: "jamf.\(SavedData.proPasswordID.uuidString)")
        let settings = fixture.settings()
        var record = try #require(settings.connections.record(id: SavedData.proPasswordID))
        #expect(record.connection.issues == [Self.message])

        record.connection.serverURL = "https://plain.example.com"
        #expect(record.connection.issues.isEmpty)
        try settings.connections.save(record)
        #expect(try fixture.savedServers().first { $0.id == SavedData.proPasswordID }?.baseURL == "https://plain.example.com")
        #expect(fixture.secrets.secret(for: "jamf.\(SavedData.proPasswordID.uuidString)") == "SECRET-password")
    }
}

// MARK: - Keychain names

@MainActor
@Suite("Keychain items")
struct KeychainNameTests {

    @Test func accountsAreTheOnesCheckpointAlwaysUsed() {
        let settings = Fixture().settings()
        #expect(CheckpointSecrets.service == "DeviceStatus.secrets")
        for record in settings.connections.records {
            switch record {
            case .apple(let org):
                #expect(CheckpointSecrets.account(for: record.connection) == "abm.\(org.id.uuidString)")
                #expect(CheckpointSecrets.account(for: record.connection) == org.privateKeyKeychainKey)
            case .mdm(let server):
                #expect(CheckpointSecrets.account(for: record.connection) == "jamf.\(server.id.uuidString)")
            }
        }
    }

    @Test func existingSecretsAreFound() throws {
        let fixture = Fixture()
        fixture.secrets.setSecret("pem", for: "abm.\(SavedData.businessID.uuidString)")
        fixture.secrets.setSecret("password", for: "jamf.\(SavedData.proPasswordID.uuidString)")
        let settings = fixture.settings()
        #expect(try settings.readSecret(for: try #require(settings.connections.record(id: SavedData.businessID))) == "pem")
        #expect(try settings.readSecret(for: try #require(settings.connections.record(id: SavedData.proPasswordID))) == "password")
    }

    @Test func savingAndDeletingUseTheSameItems() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        let org = try #require(settings.connections.record(id: SavedData.schoolID))
        let server = try #require(settings.connections.record(id: SavedData.schoolServerID))
        try settings.connections.save(org, secrets: [.main: "-----BEGIN PRIVATE KEY-----"])
        try settings.connections.save(server, secrets: [.main: "api-key"])
        #expect(fixture.secrets.all == ["abm.\(SavedData.schoolID.uuidString)": "-----BEGIN PRIVATE KEY-----",
                                        "jamf.\(SavedData.schoolServerID.uuidString)": "api-key"])
        // secrets never land in the settings
        #expect(!String(decoding: try #require(fixture.data("jamfServers")), as: UTF8.self).contains("api-key"))

        try settings.connections.delete(id: SavedData.schoolID)
        try settings.connections.delete(id: SavedData.schoolServerID)
        #expect(fixture.secrets.all.isEmpty)
    }
}

// MARK: - The legacy single-organization key

@MainActor
@Suite("Moving the legacy abm.privateKey")
struct LegacyKeyMoveTests {
    static let legacyConfig = #"{"clientID":"BUSINESSAPI.legacy","keyID":"legacy-key"}"#

    @Test func theKeyMovesToTheNewOrganization() throws {
        let fixture = Fixture(apple: nil)
        fixture.defaults.set(Data(Self.legacyConfig.utf8), forKey: "abmConfig")
        fixture.secrets.setSecret("legacy-pem", for: "abm.privateKey")
        let settings = fixture.settings()

        let org = try #require(settings.abmOrgs.first)
        #expect(settings.abmOrgs.count == 1)
        #expect(org.name == "Apple Business")
        #expect(org.kind == .business)
        #expect(org.clientID == "BUSINESSAPI.legacy")
        #expect(org.keyID == "legacy-key")
        #expect(fixture.secrets.all == ["abm.\(org.id.uuidString)": "legacy-pem"])
        #expect(fixture.data("abmConfig") == nil)
        #expect(try fixture.savedOrgs() == [org])
        // the MDM list is read as it was
        #expect(settings.mdmConnections.count == 6)
    }

    @Test func aKeyWithoutClientIDStillMoves() throws {
        let fixture = Fixture(apple: nil)
        fixture.defaults.set(Data(#"{"clientID":"","keyID":""}"#.utf8), forKey: "abmConfig")
        fixture.secrets.setSecret("legacy-pem", for: "abm.privateKey")
        let org = try #require(fixture.settings().abmOrgs.first)
        #expect(fixture.secrets.all == ["abm.\(org.id.uuidString)": "legacy-pem"])
    }

    @Test func theOldKeyStaysWhenTheCopyFails() throws {
        let fixture = Fixture(apple: nil)
        fixture.defaults.set(Data(Self.legacyConfig.utf8), forKey: "abmConfig")
        fixture.secrets.setSecret("legacy-pem", for: "abm.privateKey")
        fixture.secrets.refusesWrites = true
        let settings = fixture.settings()

        // Nothing saved, the old setup kept: the move is tried again.
        #expect(settings.abmOrgs.isEmpty)
        #expect(fixture.secrets.all == ["abm.privateKey": "legacy-pem"])
        #expect(fixture.data("abmConfig") != nil)

        fixture.secrets.refusesWrites = false
        let org = try #require(fixture.settings().abmOrgs.first)
        #expect(fixture.secrets.all == ["abm.\(org.id.uuidString)": "legacy-pem"])
        #expect(fixture.data("abmConfig") == nil)
    }

    @Test func anEmptyLegacySetupIsJustRemoved() {
        let fixture = Fixture(apple: nil)
        fixture.defaults.set(Data(#"{"clientID":"","keyID":""}"#.utf8), forKey: "abmConfig")
        let settings = fixture.settings()
        #expect(settings.abmOrgs.isEmpty)
        #expect(fixture.data("abmConfig") == nil)
        #expect(fixture.data("abmOrgs") == nil)
    }

    @Test func itRunsOnAnEmptySavedList() throws {
        let fixture = Fixture(apple: "[]")
        fixture.defaults.set(Data(Self.legacyConfig.utf8), forKey: "abmConfig")
        #expect(fixture.settings().abmOrgs.count == 1)
    }

    @Test func itDoesNotRunWhenOrganizationsExist() {
        // as on a Mac that still has the old key next to several organizations
        let fixture = Fixture()
        fixture.defaults.set(Data(Self.legacyConfig.utf8), forKey: "abmConfig")
        fixture.secrets.setSecret("legacy-pem", for: "abm.privateKey")
        let settings = fixture.settings()

        #expect(settings.abmOrgs.count == 3)
        #expect(fixture.secrets.all == ["abm.privateKey": "legacy-pem"])
        #expect(fixture.data("abmConfig") == Data(Self.legacyConfig.utf8))
        #expect(fixture.data("abmOrgs") == Data(SavedData.abmOrgs.utf8))
    }

    @Test func itNeverWritesOverAnUnreadableList() {
        let fixture = Fixture(apple: "not a list")
        fixture.defaults.set(Data(Self.legacyConfig.utf8), forKey: "abmConfig")
        fixture.secrets.setSecret("legacy-pem", for: "abm.privateKey")
        _ = fixture.settings()

        #expect(fixture.data("abmOrgs") == Data("not a list".utf8))
        #expect(fixture.data("abmConfig") == Data(Self.legacyConfig.utf8))
        #expect(fixture.secrets.all == ["abm.privateKey": "legacy-pem"])
    }
}

// MARK: - The connection chosen per role

@MainActor
@Suite("Remembering the chosen connections")
struct ChoiceTests {

    @Test func aSingleChoiceSurvivesARelaunch() {
        let fixture = Fixture()
        let model = LookupModel(settings: fixture.settings())
        model.abmScope = .organization(SavedData.schoolID)
        model.mdmScope = .connection(SavedData.intuneID)

        let relaunched = LookupModel(settings: fixture.settings())
        #expect(relaunched.abmScope == .organization(SavedData.schoolID))
        #expect(relaunched.mdmScope == .connection(SavedData.intuneID))
    }

    @Test func allIsForThisSessionOnly() {
        let fixture = Fixture()
        let model = LookupModel(settings: fixture.settings())
        model.abmScope = .organization(SavedData.schoolID)
        model.abmScope = .allOrganizations
        model.mdmScope = .connection(SavedData.platformID)
        model.mdmScope = .allConnections
        #expect(model.abmScope == .allOrganizations)
        #expect(model.readsAllConnections)

        // at launch: the last single ones used
        let relaunched = LookupModel(settings: fixture.settings())
        #expect(relaunched.abmScope == .organization(SavedData.schoolID))
        #expect(relaunched.mdmScope == .connection(SavedData.platformID))
        #expect(fixture.defaults.string(forKey: ConnectionChoiceKeys.apple) == SavedData.schoolID.uuidString)
    }

    @Test func theRolesShareTheChoice() {
        let model = LookupModel(settings: Fixture().settings())
        model.mdmScope = .allConnections
        #expect(model.mdmRole.usesAll(connectionCount: model.settings.mdmConnections.count))
        #expect(!model.appleRole.usesAll(connectionCount: model.settings.abmOrgs.count))
        #expect(model.appleRole.accepts(Connection(name: "", service: .appleSchoolManager)))
        #expect(!model.appleRole.accepts(Connection(name: "", service: .intune)))
    }

    @Test func withoutASavedChoiceTheFirstIsUsed() {
        let model = LookupModel(settings: Fixture().settings())
        #expect(model.abmScope == .organization(SavedData.businessID))
        #expect(model.mdmScope == .connection(SavedData.proPasswordID))
        #expect(LookupModel(settings: Fixture(apple: nil, mdm: nil).settings()).abmScope == .allOrganizations)
    }

    @Test func aDeletedChoiceFallsBackToTheFirst() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        let model = LookupModel(settings: settings)
        model.mdmScope = .connection(SavedData.intuneID)
        try settings.connections.delete(id: SavedData.intuneID)
        #expect(model.mdmScope == .connection(SavedData.proPasswordID))
    }

    @Test func allEndsWhenOneConnectionIsLeft() throws {
        let fixture = Fixture(apple: """
        [{"kind":"business","clientID":"a","keyID":"b","id":"\(SavedData.businessID)","name":"One"},\
        {"kind":"school","clientID":"c","keyID":"d","id":"\(SavedData.schoolID)","name":"Two"}]
        """)
        let settings = fixture.settings()
        let model = LookupModel(settings: settings)
        model.abmScope = .allOrganizations
        try settings.connections.delete(id: SavedData.schoolID)
        model.reconcileABMScope()
        #expect(model.abmScope == .organization(SavedData.businessID))

        // a second organization added later doesn't bring "All" back unasked
        try settings.connections.save(CheckpointConnection.new(for: .appleBusinessManager))
        #expect(model.abmScope == .organization(SavedData.businessID))
    }

    @Test func resolverPrefersTheSavedConnection() {
        let a = UUID(), b = UUID()
        #expect(ConnectionChoiceResolver.single(saved: b, among: [a, b]) == b)
        #expect(ConnectionChoiceResolver.single(saved: UUID(), among: [a, b]) == a)
        #expect(ConnectionChoiceResolver.single(saved: nil, among: [a, b]) == a)
        #expect(ConnectionChoiceResolver.single(saved: a, among: []) == nil)
    }
}
