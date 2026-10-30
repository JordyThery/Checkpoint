import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// How Checkpoint's remaining Jamf Pro calls behave (ROADMAP step 7, JTKit
// 0.8.2), written against Checkpoint's own code before they move to JTKit:
// PreStages and their scope, ADE, compliance, DDM status, declarations, the
// four secrets, sites, departments and buildings, and site moves. Each runs
// straight to Jamf Pro and through the Platform API.

/// A fake Jamf Pro that answers by path; nil from `answer` is a 404.
nonisolated func readServer(_ answer: @escaping @Sendable (RecordedRequest) -> MockResponse?) -> MockServer {
    MockServer { request in
        let path = request.path
        if path.hasSuffix("/oauth/token") || path.hasSuffix("/auth/token") {
            return .json(200, #"{"access_token":"t","expires_in":1200,"token":"t"}"#)
        }
        return answer(request) ?? .json(404, #"{"httpStatus":404,"errors":[{"code":"NOT_FOUND"}]}"#)
    }
}

/// Requests other than sign-ins.
nonisolated func calls(_ server: MockServer) -> [RecordedRequest] {
    server.requests.filter { !$0.path.hasSuffix("/token") }
}

/// Where a request went: straight to Jamf Pro or through the Platform API.
nonisolated enum Via: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case direct, platform

    var method: MDMAuthMethod { self == .direct ? .apiClient : .platformGateway }
    var connectionID: UUID { self == .direct ? SavedData.proClientID : SavedData.platformID }
    func api(_ path: String) -> String { self == .direct ? "/api/" + path : "/pro/" + path }
    var testDescription: String { rawValue }
}

@MainActor
private func client(_ server: MockServer, _ via: Via, log: ActivityLog? = nil) throws -> JamfClient {
    try #require(JamfClient(config: proConnection(via.method), secret: { "SECRET-client" }, log: log ?? ActivityLog(), session: server.session))
}

// MARK: - PreStages

@Suite("PreStages and their scope")
@MainActor
struct PrestageTests {

    @Test("The list is read 100 at a time, sorted by ID, until every PreStage is read", arguments: Via.allCases)
    func list(via: Via) async throws {
        let server = readServer { request in
            guard request.path.hasSuffix("/v3/computer-prestages") else { return nil }
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let ids = page == 0 ? Array(1...100) : Array(101...150)
            let items = ids.map { #"{"id":"\#($0)","displayName":"PreStage \#($0)","deviceEnrollmentProgramInstanceId":"ade-1"}"# }
            return .json(200, #"{"totalCount":150,"results":[\#(items.joined(separator: ","))]}"#)
        }
        let prestages = try await client(server, via).prestages(family: .computer)
        #expect(prestages.count == 150)
        #expect(prestages.first == JamfPrestage(id: "1", displayName: "PreStage 1", enrollmentInstanceID: "ade-1"))
        let requests = calls(server)
        #expect(requests.map(\.path) == [via.api("v3/computer-prestages"), via.api("v3/computer-prestages")])
        #expect(requests.map { $0.queryValue("page") } == ["0", "1"])
        #expect(requests.allSatisfy { $0.queryValue("page-size") == "100" && $0.queryValue("sort") == "id:asc" })
    }

    @Test("The scope map: serial → PreStage", arguments: Via.allCases)
    func scope(via: Via) async throws {
        let server = readServer { request in
            request.path.hasSuffix("/v2/mobile-device-prestages/scope")
                ? .json(200, #"{"serialsByPrestageId":{"DMPXK1JHJG5H":"5"}}"#) : nil
        }
        #expect(try await client(server, via).prestageAssignments(family: .mobileDevice) == ["DMPXK1JHJG5H": "5"])
        #expect(calls(server).only?.path == via.api("v2/mobile-device-prestages/scope"))
    }

    @Test("Adding reads the scope's version first; removing uses delete-multiple", arguments: Via.allCases)
    func change(via: Via) async throws {
        let server = readServer { request in
            guard request.path.contains("/v2/computer-prestages/5/scope") else { return nil }
            return request.method == "GET" ? .json(200, #"{"versionLock":3,"assignments":[]}"#) : .json(200, "{}")
        }
        let jamf = try client(server, via)
        try await jamf.addToPrestage(family: .computer, prestageID: "5", serials: ["C02XK1JHJG5H"])
        try await jamf.removeFromPrestage(family: .computer, prestageID: "5", serials: ["C02XK1JHJG5H"])
        let requests = calls(server)
        #expect(requests.map(\.method) == ["GET", "POST", "GET", "POST"])
        #expect(requests.map(\.path) == [via.api("v2/computer-prestages/5/scope"), via.api("v2/computer-prestages/5/scope"),
                                         via.api("v2/computer-prestages/5/scope"), via.api("v2/computer-prestages/5/scope/delete-multiple")])
        #expect(body(requests[1]) == dictionary(#"{"serialNumbers":["C02XK1JHJG5H"],"versionLock":3}"#))
        #expect(body(requests[3]) == dictionary(#"{"serialNumbers":["C02XK1JHJG5H"],"versionLock":3}"#))
    }

    @Test("Change PreStage removes from the old one before adding to the new one, and is one Action entry")
    func changePrestage() async throws {
        let harness = CommandHarness(readServer { request in
            guard request.path.contains("-prestages/") else { return nil }
            return request.method == "GET" ? .json(200, #"{"versionLock":1}"#) : .json(200, "{}")
        })
        var info = ManagedDeviceInfo(recordID: "7", connectionID: SavedData.proClientID, kind: .computer)
        info.prestageID = "1"
        try await harness.model.setPrestage(reports: [Devices.report("C02XK1JHJG5H", info)], to: "2", kind: .computer)
        let writes = harness.sent.filter { $0.method == "POST" }.map(\.path)
        #expect(writes == ["/api/v2/computer-prestages/1/scope/delete-multiple", "/api/v2/computer-prestages/2/scope"])
        let action = try #require(harness.actions.only)
        #expect(action.service == "Jamf Pro" && action.connection == "Example Jamf Pro")
    }
}

// MARK: - ADE

@Suite("Automated Device Enrollment")
@MainActor
struct ADETests {

    @Test("The tokens' Apple server IDs, page by page", arguments: Via.allCases)
    func serverIDs(via: Via) async throws {
        let server = readServer { request in
            guard request.path.hasSuffix("/v1/device-enrollments") else { return nil }
            return request.queryValue("page") == "0"
                ? .json(200, #"{"totalCount":2,"results":[{"id":"1","serverUuid":"AAA"}]}"#)
                : .json(200, #"{"totalCount":2,"results":[{"id":"2","serverUuid":""}]}"#)
        }
        #expect(try await client(server, via).adeServerUUIDs() == ["AAA"])
        #expect(calls(server).map { $0.queryValue("page") } == ["0", "1"])
        #expect(calls(server).allSatisfy { $0.queryValue("page-size") == "100" })
    }

    @Test("Each token's devices, 500 at a time, as serial → token", arguments: Via.allCases)
    func devices(via: Via) async throws {
        let server = readServer { request in
            if request.path.hasSuffix("/v1/device-enrollments") {
                return .json(200, #"{"totalCount":1,"results":[{"id":"9"}]}"#)
            }
            if request.path.hasSuffix("/v1/device-enrollments/9/devices") {
                return .json(200, #"{"totalCount":2,"results":[{"serialNumber":"c02xk1jhjg5h"},{"serialNumber":"DMPXK1JHJG5H"}]}"#)
            }
            return nil
        }
        #expect(try await client(server, via).adeInstanceBySerial() == ["C02XK1JHJG5H": "9", "DMPXK1JHJG5H": "9"])
        #expect(calls(server).last?.queryValue("page-size") == "500")
    }
}

// MARK: - Compliance

@Suite("Device compliance")
@MainActor
struct ComplianceTests {

    @Test("The feature switch, then each device's compliance; the answer is recorded", arguments: Via.allCases)
    func compliance(via: Via) async throws {
        let server = readServer { request in
            if request.path.hasSuffix("/device-compliance/feature-toggle") { return .json(200, #"{"sharedDeviceFeatureEnabled":true}"#) }
            if request.path.hasSuffix("/device-compliance-information/computer/7") {
                return .json(200, #"[{"applicable":false},{"applicable":true,"complianceState":"NON_COMPLIANT","complianceVendor":"Intune"}]"#)
            }
            if request.path.hasSuffix("/device-compliance-information/mobile/12") {
                return .json(200, #"{"applicable":true,"complianceState":"COMPLIANT"}"#)
            }
            return nil
        }
        let log = ActivityLog()
        let jamf = try client(server, via, log: log)
        #expect(try await jamf.deviceComplianceEnabled())
        let mac = try #require(try await jamf.deviceCompliance(kind: .computer, deviceID: "7"))
        #expect(mac.applicable && mac.state == "NON_COMPLIANT" && mac.vendor == "Intune")
        #expect(try await jamf.deviceCompliance(kind: .mobileDevice, deviceID: "12")?.state == "COMPLIANT")
        #expect(calls(server).map(\.path) == [via.api("v1/conditional-access/device-compliance/feature-toggle"),
                                              via.api("v1/conditional-access/device-compliance-information/computer/7"),
                                              via.api("v1/conditional-access/device-compliance-information/mobile/12")])
        #expect(log.entries.filter { $0.request?.responseBody?.contains("COMPLIANT") == true }.count == 2)
    }
}

// MARK: - DDM

@Suite("DDM status and declarations")
@MainActor
struct DDMTests {

    nonisolated private static let statusItems = #"""
    {"statusItems":[
     {"key":"softwareupdate.install-state","value":"downloading","lastUpdateTime":"2026-10-20T08:00:00.000"},
     {"key":"softwareupdate.pending-version.os-version","value":"26.1","lastUpdateTime":"2026-10-20T08:00:00.000"},
     {"key":"softwareupdate.pending-version.target-local-date-time","value":"2026-10-31 22:00:00 +0000","lastUpdateTime":"2026-10-19T08:00:00.000"},
     {"key":"softwareupdate.pending-version.softwareupdate.target-local-date-time","value":"leftover"},
     {"key":"management.declarations.configurations","value":"{active=true, identifier=Blueprint_0F2C1B0A-1111-2222-3333-444455556666_s1_c1_sys_cfg1, valid=invalid, reasons=[{code=Error.ConfigurationCannotBeApplied, description=Cannot apply, details={Error=[kSUCoreErrorDDMInvalidDeclarationFailure] Invalid declaration: target OS version (15.7.3) is older than current version (15.7.9)}}]},{active=true, identifier=custom.one, valid=valid}"}]}
    """#

    @Test("The status report: software update, declarations, and a deadline older than the offer dropped", arguments: Via.allCases)
    func status(via: Via) async throws {
        let server = readServer { request in
            request.path.hasSuffix("/v1/ddm/M-7/status-items") ? .json(200, Self.statusItems) : nil
        }
        let log = ActivityLog()
        let status = try #require(try await client(server, via, log: log).ddmStatus(managementID: "M-7"))
        #expect(calls(server).only?.path == via.api("v1/ddm/M-7/status-items"))
        let update = try #require(status.softwareUpdate)
        #expect(update.installState == "downloading")
        #expect(update.offeredOSVersion == "26.1")
        #expect(update.deadline == nil)
        #expect(status.declarations.map(\.identifier) == ["Blueprint_0F2C1B0A-1111-2222-3333-444455556666_s1_c1_sys_cfg1", "custom.one"])
        #expect(status.declarations[0].validity == .invalid)
        #expect(status.declarations[0].reasons == ["[kSUCoreErrorDDMInvalidDeclarationFailure] Invalid declaration: target OS version (15.7.3) is older than current version (15.7.9)"])
        #expect(status.declarations[0].blueprintID == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(log.entries.contains { $0.request?.responseBody?.contains("downloading") == true })
    }

    @Test("A current deadline is kept")
    func deadline() async throws {
        let server = readServer { _ in
            .json(200, #"{"statusItems":[{"key":"softwareupdate.pending-version.os-version","value":"26.1","lastUpdateTime":"2026-10-20T08:00:00.000"},{"key":"softwareupdate.pending-version.target-local-date-time","value":"2026-10-31 22:00:00 +0000","lastUpdateTime":"2026-10-20T09:00:00.000"}]}"#)
        }
        let status = try await client(server, .direct).ddmStatus(managementID: "M-7")
        #expect(status?.softwareUpdate?.deadline == DateFormatting.parseStatusItemDate("2026-10-31 22:00:00 +0000"))
    }

    @Test("No status: refused, unknown or empty", arguments: [403, 404, 200])
    func none(status: Int) async throws {
        let server = readServer { _ in .json(status, status == 200 ? #"{"statusItems":[]}"# : "{}") }
        #expect(try await client(server, .direct).ddmStatus(managementID: "M-7") == nil)
    }

    @Test("Only a software update enforcement counts; a failure means none; never recorded", arguments: Via.allCases)
    func enforcement(via: Via) async throws {
        let server = readServer { request in
            if request.path.hasSuffix("/v1/dss-declarations/enforce") {
                return .json(200, #"{"declarations":[{"type":"com.apple.configuration.softwareupdate.enforcement.specific","uuid":"u-1","payloadJson":"{\"TargetOSVersion\":\"26.1\",\"TargetBuildVersion\":\"25B78\",\"TargetLocalDateTime\":\"2026-11-01T09:00:00\"}"}]}"#)
            }
            if request.path.hasSuffix("/v1/dss-declarations/other") {
                return .json(200, #"{"declarations":[{"type":"com.apple.management.status-subscriptions","payloadJson":"{}"}]}"#)
            }
            return .json(403, "{}")
        }
        let log = ActivityLog()
        let jamf = try client(server, via, log: log)
        let declarations = ["broken", "other", "enforce"].map {
            JamfDeclaration(identifier: $0, active: true, validity: .valid, reasons: [])
        }
        let found = try #require(await jamf.updateEnforcement(among: declarations))
        #expect(found.declarationID == "u-1" && found.targetOSVersion == "26.1" && found.targetBuildVersion == "25B78")
        #expect(calls(server).map(\.path).contains(via.api("v1/dss-declarations/enforce")))
        #expect(!log.entries.contains { $0.request?.responseBody?.contains("TargetOSVersion") == true })
    }
}

// MARK: - Sites, departments, buildings

@Suite("Sites, departments and buildings")
@MainActor
struct SiteTests {

    @Test("Sites, in either shape", arguments: [#"[{"id":"1","name":"Main"}]"#, #"{"totalCount":1,"results":[{"id":"1","name":"Main"}]}"#])
    func sites(answer: String) async throws {
        let server = readServer { $0.path.hasSuffix("/v1/sites") ? .json(200, answer) : nil }
        #expect(try await client(server, .direct).sites() == [JamfSite(id: "1", name: "Main")])
    }

    @Test("Moving a site: a Mac's general.siteId, a mobile device's siteId", arguments: Via.allCases)
    func moves(via: Via) async throws {
        let server = readServer { $0.method == "PATCH" ? .json(200, "{}") : nil }
        let jamf = try client(server, via)
        try await jamf.setComputerSite(computerID: "7", siteID: "3")
        try await jamf.setMobileDeviceSite(deviceID: "12", siteID: "-1")
        let requests = calls(server)
        #expect(requests.map(\.path) == [via.api("v4/computers-inventory-detail/7"), via.api("v2/mobile-devices/12")])
        #expect(body(requests[0]) == dictionary(#"{"general":{"siteId":"3"}}"#))
        #expect(body(requests[1]) == dictionary(#"{"siteId":"-1"}"#))
    }

    @Test("Move to site names the devices that failed and is one Action entry")
    func setSite() async throws {
        let harness = CommandHarness(readServer { request in
            guard request.method == "PATCH" else { return nil }
            return request.path.hasSuffix("/mobile-devices/12") ? .json(403, "{}") : .json(200, "{}")
        })
        do {
            try await harness.model.setSite(reports: [Devices.mac(), Devices.mobile()], to: "3")
            Issue.record("moved")
        } catch {
            #expect(error.localizedDescription.hasPrefix("DMPXK1JHJG5H: "))
        }
        let action = try #require(harness.actions.only)
        #expect(action.detail == "Moved 1 of 2 devices to 3")
        #expect(action.isFailure)
    }

    @Test("Departments and buildings: 1,000 at a time until all are read", arguments: ["departments", "buildings"])
    func names(list: String) async throws {
        let server = readServer { request in
            guard request.path.hasSuffix("/v1/\(list)") else { return nil }
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let items = (0..<(page == 0 ? 1000 : 5)).map { #"{"id":"\#(page * 1000 + $0)","name":"N\#(page * 1000 + $0)"}"# }
            return .json(200, #"{"totalCount":1005,"results":[\#(items.joined(separator: ","))]}"#)
        }
        let jamf = try client(server, .direct)
        let map = list == "departments" ? try await jamf.departmentNames() : try await jamf.buildingNames()
        #expect(map.count == 1005)
        #expect(map["1004"] == "N1004")
        #expect(calls(server).map { $0.queryValue("page-size") } == ["1000", "1000"])
    }

    @Test("A refused list means no names")
    func refusedNames() async throws {
        let server = readServer { _ in .json(403, "{}") }
        #expect(try await client(server, .direct).departmentNames().isEmpty)
    }

    @Test("Blueprint names, through the Platform API; none when they can't be read")
    func blueprintNames() async throws {
        let server = readServer { request in
            request.path.hasSuffix("/blueprints/v1/blueprints")
                ? .json(200, #"{"results":[{"id":"b-1","name":"Wi-Fi"},{"id":"b-2","name":""}]}"#) : nil
        }
        #expect(try await client(server, .platform).blueprintNames() == ["b-1": "Wi-Fi"])
        let refused = readServer { _ in .json(403, "{}") }
        #expect(try await client(refused, .platform).blueprintNames().isEmpty)
    }
}

// MARK: - The four secrets

/// The secrets, each with its address and answer.
nonisolated enum Secret: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case fileVault, recoveryLock, lockPIN, localAdmin

    var value: String { "SECRET-\(rawValue)-VALUE" }
    var path: String {
        switch self {
        case .fileVault: "v4/computers-inventory/7/filevault"
        case .recoveryLock: "v4/computers-inventory/7/view-recovery-lock-password"
        case .lockPIN: "v4/computers-inventory/7/view-device-lock-pin"
        case .localAdmin: "v2/local-admin-password/M-7/account/admin/guid-1/password"
        }
    }
    var answer: String {
        let extra = #""password":"SECRET-extra","pin":"SECRET-extra-pin","personalRecoveryKey":"SECRET-extra-key""#
        return switch self {
        case .fileVault: #"{"personalRecoveryKey":"\#(value)","individualRecoveryKeyValidityStatus":"VALID","password":"SECRET-extra"}"#
        case .recoveryLock: #"{"recoveryLockPassword":"\#(value)",\#(extra)}"#
        case .lockPIN: #"{"pin":"\#(value)","password":"SECRET-extra"}"#
        case .localAdmin: #"{"password":"\#(value)","pin":"SECRET-extra-pin"}"#
        }
    }
    var actionText: String {
        switch self {
        case .fileVault: "Read the FileVault recovery key for C02XK1JHJG5H"
        case .recoveryLock: "Read the Recovery Lock password for C02XK1JHJG5H"
        case .lockPIN: "Read the device lock PIN for C02XK1JHJG5H"
        case .localAdmin: "Read the local administrator password for admin on C02XK1JHJG5H, queuing a rotation"
        }
    }
    var testDescription: String { rawValue }

    @MainActor
    func read(_ model: LookupModel, _ report: DeviceReport) async throws -> String {
        switch self {
        case .fileVault: try await model.fileVaultRecoveryKey(for: report).personalRecoveryKey
        case .recoveryLock: try await model.recoveryLockPassword(for: report)
        case .lockPIN: try await model.deviceLockPIN(for: report)
        case .localAdmin:
            try await model.localAdminPassword(for: report, account: JamfLocalAdminAccount(username: "admin", guid: "guid-1", source: "MDM"))
        }
    }
}

@Suite("The four secrets")
@MainActor
struct SecretTests {

    nonisolated private static let pairs = Secret.allCases.flatMap { secret in Via.allCases.map { (secret, $0) } }

    @Test("Each secret is read from its address", arguments: pairs)
    func read(secret: Secret, via: Via) async throws {
        let harness = CommandHarness(readServer { $0.path.hasSuffix(secret.path) ? .json(200, secret.answer) : nil })
        #expect(try await secret.read(harness.model, Devices.mac(on: via.connectionID)) == secret.value)
        #expect(harness.sent.only?.path == via.api(secret.path))
    }

    @Test("The secret never reaches the activity log or the bug-report export; the Action entry names only the device",
          arguments: pairs)
    func neverRecorded(secret: Secret, via: Via) async throws {
        let harness = CommandHarness(readServer { $0.path.hasSuffix(secret.path) ? .json(200, secret.answer) : nil })
        _ = try await secret.read(harness.model, Devices.mac(on: via.connectionID))
        let unmasked = ActivityLogExport.text(harness.log.entries, masked: false)
        let masked = ActivityLogExport.text(harness.log.entries, masked: true)
        #expect(!unmasked.contains("SECRET-") && !masked.contains("SECRET-"))
        #expect(harness.log.entries.first { $0.detail.contains(secret.path) }?.request?.contentsWithheld == true)
        let action = try #require(harness.actions.only)
        #expect(action.detail == secret.actionText)
        #expect(!masked.contains("C02XK1JHJG5H"))
    }

    @Test("Nor when the read fails and the server's answer repeats the secret", arguments: pairs)
    func failure(secret: Secret, via: Via) async throws {
        let harness = CommandHarness(readServer { request in
            guard request.path.hasSuffix(secret.path) else { return nil }
            // a refusal, so no retries: reads are retried after a server error
            return .json(403, #"{"httpStatus":403,"errors":[{"code":"ERROR","description":"Could not return \#(secret.value)"}]}"#)
        })
        await #expect(throws: (any Error).self) { _ = try await secret.read(harness.model, Devices.mac(on: via.connectionID)) }
        let unmasked = ActivityLogExport.text(harness.log.entries, masked: false)
        #expect(!unmasked.contains("SECRET-"), "\(unmasked)")
        #expect(harness.actions.only?.isFailure == true)
    }

    @Test("Nothing escrowed is said plainly", arguments: Secret.allCases)
    func none(secret: Secret) async throws {
        let harness = CommandHarness(readServer { _ in nil })
        do {
            _ = try await secret.read(harness.model, Devices.mac())
            Issue.record("read")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Jamf Pro holds no "))
        }
    }

    @Test("LAPS: the accounts, the address without a GUID, and NOT_FOUND under HTTP 400")
    func localAdmin() async throws {
        let harness = CommandHarness(readServer { request in
            if request.path.hasSuffix("/v2/local-admin-password/M-7/accounts") {
                return .json(200, #"{"results":[{"username":"admin","guid":"guid-1","userSource":"MDM"},{"username":"","guid":"x"}]}"#)
            }
            if request.path.hasSuffix("/account/jamf/password") {
                return .json(400, #"{"httpStatus":400,"errors":[{"code":"NOT_FOUND","description":"none"}]}"#)
            }
            if request.path.hasSuffix("/v2/local-admin-password/settings") { return .json(200, #"{"passwordRotationTime":3600}"#) }
            return nil
        })
        let report = Devices.mac()
        let accounts = await harness.model.localAdminAccounts(for: report)
        #expect(accounts == [JamfLocalAdminAccount(username: "admin", guid: "guid-1", source: "MDM")])
        do {
            _ = try await harness.model.localAdminPassword(for: report, account: JamfLocalAdminAccount(username: "jamf", guid: "", source: "JMF"))
            Issue.record("read")
        } catch {
            #expect(error.localizedDescription == "Jamf Pro holds no password for jamf on C02XK1JHJG5H.")
        }
        #expect(harness.sent.map(\.path).contains("/api/v2/local-admin-password/M-7/account/jamf/password"))
        // read once per server
        #expect(await harness.model.localAdminRotationTime(for: report) == 3600)
        #expect(await harness.model.localAdminRotationTime(for: report) == 3600)
        #expect(harness.sent.filter { $0.path.hasSuffix("/settings") }.count == 1)
    }

    @Test("Without the LAPS privilege, no accounts are shown")
    func refusedAccounts() async throws {
        let harness = CommandHarness(readServer { _ in .json(403, "{}") })
        #expect(await harness.model.localAdminAccounts(for: Devices.mac()).isEmpty)
    }
}

@Suite("Showing a secret")
@MainActor
struct RevealTests {

    @Test("Only the LAPS password asks first, naming the account and when it rotates")
    func lapsAsksFirst() throws {
        let question = try #require(LookupModel.revealConfirmation(.localAdminPassword, account: "admin", rotationTime: 3600))
        #expect(question.title == "Rotation after viewing")
        #expect(question.message == "Viewing the password for admin will cause Jamf Pro to rotate it in 1 hour.")
        for secret in [JamfPro.Secret.fileVaultRecoveryKey, .recoveryLockPassword, .deviceLockPIN] {
            #expect(LookupModel.revealConfirmation(secret, account: nil, rotationTime: 3600) == nil)
        }
        #expect(LookupModel.rotationPhrase(nil) == "shortly afterwards")
    }

    @Test("A secret's Action entry names the connection the record is on", arguments: Via.allCases)
    func connection(via: Via) async throws {
        let secret = Secret.fileVault
        let harness = CommandHarness(readServer { $0.path.hasSuffix(secret.path) ? .json(200, secret.answer) : nil })
        _ = try await secret.read(harness.model, Devices.mac(on: via.connectionID))
        let expected = harness.model.settings.mdmConnections.first { $0.id == via.connectionID }?.displayName
        #expect(harness.actions.only?.connection == expected)
    }
}
