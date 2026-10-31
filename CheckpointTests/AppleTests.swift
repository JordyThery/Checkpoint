import CryptoKit
import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Apple Business and Apple School Manager (ROADMAP step 9), written against
// Checkpoint's own `ABMClient` before it moves to JTKit, so the move can be
// checked against them: the private-key sign-in, every read, paging, Apple's
// 18-a-minute limit and its retries, the writes and how they are confirmed,
// and that the key and the signed sign-in request never leave the client.
// Tests that pin down a flaw the move fixes on purpose say "Today".
// Every test has its own fake Apple, key, clock and log.

// MARK: - Fixtures

/// Time that moves only when the client waits, so the 60 s window and the
/// 5, 15 and 45 s waits take no real time.
nonisolated final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_790_000_000)
    private var waits: [Double] = []

    var now: Date { lock.withLock { time } }
    /// Every wait, in order.
    var sleeps: [Double] { lock.withLock { waits } }

    func advance(_ seconds: Double) { lock.withLock { time += seconds } }

    var clock: ABMClock {
        ABMClock(now: { [self] in now },
                 sleep: { [self] seconds in lock.withLock { waits.append(seconds); time += seconds } })
    }
}

nonisolated enum AppleFixtures {
    static let tokenPath = "/auth/oauth2/v2/token"
    static let token = #"{"access_token":"SECRET-apple-token","token_type":"Bearer","expires_in":3600}"#

    static func device(_ serial: String, extra: String = "") -> String {
        #"{"serialNumber":"\#(serial)","deviceModel":"MacBook Air","productFamily":"Mac","status":"ASSIGNED","orderNumber":"ORDER-1"\#(extra)}"#
    }

    static func error(_ status: Int, title: String? = nil, detail: String? = nil) -> MockResponse {
        var item = [#""status":"\#(status)""#]
        if let title { item.append(#""title":"\#(title)""#) }
        if let detail { item.append(#""detail":"\#(detail)""#) }
        return .json(status, #"{"errors":[{\#(item.joined(separator: ","))}]}"#)
    }

    /// The fields of a form body.
    static func form(_ request: RecordedRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = request.bodyString
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
    }

    static func base64URLDecoded(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func json(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

/// A fake Apple: `route` answers first, then the token, then 404.
nonisolated func appleServer(_ route: @escaping @Sendable (RecordedRequest) -> MockResponse? = { _ in nil }) -> MockServer {
    MockServer { request in
        if let answer = route(request) { return answer }
        if request.path == AppleFixtures.tokenPath { return .json(200, AppleFixtures.token) }
        return AppleFixtures.error(404, title: "Not Found")
    }
}

/// One client on a fake Apple, with its own key, clock and log.
nonisolated struct AppleRig {
    let server: MockServer
    let key: P256.Signing.PrivateKey
    let pem: String
    let time = VirtualClock()
    let log: ActivityLog
    let client: ABMClient

    @MainActor
    init(_ server: MockServer = appleServer(), kind: AppleOrgKind = .business,
         key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), pem: String? = nil) {
        self.server = server
        self.key = key
        self.pem = pem ?? key.pemRepresentation
        let log = ActivityLog()
        self.log = log
        client = ABMClient(clientID: kind == .business ? "BUSINESSAPI.abc" : "SCHOOLAPI.def",
                           keyID: kind == .business ? "key-1" : "key-2", privateKeyPEM: self.pem, kind: kind,
                           connectionName: "Lab Org", log: log, session: server.session, clock: time.clock)
    }

    var signIns: [RecordedRequest] { server.requests.filter { $0.path == AppleFixtures.tokenPath } }
    var api: [RecordedRequest] { server.requests.filter { $0.path != AppleFixtures.tokenPath } }
}

/// The client's error message, nil when it succeeded.
nonisolated func message(_ work: () async throws -> Void) async -> String? {
    do {
        try await work()
        return nil
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Sign-in

@Suite("Apple: signing in with the private key")
@MainActor
struct AppleSignInTests {

    @Test("The token request: address, form fields and scope per service",
          arguments: [(AppleOrgKind.business, "business.api", "BUSINESSAPI.abc"), (.school, "school.api", "SCHOOLAPI.def")])
    func tokenRequest(kind: AppleOrgKind, scope: String, clientID: String) async throws {
        let rig = AppleRig(kind: kind)
        _ = try? await rig.client.mdmServers()
        let signIn = try #require(rig.signIns.first)
        #expect(signIn.url.absoluteString == "https://account.apple.com/auth/oauth2/v2/token")
        #expect(signIn.method == "POST")
        #expect(signIn.header("Content-Type") == "application/x-www-form-urlencoded")
        let form = AppleFixtures.form(signIn)
        #expect(Set(form.keys) == ["grant_type", "client_id", "client_assertion_type", "client_assertion", "scope"])
        #expect(form["grant_type"] == "client_credentials")
        #expect(form["client_id"] == clientID)
        #expect(form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(form["scope"] == scope)
        #expect(rig.api.first?.url.host() == (kind == .business ? "api-business.apple.com" : "api-school.apple.com"))
        #expect(rig.api.first?.header("Authorization") == "Bearer SECRET-apple-token")
    }

    @Test("The signed request: ES256 header, claims, 20 minutes, and a signature the key's public half accepts")
    func assertion() async throws {
        let rig = AppleRig()
        _ = try? await rig.client.mdmServers()
        let signIn = try #require(rig.signIns.first)
        let assertion = try #require(AppleFixtures.form(signIn)["client_assertion"])
        let parts = assertion.split(separator: ".", omittingEmptySubsequences: false)
        try #require(parts.count == 3)
        let header = AppleFixtures.json(AppleFixtures.base64URLDecoded(parts[0]))
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "key-1")
        #expect(header["typ"] as? String == "JWT")
        let claims = AppleFixtures.json(AppleFixtures.base64URLDecoded(parts[1]))
        #expect(claims["iss"] as? String == "BUSINESSAPI.abc")
        #expect(claims["sub"] as? String == "BUSINESSAPI.abc")
        #expect(claims["aud"] as? String == "https://account.apple.com/auth/oauth2/v2/token")
        let issued = try #require(claims["iat"] as? Int)
        #expect(issued == Int(rig.time.now.timeIntervalSince1970))
        #expect(claims["exp"] as? Int == issued + 1200)
        #expect(UUID(uuidString: claims["jti"] as? String ?? "") != nil)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: #require(AppleFixtures.base64URLDecoded(parts[2])))
        #expect(rig.key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("Each sign-in signs a new request (a new jti)")
    func newAssertionEachTime() async throws {
        let rig = AppleRig()
        _ = try? await rig.client.mdmServers()
        rig.time.advance(3600)
        _ = try? await rig.client.mdmServers()
        let assertions = rig.signIns.compactMap { AppleFixtures.form($0)["client_assertion"] }
        #expect(assertions.count == 2)
        #expect(Set(assertions).count == 2)
    }

    @Test("A PKCS#8 key labelled EC PRIVATE KEY (Apple School Manager's files) is accepted")
    func schoolKeyLabel() async throws {
        let key = P256.Signing.PrivateKey()
        let relabelled = key.pemRepresentation
            .replacingOccurrences(of: "BEGIN PRIVATE KEY", with: "BEGIN EC PRIVATE KEY")
            .replacingOccurrences(of: "END PRIVATE KEY", with: "END EC PRIVATE KEY")
        let rig = AppleRig(appleServer { $0.path == "/v1/mdmServers" ? .json(200, #"{"data":[]}"#) : nil },
                           kind: .school, key: key, pem: relabelled)
        _ = try await rig.client.mdmServers()
        #expect(rig.signIns.count == 1)
        #expect(rig.api.count == 1)
    }

    @Test("A key that can't be read: a plain message, nothing sent")
    func unreadableKey() async {
        let rig = AppleRig(pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")
        let text = await message { _ = try await rig.client.mdmServers() }
        // changed on purpose: JTKit's message, with where to get the right file
        #expect(text?.hasPrefix("The file doesn’t contain a private key. Choose the .pem file downloaded when the API account was created.\n") == true)
        #expect(rig.server.requests.isEmpty)
    }

    @Test("Five requests at once share one sign-in")
    func sharedSignIn() async {
        let rig = AppleRig(appleServer { $0.path.hasPrefix("/v1/orgDevices/") ? .json(200, #"{"data":{"attributes":\#(AppleFixtures.device("C02XK1JHJG5H"))}}"#) : nil })
        let client = rig.client
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try? await client.device(serial: "C02XK1JHJG5H") } }
        }
        #expect(rig.signIns.count == 1)
        #expect(rig.api.count == 5)
    }

    // changed on purpose (decided by Jordy): 60 s, JTKit's standard; was 120 s
    @Test("The token is kept until 60 s before it runs out")
    func renewal() async {
        let rig = AppleRig()
        _ = try? await rig.client.mdmServers()
        rig.time.advance(3600 - 60 - 1)
        _ = try? await rig.client.mdmServers()
        #expect(rig.signIns.count == 1)
        rig.time.advance(2)
        _ = try? await rig.client.mdmServers()
        #expect(rig.signIns.count == 2)
    }

    // changed on purpose: a 401 gets a new token and one more try (JTKit's rules)
    @Test("A 401 gets a new token and one more try")
    func retryAfter401() async {
        let rig = AppleRig(appleServer { $0.path == "/v1/mdmServers" ? AppleFixtures.error(401, title: "Unauthorized") : nil })
        let text = await message { _ = try await rig.client.mdmServers() }
        #expect(text == "HTTP 401 Unauthorized\nUnauthorized\nApple Business Manager didn’t accept the sign-in. Check the API account in Apple Business Manager.")
        #expect(rig.signIns.count == 2)
        #expect(rig.api.count == 2)
    }

    // changed on purpose: only Apple's error and description, never the rest
    // of its answer (the leak found by the secret tests below)
    @Test("A refused sign-in: Apple's error and description only")
    func refusedSignIn() async {
        let long = String(repeating: "x", count: 400)
        let rig = AppleRig(appleServer { request in
            request.path == AppleFixtures.tokenPath
                ? .json(400, #"{"error":"invalid_client","access_token":"SECRET-leaked","note":"\#(long)"}"#) : nil
        })
        let text = await message { _ = try await rig.client.mdmServers() } ?? ""
        #expect(text.hasPrefix("Sign-in failed: HTTP 400 Bad Request\ninvalid_client\nCheck the client ID and the key ID"))
        #expect(!text.contains("SECRET-leaked"))
        #expect(!text.contains("xxxx"))
        #expect(rig.api.isEmpty)
    }
}

// MARK: - Reads

@Suite("Apple: what Checkpoint reads")
@MainActor
struct AppleReadTests {

    @Test("A device: its address, headers and fields; 404 means not in the organization")
    func device() async throws {
        let extra = #","imei":[],"meid":["A1"],"eid":"E1","wifiMacAddress":"aa:bb","isMdmMigrationCapable":true,"mdmMigrationStatus":"STARTED""#
        let rig = AppleRig(appleServer { request in
            request.path == "/v1/orgDevices/C02XK1JHJG5H"
                ? .json(200, #"{"data":{"type":"orgDevices","id":"C02XK1JHJG5H","attributes":\#(AppleFixtures.device("C02XK1JHJG5H", extra: extra))}}"#) : nil
        })
        let device = try #require(try await rig.client.device(serial: "C02XK1JHJG5H"))
        #expect(device.deviceModel == "MacBook Air")
        #expect(device.orderNumber == "ORDER-1")
        #expect(device.imeiDisplay == nil)
        #expect(device.meid == ["A1"])
        #expect(device.isMdmMigrationCapable == true)
        #expect(device.hasActiveMigration)
        #expect(device.migrationOutcome == "Started")
        let request = try #require(rig.api.first)
        #expect(request.method == "GET")
        #expect(request.header("Accept") == "application/json")
        #expect(try await rig.client.device(serial: "UNKNOWN") == nil)
    }

    @Test("Migration outcomes: a FAILED migration reads as not migrated, never as a failure")
    func migrationOutcome() throws {
        func device(_ status: String?) throws -> ABMDevice {
            let field = status.map { #","mdmMigrationStatus":"\#($0)""# } ?? ""
            return try JSONDecoder().decode(ABMDevice.self, from: Data(AppleFixtures.device("S", extra: field).utf8))
        }
        #expect(try device("SUCCESS").migrationOutcome == "Migrated")
        #expect(try device("FAILED").migrationOutcome == "Not migrated")
        #expect(try device("REQUESTED").hasActiveMigration)
        #expect(try device(nil).migrationOutcome == nil)
    }

    @Test("AppleCare coverage: records, Active and Expired; 404 is none")
    func coverage() async throws {
        let rig = AppleRig(appleServer { request in
            guard request.path == "/v1/orgDevices/C02XK1JHJG5H/appleCareCoverage" else { return nil }
            return .json(200, #"""
            {"data":[{"type":"appleCareCoverage","id":"A","attributes":{"description":"AppleCare+","status":"ACTIVE","startDateTime":"2025-01-01T00:00:00Z","endDateTime":"2099-01-01T00:00:00Z"}},
                     {"type":"appleCareCoverage","id":"B","attributes":{"description":"Limited Warranty","status":"INACTIVE","startDateTime":"2000-01-01T00:00:00Z","endDateTime":"2001-01-01T00:00:00Z"}},
                     {"type":"appleCareCoverage","id":"C","attributes":{"description":"Other","status":"INACTIVE","endDateTime":"2099-01-01T00:00:00Z"}}]}
            """#)
        })
        let coverage = try await rig.client.appleCareCoverage(serial: "C02XK1JHJG5H")
        #expect(coverage.map(\.id) == ["A", "B", "C"])
        #expect(coverage.map(\.displayStatus) == ["Active", "Expired", "Inactive"])
        #expect(coverage.first?.description == "AppleCare+")
        #expect(try await rig.client.appleCareCoverage(serial: "UNKNOWN").isEmpty)
    }

    @Test("Activation Lock: locked with its type; 404 and server errors are no answer")
    func activationLock() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/orgDevices/LOCKED/activationLockStatus":
                .json(200, #"{"data":{"attributes":{"isLocked":true,"lockType":"MDM"}}}"#)
            case "/v1/orgDevices/QUIRK/activationLockStatus":
                AppleFixtures.error(500, title: "Internal")
            default: nil
            }
        })
        let lock = try #require(try await rig.client.activationLock(serial: "LOCKED"))
        #expect(lock.summary == "Enabled")
        #expect(lock.detail == "MDM lock. A bypass code is escrowed, so clearing it does not need the owner.")
        #expect(try await rig.client.activationLock(serial: "QUIRK") == nil)
        #expect(try await rig.client.activationLock(serial: "UNKNOWN") == nil)
        // a plain 500 is not retried (only 429 and 503 are)
        #expect(rig.api.filter { $0.path.contains("QUIRK") }.count == 1)
    }

    @Test("The assigned server: its ID, none when unassigned or unknown")
    func assignedServer() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/orgDevices/A/relationships/assignedServer": .json(200, #"{"data":{"type":"mdmServers","id":"SERVER-1"}}"#)
            case "/v1/orgDevices/B/relationships/assignedServer": .json(200, #"{"data":null}"#)
            default: nil
            }
        })
        #expect(try await rig.client.assignedServerID(serial: "A") == "SERVER-1")
        #expect(try await rig.client.assignedServerID(serial: "B") == nil)
        #expect(try await rig.client.assignedServerID(serial: "C") == nil)
    }

    @Test("MDM servers: every page; a server without a name shows its ID")
    func servers() async throws {
        let rig = AppleRig(appleServer { request in
            guard request.path == "/v1/mdmServers" else { return nil }
            if request.queryValue("cursor") == nil {
                return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro","serverType":"MDM","status":"ACTIVE"}}],"links":{"next":"https://api-business.apple.com/v1/mdmServers?limit=100&cursor=2"}}"#)
            }
            return .json(200, #"{"data":[{"id":"S2","attributes":{"serverType":"APPLE_MDM"}}],"links":{}}"#)
        })
        let servers = try await rig.client.mdmServers()
        #expect(servers.map(\.name) == ["Jamf Pro", "S2"])
        #expect(servers.map(\.isAppleManagement) == [false, true])
        #expect(rig.api.first?.queryValue("limit") == "100")
        #expect(try await rig.client.verify() == 2)
    }

    @Test("The organization snapshot: devices with 23 fields, then each server's devices")
    func snapshot() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/orgDevices":
                if request.queryValue("cursor") == nil {
                    return .json(200, #"{"data":[{"attributes":\#(AppleFixtures.device("c02aaa"))}],"links":{"next":"https://api-business.apple.com/v1/orgDevices?limit=1000&cursor=2"}}"#)
                }
                return .json(200, #"{"data":[{"attributes":\#(AppleFixtures.device("DMPBBB"))},{"attributes":\#(AppleFixtures.device("DMPCCC"))}]}"#)
            case "/v1/mdmServers":
                return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}},{"id":"S2","attributes":{"serverName":"Locked"}}]}"#)
            case "/v1/mdmServers/S1/relationships/devices":
                return .json(200, #"{"data":[{"type":"orgDevices","id":"c02aaa"},{"type":"orgDevices","id":"DMPBBB"}]}"#)
            case "/v1/mdmServers/S2/relationships/devices":
                return AppleFixtures.error(403, title: "Forbidden")
            default:
                return nil
            }
        })
        let progress = LockedList<String>()
        let snapshot = try await rig.client.organizationSnapshot { progress.append($0.description) }
        #expect(Set(snapshot.devices.keys) == ["C02AAA", "DMPBBB", "DMPCCC"])
        #expect(snapshot.serverIDBySerial == ["C02AAA": "S1", "DMPBBB": "S1"])
        #expect(snapshot.servers.map(\.id) == ["S1", "S2"])
        #expect(snapshot.capturedAt == rig.time.now)
        #expect(progress.items == ["Reading devices… 1", "Reading devices… 3",
                                   "Reading assignments… 0 of 2 services", "Reading assignments… 1 of 2 services"])
        let first = try #require(rig.api.first)
        #expect(first.queryValue("limit") == "1000")
        let fields = try #require(first.queryValue("fields[orgDevices]")).split(separator: ",").map(String.init)
        #expect(fields.count == 23)
        #expect(Set(fields).isSuperset(of: ["serialNumber", "imei", "mdmMigrationDeadlineDateTime", "purchaseSourceId"]))
        #expect(rig.api.first { $0.path == "/v1/mdmServers/S1/relationships/devices" }?.queryValue("limit") == "1000")
        #expect(snapshot.orders.map(\.number) == ["ORDER-1"])
        #expect(snapshot.serials(inOrder: "ORDER-1") == ["DMPBBB", "DMPCCC", "c02aaa"])
    }

    // changed on purpose (decided by Jordy): the server counts as unreadable,
    // a warning goes in the log, and its devices' assignment is unknown,
    // never "unassigned"
    @Test("A server's device list that fails halfway: unknown assignments and a warning")
    func snapshotCutOff() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/orgDevices": return .json(200, #"{"data":[{"attributes":\#(AppleFixtures.device("A"))},{"attributes":\#(AppleFixtures.device("B"))}]}"#)
            case "/v1/mdmServers": return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}}]}"#)
            case "/v1/mdmServers/S1/relationships/devices":
                if request.queryValue("cursor") == nil {
                    return .json(200, #"{"data":[{"id":"A"}],"links":{"next":"https://api-business.apple.com/v1/mdmServers/S1/relationships/devices?cursor=2"}}"#)
                }
                return AppleFixtures.error(500, title: "Internal")
            default: return nil
            }
        })
        let snapshot = try await rig.client.organizationSnapshot()
        #expect(snapshot.serverIDBySerial.isEmpty)
        #expect(snapshot.unreadableServers.map(\.id) == ["S1"])
        #expect(snapshot.unknownAssignments == ["A", "B"])
        #expect(rig.log.entries.contains { $0.isWarning && $0.note?.contains("Couldn’t read the devices of “Jamf Pro”") == true })
    }

    // changed on purpose: tolerant records; one without a serial is left out
    @Test("A device record without a serial is left out; the snapshot is read")
    func snapshotWithoutSerial() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/orgDevices": .json(200, #"{"data":[{"attributes":\#(AppleFixtures.device("A"))},{"attributes":{"deviceModel":"iPad"}}]}"#)
            case "/v1/mdmServers": .json(200, #"{"data":[]}"#)
            default: nil
            }
        })
        #expect(Set(try await rig.client.organizationSnapshot().devices.keys) == ["A"])
    }

    // changed on purpose: a next page on another host is refused (the token used to go there)
    @Test("A next page on another host is refused; nothing is sent there")
    func nextPageElsewhere() async throws {
        let rig = AppleRig(appleServer { request in
            if request.url.host() == "elsewhere.example" { return .json(200, #"{"data":[]}"#) }
            return request.path == "/v1/mdmServers"
                ? .json(200, #"{"data":[],"links":{"next":"https://elsewhere.example/v1/mdmServers?cursor=2"}}"#) : nil
        })
        let text = await message { _ = try await rig.client.mdmServers() }
        #expect(text == "Refused: the next page of the list pointed to elsewhere.example, not to Apple Business Manager. Nothing was sent there.")
        #expect(!rig.server.requests.contains { $0.url.host() == "elsewhere.example" })
    }

    // changed on purpose: 1,000 pages is an error (there was no limit)
    @Test("1,000 pages is an error, never a quiet cut-off")
    func pageLimit() async throws {
        let rig = AppleRig(appleServer { request in
            guard request.path == "/v1/mdmServers" else { return nil }
            let page = Int(request.queryValue("cursor") ?? "0") ?? 0
            let next = page < 1_100 ? #","links":{"next":"https://api-business.apple.com/v1/mdmServers?cursor=\#(page + 1)"}"# : ""
            return .json(200, #"{"data":[{"id":"S\#(page)","attributes":{}}]\#(next)}"#)
        })
        let text = await message { _ = try await rig.client.mdmServers() }
        #expect(text?.hasPrefix("Stopped after 1000 pages of v1/mdmServers") == true)
    }

    @Test("Built-in management: the list (no serial, no entry) and one device's details")
    func appleManaged() async throws {
        let rig = AppleRig(appleServer { request in
            switch request.path {
            case "/v1/mdmDevices":
                .json(200, #"{"data":[{"id":"R1","attributes":{"serialNumber":"c02aaa","deviceName":"Lab Mac","productFamily":"Mac"}},{"id":"R2","attributes":{"serialNumber":""}},{"id":"R3","attributes":{"serialNumber":"DMPB","productFamily":"iPad"}}]}"#)
            case "/v1/mdmDevices/R1/details":
                .json(200, #"{"data":{"attributes":{"osVersion":"15.1","isFileVaultEnabled":true,"lostModeStatus":"DISABLED"}}}"#)
            default: nil
            }
        })
        let devices = try await rig.client.appleManagedDevices()
        #expect(Set(devices.keys) == ["C02AAA", "DMPB"])
        #expect(devices["C02AAA"]?.kind == .computer)
        #expect(devices["DMPB"]?.kind == .mobileDevice)
        #expect(rig.api.first?.queryValue("limit") == "100")
        let details = try #require(try await rig.client.appleManagedDeviceDetails(id: "R1"))
        #expect(details.osVersion == "15.1")
        #expect(details.isFileVaultEnabled == true)
        #expect(try await rig.client.appleManagedDeviceDetails(id: "R9") == nil)
    }

    @Test("A device's history: the filters, the cursor, the summaries, newest first")
    func history() async throws {
        let rig = AppleRig(appleServer { request in
            guard request.path == "/v1/auditEvents" else { return nil }
            return .json(200, #"""
            {"data":[
              {"id":"1","attributes":{"eventDateTime":"2026-01-01T00:00:00Z","type":"DEVICE_ADDED_TO_ORG","outcome":"SUCCESS","eventDataPropertyKey":"addedData","addedData":{"purchaseSourceType":"RESELLER"}}},
              {"id":"2","attributes":{"eventDateTime":"2026-03-01T00:00:00Z","type":"DEVICE_ASSIGNED_TO_SERVER","actorName":"Admin","outcome":"FAILURE","eventDataPropertyKey":"assignData","assignData":{"targetServerName":"Jamf Pro"}}},
              {"id":"3","attributes":{"eventDateTime":"2026-02-01T00:00:00Z","type":"DEVICE_UNASSIGNED_FROM_SERVER","eventDataPropertyKey":"u","u":{"serverName":"Old MDM"}}},
              {"id":"4","attributes":{"eventDateTime":"2025-12-01T00:00:00Z","type":"SOME_NEW_EVENT"}}],
             "meta":{"paging":{"nextCursor":"next+1"}}}
            """#)
        })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let page = try await rig.client.auditEvents(serial: "C02XK1JHJG5H", start: start, end: end, cursor: "a+b c")
        #expect(page.events.map(\.id) == ["2", "3", "1", "4"])
        #expect(page.events.map(\.summary) == ["Assigned to Jamf Pro", "Unassigned from Old MDM", "Added from a reseller", "Some New Event"])
        #expect(page.events.first?.isFailure == true)
        #expect(page.nextCursor == "next+1")
        let request = try #require(rig.api.first)
        #expect(request.queryValue("filter[startTimestamp]") == "2023-11-14T22:13:20Z")
        #expect(request.queryValue("filter[endTimestamp]") == "2027-01-15T08:00:00Z")
        #expect(request.queryValue("filter[subjectId]") == "C02XK1JHJG5H")
        #expect(request.queryValue("limit") == "100")
        // strict encoding now: the + is encoded too
        #expect(request.queryValue("cursor") == "a+b c")
        #expect(request.url.query(percentEncoded: true)?.contains("cursor=a%2Bb%20c") == true)
    }

    // changed on purpose (decided by Jordy): letters and digits only,
    // lowercase made uppercase; was sent unchecked
    @Test("A serial is checked before it goes into an address or a query")
    func serialChecked() async {
        let rig = AppleRig()
        let text = await message { _ = try await rig.client.auditEvents(serial: "X&limit=1", start: .distantPast, end: .distantFuture) }
        #expect(text == "“X&limit=1” isn’t a serial number: it may hold only letters and digits.")
        #expect(rig.server.requests.isEmpty)
        _ = try? await rig.client.device(serial: "c02xk1jhjg5h")
        #expect(rig.api.first?.path == "/v1/orgDevices/C02XK1JHJG5H")
    }
}

/// A list several tasks append to.
nonisolated final class LockedList<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Item] = []
    func append(_ item: Item) { lock.withLock { list.append(item) } }
    var items: [Item] { lock.withLock { list } }
}

// MARK: - Apple's limit and retries

@Suite("Apple: the 18-a-minute limit and retries")
@MainActor
struct AppleLimitTests {

    static func devicesServer() -> MockServer {
        appleServer { request in
            if request.path == "/v1/mdmServers" { return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}}]}"#) }
            return request.path.hasPrefix("/v1/orgDevices/") ? .json(200, #"{"data":{"attributes":\#(AppleFixtures.device("A"))}}"#) : nil
        }
    }

    @Test("The sign-in and seventeen requests go at once; the eighteenth waits for the minute to pass")
    func window() async throws {
        let rig = AppleRig(Self.devicesServer())
        for _ in 0..<17 { _ = try await rig.client.device(serial: "A") }
        #expect(rig.time.sleeps.isEmpty)
        _ = try await rig.client.device(serial: "A")
        #expect(rig.time.sleeps.count == 1)
        #expect(abs((rig.time.sleeps.first ?? 0) - 60.1) < 0.001)
        #expect(rig.api.count == 18)
        #expect(rig.signIns.count == 1)
    }

    // changed with JTKit 0.13.0: Apple counts its sign-in too
    @Test("The sign-in counts towards the limit: it takes one of the eighteen")
    func signInCounted() async throws {
        let rig = AppleRig(Self.devicesServer())
        for _ in 0..<17 { _ = try await rig.client.device(serial: "A") }
        #expect(rig.signIns.count == 1)
        #expect(rig.time.sleeps.isEmpty)
        // An eighteenth request would go at once if the sign-in were free.
        _ = try await rig.client.device(serial: "A")
        #expect(rig.signIns.count == 1)
        #expect(rig.time.sleeps.count == 1)
    }

    // changed on purpose (decided by Jordy): a write isn't repeated after a
    // 503, only after a 429; JTKit's error format
    @Test("429 is retried for reads and writes, 503 for reads only, at 5, 15 and 45 s",
          arguments: [429, 503], ["GET", "POST"])
    func busy(status: Int, method: String) async {
        let rig = AppleRig(appleServer { request in
            request.path == AppleFixtures.tokenPath ? nil : MockResponse(status: status, body: Data())
        })
        let text = await message {
            if method == "GET" {
                _ = try await rig.client.mdmServers()
            } else {
                _ = try await rig.client.submitActivity(.assign, serials: ["A"], mdmServerID: "S1")
            }
        }
        #expect(text?.hasPrefix("HTTP \(status) ") == true)
        #expect(rig.api.allSatisfy { $0.method == method })
        if status == 503 && method == "POST" {
            #expect(rig.api.count == 1)
            #expect(rig.time.sleeps.isEmpty)
            return
        }
        #expect(rig.api.count == 4)
        #expect(rig.time.sleeps == [5, 15, 45])
        let waits = rig.log.entries.filter { $0.category == "Retry" }
        #expect(waits.map(\.note) == ["HTTP \(status): waiting 5 s, attempt 2 of 4.",
                                      "HTTP \(status): waiting 15 s, attempt 3 of 4.",
                                      "HTTP \(status): waiting 45 s, attempt 4 of 4."])
        #expect(waits.allSatisfy { $0.isWarning && $0.service == "Apple Business Manager" && $0.connection == "Lab Org" })
    }

    @Test("A dropped connection: reads try 4 times, a write once")
    func dropped() async throws {
        let rig = AppleRig(MockServer { request in
            if request.path == AppleFixtures.tokenPath { return .json(200, AppleFixtures.token) }
            throw URLError(.networkConnectionLost)
        })
        let read = await message { _ = try await rig.client.mdmServers() }
        #expect(read != nil)
        #expect(rig.api.count == 4)
        #expect(rig.time.sleeps == [5, 15, 45])
        #expect(rig.log.entries.filter { $0.category == "Retry" }.first?.note == "Network error: waiting 5 s, attempt 2 of 4.")
        let write = await message { _ = try await rig.client.submitActivity(.release, serials: ["A"]) }
        #expect(write != nil)
        #expect(rig.api.count == 5)
        #expect(rig.time.sleeps == [5, 15, 45])
    }

    // changed on purpose: a read is retried after any server error (JTKit's rules); other errors aren't
    @Test("A read is retried after a server error; a 400 isn't")
    func notRetried() async {
        let rig = AppleRig(appleServer { $0.path == "/v1/mdmServers" ? AppleFixtures.error(500, title: "Internal") : nil })
        _ = await message { _ = try await rig.client.mdmServers() }
        #expect(rig.api.count == 4)
        let refused = AppleRig(appleServer { $0.path == "/v1/mdmServers" ? AppleFixtures.error(400, title: "Bad") : nil })
        _ = await message { _ = try await refused.client.mdmServers() }
        #expect(refused.api.count == 1)
    }

    // changed on purpose: JTKit's format (status line, every error, Error ID, hints)
    @Test("Error messages in the shared format",
          arguments: [(AppleFixtures.error(403, title: "Forbidden", detail: "The API account lacks access."),
                       "HTTP 403 Forbidden\nForbidden — The API account lacks access.\nThe API account isn’t allowed to do this. Check its access in Apple Business Manager."),
                      (AppleFixtures.error(403, title: "Forbidden"),
                       "HTTP 403 Forbidden\nForbidden\nThe API account isn’t allowed to do this. Check its access in Apple Business Manager."),
                      (MockResponse(status: 403, body: Data("Forbidden".utf8)),
                       "HTTP 403 Forbidden\nThe API account isn’t allowed to do this. Check its access in Apple Business Manager.")])
    func errorMessages(answer: MockResponse, expected: String) async {
        let rig = AppleRig(appleServer { $0.path == "/v1/mdmServers" ? answer : nil })
        #expect(await message { _ = try await rig.client.mdmServers() } == expected)
    }

    @Test("Every request is in the activity log as Apple Business, with the organization's name")
    func logged() async {
        let rig = AppleRig(Self.devicesServer())
        _ = try? await rig.client.device(serial: "A")
        _ = try? await rig.client.mdmServers()
        #expect(rig.log.entries.map(\.category) == ["Sign-in", "API", "API"])
        #expect(rig.log.entries.allSatisfy { $0.service == "Apple Business Manager" && $0.connection == "Lab Org" })
        // a device lookup's answer is recorded; a list's success isn't
        #expect(rig.log.entries[1].request?.responseBody?.contains("MacBook Air") == true)
        #expect(rig.log.entries[2].request?.responseBody == nil)
    }
}

// MARK: - Writes

@Suite("Apple: writes, as the client sends them")
@MainActor
struct AppleActivityTests {

    nonisolated static func activityServer(status: String = "COMPLETED") -> MockServer {
        appleServer { request in
            if request.path == "/v1/orgDeviceActivities", request.method == "POST" {
                return .json(201, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"IN_PROGRESS"}}}"#)
            }
            if request.path == "/v1/orgDeviceActivities/ACT-1" {
                return .json(200, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"\#(status)"}}}"#)
            }
            return nil
        }
    }

    @Test("The body of each activity")
    func bodies() async throws {
        let rig = AppleRig(Self.activityServer())
        let deadline = Date().addingTimeInterval(7 * 24 * 3600)
        let id = try await rig.client.submitActivity(.assign, serials: ["A", "B"], mdmServerID: "S1")
        #expect(id == "ACT-1")
        _ = try await rig.client.submitActivity(.unassign, serials: ["A"], mdmServerID: "S1")
        _ = try await rig.client.submitActivity(.release, serials: ["A"])
        _ = try await rig.client.submitActivity(.assignWithMigrationDeadline, serials: ["A"], mdmServerID: "S2", migrationDeadline: deadline)
        _ = try await rig.client.submitActivity(.updateMigrationDeadline, serials: ["A"], migrationDeadline: deadline)
        _ = try await rig.client.submitActivity(.cancelMigration, serials: ["A"])
        let posts = rig.api.filter { $0.method == "POST" }
        #expect(posts.allSatisfy { $0.path == "/v1/orgDeviceActivities" && $0.header("Content-Type") == "application/json" })
        let bodies = posts.map { body($0) ?? [:] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: deadline)
        #expect(stamp.hasSuffix("Z"))
        #expect(bodies[0] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"ASSIGN_DEVICES"},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"},{"type":"orgDevices","id":"B"}]},"mdmServer":{"data":{"type":"mdmServers","id":"S1"}}}}}"#))
        #expect(bodies[1] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"UNASSIGN_DEVICES"},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"}]},"mdmServer":{"data":{"type":"mdmServers","id":"S1"}}}}}"#))
        #expect(bodies[2] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"RELEASE_DEVICES"},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"}]}}}}"#))
        #expect(bodies[3] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE","activityTypeMetadata":{"mdmMigrationDeadlineDateTime":"\#(stamp)"}},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"}]},"mdmServer":{"data":{"type":"mdmServers","id":"S2"}}}}}"#))
        #expect(bodies[4] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"UPDATE_MDM_MIGRATION_DEADLINE","activityTypeMetadata":{"mdmMigrationDeadlineDateTime":"\#(stamp)"}},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"}]}}}}"#))
        #expect(bodies[5] == dictionary(#"{"data":{"type":"orgDeviceActivities","attributes":{"activityType":"CANCEL_MDM_MIGRATION"},"relationships":{"devices":{"data":[{"type":"orgDevices","id":"A"}]}}}}"#))
        // the write's request body is never recorded
        #expect(rig.log.entries.allSatisfy { $0.request?.requestBody == nil })
    }

    @Test("Refused before anything is sent: Release in School, no deadline, a deadline over 90 days")
    func refusals() async {
        let school = AppleRig(Self.activityServer(), kind: .school)
        #expect(await message { _ = try await school.client.submitActivity(.release, serials: ["A"]) }
                == "Apple School Manager can’t release devices from the organization.")
        let rig = AppleRig(Self.activityServer())
        #expect(await message { _ = try await rig.client.submitActivity(.updateMigrationDeadline, serials: ["A"]) }
                == "Update Migration Deadline needs a migration deadline.")
        #expect(await message {
            _ = try await rig.client.submitActivity(.assignWithMigrationDeadline, serials: ["A"], mdmServerID: "S",
                                                    migrationDeadline: Date().addingTimeInterval(91 * 24 * 3600))
        } == "Apple Business Manager won’t accept a migration deadline more than 90 days from now.")
        #expect(school.server.requests.isEmpty)
        #expect(rig.server.requests.isEmpty)
    }

    @Test("Which activities need a server and a deadline")
    func needs() {
        let all: [ABMClient.ActivityType] = [.assign, .unassign, .release, .assignWithMigrationDeadline,
                                             .updateMigrationDeadline, .cancelMigration]
        #expect(all.map(\.rawValue) == ["ASSIGN_DEVICES", "UNASSIGN_DEVICES", "RELEASE_DEVICES",
                                         "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE", "UPDATE_MDM_MIGRATION_DEADLINE",
                                         "CANCEL_MDM_MIGRATION"])
        #expect(all.filter(\.needsServer) == [.assign, .unassign, .assignWithMigrationDeadline])
        #expect(all.filter(\.needsDeadline) == [.assignWithMigrationDeadline, .updateMigrationDeadline])
        #expect(ABMClient.maximumMigrationDeadline == 90 * 24 * 3600)
    }

    @Test("An answer without an ID is no ID")
    func noID() async throws {
        let rig = AppleRig(appleServer { $0.path == "/v1/orgDeviceActivities" ? .json(201, "{}") : nil })
        #expect(try await rig.client.submitActivity(.release, serials: ["A"]) == nil)
    }

    // Changed on purpose (ROADMAP step 9, decided by Jordy): Apple's job is
    // watched for up to 2 minutes, checks from 2 s growing to 10 s, and what
    // Apple made of it is read. Before: every 2 s for 30 s, then silence.

    @Test("Watching Apple: from 2 s, growing, until Apple has finished; its outcome is read")
    func watchesUntilDone() async throws {
        let polls = LockedList<Int>()
        let rig = AppleRig(appleServer { request in
            guard request.path == "/v1/orgDeviceActivities/ACT-1" else { return nil }
            polls.append(1)
            let state = polls.items.count < 3 ? #""status":"IN_PROGRESS","subStatus":"PROCESSING""# : #""status":"COMPLETED","subStatus":"COMPLETED_WITH_SUCCESS""#
            return .json(200, #"{"data":{"id":"ACT-1","attributes":{\#(state)}}}"#)
        })
        #expect(try await rig.client.watch(activityID: "ACT-1") == .completed)
        #expect(polls.items.count == 3)
        #expect(rig.time.sleeps == [2, 3])
    }

    @Test("Watching Apple: still in progress after 2 minutes is a warning")
    func givesUp() async throws {
        let rig = AppleRig(appleServer { request in
            request.path == "/v1/orgDeviceActivities/ACT-1" ? .json(200, #"{"data":{"id":"ACT-1","attributes":{"status":"IN_PROGRESS"}}}"#) : nil
        })
        let outcome = try await rig.client.watch(activityID: "ACT-1")
        #expect(outcome == .stillProcessing)
        #expect(outcome.isWarning)
        #expect(abs(rig.time.sleeps.filter { $0 <= 10 }.reduce(0, +) - 120) < 0.5)
    }

    @Test("Watching Apple: a failed or partly failed job, a stopped one, a failed check",
          arguments: [("FAILED", "", ABM.ActivityOutcome.failed("FAILED")),
                      ("COMPLETED", "COMPLETED_WITH_FAILURE", .partlyFailed),
                      ("STOPPED", "STOPPING", .stopped)])
    func outcomes(status: String, sub: String, expected: ABM.ActivityOutcome) async throws {
        let rig = AppleRig(appleServer { request in
            request.path == "/v1/orgDeviceActivities/ACT-1"
                ? .json(200, #"{"data":{"id":"ACT-1","attributes":{"status":"\#(status)","subStatus":"\#(sub)"}}}"#) : nil
        })
        #expect(try await rig.client.watch(activityID: "ACT-1") == expected)
        let failing = AppleRig(appleServer { $0.path.hasPrefix("/v1/orgDeviceActivities/") ? AppleFixtures.error(400) : nil })
        let outcome = try await failing.client.watch(activityID: "ACT-1")
        #expect(outcome.isWarning)
        #expect(failing.api.count == 1)
    }
}

// MARK: - Writes from the app

/// Checkpoint with today's saved organizations, a key for each, and a fake Apple.
@MainActor
struct AppleHarness {
    let server: MockServer
    let model: LookupModel
    let log = ActivityLog()
    let time = VirtualClock()

    /// Off: the fake Apple is the only server (the guards have their own tests).
    init(_ server: MockServer = AppleActivityTests.activityServer(), underTest: UnderTestGuards = .off) {
        self.server = server
        let fixture = Fixture()
        for id in [SavedData.businessID, SavedData.schoolID] {
            fixture.secrets.setSecret(P256.Signing.PrivateKey().pemRepresentation, for: "abm.\(id.uuidString)")
        }
        model = LookupModel(settings: fixture.settings(), log: log, session: server.session, abmClock: time.clock,
                            underTest: underTest)
    }

    var activities: [RecordedRequest] {
        server.requests.filter { $0.path == "/v1/orgDeviceActivities" && $0.method == "POST" }
    }

    var actions: [ActivityLogEntry] { log.entries.filter { $0.category == "Action" } }

    /// A device in the Business organization.
    static func device(_ serial: String, server: String? = nil, released: Bool = false, extra: String = "",
                       org: UUID = SavedData.businessID) throws -> DeviceReport {
        let releasedField = released ? #","releasedFromOrgDateTime":"2026-01-01T00:00:00Z""# : ""
        let device = try JSONDecoder().decode(ABMDevice.self, from: Data(AppleFixtures.device(serial, extra: releasedField + extra).utf8))
        var report = DeviceReport(serial: serial)
        report.abm = .found(ABMInfo(device: device, orgID: org, orgName: org == SavedData.businessID ? "Apple Business Manager" : "Apple School Manager",
                                    mdmServerID: server, mdmServerName: server, coverage: []))
        return report
    }
}

@Suite("Apple: writes from Checkpoint")
@MainActor
struct AppleWriteTests {

    @Test("Unassign goes once per current server; devices with no server are skipped")
    func unassignPerServer() async throws {
        let harness = AppleHarness()
        let reports = try [AppleHarness.device("A", server: "S1"), AppleHarness.device("B", server: "S1"),
                           AppleHarness.device("C", server: "S2"), AppleHarness.device("D")]
        try await harness.model.setMDMServer(reports: reports, to: nil)
        let sent = harness.activities.compactMap { body($0) }
        #expect(sent.count == 2)
        let byServer = Dictionary(uniqueKeysWithValues: sent.map { item -> (String, [String]) in
            let data = item["data"] as? [String: Any]
            let relationships = data?["relationships"] as? [String: Any]
            let server = ((relationships?["mdmServer"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String ?? ""
            let devices = ((relationships?["devices"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return (server, devices)
        })
        #expect(byServer == ["S1": ["A", "B"], "S2": ["C"]])
        let action = try #require(harness.actions.first)
        #expect(action.detail == "Unassigned 3 devices from device management")
        #expect(action.connection == "Apple Business Manager")
        #expect(action.service == "Apple Business Manager")
    }

    @Test("Nothing assigned: nothing sent, nothing logged")
    func nothingToUnassign() async throws {
        let harness = AppleHarness()
        try await harness.model.setMDMServer(reports: [AppleHarness.device("D")], to: nil)
        #expect(harness.activities.isEmpty)
        #expect(harness.actions.isEmpty)
    }

    @Test("Released devices are skipped; with none left the action is refused")
    func released() async throws {
        let harness = AppleHarness()
        let text = await message { try await harness.model.setMDMServer(reports: [AppleHarness.device("A", released: true)], to: "S1") }
        #expect(text == "None of the selected devices are in Apple Business Manager.")
        try await harness.model.setMDMServer(reports: [AppleHarness.device("A", released: true), AppleHarness.device("B")], to: "S1")
        let devices = ((body(try #require(harness.activities.first))?["data"] as? [String: Any])?["relationships"] as? [String: Any])
        #expect(((devices?["devices"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["B"])
    }

    @Test("An assignment waits for Apple, then logs one Action entry with the serials")
    func assignLogged() async throws {
        let harness = AppleHarness()
        try await harness.model.setMDMServer(reports: [AppleHarness.device("A"), AppleHarness.device("B")], to: "S1")
        #expect(harness.server.requests.contains { $0.path == "/v1/orgDeviceActivities/ACT-1" })
        let action = try #require(harness.actions.first)
        #expect(action.detail == "Assigned 2 devices to S1")
        #expect(!action.isFailure)
        #expect(action.identifiers.map(\.value).sorted() == ["A", "B"])
    }

    // changed on purpose (decided by Jordy): Apple's outcome is read and logged
    @Test("A job Apple reports as FAILED is a failed Action entry, and the error is shown")
    func failedJob() async throws {
        let harness = AppleHarness(AppleActivityTests.activityServer(status: "FAILED"))
        let text = await message { try await harness.model.setMDMServer(reports: [AppleHarness.device("A")], to: "S1") }
        #expect(text == "Assigned 1 device to S1. Apple reports the job failed (FAILED); its activity report in Apple Business Manager says why.")
        let action = try #require(harness.actions.first)
        #expect(action.detail == "Assigned 1 device to S1 — Apple reports the job failed (FAILED); its activity report in Apple Business Manager says why.")
        #expect(action.isFailure)
    }

    @Test("A job still running after 2 minutes is a warning, not done")
    func runningJob() async throws {
        let harness = AppleHarness(AppleActivityTests.activityServer(status: "IN_PROGRESS"))
        try await harness.model.setMDMServer(reports: [AppleHarness.device("A")], to: "S1")
        let action = try #require(harness.actions.first)
        #expect(!action.isFailure)
        #expect(action.isWarning)
        #expect(action.detail == "Assigned 1 device to S1 — Apple is still processing it after 2 minutes; check the devices again in a while.")
    }

    @Test("A refused write: a failed Action entry with Apple's message, and the error is shown")
    func refusedWrite() async throws {
        let harness = AppleHarness(appleServer { $0.method == "POST" && $0.path == "/v1/orgDeviceActivities"
            ? AppleFixtures.error(400, title: "Bad Request", detail: "Device not found.") : nil })
        let text = await message { try await harness.model.releaseFromABM(reports: [AppleHarness.device("A")]) }
        // changed on purpose: JTKit's format
        #expect(text == "HTTP 400 Bad Request\nBad Request — Device not found.")
        let action = try #require(harness.actions.first)
        #expect(action.detail == "Released 1 device from Apple Business Manager — HTTP 400 Bad Request\nBad Request — Device not found.")
        #expect(action.isFailure)
    }

    @Test("Release in Apple School Manager is refused before anything is sent")
    func schoolRelease() async throws {
        let harness = AppleHarness()
        let reports = [try AppleHarness.device("A", org: SavedData.schoolID)]
        #expect(harness.model.releaseUnavailabilityReason(for: reports) == "Apple School Manager provides no way to release devices from the organization.")
        let text = await message { try await harness.model.releaseFromABM(reports: reports) }
        #expect(text == "Apple School Manager provides no way to release devices from the organization.")
        #expect(harness.activities.isEmpty)
    }

    @Test("Migrations: only capable devices, only devices migrating; the summary names the deadline")
    func migrations() async throws {
        let harness = AppleHarness()
        let deadline = Date().addingTimeInterval(7 * 24 * 3600)
        let capable = try AppleHarness.device("A", extra: #","isMdmMigrationCapable":true"#)
        let migrating = try AppleHarness.device("B", extra: #","mdmMigrationStatus":"REQUESTED""#)
        let plain = try AppleHarness.device("C")
        try await harness.model.scheduleMigration(reports: [capable, migrating, plain], to: "S2", deadline: deadline)
        try await harness.model.updateMigrationDeadline(reports: [capable, migrating, plain], deadline: deadline)
        try await harness.model.cancelMigration(reports: [capable, migrating, plain])
        let due = ", due \(deadline.formatted(date: .abbreviated, time: .shortened))"
        #expect(harness.actions.map(\.detail) == ["Scheduled migration of 1 device to another service" + due,
                                                  "Moved the migration deadline for 1 device" + due,
                                                  "Cancelled the migration of 1 device"])
        #expect(await message { try await harness.model.cancelMigration(reports: [plain]) }
                == "None of the selected devices have a migration in progress.")
        #expect(await message { try await harness.model.scheduleMigration(reports: [plain], to: "S2", deadline: deadline) }
                == "None of the selected devices can be migrated.")
    }
}

// MARK: - Confirmations

// Changed on purpose (ROADMAP step 9, decided by Jordy): the dialogs follow
// JTKit's rules. Before, no dialog named the organization and nothing was
// typed, whatever the number of devices.
@Suite("Apple: confirmations by JTKit's rules")
@MainActor
struct AppleDialogTests {
    static let deadline = Date().addingTimeInterval(7 * 24 * 3600)
    static let migrating = #","isMdmMigrationCapable":true,"mdmMigrationStatus":"REQUESTED","mdmMigrationDeadlineDateTime":"2099-01-01T00:00:00Z""#

    static let writes: [AppleWrite] = [.setServer("S1"), .setServer(nil), .release,
                                       .scheduleMigration(server: "S1", deadline: deadline), .updateDeadline(deadline),
                                       .cancelMigration]

    @Test("All six name the organization; Release and the two deadlines ask for the number from two devices")
    func rules() throws {
        let harness = AppleHarness()
        let one = [try AppleHarness.device("A", server: "S0", extra: Self.migrating)]
        let two = one + [try AppleHarness.device("B", server: "S0", extra: Self.migrating)]
        let typed: Set<ABM.ActivityType> = [.release, .assignWithMigrationDeadline, .updateMigrationDeadline]
        for write in Self.writes {
            let single = try #require(harness.model.appleConfirmation(write, reports: one), "\(write)")
            let double = try #require(harness.model.appleConfirmation(write, reports: two), "\(write)")
            #expect(single.connectionLine == "On “Apple Business Manager”.", "\(write)")
            #expect(double.connectionLine == "On “Apple Business Manager”.", "\(write)")
            #expect(!single.needsTyping, "\(write)")
            #expect(double.typedCount == (typed.contains(write.type) ? 2 : nil), "\(write)")
            #expect(single.isDestructive == (write == .release || write == .cancelMigration), "\(write)")
        }
    }

    @Test("The dialog: the action and the device, the organization, what it does")
    func texts() throws {
        let harness = AppleHarness()
        let report = try AppleHarness.device("C02XK1JHJG5H", server: "S0", extra: Self.migrating)
        let release = try #require(harness.model.appleConfirmation(.release, reports: [report]))
        #expect(release.title == "Release from Organization — C02XK1JHJG5H")
        #expect(release.dialogMessage == """
            On “Apple Business Manager”.

            The device will be removed from your organization and can no longer be assigned to an MDM server. This can’t be undone through the API.
            """)
        #expect(release.actionTitle == "Release from Organization")
        let cancel = try #require(harness.model.appleConfirmation(.cancelMigration, reports: [report]))
        #expect(cancel.message.contains("stays assigned to S0 in Apple Business"))
        let assign = try #require(harness.model.appleConfirmation(.setServer("S1"), reports: [report]))
        #expect(assign.title == "Assign to “S1” — C02XK1JHJG5H")
    }

    @Test("Devices left out are explained before anything is typed")
    func skipped() throws {
        let harness = AppleHarness()
        let reports = [try AppleHarness.device("A", server: "S0"), try AppleHarness.device("B", server: "S0"),
                       try AppleHarness.device("C", released: true)]
        let release = try #require(harness.model.appleConfirmation(.release, reports: reports))
        #expect(release.typedCount == 2)
        #expect(release.explanation == "1 of the 3 selected devices are released or not in Apple Business Manager, so it isn’t included.")
        let unassign = try #require(harness.model.appleConfirmation(.setServer(nil), reports: [try AppleHarness.device("A")] + reports))
        #expect(unassign.title == "Unassign from MDM Server — 2 Devices")
        #expect(harness.model.appleConfirmation(.cancelMigration, reports: reports) == nil)
    }

    @Test("Update Deadline warns when the new deadline is earlier than the current one")
    func earlier() throws {
        let harness = AppleHarness()
        let report = try AppleHarness.device("A", extra: Self.migrating)
        let earlier = try #require(harness.model.appleConfirmation(.updateDeadline(Self.deadline), reports: [report]))
        #expect(earlier.message.hasPrefix("This deadline is earlier than the current one, or already past"))
    }
}

// MARK: - The key and the signed request never leave the client

/// Everything that leaves the client as text: each log entry's fields, both
/// exports, and the messages shown.
@MainActor
func everythingShown(_ log: ActivityLog, messages: [String?]) -> String {
    let fields: [String?] = log.entries.flatMap { entry -> [String?] in
        [entry.operation, entry.detail, entry.note, entry.request?.url, entry.request?.requestBody,
         entry.request?.responseBody, entry.request?.error, entry.request?.bodyNote]
            + (entry.request?.requestHeaders ?? []).map(\.value)
            + (entry.request?.responseHeaders ?? []).map(\.value)
    }
    let exports = [ActivityLogExport.text(log.entries, masked: false), ActivityLogExport.text(log.entries, masked: true)]
    let all: [String?] = fields + messages + exports.map { Optional($0) }
    return all.compactMap { $0 }.joined(separator: "\n")
}

/// The pieces of a secret that must not appear: the whole, and for a PEM
/// every 20-character piece of its body; for the signed request, its
/// signed part and its signature.
nonisolated func secretPieces(pem: String, assertion: String?) -> [String] {
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    var pieces = [pem, body] + stride(from: 0, to: max(body.count - 20, 1), by: 10).map {
        String(body.dropFirst($0).prefix(20))
    }
    if let assertion {
        let parts = assertion.split(separator: ".")
        pieces.append(assertion)
        if parts.count == 3 { pieces += [String(parts[1]), String(parts[2])] }
    }
    return pieces.filter { !$0.isEmpty }
}

@Suite("Apple: the private key and the signed sign-in request stay inside")
@MainActor
struct AppleSecretTests {

    /// How a fake Apple answers the sign-in, each time repeating what it got.
    enum Echo: String, CaseIterable, Sendable {
        /// A 400 with the form in Apple's `error_description`.
        case formInDescription
        /// A 400 naming the signed request without a field name.
        case bareAssertion
        /// A 400 that isn't JSON, holding the raw form.
        case plainText
        /// A 200 that isn't JSON.
        case brokenSuccess
        /// A 401 from the API with the token in its detail.
        case tokenInAPIError

        func answer(_ request: RecordedRequest) -> MockResponse? {
            let form = request.bodyString
            let assertion = AppleFixtures.form(request)["client_assertion"] ?? ""
            let isSignIn = request.path == AppleFixtures.tokenPath
            switch self {
            case .formInDescription:
                return isSignIn ? .json(400, #"{"error":"invalid_client","error_description":"received \#(form)"}"#) : nil
            case .bareAssertion:
                return isSignIn ? .json(400, #"{"error":"invalid_client","error_description":"Assertion \#(assertion) is not valid"}"#) : nil
            case .plainText:
                return isSignIn ? MockResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request: \(form) \(assertion)".utf8)) : nil
            case .brokenSuccess:
                return isSignIn ? MockResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("ok \(assertion)".utf8)) : nil
            case .tokenInAPIError:
                return isSignIn ? nil : AppleFixtures.error(401, title: "Unauthorized", detail: "Token SECRET-apple-token rejected")
            }
        }
    }

    @Test("Neither the key nor the signed request reaches the log, either export or a message", arguments: Echo.allCases)
    func nothingLeaks(echo: Echo) async throws {
        let rig = AppleRig(appleServer { echo.answer($0) })
        let shown = await message { _ = try await rig.client.mdmServers() }
        let assertion = rig.signIns.first.flatMap { AppleFixtures.form($0)["client_assertion"] }
        #expect(assertion != nil)
        let text = everythingShown(rig.log, messages: [shown])
        for piece in secretPieces(pem: rig.pem, assertion: assertion) {
            #expect(!text.contains(piece), "\(echo): found \(piece.prefix(24))…")
        }
        #expect(!text.contains("SECRET-apple-token"), "\(echo): the token")
    }

    @Test("A failed organization read's Action entry carries no secret either", arguments: Echo.allCases)
    func actionEntries(echo: Echo) async throws {
        let harness = AppleHarness(appleServer { echo.answer($0) })
        let org = try #require(harness.model.settings.abmOrgs.first { $0.id == SavedData.businessID })
        _ = await harness.model.organizationSnapshot(for: org)
        let pem = try #require(harness.model.settings.secret(for: .apple(org)))
        let assertion = harness.server.requests.first { $0.path == AppleFixtures.tokenPath }
            .flatMap { AppleFixtures.form($0)["client_assertion"] }
        let text = everythingShown(harness.log, messages: [])
        #expect(harness.actions.contains { $0.isFailure })
        for piece in secretPieces(pem: pem, assertion: assertion) {
            #expect(!text.contains(piece), "\(echo): found \(piece.prefix(24))…")
        }
    }

    @Test("A key that can't be read isn't repeated in the message or the log")
    func badKey() async {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg0000000000000000\n-----END PRIVATE KEY-----"
        let rig = AppleRig(pem: pem)
        let shown = await message { _ = try await rig.client.mdmServers() }
        let text = everythingShown(rig.log, messages: [shown])
        for piece in secretPieces(pem: pem, assertion: nil) {
            #expect(!text.contains(piece))
        }
    }
}
