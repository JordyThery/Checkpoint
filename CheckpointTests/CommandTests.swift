import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// How every command behaves (ROADMAP step 7), written against Checkpoint's
// own command code before it moved to JTKit, so the move can be checked
// against them: which connections allow each command, the address and body
// each one sends, how Jamf School and Intune are reached, and what the
// activity log keeps. Every test has its own fake server, settings domain
// and in-memory Keychain.

// MARK: - Fixtures

/// Devices on one of the saved connections in `SavedData`.
nonisolated enum Devices {
    static func mac(_ serial: String = "C02XK1JHJG5H", id: String = "7", managementID: String? = "M-7",
                    udid: String? = "5D3B6C1A-0000-1111-2222-333344445555",
                    on connection: UUID = SavedData.proClientID) -> DeviceReport {
        report(serial, ManagedDeviceInfo(recordID: id, connectionID: connection, kind: .computer,
                                         udid: udid, managementID: managementID))
    }

    static func mobile(_ serial: String = "DMPXK1JHJG5H", id: String = "12", managementID: String? = "M-12",
                       udid: String? = "00008103-001A2C3E0C38001E",
                       on connection: UUID = SavedData.proClientID) -> DeviceReport {
        report(serial, ManagedDeviceInfo(recordID: id, connectionID: connection, kind: .mobileDevice,
                                         udid: udid, managementID: managementID))
    }

    static func report(_ serial: String, _ info: ManagedDeviceInfo) -> DeviceReport {
        var report = DeviceReport(serial: serial)
        report.mdm = .found(info)
        return report
    }
}

