import JTKit
import SwiftUI

@main struct CheckpointApp: App {
    private let settings = AppSettings.shared
    @State private var model = LookupModel(settings: AppSettings.shared)
    @State private var updates = UpdateChecker(
        configuration: UpdateConfiguration(owner: "JordyThery", repository: "Checkpoint", appName: "Checkpoint")
    )

    var body: some Scene {
        // One main window: every window would show the same results and
        // share one lookup, so a second one would only mislead.
        Window("Checkpoint", id: "main") {
            ContentView()
                .environment(settings)
                .environment(model)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 420)
                // No update check under tests: neither as the unit tests'
                // host nor in a sandbox run (UI tests).
                .task { if !settings.demo.isSandbox && !UnderTest.isActive { await updates.checkAutomatically() } }
        }
        .commands {
            AppInfoCommands(appName: "Checkpoint") { updates.checkManually() }
            LookupCommands()
            // The same items as the two toolbar pickers: Apple, then MDM.
            ConnectionCommands(store: settings.connections, roles: [model.appleRole, model.mdmRole],
                               itemTitle: \.displayName) {
                DemoModeToggle(demo: settings.demo)
            }
        }
        // Checkpoint's own general settings make up the General tab.
        // Tabs open by name, so "Edit Connections…" opens Connections.
        SettingsWindow(updates: updates, opensTabsByName: true) {
            GeneralSettingsSection()
                .environment(settings)
        } tabs: {
            ConnectionsTab()
            .environment(settings)
            .environment(settings.demo)
            .environment(model)
            .environment(model.log)
        }
        AboutWindow(configuration: .checkpoint)
        // JTKit's activity log window (⇧⌘L), the same in every app.
        ActivityLogWindow(log: model.log,
                          emptyDescription: "Requests to Apple, Jamf and Intune appear here as they happen.")
    }
}

/// What the About window shows (JTKit's `AboutWindow`).
extension AboutConfiguration {
    static let checkpoint = AboutConfiguration(
        appName: "Checkpoint",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Cross-references Apple Business or Apple School Manager with Jamf Pro, Jamf School and Intune.",
        links: [
            AboutLink("github.com/JordyThery/Checkpoint", address: "https://github.com/JordyThery/Checkpoint"),
        ].compactMap { $0 }
    )
}
