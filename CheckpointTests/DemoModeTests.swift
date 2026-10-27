import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import Checkpoint

// Demo Mode (ROADMAP step 10): the lookup engine runs against JTKit's demo
// servers and DemoWorld, with the saved connections, the choices and the
// Keychain left as they are.

/// Saved connections and a Keychain like a real setup, then demo mode on.
@MainActor
private final class DemoHarness {
    let fixture = Fixture()
    let settings: AppSettings
    let model: LookupModel
    /// What was saved before demo mode was switched on.
    let savedBefore: [String: Data?]
    let secretsBefore: [String: String]

    static let savedKeys = ["abmOrgs", "jamfServers", "appleConnectionChoice", "mdmConnectionChoice"]

    init(on: Bool = true) {
        fixture.secrets.setSecret("real-key", for: "abm.\(SavedData.businessID.uuidString)")
        fixture.secrets.setSecret("real-secret", for: "jamf.\(SavedData.proClientID.uuidString)")
        settings = fixture.settings()
        settings.appleChoiceID = SavedData.businessID
        settings.mdmChoiceID = SavedData.proClientID
        // Apple's watch waits between checks; a demo test needn't.
        model = LookupModel(settings: settings, abmClock: ABMClock(now: { Date() }, sleep: { _ in }))
        let defaults = fixture.defaults
        savedBefore = Dictionary(uniqueKeysWithValues: Self.savedKeys.map { key in
            (key, defaults.object(forKey: key).map { "\($0)".data(using: .utf8) ?? Data() })
        })
        secretsBefore = fixture.secrets.all
        settings.demo.isOn = on
    }

    /// Every saved connection, choice and Keychain item is as it was.
    func expectUnchanged(sourceLocation: SourceLocation = #_sourceLocation) {
        for key in Self.savedKeys {
            let now = fixture.defaults.object(forKey: key).map { "\($0)".data(using: .utf8) ?? Data() }
            #expect(now == savedBefore[key] ?? nil, "\(key)", sourceLocation: sourceLocation)
        }
        #expect(fixture.secrets.all == secretsBefore, "Keychain", sourceLocation: sourceLocation)
        #expect(!fixture.secrets.all.values.contains { $0.contains("PRIVATE KEY") }, sourceLocation: sourceLocation)
    }

    func useAll() {
        model.abmScope = .allOrganizations
        model.mdmScope = .allConnections
    }

    func report(_ device: DemoWorld.Device) throws -> DeviceReport {
        try #require(model.reports.first { $0.serial == device.serial })
    }

    deinit {
        MainActor.assumeIsolated { settings.demo.isOn = false }
    }
}

