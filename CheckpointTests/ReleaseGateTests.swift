import CryptoKit
import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// The findings engine and the fixes from the independent release-gate review:
// stale records only on evidence, one list for the finding and the cleanup,
// approvals for every removal, the lookup's own scope for the refresh,
// partial writes that refresh and say what was done.

/// A record for the findings tests: a connection, a last contact some days
/// ago (nil: never), how it enrolled and whether it's still managed.
@MainActor
private func record(_ id: String, on connection: UUID, daysAgo: Double?, ade: Bool? = nil,
                    managed: Bool? = true, byApple: Bool = false) -> ManagedDeviceInfo {
    var info = ManagedDeviceInfo(recordID: id, connectionID: connection, managedByApple: byApple, kind: .computer)
    info.lastContact = daysAgo.map { Date().addingTimeInterval(-$0 * 24 * 3600).ISO8601Format() }
    info.enrolledViaADE = ade
    info.isManaged = managed
    return info
}

/// A device in an Apple organization, assigned to `server` (nil: unassigned).
@MainActor
private func apple(server: String? = "S1", released: Bool = false, unknown: Bool = false) throws -> ABMInfo {
    var info = try #require(AppleHarness.device("TESTSERIAL01", server: server, released: released).abm.value)
    info.assignmentUnknown = unknown
    return info
}

private let connectionA = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000C00A")!
private let connectionB = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000C00B")!
private func name(_ id: UUID?) -> String {
    switch id {
    case connectionA: "Jamf A"
    case connectionB: "Jamf B"
    default: "another connection"
    }
}

@Suite("Findings: stale only on evidence")
@MainActor
struct FindingsEngineTests {

    @Test("Assigned to a service no connection covers: an old ADE record beside a recent manual one is not called stale")
    func oldADERecordIsNotLive() throws {
        // A enrolled via ADE two years ago, B manually and checks in daily.
        let a = record("1", on: connectionA, daysAgo: 730, ade: true)
        let b = record("2", on: connectionB, daysAgo: 1, ade: false)
        let resolved = LookupModel.resolve([a, b], abm: try apple(), expectedID: nil, name: name)
        #expect(resolved.primary.key == b.key, "the most recent record is the working one")
        #expect(resolved.others.map(\.key) == [a.key])
        guard case .unverified = resolved.verdict else {
            Issue.record("Expected unverified, got \(String(describing: resolved.verdict))")
            return
        }
    }

    @Test("Assigned elsewhere: a recent ADE record beside an older one names exactly the older one")
    func fallbackStaleNamesTheOthers() throws {
        let a = record("1", on: connectionA, daysAgo: 1, ade: true)
        let b = record("2", on: connectionB, daysAgo: 200, ade: false)
        let resolved = LookupModel.resolve([b, a], abm: try apple(), expectedID: nil, name: name)
        #expect(resolved.primary.key == a.key)
        #expect(resolved.verdict == .staleElsewhere(stale: ["Jamf B"]))
        #expect(resolved.others.map(\.key) == [b.key])
    }

