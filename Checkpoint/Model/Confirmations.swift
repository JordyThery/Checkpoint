import Foundation
import JTKit

/// A confirmation with something to type, shown as a sheet, and what it
/// confirms.
struct TypedConfirmation: Identifiable {
    enum Action {
        case command(MDMCommand)
        case deleteRecord
        case removeStaleRecords
    }

    let id = UUID()
    let confirmation: MDMCommand.Confirmation
    let action: Action
}

/// Removing records, confirmed by JTKit's rules (ROADMAP step 7): the
/// connection is always named; deleting from Jamf Pro or Intune can't be
/// undone, so from two records the number is typed. Jamf School's Move to
/// Trash can be restored there, so it isn't asked for (decided by Jordy).
extension LookupModel {
    /// Delete Record (or Move to Trash) for the records in the selection.
    func deleteConfirmation(reports: [DeviceReport]) -> MDMCommand.Confirmation? {
        guard mdmActionUnavailableReason(for: reports) == nil,
              let connection = mdmActionConnection(for: reports) else { return nil }
        let withRecords = reports.filter { $0.mdm.value != nil }
        let product = connection.product
        return MDMCommand.Confirmation(
            action: withRecords.count == 1 ? product.removeRecordAction : product.removeRecordActionPlural,
            subject: withRecords.first?.serial, count: withRecords.count,
            message: product.removeRecordConsequence,
            irreversible: product != .jamfSchool, namesConnection: true,
            connectionName: connection.displayName, isDestructive: true)
    }

    /// One record beside the working one (the inspector's stale record).
    func recordRemovalConfirmation(_ info: ManagedDeviceInfo, serial: String) -> MDMCommand.Confirmation {
        let connection = connection(for: info)
        let product = connection?.product ?? .jamfPro
        return MDMCommand.Confirmation(
            action: product.removeRecordAction, subject: serial, count: 1, message: product.removeRecordConsequence,
            irreversible: product != .jamfSchool, namesConnection: true,
            connectionName: connection?.displayName, isDestructive: true)
    }

    /// The stale-record cleanup. It can span connections, which its message
    /// names ("2 on Jamf School and 1 on Intune Test").
    func staleRemovalConfirmation(reports: [DeviceReport]) -> MDMCommand.Confirmation {
        let entries = staleRecords(in: reports)
        let deletes = entries.contains { connection(for: $0.info)?.product != .jamfSchool }
        return MDMCommand.Confirmation(
            action: "Remove Stale Records", subject: entries.first?.serial, count: entries.count,
            message: "Removes \(staleRecordSummary(in: reports)). Each goes the way its product removes records — deleted from Jamf Pro and Intune, moved to the trash in Jamf School. The working records are untouched.",
            irreversible: deletes, connectionName: nil, isDestructive: true)
    }
}

extension MDMCommand.Confirmation {
    /// The dialog's message: the connection, what it does, and why fewer
    /// devices than selected receive it.
    var dialogMessage: String {
        [connectionLine, message, explanation].compactMap { $0 }.joined(separator: "\n\n")
    }
}
