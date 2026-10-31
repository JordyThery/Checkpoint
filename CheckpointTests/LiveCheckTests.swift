import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1). ⌘U skips them. Tenants are named by
// role only:
// - apple-business, apple-school: read only. Up to 5 serials are taken from
//   the organization's own device list at run time (one request), kept in
//   memory only, and looked up by the app's own lookup in Apple and every MDM
//   tenant of the run. The report holds counts, never a serial. Apple's limit
//   is kept well under by JTKit (9 a minute, 40 a run per organization).
// - jamfpro-readonly, jamfschool-readonly, intune-test: read only (intune-test
//   is made read only for Checkpoint's run). One serial from the tenant's own
//   inventory, masked, found by the app's lookup; an empty inventory is
//   "nothing to look up" with the counts.
// - jamfpro-production: the same, only with --include-production.
// - jamf-test-a (Platform API): the test code creates a JTKTEST computer and a
//   JTKTEST mobile device record with made-up serials; the app looks both up,
//   alone and in the stale/misplaced view (All Connections); the app's own
//   Delete Record removes the iPad behind a fence; cleanup removes the rest.
// Credentials: the Apple keys, jamfpro-readonly, jamfpro-production and
// intune-test come from Checkpoint's own saved connections (matched to the
// allow-list by client ID, host or tenant ID, read only, copied into memory);
// jamfschool-readonly and jamf-test-a from the Keychain items the release
// check reads. The saved connections themselves are never used or changed.
// Throughout, the checks prove that no MDM command, Apple write, secret read
// or request to a saved connection was attempted (`UnderTest`).

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

// MARK: Roles and connections

enum Roles {
    static let business = "apple-business"
    static let school = "apple-school"
    static let readOnlyPro = "jamfpro-readonly"
    static let production = "jamfpro-production"
    static let readOnlySchool = "jamfschool-readonly"
    static let intune = "intune-test"
    static let testA = "jamf-test-a"
}

struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The note for a failed step: a missing privilege is named.
func failure(_ error: any Error) -> String {
    if let error = error as? JamfPlatform.APIError, error.status == 401 || error.status == 403 {
        return "MISSING PRIVILEGE: \(error.localizedDescription)"
    }
    return "\(error.localizedDescription)"
}

/// Replaces serials in a note with placeholders, so no report or log holds them.
func masked(_ text: String, serials: [String]) -> String {
    serials.enumerated().reduce(text) { text, item in
        text.replacingOccurrences(of: item.element, with: "serial \(item.offset + 1)", options: .caseInsensitive)
    }
}

/// One allow-listed tenant: an in-memory copy of its connection, named by role.
struct LiveConnection {
    let role: String
    let record: CheckpointConnection
    let secret: String
    /// Where the credentials came from, for the report.
    let source: String

    var id: UUID { record.id }
    var mdm: MDMConnection? { if case .mdm(let server) = record { server } else { nil } }
    var org: ABMConfig? { if case .apple(let org) = record { org } else { nil } }
}

@MainActor
enum LiveConnections {
    /// Checkpoint's saved lists, read only (never written).
    static func savedOrgs() -> [ABMConfig] {
        UserDefaults.standard.data(forKey: CheckpointConnectionStorage.appleKey)
            .flatMap { try? JSONDecoder().decode([ABMConfig].self, from: $0) } ?? []
    }

    static func savedServers() -> [MDMConnection] {
        UserDefaults.standard.data(forKey: CheckpointConnectionStorage.mdmKey)
            .flatMap { try? JSONDecoder().decode([MDMConnection].self, from: $0) } ?? []
    }

    /// A saved connection's secret, read from Checkpoint's Keychain items (never written).
    static func savedSecret(_ record: CheckpointConnection) throws -> String {
        guard let secret = CheckpointSecrets.keychain.secret(for: CheckpointSecrets.account(for: record.connection)),
              !secret.isEmpty else { throw LiveFailure("No saved secret for the connection matched to this role") }
        return secret
    }

    static func host(_ address: String) -> String {
        let url = address.contains("://") ? address : "https://" + address
        return URL(string: url)?.host()?.lowercased() ?? ""
    }

