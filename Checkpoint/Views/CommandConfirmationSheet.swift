import JTKit
import SwiftUI

/// Confirms a command, or removing records, when something has to be typed
/// first (JTKit's rules, ROADMAP step 7): the PIN twice for Lock and Wipe
/// Computer, and the number of devices for anything that can't be undone
/// on two or more devices. The connection is named, and why fewer devices
/// than selected receive it is said before anything is typed. When nothing
/// has to be typed, the inspectors use a dialog instead.
struct CommandConfirmationSheet: View {
    let confirmation: MDMCommand.Confirmation
    /// Called with the confirmation's approval (carrying the PIN, when one
    /// is asked) once everything matches.
    let onConfirm: (MDMCommand.Confirmation.Approval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var pinAgain = ""
    @State private var typedCount = ""
    @FocusState private var focused: Field?

    private enum Field { case pin, pinAgain, count }

    private var problem: String? {
        confirmation.problem(typedCount: typedCount, pin: pin, pinAgain: pinAgain)
    }

    var body: some View {
        SheetFrame(title: confirmation.title,
                   systemImage: confirmation.isDestructive ? "exclamationmark.triangle" : "paperplane") {
            Form {
                Section {
                    if let connectionLine = confirmation.connectionLine {
                        Text(connectionLine)
                            .fontWeight(.semibold)
                    }
                    Text(confirmation.message)
                    if let explanation = confirmation.explanation {
                        Text(explanation)
                            .foregroundStyle(.secondary)
                    }
                }
                if confirmation.asksPINTwice {
                    Section {
                        SecureField("PIN", text: $pin, prompt: Text("6 digits"))
                            .focused($focused, equals: .pin)
                        SecureField("Confirm PIN", text: $pinAgain, prompt: Text("6 digits"))
                            .focused($focused, equals: .pinAgain)
                    } footer: {
                        Text("Needed to unlock the Mac afterwards. Every selected Mac gets the same PIN; you can look it up later with Show Device Lock PIN.")
                    }
                }
                if let count = confirmation.typedCount {
                    Section {
                        TextField("Number of devices", text: $typedCount, prompt: Text("Type \(count)"))
                            .focused($focused, equals: .count)
                    } footer: {
                        Text("Type \(count) to confirm that the command goes to \(count) devices.")
                    }
                }
            }
            .formStyle(.grouped)
        } footer: {
            if let problem, !(pin.isEmpty && pinAgain.isEmpty && typedCount.isEmpty) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            // Never the default button: Return mustn't send something that
            // can't be undone.
            Button(confirmation.actionTitle, role: confirmation.isDestructive ? .destructive : nil) {
                guard let approval = try? confirmation.approve(typedCount: typedCount, pin: pin, pinAgain: pinAgain) else { return }
                dismiss()
                onConfirm(approval)
            }
            .disabled(problem != nil)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focused = confirmation.asksPINTwice ? .pin : .count
        }
    }
}

#Preview("Wipe three Macs") {
    let macs = (1...3).map { MDMCommand.Target(serial: "C02XK1JHJG5\($0)", recordID: "\($0)", kind: .computer) }
    CommandConfirmationSheet(
        confirmation: MDMCommand.Confirmation(.wipeComputer, plan: MDMCommand.wipeComputer.plan(for: macs, on: .jamfPro),
                                              on: .jamfPro, connectionName: "Lab Jamf",
                                              extra: [.noRecord: 2]),
        onConfirm: { _ in })
}