/// A fake Jamf Pro, Platform API gateway, Jamf School and Graph in one,
/// answering every command as accepted. `override` answers first; nil falls
/// through to the defaults.
nonisolated func commandServer(_ override: @escaping @Sendable (RecordedRequest) -> MockResponse? = { _ in nil }) -> MockServer {
    MockServer { request in
        if let answer = override(request) { return answer }
        let path = request.path
        if path.hasSuffix("/oauth/token") || path.hasSuffix("/auth/token") || path.hasSuffix("/oauth2/v2.0/token") {
            return .json(200, #"{"access_token":"SECRET-token","expires_in":1200,"token":"SECRET-token"}"#)
        }
        if path.hasSuffix("/mdm/renew-profile") { return .json(200, #"{"udidsNotProcessed":{"udids":[]}}"#) }
        if path.hasSuffix("/mdm/blank-push") { return .json(200, #"{"errorUuids":[]}"#) }
        if path.hasSuffix("/detail") { return .json(200, #"{"ios":{"unlockToken":"SECRET-unlock-token"}}"#) }
        if path.hasSuffix("/devices/v1/devices") {
            let serial = (request.queryValue("filter") ?? "").replacingOccurrences(of: "serialNumber==", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .json(200, #"{"results":[{"id":"platform-\#(serial)","serialNumber":"\#(serial)"}]}"#)
        }
        if path.hasSuffix("/devices/migrate") { return .json(200, #"{"code":200,"message":"DevicesMoved"}"#) }
        if request.method == "POST" || request.method == "DELETE" { return .json(200, "{}") }
        return .json(404, "{}")
    }
}

/// Checkpoint with today's saved connections, a secret for each, and the
/// fake server.
@MainActor
struct CommandHarness {
    let server: MockServer
    let model: LookupModel
    let log = ActivityLog()

    init(_ server: MockServer = commandServer()) {
        self.server = server
        let fixture = Fixture()
        for id in [SavedData.proClientID, SavedData.proPasswordID, SavedData.platformID,
                   SavedData.schoolServerID, SavedData.intuneID] {
            fixture.secrets.setSecret("SECRET-client", for: "jamf.\(id.uuidString)")
        }
        model = LookupModel(settings: fixture.settings(), log: log, session: server.session)
    }

    /// Every request but the sign-ins.
    var sent: [RecordedRequest] {
        server.requests.filter {
            !$0.path.hasSuffix("/token")
        }
    }

    /// Sends and returns the error message, nil when it succeeded.
    @discardableResult
    func send(_ command: MDMCommand, _ reports: [DeviceReport], pin: String? = nil) async -> String? {
        do {
            try await model.sendCommand(command, reports: reports, passcode: pin)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var actions: [ActivityLogEntry] { log.entries.filter { $0.category == "Action" } }
}

/// A request's JSON body, for comparing regardless of key order.
nonisolated func body(_ request: RecordedRequest) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: request.body)) as? NSDictionary
}

nonisolated func dictionary(_ text: String) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary ?? [:]
}

// MARK: - Which connections allow each command

@Suite("Which connections allow each command")
struct CommandAvailabilityTests {

    @Test("Each product offers its commands for each kind of device, in this order")
    func offered() {
        #expect(MDMCommand.commands(for: .computer, product: .jamfPro)
                == [.lockComputer, .renewProfile, .redeployFramework, .wipeComputer, .blankPush, .unmanage])
        #expect(MDMCommand.commands(for: .mobileDevice, product: .jamfPro)
                == [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile,
                    .wipeMobile, .unmanage, .blankPush, .renewProfile])
        #expect(MDMCommand.commands(for: .computer, product: .jamfSchool)
                == [.updateInventory, .restartMobile, .wipeComputer, .unmanage])
        #expect(MDMCommand.commands(for: .mobileDevice, product: .jamfSchool)
                == [.updateInventory, .restartMobile, .wipeMobile, .unmanage])
        #expect(MDMCommand.commands(for: .computer, product: .intune)
                == [.updateInventory, .restartMobile, .shutDownMobile, .wipeComputer, .unmanage])
        #expect(MDMCommand.commands(for: .mobileDevice, product: .intune)
                == [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile,
                    .wipeMobile, .unmanage])
        #expect(MDMCommand.allInDisplayOrder
                == [.updateInventory, .lockComputer, .lockMobile, .clearPasscode, .restartMobile,
                    .shutDownMobile, .renewProfile, .redeployFramework, .blankPush, .unmanage,
                    .wipeComputer, .wipeMobile])
    }

    @Test("Over the Platform API only Renew MDM Profile is blocked; direct connections allow everything")
    func overThePlatformAPI() {
        for command in MDMCommand.allInDisplayOrder {
            #expect(command.unavailabilityReason(via: .apiClient) == nil)
            #expect(command.unavailabilityReason(via: .usernamePassword) == nil)
            if command == .renewProfile {
                #expect(command.unavailabilityReason(via: .platformGateway)
                        == "This command is currently unavailable over the Platform API and requires an API client connection.")
            } else {
                #expect(command.unavailabilityReason(via: .platformGateway) == nil)
            }
        }
    }

    @Test("A PIN is asked for Lock and Wipe Computer on Jamf Pro only")
    func pin() {
        for command in MDMCommand.allInDisplayOrder {
            let needs = command == .lockComputer || command == .wipeComputer
            #expect(command.needsPIN(product: .jamfPro) == needs)
            #expect(!command.needsPIN(product: .jamfSchool))
            #expect(!command.needsPIN(product: .intune))
        }
    }

    @Test("Wipe, lock and Remove MDM Profile have a destructive button")
    func destructive() {
        let destructive = Set(MDMCommand.allInDisplayOrder.filter(\.isDestructive))
        #expect(destructive == [.wipeComputer, .wipeMobile, .lockComputer, .lockMobile, .unmanage])
    }

    @Test("Titles and consequences, as the dialogs show them")
    func texts() {
        let titles: [MDMCommand: String] = [
            .lockComputer: "Lock Computer", .wipeComputer: "Wipe Computer", .blankPush: "Send Blank Push",
            .renewProfile: "Renew MDM Profile", .redeployFramework: "Redeploy Jamf Framework",
            .updateInventory: "Update Inventory", .lockMobile: "Lock Device", .unmanage: "Remove MDM Profile",
            .clearPasscode: "Clear Passcode", .restartMobile: "Restart Device",
            .shutDownMobile: "Shut Down Device", .wipeMobile: "Wipe Device",
        ]
        for (command, title) in titles { #expect(command.title == title) }

        let messages: [MDMCommand: String] = [
            .lockComputer: "The Mac will lock immediately and require the PIN to be used again.",
            .wipeComputer: "All data on the Mac will be erased. This cannot be undone.",
            .blankPush: "The device will be asked to check in with MDM and process any pending commands.",
            .renewProfile: "The MDM enrollment profile will be renewed on the device.",
            .redeployFramework: "Reinstalls the Jamf management framework (jamf binary) on the Mac through MDM. Use when a Mac has stopped checking in but still responds to MDM.",
            .updateInventory: "The device will be asked to submit a fresh inventory report.",
            .lockMobile: "The device will lock immediately; the owner's passcode unlocks it.",
            .clearPasscode: "The device passcode will be removed.",
            .restartMobile: "The device will restart immediately.",
            .shutDownMobile: "The device will shut down immediately and stay off until someone powers it back on.",
            .wipeMobile: "All data on the device will be erased. This cannot be undone.",
        ]
        // Intune has its own texts (IntuneTests, ROADMAP step 8)
        for (command, message) in messages {
            for product in [MDMProduct.jamfPro, .jamfSchool] {
                #expect(command.message(for: product) == message)
            }
        }
        #expect(MDMCommand.unmanage.message(for: .jamfPro)
                == "The MDM profile is removed, so Jamf Pro can no longer manage the device. Its inventory record stays until you delete it.")
        #expect(MDMCommand.unmanage.message(for: .jamfSchool)
                == "The MDM profile is removed, so Jamf School can no longer manage the device. Its record stays until you move it to the trash.")
        #expect(MDMCommand.unmanage.message(for: .intune)
                == "The device is retired: company data and the management profile are removed, so Intune can no longer manage it. Unlike the Jamf products, the record goes too once the device acknowledges.")
    }

    @Test("Clear Passcode does nothing to a device without a passcode")
    func clearPasscodeNeedsAPasscode() {
        var info = ManagedDeviceInfo(recordID: "12", kind: .mobileDevice)
        info.security = MobileSecurityState(passcodePresent: false, passcodeCompliant: nil,
                                            passcodeCompliantWithProfile: nil, hardwareEncryption: nil)
        #expect(MDMCommand.clearPasscode.inapplicabilityReason(for: info) == "This device has no passcode set.")
        #expect(MDMCommand.lockMobile.inapplicabilityReason(for: info) == nil)
    }

    @Test("A selection on two connections is refused, and nothing is sent")
    @MainActor
    func twoConnections() async {
        let harness = CommandHarness()
        let error = await harness.send(.blankPush, [Devices.mac(), Devices.mobile(on: SavedData.proPasswordID)])
        #expect(error?.contains("MDM actions work through one connection at a time") == true)
        #expect(harness.server.requests.isEmpty)
    }

    @Test("The model blocks Renew MDM Profile on a Platform API connection before anything is sent")
    @MainActor
    func renewOverThePlatformAPI() async {
        let harness = CommandHarness()
        let error = await harness.send(.renewProfile, [Devices.mac(on: SavedData.platformID)])
        #expect(error == "This command is currently unavailable over the Platform API and requires an API client connection.")
        #expect(harness.server.requests.isEmpty)
    }
}

