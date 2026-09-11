import SwiftUI

@main struct CheckpointApp: App {
    private let settings = AppSettings.shared
    @State private var model = LookupModel(settings: AppSettings.shared)

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
                .frame(minWidth: 900, minHeight: 420)
                .preferredColorScheme(colorScheme)
        }
        Settings {
            SettingsView()
                .environment(settings)
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