    /// The run's tenant for a role, or nil when the role isn't in this run.
    static func connection(_ run: LiveCheckRun, role: String) throws -> LiveConnection? {
        guard run.roles.contains(role) else { return nil }
        let label = "Live \(role)"
        switch role {
        case Roles.business, Roles.school:
            let service: AllowList.Service = role == Roles.business ? .appleBusinessManager : .appleSchoolManager
            let entry = try run.entry(role: role, service: service)
            let kind: AppleOrgKind = role == Roles.business ? .business : .school
            guard var org = savedOrgs().first(where: { $0.kind == kind && $0.clientID == entry.clientID }) else {
                throw LiveFailure("\(role): no saved Checkpoint organization with this client ID")
            }
            let secret = try savedSecret(.apple(org))
            org.name = label
            return LiveConnection(role: role, record: .apple(org), secret: secret, source: "Checkpoint's saved organization")
        case Roles.readOnlyPro, Roles.production:
            let entry = try run.entry(role: role, service: .jamfPro)
            guard var server = savedServers().first(where: {
                $0.product == .jamfPro && !$0.isUsingPlatformGateway && entry.hosts.contains(host($0.baseURL))
            }) else { throw LiveFailure("\(role): no saved Checkpoint Jamf Pro connection to this host") }
            let secret = try savedSecret(.mdm(server))
            server.name = label
            return LiveConnection(role: role, record: .mdm(server), secret: secret, source: "Checkpoint's saved connection")
        case Roles.intune:
            let entry = try run.entry(role: role, service: .intune)
            guard var server = savedServers().first(where: {
                $0.product == .intune && $0.tenantID.lowercased() == entry.entraTenantID?.lowercased()
            }) else { throw LiveFailure("\(role): no saved Checkpoint Intune connection for this tenant") }
            let secret = try savedSecret(.mdm(server))
            server.name = label
            return LiveConnection(role: role, record: .mdm(server), secret: secret, source: "Checkpoint's saved connection")
        case Roles.readOnlySchool:
            let entry = try run.entry(role: role, service: .jamfSchool)
            var server = MDMConnection(name: label, product: .jamfSchool)
            server.baseURL = "https://" + (entry.host ?? "")
            server.account = try run.credential(role, "network-id")
            return LiveConnection(role: role, record: .mdm(server), secret: try run.credential(role, "api-key"),
                                  source: "the release check's Keychain items")
        case Roles.testA:
            let entry = try run.entry(role: role, service: .jamfPlatform)
            var server = MDMConnection(name: label, product: .jamfPro, authMethod: .platformGateway)
            server.region = try #require(JamfRegion(rawValue: entry.region ?? ""))
            server.environmentID = try #require(entry.environmentID)
            if let web = try? run.entry(role: role, service: .jamfPro).host { server.baseURL = "https://" + web }
            server.account = try run.credential(role, "client-id")
            return LiveConnection(role: role, record: .mdm(server), secret: try run.credential(role, "client-secret"),
                                  source: "the release check's Keychain items")
        default:
            throw LiveFailure("\(role) isn't used by Checkpoint")
        }
    }

    /// The run's MDM tenants (read-only ones and jamf-test-a).
    static func mdm(_ run: LiveCheckRun) throws -> [LiveConnection] {
        try [Roles.readOnlyPro, Roles.production, Roles.readOnlySchool, Roles.intune, Roles.testA]
            .compactMap { try connection(run, role: $0) }
    }
}

/// The app's own lookup model on in-memory copies of the run's connections,
/// with settings of this test process only, on the guarded network (or a
/// fence in front of it). Its under-test guards are on, as in the app.
@MainActor
final class LiveModel {
    let model: LookupModel
    let activity = ActivityLog()

    init(_ connections: [LiveConnection], session: URLSession) throws {
        let (_, defaults) = TestSettings.makeDefaults("live")
        let orgs = connections.compactMap(\.org)
        let servers = connections.compactMap(\.mdm)
        defaults.set(try JSONEncoder().encode(orgs), forKey: CheckpointConnectionStorage.appleKey)
        defaults.set(try JSONEncoder().encode(servers), forKey: CheckpointConnectionStorage.mdmKey)
        let secrets = InMemorySecretStore()
        for connection in connections {
            secrets.setSecret(connection.secret, for: CheckpointSecrets.account(for: connection.record.connection))
        }
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        precondition(!settings.holdsSavedConnections)
        model = LookupModel(settings: settings, log: activity, session: session)
    }

    /// The app's own lookup of these serials, in one connection or all.
    func lookUp(_ serials: [String], mdm scope: LookupModel.MDMScope, apple org: UUID? = nil) async -> [DeviceReport] {
        if let org { model.abmScope = .organization(org) }
        model.mdmScope = scope
        await model.lookUp(serialsText: serials.joined(separator: "\n"))
        return model.reports
    }
}

/// The "under tests" checks, recorded as steps; any attempt fails the run.
@MainActor
func checkUnderTest(_ run: LiveCheckRun, when: String) {
    let logs: [(TestRun.AttemptLog, String)] = [
        (.commands, "no MDM command under tests"),
        (.appleWrites, "no Apple Business or School Manager write under tests"),
        (.secretReads, "no device secret read under tests"),
        (.savedConnections, "no request to a saved connection under tests"),
    ]
    for (log, step) in logs {
        let attempts = log.attempts()
        run.record(step: "\(step) (\(when))", passed: attempts.isEmpty,
                   note: attempts.isEmpty ? nil : "\(attempts.count) refused: " + attempts.map { "\($0.what) (\($0.process))" }.joined(separator: "; "))
        #expect(attempts.isEmpty, "\(step): \(attempts.map(\.what))")
    }
}

