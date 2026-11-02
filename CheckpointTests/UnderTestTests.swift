import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Under tests Checkpoint sends no MDM command, makes no Apple write, reads no
// device secret and reaches no saved connection.
// These tests write their attempts to a log of their own, never to the one
// the release check reads.

@MainActor
private func temporaryLog() -> TestRun.AttemptLog {
    // In this test process's folder, removed when it ends.
    TestRun.AttemptLog(fileURL: TestSettings.folder.appending(path: "attempts-\(UUID().uuidString).jsonl"))
}

@MainActor
private func activeGuards(_ log: TestRun.AttemptLog) -> UnderTestGuards {
    let on = ActionGuard(isActive: true, log: log)
    return UnderTestGuards(commands: on, appleWrites: on, secretReads: on, recordWrites: on)
}

@Suite("Under tests")
@MainActor
struct UnderTestTests {

    @Test("The unit tests' host runs under tests, with throwaway settings and no Keychain")
    func theHostIsUnderTests() {
        #expect(UnderTest.isActive)
        #expect(TestRun.isUnitTestHost)
        #expect(!AppSettings.shared.holdsSavedConnections)
        #expect(AppSettings.shared.mdmConnections.isEmpty && AppSettings.shared.abmOrgs.isEmpty)
    }

    @Test("What counts as the saved connections: the app's own settings or its Keychain items")
    func whatCountsAsSaved() {
        #expect(!Fixture().settings().holdsSavedConnections)
        let keychain = AppSettings(defaults: Fixture().defaults,
                                   secrets: KeychainSecretStore(service: "CheckpointTests.never-written"))
        #expect(keychain.holdsSavedConnections)
        // A model on such settings gets the refusing network.
        let model = LookupModel(settings: keychain, session: commandServer().session)
        // JTKit's refusing protocol (internal to JTKit, so known by its name).
        #expect(model.session.configuration.protocolClasses?.first.map { String(describing: $0) } == "RefusingURLProtocol")
        #expect(LookupModel(settings: Fixture().settings()).session === URLSession.shared)
    }

    @Test("Test Connection on the saved connections gets the refusing network; on other settings the normal one")
    func testConnectionSession() {
        let keychain = AppSettings(defaults: Fixture().defaults,
                                   secrets: KeychainSecretStore(service: "CheckpointTests.never-written"))
        // Nothing is sent: a request would be recorded in the release check's log.
        let refusing = keychain.testConnectionSession
        #expect(refusing !== URLSession.shared)
        #expect(refusing.configuration.protocolClasses?.first.map { String(describing: $0) } == "RefusingURLProtocol")
        #expect(Fixture().settings().testConnectionSession === URLSession.shared)
    }

    @Test("A request to a saved connection is refused before it's sent and recorded without its query")
    func savedConnectionRefused() async {
        let log = temporaryLog()
        let session = UnderTest.refusingSession(log: log)
        let url = URL(string: "https://example.jamfcloud.com/api/v1/computers-inventory?filter=hardware.serialNumber==\"TESTSERIAL01\"")!
        // Fails as no answer, with the refusal as its message.
        let error = await #expect(throws: URLError.self) { _ = try await session.data(from: url) }
        #expect(error?.code == .resourceUnavailable)
        #expect(error?.localizedDescription == UnderTest.refusal)
        #expect(log.attempts().map(\.what) == ["GET example.jamfcloud.com/api/v1/computers-inventory"])
    }

    @Test("Every MDM command is refused on every product, before any request, and recorded")
    func commandsRefused() async {
        let log = temporaryLog()
        let harness = CommandHarness(underTest: activeGuards(log))
        let cases: [(MDMCommand, DeviceReport)] = [
            (.wipeComputer, Devices.mac()),
            (.unmanage, Devices.mac()),
            (.lockComputer, Devices.mac()),
            (.restartMobile, Devices.mobile()),
            (.clearPasscode, Devices.mobile()),
            (.wipeMobile, Devices.mobile(on: SavedData.schoolServerID)),
            (.restartMobile, Devices.mobile(on: SavedData.intuneID)),
        ]
        for (command, report) in cases {
            #expect(await harness.send(command, [report]) == UnderTest.refusal)
        }
        #expect(harness.server.requests.isEmpty)
        #expect(log.attempts().count == cases.count)
        #expect(!log.attempts().contains { $0.what.contains("TESTMAC0001") || $0.what.contains("TESTIPAD001") })
    }