    @Test("A record whose device is no longer managed there is stale, with or without a date")
    func unmanagedIsStale() throws {
        let a = record("1", on: connectionA, daysAgo: 1, ade: true)
        let b = record("2", on: connectionB, daysAgo: nil, managed: false)
        #expect(LookupModel.resolve([a, b], abm: try apple(), expectedID: nil, name: name).verdict
                == .staleElsewhere(stale: ["Jamf B"]))
        #expect(LookupModel.resolve([a, b], abm: try apple(), expectedID: connectionA, name: name).verdict
                == .staleElsewhere(stale: ["Jamf B"]))
    }

    @Test("On the assigned connection: older records elsewhere are stale; a newer managed one isn't; an undated one can't be settled")
    func expectedConnection() throws {
        let onA = record("1", on: connectionA, daysAgo: 2)
        let older = record("2", on: connectionB, daysAgo: 90)
        let newer = record("3", on: connectionB, daysAgo: 0.5)
        let undated = record("4", on: connectionB, daysAgo: nil)
        #expect(LookupModel.resolve([older, onA], abm: try apple(), expectedID: connectionA, name: name).verdict
                == .staleElsewhere(stale: ["Jamf B"]))
        #expect(LookupModel.resolve([newer, onA], abm: try apple(), expectedID: connectionA, name: name).verdict
                == .unverified("Records on Jamf A and elsewhere both look active"))
        let unsettled = LookupModel.resolve([undated, onA], abm: try apple(), expectedID: connectionA, name: name)
        #expect(unsettled.primary.key == onA.key)
        #expect(unsettled.verdict?.isFinding == false)
    }

    @Test("Two records on the assigned connection: the older one is what the finding names and the cleanup removes")
    func duplicateOnExpected() throws {
        let current = record("1", on: connectionA, daysAgo: 1)
        let duplicate = record("2", on: connectionA, daysAgo: 60)
        let resolved = LookupModel.resolve([duplicate, current], abm: try apple(), expectedID: connectionA, name: name)
        #expect(resolved.primary.key == current.key)
        #expect(resolved.verdict == .staleElsewhere(stale: ["Jamf A"]))
        var report = DeviceReport(serial: "TESTSERIAL01")
        report.mdm = .found(resolved.primary)
        report.otherRecords = resolved.others
        report.mdmVerdict = resolved.verdict
        let model = LookupModel(settings: Fixture().settings())
        #expect(model.staleRecords(in: [report]).map(\.info.key) == [duplicate.key])
    }

    @Test("No record on the assigned connection is a mismatch")
    func assignedElsewhere() throws {
        let b = record("2", on: connectionB, daysAgo: 1)
        #expect(LookupModel.resolve([b], abm: try apple(), expectedID: connectionA, name: name).verdict
                == .assignedElsewhere(expected: "Jamf A", actual: ["Jamf B"]))
    }

    @Test("Apple's assignment unread, unassigned, released, or outside Apple")
    func appleSide() throws {
        let a = record("1", on: connectionA, daysAgo: 1, ade: true)
        #expect(LookupModel.resolve([a], abm: try apple(unknown: true), expectedID: nil, name: name).verdict
                == .unverified("Apple’s assignment couldn’t be read"))
        #expect(LookupModel.resolve([a], abm: try apple(server: nil, unknown: true), expectedID: nil, name: name).verdict?.isFinding == false,
                "a failed server read is never unassigned")
        #expect(LookupModel.resolve([a], abm: try apple(server: nil), expectedID: nil, name: name).verdict == .unassignedWithRecords)
        #expect(LookupModel.resolve([a], abm: try apple(released: true), expectedID: nil, name: name).verdict == .unassignedWithRecords)
        #expect(LookupModel.resolve([a], abm: nil, expectedID: nil, name: name).verdict == nil)
    }

    @Test("One record: a live ADE one vouches for itself; any other can't be confirmed")
    func singleRecord() throws {
        #expect(LookupModel.resolve([record("1", on: connectionA, daysAgo: 1, ade: true)], abm: try apple(),
                                    expectedID: nil, name: name).verdict == .consistent)
        #expect(LookupModel.resolve([record("1", on: connectionA, daysAgo: 1, ade: false)], abm: try apple(),
                                    expectedID: nil, name: name).verdict?.isFinding == false)
    }

    @Test("A record in Apple's built-in management is never called stale")
    func appleManagedNeverStale() throws {
        let onA = record("1", on: connectionA, daysAgo: 1)
        let byApple = record("2", on: connectionB, daysAgo: nil, byApple: true)
        let verdict = LookupModel.resolve([onA, byApple], abm: try apple(), expectedID: connectionA, name: name).verdict
        #expect(verdict?.isFinding == false)
    }

    @Test("Jamf Pro's managed and supervised state reaches the record")
    func jamfProManagedState() async throws {
        let server = readServer { request in
            if request.path.hasSuffix("/computers-inventory") {
                return .json(200, #"{"totalCount":1,"results":[{"id":"7","general":{"name":"Test Mac","supervised":true,"remoteManagement":{"managed":false}},"hardware":{"serialNumber":"TESTSERIAL01"}}]}"#)
            }
            if request.path.hasSuffix("/mobile-devices/detail") {
                return .json(200, #"{"totalCount":1,"results":[{"mobileDeviceId":"12","deviceType":"iOS","general":{"displayName":"Test iPad","managed":true,"supervised":false},"hardware":{"serialNumber":"TESTSERIAL02"}}]}"#)
            }
            return nil
        }
        let connection = try #require(Fixture().settings().mdmConnections.first { $0.id == SavedData.proClientID })
        let jamf = try #require(JamfClient(config: connection, secret: { "SECRET-client" }, log: ActivityLog(), session: server.session))
        let mac = try #require(await jamf.computers(serials: ["TESTSERIAL01"]).records["TESTSERIAL01"])
        #expect(mac.isManaged == false)
        #expect(mac.isSupervised == true)
        let iPad = try #require(await jamf.mobileDevices(serials: ["TESTSERIAL02"]).records["TESTSERIAL02"])
        #expect(iPad.isManaged == true)
        #expect(iPad.isSupervised == false)
        #expect(MDMProduct.jamfPro.capabilities.contains(.managementState))
    }
}

@Suite("Connections read once per instance")
@MainActor
struct InstanceDedupTests {
    private func connection(_ id: String, method: MDMAuthMethod, url: String = "", region: JamfRegion = .eu,
                            environment: String = "") -> MDMConnection {
        var connection = MDMConnection(id: UUID(uuidString: "EEEEEEEE-0000-4000-8000-0000000\(id)")!)
        connection.product = .jamfPro
        connection.authMethod = method
        connection.baseURL = url
        connection.region = region
        connection.environmentID = environment
        return connection
    }

    @Test("Two Platform API connections without a web address stay two when their environments differ")
    func gatewaysWithoutWebAddress() {
        let one = connection("0D001", method: .platformGateway, environment: "ENV-ONE")
        let two = connection("0D002", method: .platformGateway, environment: "ENV-TWO")
        #expect(LookupModel.dedupedByInstance([one, two]).map(\.id) == [one.id, two.id])
        let same = connection("0D003", method: .platformGateway, environment: "env-one")
        #expect(LookupModel.dedupedByInstance([one, same]).map(\.id) == [one.id])
        let otherRegion = connection("0D004", method: .platformGateway, region: .us, environment: "ENV-ONE")
        #expect(LookupModel.dedupedByInstance([one, otherRegion]).count == 2)
    }

    @Test("A direct connection to the gateway's web address wins; entries with nothing to identify them never collapse")
    func directAndEmpty() {
        let gateway = connection("0D005", method: .platformGateway, url: "https://test.example.com", environment: "ENV-ONE")
        let direct = connection("0D006", method: .apiClient, url: "https://test.example.com/")
        #expect(LookupModel.dedupedByInstance([gateway, direct]).map(\.id) == [direct.id])
        let blank = connection("0D007", method: .platformGateway)
        let blankToo = connection("0D008", method: .platformGateway)
        #expect(LookupModel.dedupedByInstance([blank, blankToo]).count == 2)
    }
}

@Suite("Removals need their approval")
@MainActor
struct RemovalApprovalTests {
    @Test("Jamf Pro and Jamf School records aren't removed without the confirmation's approval, for exactly these records")
    func noApprovalNoRemoval() async throws {
        let harness = CommandHarness()
        let mac = Devices.mac()
        let other = Devices.mac("TESTSERIAL09", id: "9")
        let school = Devices.mobile(on: SavedData.schoolServerID)
        #expect(await message { try await harness.deleteRecords([mac], approved: false) }
                == "Delete Record needs a confirmation first. Nothing was removed.")
        #expect(await message { try await harness.deleteRecords([school], approved: false) }
                == "Move to Trash needs a confirmation first. Nothing was removed.")
        let forOne = try CommandHarness.approve(try #require(harness.model.deleteConfirmation(reports: [mac])))
        #expect(await message { try await harness.model.deleteMDMRecord(reports: [mac, other], approval: forOne) }
                == "The confirmation was for 1 record, not 2 records. Nothing was removed.")
        let wipe = try #require(harness.model.commandConfirmation(.unmanage, reports: [mac]))
        #expect(await message { try await harness.model.deleteMDMRecord(reports: [mac], approval: try CommandHarness.approve(wipe)) }
                == "The confirmation was for another action. Nothing was removed.")
        #expect(await message { try await harness.model.removeStaleRecords(reports: [Self.staleReport()], approval: nil) }
                == "Remove Stale Records needs a confirmation first. Nothing was removed.")
        #expect(!harness.server.requests.contains { $0.method == "DELETE" || $0.path.contains("trash") })

        try await harness.deleteRecords([mac])
        #expect(harness.server.requests.filter { $0.method == "DELETE" }.count == 1)
    }

    @Test("Remove Stale Records removes exactly the records the finding names")
    func staleCleanupMatchesFinding() async throws {
        let harness = CommandHarness()
        let report = Self.staleReport()
        let model = harness.model
        let approval = try CommandHarness.approve(model.staleRemovalConfirmation(reports: [report]))
        try await model.removeStaleRecords(reports: [report], approval: approval)
        let deletes = harness.server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.url.host() == "jamf.example.com")
        #expect(deletes.first?.path.hasSuffix("/computers-inventory/8") == true)
    }

    /// Working record on Example Jamf Pro, a stale one on Example Password Jamf Pro.
    static func staleReport() -> DeviceReport {
        var report = Devices.mac()
        report.otherRecords = [ManagedDeviceInfo(recordID: "8", connectionID: SavedData.proPasswordID, kind: .computer)]
        report.mdmVerdict = .staleElsewhere(stale: ["Example Password Jamf Pro"])
        return report
    }
}

