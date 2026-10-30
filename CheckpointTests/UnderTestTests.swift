import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Under tests Checkpoint sends no MDM command, makes no Apple write, reads no
// device secret and reaches no saved connection (JTKit ROADMAP step 11).
// These tests write their attempts to a log of their own, never to the one
// the release check reads.

@MainActor
private func temporaryLog() -> AttemptLog {
    // In this test process's folder, removed when it ends.
    AttemptLog(fileURL: TestSettings.folder.appending(path: "attempts-\(UUID().uuidString).jsonl"))
}

@MainActor
private func activeGuards(_ log: AttemptLog) -> UnderTestGuards {
    let on = ActionGuard(isActive: true, log: log)
    return UnderTestGuards(commands: on, appleWrites: on, secretReads: on)
}

@Suite("Under tests")
@MainActor
struct UnderTestTests {

    @Test("The unit tests' host runs under tests, with throwaway settings and no Keychain")
    func theHostIsUnderTests() {
        #expect(UnderTest.isActive)
        #expect(UnderTest.isUnitTestHost)
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
        #expect(model.session.configuration.protocolClasses?.first is SavedConnectionGuard.RefusingURLProtocol.Type)
        #expect(LookupModel(settings: Fixture().settings()).session === URLSession.shared)
    }

    @Test("A request to a saved connection is refused before it's sent and recorded without its query")
    func savedConnectionRefused() async {
        let log = temporaryLog()
        let session = SavedConnectionGuard.refusingSession(log: log)
        let url = URL(string: "https://example.jamfcloud.com/api/v1/computers-inventory?filter=hardware.serialNumber==\"C02SERIAL\"")!
        await #expect(throws: (any Error).self) { _ = try await session.data(from: url) }
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
        #expect(!log.attempts().contains { $0.what.contains("C02XK1JHJG5H") || $0.what.contains("DMPXK1JHJG5H") })
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
        await #expect(throws: UnderTestRefusal.self) { _ = try await jamf.send(.wipeComputer, to: [target], pin: "123456") }
        let schoolClient = try #require(JamfSchoolClient(config: school, secret: "SECRET", session: server.session, commandGuard: on))
        await #expect(throws: UnderTestRefusal.self) { _ = try await schoolClient.send(.unmanage, to: [target]) }
        #expect(server.requests.isEmpty)
        #expect(log.attempts().count == 2)
    }

    @Test("Every Apple write is refused before any request, in the model and in the client")
    func appleWritesRefused() async throws {
        let log = temporaryLog()
        let harness = AppleHarness(underTest: activeGuards(log))
        let reports = try [AppleHarness.device("A", server: "S1")]
        await #expect(throws: UnderTestRefusal.self) { try await harness.model.setMDMServer(reports: reports, to: nil) }
        await #expect(throws: UnderTestRefusal.self) { try await harness.model.setMDMServer(reports: reports, to: "S2") }
        await #expect(throws: UnderTestRefusal.self) { try await harness.model.releaseFromABM(reports: reports) }
        #expect(harness.activities.isEmpty)

        let client = ABMClient(clientID: "BUSINESSAPI.test", keyID: "k", privateKey: { "" },
                               session: harness.server.session, writeGuard: ActionGuard(isActive: true, log: log))
        await #expect(throws: UnderTestRefusal.self) { try await client.submitActivity(.assign, serials: ["A"], mdmServerID: "S1") }
        #expect(harness.server.requests.isEmpty)
        #expect(log.attempts().count == 4)
        #expect(!log.attempts().contains { $0.what.contains("\"A\"") })
    }

    @Test("Device secrets are not read under tests")
    func secretReadsRefused() async throws {
        let log = temporaryLog()
        let harness = CommandHarness(underTest: activeGuards(log))
        let mac = Devices.mac()
        await #expect(throws: UnderTestRefusal.self) { _ = try await harness.model.fileVaultRecoveryKey(for: mac) }
        await #expect(throws: UnderTestRefusal.self) { _ = try await harness.model.recoveryLockPassword(for: mac) }
        await #expect(throws: UnderTestRefusal.self) { _ = try await harness.model.deviceLockPIN(for: mac) }
        let account = JamfLocalAdminAccount(username: "admin", guid: "", source: "MDM")
        await #expect(throws: UnderTestRefusal.self) { _ = try await harness.model.localAdminPassword(for: mac, account: account) }
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