// MARK: Inventories (reads only, test code)

@MainActor
enum Inventory {
    static func jamf(_ connection: LiveConnection, _ run: LiveCheckRun) throws -> JamfPlatform.Client {
        let secret = connection.secret
        return try JamfPlatform.Client(connection: connection.record.connection, secret: { secret },
                                       recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
    }

    /// One serial from a tenant's own inventory, or the counts when it has none.
    static func firstSerial(_ connection: LiveConnection, _ run: LiveCheckRun) async throws -> (serial: String?, counts: String) {
        guard let server = connection.mdm else { throw LiveFailure("\(connection.role) isn't an MDM connection") }
        switch server.product {
        case .jamfPro:
            let client = try jamf(connection, run)
            let page = [URLQueryItem(name: "section", value: "HARDWARE"), URLQueryItem(name: "page", value: "0"),
                        URLQueryItem(name: "page-size", value: "1")]
            let mobiles = try await client.json("pro/v2/mobile-devices/detail", query: page, privilege: .readMobileDevices)
            if let serial = mobiles["results"]?.arrayValue?.first?["hardware"]?["serialNumber"]?.stringValue, !serial.isEmpty {
                return (serial, "")
            }
            let computers = try await client.json("pro/v4/computers-inventory", query: page, privilege: .readComputers)
            if let serial = computers["results"]?.arrayValue?.first?["hardware"]?["serialNumber"]?.stringValue, !serial.isEmpty {
                return (serial, "")
            }
            let count = { (json: LosslessJSON) in json["totalCount"]?.numberValue?.intValue.map(String.init) ?? "?" }
            return (nil, "\(count(mobiles)) mobile devices, \(count(computers)) computers")
        case .jamfSchool:
            let client = try JamfSchool.Client(connection: server.connection, apiKey: connection.secret,
                                               recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
            let fleet = try await client.fleet()
            let serial = fleet.values.sorted { $0.udid < $1.udid }.compactMap(\.serialNumber).first { !$0.isEmpty }
            return (serial, "\(fleet.count) devices")
        case .intune:
            let secret = connection.secret
            guard let client = LookupModel.intuneClient(for: server, secret: { secret }, log: nil, session: run.network.session) else {
                throw LiveFailure("\(connection.role): incomplete Intune connection")
            }
            let devices = try await client.intuneDevices()
            let serial = devices.compactMap(\.serialNumber).sorted().first { !$0.isEmpty }
            return (serial, "\(devices.count) managed devices")
        }
    }
}

/// The verdicts of a lookup, as counts by kind (no names).
func verdictCounts(_ reports: [DeviceReport]) -> String {
    var counts: [String: Int] = [:]
    for report in reports {
        let kind: String
        switch report.mdmVerdict {
        case .consistent: kind = "consistent"
        case .assignedElsewhere: kind = "misplaced"
        case .staleElsewhere: kind = "stale elsewhere"
        case .unassignedWithRecords: kind = "unassigned with records"
        case .unverified: kind = "unverified"
        case nil: kind = "no finding"
        }
        counts[kind, default: 0] += 1
    }
    return counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
}

// MARK: The test records on jamf-test-a

/// Mobile device and computer records on jamf-test-a, through the Classic API
/// over the Platform gateway, the route the app's Delete Record uses for
/// mobile devices too (so the guarded network's ledger matches).
@MainActor
struct TestDevices {
    static let mobiles = "mobiledevices"
    static let computers = "computers"
    let client: JamfPlatform.Client

    /// An unmanaged record no device will ever enroll as, with no model or
    /// OS, like a record that never enrolled: Jamf types it "Unknown" and its
    /// device list leaves out the name, which JTKit 0.12.4 then reads from the
    /// record itself also in a lookup of many serials (the app's). Its name is
    /// the first `<name>`, which the guarded network checks for the run's prefix.
    func createMobile(name: String, serial: String, udid: String) async throws -> String {
        let xml = """
        <mobile_device><general><name>\(escape(name))</name><display_name>\(escape(name))</display_name>\
        <device_name>\(escape(name))</device_name><serial_number>\(serial)</serial_number><udid>\(udid)</udid>\
        <managed>false</managed><supervised>false</supervised></general></mobile_device>
        """
        let response = try await client.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.mobiles),
                                                         body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                             privilege: "Create Mobile Devices")
        return try #require(JamfClassic.createdID(in: response.data), "The mobile device create returned no id")
    }

