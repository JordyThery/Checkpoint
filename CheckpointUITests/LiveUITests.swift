import XCTest
import JTKitLiveCheck
import JTKitUITestSupport

/// Live UI tests: the real app under JTKit's live-check switch, against the
/// release check's tenants, through its gateway. Run only by
/// `Scripts/release-check.sh` (skipped on ⌘U).
///
/// - Lookups on the read roles: Jamf Pro production, Jamf School, the Intune
///   test tenant, Apple Business and Apple School Manager. Reads only.
/// - Non-interruptive commands through the app's own confirmation, to one
///   listed test device per tenant: Blank Push on Jamf Pro, Update Inventory
///   (the device refresh) on Jamf School, Sync Device on Intune. No
///   interruptive command and no Apple write, ever: the app lets only those
///   two commands through under the switch, and the gateway sends commands
///   only to the allow-list's test devices.
///
/// Serials come from the allow-list's test devices through the gateway, are
/// kept in memory and never written to a report or a failure message: they
/// are pasted, rows are found by count and position, and a live UI test
/// keeps no screenshot or element dump (the scheme keeps no automatic
/// screenshots; JTKit 1.3.2 attaches none on failure).
final class LiveUITests: JTKitUITestCase {
    override var appName: String { "Checkpoint" }
    override var launchesLive: Bool { true }

    private enum Role {
        static let production = "jamfpro-production"
        static let school = "jamfschool-readonly"
        static let intune = "intune-test"
        static let business = "apple-business"
        static let appleSchool = "apple-school"
    }

    /// The roles of this run (production only with --include-production).
    private var runRoles: Set<String> {
        Set((ProcessInfo.processInfo.environment["JTKIT_LIVE_ROLES"] ?? "").split(separator: ",").map(String.init))
    }

    /// A role's test devices, from the allow-list through the gateway (the
    /// runner is sandboxed and can't read the allow-list itself).
    private func testSerials(_ role: String) throws -> [String] {
        let gateway = try liveGateway()
        return try liveCall { try await gateway.testDevices(role: role) }.map(\.serial)
    }

    private var serialField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Serial numbers'")).firstMatch
    }

    private func choose(menuItemStartingWith title: String) {
        tap(app.menuBars.menuBarItems["Connection"], timeout: 20)
        tap(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", title)).firstMatch)
    }

    /// Looks the serials up and waits until the app's requests are done.
    private func lookUp(_ serials: [String]) {
        // pasted, not typed: XCTest's activity log records what is typed
        paste(serials.joined(separator: " "), into: serialField)
        tap(app.buttons["Look Up"].firstMatch)
        waitForNetwork(timeout: 300)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Clear"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 120), .completed, "The lookup didn't finish")
    }

    /// Every read role's test devices, looked up in all of them at once.
    func testReadOnlyLookups() throws {
        _ = try liveGateway()
        let roles = [Role.production, Role.school, Role.intune, Role.business, Role.appleSchool].filter(runRoles.contains)
        let serials = try [Role.production, Role.school, Role.intune].filter(runRoles.contains).flatMap(testSerials)
        guard !serials.isEmpty else {
            recordLive(step: "read-only lookups", passed: true, note: "no test devices in this run's roles: nothing to look up")
            return
        }
        try launchLive(roles: roles)
        if roles.contains(Role.business) || roles.contains(Role.appleSchool) { choose(menuItemStartingWith: "All Organizations") }
        choose(menuItemStartingWith: "All Connections")
        lookUp(serials)
        // counted in the status bar ("4 of 4 devices"), never found by serial:
        // a query names its text in XCTest's activity log
        let count = app.staticTexts.matching(NSPredicate(format: "value ENDSWITH ' devices' OR label ENDSWITH ' devices'")).firstMatch
        let shown = count.waitForExistence(timeout: 10)
            ? Int(((count.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? count.label).split(separator: " ").first ?? "") ?? 0
            : 0
        let missing = max(serials.count - shown, 0)
        let noRecord = app.staticTexts["No record"].firstMatch.exists
        let passed = missing == 0 && !noRecord
        recordLive(step: "read-only lookups", passed: passed,
                   note: "\(serials.count) test devices on \(roles.count) roles; \(missing) rows missing\(noRecord ? "; a device has no record" : "")")
        XCTAssertTrue(passed, "Lookup: \(missing) of \(serials.count) rows missing; no record: \(noRecord)")
    }

    /// One non-interruptive command per tenant, through the app's confirmation.
    func testNonInterruptiveCommands() throws {
        _ = try liveGateway()
        // (role, connection name in the menu, the command's button and dialog title)
        let plans: [(role: String, connection: String, command: String)] = [
            (Role.production, "\(Role.production) (Jamf Pro)", "Send Blank Push"),
            (Role.school, Role.school, "Update Inventory"),
            (Role.intune, Role.intune, "Sync Device"),
        ]
        // which roles receive a command in this run, for the report
        let receiving = try plans.map(\.role).filter { runRoles.contains($0) && !(try testSerials($0)).isEmpty }
        recordLive(step: "roles that receive a device command", passed: true,
                   note: receiving.isEmpty ? "none" : receiving.joined(separator: ", ") + " (one test device each, non-interruptive only)")
        var ran = 0
        for plan in plans where runRoles.contains(plan.role) {
            guard let serial = try testSerials(plan.role).first else { continue }
            try launchLive(roles: [plan.role])
            choose(menuItemStartingWith: plan.connection)
            lookUp([serial])
            // the one row, by position (a query by serial would name it in the log)
            tap(app.tables.firstMatch.tableRows.firstMatch, timeout: 30)
            tap(app.buttons[plan.command].firstMatch, timeout: 30)
            tap(dialogButton(plan.command), timeout: 10)
            waitForNetwork()
            let sent = anyContaining("\(plan.command): sent to").waitForExistence(timeout: 60)
            recordLive(step: "\(plan.command) on \(plan.role)", passed: sent,
                       note: sent ? "sent to its test device" : "the app didn't report it sent")
            XCTAssertTrue(sent, "\(plan.command) on \(plan.role) wasn't reported sent")
            ran += 1
            app.terminate()
        }
        if ran == 0 {
            recordLive(step: "non-interruptive commands", passed: true, note: "no role with a test device in this run")
        }
    }
}
