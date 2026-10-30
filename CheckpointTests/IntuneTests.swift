import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// How Checkpoint's Intune code behaves (ROADMAP step 8, JTKit 0.9.1),
// written against Checkpoint's own `IntuneClient` before it moved to JTKit:
// reading the tenant page by page, matching serials, retries, the sign-in,
// the confirmations, and how a Graph device becomes a `ManagedDeviceInfo`.
// Everything runs through `LookupModel`, so the tests outlive the client.

// MARK: - Fixtures

/// Graph devices as the tenant lists them.
nonisolated enum GraphDevices {
    static let mac = #"{"id":"i-mac","serialNumber":"C02XK1JHJG5H","deviceName":"Lab Mac","operatingSystem":"macOS","osVersion":"15.1","enrolledDateTime":"2026-01-02T03:04:05Z","lastSyncDateTime":"2026-10-25T08:00:00Z","managementCertificateExpirationDate":"2027-01-02T03:04:05Z","isEncrypted":true,"isSupervised":true,"managementAgent":"mdm","complianceState":"noncompliant","deviceEnrollmentType":"appleBulkWithUser"}"#
    static let iPhone = #"{"id":"i-phone","serialNumber":"DMPXK1JHJG5H","deviceName":"Cart iPhone","operatingSystem":"iOS","osVersion":"18.1","isEncrypted":true,"isSupervised":false,"managementAgent":"mdm","complianceState":"compliant","deviceEnrollmentType":"userEnrollment"}"#
    static let android = #"{"id":"i-android","serialNumber":"R58N123ABC","deviceName":"Pixel","operatingSystem":"Android","osVersion":"","isEncrypted":false,"managementAgent":"","complianceState":"inGracePeriod"}"#

    static func page(_ items: [String], next: String? = nil) -> String {
        let link = next.map { #","@odata.nextLink":"\#($0)""# } ?? ""
        return #"{"value":[\#(items.joined(separator: ","))]\#(link)}"#
    }
}

/// A fake Entra sign-in and Graph. `answer` handles every Graph request; nil
/// is an empty list.
nonisolated func intuneServer(_ answer: @escaping @Sendable (RecordedRequest) throws -> MockResponse? = { _ in nil }) -> MockServer {
    MockServer { request in
        if request.path.hasSuffix("/oauth2/v2.0/token") {
            return .json(200, #"{"access_token":"SECRET-graph-token","expires_in":3600}"#)
        }
        if let answer = try answer(request) { return answer }
        if request.method == "GET" { return .json(200, GraphDevices.page([])) }
        return MockResponse(status: 204, body: Data())
    }
}

/// Checkpoint looking at the saved Intune tenant only.
@MainActor
struct IntuneHarness {
    let server: MockServer
    let model: LookupModel
    let log = ActivityLog()

    init(_ server: MockServer = intuneServer()) {
        self.server = server
        let fixture = Fixture()
        fixture.secrets.setSecret("SECRET-entra", for: "jamf.\(SavedData.intuneID.uuidString)")
        model = LookupModel(settings: fixture.settings(), log: log, session: server.session, underTest: .off)
        model.mdmScope = .connection(SavedData.intuneID)
    }

    var signIns: [RecordedRequest] { server.requests.filter { $0.path.hasSuffix("/oauth2/v2.0/token") } }
    var graph: [RecordedRequest] { server.requests.filter { !$0.path.hasSuffix("/oauth2/v2.0/token") } }
    var deviceReads: [RecordedRequest] { graph.filter { $0.method == "GET" } }

    /// The row's MDM state after looking `serial` up.
    func lookUp(_ serial: String) async -> FetchState<ManagedDeviceInfo>? {
        await model.lookUp(serialsText: serial)
        return model.reports.first { $0.serial == serial }?.mdm
    }

    func device(_ serial: String = "DMPXK1JHJG5H", id: String = "i-1", kind: DeviceKind = .mobileDevice) -> DeviceReport {
        Devices.report(serial, ManagedDeviceInfo(recordID: id, connectionID: SavedData.intuneID, kind: kind))
    }

    @discardableResult
    func send(_ command: MDMCommand, _ reports: [DeviceReport]) async -> String? {
        do {
            try await model.sendCommand(command, reports: reports)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension FetchState {
    var isNotFound: Bool { if case .notFound = self { true } else { false } }
    var failure: String? { if case .failed(let message) = self { message } else { nil } }
}

// MARK: - Reading the tenant

@Suite("Intune: reading the tenant")
@MainActor
struct IntunePagingTests {

    @Test("The first page asks for Checkpoint's 13 fields, 1,000 at a time")
    func firstPage() async throws {
        let harness = IntuneHarness()
        _ = await harness.lookUp("C02XK1JHJG5H")
        let read = try #require(harness.deviceReads.only)
        #expect(read.url.host() == "graph.microsoft.com")
        #expect(read.path == "/v1.0/deviceManagement/managedDevices")
        #expect(read.queryValue("$select") == "id,serialNumber,deviceName,operatingSystem,osVersion,enrolledDateTime,lastSyncDateTime,managementCertificateExpirationDate,isEncrypted,isSupervised,managementAgent,complianceState,deviceEnrollmentType")
        #expect(read.queryValue("$top") == "1000")
        #expect(read.header("Authorization") == "Bearer SECRET-graph-token")
        #expect(read.header("Accept") == "application/json")
    }

    @Test("Next pages are followed as Graph gives them, and every page counts")
    func pages() async throws {
        let harness = IntuneHarness(intuneServer { request in
            switch request.queryValue("$skiptoken") {
            case nil: .json(200, GraphDevices.page([GraphDevices.android],
                                                   next: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=two"))
            case "two": .json(200, GraphDevices.page([GraphDevices.iPhone],
                                                     next: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=three"))
            default: .json(200, GraphDevices.page([GraphDevices.mac]))
            }
        })
        #expect(await harness.lookUp("C02XK1JHJG5H")?.value?.recordID == "i-mac")
        #expect(harness.deviceReads.map { $0.queryValue("$skiptoken") } == [nil, "two", "three"])
        // the link is sent as given: no fields or page size added
        #expect(harness.deviceReads[1].queryValue("$select") == nil)
    }

    @Test("Serials match in any case; the first record wins; devices without a serial are left out")
    func matching() async throws {
        let harness = IntuneHarness(intuneServer { _ in
            .json(200, GraphDevices.page([
                #"{"id":"no-serial","serialNumber":""}"#, #"{"id":"null-serial"}"#,
                #"{"id":"first","serialNumber":"c02xk1jhjg5h","operatingSystem":"macOS"}"#,
                #"{"id":"second","serialNumber":"C02XK1JHJG5H","operatingSystem":"macOS"}"#,
            ]))
        })
        #expect(await harness.lookUp("C02XK1JHJG5H")?.value?.recordID == "first")
        #expect(await harness.lookUp("ABSENT00000")?.isNotFound == true)
    }

    @Test("A next page on another host is refused before the token goes there")
    func nextPageElsewhere() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.url.host() == "graph.microsoft.com"
                ? .json(200, GraphDevices.page([GraphDevices.mac], next: "https://evil.example.com/v1.0/deviceManagement/managedDevices?$skiptoken=x"))
                : .json(200, GraphDevices.page([]))
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        // changed on purpose: before JTKit the link was followed, token and all
        #expect(!harness.server.requests.contains { $0.url.host() == "evil.example.com" })
        #expect(state?.failure?.contains("evil.example.com") == true)
    }

    @Test("A tenant that never stops paging is an error after 1,000 pages, not a quiet cut-off")
    func pageLimit() async throws {
        let harness = IntuneHarness(intuneServer { request in
            let page = Int(request.queryValue("$skiptoken") ?? "0") ?? 0
            return .json(200, GraphDevices.page(page == 0 ? [GraphDevices.mac] : [],
                                                next: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=\(page + 1)"))
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        // changed on purpose: before JTKit it stopped after 101 pages without a word
        #expect(harness.deviceReads.count == 1_000)
        #expect(state?.failure?.contains("1000 pages") == true)
    }

    @Test("A failed tenant read shows as an error on the row, not as “not found”")
    func failedRead() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "GET" ? .json(403, #"{"error":{"code":"Forbidden","message":"Application is not authorized to perform this operation."}}"#) : nil
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        // changed on purpose: before JTKit the error was swallowed, so the device read as not found
        #expect(state?.isNotFound == false)
        #expect(state?.failure?.contains("HTTP 403") == true)
        #expect(state?.failure?.contains("DeviceManagementManagedDevices.Read.All") == true)
    }

    @Test("Each request is in the activity log under Intune, the answer of the device read included")
    func recorded() async throws {
        let harness = IntuneHarness(intuneServer { _ in .json(200, GraphDevices.page([GraphDevices.mac])) })
        _ = await harness.lookUp("C02XK1JHJG5H")
        let requests = harness.log.entries.filter { $0.request != nil }
        #expect(requests.map(\.category) == ["Sign-in", "Intune"]) // was "API"
        #expect(requests.allSatisfy { $0.service == "Intune" && $0.connection == "Example Intune" })
        #expect(requests.last?.request?.responseBody?.contains("Lab Mac") == true)
        let all = ActivityLogExport.text(harness.log.entries, masked: false)
        #expect(!all.contains("SECRET-"))
    }
}

// MARK: - Retries

@Suite("Intune: retries")
@MainActor
struct IntuneRetryTests {

    @Test("A 429 waits as Graph asks and tries again, with a warning in the log")
    func throttled() async throws {
        let calls = Counter()
        let harness = IntuneHarness(intuneServer { request in
            guard request.method == "GET" else { return nil }
            return calls.next() == 1
                ? .json(429, "{}", headers: ["Retry-After": "0"])
                : .json(200, GraphDevices.page([GraphDevices.mac]))
        })
        #expect(await harness.lookUp("C02XK1JHJG5H")?.value?.recordID == "i-mac")
        #expect(harness.deviceReads.count == 2)
        #expect(harness.log.entries.contains { $0.category == "Retry" && $0.isWarning })
    }

    @Test("After four 429s it gives up")
    func throttledFourTimes() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "GET" ? .json(429, "{}", headers: ["Retry-After": "0"]) : nil
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        #expect(harness.deviceReads.count == 4)
        #expect(state?.failure?.contains("HTTP 429") == true) // was "not found"
    }

    @Test("A server error on the device read is tried again: reading twice does no harm")
    func serverErrorOnRead() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "GET" ? .json(503, "{}", headers: ["Retry-After": "0"]) : nil
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        // changed on purpose: before JTKit a read wasn't tried again
        #expect(harness.deviceReads.count == 4)
        #expect(state?.failure?.contains("HTTP 503") == true)
    }

    @Test("A 401 signs in again once, then gives up")
    func unauthorized() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "GET" ? .json(401, #"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}"#) : nil
        })
        let state = await harness.lookUp("C02XK1JHJG5H")
        // changed on purpose: before JTKit a 401 wasn't tried again
        #expect(harness.deviceReads.count == 2)
        #expect(harness.signIns.count == 2)
        #expect(state?.failure?.contains("HTTP 401") == true)
    }

    @Test("A command isn't sent again after a server error")
    func serverErrorOnCommand() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "POST" ? .json(500, #"{"error":{"code":"InternalServerError","message":"Oops."}}"#, headers: ["Retry-After": "0"]) : nil
        })
        let message = await harness.send(.wipeMobile, [harness.device()])
        #expect(harness.graph.filter { $0.method == "POST" }.count == 1)
        #expect(message?.contains("HTTP 500") == true)
    }

    @Test("A command is sent again after a 429: nothing was done")
    func throttledCommand() async throws {
        let calls = Counter()
        let harness = IntuneHarness(intuneServer { request in
            guard request.method == "POST" else { return nil }
            return calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "0"]) : MockResponse(status: 204, body: Data())
        })
        #expect(await harness.send(.restartMobile, [harness.device()]) == nil)
        #expect(harness.graph.filter { $0.method == "POST" }.count == 2)
    }

    @Test("A network drop during a command isn't sent again")
    func droppedCommand() async throws {
        let harness = IntuneHarness(intuneServer { request in
            if request.method == "POST" { throw URLError(.networkConnectionLost) }
            return nil
        })
        #expect(await harness.send(.lockMobile, [harness.device()]) != nil)
        #expect(harness.graph.filter { $0.method == "POST" }.count == 1)
    }
}

// MARK: - Signing in

@Suite("Intune: signing in")
@MainActor
struct IntuneSignInTests {

    @Test("The app registration signs in with its client secret for Graph's .default scope")
    func form() async throws {
        let harness = IntuneHarness()
        _ = await harness.lookUp("C02XK1JHJG5H")
        let signIn = try #require(harness.signIns.only)
        #expect(signIn.method == "POST")
        #expect(signIn.url.host() == "login.microsoftonline.com")
        #expect(signIn.path == "/contoso.onmicrosoft.com/oauth2/v2.0/token")
        #expect(signIn.header("Content-Type") == "application/x-www-form-urlencoded")
        let form = Dictionary(uniqueKeysWithValues: signIn.bodyString.split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
            return (pair[0], pair[1].removingPercentEncoding ?? pair[1])
        })
        #expect(form == ["client_id": "6F1B2C3D-0000-1111-2222-333344445555", "client_secret": "SECRET-entra",
                         "grant_type": "client_credentials", "scope": "https://graph.microsoft.com/.default"])
    }

    @Test("One sign-in serves the lookup and the commands after it, also when they run at once")
    func shared() async throws {
        let harness = IntuneHarness()
        _ = await harness.lookUp("C02XK1JHJG5H")
        async let first = harness.send(.updateInventory, [harness.device()])
        async let second = harness.send(.restartMobile, [harness.device("DMPAAAAAAAAA", id: "i-2")])
        _ = await (first, second)
        #expect(harness.signIns.count == 1)
    }

    @Test("A refused sign-in says what Microsoft says, with a hint")
    func refused() async throws {
        let harness = IntuneHarness(MockServer { request in
            request.path.hasSuffix("/oauth2/v2.0/token")
                ? .json(401, #"{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided. Ensure the secret being sent in the request is the client secret value, not the client secret ID.\r\nTrace ID: 0000-trace\r\nCorrelation ID: 1111-corr","error_codes":[7000215],"trace_id":"0000-trace","correlation_id":"1111-corr"}"#)
                : .json(500, "{}")
        })
        let message = try #require(await harness.send(.updateInventory, [harness.device()]))
        #expect(message.contains("AADSTS7000215") || message.contains("7000215"))
        #expect(message.contains("The client secret is wrong.")) // JTKit's hint
        #expect(!message.contains("SECRET-"))
    }
}

// MARK: - Commands

@Suite("Intune: commands and their permissions")
@MainActor
struct IntuneCommandSendTests {

    @Test("Commands go to the managed device's Graph action, one request per device",
          arguments: [(MDMCommand.updateInventory, "syncDevice"), (.restartMobile, "rebootNow"),
                      (.shutDownMobile, "shutDown"), (.lockMobile, "remoteLock"),
                      (.clearPasscode, "resetPasscode"), (.unmanage, "retire")])
    func actions(command: MDMCommand, action: String) async throws {
        let harness = IntuneHarness()
        #expect(await harness.send(command, [harness.device(), harness.device("DMPAAAAAAAAA", id: "i-2")]) == nil)
        #expect(harness.graph.map(\.path) == ["/v1.0/deviceManagement/managedDevices/i-1/\(action)",
                                              "/v1.0/deviceManagement/managedDevices/i-2/\(action)"])
        #expect(harness.graph.allSatisfy { $0.method == "POST" })
    }

    @Test("A Mac is wiped with an empty JSON body and no PIN")
    func wipeMac() async throws {
        let harness = IntuneHarness()
        #expect(await harness.send(.wipeComputer, [harness.device("C02XK1JHJG5H", kind: .computer)]) == nil)
        let request = try #require(harness.graph.only)
        #expect(request.path == "/v1.0/deviceManagement/managedDevices/i-1/wipe")
        #expect(request.bodyString == "{}")
    }

    @Test("A refused command names the application permission it needs")
    func commandForbidden() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "POST" ? .json(403, #"{"error":{"code":"Forbidden","message":"Application is not authorized to perform this operation."}}"#) : nil
        })
        let message = try #require(await harness.send(.restartMobile, [harness.device()]))
        #expect(message.contains("HTTP 403"))
        #expect(message.contains("“DeviceManagementManagedDevices.PrivilegedOperations.All”"))
        #expect(!message.contains("ReadWrite"))
    }

    @Test("A refused Delete Record names ReadWrite.All")
    func deleteForbidden() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "DELETE" ? .json(403, #"{"error":{"code":"Forbidden","message":"Application is not authorized to perform this operation."}}"#) : nil
        })
        var message: String?
        do { try await harness.model.deleteMDMRecord(reports: [harness.device()]) } catch { message = error.localizedDescription }
        #expect(message?.contains("“DeviceManagementManagedDevices.ReadWrite.All”") == true)
        #expect(message?.contains("PrivilegedOperations") == false)
    }

    @Test("Delete Record deletes the managed device; a failure is reported per device")
    func delete() async throws {
        let harness = IntuneHarness(intuneServer { request in
            request.method == "DELETE" && request.path.hasSuffix("/i-2") ? .json(404, #"{"error":{"code":"ResourceNotFound","message":"Not found."}}"#) : nil
        })
        var message: String?
        do {
            try await harness.model.deleteMDMRecord(reports: [harness.device(), harness.device("DMPAAAAAAAAA", id: "i-2")])
        } catch { message = error.localizedDescription }
        #expect(harness.graph.filter { $0.method == "DELETE" }.map(\.path)
                == ["/v1.0/deviceManagement/managedDevices/i-1", "/v1.0/deviceManagement/managedDevices/i-2"])
        #expect(message?.hasPrefix("DMPAAAAAAAAA: ") == true)
    }

    @Test("Sending is one Action entry under Intune with the connection")
    func actionEntry() async throws {
        let harness = IntuneHarness()
        await harness.send(.updateInventory, [harness.device()])
        let action = try #require(harness.log.entries.filter { $0.category == "Action" }.only)
        #expect(action.service == "Intune" && action.connection == "Example Intune")
        #expect(action.detail == "Sent Sync Device to 1 device") // was "Update Inventory"
    }
}