// MARK: - Jamf Pro: addresses and bodies

/// Where a Jamf Pro connection sends: straight to the server or through the
/// Platform API, whose paths start with /pro and /proclassic.
nonisolated enum Route: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case apiClient, usernamePassword, platform

    var id: UUID {
        switch self {
        case .apiClient: SavedData.proClientID
        case .usernamePassword: SavedData.proPasswordID
        case .platform: SavedData.platformID
        }
    }

    var host: String {
        switch self {
        case .apiClient: "aviobook.jamfcloud.com"
        case .usernamePassword: "jamf.example.com"
        case .platform: "eu.api.jamfcloud.com"
        }
    }

    /// `/api/…` as this route sends it.
    func api(_ path: String) -> String { self == .platform ? "/pro/" + path : "/api/" + path }
    func classic(_ path: String) -> String { self == .platform ? "/proclassic/" + path : "/JSSResource/" + path }

    var testDescription: String { rawValue }
}

@Suite("Jamf Pro commands: address and body")
@MainActor
struct JamfProCommandTests {

    @Test("Lock Computer sends DEVICE_LOCK with the PIN to v2/mdm/commands", arguments: Route.allCases)
    func lockComputer(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.lockComputer, [Devices.mac(on: route.id)], pin: "123456") == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.url.host() == route.host)
        #expect(request.path == route.api("v2/mdm/commands"))
        #expect(body(request) == dictionary(#"{"clientData":[{"managementId":"M-7"}],"commandData":{"commandType":"DEVICE_LOCK","pin":"123456"}}"#))
    }

    @Test("Lock Device sends DEVICE_LOCK without a PIN, all devices in one request", arguments: Route.allCases)
    func lockMobile(route: Route) async throws {
        let harness = CommandHarness()
        let devices = [Devices.mobile(on: route.id), Devices.mobile("DMPAAAAAAAAA", id: "13", managementID: "M-13", on: route.id)]
        #expect(await harness.send(.lockMobile, devices) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.path == route.api("v2/mdm/commands"))
        #expect(body(request) == dictionary(#"{"clientData":[{"managementId":"M-12"},{"managementId":"M-13"}],"commandData":{"commandType":"DEVICE_LOCK"}}"#))
    }

    @Test("Restart and Shut Down go to v2/mdm/commands on a direct connection",
          arguments: [(MDMCommand.restartMobile, "RESTART_DEVICE"), (.shutDownMobile, "SHUT_DOWN_DEVICE")])
    func restartDirect(command: MDMCommand, type: String) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(command, [Devices.mobile()]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.path == "/api/v2/mdm/commands")
        #expect(body(request) == dictionary(#"{"clientData":[{"managementId":"M-12"}],"commandData":{"commandType":"\#(type)"}}"#))
    }

    @Test("Through the Platform API, Restart and Shut Down look the device up by serial, then use device-actions",
          arguments: [(MDMCommand.restartMobile, "restart"), (.shutDownMobile, "shutdown")])
    func restartPlatform(command: MDMCommand, action: String) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(command, [Devices.mobile(on: SavedData.platformID)]) == nil)
        let requests = harness.sent
        #expect(requests.count == 2)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.path == "/devices/v1/devices")
        #expect(requests.first?.queryValue("filter") == #"serialNumber=="DMPXK1JHJG5H""#)
        #expect(requests.last?.method == "POST")
        #expect(requests.last?.path == "/device-actions/v1/devices/platform-DMPXK1JHJG5H/\(action)")
        #expect(requests.last?.body.isEmpty == true)
    }

    @Test("Through the Platform API, a serial that doesn't match exactly sends nothing")
    func platformMismatch() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/devices/v1/devices")
                ? .json(200, #"{"results":[{"id":"someone-else","serialNumber":"OTHER"}]}"#) : nil
        })
        let error = await harness.send(.restartMobile, [Devices.mobile(on: SavedData.platformID)])
        #expect(error?.contains("DMPXK1JHJG5H") == true)
        #expect(error?.contains("No command was sent.") == true)
        #expect(!harness.sent.contains { $0.path.contains("device-actions") })
    }

    @Test("Through the Platform API, a device not in the inventory is named")
    func platformUnknown() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/devices/v1/devices") ? .json(200, #"{"results":[]}"#) : nil
        })
        let error = await harness.send(.shutDownMobile, [Devices.mobile(on: SavedData.platformID)])
        #expect(error == "DMPXK1JHJG5H: not in the platform device inventory.")
    }

    @Test("Through the Platform API, a 422 is explained")
    func platform422() async {
        let harness = CommandHarness(commandServer { request in
            request.path.contains("/device-actions/") ? .json(422, "{}") : nil
        })
        let error = await harness.send(.restartMobile, [Devices.mobile(on: SavedData.platformID)])
        #expect(error?.contains("will not restart this device. It may be unmanaged, personally owned, or running an OS version that does not support the command.") == true)
    }

    @Test("Wipe Computer sends the PIN to the computer's erase", arguments: Route.allCases)
    func wipeComputer(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.wipeComputer, [Devices.mac(on: route.id)], pin: "654321") == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.path == route.api("v4/computers-inventory/7/erase"))
        #expect(body(request) == dictionary(#"{"pin":"654321"}"#))
    }

    @Test("Wipe Device sends an empty body to the mobile device's erase", arguments: Route.allCases)
    func wipeMobile(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.wipeMobile, [Devices.mobile(on: route.id)]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.path == route.api("v2/mobile-devices/12/erase"))
        #expect(body(request) == dictionary("{}"))
    }

    @Test("Remove MDM Profile: remove-mdm-profile for a Mac, unmanage for a mobile device", arguments: Route.allCases)
    func unmanage(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.unmanage, [Devices.mac(on: route.id), Devices.mobile(on: route.id)]) == nil)
        let requests = harness.sent
        #expect(requests.map(\.method) == ["POST", "POST"])
        #expect(requests.map(\.path) == [route.api("v4/computers-inventory/7/remove-mdm-profile"),
                                         route.api("v2/mobile-devices/12/unmanage")])
        #expect(requests.allSatisfy { $0.body.isEmpty })
    }

    @Test("Redeploy Jamf Framework goes to each Mac's redeploy", arguments: Route.allCases)
    func redeploy(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.redeployFramework, [Devices.mac(on: route.id), Devices.mobile(on: route.id)]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.path == route.api("v1/jamf-management-framework/redeploy/7"))
    }

    @Test("Renew MDM Profile sends the UDIDs in one request", arguments: [Route.apiClient, .usernamePassword])
    func renew(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.renewProfile, [Devices.mac(on: route.id), Devices.mobile(on: route.id)]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.path == route.api("v1/mdm/renew-profile"))
        #expect(body(request) == dictionary(#"{"udids":["5D3B6C1A-0000-1111-2222-333344445555","00008103-001A2C3E0C38001E"]}"#))
    }

    @Test("Renew MDM Profile names the devices Jamf Pro didn't renew")
    func renewNotProcessed() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/renew-profile")
                ? .json(200, #"{"udidsNotProcessed":{"udids":["00008103-001A2C3E0C38001E"]}}"#) : nil
        })
        let error = await harness.send(.renewProfile, [Devices.mac(), Devices.mobile()])
        #expect(error == "Jamf Pro accepted the request but renewed no profile for: DMPXK1JHJG5H")
    }

    @Test("Renew MDM Profile without any UDID sends nothing")
    func renewWithoutUDID() async {
        let harness = CommandHarness()
        let error = await harness.send(.renewProfile, [Devices.mac(udid: nil)])
        #expect(error == "No device UDIDs are known, so the MDM profile cannot be renewed.")
        #expect(harness.sent.isEmpty)
    }

    @Test("Blank Push: a DDM sync per device, then one blank push", arguments: Route.allCases)
    func blankPush(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.blankPush, [Devices.mac(on: route.id), Devices.mobile(on: route.id)]) == nil)
        let requests = harness.sent
        #expect(requests.map(\.path) == [route.api("v1/ddm/M-7/sync"), route.api("v1/ddm/M-12/sync"),
                                         route.api("v2/mdm/blank-push")])
        #expect(requests.allSatisfy { $0.method == "POST" })
        #expect(body(requests[2]) == dictionary(#"{"clientManagementIds":["M-7","M-12"]}"#))
    }

    @Test("Blank Push: a device that refuses the DDM sync gets a DeviceInformation query instead")
    func blankPushFallback() async throws {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/M-12/sync") ? .json(400, "{}") : nil
        })
        #expect(await harness.send(.blankPush, [Devices.mac(), Devices.mobile()]) == nil)
        let paths = harness.sent.map(\.path)
        #expect(paths == ["/api/v1/ddm/M-7/sync", "/api/v1/ddm/M-12/sync", "/api/v2/mdm/commands", "/api/v2/mdm/blank-push"])
        #expect(body(harness.sent[2]) == dictionary(#"{"clientData":[{"managementId":"M-12"}],"commandData":{"commandType":"DEVICE_INFORMATION","queries":["DeviceName"]}}"#))
    }

    @Test("Blank Push names the devices it couldn't reach")
    func blankPushErrors() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/blank-push") ? .json(200, #"{"errorUuids":["m-12"]}"#) : nil
        })
        let error = await harness.send(.blankPush, [Devices.mac(), Devices.mobile()])
        #expect(error == "Jamf Pro could not deliver the blank push to: DMPXK1JHJG5H")
    }

    @Test("Blank Push without a management ID sends nothing")
    func blankPushWithoutManagementID() async {
        let harness = CommandHarness()
        let error = await harness.send(.blankPush, [Devices.mac(managementID: nil)])
        #expect(error == "No management IDs are known, so a blank push cannot be sent. Run a fresh lookup first.")
        #expect(harness.sent.isEmpty)
    }

    @Test("Clear Passcode reads the unlock token, then sends CLEAR_PASSCODE with it", arguments: Route.allCases)
    func clearPasscode(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.clearPasscode, [Devices.mobile(on: route.id)]) == nil)
        let requests = harness.sent
        #expect(requests.map(\.method) == ["GET", "POST"])
        #expect(requests.map(\.path) == [route.api("v2/mobile-devices/12/detail"), route.api("v2/mdm/commands")])
        #expect(body(requests[1]) == dictionary(#"{"clientData":[{"managementId":"M-12"}],"commandData":{"commandType":"CLEAR_PASSCODE","unlockToken":"SECRET-unlock-token"}}"#))
    }

    @Test("Clear Passcode without an escrowed unlock token sends no command")
    func clearPasscodeWithoutToken() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/detail") ? .json(200, #"{"ios":{}}"#) : nil
        })
        let error = await harness.send(.clearPasscode, [Devices.mobile()])
        #expect(error == "DMPXK1JHJG5H: Jamf Pro has no escrowed unlock token for this device, so the passcode cannot be cleared.")
        #expect(!harness.sent.contains { $0.method == "POST" })
    }

    @Test("Update Inventory is a Classic mobile device command", arguments: Route.allCases)
    func updateInventory(route: Route) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.updateInventory, [Devices.mobile(on: route.id)]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.path == route.classic("mobiledevicecommands/command/UpdateInventory/id/12"))
        #expect(request.body.isEmpty)
    }

    @Test("Update Inventory isn't sent to a Mac on Jamf Pro")
    func updateInventoryMac() async {
        let harness = CommandHarness()
        let error = await harness.send(.updateInventory, [Devices.mac()])
        #expect(error == "Update Inventory doesn't apply to any of the selected devices.")
        #expect(harness.server.requests.isEmpty)
    }

    @Test("A mixed selection is sent per kind of device, each in one request")
    func mixedKinds() async {
        let harness = CommandHarness()
        // Lock Computer applies to Macs, Lock Device to mobile devices: one
        // command, one kind each.
        #expect(await harness.send(.lockMobile, [Devices.mac(), Devices.mobile()]) == nil)
        #expect(harness.sent.count == 1)
        #expect(body(harness.sent[0])?["clientData"] as? [NSDictionary] == [["managementId": "M-12"]])
    }

    @Test("A device without a management ID is named; the others are still sent")
    func withoutManagementID() async {
        let harness = CommandHarness()
        let devices = [Devices.mobile(), Devices.mobile("DMPAAAAAAAAA", id: "13", managementID: nil)]
        let error = await harness.send(.lockMobile, devices)
        #expect(error == "DMPAAAAAAAAA: the record has no management ID. Run a fresh lookup first.")
        #expect(body(harness.sent[0])?["clientData"] as? [NSDictionary] == [["managementId": "M-12"]])
    }

    @Test("A failed device is named; the others are still sent")
    func onePerDeviceFailure() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/mobile-devices/13/erase") ? .json(500, "{}") : nil
        })
        let devices = [Devices.mobile(), Devices.mobile("DMPAAAAAAAAA", id: "13", managementID: "M-13")]
        let error = await harness.send(.wipeMobile, devices)
        #expect(error?.hasPrefix("DMPAAAAAAAAA: ") == true)
        #expect(harness.sent.map(\.path) == ["/api/v2/mobile-devices/12/erase", "/api/v2/mobile-devices/13/erase"])
    }

    @Test("A command isn't repeated after a server error")
    func notRepeated() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/mdm/commands") ? .json(500, "{}") : nil
        })
        #expect(await harness.send(.lockMobile, [Devices.mobile()]) != nil)
        #expect(harness.sent.count == 1)
    }

    @Test("A command is sent again after a 429, when nothing was done")
    func retriedAfter429() async {
        let calls = Counter()
        let harness = CommandHarness(commandServer { request in
            guard request.path.hasSuffix("/mdm/commands") else { return nil }
            return calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "0"]) : nil
        })
        #expect(await harness.send(.lockMobile, [Devices.mobile()]) == nil)
        #expect(harness.sent.count == 2)
    }
}

