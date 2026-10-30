import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// An action on a record goes through the record's own connection, never the
// toolbar's; when that connection has been removed, the action is refused
// with a message. A record is identified by its connection and its record
// ID, which repeat across connections (found during JTKit ROADMAP step 11).

@Suite("Actions follow the record's own connection")
@MainActor
struct RecordConnectionTests {
    /// A connection no longer configured (removed in Settings after the lookup).
    static let removedID = UUID(uuidString: "EEEEEEEE-0000-4000-8000-00000000DEAD")!

    /// Today's saved connections, the toolbar on "Example Jamf Pro".
    private func harness() -> CommandHarness {
        let harness = CommandHarness()
        harness.model.selectedConnectionID = SavedData.proClientID
        return harness
    }

    private func message(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test("A record from a removed connection has no connection, offers nothing and names why")
    func removedConnectionHasNoFallback() {
        let model = harness().model
        let report = Devices.mac(on: Self.removedID)
        #expect(model.selectedConnection?.id == SavedData.proClientID)
        #expect(model.connection(for: report) == nil, "never the toolbar's connection")
        #expect(model.isFromRemovedConnection(report.mdm.value))
        #expect(model.capabilities(for: report).isEmpty)
        #expect(model.mdmActionUnavailableReason(for: [report]) == LookupModel.removedConnectionMessage)
        // A record on a configured connection is that connection's, whatever the toolbar says.
        #expect(model.connection(for: Devices.mac(on: SavedData.proPasswordID))?.id == SavedData.proPasswordID)
        #expect(!model.isFromRemovedConnection(Devices.mac(on: SavedData.proPasswordID).mdm.value))
    }

    @Test("Every action on a record from a removed connection is refused before any request")
    func actionsOnRemovedConnectionRefuse() async throws {
        let harness = harness()
        let model = harness.model
        let mac = Devices.mac(on: Self.removedID)
        let info = try #require(mac.mdm.value)
        let refusal = LookupModel.removedConnectionMessage
        #expect(await message { try await model.removeRecord(info, serial: mac.serial) } == refusal)
        #expect(await message { try await model.setAssetTag("TAG", for: mac) } == refusal)
        #expect(await message { _ = try await model.fileVaultRecoveryKey(for: mac) } == refusal)
        #expect(await message { _ = try await model.recoveryLockPassword(for: mac) } == refusal)
        #expect(await message { _ = try await model.deviceLockPIN(for: mac) } == refusal)
        let account = JamfLocalAdminAccount(username: "admin", guid: "", source: "MDM")
        #expect(await message { _ = try await model.localAdminPassword(for: mac, account: account) } == refusal)
        #expect(await message { try await model.deleteMDMRecord(reports: [mac]) } == refusal)
        #expect(await message { try await model.sendCommand(.blankPush, reports: [mac]) } == refusal)
        #expect(await message { try await model.setSite(reports: [mac], to: "-1") } == refusal)
        #expect(harness.server.requests.isEmpty)
    }

    @Test("Removing an “Also on…” record reaches that record's server, not the toolbar's")
    func alsoOnRecordUsesItsOwnConnection() async throws {
        let harness = harness()
        // The working record on the toolbar's connection, a stale one on "Example Password Jamf Pro".
        var report = Devices.mac(on: SavedData.proClientID)
        let stale = ManagedDeviceInfo(recordID: "7", connectionID: SavedData.proPasswordID, kind: .computer)
        report.otherRecords = [stale]
        try await harness.model.removeRecord(stale, serial: report.serial)
        let deletes = harness.server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.url.host() == "jamf.example.com", "Example Password Jamf Pro's server")
        #expect(deletes.first?.path.hasSuffix("/computers-inventory/7") == true)
        #expect(!harness.server.requests.contains { $0.url.host() == "example.jamfcloud.com" && $0.method == "DELETE" })
    }

    @Test("A record's identity is its connection plus its record ID")
    func recordIdentity() {
        let onSandbox = ManagedDeviceInfo(recordID: "7", connectionID: SavedData.proClientID, kind: .computer)
        let onPassword = ManagedDeviceInfo(recordID: "7", connectionID: SavedData.proPasswordID, kind: .computer)
        let again = ManagedDeviceInfo(recordID: "7", connectionID: SavedData.proClientID, kind: .mobileDevice)
        #expect(onSandbox.key != onPassword.key, "the same record ID on two servers is two records")
        #expect(onSandbox.key == again.key)
        var report = DeviceReport(serial: "C02XK1JHJG5H")
        report.otherRecords = [onSandbox, onPassword]
        #expect(Set(report.otherRecords.map(\.key)).count == 2, "the inspector lists both")
    }
}