@MainActor
@Suite("Demo mode", .serialized)
struct DemoModeTests {
    @Test("Both roles switch to the demo organizations and connections; the saved ones stay")
    func switchesRoles() {
        let harness = DemoHarness()
        let model = harness.model
        #expect(model.abmOrgs.map(\.displayName) == ["Contoso (Demo)", "Contoso Academy (Demo)"])
        #expect(model.mdmConnections.map(\.displayName)
                == ["Contoso Jamf Pro (Demo)", "Contoso Intune (Demo)", "Contoso Academy (Demo)"])
        #expect(model.selectedABMOrg?.id == Connection.demoAppleBusiness.id, "starts on Contoso")
        #expect(model.selectedConnection?.id == Connection.demoJamfPro.id, "starts on Contoso Jamf Pro")
        #expect(!model.readsAllABMOrgs && !model.readsAllConnections, "All is a choice, not the default")
        #expect(model.isABMConfigured)
        harness.useAll()
        #expect(model.readsAllABMOrgs && model.readsAllConnections)
        harness.expectUnchanged()
        harness.settings.demo.isOn = false
        #expect(model.abmOrgs.map(\.id).contains(SavedData.businessID))
        #expect(model.selectedABMOrg?.id == SavedData.businessID && model.selectedConnection?.id == SavedData.proClientID)
        #expect(!model.readsAllABMOrgs, "the demo's All isn't the saved roles' All")
    }

    @Test("Choosing a saved connection leaves demo mode; the demo's choices aren't saved")
    func savedConnectionLeavesDemo() {
        let harness = DemoHarness()
        harness.model.abmScope = .organization(Connection.demoAppleSchool.id)
        #expect(harness.settings.demo.isOn && harness.model.selectedABMOrg?.kind == .school)
        harness.expectUnchanged()
        harness.model.mdmRole.selection.wrappedValue = SavedData.intuneID
        harness.model.abmScope = .organization(SavedData.schoolID)
        #expect(!harness.settings.demo.isOn)
        #expect(harness.settings.appleChoiceID == SavedData.schoolID)
    }

    @Test("All 41 devices with every organization and connection: each gap shows as designed")
    func gaps() async throws {
        let harness = DemoHarness()
        harness.useAll()
        let model = harness.model
        #expect(model.needsOrganizationRead(forDeviceCount: LookupModel.demoSerials.count), "the consent dialog still comes")
        await model.lookUp(serialsText: LookupModel.demoSerials.joined(separator: "\n"))
        #expect(model.reports.count == 41)

        for device in DemoWorld.missingFromIntune {
            let report = try harness.report(device)
            #expect(report.abm.value?.mdmServerName == "Contoso Intune")
            guard case .notFound = report.mdm else { Issue.record("\(device.serial) has an MDM record"); continue }
        }
        let unassigned = try harness.report(DemoWorld.unassigned[0])
        #expect(unassigned.abm.value.map { $0.mdmServerID == nil && !$0.isReleased && !$0.assignmentUnknown } == true)
        let released = try harness.report(DemoWorld.releasePending[0])
        #expect(released.abm.value?.isReleased == true)
        #expect(released.mdm.value?.connectionID == Connection.demoJamfPro.id, "still in Jamf Pro")
        let outside = try harness.report(DemoWorld.notInApple[0])
        guard case .notFound = outside.abm else { Issue.record("in an Apple organization"); return }
        #expect(outside.mdm.value != nil)

        var stale = DeviceFilters()
        stale.lastContact = .overNinetyDays
        #expect(model.reports.filter(stale.matches).map(\.serial) == DemoWorld.stale.map(\.serial))

        let expired = try harness.report(DemoWorld.appleCareExpired[0])
        let coverage = try #require(try await model.appleCareCoverage(for: expired))
        #expect(coverage.first?.status == "INACTIVE")

        // The rest match: Apple's server and the MDM holding the record agree.
        let academy = try harness.report(DemoWorld.devices(in: .academy)[0])
        #expect(academy.abm.value?.orgName == "Contoso Academy (Demo)")
        #expect(academy.mdm.value?.connectionID == Connection.demoJamfSchool.id)
        harness.expectUnchanged()
    }

    @Test("A command and a delete go to the demo Jamf Pro, with the real confirmation")
    func commands() async throws {
        let harness = DemoHarness()
        let model = harness.model
        let mac = DemoWorld.devices(managedBy: .jamfPro).first(where: \.isComputer)!
        await model.lookUp(serialsText: mac.serial)
        let report = try harness.report(mac)
        // A destructive command's confirmation names the connection: the demo one.
        let confirmation = try #require(model.commandConfirmation(.wipeComputer, reports: [report]))
        #expect(confirmation.connectionLine?.contains("Contoso Jamf Pro (Demo)") == true)
        #expect(try await model.sendCommand(.redeployFramework, reports: [report]) == 1)
        #expect(model.settings.demo.jamfProServer.commands.last?.command == "REDEPLOY_FRAMEWORK")
        try await model.deleteMDMRecord(reports: [try harness.report(mac)])
        #expect(model.settings.demo.jamfProServer.isManaged(serial: mac.serial) == nil)
        harness.expectUnchanged()
    }

    @Test("Secrets read back obviously fake values")
    func secrets() async throws {
        let harness = DemoHarness()
        let model = harness.model
        let mac = DemoWorld.devices(managedBy: .jamfPro).first(where: \.isComputer)!
        await model.lookUp(serialsText: mac.serial)
        let report = try harness.report(mac)
        #expect(try await model.fileVaultRecoveryKey(for: report).personalRecoveryKey == DemoJamfProServer.FakeSecret.fileVaultKey)
        #expect(try await model.recoveryLockPassword(for: report) == DemoJamfProServer.FakeSecret.recoveryLock)
        #expect(try await model.deviceLockPIN(for: report) == DemoJamfProServer.FakeSecret.deviceLockPIN)
        let account = try #require(await model.localAdminAccounts(for: report).first)
        #expect(try await model.localAdminPassword(for: report, account: account) == DemoJamfProServer.FakeSecret.localAdminPassword)
        harness.expectUnchanged()
    }

    @Test("An Apple assignment runs against the demo organization and the row follows")
    func appleActivity() async throws {
        let harness = DemoHarness()
        let model = harness.model
        let iPad = DemoWorld.unassigned[0]
        await model.lookUp(serialsText: iPad.serial)
        try await model.setMDMServer(reports: [try harness.report(iPad)], to: DemoWorld.jamfProServerID)
        #expect(model.settings.demo.appleBusinessServer.assignedServer(serial: iPad.serial) == DemoWorld.jamfProServerID)
        #expect(try harness.report(iPad).abm.value?.mdmServerName == "Contoso Jamf Pro")
        let entry = try #require(model.log.entries.last { $0.category == "Action" })
        #expect(entry.connection == "Contoso (Demo)")
        harness.expectUnchanged()
    }

    @Test("Apple actions stay in one organization: a selection across both demo organizations is blocked")
    func oneOrganization() async throws {
        let harness = DemoHarness()
        harness.useAll()
        let business = DemoWorld.devices(in: .contoso)[0], school = DemoWorld.devices(in: .academy)[0]
        await harness.model.lookUp(serialsText: "\(business.serial) \(school.serial)")
        let reason = harness.model.appleActionUnavailableReason(for: [try harness.report(business), try harness.report(school)])
        #expect(reason?.contains("Contoso (Demo)") == true && reason?.contains("Contoso Academy (Demo)") == true)
    }

    @Test("Apple's limit: off for a demo organization only, kept for a real one and Test Connection")
    func rateLimit() throws {
        let harness = DemoHarness()
        harness.fixture.secrets.setSecret("real-key", for: "abm.\(SavedData.businessID.uuidString)")
        let demoClient = try #require(harness.model.makeABMClient(for: LookupModel.demoOrgs[0]))
        #expect(demoClient.client.rateLimit == nil)
        let real = try #require(harness.settings.abmOrgs.first { $0.id == SavedData.businessID })
        let realClient = try #require(harness.model.makeABMClient(for: real), "demo mode is on")
        #expect(realClient.client.rateLimit == ABM.rateLimit)
        // Settings › Test Connection builds its client like this, with the typed key.
        #expect(ABMClient(clientID: real.clientID, keyID: real.keyID, privateKeyPEM: "k").client.rateLimit == ABM.rateLimit)
    }

    @Test("A demo connection never reads the Keychain; a saved one never reaches the demo network")
    func noCrossing() throws {
        let harness = DemoHarness()
        let demoOrg = CheckpointConnection.apple(LookupModel.demoOrgs[0])
        #expect(harness.model.secret(for: demoOrg)?.contains("BEGIN PRIVATE KEY") == true)
        #expect(harness.fixture.secrets.secret(for: CheckpointSecrets.account(for: demoOrg.connection)) == nil)
        #expect(harness.settings.demo.source(for: CheckpointConnection.mdm(harness.settings.mdmConnections[0]).connection) == nil)
        #expect(throws: ConnectionStoreError.self) { try harness.settings.connections.save(demoOrg) }
        harness.expectUnchanged()
    }

    @Test("Switching demo mode empties the table")
    func clearsTable() async {
        let harness = DemoHarness()
        await harness.model.lookUp(serialsText: DemoWorld.devices[0].serial)
        #expect(!harness.model.reports.isEmpty)
        harness.settings.demo.isOn = false
        harness.model.demoModeChanged()
        #expect(harness.model.reports.isEmpty)
    }
}