// MARK: - Deleting records

@Suite("Deleting a Jamf Pro record")
@MainActor
struct DeleteRecordTests {

    @Test("A Mac's record is deleted on v4, a mobile device's on the Classic API", arguments: Route.allCases)
    func delete(route: Route) async throws {
        let harness = CommandHarness()
        try await harness.model.deleteMDMRecord(reports: [Devices.mac(on: route.id), Devices.mobile(on: route.id)])
        let deletes = harness.sent.filter { $0.method == "DELETE" }
        #expect(deletes.map(\.path) == [route.api("v4/computers-inventory/7"), route.classic("mobiledevices/id/12")])
        let action = try #require(harness.actions.last)
        #expect(action.service == "Jamf Pro")
        #expect(action.connection == harness.model.settings.mdmConnections.first { $0.id == route.id }?.displayName)
    }
}

// MARK: - Jamf School

@Suite("Jamf School commands, Move to Trash and moving location")
@MainActor
struct JamfSchoolCommandTests {

    private func device(_ serial: String = "DMPXK1JHJG5H", udid: String = "u-1", kind: DeviceKind = .mobileDevice,
                        location: String? = "1") -> DeviceReport {
        var info = ManagedDeviceInfo(recordID: udid, connectionID: SavedData.schoolServerID, kind: kind, udid: udid)
        info.locationID = location
        return Devices.report(serial, info)
    }

