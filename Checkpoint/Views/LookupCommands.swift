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
            Button("Stop Waiting") { stopWaiting?() }
                .keyboardShortcut(".")
                .disabled(stopWaiting == nil)
            Divider()
            Button("Clear List") { actions?.clear?() }
                .keyboardShortcut("k")
                .disabled(actions?.clear == nil)
        }
    }
}