// MARK: - Confirmations

@Suite("Intune: confirmations")
@MainActor
struct IntuneConfirmationTests {

    @Test("Wipe and Retire name the connection for one device; nothing is typed",
          arguments: [MDMCommand.wipeMobile, .unmanage])
    func irreversibleOne(command: MDMCommand) throws {
        let harness = IntuneHarness()
        let confirmation = try #require(harness.model.commandConfirmation(command, reports: [harness.device()]))
        #expect(confirmation.connectionLine == "On “Example Intune”.")
        #expect(confirmation.typedCount == nil)
        #expect(!confirmation.asksPINTwice)
        #expect(confirmation.isDestructive)
    }

    @Test("Wipe and Retire ask for the number from two devices", arguments: [MDMCommand.wipeMobile, .unmanage])
    func irreversibleTwo(command: MDMCommand) throws {
        let harness = IntuneHarness()
        let confirmation = try #require(harness.model.commandConfirmation(
            command, reports: [harness.device(), harness.device("DMPAAAAAAAAA", id: "i-2")]))
        #expect(confirmation.connectionLine == "On “Example Intune”.")
        #expect(confirmation.typedCount == 2)
        #expect(confirmation.problem(typedCount: "1") == "Type 2 to confirm.")
        #expect(confirmation.problem(typedCount: "2") == nil)
    }

    @Test("Wiping a Mac on Intune asks for no PIN")
    func wipeMacNoPIN() throws {
        let harness = IntuneHarness()
        let confirmation = try #require(harness.model.commandConfirmation(
            .wipeComputer, reports: [harness.device("C02XK1JHJG5H", kind: .computer)]))
        #expect(!confirmation.asksPINTwice)
        #expect(confirmation.connectionLine == "On “Example Intune”.")
    }

    @Test("Delete Record names the connection, and asks for the number from two records")
    func deleteRecord() throws {
        let harness = IntuneHarness()
        let one = try #require(harness.model.deleteConfirmation(reports: [harness.device()]))
        #expect(one.title == "Delete Record — DMPXK1JHJG5H")
        #expect(one.connectionLine == "On “Example Intune”.")
        #expect(one.typedCount == nil)
        #expect(one.message == "The record will be deleted from Intune. The device itself stays enrolled and will reappear at its next check-in; Retire Device is what unmanages it.")
        let two = try #require(harness.model.deleteConfirmation(reports: [harness.device(), harness.device("DMPAAAAAAAAA", id: "i-2")]))
        #expect(two.typedCount == 2)
    }

    @Test("Sync, Restart, Shut Down, Lock and Clear Passcode are plain dialogs, even for two devices",
          arguments: [MDMCommand.updateInventory, .restartMobile, .shutDownMobile, .lockMobile, .clearPasscode])
    func plain(command: MDMCommand) throws {
        let harness = IntuneHarness()
        let confirmation = try #require(harness.model.commandConfirmation(
            command, reports: [harness.device(), harness.device("DMPAAAAAAAAA", id: "i-2")]))
        #expect(confirmation.connectionLine == nil)
        #expect(confirmation.typedCount == nil)
        #expect(!confirmation.needsTyping)
    }

    @Test("Intune's own titles and texts")
    func texts() throws {
        let harness = IntuneHarness()
        let expected: [(MDMCommand, DeviceKind, String, String)] = [
            (.updateInventory, .mobileDevice, "Sync Device — DMPXK1JHJG5H",
             "Intune asks the device to check in now, so it picks up pending policies and actions and reports its state."),
            (.restartMobile, .mobileDevice, "Restart Device — DMPXK1JHJG5H", "The device will restart immediately."),
            (.shutDownMobile, .mobileDevice, "Shut Down Device — DMPXK1JHJG5H",
             "The device will shut down immediately and stay off until someone powers it back on."),
            (.lockMobile, .mobileDevice, "Lock Device — DMPXK1JHJG5H", "The device will lock immediately; the owner's passcode unlocks it."),
            (.clearPasscode, .mobileDevice, "Clear Passcode — DMPXK1JHJG5H",
             "Intune removes the device passcode. If a policy requires one, the user is asked to set a new one."),
            (.wipeMobile, .mobileDevice, "Wipe Device — DMPXK1JHJG5H",
             "All data on the device will be erased and it returns to factory settings. This cannot be undone."),
            (.wipeComputer, .computer, "Wipe Computer — DMPXK1JHJG5H",
             "All data on the Mac will be erased and it returns to factory settings. This cannot be undone."),
            (.unmanage, .mobileDevice, "Retire Device — DMPXK1JHJG5H",
             "The device is retired: company data and the management profile are removed, so Intune can no longer manage it. Unlike the Jamf products, the record goes too once the device acknowledges."),
        ]
        for (command, kind, title, message) in expected {
            let confirmation = try #require(harness.model.commandConfirmation(command, reports: [harness.device(kind: kind)]))
            #expect(confirmation.title == title)
            #expect(confirmation.message == message)
        }
    }

    @Test("Lock skips a Mac and says so before anything is sent")
    func skipsMac() throws {
        let harness = IntuneHarness()
        let confirmation = try #require(harness.model.commandConfirmation(
            .lockMobile, reports: [harness.device(), harness.device("C02XK1JHJG5H", id: "i-mac", kind: .computer)]))
        #expect(confirmation.title == "Lock Device — DMPXK1JHJG5H")
        #expect(confirmation.explanation == "2 selected, 1 will receive the command; 1 is a Mac.")
    }
}