    @Test("Each command is a form POST to the device, with the required fields always false",
          arguments: [(MDMCommand.updateInventory, "refresh", ""),
                      (.restartMobile, "restart", "clearPasscode=false"),
                      (.wipeMobile, "wipe", "clearActivationLock=false"),
                      (.unmanage, "unenroll", "")])
    func commands(command: MDMCommand, action: String, form: String) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(command, [device()]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.url.host() == "school.jamfcloud.com")
        #expect(request.path == "/api/devices/u-1/\(action)")
        #expect(request.bodyString == form)
        if !form.isEmpty {
            #expect(request.header("Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
        }
        let basic = Data("067680:SECRET-client".utf8).base64EncodedString()
        #expect(request.header("Authorization") == "Basic \(basic)")
    }

    @Test("Wipe Computer reaches a Mac through the same wipe")
    func wipeMac() async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.wipeComputer, [device("C02XK1JHJG5H", udid: "u-9", kind: .computer)]) == nil)
        #expect(harness.sent.only?.path == "/api/devices/u-9/wipe")
    }

    @Test("A failure under HTTP 200 is reported, and the other devices are still sent")
    func failureUnder200() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasPrefix("/api/devices/u-2/") ? .json(200, #"{"code":400,"message":"DeviceNotActive"}"#) : nil
        })
        let error = await harness.send(.restartMobile, [device(), device("DMPAAAAAAAAA", udid: "u-2")])
        #expect(error?.hasPrefix("DMPAAAAAAAAA: ") == true)
        #expect(error?.contains("the device is trashed or inactive, so it cannot be sent commands.") == true)
        #expect(harness.sent.count == 2)
    }

    @Test("Move to Trash is a DELETE with the trailing slash")
    func trash() async throws {
        let harness = CommandHarness()
        try await harness.model.deleteMDMRecord(reports: [device()])
        let request = try #require(harness.sent.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/devices/u-1/")
        let action = try #require(harness.actions.last)
        #expect(action.service == "Jamf School")
        #expect(action.detail.hasPrefix("Trashed"))
    }

    @Test("Moving location is a JSON PUT of at most twenty devices each")
    func move() async throws {
        let harness = CommandHarness()
        let devices = (1...25).map { device(String(format: "SER%04d", $0), udid: "u-\($0)") }
        try await harness.model.setLocation(reports: devices, to: "2")
        let puts = harness.sent.filter { $0.method == "PUT" }
        #expect(puts.count == 2)
        #expect(puts.allSatisfy { $0.path == "/api/devices/migrate" && $0.header("Content-Type") == "application/json" })
        #expect((body(puts[0])?["udids"] as? [String])?.count == 20)
        #expect((body(puts[1])?["udids"] as? [String]) == (21...25).map { "u-\($0)" })
        #expect(body(puts[0])?["locationId"] as? String == "2")
    }

    @Test("Devices Jamf School didn't move are named")
    func unmoved() async {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/migrate") ? .json(200, #"{"devicesMoved":["u-1"],"devicesMoveFailed":["u-2"]}"#) : nil
        })
        do {
            try await harness.model.setLocation(reports: [device(), device("DMPAAAAAAAAA", udid: "u-2")], to: "2")
            Issue.record("moved")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Jamf School did not move: DMPAAAAAAAAA."))
        }
    }

    @Test("Devices already in the location aren't sent")
    func alreadyThere() async throws {
        let harness = CommandHarness()
        try await harness.model.setLocation(reports: [device(location: "2")], to: "2")
        #expect(harness.sent.isEmpty)
    }
}