    @Test("Record changes are refused before any request: delete, trash, site, PreStage, location, asset tag")
    func recordWritesRefused() async throws {
        let log = temporaryLog()
        let harness = CommandHarness(underTest: activeGuards(log))
        let model = harness.model
        let mac = Devices.mac()
        let ipad = Devices.mobile(on: SavedData.schoolServerID)
        let intune = Devices.mobile(on: SavedData.intuneID)
        for report in [mac, ipad, intune] {
            let approval = try model.deleteConfirmation(reports: [report]).map { try CommandHarness.approve($0) }
            #expect(await message { try await model.deleteMDMRecord(reports: [report], approval: approval) }?
                .contains(UnderTest.refusal) == true)
        }
        #expect(await message { try await model.setSite(reports: [mac], to: "5") } == UnderTest.refusal)
        #expect(await message { try await model.setPrestage(reports: [mac], to: "3", kind: .computer) } == UnderTest.refusal)
        #expect(await message { try await model.setLocation(reports: [ipad], to: "2") } == UnderTest.refusal)
        #expect(await message { try await model.setAssetTag("TAG-1", for: mac) } == UnderTest.refusal)
        #expect(!harness.server.requests.contains { ["DELETE", "PUT", "PATCH", "POST"].contains($0.method) && !$0.path.hasSuffix("token") })
        #expect(log.attempts().count == 7)
    }

    @Test("The Jamf Pro and Jamf School clients refuse commands too")
    func clientsRefuse() async throws {
        let log = temporaryLog()
        let server = commandServer()
        let fixture = Fixture()
        let connections = fixture.settings().mdmConnections
        let pro = try #require(connections.first { $0.id == SavedData.proClientID })
        let school = try #require(connections.first { $0.id == SavedData.schoolServerID })
        let on = ActionGuard(isActive: true, log: log)
        let jamf = try #require(JamfClient(config: pro, secret: { "SECRET" }, session: server.session, commandGuard: on))
        let target = MDMCommand.Target(serial: "C02", recordID: "7", kind: .computer)
        let wipe = try MDMCommand.Confirmation(.wipeComputer, plan: MDMCommand.wipeComputer.plan(for: [target], on: .jamfPro),
                                               on: .jamfPro, connectionName: nil).approve(pin: "123456", pinAgain: "123456")
        await #expect(throws: TestRun.Refusal.self) { _ = try await jamf.send(.wipeComputer, to: [target], approval: wipe) }
        let schoolClient = try #require(JamfSchoolClient(config: school, secret: "SECRET", session: server.session, commandGuard: on))
        let unmanage = try MDMCommand.Confirmation(.unmanage, plan: MDMCommand.unmanage.plan(for: [target], on: .jamfSchool),
                                                   on: .jamfSchool, connectionName: nil).approve()
        await #expect(throws: TestRun.Refusal.self) { _ = try await schoolClient.send(.unmanage, to: [target], approval: unmanage) }
        #expect(server.requests.isEmpty)
        #expect(log.attempts().count == 2)
    }

    @Test("Every Apple write is refused before any request, in the model and in the client")
    func appleWritesRefused() async throws {
        let log = temporaryLog()
        let harness = AppleHarness(underTest: activeGuards(log))
        let reports = try [AppleHarness.device("A", server: "S1")]
        await #expect(throws: TestRun.Refusal.self) { try await harness.model.setMDMServer(reports: reports, to: nil) }
        await #expect(throws: TestRun.Refusal.self) { try await harness.model.setMDMServer(reports: reports, to: "S2") }
        await #expect(throws: TestRun.Refusal.self) { try await harness.model.releaseFromABM(reports: reports) }
        #expect(harness.activities.isEmpty)

        let client = ABMClient(clientID: "BUSINESSAPI.test", keyID: "k", privateKey: { "" },
                               session: harness.server.session, writeGuard: ActionGuard(isActive: true, log: log))
        await #expect(throws: TestRun.Refusal.self) { try await client.submitActivity(.assign, serials: ["A"], mdmServerID: "S1") }
        #expect(harness.server.requests.isEmpty)
        #expect(log.attempts().count == 4)
        #expect(!log.attempts().contains { $0.what.contains("\"A\"") })
    }

    @Test("Device secrets are not read under tests")
    func secretReadsRefused() async throws {
        let log = temporaryLog()
        let harness = CommandHarness(underTest: activeGuards(log))
        let mac = Devices.mac()
        await #expect(throws: TestRun.Refusal.self) { _ = try await harness.model.fileVaultRecoveryKey(for: mac) }
        await #expect(throws: TestRun.Refusal.self) { _ = try await harness.model.recoveryLockPassword(for: mac) }
        await #expect(throws: TestRun.Refusal.self) { _ = try await harness.model.deviceLockPIN(for: mac) }
        let account = JamfLocalAdminAccount(username: "admin", guid: "", source: "MDM")
        await #expect(throws: TestRun.Refusal.self) { _ = try await harness.model.localAdminPassword(for: mac, account: account) }
        #expect(harness.server.requests.isEmpty)
        #expect(log.attempts().map(\.what) == ["FileVault recovery key (Jamf Pro)", "Recovery Lock password (Jamf Pro)",
                                               "Device lock PIN (Jamf Pro)", "Local administrator password (Jamf Pro)"])
    }

    @Test("Off outside tests: nothing is refused or recorded")
    func offOutsideTests() throws {
        let log = temporaryLog()
        try ActionGuard(isActive: false, log: log).check("Erase")
        #expect(log.attempts().isEmpty)
    }

    @Test("Test settings stay out of Preferences")
    func testSettingsStayOutOfPreferences() throws {
        let fixture = Fixture()
        fixture.defaults.set(true, forKey: "configurationHintDismissed")
        #expect(fixture.domain.hasPrefix(TestSettings.root.path))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: TestSettings.preferencesFolder.path)) ?? []
        #expect(!files.contains { $0.contains(URL(filePath: fixture.domain).lastPathComponent) })
    }
}

