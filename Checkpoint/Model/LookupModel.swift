import Foundation
import Observation

// MARK: - Report models

enum FetchState<Value: Sendable>: Sendable {
    case pending
    case notConfigured
    case found(Value)
    case notFound
    case failed(String)

    var value: Value? {
        if case .found(let value) = self { return value }
        return nil
    }
}

struct ABMInfo: Sendable {
    var device: ABMDevice
    var mdmServerID: String?
    var mdmServerName: String?
    var coverage: [AppleCareCoverage]

    var isReleased: Bool { device.releasedFromOrgDateTime != nil }
}

struct JamfInfo: Sendable {
    /// Computer or mobile device record ID, depending on `kind`.
    var computerID: String
    var kind: JamfDeviceKind
    var udid: String?
    /// UUID used by the modern /v2/mdm/commands endpoint.
    var managementID: String?
    var name: String?
    var siteID: String?
    var siteName: String?
    /// Device-enrollment (ADE) instance that synced this serial, if any.
    var adeInstanceID: String?
    /// Escrowed unlock token (mobile devices), needed for Clear Passcode.
    var unlockToken: String?
    var lastEnrolledDate: String?
    var reportDate: String?
    /// Last check-in (Jamf binary; computers only).
    var lastContactTime: String?
    /// Last Contact inventory attribute (Jamf Pro 11.30+, both kinds).
    var lastContact: String?
    var mdmProfileExpiration: String?
    var prestageID: String?
    var prestageName: String?
    var webURL: URL?
}

struct DeviceReport: Identifiable, Sendable {
    let serial: String
    var id: String { serial }
    var abm: FetchState<ABMInfo> = .pending
    var jamf: FetchState<JamfInfo> = .pending

    /// Best-effort classification from the Jamf record kind, falling back to
    /// the ABM product family. Nil when neither service knows the device.
    var deviceKind: JamfDeviceKind? {
        if let kind = jamf.value?.kind { return kind }
        if let family = abm.value?.device.productFamily {
            return family == "Mac" ? .computer : .mobileDevice
        }
        return nil
    }
}

