import SwiftUI

/// What the main window can do now, for the menu bar: each action is nil
/// while it can't run, which dims its menu item.
struct LookupActions {
    var importFile: (() -> Void)?
    var lookUp: (() -> Void)?
    var lookUpGroup: (() -> Void)?
    var lookUpOrder: (() -> Void)?
    /// Demo mode only.
    var sampleSerials: (() -> Void)?
    var clear: (() -> Void)?
}

extension FocusedValues {
    @Entry var lookupActions: LookupActions?
    /// Ends the retry waits; nil while nothing waits.
    @Entry var stopWaiting: (() -> Void)?
}

/// The main window's actions in the menu bar: File › Import Serial Numbers…,
/// and a Lookup menu with Look Up, Look Up Group…, Look Up Order… and Clear List.
struct LookupCommands: Commands {
    @FocusedValue(\.lookupActions) private var actions
    @FocusedValue(\.stopWaiting) private var stopWaiting

    var body: some Commands {
        // One main window, so File › New Window gives way to Import.
        CommandGroup(replacing: .newItem) {
            Button("Import Serial Numbers…") { actions?.importFile?() }
                .keyboardShortcut("o")
                .disabled(actions?.importFile == nil)
        }
        CommandMenu("Lookup") {
            Button("Look Up") { actions?.lookUp?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.lookUp == nil)
            // No shortcut: ⇧⌘G is Find Previous.
            Button("Look Up Group…") { actions?.lookUpGroup?() }
                .disabled(actions?.lookUpGroup == nil)
            Button("Look Up Order…") { actions?.lookUpOrder?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.lookUpOrder == nil)
            // Demo Mode only; dimmed otherwise, so the menu keeps its items.
            Button("Fill In Sample Serials") { actions?.sampleSerials?() }
                .disabled(actions?.sampleSerials == nil)
            // ⌥⌘., not ⌘.: ⌘. is the system's Cancel key for alerts and sheets.
            Button("Stop Waiting") { stopWaiting?() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(stopWaiting == nil)
            Divider()
            Button("Clear List") { actions?.clear?() }
                .keyboardShortcut("k")
                .disabled(actions?.clear == nil)
        }
    }
}

// MARK: - Device menu

/// One of the inspector's actions in the Device menu: its title as the
/// inspector's button reads, and what the button does (the same
/// confirmation). Nil: dimmed.
struct DeviceMenuItem: Identifiable {
    let id: String
    let title: String
    var isDestructive = false
    let action: (() -> Void)?
}

/// The selected device's (or devices') actions, published by the inspector.
struct DeviceActions {
    var apple: [DeviceMenuItem] = []
    var commands: [DeviceMenuItem] = []
}

/// Open the selected records in their product's web interface.
struct OpenRecords {
    /// "Open in Jamf Pro", or "Open Records" when the products differ.
    let title: String
    let action: (() -> Void)?
}

extension FocusedValues {
    @Entry var deviceActions: DeviceActions?
    @Entry var openRecords: OpenRecords?
}

/// The Device menu: Open in…, then the inspector's Apple actions and MDM
/// commands, each through the inspector's own confirmation.
struct DeviceCommands: Commands {
    @FocusedValue(\.deviceActions) private var actions
    @FocusedValue(\.openRecords) private var open

    var body: some Commands {
        CommandMenu("Device") {
            Button(open?.title ?? "Open Record") { open?.action?() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(open?.action == nil)
            Divider()
            if let actions, !actions.apple.isEmpty || !actions.commands.isEmpty {
                if !actions.apple.isEmpty {
                    Section("Apple") { items(actions.apple) }
                }
                if !actions.commands.isEmpty {
                    Section("MDM Commands") { items(actions.commands) }
                }
            } else {
                Button("Select a Device to See Its Actions") {}
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private func items(_ list: [DeviceMenuItem]) -> some View {
        ForEach(list) { item in
            Button(item.title, role: item.isDestructive ? .destructive : nil) { item.action?() }
                .disabled(item.action == nil)
        }
    }
}
