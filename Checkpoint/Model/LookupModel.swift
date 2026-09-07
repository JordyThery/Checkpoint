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
    var name: String?
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
    case updateInventory
    case lockMobile
    case clearPasscode
    case restartMobile
    case wipeMobile

    static func commands(for kind: JamfDeviceKind) -> [MDMCommand] {
        switch kind {
        case .computer: [.lockComputer, .renewProfile, .wipeComputer, .blankPush]
        case .mobileDevice: [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .wipeMobile, .blankPush, .renewProfile]
        }
    }

    /// Display order when a mixed selection is shown.
    static let allInDisplayOrder: [MDMCommand] = [
        .updateInventory, .lockComputer, .lockMobile, .clearPasscode,
        .restartMobile, .renewProfile, .blankPush, .wipeComputer, .wipeMobile,
    ]

    func applies(to kind: JamfDeviceKind) -> Bool {
        Self.commands(for: kind).contains(self)
    }

    /// Classic API command string, per device kind. Nil when the command is
    /// not sent through the Classic command endpoints.
    func classicCommand(for kind: JamfDeviceKind) -> String? {
        guard applies(to: kind) else { return nil }
        switch self {
        case .blankPush: return "BlankPush"
        case .lockComputer, .lockMobile: return "DeviceLock"
        case .wipeComputer, .wipeMobile: return "EraseDevice"
        case .updateInventory: return "UpdateInventory"
        case .clearPasscode: return "ClearPasscode"
        case .restartMobile: return "RestartDevice"
        case .renewProfile: return nil
        }
    }

    var title: String {
        switch self {
        case .lockComputer: "Lock Computer"
        case .wipeComputer: "Wipe Computer"
        case .blankPush: "Send Blank Push"
        case .renewProfile: "Renew MDM Profile"
        case .updateInventory: "Update Inventory"
        case .lockMobile: "Lock Device"
        case .clearPasscode: "Clear Passcode"
        case .restartMobile: "Restart Device"
        case .wipeMobile: "Wipe Device"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .wipeComputer, .wipeMobile, .lockComputer, .lockMobile: true
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
        case .blankPush: "Sends an empty APNs push so the device checks in with MDM."
        case .renewProfile: "The MDM enrollment profile will be renewed on the device."
        case .updateInventory: "The device will be asked to submit a fresh inventory report."
        case .lockMobile: "The device will lock immediately; the owner's passcode unlocks it."
        case .clearPasscode: "The device passcode will be removed."
        case .restartMobile: "The device will restart immediately."
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

    /// Jamf reports "never" as the Unix epoch — treat anything before 1971 as no value.
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

    var reports: [DeviceReport] = []
    var isLoading = false
    var selectedJamfServerID: UUID?
    var mdmServers: [MDMServer] = []
    var prestages: [JamfPrestage] = []
    var mobilePrestages: [JamfPrestage] = []

    init(settings: AppSettings) {
        self.settings = settings
        selectedJamfServerID = settings.jamfServers.first?.id
    }

    var selectedJamfServer: JamfServerConfig? {
        settings.jamfServers.first { $0.id == selectedJamfServerID } ?? settings.jamfServers.first
    }

    var isABMConfigured: Bool {
        settings.abm.isConfigured && Keychain.get(ABMConfig.privateKeyKeychainKey) != nil
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

    /// Permanently releases the devices from Apple Business.
    func releaseFromABM(reports: [DeviceReport]) async throws {
        guard let abm = makeABMClient() else { throw ActionError(message: "Apple Business is not configured.") }
        let serials = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }.map(\.serial)
        guard !serials.isEmpty else { throw ActionError(message: "None of the selected devices are in Apple Business.") }
        try await abm.submitActivity(.release, serials: serials)
        await refreshRows(serials)
    }

    /// Assigns the devices to an MDM server, or unassigns them when `serverID` is nil.
    func setMDMServer(reports: [DeviceReport], to serverID: String?) async throws {
        guard let abm = makeABMClient() else { throw ActionError(message: "Apple Business is not configured.") }
        let inOrg = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }
        guard !inOrg.isEmpty else { throw ActionError(message: "None of the selected devices are in Apple Business.") }
        if let serverID {
            try await abm.submitActivity(.assign, serials: inOrg.map(\.serial), mdmServerID: serverID)
        } else {
            // Unassigning requires naming the current server, so batch per server.
            var byServer: [String: [String]] = [:]
            for report in inOrg {
                if let current = report.abm.value?.mdmServerID {
                    byServer[current, default: []].append(report.serial)
                }
            }
            guard !byServer.isEmpty else { return }
            for (server, serials) in byServer {
                try await abm.submitActivity(.unassign, serials: serials, mdmServerID: server)
            }
        }
        await refreshRows(inOrg.map(\.serial))
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
        for (prestage, serials) in removeByPrestage {
            try await jamf.removeFromPrestage(family: family, prestageID: prestage, serials: serials)
        }
        if let newID {
            try await jamf.addToPrestage(family: family, prestageID: newID, serials: affected)
        }
        await refreshRows(affected)
    }

    // MARK: MDM commands

    /// Sends a Jamf Pro MDM command to every selected device it applies to,
    /// routed per record kind. Returns the number of devices it was sent to.
    @discardableResult
    func sendCommand(_ command: MDMCommand, reports: [DeviceReport], passcode: String? = nil) async throws -> Int {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        let targets = reports.compactMap { report in
            report.jamf.value.map { (serial: report.serial, info: $0) }
        }.filter { command.applies(to: $0.info.kind) }
        guard !targets.isEmpty else {
            throw ActionError(message: "\(command.title) doesn't apply to any of the selected devices.")
        }

        if command == .renewProfile {
            let udids = targets.compactMap(\.info.udid).filter { !$0.isEmpty }
            guard !udids.isEmpty else {
                throw ActionError(message: "No device UDIDs are known, so the MDM profile cannot be renewed.")
            }
            try await jamf.renewMDMProfile(udids: udids)
            return udids.count
        }

        var failures: [String] = []
        var sent = 0
        for target in targets {
            guard let commandName = command.classicCommand(for: target.info.kind) else { continue }
            do {
                switch target.info.kind {
                case .computer:
                    try await jamf.sendComputerCommand(
                        commandName,
                        computerID: target.info.computerID,
                        passcode: command.needsPIN ? passcode : nil
                    )
                case .mobileDevice:
                    try await jamf.sendMobileDeviceCommand(commandName, deviceID: target.info.computerID)
                }
                sent += 1
            } catch {
                failures.append("\(target.serial): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
        return sent
    }

    // MARK: Clients & shared context

    private func makeABMClient() -> ABMClient? {
        guard settings.abm.isConfigured,
              let pem = Keychain.get(ABMConfig.privateKeyKeychainKey), !pem.isEmpty else { return nil }
        return ABMClient(clientID: settings.abm.clientID, keyID: settings.abm.keyID, privateKeyPEM: pem)
    }

    private func makeJamfClient() -> JamfClient? {
        guard let config = selectedJamfServer,
              let secret = Keychain.get(config.secretKeychainKey), !secret.isEmpty else { return nil }
        return JamfClient(config: config, secret: secret)
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
            context.computerPrestageNames = Dictionary(prestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.mobilePrestageNames = Dictionary(mobilePrestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.computerPrestageBySerial = (try? await jamf.prestageAssignments(family: .computer)) ?? [:]
            context.mobilePrestageBySerial = (try? await jamf.prestageAssignments(family: .mobileDevice)) ?? [:]
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
                    name: record.name,
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
                    name: record.name,
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