// MARK: - Intune

@Suite("Intune commands")
@MainActor
struct IntuneCommandTests {

    private func device(kind: DeviceKind = .mobileDevice) -> DeviceReport {
        Devices.report("DMPXK1JHJG5H", ManagedDeviceInfo(recordID: "i-1", connectionID: SavedData.intuneID, kind: kind))
    }

    @Test("Each command is a POST to the managed device's action",
          arguments: [(MDMCommand.updateInventory, "syncDevice"), (.restartMobile, "rebootNow"),
                      (.shutDownMobile, "shutDown"), (.lockMobile, "remoteLock"),
                      (.clearPasscode, "resetPasscode"), (.unmanage, "retire")])
    func actions(command: MDMCommand, action: String) async throws {
        let harness = CommandHarness()
        #expect(await harness.send(command, [device()]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.method == "POST")
        #expect(request.path == "/v1.0/deviceManagement/managedDevices/i-1/\(action)")
    }

    @Test("Wipe sends an empty JSON body")
    func wipe() async throws {
        let harness = CommandHarness()
        #expect(await harness.send(.wipeMobile, [device()]) == nil)
        let request = try #require(harness.sent.only)
        #expect(request.path == "/v1.0/deviceManagement/managedDevices/i-1/wipe")
        #expect(request.bodyString == "{}")
    }

