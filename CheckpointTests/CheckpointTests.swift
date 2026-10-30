import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Checkpoint's saved connections in JTKit's shared list (ROADMAP step 4).
// Every test uses its own settings domain and an in-memory Keychain, never
// the real ones.

/// Saved data as Checkpoint writes it today.
nonisolated enum SavedData {
    static let businessID = UUID(uuidString: "221C8C35-39FE-46E6-8180-901EB03E7666")!
    static let schoolID = UUID(uuidString: "85885B36-6AA0-4199-B9A7-6A350D9FF830")!
    static let olderOrgID = UUID(uuidString: "83DD4E5C-675F-484F-9F02-A1279A12D770")!

    static let proPasswordID = UUID(uuidString: "A56B95A9-F251-4E89-93DE-75D18119AA11")!
    static let platformID = UUID(uuidString: "F960ECC5-08B0-45B9-A7BC-067125C0D69A")!
    static let schoolServerID = UUID(uuidString: "4ABFD4C0-D153-4814-9895-3047F6CC5963")!
    static let intuneID = UUID(uuidString: "E51E496D-2A76-4546-8458-3ABF5273D387")!
    static let proClientID = UUID(uuidString: "77DAF8BA-C8F0-41FD-BF6A-3240D071F29F")!
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
    [{"id":"\(proPasswordID)","baseURL":"https://jamf.example.com","name":"API Jamf Pro","region":"us","environmentID":"","account":"admin","tenantID":"","authMethod":"usernamePassword","product":"pro"},\
    {"id":"\(platformID)","baseURL":"https://jamf.example.com","name":"Platform Jamf Pro","region":"eu","environmentID":"0F2C1B0A-1111-2222-3333-444455556666","account":"platform-client","tenantID":"","authMethod":"platformGateway","product":"pro"},\
    {"id":"\(schoolServerID)","baseURL":"https://school.jamfcloud.com","name":"Jamf School","region":"us","environmentID":"","account":"067680","tenantID":"","authMethod":"apiClient","product":"school"},\
    {"id":"\(intuneID)","baseURL":"","name":"Intune Test","region":"us","environmentID":"","account":"6F1B2C3D-0000-1111-2222-333344445555","tenantID":"contoso.onmicrosoft.com","authMethod":"entraApp","product":"intune"},\
    {"id":"\(proClientID)","baseURL":"https://example.jamfcloud.com/","name":"Jamf Pro sandbox","region":"us","environmentID":"","account":"client-1","tenantID":"","authMethod":"apiClient","product":"pro"},\
    {"id":"\(flavorID)","baseURL":"https://old.jamfcloud.com","name":"Old School","authMethod":"apiClient","account":"1234","flavor":"school"}]
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
        #expect(platform.environmentID == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(platform.clientID == "platform-client")
        #expect(platform.jamfProWebURL == "https://jamf.example.com")

        let school = try shared(SavedData.schoolServerID)
        #expect(school.service == .jamfSchool)
        #expect(school.signIn == .schoolAPIKey)
        #expect(school.clientID == "067680")

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
        record.connection.environmentID = " 0F2C1B0A-1111-2222-3333-444455556666 "
        guard case .mdm(let gateway) = record else { Issue.record("not MDM"); return }
        #expect(gateway.authMethod == .platformGateway)
        #expect(gateway.region == JamfRegion.apac)
        #expect(gateway.environmentID == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(gateway.baseURL == "https://jamf.example.com")
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
                #expect(CheckpointSecrets.account(for: record.connection) == server.secretKeychainKey)
            }
        }
    }

    @Test func existingSecretsAreFound() throws {
        let fixture = Fixture()
        fixture.secrets.setSecret("pem", for: "abm.\(SavedData.businessID.uuidString)")
        fixture.secrets.setSecret("password", for: "jamf.\(SavedData.proPasswordID.uuidString)")
        let settings = fixture.settings()
        #expect(settings.secret(for: try #require(settings.connections.record(id: SavedData.businessID))) == "pem")
        #expect(settings.secret(for: try #require(settings.connections.record(id: SavedData.proPasswordID))) == "password")
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

        #expect(settings.abmOrgs.count == 1)
        #expect(fixture.secrets.all == ["abm.privateKey": "legacy-pem"])
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