    /// An unmanaged computer record, never enrolled: a made-up Mac.
    func createComputer(name: String, serial: String, udid: String) async throws -> String {
        let xml = """
        <computer><general><name>\(escape(name))</name><serial_number>\(serial)</serial_number><udid>\(udid)</udid>\
        <remote_management><managed>false</managed></remote_management></general>\
        <hardware><model>MacBook Air (M2, 2022)</model><model_identifier>Mac14,2</model_identifier>\
        <os_name>macOS</os_name><os_version>15.0</os_version></hardware></computer>
        """
        let response = try await client.send(HTTPRequest(method: "POST", path: JamfClassic.createPath(Self.computers),
                                                         body: Data(xml.utf8), accept: "application/xml", contentType: "application/xml"),
                                             privilege: "Create Computers")
        return try #require(JamfClassic.createdID(in: response.data), "The computer create returned no id")
    }

    /// Every mobile device and computer record whose name marks it as a test object.
    func testRecords(_ run: LiveCheckRun) async throws -> [(resource: String, id: String, name: String)] {
        var found: [(resource: String, id: String, name: String)] = []
        for (resource, key, privilege) in [(Self.mobiles, "mobile_devices", JamfPro.Privilege.readMobileDevices),
                                           (Self.computers, "computers", JamfPro.Privilege.readComputers)] {
            let response = try await client.send(HTTPRequest(method: "GET", path: "proclassic/\(resource)", accept: "application/json"),
                                                 privilege: privilege)
            for record in try LosslessJSON(data: response.data)[key]?.arrayValue ?? [] {
                if let id = record["id"]?.stringValue, let name = record["name"]?.stringValue, run.isSweepable(name) {
                    found.append((resource, id, name))
                }
            }
        }
        return found
    }

    /// Whether the record still exists (a 404 means it's gone).
    func exists(resource: String, id: String) async throws -> Bool {
        do {
            _ = try await client.send(HTTPRequest(method: "GET", path: JamfClassic.path(resource, id: id), accept: "application/json"),
                                      privilege: resource == Self.mobiles ? .readMobileDevices : .readComputers)
            return true
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            return false
        }
    }

    func delete(resource: String, id: String) async throws {
        if resource == Self.computers {
            _ = try await client.send(HTTPRequest(method: "DELETE", path: JamfClassic.path(Self.computers, id: id), accept: "application/json"),
                                      privilege: "Delete Computers")
        } else {
            try await client.deleteMobileDevice(id: id)
        }
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: The Delete Record fence

/// In front of the guarded network for the app's model on jamf-test-a: lets
/// through reads, sign-in, and one change only, the delete of this run's
/// test iPad. Anything else is refused before it is sent and fails the check.
final class DeleteFence: @unchecked Sendable {
    static let header = "X-JTKTEST-Fence"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fences: [UUID: DeleteFence] = [:]

    let id = UUID()
    let inner: URLSession
    let mobileID: String
    private let lock = NSLock()
    private var refused: [String] = []
    private var deleted = 0

    init(inner: URLSession, mobileID: String) {
        self.inner = inner
        self.mobileID = mobileID
        Self.lock.withLock { Self.fences[id] = self }
    }

    static func fence(_ id: UUID) -> DeleteFence? { lock.withLock { fences[id] } }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteFenceProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id.uuidString]
        return URLSession(configuration: configuration)
    }

    var refusals: [String] { lock.withLock { refused } }
    var deletes: Int { lock.withLock { deleted } }

    static let signInPaths: Set<String> = ["/auth/token", "/api/oauth/token", "/api/v1/auth/token",
                                           "/api/v1/auth/invalidate-token", "/api/v1/auth/keep-alive"]

    func allows(method: String, path: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            return true
        case "POST":
            return Self.signInPaths.contains(path)
        case "DELETE":
            return lock.withLock {
                guard deleted == 0, path.hasSuffix("/mobiledevices/id/\(mobileID)") else { return false }
                deleted += 1
                return true
            }
        default:
            return false
        }
    }

    func refuse(_ request: String) { lock.withLock { refused.append(request) } }
}

