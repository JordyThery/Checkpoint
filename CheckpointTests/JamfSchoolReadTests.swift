import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// A failed Jamf School device-list read shows as an error on the rows, not
// as "not found", as Intune's does.

/// Checkpoint looking at the saved Jamf School server only. `devices`
/// answers the device list; everything else is an empty answer.
@MainActor
private struct SchoolHarness {
    let server: MockServer
    let model: LookupModel

    init(devices: @escaping @Sendable () throws -> MockResponse) {
        server = MockServer { request in
            if request.path == "/api/devices" { return try devices() }
            if request.path.hasPrefix("/api/devices/") { return .json(200, #"{"device":{}}"#) }
            return .json(200, #"{"locations":[]}"#)
        }
        let fixture = Fixture()
        fixture.secrets.setSecret("SECRET-api-key", for: "jamf.\(SavedData.schoolServerID.uuidString)")
        model = LookupModel(settings: fixture.settings(), log: ActivityLog(), session: server.session, underTest: .off)
        model.mdmScope = .connection(SavedData.schoolServerID)
    }

    var deviceReads: Int { server.requests.filter { $0.path == "/api/devices" }.count }

    func lookUp(_ serial: String) async -> FetchState<ManagedDeviceInfo>? {
        await model.lookUp(serialsText: serial)
        return row(serial)
    }

    func row(_ serial: String) -> FetchState<ManagedDeviceInfo>? {
        model.reports.first { $0.serial == serial }?.mdm
    }
}

private let fleet = MockResponse.json(200, #"{"devices":[{"UDID":"u-1","serialNumber":"TESTIPAD001","name":"Cart iPad"}]}"#)

@Suite("Jamf School: a failed device-list read")
@MainActor
struct JamfSchoolReadErrorTests {

    @Test("A device in the list is found; one that isn't is “not found”")
    func found() async throws {
        let harness = SchoolHarness { fleet }
        #expect(await harness.lookUp("TESTIPAD001")?.value?.recordID == "u-1")
        #expect(await harness.lookUp("TESTMAC0001")?.isNotFound == true)
    }

    @Test("A refused read shows the error on the row")
    func refused() async throws {
        let harness = SchoolHarness { .json(401, #"{"code":401,"message":"Unauthorized"}"#) }
        let state = await harness.lookUp("TESTIPAD001")
        #expect(state?.isNotFound == false)
        #expect(state?.failure?.contains("401") == true)
        #expect(state?.failure?.contains("SECRET-") == false)
    }

    @Test("An answer that isn't Jamf School's (a web page from a wrong address) is an error, not an empty list")
    func notJamfSchool() async throws {
        let harness = SchoolHarness { MockResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Sign in</html>".utf8)) }
        let state = await harness.lookUp("TESTIPAD001")
        #expect(state?.failure?.contains("not a Jamf School device list") == true)
    }

    @Test("A dropped connection is an error on the row")
    func dropped() async throws {
        let harness = SchoolHarness { throw URLError(.cannotConnectToHost) }
        let state = await harness.lookUp("TESTIPAD001")
        #expect(state?.failure != nil)
    }

    @Test("Refreshing rows after an action: a failed read is an error; a read that works again clears it")
    func refresh() async throws {
        let failing = Locked(false)
        let harness = SchoolHarness { failing.value ? .json(403, #"{"code":403,"message":"Forbidden"}"#) : fleet }
        #expect(await harness.lookUp("TESTIPAD001")?.value != nil)

        failing.withLock { $0 = true }
        await harness.model.refreshRows(["TESTIPAD001"])
        #expect(harness.row("TESTIPAD001")?.failure?.contains("403") == true)

        failing.withLock { $0 = false }
        await harness.model.refreshRows(["TESTIPAD001"])
        #expect(harness.row("TESTIPAD001")?.value?.recordID == "u-1")
        #expect(harness.deviceReads == 3)
    }
}
