import SwiftUI

@main struct CheckpointApp: App {
    private let settings = AppSettings.shared
    @State private var model = LookupModel(settings: AppSettings.shared)

    var body: some Scene {
        WindowGroup("Checkpoint") {
            ContentView()
                .environment(settings)
                .environment(model)
                .frame(minWidth: 900, minHeight: 420)
        }
        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