private final class DeleteFenceProtocol: URLProtocol, @unchecked Sendable {
    private var forwarding: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: DeleteFence.header), let id = UUID(uuidString: value),
              let fence = DeleteFence.fence(id) else {
            client?.urlProtocol(self, didFailWithError: LiveFailure("A request without its fence"))
            return
        }
        var forwarded = request
        forwarded.setValue(nil, forHTTPHeaderField: DeleteFence.header)
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body.isEmpty ? nil : body
        let method = forwarded.httpMethod ?? "GET"
        let path = forwarded.url?.path(percentEncoded: false) ?? ""
        guard fence.allows(method: method, path: path) else {
            fence.refuse("\(method) \(path)")
            client?.urlProtocol(self, didFailWithError: LiveFailure("The fence refused \(method) \(path): the app may only delete this run's test iPad"))
            return
        }
        let client = client
        forwarding = Task { [self] in
            do {
                let (data, response) = try await fence.inner.data(for: forwarded)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        forwarding?.cancel()
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and one small read on each tenant, plus a count of left-over
    /// test records on jamf-test-a. Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        checkUnderTest(run, when: "start")
        var failed: (any Error)?
        for role in [Roles.business, Roles.school, Roles.readOnlyPro, Roles.production, Roles.readOnlySchool, Roles.intune, Roles.testA] {
            guard run.roles.contains(role) else { continue }
            do {
                guard let connection = try LiveConnections.connection(run, role: role) else { continue }
                let live = try LiveModel([connection], session: run.network.session)
                var note: String
                switch connection.record {
                case .apple(let org):
                    let client = try #require(live.model.makeABMClient(for: org), "\(role): incomplete organization")
                    let services = try await client.verify()
                    note = "signed in; \(services) device management services"
                case .mdm(let server):
                    switch server.product {
                    case .jamfPro:
                        let client = try #require(live.model.makeJamfClient(for: server), "\(role): incomplete connection")
                        try await client.verify()
                        note = "signed in"
                    case .jamfSchool:
                        let client = try #require(live.model.makeJamfSchoolClient(for: server), "\(role): incomplete connection")
                        note = "signed in; \(try await client.verify()) locations"
                    case .intune:
                        let client = try #require(live.model.makeIntuneClient(for: server), "\(role): incomplete connection")
                        try await client.testConnection()
                        note = "signed in"
                    }
                }
                if role == Roles.testA {
                    let records = try await TestDevices(client: try Inventory.jamf(connection, run)).testRecords(run)
                    note += "; \(records.count) left-over test records"
                }
                run.record(step: "sign in: \(role)", passed: true, note: "\(note) (credentials: \(connection.source))")
            } catch {
                run.record(step: "sign in: \(role)", passed: false, note: failure(error))
                failed = failed ?? error
            }
        }
        if run.readOnlyRoles.contains(Roles.intune) {
            run.record(step: "intune-test is read only for Checkpoint", passed: true, note: "READ_ONLY_ROLES")
        }
        if let failed { throw failed }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: lookups and test records", .enabled(if: live), .serialized)
struct LiveLookupTests {
    /// Apple: up to 5 serials per organization from its own list, looked up
    /// in Apple and every MDM tenant; then one serial per read-only MDM
    /// tenant. Nothing is written anywhere.
    @Test func readOnlyLookups() async throws {
        let run = try LiveCheckRun.current()
        checkUnderTest(run, when: "before the lookups")
        let mdm = try LiveConnections.mdm(run)
        var failed: (any Error)?

        // The two organizations in parallel (Apple's limit is per organization).
        let orgs = try [Roles.business, Roles.school].compactMap { try LiveConnections.connection(run, role: $0) }
        let models = try orgs.map { try LiveModel([$0] + mdm, session: run.network.session) }
        let appleErrors = await withTaskGroup(of: (any Error)?.self) { group in
            for (org, live) in zip(orgs, models) {
                group.addTask { @MainActor in
                    do {
                        try await Self.appleLookup(run, org: org, live: live)
                        return nil
                    } catch {
                        run.record(step: "\(org.role): up to 5 serials from its list, looked up everywhere", passed: false, note: failure(error))
                        return error
                    }
                }
            }
            var errors: [any Error] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
        failed = appleErrors.first

        // --fault apple-write-attempt: one Unassign through the app's real
        // path, to show it is refused before anything is sent and fails the run.
        if run.fault == "apple-write-attempt", let org = orgs.first?.org, let live = models.first {
            try #require(live.model.underTest.appleWrites.isActive, "The Apple write guard is off: the fault isn't injected")
            let serial = "JTKTESTCPFAULT"
            let device = try JSONDecoder().decode(ABMDevice.self, from: Data(AppleFixtures.device(serial).utf8))
            var report = DeviceReport(serial: serial)
            report.abm = .found(ABMInfo(device: device, orgID: org.id, orgName: org.name, mdmServerID: "JTKTEST-FAULT",
                                        mdmServerName: nil, coverage: []))
            let message = await { () async -> String in
                do { try await live.model.setMDMServer(reports: [report], to: nil); return "sent" } catch { return error.localizedDescription }
            }()
            run.record(step: "apple-write-attempt", passed: false,
                       note: "an Unassign of a made-up serial through the app's real path, injected on purpose (--fault apple-write-attempt): \(message)")
        }

        // One serial from each read-only MDM tenant's own inventory, looked
        // up in that tenant only (no Apple organization: no Apple requests).
        let mdmModel = try LiveModel(mdm, session: run.network.session)
        for connection in mdm where connection.role != Roles.testA {
            let step = "\(connection.role): one serial from its inventory, found by the app's lookup"
            do {
                let picked = try await Inventory.firstSerial(connection, run)
                guard let serial = picked.serial else {
                    // Decided by Jordy: an empty inventory is reported, not failed.
                    run.record(step: "\(connection.role): nothing to look up", passed: true, note: picked.counts)
                    continue
                }
                let reports = await mdmModel.lookUp([serial], mdm: .connection(connection.id))
                let record = reports.first?.mdm.value
                let found = record?.connectionID == connection.id
                let state = reports.first.map { "\($0.mdm)" } ?? "no row"
                run.record(step: step, passed: found,
                           note: found ? "serial 1 found as a \(record?.kind == .computer ? "computer" : "mobile device")"
                                       : masked("serial 1: \(state)", serials: [serial]))
                #expect(found, "\(connection.role): the app's lookup didn't find the serial")
                if !found { failed = failed ?? LiveFailure("\(connection.role): lookup") }
            } catch {
                run.record(step: step, passed: false, note: failure(error))
                failed = failed ?? error
            }
        }
        checkUnderTest(run, when: "after the lookups")
        if let failed { throw failed }
    }

    /// One organization: its first serials, then the app's own lookup in
    /// Apple and every MDM tenant (the stale and misplaced findings). Counts
    /// only in the report; nothing is removed or changed.
    static func appleLookup(_ run: LiveCheckRun, org: LiveConnection, live: LiveModel) async throws {
        let step = "\(org.role): up to 5 serials from its list, looked up everywhere"
        let config = try #require(org.org)
        let client = try #require(live.model.makeABMClient(for: config), "\(org.role): incomplete organization")
        // One request; the serials stay in memory.
        let serials = try await client.client.firstDevices(limit: 5).map(\.serialNumber)
        guard !serials.isEmpty else {
            run.record(step: "\(org.role): nothing to look up", passed: true, note: "0 devices")
            return
        }
        let reports = await live.lookUp(serials, mdm: .allConnections, apple: config.id)
        let inApple = reports.filter { if case .found = $0.abm { true } else { false } }.count
        let withRecord = reports.filter { $0.mdm.value != nil }.count
        let failures = reports.filter {
            if case .failed = $0.abm { return true }
            if case .failed = $0.mdm { return true }
            return false
        }.count
        let stale = live.model.staleRecords(in: reports).count
        let passed = inApple == serials.count && failures == 0
        run.record(step: step, passed: passed,
                   note: "\(serials.count) serials (serial 1–\(serials.count)): \(inApple) found in Apple, \(withRecord) with an MDM record, "
                       + "\(failures) failed reads; findings: \(verdictCounts(reports)); \(stale) stale records counted, none removed")
        #expect(passed, "\(org.role): \(inApple) of \(serials.count) found in Apple, \(failures) failed reads")
    }

    /// On jamf-test-a: a JTKTEST computer and mobile device record, the app's
    /// lookups (alone and in the stale/misplaced view), and the app's own
    /// Delete Record on the iPad behind a fence.
    @Test func testRecords() async throws {
        let run = try LiveCheckRun.current()
        guard let testA = try LiveConnections.connection(run, role: Roles.testA) else { return }
        let role = testA.role
        let step = { (name: String) in "\(role): \(name)" }
        func attempt<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
            do {
                return try await body()
            } catch {
                run.record(step: step(name), passed: false, note: failure(error))
                throw error
            }
        }
        let devices = TestDevices(client: try Inventory.jamf(testA, run))

        // 1. The test records: made-up serials and UDIDs, unmanaged.
        let digits = run.prefix.filter(\.isNumber)
        let iPadSerial = "JTKTESTCP\(digits)"
        let macSerial = "JTKTESTCM\(digits)"
        let iPadName = "\(run.prefix) – iPad"
        let macName = "\(run.prefix) – Mac"
        let iPadID = try await attempt("create a test mobile device record") {
            try await devices.createMobile(name: iPadName, serial: iPadSerial, udid: "00000000-0000\(digits)0000")
        }
        run.record(step: step("create a test mobile device record"), passed: true,
                   note: "id \(iPadID), made-up serial \(iPadSerial), never enrolled (no model or OS), not managed")
        let macID = try await attempt("create a test computer record") {
            try await devices.createComputer(name: macName, serial: macSerial, udid: UUID().uuidString)
        }
        run.record(step: step("create a test computer record"), passed: true, note: "id \(macID), made-up serial \(macSerial), not managed")
        try run.injectFault("fail-live-step", at: step("after both test records were created"))

        // 2. The app's lookup on jamf-test-a alone: both found, with their names.
        // The same jamf-test-a copy (and ID) as above, so the scope names it.
        let mdm = try LiveConnections.mdm(run).map { $0.role == Roles.testA ? testA : $0 }
        // Jamf may list a new record in the Jamf Pro API's search a moment
        // after it's created: the lookup is repeated for up to a minute.
        let mdmModel = try LiveModel(mdm, session: run.network.session)
        let started = Date()
        var single: [DeviceReport] = []
        var iPad: ManagedDeviceInfo?
        var mac: ManagedDeviceInfo?
        var bothFound = false
        for attempt in 0..<20 {
            if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
            single = await mdmModel.lookUp([iPadSerial, macSerial], mdm: .connection(testA.id))
            iPad = single.first { $0.serial == iPadSerial }?.mdm.value
            mac = single.first { $0.serial == macSerial }?.mdm.value
            bothFound = iPad?.recordID == iPadID && iPad?.kind == .mobileDevice && mac?.recordID == macID && mac?.kind == .computer
            if bothFound { break }
        }
        if !bothFound {
            // Diagnostic: whether Jamf lists the record to a fresh question,
            // and whether its answers may be cached (header names and values only).
            let response = try? await devices.client.send(HTTPRequest(path: "pro/v2/mobile-devices/detail", query: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "filter", value: "serialNumber==\"\(iPadSerial)\""),
            ]), privilege: .readMobileDevices)
            let total = response.flatMap { try? LosslessJSON(data: $0.data)["totalCount"]?.numberValue?.intValue }
            let caching = (response?.headers ?? [:]).filter {
                ["cache-control", "expires", "age", "etag", "last-modified", "pragma", "vary"].contains($0.key.lowercased())
            }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            run.record(step: step("diagnostic: a fresh question to Jamf for the iPad"), passed: false,
                       note: "totalCount \(total.map(String.init) ?? "unreadable"); caching headers: \(caching.isEmpty ? "none" : caching)")
        }
        // The never-enrolled iPad's name comes from its own record (JTKit 0.12.4).
        run.record(step: step("the app shows the never-enrolled iPad's name"), passed: iPad?.name == iPadName,
                   note: "“\(iPad?.name ?? "none")”")
        run.record(step: step("the app's lookup finds both test records"), passed: bothFound,
                   note: "iPad “\(iPad?.name ?? "not found")”, Mac “\(mac?.name ?? "not found")”, "
                       + "listed by Jamf after \(Int(Date().timeIntervalSince(started))) s")
        #expect(bothFound)
        #expect(iPad?.name == iPadName)
        #expect(mac?.name == macName)

        // --fault command-attempt: one Erase on the test iPad through the
        // app's real path, confirmed as the app confirms it, to show it is
        // refused before anything is sent.
        if run.fault == "command-attempt", let report = single.first(where: { $0.serial == iPadSerial }) {
            try #require(mdmModel.model.underTest.commands.isActive, "The command guard is off: the fault isn't injected")
            let message = await { () async -> String in
                do {
                    let approval = try mdmModel.model.commandConfirmation(.wipeMobile, reports: [report])?.approve()
                    try await mdmModel.model.sendCommand(.wipeMobile, reports: [report], approval: approval)
                    return "sent"
                } catch { return error.localizedDescription }
            }()
            run.record(step: "command-attempt", passed: false,
                       note: "an Erase of the test iPad through the app's real path, injected on purpose (--fault command-attempt): \(message)")
        }

        // 3. The stale/misplaced view (All Connections): both on jamf-test-a
        //    only, no finding (made-up serials aren't in Apple), nothing
        //    offered for stale removal.
        let all = await mdmModel.lookUp([iPadSerial, macSerial], mdm: .allConnections)
        let onTestAOnly = all.allSatisfy { $0.mdm.value?.connectionID == testA.id && $0.otherRecords.isEmpty }
        let noFinding = all.allSatisfy { $0.mdmVerdict == nil }
        let staleOffered = mdmModel.model.staleRecords(in: all).count
        run.record(step: step("the stale/misplaced view (All Connections) shows both, no finding, nothing to remove"),
                   passed: onTestAOnly && noFinding && staleOffered == 0 && all.count == 2,
                   note: "\(mdm.count) connections read; findings: \(verdictCounts(all)); \(staleOffered) stale records offered")
        #expect(onTestAOnly && noFinding && staleOffered == 0)

        // 4. The app's own Delete Record on the iPad, behind the fence.
        let fence = DeleteFence(inner: run.network.session, mobileID: iPadID)
        let deleting = try LiveModel([testA], session: fence.session)
        let before = await deleting.lookUp([iPadSerial], mdm: .connection(testA.id))
        try #require(before.first?.mdm.value?.recordID == iPadID, "The app's lookup didn't find the test iPad before the delete")
        try await attempt("the app's Delete Record removes the test iPad") {
            try await deleting.model.deleteMDMRecord(reports: before, approval: deleting.model.deleteConfirmation(reports: before)?.approve())
        }
        let gone = try await !devices.exists(resource: TestDevices.mobiles, id: iPadID)
        let after = deleting.model.reports.first { $0.serial == iPadSerial }
        var notFound = false
        if case .notFound = after?.mdm { notFound = true }
        let macStays = try await devices.exists(resource: TestDevices.computers, id: macID)
        run.record(step: step("the app's Delete Record removes the test iPad"), passed: fence.deletes == 1 && gone && notFound && macStays,
                   note: "\(fence.deletes) delete sent; read back: \(gone ? "gone" : "still there"); the app's lookup: \(notFound ? "not found" : "\(after.map { "\($0.mdm)" } ?? "no row")"); the Mac \(macStays ? "untouched" : "missing")")
        #expect(fence.deletes == 1 && gone && notFound && macStays)
        run.record(step: step("the app sent nothing but reads, sign-in and this delete"), passed: fence.refusals.isEmpty,
                   note: fence.refusals.isEmpty ? nil : fence.refusals.joined(separator: "; "))
        #expect(fence.refusals.isEmpty, "\(fence.refusals)")
        checkUnderTest(run, when: "after the test records")

        // 5. The Mac (cleanup also runs on every exit).
        try await attempt("delete the test computer") {
            try await devices.delete(resource: TestDevices.computers, id: macID)
        }
        run.record(step: step("delete the test computer"), passed: true)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Cleanup, on every exit

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the ledger still lists, then sweeps jamf-test-a for any
    /// record still named as a test object. Fails if anything is left. Also
    /// the last under-tests check, after the unit and smoke tests, and the
    /// run's Apple requests and refusals.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        defer {
            checkUnderTest(run, when: "end of the run")
            let apple = run.appleRequestCounts
            let within = apple.values.allSatisfy { $0 <= 40 }
            run.record(step: "Apple requests per organization (at most 40)", passed: within,
                       note: apple.isEmpty ? "none" : apple.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            let refusals = run.runRefusals
            // Saved Apple organizations that aren't on the allow-list: never
            // in a live model, so never asked; a request would be refused
            // (deny by default) and show here, or as a saved-connection attempt.
            let allowed = Set(run.allowList.tenants.compactMap(\.clientID))
            let unlisted = LiveConnections.savedOrgs().filter { !allowed.contains($0.clientID) }.count
            let appleHosts = ["account.apple.com", "api-business.apple.com", "api-school.apple.com"]
            let appleRefused = refusals.filter { refusal in appleHosts.contains { refusal.location.hasPrefix($0) } }.count
            let appleAttempted = TestRun.AttemptLog.savedConnections.attempts().filter { attempt in appleHosts.contains { attempt.what.contains($0) } }.count
            run.record(step: "saved Apple organizations not on the allow-list received no request",
                       passed: appleRefused == 0 && appleAttempted == 0,
                       note: "\(unlisted) such organization\(unlisted == 1 ? "" : "s"); \(appleRefused) refused, \(appleAttempted) attempted")
            #expect(appleRefused == 0 && appleAttempted == 0)
            run.record(step: "no request refused by the live-check network", passed: refusals.isEmpty,
                       note: refusals.isEmpty ? nil : "\(refusals.count) refused")
            #expect(within)
            #expect(refusals.isEmpty, "\(refusals)")
        }
        guard let testA = try LiveConnections.connection(run, role: Roles.testA) else { return }
        let devices = TestDevices(client: try Inventory.jamf(testA, run))
        let target = try run.target(role: Roles.testA, service: .jamfPlatform)
        for record in try await devices.testRecords(run) {
            try run.adoptForSweep(role: Roles.testA, service: .jamfPlatform, resource: record.resource, id: record.id, name: record.name)
        }
        for item in run.ledger.outstanding where item.target == target {
            do {
                try await devices.delete(resource: item.resource, id: item.id)
            } catch {
                run.record(step: "cleanup: \(item.resource) \(item.id)", passed: false, note: failure(error))
            }
        }
        let left = run.ledger.outstanding
        let still = try await devices.testRecords(run)
        let clean = left.isEmpty && still.isEmpty
        run.record(step: "cleanup", passed: clean,
                   note: clean ? nil : "\(left.count) in the ledger and \(still.count) on the tenant not removed")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
        #expect(still.isEmpty, "\(still.map { "\($0.resource) \($0.id) \($0.name)" })")
    }
}