    @Test("Delete Record deletes the managed device")
    func delete() async throws {
        let harness = CommandHarness()
        try await harness.model.deleteMDMRecord(reports: [device()])
        // The lookup that refreshes the row afterwards doesn't count.
        let request = try #require(harness.sent.filter { $0.method == "DELETE" }.only)
        #expect(request.path == "/v1.0/deviceManagement/managedDevices/i-1")
    }
}

// MARK: - What the log keeps

@Suite("Commands in the activity log")
@MainActor
struct CommandLogTests {

    @Test("A sent command is one Action entry with the connection and serials")
    func sentEntry() async throws {
        let harness = CommandHarness()
        await harness.send(.lockMobile, [Devices.mobile(), Devices.mobile("DMPAAAAAAAAA", id: "13", managementID: "M-13")])
        let action = try #require(harness.actions.only)
        #expect(action.service == "Jamf Pro")
        #expect(action.connection == "Jamf Pro sandbox")
        #expect(!action.isFailure)
        let masked = ActivityLogExport.text(harness.log.entries, masked: true)
        #expect(!masked.contains("DMPXK1JHJG5H") && !masked.contains("DMPAAAAAAAAA"))
    }

    @Test("A failed command is a failed Action entry")
    func failedEntry() async throws {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/erase") ? .json(500, "{}") : nil
        })
        await harness.send(.wipeMobile, [Devices.mobile()])
        let action = try #require(harness.actions.only)
        #expect(action.isFailure)
    }

    @Test("Neither the PIN nor the unlock token reaches the log, also when the command fails",
          arguments: Route.allCases)
    func noSecrets(route: Route) async {
        let harness = CommandHarness(commandServer { request in
            if request.path.hasSuffix("/mdm/commands") || request.path.hasSuffix("/erase") {
                return .json(400, #"{"errors":[{"code":"INVALID","description":"Refused"}]}"#)
            }
            return nil
        })
        await harness.send(.lockComputer, [Devices.mac(on: route.id)], pin: "SECRET-PIN-1")
        await harness.send(.wipeComputer, [Devices.mac(on: route.id)], pin: "SECRET-PIN-2")
        await harness.send(.wipeMobile, [Devices.mobile(on: route.id)])
        await harness.send(.clearPasscode, [Devices.mobile(on: route.id)])
        let everything = ActivityLogExport.text(harness.log.entries, masked: false)
        #expect(!everything.contains("SECRET-"))
    }
}

extension Array {
    /// The one element, nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}

// MARK: - Step 7: the confirmation rules and what the Action entry says

@Suite("Confirming commands and record removals")
@MainActor
struct ConfirmationRuleTests {

    @Test("Wipe on one device names the connection and asks nothing to be typed")
    func wipeOne() throws {
        let harness = CommandHarness()
        let confirmation = try #require(harness.model.commandConfirmation(.wipeMobile, reports: [Devices.mobile()]))
        #expect(confirmation.title == "Wipe Device — DMPXK1JHJG5H")
        #expect(confirmation.connectionLine == "On “Jamf Pro sandbox”.")
        #expect(!confirmation.needsTyping)
        #expect(confirmation.dialogMessage == "On “Jamf Pro sandbox”.\n\nAll data on the device will be erased. This cannot be undone.")
    }

    @Test("Remove MDM Profile on three devices asks for the number")
    func unmanageThree() throws {
        let harness = CommandHarness()
        let devices = [Devices.mac(), Devices.mobile(), Devices.mobile("DMPAAAAAAAAA", id: "13")]
        let confirmation = try #require(harness.model.commandConfirmation(.unmanage, reports: devices))
        #expect(confirmation.title == "Remove MDM Profile — 3 Devices")
        #expect(confirmation.typedCount == 3)
        #expect(confirmation.connectionLine != nil)
    }

    @Test("Lock and Wipe Computer ask for the PIN twice on Jamf Pro, not on Jamf School")
    func pinTwice() throws {
        let harness = CommandHarness()
        let lock = try #require(harness.model.commandConfirmation(.lockComputer, reports: [Devices.mac()]))
        #expect(lock.asksPINTwice && lock.typedCount == nil && lock.connectionLine == nil)
        var schoolMac = ManagedDeviceInfo(recordID: "u-9", connectionID: SavedData.schoolServerID, kind: .computer)
        schoolMac.udid = "u-9"
        let wipe = try #require(harness.model.commandConfirmation(.wipeComputer, reports: [Devices.report("C02XK1JHJG5H", schoolMac)]))
        #expect(!wipe.asksPINTwice)
        #expect(wipe.connectionLine == "On “Jamf School”.")
    }