/// Jamf Pro MDM remote commands offered by the app, with the device kinds
/// each one applies to.
nonisolated enum MDMCommand: Hashable, Sendable {
    case lockComputer
    case wipeComputer
    case blankPush
    case renewProfile
    case redeployFramework
    case updateInventory
    case lockMobile
    case clearPasscode
    case restartMobile
    case wipeMobile
    case unmanage
    case shutDownMobile

    /// Commands offered for a device kind, in the order they are shown.
    ///
    /// Shut Down is mobile only, because Jamf Pro has no computer privilege
    /// for it. Remove MDM Profile is kept clear of Renew MDM Profile, whose
    /// name reads alike though only one of them is destructive.
    ///
    /// Adding or removing a command means a row in the privileges table in
    /// `docs/permissions.md`, and one in `docs/platform-api.md` if the gateway
    /// cannot carry it.
    static func commands(for kind: JamfDeviceKind) -> [MDMCommand] {
        switch kind {
        case .computer: [.lockComputer, .renewProfile, .redeployFramework, .wipeComputer, .blankPush, .unmanage]
        case .mobileDevice: [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile, .wipeMobile, .unmanage, .blankPush, .renewProfile]
        }
    }

    /// Display order when a mixed selection is shown.
    static let allInDisplayOrder: [MDMCommand] = [
        .updateInventory, .lockComputer, .lockMobile, .clearPasscode,
        .restartMobile, .shutDownMobile, .renewProfile, .redeployFramework, .blankPush, .unmanage, .wipeComputer, .wipeMobile,
    ]

    func applies(to kind: JamfDeviceKind) -> Bool {
        Self.commands(for: kind).contains(self)
    }

    /// Why this command cannot be sent over the given connection, or nil when
    /// it can be. The wording is the same for every blocked command: the
    /// reasons differ but the remedy does not.
    func unavailabilityReason(via authMethod: JamfAuthMethod) -> String? {
        guard authMethod == .platformGateway, !worksOverGateway else { return nil }
        return "This command is currently unavailable over the Platform API and requires an API client connection."
    }

    /// Whether the Platform API gateway can carry this command.
    ///
    /// Lock and clear passcode exist solely as command types on
    /// `POST /v2/mdm/commands`, which the gateway publishes as GET only. Renew
    /// profile is accepted there but renews nothing, returning every UDID
    /// under `udidsNotProcessed`, confirmed for both device kinds against an
    /// instance that renews them over a direct connection. Everything else
    /// reaches the gateway through a per-device Jamf Pro endpoint or the
    /// platform device actions API.
    ///
    /// The single place to revisit when Jamf widens gateway coverage. The list
    /// of what the gateway cannot carry is repeated for users in
    /// `docs/platform-api.md`, and in the warning shown when a Platform API
    /// connection is chosen in Settings; change all three together.
    private var worksOverGateway: Bool {
        switch self {
        case .lockComputer, .lockMobile, .clearPasscode, .renewProfile: false
        case .restartMobile, .shutDownMobile, .wipeComputer, .wipeMobile, .unmanage,
             .blankPush, .redeployFramework, .updateInventory: true
        }
    }

    /// Body for the modern /v2/mdm/commands endpoint. Nil when the command is
    /// served by a Classic or dedicated endpoint instead.
    func modernCommandData(for kind: JamfDeviceKind, passcode: String?) -> [String: any Sendable]? {
        guard applies(to: kind) else { return nil }
        switch self {
        case .lockComputer:
            var data: [String: any Sendable] = ["commandType": "DEVICE_LOCK"]
            if let passcode { data["pin"] = passcode }
            return data
        case .lockMobile:
            return ["commandType": "DEVICE_LOCK"]
        case .restartMobile:
            return ["commandType": "RESTART_DEVICE"]
        case .shutDownMobile:
            return ["commandType": "SHUT_DOWN_DEVICE"]
        case .wipeComputer, .wipeMobile, .unmanage, .clearPasscode,
             .blankPush, .updateInventory, .renewProfile, .redeployFramework:
            // Each of these has its own endpoint, or needs per-device data that
            // cannot share one batched body. sendCommand routes them.
            return nil
        }
    }

    var title: String {
        switch self {
        case .lockComputer: "Lock Computer"
        case .wipeComputer: "Wipe Computer"
        case .blankPush: "Send Blank Push"
        case .renewProfile: "Renew MDM Profile"
        case .redeployFramework: "Redeploy Jamf Framework"
        case .updateInventory: "Update Inventory"
        case .lockMobile: "Lock Device"
        case .unmanage: "Remove MDM Profile"
        case .clearPasscode: "Clear Passcode"
        case .restartMobile: "Restart Device"
        case .shutDownMobile: "Shut Down Device"
        case .wipeMobile: "Wipe Device"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .wipeComputer, .wipeMobile, .lockComputer, .lockMobile, .unmanage: true
        default: false
        }
    }

    /// Computer lock and wipe require a 6-digit PIN.
    var needsPIN: Bool {
        self == .lockComputer || self == .wipeComputer
    }

    var message: String {
        switch self {
        case .lockComputer: "The Mac will lock immediately and require the PIN to be used again."
        case .wipeComputer: "All data on the Mac will be erased. This cannot be undone."
        case .blankPush: "The device will be asked to check in with MDM and process any pending commands."
        case .renewProfile: "The MDM enrollment profile will be renewed on the device."
        case .redeployFramework: "Reinstalls the Jamf management framework (jamf binary) on the Mac through MDM. Use when a Mac has stopped checking in but still responds to MDM."
        case .updateInventory: "The device will be asked to submit a fresh inventory report."
        case .lockMobile: "The device will lock immediately; the owner's passcode unlocks it."
        case .unmanage: "The MDM profile is removed, so Jamf Pro can no longer manage the device. Its inventory record stays until you delete it."
        case .clearPasscode: "The device passcode will be removed."
        case .restartMobile: "The device will restart immediately."
        case .shutDownMobile: "The device will shut down immediately and stay off until someone powers it back on."
        case .wipeMobile: "All data on the device will be erased. This cannot be undone."
        }
    }
}

// MARK: - Date helpers