// MARK: - Conversion

@Suite("Intune: a Graph device as Checkpoint shows it")
@MainActor
struct IntuneConversionTests {

    private func found(_ device: String, serial: String) async throws -> ManagedDeviceInfo {
        let harness = IntuneHarness(intuneServer { _ in .json(200, GraphDevices.page([device])) })
        return try #require(await harness.lookUp(serial)?.value)
    }

    @Test("A Mac: FileVault from the encryption flag, ADE from the enrollment type")
    func mac() async throws {
        let info = try await found(GraphDevices.mac, serial: "C02XK1JHJG5H")
        #expect(info.recordID == "i-mac")
        #expect(info.connectionID == SavedData.intuneID)
        #expect(info.kind == .computer)
        #expect(info.name == "Lab Mac")
        #expect(info.enrolledViaADE == true)
        #expect(info.enrollmentMethod == "appleBulkWithUser")
        #expect(info.encryption?.fileVaultEnabled == true)
        #expect(info.security == nil)
        #expect(info.osVersion == "15.1" && info.osName == "macOS")
        #expect(info.lastEnrolledDate == "2026-01-02T03:04:05Z")
        #expect(info.lastContact == "2026-10-25T08:00:00Z")
        #expect(info.mdmProfileExpiration == "2027-01-02T03:04:05Z")
        #expect(info.webURL?.absoluteString == "https://intune.microsoft.com/#view/Microsoft_Intune_ManagedDevices/ManagedDeviceMenu.MenuView/~/overview/managedDeviceId/i-mac")
        #expect(info.isManaged == true)
        #expect(info.isSupervised == true)
        #expect(info.complianceSummary == "Not compliant")
        #expect(info.udid == nil && info.managementID == nil)
    }

