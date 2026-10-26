import CryptoKit
import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Checkpoint on JTKit's networking (ROADMAP step 5): Jamf Pro sign-in and
// sending through JTKit, the other services through its request recorder,
// one client per connection, and what the activity log may record. Every
// test uses its own fake server, settings domain and in-memory Keychain.

/// Fields that must never appear in a recorded body: each value starts with
/// "SECRET-", so one search finds any that got through.
nonisolated enum Laced {
    /// Secret fields, an extension attribute and personal blocks, to put
    /// inside any record.
    static let fields = [
        #""unlockToken":"SECRET-unlock","passcode":"SECRET-passcode","pin":"SECRET-pin""#,
        #""password":"SECRET-password","recoveryLockPassword":"SECRET-recovery-lock""#,
        #""personalRecoveryKey":"SECRET-filevault","escrowToken":"SECRET-escrow""#,
        #""client_secret":"SECRET-client","access_token":"SECRET-access""#,
        #""extensionAttributes":[{"name":"Wi-Fi key","values":["SECRET-ea"]}]"#,
        #""owner":{"name":"SECRET-owner"},"notes":"SECRET-notes""#,
    ].joined(separator: ",")

    static let computers = #"""
    {"totalCount":1,"results":[{"id":"7","udid":"5D3B6C1A-0000-1111-2222-333344445555",
     "general":{"name":"Lab Mac","managementId":"M-7",\#(fields)},
     "hardware":{"serialNumber":"C02XK1JHJG5H",\#(fields)},
     "diskEncryption":{"fileVault2Enabled":true,\#(fields)},
     "operatingSystem":{"version":"15.1",\#(fields)},
     "userAndLocation":{"email":"SECRET-user@example.com","departmentId":"1"},
     "localUserAccounts":[{"username":"SECRET-local-account"}],
     "certificates":[{"commonName":"SECRET-certificate"}],
     "security":{"activationLockEnabled":"SECRET-not-requested"},
     "extensionAttributes":[{"values":["SECRET-ea-top"]}]}]}
    """#

    static let mobileDevices = #"""
    {"totalCount":1,"results":[{"mobileDeviceId":"12","deviceType":"iOS",
     "general":{"displayName":"Lab iPad","udid":"00008103-001A2C3E0C38001E",\#(fields)},
     "hardware":{"serialNumber":"DMPXK1JHJG5H"},
     "security":{"passcodePresent":true,\#(fields)},
     "userAndLocation":{"username":"SECRET-pupil"},
     "ios":{"unlockToken":"SECRET-ios-unlock"},
     "localUserAccounts":[{"username":"SECRET-local-account"}],
     "certificates":[{"commonName":"SECRET-certificate"}]}]}
    """#
}

/// A fake Jamf Pro (or Platform API gateway) that answers every request
/// Checkpoint makes with secret-laden answers, and counts sign-ins.
nonisolated func jamfServer(signInStatus: Int = 200) -> MockServer {
    MockServer { request in
        let path = request.path
        if path.hasSuffix("/oauth/token") || path.hasSuffix("/auth/token") {
            return .json(signInStatus, signInStatus == 200
                         ? #"{"access_token":"SECRET-token","expires_in":1200,"token":"SECRET-token"}"#
                         : #"{"error":"invalid_client"}"#)
        }
        if path.hasSuffix("/computers-inventory") { return .json(200, Laced.computers) }
        if path.hasSuffix("/mobile-devices/detail") { return .json(200, Laced.mobileDevices) }
        if path.contains("/mobile-devices/") && path.hasSuffix("/detail") {
            return .json(200, #"{"ios":{"unlockToken":"SECRET-device-unlock"}}"#)
        }
        if path.hasSuffix("/filevault") { return .json(200, #"{"personalRecoveryKey":"SECRET-fv-key"}"#) }
        if path.hasSuffix("/view-device-lock-pin") { return .json(200, #"{"pin":"SECRET-lock-pin"}"#) }
        if path.hasSuffix("/view-recovery-lock-password") {
            return .json(200, #"{"recoveryLockPassword":"SECRET-rl-password"}"#)
        }
        if path.hasSuffix("/password") { return .json(200, #"{"password":"SECRET-laps"}"#) }
        if path.hasSuffix("/erase") { return .json(200, #"{"pin":"SECRET-erase-pin"}"#) }
        if path.hasSuffix("/status-items") {
            return .json(200, #"{"statusItems":[{"key":"softwareupdate.install-state","value":"idle",\#(Laced.fields)}]}"#)
        }
        if path.contains("/device-compliance-information/") {
            return .json(200, #"[{"applicable":true,"complianceState":"COMPLIANT",\#(Laced.fields)}]"#)
        }
        if path.hasSuffix("/devices/v1/devices") {
            return .json(200, #"{"results":[{"id":"d-1","serialNumber":"C02XK1JHJG5H",\#(Laced.fields)}]}"#)
        }
        if path.hasSuffix("/declarations") {
            return .json(200, #"{"results":[{"identifier":"x",\#(Laced.fields)}]}"#)
        }
        if path.hasSuffix("/sites") { return .json(200, #"[{"id":"1","name":"Main","password":"SECRET-site"}]"#) }
        return .json(404, "{}")
    }
}

/// A Jamf Pro connection to the fake server.
nonisolated func proConnection(_ method: MDMAuthMethod = .apiClient) -> MDMConnection {
    var connection = MDMConnection(name: "Lab Jamf", product: .jamfPro, authMethod: method)
    connection.baseURL = "https://jamf.example.com"
    connection.account = "client-1"
    connection.region = .eu
    connection.environmentID = "0F2C1B0A-1111-2222-3333-444455556666"
    return connection
}

@MainActor
private func makeJamf(_ server: MockServer, _ method: MDMAuthMethod = .apiClient,
                      log: ActivityLog) throws -> JamfClient {
    try #require(JamfClient(config: proConnection(method), secret: { "SECRET-client" }, log: log, session: server.session))
}

/// Everything the log holds, as the unmasked export shows it.
@MainActor
private func everything(_ log: ActivityLog) -> String {
    ActivityLogExport.text(log.entries, masked: false)
}

// MARK: - Jamf Pro on JTKit

@Suite("Jamf Pro sign-in and sending")
@MainActor
struct JamfProTests {

    @Test("Each sign-in method signs in at its address, and the token is sent",
          arguments: [(MDMAuthMethod.apiClient, "/api/oauth/token"),
                      (.usernamePassword, "/api/v1/auth/token"),
                      (.platformGateway, "/auth/token")])
    func signIn(method: MDMAuthMethod, tokenPath: String) async throws {
        let server = jamfServer()
        let jamf = try makeJamf(server, method, log: ActivityLog())
        _ = try await jamf.sites()

        let signIn = try #require(server.requests.first)
        #expect(signIn.method == "POST")
        #expect(signIn.path == tokenPath)
        if method == .usernamePassword {
            let basic = Data("client-1:SECRET-client".utf8).base64EncodedString()
            #expect(signIn.header("Authorization") == "Basic \(basic)")
        } else {
            #expect(signIn.bodyString.contains("client_id=client-1"))
            #expect(signIn.bodyString.contains("client_secret=SECRET-client"))
        }
        let sites = try #require(server.requests.last)
        #expect(sites.header("Authorization") == "Bearer SECRET-token")
        #expect(sites.header("Accept") == "application/json")
    }

    @Test("The Platform API goes to the region's gateway, under /pro, with X-Environment-Id")
    func platformGateway() async throws {
        let server = jamfServer()
        _ = try await makeJamf(server, .platformGateway, log: ActivityLog()).sites()
        let sites = try #require(server.requests.last)
        #expect(sites.url.host() == "eu.api.jamfcloud.com")
        #expect(sites.path == "/pro/v1/sites")
        #expect(sites.header("X-Environment-Id") == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(server.requests.first?.url.host() == "eu.api.jamfcloud.com")
    }

    @Test("A direct connection sends no X-Environment-Id")
    func directHasNoEnvironment() async throws {
        let server = jamfServer()
        _ = try await makeJamf(server, log: ActivityLog()).sites()
        #expect(server.requests.last?.header("X-Environment-Id") == nil)
        #expect(server.requests.last?.url.host() == "jamf.example.com")
    }

    // Step 7: JTKit's format and hints replace Checkpoint's (decided by
    // Jordy); a direct Jamf Pro server's hint names no region.
    @Test("A refused sign-in shows JTKit's format and hint",
          arguments: [(MDMAuthMethod.apiClient, "Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients."),
                      (.usernamePassword, "Check the username and password."),
                      (.platformGateway, "Check the client ID, client secret and region.")])
    func refusedSignIn(method: MDMAuthMethod, hint: String) async throws {
        let server = jamfServer(signInStatus: 401)
        let jamf = try makeJamf(server, method, log: ActivityLog())
        do {
            try await jamf.verify()
            Issue.record("signed in")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Sign-in failed: HTTP 401 Unauthorized"))
            #expect(error.localizedDescription.contains(hint))
            if method != .platformGateway {
                #expect(!error.localizedDescription.contains("region"))
            }
        }
    }

    @Test("A refused request names the missing privilege")
    func privilegeHint() async throws {
        let server = MockServer { request in
            request.path.hasSuffix("/oauth/token") ? .json(200, #"{"access_token":"t","expires_in":1200}"#) : .json(403, "{}")
        }
        do {
            _ = try await makeJamf(server, log: ActivityLog()).sites()
            Issue.record("read")
        } catch {
            #expect(error.localizedDescription.hasPrefix("HTTP 403 Forbidden"))
            #expect(error.localizedDescription.contains("The API role is missing the “Read Sites” privilege."))
        }
    }

    @Test("A 429 is retried, and the wait is in the log")
    func rateLimitIsRetried() async throws {
        let calls = Counter()
        let server = MockServer { request in
            if request.path.hasSuffix("/oauth/token") { return .json(200, #"{"access_token":"t","expires_in":1200}"#) }
            return calls.next() == 1
                ? .json(429, "{}", headers: ["Retry-After": "0"])
                : .json(200, #"[{"id":"1","name":"Main"}]"#)
        }
        let log = ActivityLog()
        let sites = try await makeJamf(server, log: log).sites()
        #expect(sites.map(\.name) == ["Main"])
        #expect(calls.value == 2)
        #expect(log.entries.contains { $0.category == "Retry" && $0.isWarning })
    }

    @Test("A refused filter still falls back to one serial at a time")
    func refusedFilterFallsBack() async throws {
        let filters = Locked<[String]>([])
        let server = MockServer { request in
            if request.path.hasSuffix("/oauth/token") { return .json(200, #"{"access_token":"t","expires_in":1200}"#) }
            let filter = request.queryValue("filter") ?? ""
            filters.withLock { $0.append(filter) }
            return filter.contains("=in=") ? .json(400, "{}") : .json(200, Laced.computers)
        }
        let jamf = try makeJamf(server, log: ActivityLog())
        let batch = await jamf.computers(serials: ["C02XK1JHJG5H", "C02AAAAAAAAA"])
        #expect(filters.value.count == 3)
        #expect(filters.value.dropFirst().allSatisfy { $0.hasPrefix("hardware.serialNumber==") })
        #expect(batch.records["C02XK1JHJG5H"]?.name == "Lab Mac")
    }
}

/// Counts calls: `next()` returns 1, 2, 3…
nonisolated final class Counter: @unchecked Sendable {
    private let count = Locked(0)
    var value: Int { count.value }

    func next() -> Int {
        count.withLock { $0 += 1; return $0 }
    }
}

/// A value shared between a test and the fake server's handler.
nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&stored) }
    }
}

// MARK: - What the log records

@Suite("What the activity log records")
@MainActor
struct RecordedBodyTests {

    /// The calls that carry a device secret, which used to withhold their
    /// bodies in Checkpoint itself and are now recognised by JTKit.
    static let sensitivePaths = [
        "/api/v2/mobile-devices/12/detail",
        "/api/v4/computers-inventory/7/erase",
        "/api/v4/computers-inventory/7/filevault",
        "/api/v4/computers-inventory/7/view-device-lock-pin",
        "/api/v4/computers-inventory/7/view-recovery-lock-password",
        "/api/v2/local-admin-password/M-7/account/admin/password",
        "/api/v2/local-admin-password/M-7/account/admin/guid-1/password",
        // step 7: the command addresses
        "/api/v2/mdm/commands",
        "/api/v2/mobile-devices/12/erase",
        "/JSSResource/mobiledevicecommands/command/UpdateInventory/id/12",
    ]

    @Test("The sensitive calls are recognised, directly and through the Platform API")
    func sensitiveCallsAreKnown() {
        for path in Self.sensitivePaths {
            #expect(SensitiveRequests.isSensitive(path: path), "\(path)")
            #expect(SensitiveRequests.isSensitive(path: JamfClient.gatewayPath(for: path)), "\(path) via the gateway")
        }
    }

    /// Every Jamf Pro request whose answer is recorded, and every sensitive
    /// one, against answers full of secrets.
    private func runEveryLookup(_ jamf: JamfClient) async {
        _ = await jamf.computers(serials: ["C02XK1JHJG5H"])
        _ = await jamf.mobileDevices(serials: ["DMPXK1JHJG5H"])
        _ = try? await jamf.ddmStatus(managementID: "M-7")
        _ = try? await jamf.deviceCompliance(kind: .computer, deviceID: "7")
        _ = try? await jamf.platformDeviceID(serial: "C02XK1JHJG5H")
        _ = try? await jamf.platformDeclarations(serial: "C02XK1JHJG5H")
        let iPad = MDMCommand.Target(serial: "DMPXK1JHJG5H", recordID: "12", kind: .mobileDevice, managementID: "M-12")
        _ = try? await jamf.send(.clearPasscode, to: [iPad], pin: nil)
        _ = try? await jamf.fileVaultRecoveryKey(computerID: "7")
        _ = try? await jamf.deviceLockPIN(computerID: "7")
        _ = try? await jamf.recoveryLockPassword(computerID: "7")
        _ = try? await jamf.localAdminPassword(managementID: "M-7",
                                               account: JamfLocalAdminAccount(username: "admin", guid: "", source: "MDM"))
        let mac = MDMCommand.Target(serial: "C02XK1JHJG5H", recordID: "7", kind: .computer, managementID: "M-7")
        _ = try? await jamf.send(.wipeComputer, to: [mac], pin: "246813")
        _ = try? await jamf.send(.lockComputer, to: [mac], pin: "246813")
        _ = try? await jamf.sites()
    }

    @Test("No recorded body ever holds a secret, an extension attribute or a personal block",
          arguments: [MDMAuthMethod.apiClient, .platformGateway])
    func noSecretIsRecorded(method: MDMAuthMethod) async throws {
        let server = jamfServer()
        let log = ActivityLog()
        await runEveryLookup(try makeJamf(server, method, log: log))

        let recorded = everything(log)
        #expect(!recorded.contains("SECRET-"), "\(recorded)")
        #expect(!recorded.contains("246813"))
        // the lookups did record their answers
        #expect(recorded.contains("Lab Mac"))
        #expect(recorded.contains("Lab iPad"))
        #expect(recorded.contains("COMPLIANT"))
        #expect(log.entries.filter { $0.request?.responseBody != nil }.count >= 4)
    }

    @Test("The mobile-devices/detail lookup records only the sections asked for")
    func mobileDeviceLookupIsTrimmed() async throws {
        let log = ActivityLog()
        let jamf = try makeJamf(jamfServer(), log: log)
        _ = await jamf.mobileDevices(serials: ["DMPXK1JHJG5H"])

        let entry = try #require(log.entries.first { $0.detail.contains("/mobile-devices/detail") })
        let body = try #require(entry.request?.responseBody)
        let page = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let record = try #require((page["results"] as? [[String: Any]])?.first)
        #expect(Set(record.keys) == ["mobileDeviceId", "deviceType", "general", "hardware", "security", "userAndLocation"])
        #expect(record["userAndLocation"] as? String == Redaction.placeholder)
        let security = try #require(record["security"] as? [String: Any])
        #expect(security["passcodePresent"] as? Bool == true)
        #expect(security["passcode"] as? String == Redaction.placeholder)
        #expect(security["unlockToken"] as? String == Redaction.placeholder)
        #expect(record["ios"] == nil)
        #expect(!body.contains("localUserAccounts") && !body.contains("certificates"))
    }

    @Test("The computer lookup keeps its five sections, without extension attributes")
    func computerLookupIsTrimmed() async throws {
        let log = ActivityLog()
        let jamf = try makeJamf(jamfServer(), log: log)
        _ = await jamf.computers(serials: ["C02XK1JHJG5H"])

        let body = try #require(log.entries.first { $0.detail.contains("/computers-inventory") }?.request?.responseBody)
        let page = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let record = try #require((page["results"] as? [[String: Any]])?.first)
        #expect(Set(record.keys) == ["id", "udid", "general", "hardware", "diskEncryption", "operatingSystem", "userAndLocation"])
        let general = try #require(record["general"] as? [String: Any])
        #expect(general["extensionAttributes"] as? String == Redaction.placeholder)
    }

    @Test("An inventory answer that isn't JSON can't be trimmed, so it isn't recorded")
    func textInventoryIsNotRecorded() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/oauth/token") { return .json(200, #"{"access_token":"t","expires_in":1200}"#) }
            return MockResponse(status: 200, headers: ["Content-Type": "text/plain"],
                                body: Data(#"localUserAccounts: SECRET-local "extensionAttributes": SECRET-ea"#.utf8))
        }
        let log = ActivityLog()
        let jamf = try makeJamf(server, log: log)
        _ = await jamf.computers(serials: ["C02XK1JHJG5H"])
        let entry = try #require(log.entries.first { $0.detail.contains("/computers-inventory") })
        #expect(entry.request?.responseBody == nil)
        #expect(entry.request?.bodyNote == "Response body not recorded: not JSON.")
        #expect(!everything(log).contains("SECRET-"))
    }

    @Test("The mobile device detail with the unlock token is recorded without contents")
    func unlockTokenCallIsWithheld() async throws {
        let log = ActivityLog()
        let iPad = MDMCommand.Target(serial: "DMPXK1JHJG5H", recordID: "12", kind: .mobileDevice, managementID: "M-12")
        // Clear Passcode reads the token, then sends it (both withheld)
        _ = try await makeJamf(jamfServer(), log: log).send(.clearPasscode, to: [iPad], pin: nil)

        let entry = try #require(log.entries.first { $0.detail.hasSuffix("/mobile-devices/12/detail") })
        let details = try #require(entry.request)
        #expect(details.contentsWithheld)
        #expect(details.responseBody == nil && details.requestBody == nil)
        #expect(details.requestHeaders.isEmpty && details.responseHeaders.isEmpty)
    }

    @Test("Other requests record no answer, and sign-ins no bodies")
    func defaultsStay() async throws {
        let log = ActivityLog()
        _ = try await makeJamf(jamfServer(), log: log).sites()
        let signIn = try #require(log.entries.first { $0.category == "Sign-in" })
        #expect(signIn.request?.requestBody == nil && signIn.request?.responseBody == nil)
        #expect(signIn.service == "Jamf Pro" && signIn.connection == "Lab Jamf")
        let sites = try #require(log.entries.last)
        #expect(sites.request?.responseBody == nil)
        #expect(sites.request?.bodyNote == "Response body not recorded.")
        #expect(sites.request?.requestHeaders.first { $0.name == "Authorization" }?.value == "Bearer \(Redaction.placeholder)")
    }
}

// MARK: - The other services, through the recorder

@Suite("Intune, Apple and Jamf School through the request recorder")
@MainActor
struct RecorderTests {

    @Test("Jamf School: the device list is recorded, with the API key hidden")
    func jamfSchool() async throws {
        let server = MockServer { _ in
            .json(200, #"{"devices":[{"UDID":"u-1","serialNumber":"DMPXK1JHJG5H","name":"Cart iPad",\#(Laced.fields)}]}"#)
        }
        var config = MDMConnection(name: "School", product: .jamfSchool)
        config.baseURL = "https://school.jamfcloud.com"
        config.account = "067680"
        let log = ActivityLog()
        let school = try #require(JamfSchoolClient(config: config, secret: "SECRET-api-key", log: log, session: server.session))
        _ = try await school.fleet()

        let entry = try #require(log.entries.first)
        #expect(entry.service == "Jamf School" && entry.connection == "School")
        #expect(entry.request?.requestHeaders.first { $0.name == "Authorization" }?.value == "Basic \(Redaction.placeholder)")
        #expect(entry.request?.responseBody?.contains("Cart iPad") == true)
        #expect(!everything(log).contains("SECRET-"))
    }

    @Test("Intune: the sign-in and the device read are recorded; the secret and token aren't")
    func intune() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/oauth2/v2.0/token") {
                return .json(200, #"{"access_token":"SECRET-graph-token","expires_in":3600}"#)
            }
            return .json(200, #"{"value":[{"id":"i-1","serialNumber":"C02XK1JHJG5H","deviceName":"Lab Mac",\#(Laced.fields)}]}"#)
        }
        var config = MDMConnection(name: "Contoso", product: .intune, authMethod: .entraApp)
        config.tenantID = "contoso.onmicrosoft.com"
        config.account = "app-1"
        let log = ActivityLog()
        let intune = try #require(IntuneClient(config: config, secret: "SECRET-entra", log: log, session: server.session))
        _ = try? await intune.fleet()

        #expect(log.entries.map(\.category) == ["Sign-in", "API"])
        #expect(log.entries.allSatisfy { $0.service == "Intune" && $0.connection == "Contoso" })
        #expect(log.entries.last?.request?.responseBody?.contains("Lab Mac") == true)
        #expect(!everything(log).contains("SECRET-"))
    }

    @Test("Apple: the sign-in and a device lookup are recorded; the assertion and token aren't")
    func apple() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/oauth2/v2/token") {
                return .json(200, #"{"access_token":"SECRET-apple-token","expires_in":3600}"#)
            }
            return .json(200, #"{"data":{"attributes":{"serialNumber":"C02XK1JHJG5H",\#(Laced.fields)}}}"#)
        }
        let log = ActivityLog()
        let abm = ABMClient(clientID: "BUSINESSAPI.abc", keyID: "key-1",
                            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
                            kind: .business, connectionName: "Apple Business", log: log, session: server.session)
        _ = try? await abm.device(serial: "C02XK1JHJG5H")

        #expect(log.entries.map(\.category) == ["Sign-in", "API"])
        #expect(log.entries.allSatisfy { $0.service == "Apple Business" && $0.connection == "Apple Business" })
        #expect(log.entries.first?.request?.requestBody == nil)
        #expect(log.entries.last?.request?.responseBody?.contains("C02XK1JHJG5H") == true)
        #expect(!everything(log).contains("SECRET-"))
    }

    @Test("Apple keeps its own waits: 5, 15 and 45 s")
    func appleWaits() {
        #expect((0..<4).map(ABMClient.backoff) == [5, 15, 45, 45])
    }
}

// MARK: - One client per connection

@Suite("One client per connection")
@MainActor
struct ClientCacheTests {
    private let id = SavedData.proClientID
    private var account: String { "jamf.\(id.uuidString)" }

    /// Checkpoint with today's saved connections and a secret for the
    /// "Jamf Pro sandbox" API client, against the fake server.
    private func setUp(_ server: MockServer) throws -> (AppSettings, LookupModel, MDMConnection) {
        let fixture = Fixture()
        fixture.secrets.setSecret("first-secret", for: account)
        let settings = fixture.settings()
        let model = LookupModel(settings: settings, session: server.session)
        let config = try #require(settings.mdmConnections.first { $0.id == id })
        return (settings, model, config)
    }

    private func signIns(_ server: MockServer) -> [RecordedRequest] {
        server.requests.filter { $0.path.hasSuffix("/oauth/token") }
    }

    @Test("The same client is used while the connection stays as it is")
    func reused() async throws {
        let server = jamfServer()
        let (_, model, config) = try setUp(server)
        let first = try #require(model.makeJamfClient(for: config))
        #expect(model.makeJamfClient(for: config) === first)
        // Two reads, one sign-in. (Test Connection, `verify`, always signs in
        // afresh since step 7, as JTKit's does.)
        _ = try await first.sites()
        _ = try await first.sites()
        #expect(signIns(server).count == 1)
    }

    @Test("Saving only a new secret drops the client, and its token is forgotten")
    func secretOnlyEdit() async throws {
        let server = jamfServer()
        let (settings, model, config) = try setUp(server)
        let first = try #require(model.makeJamfClient(for: config))
        try await first.verify()

        try settings.connections.save(.mdm(config), secrets: [.main: "second-secret"])
        let second = try #require(model.makeJamfClient(for: config))
        #expect(second !== first)

        // a client still in use by a running lookup signs in again, with the new secret
        await model.pendingForget?.value
        try await first.verify()
        #expect(signIns(server).count == 2)
        #expect(signIns(server).last?.bodyString.contains("client_secret=second-secret") == true)
    }

    @Test("The edit hook tells the model at once, also for a secret alone")
    func editsAreReported() throws {
        let fixture = Fixture()
        let settings = fixture.settings()
        var told = [UUID]()
        settings.edits.onChange = { told.append($0) }
        let config = try #require(settings.mdmConnections.first { $0.id == id })

        try settings.connections.save(.mdm(config), secrets: [.main: "new"])
        #expect(told == [id])

        told = []
        var renamed = config
        renamed.name = "Renamed"
        try settings.connections.save(.mdm(renamed))
        #expect(told == [id])

        told = []
        try settings.connections.delete(id: id)
        #expect(told.allSatisfy { $0 == id } && !told.isEmpty)
    }

    @Test("Editing a field makes a new client")
    func fieldEdit() throws {
        let (settings, model, config) = try setUp(jamfServer())
        let first = try #require(model.makeJamfClient(for: config))
        var edited = config
        edited.baseURL = "https://other.example.com"
        try settings.connections.save(.mdm(edited))
        let saved = try #require(settings.mdmConnections.first { $0.id == id })
        let second = try #require(model.makeJamfClient(for: saved))
        #expect(second !== first)
    }

    @Test("Deleting a connection drops its client")
    func deleted() throws {
        let (settings, model, config) = try setUp(jamfServer())
        let first = try #require(model.makeJamfClient(for: config))
        try settings.connections.delete(id: id)
        #expect(model.makeJamfClient(for: config) == nil)

        // saved again under the same ID, it gets a new client
        try settings.connections.save(.mdm(config), secrets: [.main: "again"])
        #expect(model.makeJamfClient(for: config) !== first)
    }

    @Test("Intune and Jamf School clients are replaced after a new secret too")
    func otherServices() throws {
        let fixture = Fixture()
        fixture.secrets.setSecret("intune-1", for: "jamf.\(SavedData.intuneID.uuidString)")
        fixture.secrets.setSecret("school-1", for: "jamf.\(SavedData.schoolServerID.uuidString)")
        let settings = fixture.settings()
        let model = LookupModel(settings: settings)
        let intune = try #require(settings.mdmConnections.first { $0.id == SavedData.intuneID })
        let school = try #require(settings.mdmConnections.first { $0.id == SavedData.schoolServerID })
        let firstIntune = try #require(model.makeIntuneClient(for: intune))
        let firstSchool = try #require(model.makeJamfSchoolClient(for: school))
        #expect(model.makeIntuneClient(for: intune) === firstIntune)

        try settings.connections.save(.mdm(intune), secrets: [.main: "intune-2"])
        try settings.connections.save(.mdm(school), secrets: [.main: "school-2"])
        #expect(model.makeIntuneClient(for: intune) !== firstIntune)
        #expect(model.makeJamfSchoolClient(for: school) !== firstSchool)
    }
}

// MARK: - Actions

@Suite("Action entries")
@MainActor
struct ActionEntryTests {

    @Test("An action names its service and connection, and its serials are masked in the bug report")
    func actionsAreMasked() throws {
        let log = ActivityLog()
        log.recordAction(service: .jamfPro, connection: "Lab Jamf", summary: "Erase C02XK1JHJG5H",
                         outcome: .failed, serials: ["C02XK1JHJG5H"])
        let entry = try #require(log.entries.first)
        #expect(entry.category == "Action")
        #expect(entry.service == "Jamf Pro" && entry.connection == "Lab Jamf")
        #expect(entry.isFailure)

        let masked = ActivityLogExport.text(log.entries, masked: true)
        #expect(!masked.contains("C02XK1JHJG5H"))
        #expect(masked.contains("<device 1>"))
        #expect(ActivityLogExport.text(log.entries, masked: false).contains("C02XK1JHJG5H"))
    }
}
