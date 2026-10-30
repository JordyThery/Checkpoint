import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Checkpoint

// Fixes for what JTKit ROADMAP step 11 (the release check) found in
// Checkpoint, besides the record's connection (`RecordConnectionTests`).

/// Counts reads of Apple private keys.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private var reads = 0
    init(_ secrets: [String: String]) { self.secrets = secrets }
    var appleKeyReads: Int { lock.withLock { reads } }
    func secret(for account: String) -> String? {
        lock.withLock {
            if account.hasPrefix("abm.") { reads += 1 }
            return secrets[account]
        }
    }
    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock { secrets[account] = secret }
        return true
    }
}

@Suite("Fixes from the release check")
@MainActor
struct FindingsFixesTests {

    @Test("The Apple key check reads the Keychain once per organization, again only after a change")
    func appleKeyCheckIsKept() {
        let fixture = Fixture()
        let store = CountingSecretStore(["abm.\(SavedData.businessID.uuidString)": "PEM"])
        let settings = AppSettings(defaults: fixture.defaults, secrets: store)
        let model = LookupModel(settings: settings)
        model.abmScope = .organization(SavedData.businessID)
        for _ in 0..<5 { #expect(model.isABMConfigured) }
        #expect(store.appleKeyReads == 1, "one read for five redraws")

        // The key is deleted (Settings): the next check reads again.
        settings.secretStore.setSecret(nil, for: "abm.\(SavedData.businessID.uuidString)")
        #expect(!model.isABMConfigured)
        #expect(store.appleKeyReads == 2)
    }

    @Test("-JTKitSandbox is read as JTKit reads it: YES, true or 1; NO is an ordinary launch")
    func sandboxArgument() {
        #expect(UnderTest.isSandboxLaunch(["Checkpoint", "-JTKitSandbox", "YES"]))
        #expect(UnderTest.isSandboxLaunch(["Checkpoint", "-JTKitSandbox", "true"]))
        #expect(UnderTest.isSandboxLaunch(["Checkpoint", "-JTKitSandbox", "1"]))
        #expect(!UnderTest.isSandboxLaunch(["Checkpoint", "-JTKitSandbox", "NO"]))
        #expect(!UnderTest.isSandboxLaunch(["Checkpoint", "-JTKitSandbox"]))
        #expect(!UnderTest.isSandboxLaunch(["Checkpoint"]))
        // The same answer as JTKit's demo mode, which decides "— Demo" and saving.
        for value in ["YES", "NO", "true", "0"] {
            let arguments = ["Checkpoint", "-JTKitSandbox", value]
            let demo = DemoMode(key: "demoMode", defaults: Fixture().defaults, arguments: arguments)
            #expect(demo.isSandbox == UnderTest.isSandboxLaunch(arguments), "\(value)")
        }
    }

    @Test("Schedule Migration skips released devices, as Assign and Unassign do")
    func migrationSkipsReleased() async throws {
        let harness = AppleHarness()
        let deadline = Date().addingTimeInterval(7 * 24 * 3600)
        let capable = try AppleHarness.device("A", extra: #","isMdmMigrationCapable":true"#)
        let released = try AppleHarness.device("B", released: true, extra: #","isMdmMigrationCapable":true"#)
        try await harness.model.scheduleMigration(reports: [capable, released], to: "S2", deadline: deadline)
        #expect(harness.actions.first?.detail.hasPrefix("Scheduled migration of 1 device") == true)
        let sent = harness.activities.compactMap { body($0) }
        let devices = sent.flatMap { item -> [String] in
            let relationships = (item["data"] as? [String: Any])?["relationships"] as? [String: Any]
            return ((relationships?["devices"] as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        #expect(devices == ["A"])
        #expect(await message { try await harness.model.scheduleMigration(reports: [released], to: "S2", deadline: deadline) }
                == "None of the selected devices can be migrated.")
    }
}