    @Test("When fewer devices than selected receive it, the confirmation says why")
    func explanation() throws {
        let harness = CommandHarness()
        let devices = [Devices.mobile("DMP1", id: "1", managementID: "M-1"), Devices.mobile("DMP2", id: "2", managementID: "M-2"),
                       Devices.mobile("DMP3", id: "3", managementID: "M-3"),
                       Devices.mobile("DMP4", id: "4", managementID: nil), Devices.mobile("DMP5", id: "5", managementID: nil)]
        let confirmation = try #require(harness.model.commandConfirmation(.lockMobile, reports: devices))
        #expect(confirmation.explanation == "5 selected, 3 will receive the command; 2 have no management ID.")
        #expect(confirmation.title == "Lock Device — 3 Devices")
        let wipe = try #require(harness.model.commandConfirmation(.wipeMobile, reports: devices + [Devices.mac()]))
        #expect(wipe.typedCount == 5)
        #expect(wipe.explanation == "6 selected, 5 will receive the command; 1 is a Mac.")
    }

    @Test("Deleting Jamf Pro records names the connection and, from two, asks for the number")
    func deleteRecords() throws {
        let harness = CommandHarness()
        let one = try #require(harness.model.deleteConfirmation(reports: [Devices.mac()]))
        #expect(one.connectionLine == "On “Jamf Pro sandbox”." && !one.needsTyping)
        let two = try #require(harness.model.deleteConfirmation(reports: [Devices.mac(), Devices.mobile()]))
        #expect(two.typedCount == 2)
    }

    @Test("Move to Trash names the connection but asks for no number")
    func trash() throws {
        let harness = CommandHarness()
        let devices = ["u-1", "u-2", "u-3"].map {
            Devices.report("S-\($0)", ManagedDeviceInfo(recordID: $0, connectionID: SavedData.schoolServerID, kind: .mobileDevice))
        }
        let confirmation = try #require(harness.model.deleteConfirmation(reports: devices))
        #expect(confirmation.connectionLine == "On “Jamf School”.")
        #expect(confirmation.typedCount == nil)
        #expect(confirmation.title == "Move to Trash — 3 Devices")
    }

    @Test("A selection on two connections has no confirmation: nothing can be sent")
    func twoConnections() {
        let harness = CommandHarness()
        #expect(harness.model.commandConfirmation(.wipeMobile, reports: [Devices.mobile(), Devices.mobile(on: SavedData.proPasswordID)]) == nil)
    }
}

@Suite("The Action entry for a command")
@MainActor
struct CommandActionEntryTests {

    @Test("It counts the devices the command went to and names the skipped ones with the reason")
    func skipped() async throws {
        let harness = CommandHarness()
        let devices = [Devices.mobile(), Devices.mobile("DMPAAAAAAAAA", id: "13", managementID: nil), Devices.mac()]
        _ = await harness.send(.lockMobile, devices)
        let action = try #require(harness.actions.only)
        #expect(action.detail == "Sent Lock Device to 1 of 3 devices")
        #expect(action.note?.contains("DMPAAAAAAAAA: skipped — the record has no management ID. Run a fresh lookup first.") == true)
        #expect(action.note?.contains("C02XK1JHJG5H: skipped — the command doesn’t apply to Macs.") == true)
        #expect(action.isWarning && !action.isFailure)
    }

    @Test("The number sent is returned, for the message after sending")
    func sentCount() async throws {
        let harness = CommandHarness()
        let sent = try await harness.model.sendCommand(.unmanage, reports: [Devices.mac(), Devices.mobile()])
        #expect(sent == 2)
        #expect(harness.actions.only?.detail == "Sent Remove MDM Profile to 2 devices")
    }

    @Test("A command refused as a whole is one failed entry")
    func refused() async throws {
        let harness = CommandHarness()
        _ = await harness.send(.renewProfile, [Devices.mac(udid: nil)])
        let action = try #require(harness.actions.only)
        #expect(action.detail == "Renew MDM Profile failed — No device UDIDs are known, so the MDM profile cannot be renewed.")
        #expect(action.isFailure)
    }

    @Test("Jamf School: a failed device is named in the entry")
    func school() async throws {
        let harness = CommandHarness(commandServer { request in
            request.path.hasPrefix("/api/devices/u-2/") ? .json(200, #"{"code":400,"message":"DeviceNotActive"}"#) : nil
        })
        let devices = ["u-1", "u-2"].map {
            Devices.report("S-\($0)", ManagedDeviceInfo(recordID: $0, connectionID: SavedData.schoolServerID, kind: .mobileDevice))
        }
        _ = await harness.send(.restartMobile, devices)
        let action = try #require(harness.actions.only)
        #expect(action.service == "Jamf School" && action.connection == "Jamf School")
        #expect(action.detail == "Sent Restart Device to 1 of 2 devices")
        #expect(action.isFailure)
        #expect(action.note?.hasPrefix("S-u-2: failed — Jamf School: the device is trashed or inactive") == true)
    }

    @Test("A Jamf Pro error shows JTKit's format, naming the command's privilege")
    func errorFormat() async throws {
        let harness = CommandHarness(commandServer { request in
            request.path.hasSuffix("/erase") ? .json(403, #"{"httpStatus":403,"traceId":"trace-1","errors":[{"code":"FORBIDDEN","description":"Not allowed"}]}"#) : nil
        })
        let error = await harness.send(.wipeMobile, [Devices.mobile()])
        #expect(error == """
            DMPXK1JHJG5H: HTTP 403 Forbidden
            FORBIDDEN: Not allowed
            Trace ID: trace-1
            The API role is missing the “Send Mobile Device Remote Wipe Command” privilege. Add it in Jamf Pro under Settings › API Roles and Clients.
            """)
    }
}