    @Test("An iPhone: the encryption flag is the passcode")
    func iPhone() async throws {
        let info = try await found(GraphDevices.iPhone, serial: "DMPXK1JHJG5H")
        #expect(info.kind == .mobileDevice)
        #expect(info.encryption == nil)
        #expect(info.security?.passcodePresent == true)
        #expect(info.enrolledViaADE == false)
        #expect(info.complianceSummary == "Compliant")
        #expect(info.isSupervised == false)
    }

    @Test("Another platform: storage encryption; empty values left out")
    func android() async throws {
        let info = try await found(GraphDevices.android, serial: "R58N123ABC")
        #expect(info.kind == .mobileDevice)
        #expect(info.encryption?.fileVaultEnabled == false)
        #expect(info.security == nil)
        #expect(info.osVersion == nil)
        #expect(info.osName == "Android")
        #expect(info.isManaged == nil)
        #expect(info.enrolledViaADE == nil)
        #expect(info.complianceSummary == "In grace period")
    }

    @Test("Compliance in words", arguments: [
        ("compliant", "Compliant"), ("noncompliant", "Not compliant"), ("inGracePeriod", "In grace period"),
        ("configManager", "Managed by Configuration Manager"), ("unknown", "Unknown"), ("conflict", "Conflict"),
    ])
    func compliance(state: String, words: String) async throws {
        let info = try await found(#"{"id":"i-1","serialNumber":"C02XK1JHJG5H","complianceState":"\#(state)"}"#, serial: "C02XK1JHJG5H")
        #expect(info.complianceSummary == words)
    }

    @Test("A retired device keeps its record with the agent cleared: managed is unknown, an EAS-only device isn't managed")
    func managed() async throws {
        let eas = try await found(#"{"id":"i-1","serialNumber":"C02XK1JHJG5H","managementAgent":"eas"}"#, serial: "C02XK1JHJG5H")
        #expect(eas.isManaged == false)
        let both = try await found(#"{"id":"i-1","serialNumber":"C02XK1JHJG5H","managementAgent":"easMdm"}"#, serial: "C02XK1JHJG5H")
        #expect(both.isManaged == true)
    }
}
