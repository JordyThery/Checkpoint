import Foundation
import JTKit

/// A confirmation with something to type, shown as a sheet, and what it
/// confirms.
struct TypedConfirmation: Identifiable {
    enum Action {
        case command(MDMCommand)
        case deleteRecord
        case removeStaleRecords
        case apple(AppleWrite)
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
        let confirmation = MDMCommand.Confirmation(
            action: withRecords.count == 1 ? product.removeRecordAction : product.removeRecordActionPlural,
            subject: withRecords.first?.serial, count: withRecords.count,
            message: product.removeRecordConsequence,
            irreversible: product != .jamfSchool, namesConnection: true,
            connectionName: connection.displayName, isDestructive: true)
        return product == .intune
            ? Self.intuneDeleteRecord(as: confirmation, serials: withRecords.map(\.serial), connectionName: connection.displayName)
            : confirmation
    }

    /// One record beside the working one (the inspector's stale record).
    func recordRemovalConfirmation(_ info: ManagedDeviceInfo, serial: String) -> MDMCommand.Confirmation {
        let connection = connection(for: info)
        let product = connection?.product ?? .jamfPro
        let confirmation = MDMCommand.Confirmation(
            action: product.removeRecordAction, subject: serial, count: 1, message: product.removeRecordConsequence,
            irreversible: product != .jamfSchool, namesConnection: true,
            connectionName: connection?.displayName, isDestructive: true)
        return product == .intune
            ? Self.intuneDeleteRecord(as: confirmation, serials: [serial], connectionName: connection?.displayName)
            : confirmation
    }

    /// The stale-record cleanup. It can span connections, which its message
    /// names ("2 on Jamf School and 1 on Example Intune").
    func staleRemovalConfirmation(reports: [DeviceReport]) -> MDMCommand.Confirmation {
        let entries = staleRecords(in: reports)
        let deletes = entries.contains { connection(for: $0.info)?.product != .jamfSchool }
        let confirmation = MDMCommand.Confirmation(
            action: "Remove Stale Records", subject: entries.first?.serial, count: entries.count,
            message: "Removes \(staleRecordSummary(in: reports)). Each goes the way its product removes records — deleted from Jamf Pro and Intune, moved to the trash in Jamf School. The working records are untouched.",
            irreversible: deletes, connectionName: nil, isDestructive: true)
        // Intune's Delete Record is sent only with an approval: this one
        // confirmation answers for every record in the cleanup.
        guard entries.contains(where: { connection(for: $0.info)?.product == .intune }) else { return confirmation }
        return Self.intuneDeleteRecord(as: confirmation, serials: entries.map(\.serial), connectionName: nil)
    }

    /// Intune's Delete Record is JTKit's command, sent only with the approval
    /// of a confirmation built from its plan. That confirmation shows and asks
    /// exactly what `shown` does (its title, text, button and number to type).
    nonisolated static func intuneDeleteRecord(as shown: MDMCommand.Confirmation, serials: [String],
                                               connectionName: String?) -> MDMCommand.Confirmation {
        let targets = serials.map { MDMCommand.Target(serial: $0, recordID: "", kind: .computer) }
        var confirmation = MDMCommand.Confirmation(.deleteRecord, plan: MDMCommand.deleteRecord.plan(for: targets, on: .intune),
                                                   on: .intune, connectionName: connectionName)
        confirmation.title = shown.title
        confirmation.message = shown.message
        confirmation.connectionLine = shown.connectionLine
        confirmation.explanation = shown.explanation
        confirmation.actionTitle = shown.actionTitle
        confirmation.isDestructive = shown.isDestructive
        confirmation.asksPINTwice = shown.asksPINTwice
        return confirmation
    }
}

/// One of the six Apple writes as the screens ask for it.
enum AppleWrite: Hashable, Sendable {
    /// Assign to a server, or unassign with nil.
    case setServer(String?)
    case release
    case scheduleMigration(server: String, deadline: Date)
    case updateDeadline(Date)
    case cancelMigration

    var type: ABM.ActivityType {
        switch self {
        case .setServer(let server): server == nil ? .unassign : .assign
        case .release: .release
        case .scheduleMigration: .assignWithMigrationDeadline
        case .updateDeadline: .updateMigrationDeadline
        case .cancelMigration: .cancelMigration
        }
    }