// MARK: - Commands under the live switch (2.10.0)

@Suite("Commands under the live switch")
@MainActor
struct LiveCommandGuardTests {

    @Test("Through a connection that receives commands: only Blank Push and Update Inventory pass")
    func onlyTheTwoPass() throws {
        let guards = activeGuards(temporaryLog()).forConnection(receivesCommands: true)
        try guards.commands.check(.blankPush, "Blank Push")
        try guards.commands.check(.updateInventory, "Update Inventory")
        for command in MDMCommand.allCases where ![.blankPush, .updateInventory].contains(command) {
            #expect(throws: TestRun.Refusal.self, "\(command) is refused") { try guards.commands.check(command, "\(command)") }
        }
        #expect(throws: TestRun.Refusal.self, "an Apple write is refused") { try guards.appleWrites.check("Apple Assign") }
        #expect(throws: TestRun.Refusal.self) { try guards.recordWrites.check("Delete Record") }
        #expect(throws: TestRun.Refusal.self) { try guards.secretReads.check("FileVault key") }
    }

    @Test("Through a connection without test devices, or outside the switch: Blank Push is refused")
    func refusedElsewhere() {
        let guards = activeGuards(temporaryLog()).forConnection(receivesCommands: false)
        #expect(throws: TestRun.Refusal.self) { try guards.commands.check(.blankPush, "Blank Push") }
        #expect(throws: TestRun.Refusal.self) { try guards.commands.check(.updateInventory, "Update Inventory") }
        // the unit-test host is under tests and not under the switch. The
        // shared guard isn't called: it writes to the log the release check reads.
        #expect(UnderTestGuards.shared.commands.isActive)
        #expect(UnderTestGuards.shared.commands.allowedCommands.isEmpty)
        #expect(!LiveLaunch.receivesCommands(SavedData.schoolServerID))
        #expect(UnderTestGuards.shared.forConnection(receivesCommands: false).commands.allowedCommands.isEmpty)
    }

    @Test("The model refuses Blank Push under tests outside the switch, before anything is sent")
    func modelRefuses() async {
        let log = temporaryLog()
        let harness = CommandHarness(underTest: activeGuards(log))
        let message = await harness.send(.blankPush, [Devices.mac()])
        #expect(message == UnderTest.refusal)
        #expect(harness.sent.isEmpty)
    }

    @Test("The live allowance is exactly Blank Push and Update Inventory")
    func theAllowance() {
        #expect(UnderTest.liveCommands == [.blankPush, .updateInventory])
    }
}