nonisolated enum DateFormatting {
    static func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Jamf reports "never" as the Unix epoch, so treat anything before 1971 as no value.
    private static let earliestPlausibleDate = Date(timeIntervalSince1970: 365 * 24 * 3600)

    static func short(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        guard let date = parseISO(iso) else { return iso }
        guard date > earliestPlausibleDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dateOnly(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        guard let date = parseISO(iso) else { return iso }
        guard date > earliestPlausibleDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func isoFromEpochMilliseconds(_ milliseconds: Int64?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}

// MARK: - Lookup model

@MainActor
@Observable
final class LookupModel {
    private let settings: AppSettings
    let log: ActivityLog

    var reports: [DeviceReport] = []
    var isLoading = false
    var selectedABMOrgID: UUID?
    var selectedJamfServerID: UUID?
    var mdmServers: [MDMServer] = []
    var prestages: [JamfPrestage] = []
    var mobilePrestages: [JamfPrestage] = []
    var sites: [JamfSite] = []

    // One client per configuration, reused across lookups and actions. Each new
    // ABMClient requests a fresh OAuth token and Apple rate-limits that endpoint
    // hard (HTTP 429 after a few sign-ins), so switching organization or server
    // must not cost a re-authentication.
    private var abmClients: [String: ABMClient] = [:]
    private var jamfClients: [String: JamfClient] = [:]

    init(settings: AppSettings, log: ActivityLog? = nil) {
        self.settings = settings
        self.log = log ?? ActivityLog()
        selectedABMOrgID = settings.abmOrgs.first?.id
        selectedJamfServerID = settings.jamfServers.first?.id
    }

    /// Records the outcome of a user-requested action, alongside the individual
    /// requests the clients log. This tier is what makes the log readable:
    /// it says what was asked for and what came of it, in the app's own words.
    private func recordAction(
        _ service: ActivityService,
        _ summary: String,
        serials: [String],
        outcome: ActivityOutcome = .succeeded
    ) {
        log.recordAction(
            service: service,
            connection: service == .appleBusiness ? selectedABMOrg?.displayName : selectedJamfServer?.displayName,
            summary: summary,
            outcome: outcome,
            serials: serials
        )
    }

    /// Runs an action and records its outcome either way, then rethrows so the
    /// view still reports the failure to the user.
    private func recording<T>(
        _ service: ActivityService,
        _ summary: String,
        serials: [String],
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            recordAction(service, summary, serials: serials)
            return result
        } catch {
            recordAction(service, "\(summary) — \(error.localizedDescription)", serials: serials, outcome: .failed)
            throw error
        }
    }

    var selectedABMOrg: ABMConfig? {
        settings.abmOrgs.first { $0.id == selectedABMOrgID } ?? settings.abmOrgs.first
    }

    var selectedJamfServer: JamfServerConfig? {
        settings.jamfServers.first { $0.id == selectedJamfServerID } ?? settings.jamfServers.first
    }

    var isABMConfigured: Bool {
        guard let org = selectedABMOrg else { return false }
        return org.isConfigured && Keychain.get(org.privateKeyKeychainKey) != nil
    }

    /// Empties the results table. Cached clients are deliberately kept so their
    /// access tokens survive; clearing the list must not cost a fresh sign-in.
    func clearReports() {
        reports = []
    }

    /// True when the selected Jamf Pro server talks to the Platform API
    /// gateway, which exposes a narrower set of MDM commands.
    var isUsingPlatformAPI: Bool {
        selectedJamfServer?.authMethod == .platformGateway
    }

    /// Why the given command cannot be sent to the selected server, or nil.
    func unavailabilityReason(for command: MDMCommand) -> String? {
        command.unavailabilityReason(via: selectedJamfServer?.authMethod ?? .apiClient)
    }

    // MARK: Lookup

    static func parseSerials(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func lookUp(serialsText: String) async {
        let serials = Self.parseSerials(serialsText)
        guard !serials.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        reports = serials.map { DeviceReport(serial: $0) }

        let context = await makeContext()
        await withTaskGroup(of: (String, FetchState<ABMInfo>, FetchState<JamfInfo>).self) { group in
            for serial in serials {
                group.addTask {
                    async let abm = Self.fetchABM(context: context, serial: serial)
                    async let jamf = Self.fetchJamf(context: context, serial: serial)
                    return await (serial, abm, jamf)
                }
            }
            for await (serial, abmState, jamfState) in group {
                if let index = reports.firstIndex(where: { $0.serial == serial }) {
                    reports[index].abm = abmState
                    reports[index].jamf = jamfState
                }
            }
        }
    }

    func refreshRows(_ serials: [String]) async {
        let context = await makeContext()
        for serial in serials {
            guard let index = reports.firstIndex(where: { $0.serial == serial }) else { continue }
            reports[index].abm = await Self.fetchABM(context: context, serial: serial)
            reports[index].jamf = await Self.fetchJamf(context: context, serial: serial)
        }
    }

    // MARK: Import

    /// Extracts serial numbers from an imported text/CSV file: takes the first
    /// column of each line and keeps tokens that look like serial numbers.
    static func parseImportedList(_ text: String) -> [String] {
        var seen = Set<String>()
        var serials: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let separator: Character? = line.contains(",") ? "," : (line.contains(";") ? ";" : nil)
            let field = separator.map { String(line.split(separator: $0, omittingEmptySubsequences: false).first ?? "") } ?? line
            let token = field.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).uppercased()
            guard token.count >= 6, token.count <= 20,
                  token.allSatisfy({ $0.isLetter || $0.isNumber }),
                  token.contains(where: \.isNumber),
                  seen.insert(token).inserted else { continue }
            serials.append(token)
        }
        return serials
    }

    // MARK: Actions

    struct ActionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Activity log phrasing

    /// "1 device" or "3 devices", so log summaries read as sentences.
    static func deviceCount(_ count: Int) -> String {
        "\(count) device\(count == 1 ? "" : "s")"
    }

    static func deviceCount(_ serials: [String]) -> String { deviceCount(serials.count) }

    static func deviceCount(_ reports: [DeviceReport]) -> String { deviceCount(reports.count) }

    /// Summarises an action that reports per-device failures rather than
    /// throwing on the first one, so a partial result is not logged as either
    /// a clean success or a total failure.
    static func partialSummary(
        _ verb: String,
        noun: String,
        of total: Int,
        failed: Int,
        from source: String?
    ) -> String {
        let suffix = source.map { " from \($0)" } ?? ""
        guard failed > 0 else {
            return "\(verb) \(total) \(noun)\(total == 1 ? "" : "s")\(suffix)"
        }
        return "\(verb) \(total - failed) of \(total) \(noun)\(total == 1 ? "" : "s")\(suffix)"
    }

    /// Permanently releases the devices from Apple Business.
    func releaseFromABM(reports: [DeviceReport]) async throws {
        guard let abm = makeABMClient() else { throw ActionError(message: "Apple Business is not configured.") }
        let serials = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }.map(\.serial)
        guard !serials.isEmpty else { throw ActionError(message: "None of the selected devices are in Apple Business.") }
        try await recording(.appleBusiness, "Released \(Self.deviceCount(serials)) from Apple Business", serials: serials) {
            let activityID = try await abm.submitActivity(.release, serials: serials)
            if let activityID { await abm.waitForActivity(id: activityID) }
        }
        await refreshRows(serials)
    }

    /// Assigns the devices to an MDM server, or unassigns them when `serverID` is nil.
    func setMDMServer(reports: [DeviceReport], to serverID: String?) async throws {
        guard let abm = makeABMClient() else { throw ActionError(message: "Apple Business is not configured.") }
        let inOrg = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }
        guard !inOrg.isEmpty else { throw ActionError(message: "None of the selected devices are in Apple Business.") }

        // Unassigning requires naming the current server, so batch per server.
        // Devices with no current assignment have nothing to unassign, and if
        // that leaves nothing at all there is no action to take or to log.
        var unassignByServer: [String: [String]] = [:]
        if serverID == nil {
            for report in inOrg {
                if let current = report.abm.value?.mdmServerID {
                    unassignByServer[current, default: []].append(report.serial)
                }
            }
            guard !unassignByServer.isEmpty else { return }
        }

        let serials = serverID == nil ? unassignByServer.values.flatMap { $0 } : inOrg.map(\.serial)
        let serverName = serverID.flatMap { id in mdmServers.first { $0.id == id }?.name } ?? serverID
        let summary = serverName.map { "Assigned \(Self.deviceCount(serials)) to \($0)" }
            ?? "Unassigned \(Self.deviceCount(serials)) from device management"

        try await recording(.appleBusiness, summary, serials: serials) {
            var activityIDs: [String] = []
            if let serverID {
                if let id = try await abm.submitActivity(.assign, serials: serials, mdmServerID: serverID) {
                    activityIDs.append(id)
                }
            } else {
                for (server, batch) in unassignByServer {
                    if let id = try await abm.submitActivity(.unassign, serials: batch, mdmServerID: server) {
                        activityIDs.append(id)
                    }
                }
            }
            // ABM applies activities asynchronously; wait for them so the refresh
            // below reads the new assignment instead of the old one.
            for id in activityIDs { await abm.waitForActivity(id: id) }
        }
        await refreshRows(inOrg.map(\.serial))
    }

    /// Assigns the devices to an MDM server and schedules a migration due by
    /// `deadline`. Unlike a plain assignment they stay enrolled in their
    /// current service until they migrate, so nothing is erased.
    func scheduleMigration(reports: [DeviceReport], to serverID: String, deadline: Date) async throws {
        try await submitMigrationActivity(
            .assignWithMigrationDeadline,
            reports: reports.filter { $0.abm.value?.device.isMdmMigrationCapable == true },
            mdmServerID: serverID,
            deadline: deadline,
            emptyMessage: "None of the selected devices can be migrated."
        )
    }

    /// Moves the deadline of a migration already under way.
    func updateMigrationDeadline(reports: [DeviceReport], deadline: Date) async throws {
        try await submitMigrationActivity(
            .updateMigrationDeadline,
            reports: reports.filter { $0.abm.value?.device.hasActiveMigration == true },
            deadline: deadline,
            emptyMessage: "None of the selected devices have a migration in progress."
        )
    }

    func cancelMigration(reports: [DeviceReport]) async throws {
        try await submitMigrationActivity(
            .cancelMigration,
            reports: reports.filter { $0.abm.value?.device.hasActiveMigration == true },
            emptyMessage: "None of the selected devices have a migration in progress."
        )
    }

    private func submitMigrationActivity(
        _ type: ABMClient.ActivityType,
        reports: [DeviceReport],
        mdmServerID: String? = nil,
        deadline: Date? = nil,
        emptyMessage: String
    ) async throws {
        guard let abm = makeABMClient() else { throw ActionError(message: "Apple Business is not configured.") }
        let serials = reports.map(\.serial)
        guard !serials.isEmpty else { throw ActionError(message: emptyMessage) }

        var summary: String
        switch type {
        case .assignWithMigrationDeadline:
            let name = mdmServerID.flatMap { id in mdmServers.first { $0.id == id }?.name } ?? "another service"
            summary = "Scheduled migration of \(Self.deviceCount(serials)) to \(name)"
        case .updateMigrationDeadline:
            summary = "Moved the migration deadline for \(Self.deviceCount(serials))"
        case .cancelMigration:
            summary = "Cancelled the migration of \(Self.deviceCount(serials))"
        default:
            summary = "\(type.rawValue) for \(Self.deviceCount(serials))"
        }
        if let deadline {
            summary += ", due \(deadline.formatted(date: .abbreviated, time: .shortened))"
        }

        try await recording(.appleBusiness, summary, serials: serials) {
            let activityID = try await abm.submitActivity(
                type,
                serials: serials,
                mdmServerID: mdmServerID,
                migrationDeadline: deadline
            )
            // Apple applies activities asynchronously, so wait before re-reading.
            if let activityID { await abm.waitForActivity(id: activityID) }
        }
        await refreshRows(serials)
    }

    // MARK: Recovery secrets

    /// A computer's FileVault personal recovery key. Fetched only on explicit
    /// request: recovery secrets are never read during a lookup, and are not
    /// stored on the report.
    func fileVaultRecoveryKey(for report: DeviceReport) async throws -> JamfFileVaultKey {
        let id = try computerID(for: report, action: "FileVault recovery keys")
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        // The activity log records that a key was read, never the key itself.
        // Jamf Pro keeps its own audit entry for this; ours makes it visible
        // without having to go and look.
        return try await recording(.jamfPro, "Read the FileVault recovery key for \(report.serial)", serials: [report.serial]) {
            guard let key = try await jamf.fileVaultRecoveryKey(computerID: id) else {
                throw ActionError(message: "Jamf Pro holds no FileVault recovery key for \(report.serial).")
            }
            return key
        }
    }

    /// A computer's Recovery Lock password. Fetched on request only,
    /// on the same terms as the FileVault key.
    func recoveryLockPassword(for report: DeviceReport) async throws -> String {
        let id = try computerID(for: report, action: "Recovery Lock passwords")
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        return try await recording(.jamfPro, "Read the Recovery Lock password for \(report.serial)", serials: [report.serial]) {
            guard let password = try await jamf.recoveryLockPassword(computerID: id) else {
                throw ActionError(message: "Jamf Pro holds no Recovery Lock password for \(report.serial).")
            }
            return password
        }
    }

    /// The PIN a Mac was locked with. Fetched on request, like the other
    /// recovery secrets.
    func deviceLockPIN(for report: DeviceReport) async throws -> String {
        let id = try computerID(for: report, action: "Device lock PINs")
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        return try await recording(.jamfPro, "Read the device lock PIN for \(report.serial)", serials: [report.serial]) {
            guard let pin = try await jamf.deviceLockPIN(computerID: id) else {
                throw ActionError(message: "Jamf Pro holds no device lock PIN for \(report.serial). One exists only after the Mac has been locked through Jamf Pro.")
            }
            return pin
        }
    }

    private func computerID(for report: DeviceReport, action: String) throws -> String {
        guard let info = report.jamf.value else {
            throw ActionError(message: "\(report.serial) has no Jamf Pro record.")
        }
        guard info.kind == .computer else {
            throw ActionError(message: "\(action) apply to Macs only.")
        }
        return info.computerID
    }

    func deleteFromJamf(reports: [DeviceReport]) async throws {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        let withRecords = reports.compactMap { report in
            report.jamf.value.map { (serial: report.serial, info: $0) }
        }
        guard !withRecords.isEmpty else { throw ActionError(message: "None of the selected devices have a Jamf Pro record.") }
        var failures: [String] = []
        for entry in withRecords {
            do {
                switch entry.info.kind {
                case .computer:
                    try await jamf.deleteComputer(id: entry.info.computerID)
                case .mobileDevice:
                    try await jamf.deleteMobileDevice(id: entry.info.computerID)
                }
            } catch {
                failures.append("\(entry.serial): \(error.localizedDescription)")
            }
        }
        recordAction(
            .jamfPro,
            Self.partialSummary("Deleted", noun: "record", of: withRecords.count, failed: failures.count, from: "Jamf Pro"),
            serials: withRecords.map(\.serial),
            outcome: failures.isEmpty ? .succeeded : .failed
        )
        await refreshRows(withRecords.map(\.serial))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    /// Moves the devices of the given kind between PreStage scopes. Pass nil
    /// to remove them from their current PreStage without adding them to
    /// another. Devices of the other kind in `reports` are skipped.
    func setPrestage(reports: [DeviceReport], to newID: String?, kind: JamfDeviceKind) async throws {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        let family: JamfPrestageFamily = kind == .computer ? .computer : .mobileDevice
        var removeByPrestage: [String: [String]] = [:]
        var affected: [String] = []
        for report in reports {
            guard report.deviceKind == kind else { continue }
            let current = report.jamf.value?.prestageID
            guard current != newID else { continue }
            if let current { removeByPrestage[current, default: []].append(report.serial) }
            affected.append(report.serial)
        }
        guard !affected.isEmpty else { return }
        let all = kind == .computer ? prestages : mobilePrestages
        let name = newID.flatMap { id in all.first { $0.id == id }?.displayName }
        let summary = name.map { "Added \(Self.deviceCount(affected)) to PreStage \($0)" }
            ?? "Removed \(Self.deviceCount(affected)) from their PreStage"
        try await recording(.jamfPro, summary, serials: affected) {
            for (prestage, serials) in removeByPrestage {
                try await jamf.removeFromPrestage(family: family, prestageID: prestage, serials: serials)
            }
            if let newID {
                try await jamf.addToPrestage(family: family, prestageID: newID, serials: affected)
            }
        }
        await refreshRows(affected)
    }

    /// Moves the devices' Jamf Pro records to another site ("-1" for none).
    /// Note this does not change which PreStages a device can join. That is
    /// determined by the ADE token that synced it, not by the record's site.
    func setSite(reports: [DeviceReport], to siteID: String) async throws {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        let withRecords = reports.compactMap { report in
            report.jamf.value.map { (serial: report.serial, info: $0) }
        }.filter { ($0.info.siteID ?? "-1") != siteID }
        guard !withRecords.isEmpty else { return }
        var failures: [String] = []
        for entry in withRecords {
            do {
                switch entry.info.kind {
                case .computer:
                    try await jamf.setComputerSite(computerID: entry.info.computerID, siteID: siteID)
                case .mobileDevice:
                    try await jamf.setMobileDeviceSite(deviceID: entry.info.computerID, siteID: siteID)
                }
            } catch {
                failures.append("\(entry.serial): \(error.localizedDescription)")
            }
        }
        let siteName = siteID == "-1" ? "no site" : (sites.first { $0.id == siteID }?.name ?? siteID)
        recordAction(
            .jamfPro,
            Self.partialSummary("Moved", noun: "device", of: withRecords.count, failed: failures.count, from: nil)
                + " to \(siteName)",
            serials: withRecords.map(\.serial),
            outcome: failures.isEmpty ? .succeeded : .failed
        )
        await refreshRows(withRecords.map(\.serial))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    // MARK: MDM commands

    /// Sends a Jamf Pro MDM command to every selected device it applies to,
    /// routed per record kind. Returns the number of devices it was sent to.
    @discardableResult
    func sendCommand(_ command: MDMCommand, reports: [DeviceReport], passcode: String? = nil) async throws -> Int {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        // Fail before doing any work, so a command the connection cannot carry
        // never gets as far as a confirmation prompt.
        if let reason = unavailabilityReason(for: command) {
            throw ActionError(message: reason)
        }
        let targets = reports.compactMap { report in
            report.jamf.value.map { (serial: report.serial, info: $0) }
        }.filter { command.applies(to: $0.info.kind) }
        guard !targets.isEmpty else {
            throw ActionError(message: "\(command.title) doesn't apply to any of the selected devices.")
        }

        let serials = targets.map(\.serial)
        do {
            let sent = try await route(command, jamf: jamf, targets: targets, passcode: passcode)
            recordAction(.jamfPro, "Sent \(command.title) to \(Self.deviceCount(sent))", serials: serials)
            return sent
        } catch {
            recordAction(
                .jamfPro,
                "\(command.title) failed — \(error.localizedDescription)",
                serials: serials,
                outcome: .failed
            )
            throw error
        }
    }

    /// Routes a command to whichever endpoint carries it for these targets.
    private func route(
        _ command: MDMCommand,
        jamf: JamfClient,
        targets: [(serial: String, info: JamfInfo)],
        passcode: String?
    ) async throws -> Int {
        if command == .renewProfile {
            let udids = targets.compactMap(\.info.udid).filter { !$0.isEmpty }
            guard !udids.isEmpty else {
                throw ActionError(message: "No device UDIDs are known, so the MDM profile cannot be renewed.")
            }
            // The endpoint answers with success even when it renews nothing,
            // naming the devices it skipped, so report those rather than
            // treating the status alone as the result.
            let notProcessed = Set(try await jamf.renewMDMProfile(udids: udids))
            guard notProcessed.isEmpty else {
                let serials = targets
                    .filter { notProcessed.contains($0.info.udid ?? "") }
                    .map(\.serial)
                let named = serials.isEmpty ? Array(notProcessed) : serials
                throw ActionError(message: "Jamf Pro accepted the request but renewed no profile for: \(named.joined(separator: ", "))")
            }
            return udids.count
        }

        if command == .blankPush {
            let pushTargets = targets.filter { $0.info.managementID != nil }
            let managementIDs = pushTargets.compactMap(\.info.managementID)
            guard !managementIDs.isEmpty else {
                throw ActionError(message: "No management IDs are known, so a blank push cannot be sent. Run a fresh lookup first.")
            }
            // The Jamf Pro UI's blank push queues a DeclarativeManagement sync
            // per device (POST /v1/ddm/{managementId}/sync), which is the entry
            // in the management history. Do the same, falling back to a
            // minimal DeviceInformation query for devices the DDM endpoint
            // rejects. Failures don't stop the push itself.
            var ddmError: String?
            var fallbackIDs: [String] = []
            var syncErrors: [String] = []
            for managementID in managementIDs {
                do {
                    try await jamf.ddmSync(managementID: managementID)
                } catch {
                    fallbackIDs.append(managementID)
                    syncErrors.append(error.localizedDescription)
                }
            }
            if !fallbackIDs.isEmpty {
                do {
                    try await jamf.sendModernCommand(
                        commandData: ["commandType": "DEVICE_INFORMATION", "queries": ["DeviceName"]],
                        managementIDs: fallbackIDs
                    )
                } catch {
                    ddmError = "\(syncErrors.first ?? ""); fallback DeviceInformation also failed: \(error.localizedDescription)"
                }
            }
            let errorIDs = Set(try await jamf.blankPush(managementIDs: managementIDs).map { $0.lowercased() })
            if !errorIDs.isEmpty {
                let failedSerials = pushTargets
                    .filter { errorIDs.contains(($0.info.managementID ?? "").lowercased()) }
                    .map(\.serial)
                let names = failedSerials.isEmpty ? errorIDs.joined(separator: ", ") : failedSerials.joined(separator: ", ")
                throw ActionError(message: "Jamf Pro could not deliver the blank push to: \(names)")
            }
            if let ddmError {
                throw ActionError(message: "The blank push was sent, but no visible command could be queued with it: \(ddmError)")
            }
            return managementIDs.count
        }

        var failures: [String] = []
        var sent = 0

        if command == .clearPasscode {
            for target in targets where target.info.kind == .mobileDevice {
                guard let managementID = target.info.managementID else {
                    failures.append("\(target.serial): the record has no management ID. Run a fresh lookup first.")
                    continue
                }
                guard let unlockToken = target.info.unlockToken, !unlockToken.isEmpty else {
                    failures.append("\(target.serial): Jamf Pro has no escrowed unlock token for this device, so the passcode cannot be cleared.")
                    continue
                }
                do {
                    try await jamf.sendModernCommand(
                        commandData: ["commandType": "CLEAR_PASSCODE", "unlockToken": unlockToken],
                        managementIDs: [managementID]
                    )
                    sent += 1
                } catch {
                    failures.append("\(target.serial): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
            return sent
        }

        // Restart and shut down have no Jamf Pro route, only the platform
        // Device Management Actions API, which the gateway reaches. On a direct
        // connection they fall through to the batched command endpoint below.
        if isUsingPlatformAPI, command == .shutDownMobile || command == .restartMobile {
            for target in targets {
                do {
                    guard let deviceID = try await jamf.platformDeviceID(serial: target.serial) else {
                        failures.append("\(target.serial): not in the platform device inventory.")
                        continue
                    }
                    if command == .shutDownMobile {
                        try await jamf.platformShutDown(deviceID: deviceID)
                    } else {
                        try await jamf.platformRestart(deviceID: deviceID)
                    }
                    sent += 1
                } catch {
                    failures.append("\(target.serial): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
            return sent
        }

        // Wipe and Remove MDM Profile use per-device endpoints rather than the
        // batched one, which is also why they work over the Platform API.
        if command == .wipeComputer || command == .wipeMobile || command == .unmanage {
            for target in targets {
                do {
                    switch (command, target.info.kind) {
                    case (.wipeComputer, .computer):
                        try await jamf.eraseComputer(computerID: target.info.computerID, pin: passcode)
                    case (.wipeMobile, .mobileDevice):
                        try await jamf.eraseMobileDevice(deviceID: target.info.computerID)
                    case (.unmanage, .computer):
                        try await jamf.removeMDMProfile(computerID: target.info.computerID)
                    case (.unmanage, .mobileDevice):
                        try await jamf.unmanageMobileDevice(deviceID: target.info.computerID)
                    default:
                        continue
                    }
                    sent += 1
                } catch {
                    failures.append("\(target.serial): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
            return sent
        }

        if command == .redeployFramework {
            for target in targets where target.info.kind == .computer {
                do {
                    try await jamf.redeployFramework(computerID: target.info.computerID)
                    sent += 1
                } catch {
                    failures.append("\(target.serial): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
            return sent
        }

        // Modern /v2/mdm/commands endpoint, batched per device kind (the
        // payload differs between computers and mobile devices).
        for kind in [JamfDeviceKind.computer, .mobileDevice] {
            guard let commandData = command.modernCommandData(for: kind, passcode: command.needsPIN ? passcode : nil) else { continue }
            let kindTargets = targets.filter { $0.info.kind == kind }
            guard !kindTargets.isEmpty else { continue }
            for target in kindTargets where target.info.managementID == nil {
                failures.append("\(target.serial): the record has no management ID. Run a fresh lookup first.")
            }
            let managementIDs = kindTargets.compactMap(\.info.managementID)
            guard !managementIDs.isEmpty else { continue }
            do {
                try await jamf.sendModernCommand(commandData: commandData, managementIDs: managementIDs)
                sent += managementIDs.count
            } catch {
                failures.append("\(kindTargets.map(\.serial).joined(separator: ", ")): \(error.localizedDescription)")
            }
        }

        // Update Inventory is the one command still served by the Classic API.
        if command == .updateInventory {
            for target in targets where target.info.kind == .mobileDevice {
                do {
                    try await jamf.sendMobileDeviceCommand("UpdateInventory", deviceID: target.info.computerID)
                    sent += 1
                } catch {
                    failures.append("\(target.serial): \(error.localizedDescription)")
                }
            }
        }
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
        return sent
    }

    // MARK: Clients & shared context

    private func makeABMClient() -> ABMClient? {
        guard let config = selectedABMOrg, config.isConfigured,
              let pem = Keychain.get(config.privateKeyKeychainKey), !pem.isEmpty else { return nil }
        let key = [config.id.uuidString, config.clientID, config.keyID, pem].joined(separator: "|")
        if let cached = abmClients[key] { return cached }
        let client = ABMClient(
            clientID: config.clientID,
            keyID: config.keyID,
            privateKeyPEM: pem,
            connectionName: config.displayName,
            log: log
        )
        abmClients[key] = client
        return client
    }

    private func makeJamfClient() -> JamfClient? {
        guard let config = selectedJamfServer,
              let secret = Keychain.get(config.secretKeychainKey), !secret.isEmpty else { return nil }
        let key = [config.id.uuidString, config.normalizedBaseURL, config.authMethod.rawValue, config.account, secret].joined(separator: "|")
        if let cached = jamfClients[key] { return cached }
        guard let client = JamfClient(config: config, secret: secret, log: log) else { return nil }
        jamfClients[key] = client
        return client
    }

    private struct LookupContext: Sendable {
        var abm: ABMClient?
        var jamf: JamfClient?
        var jamfBaseURL: String?
        var mdmServerNames: [String: String] = [:]
        var computerPrestageBySerial: [String: String] = [:]
        var computerPrestageNames: [String: String] = [:]
        var mobilePrestageBySerial: [String: String] = [:]
        var mobilePrestageNames: [String: String] = [:]
        var adeInstanceBySerial: [String: String] = [:]
    }

    private func makeContext() async -> LookupContext {
        var context = LookupContext(
            abm: makeABMClient(),
            jamf: makeJamfClient(),
            jamfBaseURL: selectedJamfServer?.normalizedBaseURL
        )
        if let abm = context.abm {
            if let servers = try? await abm.mdmServers() {
                mdmServers = servers
            }
            context.mdmServerNames = Dictionary(mdmServers.map { ($0.id, $0.name) }) { first, _ in first }
        }
        if let jamf = context.jamf {
            if let list = try? await jamf.prestages(family: .computer) {
                prestages = list
            }
            if let list = try? await jamf.prestages(family: .mobileDevice) {
                mobilePrestages = list
            }
            if let list = try? await jamf.sites() {
                sites = list
            }
            context.computerPrestageNames = Dictionary(prestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.mobilePrestageNames = Dictionary(mobilePrestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.computerPrestageBySerial = (try? await jamf.prestageAssignments(family: .computer)) ?? [:]
            context.mobilePrestageBySerial = (try? await jamf.prestageAssignments(family: .mobileDevice)) ?? [:]
            context.adeInstanceBySerial = (try? await jamf.adeInstanceBySerial()) ?? [:]
        }
        return context
    }

    private static func fetchABM(context: LookupContext, serial: String) async -> FetchState<ABMInfo> {
        guard let client = context.abm else { return .notConfigured }
        do {
            guard let device = try await client.device(serial: serial) else { return .notFound }
            let coverage = (try? await client.appleCareCoverage(serial: serial)) ?? []
            let serverID = try? await client.assignedServerID(serial: serial)
            return .found(ABMInfo(
                device: device,
                mdmServerID: serverID ?? nil,
                mdmServerName: (serverID ?? nil).map { context.mdmServerNames[$0] ?? $0 },
                coverage: coverage
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func fetchJamf(context: LookupContext, serial: String) async -> FetchState<JamfInfo> {
        guard let client = context.jamf else { return .notConfigured }
        do {
            if let record = try await client.computer(serial: serial) {
                let prestageID = context.computerPrestageBySerial[serial]
                let webURL = context.jamfBaseURL.flatMap { URL(string: "\($0)/computers.html?id=\(record.id)&o=r") }
                return .found(JamfInfo(
                    computerID: record.id,
                    kind: .computer,
                    udid: record.udid,
                    managementID: record.managementID,
                    name: record.name,
                    siteID: record.siteID,
                    siteName: record.siteName,
                    adeInstanceID: context.adeInstanceBySerial[serial],
                    lastEnrolledDate: record.lastEnrolledDate,
                    reportDate: record.reportDate,
                    lastContactTime: record.lastContactTime,
                    lastContact: record.lastContact,
                    mdmProfileExpiration: record.mdmProfileExpiration,
                    prestageID: prestageID,
                    prestageName: prestageID.map { context.computerPrestageNames[$0] ?? "PreStage \($0)" },
                    webURL: webURL
                ))
            }
            if let record = try await client.mobileDevice(serial: serial) {
                let prestageID = context.mobilePrestageBySerial[serial]
                let webURL = context.jamfBaseURL.flatMap { URL(string: "\($0)/mobileDevices.html?id=\(record.id)&o=r") }
                return .found(JamfInfo(
                    computerID: record.id,
                    kind: .mobileDevice,
                    udid: record.udid,
                    managementID: record.managementID,
                    name: record.name,
                    siteID: record.siteID,
                    siteName: record.siteName,
                    adeInstanceID: context.adeInstanceBySerial[serial],
                    unlockToken: record.unlockToken,
                    lastEnrolledDate: record.lastEnrolledDate,
                    reportDate: record.lastInventoryDate,
                    lastContactTime: nil,
                    lastContact: record.lastContactTime,
                    mdmProfileExpiration: record.mdmProfileExpiration,
                    prestageID: prestageID,
                    prestageName: prestageID.map { context.mobilePrestageNames[$0] ?? "PreStage \($0)" },
                    webURL: webURL
                ))
            }
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