    var serverID: String? {
        switch self {
        case .setServer(let server): server
        case .scheduleMigration(let server, _): server
        default: nil
        }
    }

    var deadline: Date? {
        switch self {
        case .scheduleMigration(_, let deadline), .updateDeadline(let deadline): deadline
        default: nil
        }
    }
}

/// Apple writes, confirmed by JTKit's rules (ROADMAP step 9, decided by
/// Jordy): every dialog names the organization; Release, Assign with
/// Migration Deadline and Update Deadline ask for the number from two
/// devices; Update Deadline warns when the new deadline is earlier.
extension LookupModel {
    /// The devices a write goes to, as the write itself picks them.
    func appleTargets(_ write: AppleWrite, reports: [DeviceReport]) -> [DeviceReport] {
        reports.filter { report in
            guard let abm = report.abm.value else { return false }
            switch write.type {
            case .assign, .release: return !abm.isReleased
            case .unassign: return !abm.isReleased && abm.mdmServerID != nil
            case .assignWithMigrationDeadline: return abm.device.isMdmMigrationCapable == true
            case .updateMigrationDeadline, .cancelMigration: return abm.device.hasActiveMigration
            }
        }
    }

    /// Nil when the write can't go anywhere (no organization, no device).
    func appleConfirmation(_ write: AppleWrite, reports: [DeviceReport]) -> MDMCommand.Confirmation? {
        guard let org = appleActionOrg(for: reports) else { return nil }
        let receiving = appleTargets(write, reports: reports)
        guard !receiving.isEmpty else { return nil }
        let serverName = write.serverID.map { id in mdmServers(for: org).first { $0.id == id }?.name ?? id }
        let current = receiving.count == 1 ? receiving[0].abm.value?.mdmServerName : nil
        let skipped = reports.count - receiving.count
        let explanation = skipped > 0
            ? "\(skipped) of the \(reports.count) selected devices \(Self.skipReason(write.type, org: org.displayName)), so \(skipped == 1 ? "it isn’t" : "they aren’t") included."
            : nil
        return write.type.confirmation(
            serials: receiving.map(\.serial), organization: org.displayName, service: org.kind.service,
            server: serverName, currentServer: current, deadline: write.deadline,
            currentDeadlines: receiving.compactMap { $0.abm.value?.device.migrationDeadline },
            explanation: explanation)
    }

    nonisolated static func skipReason(_ type: ABM.ActivityType, org: String) -> String {
        switch type {
        case .assign, .release: "are released or not in \(org)"
        case .unassign: "have no MDM server"
        case .assignWithMigrationDeadline: "can’t be migrated"
        case .updateMigrationDeadline, .cancelMigration: "have no migration in progress"
        }
    }

    /// Sends the write.
    func perform(_ write: AppleWrite, reports: [DeviceReport]) async throws {
        switch write {
        case .setServer(let server): try await setMDMServer(reports: reports, to: server)
        case .release: try await releaseFromABM(reports: reports)
        case .scheduleMigration(let server, let deadline): try await scheduleMigration(reports: reports, to: server, deadline: deadline)
        case .updateDeadline(let deadline): try await updateMigrationDeadline(reports: reports, deadline: deadline)
        case .cancelMigration: try await cancelMigration(reports: reports)
        }
    }
}

extension MDMCommand.Confirmation {
    /// The dialog's message: the connection, what it does, and why fewer
    /// devices than selected receive it.
    var dialogMessage: String {
        [connectionLine, message, explanation].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Reading a secret (JTKit's rules, ROADMAP step 7): only a LAPS password
/// rotates when viewed, so only it is asked about first.
extension LookupModel {
    /// "in 1 hour", "shortly afterwards", as Jamf Pro words the rotation. The
    /// interval is an instance setting, read from the server.
    nonisolated static func rotationPhrase(_ interval: TimeInterval?) -> String {
        guard let interval else { return "shortly afterwards" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval).map { "in \($0)" } ?? "shortly afterwards"
    }

    /// The question before showing a secret; nil when it shows at once.
    nonisolated static func revealConfirmation(_ secret: JamfPro.Secret, account: String?,
                                               rotationTime: TimeInterval?) -> (title: String, message: String)? {
        secret.confirmation(account: account, rotation: rotationPhrase(rotationTime))
    }
}
