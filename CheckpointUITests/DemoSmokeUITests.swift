import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// JTKit's Contoso organizations and connections, the same answers every run,
/// no tenant, nothing saved. Run one at a time by `Scripts/release-check.sh`;
/// minutes, not hours.
final class DemoSmokeUITests: JTKitUITestCase {
    override var appName: String { "Checkpoint" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(window(titled: "Checkpoint").waitForExistence(timeout: 20), "The main window did not open")
    }

    /// "x of y devices" above the table.
    private var deviceCount: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value MATCHES '[0-9]+ of [0-9]+ devices?' OR label MATCHES '[0-9]+ of [0-9]+ devices?'")).firstMatch
    }

    private func countText() -> String {
        (deviceCount.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? deviceCount.label
    }

    /// Every demo serial, looked up after the bulk-read consent (42 is more
    /// than the 15 that read the organization whole).
    private func lookUpSampleSerials(allConnections: Bool) {
        if allConnections {
            // The Connection menu holds the same items as the toolbar pickers.
            tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
            // "All Connections (Demo)" in demo mode.
            tap(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'All Connections'")).firstMatch)
        }
        tap(app.buttons["Sample Serials"], timeout: 20)
        tap(app.buttons["Look Up"].firstMatch)
        tap(dialogButton("Look Up"), timeout: 10)
        XCTAssertTrue(deviceCount.waitForExistence(timeout: 60), "The lookup showed no devices")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Clear"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed, "The lookup didn't finish")
    }

    func test1Launch() {
        XCTAssertTrue(app.buttons["Sample Serials"].waitForExistence(timeout: 20), "Demo mode's Sample Serials is missing")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Serial numbers'")).firstMatch.exists,
                      "The serial number field is missing")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        checkConnectionsEditor(service: "Jamf Pro") { settings in
            let server = settings.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'https://yourorg'")).firstMatch
            if server.waitForExistence(timeout: 5) { self.type("https://jtktest.example.com", into: server) }
            let client = settings.textFields["Client ID"].firstMatch
            if client.exists { self.type("jtktest-client", into: client) }
            let secret = settings.secureTextFields.firstMatch
            if secret.exists { self.type("jtktest-secret", into: secret) }
        }
    }

    /// Sample Serials across every connection: Apple, Jamf and Intune columns
    /// filled, findings shown, and the device last seen 131 days ago found by
    /// the "More than 90 days ago" filter.
    func test5MainTask() {
        lookUpSampleSerials(allConnections: true)
        let total = String(countText().split(separator: " ").first ?? "")
        XCTAssertEqual(countText(), "\(total) of \(total) devices", "Not every device is shown")
        // The column groups: Apple, the finding (All Connections only) and the MDM side.
        for header in ["Serial Number", "Finding", "Apple Business", "MDM Server Assignment", "Connection", "Device Name"] {
            XCTAssertTrue(any(header).waitForExistence(timeout: 10), "No \(header) column")
        }
        // Records from Jamf Pro and Intune, side by side.
        XCTAssertTrue(anyContaining("Jamf Pro").waitForExistence(timeout: 10), "No Jamf Pro record")
        XCTAssertTrue(anyContaining("Intune").waitForExistence(timeout: 10), "No Intune record")

        // The 131-day gap: the stale device under "More than 90 days ago".
        tap(app.menuButtons.matching(NSPredicate(format: "title BEGINSWITH 'Filter' OR label BEGINSWITH 'Filter'")).firstMatch, timeout: 10)
        // The Last Contact submenu (Date Added and the others have the same presets).
        let lastContact = app.menuItems["Last Contact"].firstMatch
        XCTAssertTrue(lastContact.waitForExistence(timeout: 10), "The filter has no Last Contact choice")
        lastContact.hover()
        let stale = lastContact.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'More than 90 days ago ('")).firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 10), "The filter offers no device last seen more than 90 days ago")
        let title = stale.title.isEmpty ? stale.label : stale.title
        XCTAssertFalse(title.hasSuffix("(0)"), "No device last seen more than 90 days ago")
        let count = String(title.split(separator: "(").last?.dropLast() ?? "")
        tap(stale)
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
                                                                        "\(count) of", "\(count) of"), object: deviceCount)
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 10), .completed,
                       "The filter's count (\(title)) doesn't match the list (\(countText()))")
    }

    func test6ActivityLog() {
        lookUpSampleSerials(allConnections: false)
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }
}
