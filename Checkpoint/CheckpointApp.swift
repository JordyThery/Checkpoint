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
                .preferredColorScheme(colorScheme)
        }
    }
}
