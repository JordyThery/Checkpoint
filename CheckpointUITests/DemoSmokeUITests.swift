import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests, in demo mode:
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

    /// "x of y devices" in the status bar.
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

    // MARK: More of the main features, in demo mode (2.10)

    /// Demo devices, from JTKit's `DemoWorld`: Macs 1 and 2 on Contoso Jamf
    /// Pro, an iPad on Contoso Academy Jamf School.
    private let mac1 = "ZZDEMOM01QW", mac2 = "ZZDEMOM02RX", academyIPad = "ZZDEMOD31QW"

    private var serialField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Serial numbers'")).firstMatch
    }

    private var fieldText: String { serialField.value as? String ?? "" }

    /// Waits until a lookup has finished (Clear is enabled again).
    private func waitForLookup() {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Clear"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed, "The lookup didn't finish")
    }

    /// A few serials, under the bulk threshold: no consent asked.
    private func lookUp(_ serials: [String]) {
        type(serials.joined(separator: " "), into: serialField)
        tap(app.buttons["Look Up"].firstMatch)
        XCTAssertTrue(deviceCount.waitForExistence(timeout: 60), "The lookup showed no devices")
        waitForLookup()
    }

    private func select(_ serial: String) {
        tap(app.staticTexts[serial].firstMatch, timeout: 30)
    }

    private func menu(_ menu: String, _ item: String) {
        tap(app.menuBars.menuBarItems[menu], timeout: 10)
        tap(app.menuItems[item].firstMatch)
    }

    /// The Lookup menu holds the window's actions; the status bar marks Demo Mode.
    func test8MenusAndStatusBar() {
        XCTAssertTrue(anyContaining("Demo Mode").waitForExistence(timeout: 10), "The status bar doesn't show Demo Mode")
        tap(app.menuBars.menuBarItems["Lookup"], timeout: 10)
        for item in ["Look Up", "Look Up Group…", "Look Up Order…", "Fill In Sample Serials", "Stop Waiting", "Clear List"] {
            XCTAssertTrue(app.menuItems[item].firstMatch.exists, "The Lookup menu has no \(item)")
        }
        app.typeKey(.escape, modifierFlags: [])
        menu("Lookup", "Fill In Sample Serials")
        XCTAssertTrue(fieldText.contains(mac1), "Fill In Sample Serials didn't fill the field")
        menu("Lookup", "Clear List")
        XCTAssertFalse(fieldText.contains(mac1), "Clear List didn't empty the field")
        tap(app.menuBars.menuBarItems["File"], timeout: 10)
        XCTAssertTrue(app.menuItems["Import Serial Numbers…"].firstMatch.exists, "File has no Import Serial Numbers…")
        XCTAssertFalse(app.menuItems["New Window"].firstMatch.exists, "One main window: File has no New Window")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// One device: the inspector's Apple and Jamf Pro sections.
    func test9Inspector() {
        lookUp([mac1])
        select(mac1)
        for label in ["Activation Lock", "History", "Identifiers", "MDM Commands", "Show FileVault Recovery Key"] {
            XCTAssertTrue(any(label).waitForExistence(timeout: 20), "The inspector has no \(label)")
        }
    }

    /// Blank Push through the real confirmation; the outcome in the status bar.
    func test10BlankPush() {
        lookUp([mac1])
        select(mac1)
        tap(app.buttons["Send Blank Push"].firstMatch, timeout: 20)
        tap(dialogButton("Send Blank Push"), timeout: 10)
        XCTAssertTrue(anyContaining("sent to \(mac1)").waitForExistence(timeout: 30), "The status bar doesn't say the command was sent")
    }

    /// A recovery secret opens in its sheet and closes with Done.
    func test11RecoveryKey() {
        lookUp([mac1])
        select(mac1)
        tap(app.buttons["Show FileVault Recovery Key"].firstMatch, timeout: 20)
        XCTAssertTrue(app.buttons["Copy"].firstMatch.waitForExistence(timeout: 20), "The key's sheet didn't open")
        tap(app.buttons["Done"].firstMatch)
        XCTAssertFalse(app.buttons["Copy"].firstMatch.waitForExistence(timeout: 3), "The key's sheet didn't close")
    }

    /// Delete Record on two devices asks for their number to be typed; Cancel sends nothing.
    func test12TypedConfirmation() {
        lookUp([mac1, mac2])
        select(mac1)
        XCUIElement.perform(withKeyModifiers: .command) { app.staticTexts[mac2].firstMatch.click() }
        let delete = app.buttons.matching(NSPredicate(format: "title BEGINSWITH 'Delete Record' OR label BEGINSWITH 'Delete Record'")).firstMatch
        tap(delete, timeout: 20)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "No confirmation sheet for two records")
        XCTAssertTrue(sheet.textFields.firstMatch.waitForExistence(timeout: 10), "The sheet doesn’t ask for the number")
        tap(sheet.buttons["Cancel"].firstMatch)
        XCTAssertTrue(app.staticTexts[mac2].firstMatch.exists, "A record went after Cancel")
    }

    /// All Organizations: a device of each organization, with the Organization column.
    func test13AllOrganizations() {
        tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
        tap(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'All Organizations'")).firstMatch)
        lookUp([mac1, academyIPad])
        XCTAssertTrue(any("Organization").waitForExistence(timeout: 10), "No Organization column")
        XCTAssertTrue(anyContaining("Contoso Academy").waitForExistence(timeout: 10), "The Apple School Manager device isn't found")
    }

    /// Look Up Order…: the organization is read after consent, an order fills the field.
    func test14Order() {
        menu("Lookup", "Look Up Order…")
        let read = app.buttons["Read Organization"].firstMatch
        if read.waitForExistence(timeout: 10) { tap(read) }
        let order = app.staticTexts["DEMO-1001"].firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: 90), "The orders weren't listed")
        order.doubleClick()
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", mac1), object: serialField)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 20), .completed, "The order's serials weren't filled in")
    }

    /// Look Up Group…: Contoso Jamf Pro's groups, one fills the field.
    func test15Group() {
        menu("Lookup", "Look Up Group…")
        let group = app.staticTexts["Design Macs"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30), "The groups weren't listed")
        group.doubleClick()
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", mac1), object: serialField)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 20), .completed, "The group's serials weren't filled in")
    }

    /// The Device menu offers the inspector's actions, through the same confirmation.
    func test16DeviceMenu() {
        lookUp([mac1])
        select(mac1)
        tap(app.menuBars.menuBarItems["Device"], timeout: 10)
        XCTAssertTrue(app.menuItems["Open in Jamf Pro"].firstMatch.exists, "The Device menu has no Open in Jamf Pro")
        XCTAssertTrue(app.menuItems["Unassign from MDM Server"].firstMatch.exists, "The Device menu has no Apple actions")
        tap(app.menuItems["Send Blank Push"].firstMatch)
        tap(dialogButton("Send Blank Push"), timeout: 10)
        XCTAssertTrue(anyContaining("sent to \(mac1)").waitForExistence(timeout: 30), "The status bar doesn't say the command was sent")
    }

    /// Opening more than 10 records asks first; Cancel opens nothing.
    func test17OpenManyRecordsAsks() {
        lookUpSampleSerials(allConnections: false)
        select(mac1)
        app.typeKey("a", modifierFlags: .command)
        tap(app.menuBars.menuBarItems["Device"], timeout: 10)
        tap(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Open'")).firstMatch)
        // the question's own button, e.g. "Open 23 Records"
        let ask = app.buttons.matching(NSPredicate(format: "label MATCHES 'Open [0-9]+ Records'")).firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "Opening many records didn't ask first")
        tap(dialogButton("Cancel"))
    }
}
