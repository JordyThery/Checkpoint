import XCTest
import JTKitUITestSupport

/// Captures the README and docs screenshots (docs/screenshot*.png) in demo
/// mode: Contoso's sample organizations and connections, no tenant. Not part
/// of the release check. Run with
/// `xcodebuild test -scheme "Checkpoint Release Check" -only-testing:CheckpointUITests/ScreenshotUITests`
/// and export the result bundle's attachments; keep hands off the Mac while it runs.
final class ScreenshotUITests: JTKitUITestCase {
    override var appName: String { "Checkpoint" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "The main window did not open")
        // Room for the table's columns and the inspector.
        tap(app.menuBars.menuBarItems["Window"], timeout: 10)
        tap(app.menuItems["Zoom"].firstMatch)
        Thread.sleep(forTimeInterval: 1)
    }

    private var mainWindow: XCUIElement { window(titled: "Checkpoint") }

    /// JTKit's `DemoWorld.serial(_:_:)`: device numbers 1–42, family M, P or D.
    private func serial(_ number: Int, _ family: Character) -> String {
        let letters = Array("KQRMXTVWHJ")
        return "ZZDEMO\(family)\(String(format: "%02d", number))\(letters[number % 10])\(letters[(number * 7) % 10])"
    }

    private func capture(_ name: String, _ element: XCUIElement) {
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A Connection menu item; "Contoso Academy (Demo)" is in both roles, Apple first.
    private func choose(_ title: String, index: Int = 0) {
        tap(app.menuBars.menuBarItems["Connection"], timeout: 10)
        tap(app.menuItems.matching(NSPredicate(format: "title == %@", title)).element(boundBy: index))
    }

    private var serialField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Serial numbers'")).firstMatch
    }

    /// Fewer than 15 serials: no bulk-read consent.
    private func lookUp(_ serials: [String]) {
        type(serials.joined(separator: " "), into: serialField)
        tap(app.buttons["Look Up"].firstMatch)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Clear"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed, "The lookup didn't finish")
    }

    /// Selects a row and waits for the inspector's per-device reads.
    private func select(_ serial: String, waitingFor label: String) {
        tap(app.staticTexts[serial].firstMatch, timeout: 30)
        XCTAssertTrue(any(label).waitForExistence(timeout: 20), "The inspector has no \(label)")
        Thread.sleep(forTimeInterval: 2)
    }

    /// Contoso's 14 Macs in Apple Business and Jamf Pro, the inspector open.
    func test1JamfPro() {
        lookUp((1...14).map { serial($0, "M") })
        select(serial(1, "M"), waitingFor: "MDM Commands")
        capture("screenshot", mainWindow)
    }

    /// Contoso Academy in Apple School Manager and Jamf School.
    func test2JamfSchool() {
        choose("Contoso Academy (Demo)", index: 0)
        choose("Contoso Academy (Demo)", index: 1)
        lookUp((31...38).map { serial($0, "D") } + (39...40).map { serial($0, "M") })
        select(serial(31, "D"), waitingFor: "MDM Commands")
        capture("screenshot-jamf-school", mainWindow)
    }

    /// Contoso's iPhones in Apple Business and Intune.
    func test3Intune() {
        choose("Contoso Intune (Demo)")
        lookUp((23...30).map { serial($0, "P") })
        select(serial(23, "P"), waitingFor: "MDM Commands")
        capture("screenshot-intune", mainWindow)
    }

    /// Look Up Order… in Contoso, after the organization is read.
    func test4Order() {
        lookUp((1...14).map { serial($0, "M") })
        tap(app.menuBars.menuBarItems["Lookup"], timeout: 10)
        tap(app.menuItems["Look Up Order…"].firstMatch)
        let read = app.buttons["Read Organization"].firstMatch
        if read.waitForExistence(timeout: 10) { tap(read) }
        let order = app.staticTexts["DEMO-1001"].firstMatch
        XCTAssertTrue(order.waitForExistence(timeout: 90), "The orders weren't listed")
        order.click()
        Thread.sleep(forTimeInterval: 1)
        capture("screenshot-order", mainWindow)
    }

    /// The activity log after a Contoso Academy lookup, a request selected.
    func test5ActivityLog() {
        choose("Contoso Academy (Demo)", index: 0)
        choose("Contoso Academy (Demo)", index: 1)
        lookUp((31...38).map { serial($0, "D") })
        app.typeKey("l", modifierFlags: [.command, .shift])
        let log = window(titled: "Activity Log")
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The activity log didn't open")
        // Jamf School's device list: a request with a response body.
        let request = log.staticTexts["/api/devices"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The activity log has no Jamf School device list")
        request.click()
        Thread.sleep(forTimeInterval: 1)
        capture("screenshot-activity-log", log)
    }
}