@Suite("Partial writes refresh and say what was done")
@MainActor
struct PartialWriteTests {

    @Test("A failed Apple job still refreshes the rows")
    func appleFailureRefreshes() async throws {
        let harness = AppleHarness(AppleActivityTests.activityServer(status: "FAILED"))
        let report = try AppleHarness.device("A")
        harness.model.reports = [report]
        #expect(await message { try await harness.model.setMDMServer(reports: [report], to: "S1") } != nil)
        let posted = try #require(harness.server.requests.firstIndex { $0.path == "/v1/orgDeviceActivities" && $0.method == "POST" })
        #expect(harness.server.requests[posted...].contains { Self.readsDevice($0, "A") }, "the row was read again")
    }

    @Test("Unassign across two servers: when the second can't be submitted, the first is followed and both are reported")
    func partialUnassign() async throws {
        let server = appleServer { request in
            if request.path == "/v1/orgDeviceActivities", request.method == "POST" {
                return request.bodyString.contains("\"S2\"")
                    ? AppleFixtures.error(400, title: "Bad Request", detail: "Refused")
                    : .json(201, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"IN_PROGRESS"}}}"#)
            }
            if request.path == "/v1/orgDeviceActivities/ACT-1" {
                return .json(200, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"COMPLETED"}}}"#)
            }
            return nil
        }
        let harness = AppleHarness(server)
        let reports = try [AppleHarness.device("A", server: "S1"), AppleHarness.device("B", server: "S2")]
        harness.model.reports = reports
        let text = try #require(await message { try await harness.model.setMDMServer(reports: reports, to: nil) })
        #expect(text.hasPrefix("Unassigned 2 devices from their MDM server."))
        #expect(text.contains("1 of 2 devices weren’t sent"))
        #expect(harness.server.requests.contains { $0.path == "/v1/orgDeviceActivities/ACT-1" }, "the first was followed")
        #expect(harness.actions.last?.isFailure == true)
        #expect(harness.server.requests.contains { Self.readsDevice($0, "A") })
    }

    /// A read of the device: on its own, or with Apple's serial number filter.
    static func readsDevice(_ request: RecordedRequest, _ serial: String) -> Bool {
        request.path == "/v1/orgDevices/\(serial)"
            || (request.path == "/v1/orgDevices"
                && request.queryValue("filter[serialNumber]")?.split(separator: ",").contains(Substring(serial)) == true)
    }

    @Test("Schedule Migration's confirmation counts only what is sent")
    func migrationConfirmationMatchesWrite() throws {
        let harness = AppleHarness()
        let capable = try AppleHarness.device("A", extra: #","isMdmMigrationCapable":true"#)
        let released = try AppleHarness.device("B", released: true, extra: #","isMdmMigrationCapable":true"#)
        let write = AppleWrite.scheduleMigration(server: "S2", deadline: Date().addingTimeInterval(7 * 24 * 3600))
        #expect(harness.model.appleTargets(write, reports: [capable, released]).map(\.serial) == ["A"])
        #expect(harness.model.appleConfirmation(write, reports: [capable, released])?.deviceCount == 1)
    }

    @Test("A PreStage add that fails after the removal says so and refreshes")
    func prestageAddFails() async throws {
        let server = readServer { request in
            if request.path == "/api/v2/computer-prestages/1/scope", request.method == "GET" {
                return .json(200, #"{"versionLock":3,"assignments":[]}"#)
            }
            if request.path == "/api/v2/computer-prestages/2/scope", request.method == "GET" {
                return .json(200, #"{"versionLock":4,"assignments":[]}"#)
            }
            if request.path == "/api/v2/computer-prestages/1/scope/delete-multiple" { return .json(200, "{}") }
            if request.path == "/api/v2/computer-prestages/2/scope", request.method == "POST" {
                return .json(409, #"{"httpStatus":409,"errors":[{"code":"OPTIMISTIC_LOCK_FAILED","description":"Locked"}]}"#)
            }
            return nil
        }
        let harness = CommandHarness(server)
        harness.model.mdmScope = .connection(SavedData.proClientID)
        var mac = Devices.mac("TESTSERIAL01")
        mac.mdm = .found({ var info = mac.mdm.value!; info.prestageID = "1"; return info }())
        harness.model.reports = [mac]
        let text = try #require(await message { try await harness.model.setPrestage(reports: [mac], to: "2", kind: .computer) })
        #expect(text.hasPrefix("Removed 1 device from their PreStage but couldn’t add them to PreStage 2, so they’re in no PreStage now"))
        let added = try #require(server.requests.firstIndex { $0.method == "POST" && $0.path.hasSuffix("/2/scope") })
        #expect(server.requests[added...].contains { $0.path.hasSuffix("/computers-inventory") }, "the row was read again")
        #expect(harness.actions.last?.isFailure == true)
    }

    @Test("A Jamf School move that fails on its second batch says how many moved and refreshes")
    func locationBatchFails() async throws {
        let server = commandServer { request in
            if request.path.hasSuffix("/devices/migrate"), request.bodyString.contains("TESTUDID-21") {
                return .json(500, #"{"code":500,"message":"ServerError"}"#)
            }
            return nil
        }
        let harness = CommandHarness(server)
        let reports = (1...25).map { index in
            Devices.report(String(format: "TESTSERIAL%02d", index),
                           ManagedDeviceInfo(recordID: String(format: "TESTUDID-%02d", index),
                                             connectionID: SavedData.schoolServerID, kind: .mobileDevice))
        }
        harness.model.reports = reports
        let text = try #require(await message { try await harness.model.setLocation(reports: reports, to: "2") })
        #expect(text.hasPrefix("Moved 20 of 25 devices. Not sent: TESTSERIAL21, TESTSERIAL22, TESTSERIAL23, TESTSERIAL24, TESTSERIAL25"))
        #expect(harness.actions.last?.detail.hasPrefix("Moved 20 of 25 devices to") == true)
        #expect(server.requests.filter { $0.path.hasSuffix("/devices/migrate") }.count == 2)
    }

    @Test("A move counts and sends only the devices not there already")
    func movesSkipDevicesAlreadyThere() async throws {
        let server = readServer { request in request.method == "PATCH" ? .json(200, "{}") : nil }
        let harness = CommandHarness(server)
        var there = Devices.mac("TESTSERIAL01", id: "7")
        there.mdm = .found({ var info = there.mdm.value!; info.siteID = "5"; return info }())
        let moving = Devices.mac("TESTSERIAL02", id: "8")
        #expect(harness.model.siteMoves([there, moving], to: "5").map(\.serial) == ["TESTSERIAL02"])
        try await harness.model.setSite(reports: [there, moving], to: "5")
        #expect(server.requests.filter { $0.method == "PATCH" }.map(\.path) == ["/api/v4/computers-inventory-detail/8"])
    }

    @Test("A command that reached some devices says so beside the failures")
    func partialCommand() async throws {
        let server = commandServer { request in
            request.path.hasSuffix("/mdm/renew-profile")
                ? .json(200, #"{"udidsNotProcessed":{"udids":["TESTUDID-B"]}}"#) : nil
        }
        let harness = CommandHarness(server)
        let reports = [Devices.mac("TESTSERIAL01", id: "1", udid: "TESTUDID-A"), Devices.mac("TESTSERIAL02", id: "2", udid: "TESTUDID-B")]
        let text = try #require(await harness.send(.renewProfile, reports))
        #expect(text.hasPrefix("Sent to 1 of 2 devices."))
    }
}

@Suite("Scope, caches and secrets")
@MainActor
struct ScopeAndCacheTests {

    @Test("The refresh after an action reads what the lookup read, whatever the toolbar shows now")
    func refreshUsesLookupScope() async throws {
        let settings = Fixture().settings()
        let model = LookupModel(settings: settings, abmClock: ABMClock(now: { Date() }, sleep: { _ in }))
        settings.demo.isOn = true
        defer { settings.demo.isOn = false }
        model.abmScope = .allOrganizations
        model.mdmScope = .allConnections
        let device = try #require(DemoWorld.devices.first { $0.managedBy == .intune && $0.organization != nil })
        await model.lookUp(serialsText: device.serial)
        let intune = try #require(model.reports.first?.mdm.value?.connectionID)
        // The toolbar moves to Jamf Pro; the row's refresh still reads Intune.
        model.mdmScope = .connection(Connection.demoJamfPro.id)
        await model.refreshRows([device.serial])
        #expect(model.reports.first?.mdm.value?.connectionID == intune)
    }

    @Test("Forgetting a connection forgets what was read from it")
    func forgetClearsCaches() async throws {
        let settings = Fixture().settings()
        let model = LookupModel(settings: settings, abmClock: ABMClock(now: { Date() }, sleep: { _ in }))
        settings.demo.isOn = true
        defer { settings.demo.isOn = false }
        model.mdmScope = .connection(Connection.demoJamfPro.id)
        await model.lookUp(serialsText: try #require(DemoWorld.devices(managedBy: .jamfPro).first).serial)
        #expect(model.taxonomyByConnection[Connection.demoJamfPro.id] != nil)
        model.forgetClients(for: Connection.demoJamfPro.id)
        #expect(model.taxonomyByConnection[Connection.demoJamfPro.id] == nil)
    }

    @Test("A kept client doesn't read the Keychain again")
    func clientBeforeKeychain() throws {
        let fixture = Fixture()
        let store = CountingStore(["abm.\(SavedData.businessID.uuidString)": P256.Signing.PrivateKey().pemRepresentation,
                                   "jamf.\(SavedData.proClientID.uuidString)": "SECRET"])
        let model = LookupModel(settings: AppSettings(defaults: fixture.defaults, secrets: store))
        let org = try #require(model.abmOrgs.first { $0.id == SavedData.businessID })
        let pro = try #require(model.mdmConnections.first { $0.id == SavedData.proClientID })
        #expect(model.makeABMClient(for: org) != nil)
        #expect(model.makeJamfClient(for: pro) != nil)
        let reads = store.reads
        for _ in 0..<3 {
            _ = model.makeABMClient(for: org)
            _ = model.makeJamfClient(for: pro)
        }
        #expect(store.reads == reads)
    }

    @Test("Blueprint names that couldn't be read are asked for again")
    func blueprintFailureNotKept() async throws {
        let answers = Answers()
        let server = readServer { request in
            guard request.path.hasSuffix("/blueprints/v1/blueprints") else { return nil }
            return answers.next() == 0 ? .json(403, "{}") : .json(200, #"{"results":[{"id":"b-1","name":"Wi-Fi"}]}"#)
        }
        let harness = CommandHarness(server)
        let report = Devices.mac(on: SavedData.platformID)
        #expect(await harness.model.blueprintName(for: "b-1", report: report) == nil)
        #expect(await harness.model.blueprintName(for: "b-1", report: report) == "Wi-Fi")
    }

    @Test("The Blueprint link opens the record's own connection, never the toolbar's")
    func blueprintLink() {
        let harness = CommandHarness()
        harness.model.mdmScope = .connection(SavedData.proClientID)
        let report = Devices.mac(on: SavedData.proPasswordID)
        #expect(harness.model.blueprintURL("b-1", for: report)?.absoluteString == "https://jamf.example.com/view/mfe/blueprints/b-1")
    }

    @Test("The Keychain wrapper forwards every call, and reports writes")
    func reportingStoreForwards() throws {
        let base = CountingStore(["jamf.x": "S"])
        var changed: [String] = []
        let edits = ConnectionEdits()
        edits.onChange = { id, _ in changed.append(id.uuidString) }
        let store = ReportingSecretStore(base: base, edits: edits)
        #expect(try store.hasSecret(for: "jamf.x"))
        #expect(try store.readSecret(for: "jamf.x") == "S")
        let id = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000F001")!
        try store.writeSecret("T", for: "jamf.\(id.uuidString)")
        #expect(base.calls == ["has", "read", "write"])
        #expect(changed == [id.uuidString])
        #expect(base.reads == 0, "presence and the throwing read go to the base store's own calls")
    }

    @Test("Serials from text and from a file")
    func parsing() {
        #expect(LookupModel.parseSerials(" testserial01, TESTSERIAL02;testserial01\nTESTSERIAL03\t") == ["TESTSERIAL01", "TESTSERIAL02", "TESTSERIAL03"])
        let csv = """
        Serial,Name
        "TESTSERIAL01",Mac one
        testserial02;iPad
        short1
        NODIGITSHERE
        TESTSERIAL01
        """
        #expect(LookupModel.parseImportedList(csv) == ["TESTSERIAL01", "TESTSERIAL02", "SHORT1"])
    }
}

/// Counts reads and records which of the throwing calls were made.
private final class CountingStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private var readCount = 0
    private var log: [String] = []
    init(_ secrets: [String: String]) { self.secrets = secrets }
    var reads: Int { lock.withLock { readCount } }
    var calls: [String] { lock.withLock { log } }
    func secret(for account: String) -> String? {
        lock.withLock { readCount += 1; return secrets[account] }
    }
    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock { secrets[account] = secret }
        return true
    }
    func writeSecret(_ secret: String?, for account: String) throws {
        lock.withLock { log.append("write"); secrets[account] = secret }
    }
    func hasSecret(for account: String) throws -> Bool {
        lock.withLock { log.append("has"); return secrets[account] != nil }
    }
    func readSecret(for account: String) throws -> String? {
        lock.withLock { log.append("read"); return secrets[account] }
    }
}

/// Numbers the answers a fake server gives, from 0.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

@Suite("2.10: Apple's serial filter and a renamed organization")
@MainActor
struct AppleFilterTests {

    /// A fake Apple that answers the serial filter with the devices it holds.
    static func filterServer(holding held: Set<String>) -> MockServer {
        appleServer { request in
            switch request.path {
            case "/v1/mdmServers":
                return .json(200, #"{"data":[]}"#)
            case "/v1/orgDevices":
                guard let filter = request.queryValue("filter[serialNumber]") else { return nil }
                let items = filter.split(separator: ",").map(String.init).filter(held.contains)
                    .map { #"{"type":"orgDevices","id":"\#($0)","attributes":\#(AppleFixtures.device($0))}"# }
                return .json(200, #"{"data":[\#(items.joined(separator: ","))]}"#)
            default:
                if request.path.hasSuffix("/relationships/assignedServer") { return .json(200, #"{"data":null}"#) }
                return nil
            }
        }
    }

    @Test("A small lookup asks Apple for its devices together, with the serial filter")
    func filteredLookup() async throws {
        let server = Self.filterServer(holding: ["AAA111"])
        let harness = AppleHarness(server)
        harness.model.abmScope = .organization(SavedData.businessID)
        await harness.model.lookUp(serialsText: "AAA111 BBB222")
        let filtered = server.requests.filter { $0.path == "/v1/orgDevices" }
        #expect(filtered.count == 1)
        #expect(filtered.first?.queryValue("filter[serialNumber]") == "AAA111,BBB222")
        #expect(!server.requests.contains { $0.path == "/v1/orgDevices/AAA111" }, "a device the filter returned isn't read again")
        #expect(harness.model.reports.first { $0.serial == "AAA111" }?.abm.value != nil)
        guard case .notFound? = harness.model.reports.first(where: { $0.serial == "BBB222" })?.abm else {
            Issue.record("a serial Apple doesn't hold is not in the organization")
            return
        }
    }

    @Test("Renaming an organization keeps what was read from it; another edit doesn't")
    func renameKeepsSnapshot() throws {
        let harness = AppleHarness()
        let settings = harness.model.settings
        harness.model.abmScope = .organization(SavedData.businessID)
        harness.model.abmSnapshots[SavedData.businessID] = ABMSnapshot(devices: [:], serverIDBySerial: [:], servers: [],
                                                                        capturedAt: harness.time.now)

        var record = try #require(settings.connections.record(id: SavedData.businessID))
        record.connection.name = "Renamed Organization"
        try settings.connections.save(record)
        #expect(harness.model.abmSnapshots[SavedData.businessID] != nil, "a rename keeps the snapshot")

        record.connection.keyID = "OTHERKEY1"
        try settings.connections.save(record)
        #expect(harness.model.abmSnapshots[SavedData.businessID] == nil, "a new key ID reads the organization again")
    }
}

@Suite("2.10: review fixes")
@MainActor
struct ReviewFixTests {
    @Test("A refresh after an Apple write on 20 devices reads only those devices, never the whole organization")
    func refreshReadsOnlyTheAffectedDevices() async throws {
        let serials = (1...20).map { String(format: "TESTREF%03d", $0) }
        let server = appleServer { request in
            if request.path == "/v1/orgDeviceActivities", request.method == "POST" {
                return .json(201, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"IN_PROGRESS"}}}"#)
            }
            if request.path == "/v1/orgDeviceActivities/ACT-1" {
                return .json(200, #"{"data":{"type":"orgDeviceActivities","id":"ACT-1","attributes":{"status":"COMPLETED"}}}"#)
            }
            if request.path == "/v1/mdmServers" { return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}}]}"#) }
            if request.path == "/v1/orgDevices", let filter = request.queryValue("filter[serialNumber]") {
                let items = filter.split(separator: ",").map { #"{"type":"orgDevices","id":"\#($0)","attributes":\#(AppleFixtures.device(String($0)))}"# }
                return .json(200, #"{"data":[\#(items.joined(separator: ","))]}"#)
            }
            if request.path.hasSuffix("/relationships/assignedServer") { return .json(200, #"{"data":{"type":"mdmServers","id":"S1"}}"#) }
            return nil
        }
        let harness = AppleHarness(server)
        harness.model.abmScope = .organization(SavedData.businessID)
        let reports = try serials.map { try AppleHarness.device($0) }
        harness.model.reports = reports
        try await harness.model.setMDMServer(reports: reports, to: "S1")
        let posted = try #require(server.requests.firstIndex { $0.path == "/v1/orgDeviceActivities" && $0.method == "POST" })
        let after = server.requests[posted...]
        #expect(!after.contains { $0.path == "/v1/orgDevices" && $0.queryValue("filter[serialNumber]") == nil },
                "the organization isn't read in full")
        #expect(!after.contains { $0.path.contains("/relationships/devices") }, "no server's device list either")
        #expect(after.filter { $0.path == "/v1/orgDevices" }.count == 1, "20 devices in one filtered request")
        #expect(!after.contains { $0.path.contains("appleCareCoverage") }, "coverage is left for the inspector")
        #expect(harness.model.reports.allSatisfy { $0.abm.value?.mdmServerID == "S1" })
    }

    @Test("Jamf School's check-in time is read from its first 19 characters, in the instance's zone")
    func schoolCheckIn() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")
        #expect(DateFormatting.isoFromInstanceLocal("2026-10-20 08:12:33", timeZone: tokyo) == "2026-10-19T23:12:33Z")
        #expect(DateFormatting.isoFromInstanceLocal("2026-10-20 08:12:33.000000", timeZone: tokyo) == "2026-10-19T23:12:33Z")
        #expect(DateFormatting.isoFromInstanceLocal("2026-10-20T08:12:33+09:00", timeZone: tokyo) == "2026-10-19T23:12:33Z")
        #expect(DateFormatting.isoFromInstanceLocal("", timeZone: tokyo) == nil)
    }

    @Test("The status bar: an action's start clears the last message; a failure shows there too")
    func statusBar() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/refresh") ? .json(500, #"{"code":500,"message":"Server error"}"#) : nil
        })
        harness.model.report("Update Inventory: sent to TESTIPAD001 in Jamf School.")
        harness.model.clearStatus()
        #expect(harness.model.statusMessage == nil)
        harness.model.report("Refused.", failed: true)
        #expect(harness.model.statusMessage?.failed == true)
        #expect(harness.model.statusMessage?.text == "Refused.")
        // the same text twice is still a change, so it is said again
        let first = harness.model.statusMessage
        harness.model.report("Refused.", failed: true)
        #expect(harness.model.statusMessage != first)
    }

    @Test("A Jamf Pro address's path stays in record and Blueprint links")
    func linksKeepThePath() {
        let server = MDMConnection(name: "On-premises", baseURL: "https://jss.example.com:8443/jamf/")
        #expect(JamfWebLink.computer(id: "7", base: server.normalizedBaseURL)?.absoluteString
                == "https://jss.example.com:8443/jamf/computers.html?id=7&o=r")
        #expect(JamfWebLink.blueprint(id: "b-1", base: server.normalizedBaseURL)?.absoluteString
                == "https://jss.example.com:8443/jamf/view/mfe/blueprints/b-1")
    }
}
