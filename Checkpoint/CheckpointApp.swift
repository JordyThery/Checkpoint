import SwiftUI

@main struct CheckpointApp: App {
    private let settings = AppSettings.shared
    @State private var model = LookupModel(settings: AppSettings.shared)
    @State private var updates = UpdateChecker()

    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some Scene {
        WindowGroup("Checkpoint") {
            ContentView()
                .environment(settings)
                .environment(model)
                .environment(updates)
                .frame(minWidth: 900, minHeight: 420)
                .preferredColorScheme(colorScheme)
                .task { await updates.checkAutomatically() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkManually() }
            }
        }
        Settings {
            SettingsView()
                .environment(settings)
                .environment(model)
                .environment(model.log)
                .preferredColorScheme(colorScheme)
        }
        // A single window rather than a group: one log, brought forward again
        // when the shortcut is used a second time.
        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
                .environment(model.log)
                .preferredColorScheme(colorScheme)
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
    }
}
