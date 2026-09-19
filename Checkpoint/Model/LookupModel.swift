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
    /// The organization the device was found in. Every lookup path sets it.
    var orgID: UUID?
    var orgName: String?
    var mdmServerID: String?
    var mdmServerName: String?
    var coverage: [AppleCareCoverage]
    /// False when the lookup came from an organization snapshot, which has no
    /// bulk source for AppleCare. Coverage is then read on demand instead.
    var coverageLoaded: Bool = true

    var isReleased: Bool { device.releasedFromOrgDateTime != nil }
}

struct DeviceReport: Identifiable, Sendable {
    let serial: String
    var id: String { serial }
    var abm: FetchState<ABMInfo> = .pending
    var mdm: FetchState<ManagedDeviceInfo> = .pending

    /// Best-effort classification from the MDM record kind, falling back to
    /// the ABM product family. Nil when neither service knows the device.
    var deviceKind: DeviceKind? {
        if let kind = mdm.value?.kind { return kind }
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
    /// Jamf School has no computer/mobile split at all: one device resource
    /// serves both, so restart and wipe reach a Mac through the same endpoint
    /// as an iPad. Its list is the commands it shares with Jamf Pro; its API
    /// also defines clearing Activation Lock, which is deliberately not
    /// offered because Jamf Pro has no equivalent.
    ///
    /// Intune keeps one collection for every platform, so the split here is
    /// inferred from the platform rather than reported. Lock and clear
    /// passcode are offered for mobile devices only: Graph accepts both
    /// against a Mac, and neither does what the name suggests there.
    /// Bypassing Activation Lock is left out for the same reason as in Jamf
    /// School. Remove MDM Profile maps to Intune's retire, which is the
    /// closest equivalent — see its message.
    ///
    /// Adding or removing a command means a row in the privileges table in
    /// `docs/permissions.md`, and one in `docs/platform-api.md` if the gateway
    /// cannot carry it.
    static func commands(for kind: DeviceKind, product: MDMProduct = .jamfPro) -> [MDMCommand] {
        switch (product, kind) {
        case (.jamfPro, .computer):
            [.lockComputer, .renewProfile, .redeployFramework, .wipeComputer, .blankPush, .unmanage]
        case (.jamfPro, .mobileDevice):
            [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile, .wipeMobile, .unmanage, .blankPush, .renewProfile]
        case (.jamfSchool, .computer):
            [.updateInventory, .restartMobile, .wipeComputer, .unmanage]
        case (.jamfSchool, .mobileDevice):
            [.updateInventory, .restartMobile, .wipeMobile, .unmanage]
        case (.intune, .computer):
            [.updateInventory, .restartMobile, .shutDownMobile, .wipeComputer, .unmanage]
        case (.intune, .mobileDevice):
            [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile, .wipeMobile, .unmanage]
        }
    }

    /// Display order when a mixed selection is shown.
    static let allInDisplayOrder: [MDMCommand] = [
        .updateInventory, .lockComputer, .lockMobile, .clearPasscode,
        .restartMobile, .shutDownMobile, .renewProfile, .redeployFramework, .blankPush,
        .unmanage, .wipeComputer, .wipeMobile,
    ]

    func applies(to kind: DeviceKind, product: MDMProduct = .jamfPro) -> Bool {
        Self.commands(for: kind, product: product).contains(self)
    }

    /// Why this command cannot be sent over the given connection, or nil when
    /// it can be. The wording is the same for every blocked command: the
    /// reasons differ but the remedy does not.
    func unavailabilityReason(via authMethod: MDMAuthMethod) -> String? {
        guard authMethod == .platformGateway, !worksOverGateway else { return nil }
        return "This command is currently unavailable over the Platform API and requires an API client connection."
    }

    /// Why this command would do nothing to this particular device, or nil.
    /// Distinct from the connection check above: this one is about the state
    /// of the device rather than what the connection can carry.
    func inapplicabilityReason(for info: ManagedDeviceInfo) -> String? {
        guard self == .clearPasscode, info.security?.passcodePresent == false else { return nil }
        return "This device has no passcode set."
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
    func modernCommandData(for kind: DeviceKind, passcode: String?) -> [String: any Sendable]? {
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
    ///
    /// Jamf Pro only. Jamf School's wipe endpoint takes no PIN, so asking for
    /// one there would collect a code that went nowhere.
    func needsPIN(product: MDMProduct = .jamfPro) -> Bool {
        guard product == .jamfPro else { return false }
        return self == .lockComputer || self == .wipeComputer
    }

    func message(for product: MDMProduct = .jamfPro) -> String {
        switch self {
        case .lockComputer: "The Mac will lock immediately and require the PIN to be used again."
        case .wipeComputer: "All data on the Mac will be erased. This cannot be undone."
        case .blankPush: "The device will be asked to check in with MDM and process any pending commands."
        case .renewProfile: "The MDM enrollment profile will be renewed on the device."
        case .redeployFramework: "Reinstalls the Jamf management framework (jamf binary) on the Mac through MDM. Use when a Mac has stopped checking in but still responds to MDM."
        case .updateInventory: "The device will be asked to submit a fresh inventory report."
        case .lockMobile: "The device will lock immediately; the owner's passcode unlocks it."
        case .unmanage:
            switch product {
            case .jamfPro: "The MDM profile is removed, so Jamf Pro can no longer manage the device. Its inventory record stays until you delete it."
            case .jamfSchool: "The MDM profile is removed, so Jamf School can no longer manage the device. Its record stays until you move it to the trash."
            case .intune: "The device is retired: company data and the management profile are removed, so Intune can no longer manage it. Unlike the Jamf products, the record goes too once the device acknowledges."
            }
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

    /// Parses a timestamp with no time zone, as Jamf Pro gives the times on
    /// declarative status items. Read in the current zone, which is what a
    /// server-local wall-clock time means to whoever is looking at it. The
    /// zoned parser is tried first, in case a release starts sending one.
    static func parseDeviceLocal(_ string: String) -> Date? {
        if let date = parseISO(string) { return date }
        // Report times carry milliseconds; other values do not.
        if let date = parse(string, format: "yyyy-MM-dd'T'HH:mm:ss.SSS", timeZone: .current) { return date }
        return parse(string, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: .current)
    }

    /// Values inside declarative status items use a space instead of the T and
    /// carry an offset, e.g. `2026-08-31 22:01:00 +0000`.
    static func parseStatusItemDate(_ string: String) -> Date? {
        if let date = parseISO(string) { return date }
        if let date = parse(string, format: "yyyy-MM-dd HH:mm:ss Z", timeZone: nil) { return date }
        return parseDeviceLocal(string)
    }

    /// Converts a Jamf School timestamp into an ISO one.
    ///
    /// Jamf School stamps `2026-09-12 17:42:00` with no offset, in the
    /// instance's own zone rather than UTC. The zone is not on that response;
    /// it appears only on the per-device record, and is passed in here. With
    /// it, a check-in reads correctly wherever the person looking is; without
    /// it, the time is read as local and is wrong by the offset between them.
    static func isoFromInstanceLocal(_ string: String?, timeZone: TimeZone?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        let zone = timeZone ?? .current
        guard let date = parse(string, format: "yyyy-MM-dd HH:mm:ss", timeZone: zone)
            ?? parse(string, format: "yyyy-MM-dd'T'HH:mm:ss", timeZone: zone) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func parse(_ string: String, format: String, timeZone: TimeZone?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let timeZone { formatter.timeZone = timeZone }
        return formatter.date(from: string)
    }

    static func short(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
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
    /// Progress through a lookup. Zero total means no lookup is running, or
    /// one too small to be worth reporting on.
    private(set) var completedLookups = 0
    private(set) var totalLookups = 0
    /// Which Apple organizations a lookup reads.
    ///
    /// Reading all of them answers a different question — which organization
    /// owns a device — and is effectively read-only, since an Apple action
    /// needs one organization to act in. See `appleActionOrg(for:)`.
    nonisolated enum ABMScope: Hashable, Sendable {
        case organization(UUID)
        case allOrganizations
    }

    var abmScope: ABMScope = .allOrganizations
    var selectedConnectionID: UUID?
    /// Device management services per Apple organization. A service ID means
    /// nothing outside the organization that issued it, so they are never
    /// pooled for an action — only for resolving a name.
    private(set) var mdmServersByOrg: [UUID: [MDMServer]] = [:]
    var prestages: [JamfPrestage] = []
    var mobilePrestages: [JamfPrestage] = []
    var sites: [JamfSite] = []
    /// Jamf School locations, that product's equivalent of sites.
    var jamfLocations: [JamfSchoolLocation] = []

    // One client per configuration, reused across lookups and actions. Each new
    // ABMClient requests a fresh OAuth token and Apple rate-limits that endpoint
    // hard (HTTP 429 after a few sign-ins), so switching organization or server
    // must not cost a re-authentication.
    private var abmClients: [String: ABMClient] = [:]
    private var jamfClients: [String: JamfClient] = [:]
    private var jamfSchoolClients: [String: JamfSchoolClient] = [:]
    private var intuneClients: [String: IntuneClient] = [:]
    /// LAPS rotation time per server, cached because it is server-wide.
    private var rotationTimes: [UUID: TimeInterval] = [:]
    /// Blueprint names per server, cached for the same reason.
    private var blueprintNames: [UUID: [String: String]] = [:]
    /// The time zone a Jamf School instance reports its timestamps in, per
    /// server. Instance-wide, and only the per-device endpoint names it, so it
    /// is read once and kept.
    private var jamfSchoolTimeZones: [UUID: TimeZone] = [:]
    /// The last organization snapshot, per Apple Business organization.
    /// Discarded whenever Checkpoint changes anything in Apple Business.
    private var abmSnapshots: [UUID: ABMSnapshot] = [:]
    /// Whether the Device Compliance integration is on, per Jamf Pro server.
    /// Instance-wide, so read once and kept. Nil means it has not been
    /// determined, which is not the same as off.
    private var deviceComplianceEnabled: [UUID: Bool] = [:]
    /// Serial → device-enrollment (ADE) instance, per Jamf Pro server.
    private var adeInstances: [UUID: [String: String]] = [:]
    /// One read in flight per server, so a device selection and a bulk
    /// selection arriving together do not both ask for it. Nil on failure,
    /// which is kept distinct from an instance that has no ADE devices.
    private var adeInstanceReads: [UUID: Task<[String: String]?, Never>] = [:]

    /// Above this many devices, Apple Business is read in bulk rather than
    /// one device at a time. Apple allows roughly twenty requests a minute
    /// per organization, and a per-device lookup costs three of them, so the
    /// whole organization becomes cheaper than about seven devices.
    static let snapshotThreshold = 15

    /// What the organization read is currently doing, for the progress text.
    private(set) var snapshotStatus: String?
    private(set) var isBuildingSnapshot = false

    init(settings: AppSettings, log: ActivityLog? = nil) {
        self.settings = settings
        self.log = log ?? ActivityLog()
        // A single organization unless there are several, where reading them
        // all is the more useful default and costs nothing extra to offer.
        abmScope = settings.abmOrgs.count > 1
            ? .allOrganizations
            : settings.abmOrgs.first.map { ABMScope.organization($0.id) } ?? .allOrganizations
        selectedConnectionID = settings.mdmConnections.first?.id
    }

    /// Records the outcome of a user-requested action, alongside the individual
    /// requests the clients log. This tier is what makes the log readable:
    /// it says what was asked for and what came of it, in the app's own words.
    /// `orgName` names the Apple organization an entry belongs to. With
    /// several in scope there is no selected one to fall back on, and an
    /// entry naming none would not say which organization it changed.
    private func recordAction(
        _ service: ActivityService,
        _ summary: String,
        serials: [String],
        outcome: ActivityOutcome = .succeeded,
        orgName: String? = nil
    ) {
        log.recordAction(
            service: service,
            connection: service.isAppleOrganization
                ? (orgName ?? selectedABMOrg?.displayName)
                : selectedConnection?.displayName,
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
        orgName: String? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            recordAction(service, summary, serials: serials, orgName: orgName)
            return result
        } catch {
            recordAction(
                service,
                "\(summary) — \(error.localizedDescription)",
                serials: serials,
                outcome: .failed,
                orgName: orgName
            )
            throw error
        }
    }

    /// The one organization in scope, or nil when every organization is.
    var selectedABMOrg: ABMConfig? {
        guard case .organization(let id) = abmScope else { return nil }
        return settings.abmOrgs.first { $0.id == id } ?? settings.abmOrgs.first
    }

    /// The organizations a lookup will read, in configured order.
    var abmOrgsInScope: [ABMConfig] {
        switch abmScope {
        case .allOrganizations: settings.abmOrgs.filter(\.isConfigured)
        case .organization: selectedABMOrg.map { $0.isConfigured ? [$0] : [] } ?? []
        }
    }

    /// The device management services of one organization, for its pickers.
    /// Empty for an organization that has not been read yet.
    func mdmServers(for org: ABMConfig?) -> [MDMServer] {
        org.flatMap { mdmServersByOrg[$0.id] } ?? []
    }

    /// The reference organization's services, for the single-organization
    /// case and for resolving a name when no organization is in hand.
    var mdmServers: [MDMServer] {
        mdmServers(for: referenceABMOrg)
    }

    /// Every service across the organizations in scope, for turning an ID
    /// into a name. Never for a picker: an ID belongs to one organization.
    private var allMDMServers: [MDMServer] {
        abmOrgsInScope.flatMap { mdmServersByOrg[$0.id] ?? [] }
    }

    /// The organization the interface takes its labels from. With every
    /// organization in scope the first configured one stands in, since every
    /// label it drives is either neutral or resolved per device.
    var referenceABMOrg: ABMConfig? {
        selectedABMOrg ?? settings.abmOrgs.first
    }

    /// True when a lookup is reading more than one organization, which adds
    /// the Organization column and restricts the Apple actions.
    var readsAllABMOrgs: Bool {
        abmScope == .allOrganizations && settings.abmOrgs.count > 1
    }

    var selectedConnection: MDMConnection? {
        settings.mdmConnections.first { $0.id == selectedConnectionID } ?? settings.mdmConnections.first
    }

    var isABMConfigured: Bool {
        abmOrgsInScope.contains { Keychain.get($0.privateKeyKeychainKey) != nil }
    }

    /// Brings the scope back to something that exists, after organizations
    /// are added or removed. A scope pointing at a deleted organization would
    /// leave the popup blank, and searching them all makes no sense once one
    /// is left — the popup stops offering that entry.
    func reconcileABMScope() {
        if case .organization(let id) = abmScope,
           !settings.abmOrgs.contains(where: { $0.id == id }) {
            abmScope = settings.abmOrgs.first.map { .organization($0.id) } ?? .allOrganizations
        }
        if abmScope == .allOrganizations, settings.abmOrgs.count == 1,
           let only = settings.abmOrgs.first {
            abmScope = .organization(only.id)
        }
    }

    /// Empties the results table. Cached clients are deliberately kept so their
    /// access tokens survive; clearing the list must not cost a fresh sign-in.
    func clearReports() {
        reports = []
    }

    /// True when the selected Jamf Pro server talks to the Platform API
    /// gateway, which exposes a narrower set of MDM commands.
    var isUsingPlatformAPI: Bool {
        selectedConnection?.isUsingPlatformGateway ?? false
    }

    /// Which product the selected connection talks to. Jamf Pro when nothing
    /// is selected, so a missing connection never changes what the interface
    /// offers.
    var mdmProduct: MDMProduct {
        selectedConnection?.product ?? .jamfPro
    }

    /// What the selected connection can report and do. Drives which columns,
    /// rows and actions exist at all: what a product cannot do is left out
    /// rather than shown disabled.
    var mdmCapabilities: MDMCapabilities {
        selectedConnection?.capabilities ?? MDMProduct.jamfPro.capabilities
    }

    /// Why the given command cannot be sent to the selected server, or nil.
    func unavailabilityReason(for command: MDMCommand) -> String? {
        guard mdmProduct == .jamfPro else { return nil }
        return command.unavailabilityReason(via: selectedConnection?.authMethod ?? .apiClient)
    }

    // MARK: Lookup

    static func parseSerials(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// How many devices are looked up at once.
    ///
    /// Each device costs several requests across both APIs, and Apple rate
    /// limits hard enough that the clients are cached to avoid re-signing in.
    /// A group or a pasted list can hold several hundred serials, so the work
    /// is fed through a fixed window rather than started all at once.
    static let maximumConcurrentLookups = 8

    func lookUp(serialsText: String) async {
        let serials = Self.parseSerials(serialsText)
        guard !serials.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        reports = serials.map { DeviceReport(serial: $0) }
        completedLookups = 0
        totalLookups = serials.count
        defer { totalLookups = 0 }

        let context = await makeContext(deviceCount: serials.count)
        await withTaskGroup(of: (String, FetchState<ABMInfo>, FetchState<ManagedDeviceInfo>).self) { group in
            var pending = serials.makeIterator()
            func addNext() {
                guard let serial = pending.next() else { return }
                group.addTask {
                    async let abm = Self.fetchABM(context: context, serial: serial)
                    async let mdm = Self.fetchMDM(context: context, serial: serial)
                    return await (serial, abm, mdm)
                }
            }
            for _ in 0..<Self.maximumConcurrentLookups { addNext() }
            for await (serial, abmState, mdmState) in group {
                if let index = reports.firstIndex(where: { $0.serial == serial }) {
                    reports[index].abm = abmState
                    reports[index].mdm = mdmState
                }
                completedLookups += 1
                addNext()
            }
        }
    }

    /// Passes the row count so a refresh after a bulk change rebuilds the
    /// organization snapshot instead of asking Apple per device, which the
    /// request quota would stretch to hours.
    func refreshRows(_ serials: [String]) async {
        // The organizations those devices were found in. A refresh after an
        // action need not search the others: nothing happened to them, and
        // re-reading one costs a minute of its quota.
        let affected = Set(serials.compactMap { serial in
            reports.first { $0.serial == serial }?.abm.value?.orgID
        })
        let orgs = affected.isEmpty ? nil : settings.abmOrgs.filter { affected.contains($0.id) }
        let context = await makeContext(deviceCount: serials.count, orgs: orgs)
        for serial in serials {
            guard let index = reports.firstIndex(where: { $0.serial == serial }) else { continue }
            reports[index].abm = await Self.fetchABM(context: context, serial: serial)
            reports[index].mdm = await Self.fetchMDM(context: context, serial: serial)
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

    /// Which Apple service the selected organization belongs to, for wording
    /// and for the actions it supports.
    /// Which Apple service to word things for. The interface shows
    /// `appleScopeLabel`, which stays neutral when the organizations in scope
    /// are of both kinds; this is for action wording, where one organization
    /// has always been resolved first.
    var abmKind: AppleOrgKind { referenceABMOrg?.kind ?? .business }

    /// What to call the Apple side in a column header or a sentence: the one
    /// service when every organization in scope is the same kind, and plainly
    /// "Apple" when they are not.
    var appleScopeLabel: String {
        let kinds = Set(abmOrgsInScope.map(\.kind))
        guard kinds.count == 1, let kind = kinds.first else {
            return abmOrgsInScope.isEmpty ? abmKind.label : "Apple"
        }
        return kind.label
    }

    /// The one Apple organization an action can be carried out in, or nil
    /// when the selection gives no single answer.
    ///
    /// Every Apple action names a device management service, and a service ID
    /// means nothing outside the organization that issued it — so an action
    /// spanning two organizations has no valid request to make. A single
    /// device always resolves, which is why the inspector keeps working with
    /// every organization in scope and only bulk actions are restricted.
    func appleActionOrg(for reports: [DeviceReport]) -> ABMConfig? {
        let ids = Set(reports.compactMap { $0.abm.value?.orgID })
        if ids.count == 1, let id = ids.first {
            return settings.abmOrgs.first { $0.id == id }
        }
        // Nothing looked up yet, or nothing in an organization: fall back to
        // the one in scope, which is the single-organization case.
        return ids.isEmpty ? selectedABMOrg : nil
    }

    /// Why the Apple actions are unavailable for this selection, or nil.
    func appleActionUnavailableReason(for reports: [DeviceReport]) -> String? {
        guard appleActionOrg(for: reports) == nil else { return nil }
        let names = Set(reports.compactMap { $0.abm.value?.orgName }).sorted()
        switch names.count {
        case 0:
            // Reachable with every organization in scope and a selection of
            // devices none of them holds.
            return "None of the selected devices are in an Apple organization."
        case 1:
            // One organization resolved by name but no longer configured,
            // which is a different problem from spanning two.
            return "\(names[0]) is no longer configured, so its devices cannot be acted on."
        default:
            return "The selected devices are in \(names.formatted(.list(type: .and))). "
                + "Apple actions work in one organization at a time, so narrow the selection to one of them."
        }
    }

    /// Why devices cannot be released from this organization, or nil.
    func releaseUnavailabilityReason(for reports: [DeviceReport]) -> String? {
        if let reason = appleActionUnavailableReason(for: reports) { return reason }
        let kind = appleActionOrg(for: reports)?.kind ?? abmKind
        guard !kind.supportsRelease else { return nil }
        return "\(kind.label) provides no way to release devices from the organization."
    }

    /// The scope-wide answer, for wording that precedes a selection.
    var releaseUnavailabilityReason: String? {
        guard !abmKind.supportsRelease else { return nil }
        return "\(abmKind.label) provides no way to release devices from the organization."
    }

    /// Resolves the organization an action will run in, or throws the reason
    /// it cannot. Every Apple action starts here.
    private func actingOrg(for reports: [DeviceReport]) throws -> (config: ABMConfig, client: ABMClient) {
        if let reason = appleActionUnavailableReason(for: reports) { throw ActionError(message: reason) }
        guard let org = appleActionOrg(for: reports) else {
            throw ActionError(message: "\(abmKind.label) is not configured.")
        }
        guard let client = makeABMClient(for: org) else {
            throw ActionError(message: "\(org.displayName) is not configured.")
        }
        return (org, client)
    }

    /// Permanently releases the devices from the organization.
    func releaseFromABM(reports: [DeviceReport]) async throws {
        if let reason = releaseUnavailabilityReason(for: reports) { throw ActionError(message: reason) }
        let (org, abm) = try actingOrg(for: reports)
        let serials = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }.map(\.serial)
        guard !serials.isEmpty else { throw ActionError(message: "None of the selected devices are in \(org.displayName).") }
        try await recording(
            org.kind.activityService,
            "Released \(Self.deviceCount(serials)) from \(org.displayName)",
            serials: serials,
            orgName: org.displayName
        ) {
            let activityID = try await abm.submitActivity(.release, serials: serials)
            if let activityID { await abm.waitForActivity(id: activityID) }
        }
        invalidateSnapshot(for: org)
        await refreshRows(serials)
    }

    /// Assigns the devices to an MDM server, or unassigns them when `serverID` is nil.
    func setMDMServer(reports: [DeviceReport], to serverID: String?) async throws {
        let (org, abm) = try actingOrg(for: reports)
        let inOrg = reports.filter { $0.abm.value.map { !$0.isReleased } ?? false }
        guard !inOrg.isEmpty else { throw ActionError(message: "None of the selected devices are in \(org.displayName).") }

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
        let serverName = serverID.flatMap { id in allMDMServers.first { $0.id == id }?.name } ?? serverID
        let summary = serverName.map { "Assigned \(Self.deviceCount(serials)) to \($0)" }
            ?? "Unassigned \(Self.deviceCount(serials)) from device management"

        try await recording(org.kind.activityService, summary, serials: serials, orgName: org.displayName) {
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
        invalidateSnapshot(for: org)
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
        let (org, abm) = try actingOrg(for: reports)
        let serials = reports.map(\.serial)
        guard !serials.isEmpty else { throw ActionError(message: emptyMessage) }

        var summary: String
        switch type {
        case .assignWithMigrationDeadline:
            let name = mdmServerID.flatMap { id in allMDMServers.first { $0.id == id }?.name } ?? "another service"
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

        try await recording(org.kind.activityService, summary, serials: serials, orgName: org.displayName) {
            let activityID = try await abm.submitActivity(
                type,
                serials: serials,
                mdmServerID: mdmServerID,
                migrationDeadline: deadline
            )
            // Apple applies activities asynchronously, so wait before re-reading.
            if let activityID { await abm.waitForActivity(id: activityID) }
        }
        invalidateSnapshot(for: org)
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

    // MARK: Organization snapshot

    /// The organization snapshot for the selected Apple Business account,
    /// reading it first if necessary. Nil when Apple Business is not
    /// configured or the read fails, in which case callers fall back to
    /// asking per device.
    @discardableResult
    func organizationSnapshot(forceRefresh: Bool = false) async -> ABMSnapshot? {
        guard let org = referenceABMOrg else { return nil }
        return await organizationSnapshot(for: org, forceRefresh: forceRefresh)
    }

    /// Reads several organizations at once, returning the snapshots that
    /// succeeded.
    ///
    /// Apple's quota is per organization, so parallel reads do not contend
    /// and the wall-clock cost is the slowest organization rather than the
    /// sum. The progress text counts organizations rather than devices:
    /// several device counts arriving at once would be unreadable, and it is
    /// the number of organizations that explains the wait.
    private func readSnapshots(_ pairs: [(org: ABMConfig, client: ABMClient)]) async -> [UUID: ABMSnapshot] {
        guard !pairs.isEmpty else { return [:] }
        // One organization keeps its per-device progress, which is the
        // single-organization experience unchanged.
        if pairs.count == 1 {
            return await organizationSnapshot(for: pairs[0].org).map { [pairs[0].org.id: $0] } ?? [:]
        }
        isBuildingSnapshot = true
        snapshotStatus = "Reading \(pairs.count) organizations…"
        defer { isBuildingSnapshot = false; snapshotStatus = nil }

        var results: [UUID: ABMSnapshot] = [:]
        var done = 0
        await withTaskGroup(of: (ABMConfig, Result<ABMSnapshot, any Error>).self) { group in
            for pair in pairs {
                group.addTask {
                    do { return (pair.org, .success(try await pair.client.organizationSnapshot())) }
                    catch { return (pair.org, .failure(error)) }
                }
            }
            for await (org, result) in group {
                done += 1
                snapshotStatus = "Read \(done) of \(pairs.count) organizations…"
                switch result {
                case .success(let snapshot):
                    abmSnapshots[org.id] = snapshot
                    results[org.id] = snapshot
                    recordAction(
                        org.kind.activityService,
                        "Read the organization: \(Self.deviceCount(snapshot.devices.count))",
                        serials: [],
                        orgName: org.displayName
                    )
                case .failure(let error):
                    recordAction(
                        org.kind.activityService,
                        "Could not read the organization — \(error.localizedDescription)",
                        serials: [],
                        outcome: .failed,
                        orgName: org.displayName
                    )
                }
            }
        }
        return results
    }

    /// Reads one organization, or returns the snapshot already held for it.
    ///
    /// The progress text names the organization when several are being read,
    /// so a minute of "Reading devices…" says which one it is waiting on.
    @discardableResult
    func organizationSnapshot(for org: ABMConfig, forceRefresh: Bool = false) async -> ABMSnapshot? {
        guard let abm = makeABMClient(for: org) else { return nil }
        if !forceRefresh, let cached = abmSnapshots[org.id] { return cached }
        isBuildingSnapshot = true
        snapshotStatus = nil
        defer { isBuildingSnapshot = false; snapshotStatus = nil }
        let prefix = readsAllABMOrgs ? "\(org.displayName): " : ""
        do {
            let snapshot = try await abm.organizationSnapshot { progress in
                Task { @MainActor in self.snapshotStatus = prefix + progress.description }
            }
            abmSnapshots[org.id] = snapshot
            recordAction(
                org.kind.activityService,
                "Read the organization: \(Self.deviceCount(snapshot.devices.count))",
                serials: [],
                orgName: org.displayName
            )
            return snapshot
        } catch {
            recordAction(
                org.kind.activityService,
                "Could not read the organization — \(error.localizedDescription)",
                serials: [],
                outcome: .failed,
                orgName: org.displayName
            )
            return nil
        }
    }

    /// Compliance for one device, or nil when the connection has no source
    /// for it, the integration is off, or the device is out of its scope.
    ///
    /// Read on selection rather than during a lookup: Jamf Pro serves it one
    /// device at a time, so a bulk lookup would cost a request per device for
    /// a value most rows never show. Intune reports compliance in its tenant
    /// read instead, which is why that one arrives with the lookup.
    func deviceCompliance(for report: DeviceReport) async -> JamfDeviceCompliance? {
        guard mdmCapabilities.contains(.complianceOnDemand),
              let info = report.mdm.value,
              let server = selectedConnection,
              let jamf = makeJamfClient() else { return nil }
        // The instance-wide toggle first, so a fleet with the integration off
        // never pays a request per device. A toggle that cannot be read is
        // left undetermined and the per-device call decides.
        if deviceComplianceEnabled[server.id] == false { return nil }
        if deviceComplianceEnabled[server.id] == nil,
           let enabled = try? await jamf.deviceComplianceEnabled() {
            deviceComplianceEnabled[server.id] = enabled
            if !enabled { return nil }
        }
        return try? await jamf.deviceCompliance(kind: info.kind, deviceID: info.recordID)
    }

    /// Which ADE token synced a serial, for filtering the PreStage pickers.
    /// Nil until the map has been read, which leaves the pickers offering
    /// every PreStage.
    func adeInstance(forSerial serial: String) -> String? {
        guard let id = selectedConnectionID else { return nil }
        return adeInstances[id]?[serial.uppercased()]
    }

    /// Reads which ADE token synced each device in the instance.
    ///
    /// Deliberately not part of a lookup. The map covers every device the
    /// instance has ever synced through a token, so it costs the same for one
    /// device as for four hundred, and Jamf serves it 500 devices at a time —
    /// a large token takes the best part of a minute. Only the PreStage
    /// pickers read it, and both fall back to the full list without it, so it
    /// is read when a device is selected and then kept for the session.
    func loadADEInstances() async {
        guard let server = selectedConnection,
              server.capabilities.contains(.prestageScope),
              adeInstances[server.id] == nil else { return }
        if let inFlight = adeInstanceReads[server.id] {
            _ = await inFlight.value
            return
        }
        guard let jamf = makeJamfClient() else { return }
        let read = Task { try? await jamf.adeInstanceBySerial() }
        adeInstanceReads[server.id] = read
        // An empty map is kept: an instance may simply have no ADE devices,
        // and re-walking every token to learn that again would be the slow
        // path for nothing. A failed read is not kept, so it can be retried.
        if let map = await read.value {
            adeInstances[server.id] = map
        }
        adeInstanceReads[server.id] = nil
    }

    /// Order numbers in the organization, with how many devices each covers.
    /// Reads the organization if it has not been read already.
    /// Reads every organization in scope again, for the order picker's
    /// refresh: an order added since the last read appears in none of the
    /// snapshots until they are rebuilt.
    func refreshOrganizationsInScope() async {
        for org in abmOrgsInScope { abmSnapshots[org.id] = nil }
        let pairs = abmOrgsInScope.compactMap { org in
            makeABMClient(for: org).map { (org: org, client: $0) }
        }
        _ = await readSnapshots(pairs)
    }

    /// Snapshots for every organization in scope, reading whichever are
    /// missing together rather than one after another.
    ///
    /// The order picker needs all of them before it can show anything, so
    /// reading them in sequence would cost their sum — the same trap the
    /// lookup path avoids.
    private func snapshotsInScope() async -> [ABMSnapshot] {
        let pairs = abmOrgsInScope
            .filter { cachedSnapshot(for: $0) == nil }
            .compactMap { org in makeABMClient(for: org).map { (org: org, client: $0) } }
        _ = await readSnapshots(pairs)
        return abmOrgsInScope.compactMap { abmSnapshots[$0.id] }
    }

    /// Order numbers across every organization in scope, most devices first.
    ///
    /// An order belongs to the organization that bought under it, so the same
    /// number appearing in two organizations would be two different orders —
    /// possible in principle, and the counts are summed rather than one
    /// hiding the other.
    func abmOrders() async -> [(number: String, count: Int)] {
        var counts: [String: Int] = [:]
        for snapshot in await snapshotsInScope() {
            for order in snapshot.orders { counts[order.number, default: 0] += order.count }
        }
        return counts
            .map { (number: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.number) > ($1.count, $0.number) }
    }

    /// The serial numbers on an order.
    /// Every serial on that order across the organizations in scope.
    func serials(inOrder order: String) async -> [String] {
        var serials: [String] = []
        for snapshot in await snapshotsInScope() {
            serials += snapshot.serials(inOrder: order)
        }
        return serials.sorted()
    }

    /// The snapshot already held for the selected organization, without
    /// reading one.
    private func cachedSnapshot(for org: ABMConfig) -> ABMSnapshot? {
        abmSnapshots[org.id]
    }

    /// Whether a lookup of this many devices would have to read the whole
    /// Apple Business organization first, which takes about a minute. False
    /// once a snapshot has been read, since it is reused.
    /// Whether a lookup of this size has to read an organization first, which
    /// is what makes a lookup take a minute. True while any organization in
    /// scope still needs reading.
    func needsOrganizationRead(forDeviceCount count: Int) -> Bool {
        guard isABMConfigured else { return false }
        guard count >= Self.snapshotThreshold else { return false }
        return abmOrgsInScope.contains { cachedSnapshot(for: $0) == nil }
    }

    /// Discards the cached snapshot for the selected organization. Called
    /// after anything that changes Apple Business, so the next bulk lookup
    /// does not report the state from before the change.
    /// Discards one organization's snapshot, after a change to it.
    ///
    /// Scoped deliberately: an action runs in a single organization, and
    /// dropping every snapshot would make the refresh that follows re-read
    /// organizations nothing had happened to — a minute of quota each.
    private func invalidateSnapshot(for org: ABMConfig) {
        abmSnapshots[org.id] = nil
    }

    // MARK: Groups

    /// Every computer and mobile device group on the selected server, both
    /// smart and static, sorted for display.
    /// Jamf School keeps one list of device groups rather than splitting them
    /// by device kind, so its groups come back in a single request.
    func jamfGroups() async throws -> [JamfGroup] {
        if let school = makeJamfSchoolClient() {
            return try await school.groups().sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        guard let jamf = makeJamfClient() else {
            throw ActionError(message: "No \(mdmProduct.label) server is selected or configured.")
        }
        var all: [JamfGroup] = []
        for kind in JamfGroupKind.allCases {
            all += try await jamf.groups(kind: kind)
        }
        return all.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The serial numbers in a group.
    func serials(in group: JamfGroup) async throws -> [String] {
        if let school = makeJamfSchoolClient() {
            var seen = Set<String>()
            return try await school.devices(inGroup: group.id)
                .map { $0.serialNumber.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        guard let jamf = makeJamfClient() else {
            throw ActionError(message: "No \(mdmProduct.label) server is selected or configured.")
        }
        return try await jamf.groupSerials(group)
    }

    // MARK: Per-device detail

    // Fetched when a device is selected rather than during a lookup: each
    // costs a request per device, and a lookup of several hundred serials
    // should not pay for detail that only the inspector shows.

    /// AppleCare coverage for one device. Apple has no bulk endpoint for it,
    /// so a lookup that read the organization in bulk leaves it out and the
    /// inspector fetches it for whichever device is selected.
    func appleCareCoverage(for report: DeviceReport) async -> [AppleCareCoverage]? {
        guard let info = report.abm.value, !info.coverageLoaded, !info.isReleased,
              let abm = clientForOrg(of: info) else { return nil }
        // Empty rather than nil on failure: nil keeps the inspector's
        // progress indicator up, and it would never resolve.
        return (try? await abm.appleCareCoverage(serial: report.serial)) ?? []
    }

    /// Whether the device is Activation Locked, and by whom.
    ///
    /// Read for the selected device only: Apple serves it one device at a
    /// time, the same as AppleCare coverage. It comes from the Apple
    /// organization deliberately — the organization knows the live state and
    /// distinguishes an MDM lock from a user's, which no MDM inventory does.
    func activationLock(for report: DeviceReport) async -> ABMActivationLock? {
        guard let info = report.abm.value, !info.isReleased,
              let abm = clientForOrg(of: info) else { return nil }
        return try? await abm.activationLock(serial: report.serial)
    }

    /// The client for the organization a device was found in, falling back to
    /// the one in scope for a record from before organizations were recorded.
    private func clientForOrg(of info: ABMInfo) -> ABMClient? {
        guard let id = info.orgID, let org = settings.abmOrgs.first(where: { $0.id == id }) else {
            return makeABMClient()
        }
        return makeABMClient(for: org)
    }

    /// Passcode state for one device on Jamf School.
    ///
    /// Its list endpoint omits `hasPasscode` entirely; only the per-device
    /// record carries it. So this is read for whichever device is selected,
    /// rather than making every lookup pay a request per device for a value
    /// the table does not show.
    func jamfSchoolDetails(for report: DeviceReport) async -> JamfSchoolDeviceDetails? {
        guard let info = report.mdm.value, let school = makeJamfSchoolClient(),
              let udid = info.udid, !udid.isEmpty else { return nil }
        return try? await school.deviceDetails(udid: udid)
    }

    /// What the device last reported about itself declaratively: its software
    /// update state and the declarations it has processed. One request serves
    /// both. Nil when it has reported nothing.
    func ddmStatus(for report: DeviceReport) async -> JamfDDMStatus? {
        guard let info = report.mdm.value, let jamf = makeJamfClient(),
              let managementID = info.managementID, !managementID.isEmpty else { return nil }
        guard let status = try? await jamf.ddmStatus(managementID: managementID) else { return nil }
        // The status report is still the only source for the software update
        // half, so it is always read. On a gateway connection the platform
        // will also report the declarations as typed JSON, which is worth
        // preferring over parsing them out of a flattened status item — but
        // only if it answers, since losing the row would be worse than a
        // fragile parse.
        guard let typed = try? await jamf.platformDeclarations(serial: report.serial), !typed.isEmpty else {
            return status
        }
        return JamfDDMStatus(
            softwareUpdate: status.softwareUpdate,
            declarations: typed,
            reportedAt: status.reportedAt
        )
    }

    /// The software update target the device is being held to.
    ///
    /// The status report names the device's declarations but not what they
    /// contain, so the enforced version is read back from the server. Worth
    /// the extra requests only for the device being looked at, which is why
    /// this is separate from the status fetch.
    func updateEnforcement(in status: JamfDDMStatus) async -> JamfUpdateEnforcement? {
        guard let jamf = makeJamfClient() else { return nil }
        let candidates = status.declarationsWorthResolving()
        guard !candidates.isEmpty else { return nil }
        return await jamf.updateEnforcement(among: candidates)
    }

    /// The name of a blueprint, when the connection can resolve one.
    ///
    /// Read once per server and kept: the list is server-wide and small, and
    /// several devices in a selection usually share a blueprint. A direct
    /// Jamf Pro connection has no blueprints endpoint, so this stays nil and
    /// callers fall back to the identifier.
    func blueprintName(for id: String) async -> String? {
        guard let server = selectedConnection,
              server.capabilities.contains(.blueprintNames),
              let jamf = makeJamfClient() else { return nil }
        if let cached = blueprintNames[server.id] { return cached[id] }
        let names = (try? await jamf.blueprintNames()) ?? [:]
        blueprintNames[server.id] = names
        return names[id]
    }

    /// The managed local administrator accounts for a Mac, or an empty list
    /// when there are none, the device is not a Mac, or the connection lacks
    /// the privilege. Called during ordinary browsing, so it never throws.
    func localAdminAccounts(for report: DeviceReport) async -> [JamfLocalAdminAccount] {
        guard let info = report.mdm.value, info.kind == .computer,
              let managementID = info.managementID, !managementID.isEmpty,
              let jamf = makeJamfClient() else { return [] }
        return (try? await jamf.localAdminAccounts(managementID: managementID)) ?? []
    }

    /// How long after being viewed Jamf Pro rotates a local administrator
    /// password. Nil when the setting cannot be read.
    ///
    /// This is a server-wide setting, so it is read once per server rather
    /// than each time a device is selected.
    func localAdminRotationTime() async -> TimeInterval? {
        guard let serverID = selectedConnection?.id else { return nil }
        if let cached = rotationTimes[serverID] { return cached }
        guard let jamf = makeJamfClient(),
              let seconds = try? await jamf.localAdminRotationTime(), seconds > 0 else { return nil }
        let interval = TimeInterval(seconds)
        rotationTimes[serverID] = interval
        return interval
    }

    /// Reads a managed local administrator password. Recorded as a change
    /// rather than a read, because viewing queues a rotation.
    func localAdminPassword(for report: DeviceReport, account: JamfLocalAdminAccount) async throws -> String {
        guard let info = report.mdm.value else {
            throw ActionError(message: "\(report.serial) has no Jamf Pro record.")
        }
        guard info.kind == .computer else {
            throw ActionError(message: "Local administrator passwords apply to Macs only.")
        }
        guard let managementID = info.managementID, !managementID.isEmpty else {
            throw ActionError(message: "\(report.serial) has no management ID. Run a fresh lookup first.")
        }
        guard let jamf = makeJamfClient() else {
            throw ActionError(message: "No Jamf Pro server is selected or configured.")
        }
        let summary = "Read the local administrator password for \(account.username) on \(report.serial), queuing a rotation"
        return try await recording(.jamfPro, summary, serials: [report.serial]) {
            guard let password = try await jamf.localAdminPassword(managementID: managementID, account: account) else {
                throw ActionError(message: "Jamf Pro holds no password for \(account.username) on \(report.serial).")
            }
            return password
        }
    }

    private func computerID(for report: DeviceReport, action: String) throws -> String {
        guard let info = report.mdm.value else {
            throw ActionError(message: "\(report.serial) has no Jamf Pro record.")
        }
        guard info.kind == .computer else {
            throw ActionError(message: "\(action) apply to Macs only.")
        }
        return info.recordID
    }

    /// Removes the devices' records. Jamf Pro and Intune delete them; Jamf
    /// School moves them to its trash, from where they can be restored.
    ///
    /// Deleting an Intune record does nothing to the device: it stays enrolled
    /// and reappears at its next check-in. Retiring it, which is what Remove
    /// MDM Profile sends there, is the one that unmanages it.
    func deleteMDMRecord(reports: [DeviceReport]) async throws {
        let product = mdmProduct
        let school = makeJamfSchoolClient()
        let intune = makeIntuneClient()
        let jamf = (school == nil && intune == nil) ? makeJamfClient() : nil
        guard school != nil || intune != nil || jamf != nil else {
            throw ActionError(message: "No \(product.label) \(product.connectionNoun) is selected or configured.")
        }
        let withRecords = reports.compactMap { report in
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }
        guard !withRecords.isEmpty else {
            throw ActionError(message: "None of the selected devices have a \(product.label) record.")
        }
        var failures: [String] = []
        for entry in withRecords {
            do {
                if let school {
                    try await school.trash(udid: entry.info.recordID)
                } else if let intune {
                    try await intune.deleteDevice(id: entry.info.recordID)
                } else if let jamf {
                    switch entry.info.kind {
                    case .computer:
                        try await jamf.deleteComputer(id: entry.info.recordID)
                    case .mobileDevice:
                        try await jamf.deleteMobileDevice(id: entry.info.recordID)
                    }
                }
            } catch {
                failures.append("\(entry.serial): \(error.localizedDescription)")
            }
        }
        recordAction(
            product.activityService,
            Self.partialSummary(
                product.removeRecordPastTense,
                noun: "record",
                of: withRecords.count,
                failed: failures.count,
                from: product.label
            ),
            serials: withRecords.map(\.serial),
            outcome: failures.isEmpty ? .succeeded : .failed
        )
        await refreshRows(withRecords.map(\.serial))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    /// Moves the devices to another Jamf School location, that product's
    /// equivalent of a site.
    ///
    /// Sent through the bulk endpoint in chunks, which is also what makes a
    /// single-device move safe: the per-device path takes an identifier that
    /// is documented nowhere, while the bulk one takes UDIDs explicitly.
    func setLocation(reports: [DeviceReport], to locationID: String) async throws {
        guard let school = makeJamfSchoolClient() else {
            throw ActionError(message: "No Jamf School server is selected or configured.")
        }
        let moving = reports.compactMap { report in
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }.filter { $0.info.locationID != locationID }
        guard !moving.isEmpty else { return }
        let name = jamfLocations.first { $0.id == locationID }?.name ?? locationID
        let summary = "Moved \(Self.deviceCount(moving.map(\.serial))) to \(name)"
        try await recording(.jamfSchool, summary, serials: moving.map(\.serial)) {
            let outcome = try await school.move(udids: moving.map(\.info.recordID), toLocation: locationID)
            // The endpoint reports per device inside a success, so a device
            // that never moved has to be named here or the action would claim
            // to have moved it.
            guard outcome.unmoved.isEmpty else {
                let unmoved = Set(outcome.unmoved)
                let serials = moving
                    .filter { unmoved.contains($0.info.recordID) }
                    .map(\.serial)
                let named = serials.isEmpty ? outcome.unmoved : serials
                // Nearly always the owner: Jamf School refuses to move a
                // device away from the location its assigned user is in.
                throw ActionError(message: """
                    Jamf School did not move: \(named.joined(separator: ", ")).
                    A device with an assigned owner can only change location if the owner is in the district, or if Cross Location Enrollment is enabled.
                    """)
            }
        }
        await refreshRows(moving.map(\.serial))
    }

    /// Moves the devices of the given kind between PreStage scopes. Pass nil
    /// to remove them from their current PreStage without adding them to
    /// another. Devices of the other kind in `reports` are skipped.
    func setPrestage(reports: [DeviceReport], to newID: String?, kind: DeviceKind) async throws {
        guard let jamf = makeJamfClient() else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
        let family: JamfPrestageFamily = kind == .computer ? .computer : .mobileDevice
        var removeByPrestage: [String: [String]] = [:]
        var affected: [String] = []
        for report in reports {
            guard report.deviceKind == kind else { continue }
            let current = report.mdm.value?.prestageID
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
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }.filter { ($0.info.siteID ?? "-1") != siteID }
        guard !withRecords.isEmpty else { return }
        var failures: [String] = []
        for entry in withRecords {
            do {
                switch entry.info.kind {
                case .computer:
                    try await jamf.setComputerSite(computerID: entry.info.recordID, siteID: siteID)
                case .mobileDevice:
                    try await jamf.setMobileDeviceSite(deviceID: entry.info.recordID, siteID: siteID)
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
        let product = mdmProduct
        let school = makeJamfSchoolClient()
        let intune = makeIntuneClient()
        let jamf = (school == nil && intune == nil) ? makeJamfClient() : nil
        guard school != nil || intune != nil || jamf != nil else {
            throw ActionError(message: "No \(product.label) \(product.connectionNoun) is selected or configured.")
        }
        // Fail before doing any work, so a command the connection cannot carry
        // never gets as far as a confirmation prompt.
        if let reason = unavailabilityReason(for: command) {
            throw ActionError(message: reason)
        }
        let targets = reports.compactMap { report in
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }.filter { command.applies(to: $0.info.kind, product: product) }
        guard !targets.isEmpty else {
            throw ActionError(message: "\(command.title) doesn't apply to any of the selected devices.")
        }

        let serials = targets.map(\.serial)
        do {
            let sent: Int
            if let school {
                sent = try await routeSchool(command, school: school, targets: targets)
            } else if let intune {
                sent = try await routeIntune(command, intune: intune, targets: targets)
            } else if let jamf {
                sent = try await route(command, jamf: jamf, targets: targets, passcode: passcode)
            } else {
                sent = 0
            }
            recordAction(product.activityService, "Sent \(command.title) to \(Self.deviceCount(sent))", serials: serials)
            return sent
        } catch {
            recordAction(
                product.activityService,
                "\(command.title) failed — \(error.localizedDescription)",
                serials: serials,
                outcome: .failed
            )
            throw error
        }
    }

    /// Routes a command to its Jamf School endpoint.
    ///
    /// Straightforward compared with the Jamf Pro side: every command is one
    /// request per device against a single device resource, and there is no
    /// computer/mobile split to route around, so a Mac and an iPad take the
    /// same path. Failures are collected per device rather than abandoning the
    /// rest of the selection.
    private func routeSchool(
        _ command: MDMCommand,
        school: JamfSchoolClient,
        targets: [(serial: String, info: ManagedDeviceInfo)]
    ) async throws -> Int {
        var failures: [String] = []
        var sent = 0
        for target in targets {
            let udid = target.info.recordID
            do {
                switch command {
                case .updateInventory:
                    try await school.refreshInventory(udid: udid)
                case .restartMobile:
                    try await school.restart(udid: udid)
                case .wipeComputer, .wipeMobile:
                    try await school.wipe(udid: udid)
                case .unmanage:
                    try await school.unenroll(udid: udid)
                default:
                    // Not offered for Jamf School, so unreachable through the
                    // interface; refused here rather than silently skipped.
                    throw ActionError(message: "\(command.title) is not available in Jamf School.")
                }
                sent += 1
            } catch {
                failures.append("\(target.serial): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
        return sent
    }

    /// Routes a command to its Intune action.
    ///
    /// One request per device, like Jamf School, because Graph's device
    /// actions take no device list. Failures are collected per device rather
    /// than abandoning the rest of the selection.
    ///
    /// Every action here answers 204 with no body, so there is no per-device
    /// outcome hidden inside a success to check for — unlike Jamf School's
    /// envelope or Jamf Pro's `udidsNotProcessed`. Whether the device then
    /// acts on it is reported by Intune as a device action result, which
    /// Checkpoint does not poll.
    private func routeIntune(
        _ command: MDMCommand,
        intune: IntuneClient,
        targets: [(serial: String, info: ManagedDeviceInfo)]
    ) async throws -> Int {
        var failures: [String] = []
        var sent = 0
        for target in targets {
            let id = target.info.recordID
            do {
                switch command {
                case .updateInventory:
                    try await intune.perform(.sync, deviceID: id)
                case .restartMobile:
                    try await intune.perform(.restart, deviceID: id)
                case .shutDownMobile:
                    try await intune.perform(.shutDown, deviceID: id)
                case .lockMobile:
                    try await intune.perform(.remoteLock, deviceID: id)
                case .clearPasscode:
                    try await intune.perform(.resetPasscode, deviceID: id)
                case .unmanage:
                    try await intune.perform(.retire, deviceID: id)
                case .wipeComputer, .wipeMobile:
                    try await intune.wipe(deviceID: id)
                default:
                    // Not offered for Intune, so unreachable through the
                    // interface; refused here rather than silently skipped.
                    throw ActionError(message: "\(command.title) is not available in Intune.")
                }
                sent += 1
            } catch {
                failures.append("\(target.serial): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
        return sent
    }

    /// Routes a command to whichever endpoint carries it for these targets.
    private func route(
        _ command: MDMCommand,
        jamf: JamfClient,
        targets: [(serial: String, info: ManagedDeviceInfo)],
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
                        try await jamf.eraseComputer(computerID: target.info.recordID, pin: passcode)
                    case (.wipeMobile, .mobileDevice):
                        try await jamf.eraseMobileDevice(deviceID: target.info.recordID)
                    case (.unmanage, .computer):
                        try await jamf.removeMDMProfile(computerID: target.info.recordID)
                    case (.unmanage, .mobileDevice):
                        try await jamf.unmanageMobileDevice(deviceID: target.info.recordID)
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
                    try await jamf.redeployFramework(computerID: target.info.recordID)
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
        for kind in [DeviceKind.computer, .mobileDevice] {
            guard let commandData = command.modernCommandData(for: kind, passcode: command.needsPIN() ? passcode : nil) else { continue }
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
                    try await jamf.sendMobileDeviceCommand("UpdateInventory", deviceID: target.info.recordID)
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
        referenceABMOrg.flatMap { makeABMClient(for: $0) }
    }

    private func makeABMClient(for config: ABMConfig) -> ABMClient? {
        guard config.isConfigured,
              let pem = Keychain.get(config.privateKeyKeychainKey), !pem.isEmpty else { return nil }
        let key = [config.id.uuidString, config.clientID, config.keyID, pem].joined(separator: "|")
        if let cached = abmClients[key] { return cached }
        let client = ABMClient(
            clientID: config.clientID,
            keyID: config.keyID,
            privateKeyPEM: pem,
            kind: config.kind,
            connectionName: config.displayName,
            log: log
        )
        abmClients[key] = client
        return client
    }

    /// The Jamf Pro client, or nil when the selected server is not a Jamf Pro
    /// one. The product guard matters: without it a Jamf Pro request would be
    /// sent to a Jamf School host, which answers something unrecognisable
    /// rather than refusing.
    private func makeJamfClient() -> JamfClient? {
        guard let config = selectedConnection, config.product == .jamfPro,
              let secret = Keychain.get(config.secretKeychainKey), !secret.isEmpty else { return nil }
        let key = [config.id.uuidString, config.normalizedBaseURL, config.authMethod.rawValue, config.account, secret].joined(separator: "|")
        if let cached = jamfClients[key] { return cached }
        guard let client = JamfClient(config: config, secret: secret, log: log) else { return nil }
        jamfClients[key] = client
        return client
    }

    private func makeIntuneClient() -> IntuneClient? {
        guard let config = selectedConnection, config.product == .intune,
              let secret = Keychain.get(config.secretKeychainKey), !secret.isEmpty else { return nil }
        let key = [config.id.uuidString, config.tenantID, config.account, secret].joined(separator: "|")
        if let cached = intuneClients[key] { return cached }
        guard let client = IntuneClient(config: config, secret: secret, log: log) else { return nil }
        intuneClients[key] = client
        return client
    }

    private func makeJamfSchoolClient() -> JamfSchoolClient? {
        guard let config = selectedConnection, config.product == .jamfSchool,
              let secret = Keychain.get(config.secretKeychainKey), !secret.isEmpty else { return nil }
        let key = [config.id.uuidString, config.normalizedBaseURL, config.account, secret].joined(separator: "|")
        if let cached = jamfSchoolClients[key] { return cached }
        guard let client = JamfSchoolClient(config: config, secret: secret, log: log) else { return nil }
        jamfSchoolClients[key] = client
        return client
    }

    /// One Apple organization as a lookup sees it: its client, its snapshot
    /// if one was read, and the names its device management services go by.
    private struct ABMOrgContext: Sendable {
        let id: UUID
        let name: String
        let kind: AppleOrgKind
        let client: ABMClient
        var snapshot: ABMSnapshot?
        /// True when a snapshot was wanted and could not be read. The
        /// per-device path is not a substitute for it: at three requests per
        /// device against Apple's quota, a large lookup would crawl instead
        /// of saying plainly that the organization could not be read.
        var snapshotFailed = false
        var mdmServerNames: [String: String] = [:]
    }

    private struct LookupContext: Sendable {
        /// Every organization in scope, in configured order. A device belongs
        /// to at most one, so the first that reports it wins — except that a
        /// device released from one and re-added to another appears in both,
        /// which is why an active record is preferred over a released one.
        var abmOrgs: [ABMOrgContext] = []
        var proClient: JamfClient?
        var schoolClient: JamfSchoolClient?
        var intuneClient: IntuneClient?
        var consoleBaseURL: String?
        /// Every device in the Jamf School instance, keyed by serial. Read in
        /// one request whatever the size of the lookup, because Jamf School
        /// serves the whole fleet at once and per-device lookups would only
        /// be slower.
        var schoolFleet: [String: JamfSchoolDevice] = [:]
        var schoolLocationNames: [String: String] = [:]
        /// The zone the instance reports its timestamps in. Its check-in times
        /// carry no offset, so without this they would be read in whatever
        /// zone the Mac happens to be in.
        var schoolTimeZone: TimeZone?
        var computerPrestageBySerial: [String: String] = [:]
        var computerPrestageNames: [String: String] = [:]
        var mobilePrestageBySerial: [String: String] = [:]
        var mobilePrestageNames: [String: String] = [:]
        /// Every managed device in the Intune tenant, keyed by serial. Read in
        /// pages rather than per device because Graph documents no $filter on
        /// serialNumber, so there is no per-serial query to make.
        var intuneFleet: [String: IntuneDevice] = [:]
    }

    /// Builds the clients and snapshots a lookup reads from.
    ///
    /// `orgs` narrows the Apple side to particular organizations, which is
    /// what a refresh after an action passes: the devices it is refreshing
    /// are known to belong to one organization, and the others have not
    /// changed.
    private func makeContext(deviceCount: Int = 0, orgs: [ABMConfig]? = nil) async -> LookupContext {
        var context = LookupContext(
            proClient: makeJamfClient(),
            schoolClient: makeJamfSchoolClient(),
            intuneClient: makeIntuneClient(),
            consoleBaseURL: selectedConnection?.normalizedBaseURL
        )
        // One entry per organization being read. A snapshot already in hand
        // answers instantly, so it is used whatever the size of the lookup.
        // Reading one is worth it when asking per device would be slower, or
        // when several organizations are in play, where asking per device
        // would mean asking each of them in turn.
        let orgsToRead = orgs ?? abmOrgsInScope
        // The threshold alone decides, however many organizations are in
        // scope. Asking per device across several is far cheaper than it
        // looks: an organization that does not hold the device answers 404
        // to the first request and costs nothing more, so a serial costs one
        // request per organization plus two for the one that has it. Reading
        // an organization in full costs a request per thousand devices plus
        // one per device management service, which on a real tenant is a few
        // dozen and can cross Apple's per-minute quota on its own.
        let readInBulk = deviceCount >= Self.snapshotThreshold
        let pairs = orgsToRead.compactMap { org in
            makeABMClient(for: org).map { (org: org, client: $0) }
        }
        let needSnapshots = readInBulk
            ? pairs.filter { cachedSnapshot(for: $0.org) == nil }
            : []
        let fresh = await readSnapshots(needSnapshots)
        // A snapshot already carries the organization's services, so only
        // the organizations without one need asking. Those are read together
        // rather than one after another.
        let needServices = pairs.filter { pair in
            (cachedSnapshot(for: pair.org) ?? fresh[pair.org.id]) == nil
        }
        let servers = await withTaskGroup(of: (UUID, [MDMServer]?).self) { group in
            for pair in needServices {
                group.addTask { (pair.org.id, try? await pair.client.mdmServers()) }
            }
            var byOrg: [UUID: [MDMServer]?] = [:]
            for await (id, list) in group { byOrg[id] = list }
            return byOrg
        }
        for pair in pairs {
            let org = pair.org
            var entry = ABMOrgContext(id: org.id, name: org.displayName, kind: org.kind, client: pair.client)
            entry.snapshot = cachedSnapshot(for: org) ?? fresh[org.id]
            entry.snapshotFailed = readInBulk && entry.snapshot == nil
            if let list = entry.snapshot?.servers ?? (servers[org.id] ?? nil) {
                mdmServersByOrg[org.id] = list
            }
            entry.mdmServerNames = Dictionary(
                (mdmServersByOrg[org.id] ?? []).map { ($0.id, $0.name) }
            ) { first, _ in first }
            context.abmOrgs.append(entry)
        }
        if let jamf = context.proClient {
            // Started together rather than one after another. All five are
            // independent, and every one has to finish before the first
            // device is looked up, so serially they were five round trips of
            // dead time at the head of every lookup.
            async let computerPrestages = try? jamf.prestages(family: .computer)
            async let mobileDevicePrestages = try? jamf.prestages(family: .mobileDevice)
            async let siteList = try? jamf.sites()
            async let computerScope = try? jamf.prestageAssignments(family: .computer)
            async let mobileScope = try? jamf.prestageAssignments(family: .mobileDevice)
            if let list = await computerPrestages {
                prestages = list
            }
            if let list = await mobileDevicePrestages {
                mobilePrestages = list
            }
            if let list = await siteList {
                sites = list
            }
            context.computerPrestageNames = Dictionary(prestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.mobilePrestageNames = Dictionary(mobilePrestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            context.computerPrestageBySerial = await computerScope ?? [:]
            context.mobilePrestageBySerial = await mobileScope ?? [:]
        }
        if let intune = context.intuneClient {
            // One read for the tenant, however many serials are being looked
            // up. Graph pages at a thousand, so a few thousand devices cost a
            // handful of requests against a per-device cost of one each.
            context.intuneFleet = (try? await intune.fleet()) ?? [:]
        }
        if let school = context.schoolClient {
            // The whole fleet in one request. Jamf School offers no
            // pagination and no per-device serial route worth using, and has
            // no request quota, so this is both simpler and cheaper than
            // asking device by device.
            async let fleet = try? school.fleet()
            async let locationList = try? school.locations()
            context.schoolFleet = await fleet ?? [:]
            if let list = await locationList {
                jamfLocations = list
            }
            context.schoolLocationNames = Dictionary(jamfLocations.map { ($0.id, $0.name) }) { first, _ in first }
            // Left until last: it reads one device out of the fleet above.
            context.schoolTimeZone = await jamfSchoolTimeZone(school: school, fleet: context.schoolFleet)
        }
        return context
    }

    /// The zone a Jamf School instance stamps its times in.
    ///
    /// Only the per-device endpoint names it, and it is the same for the whole
    /// instance, so it is read from one arbitrary device and then kept for the
    /// session. Nil leaves times to be read as local, which is right often
    /// enough and wrong only by an offset.
    private func jamfSchoolTimeZone(
        school: JamfSchoolClient,
        fleet: [String: JamfSchoolDevice]
    ) async -> TimeZone? {
        guard let serverID = selectedConnection?.id else { return nil }
        if let cached = jamfSchoolTimeZones[serverID] { return cached }
        guard let udid = fleet.values.first?.udid,
              let details = try? await school.deviceDetails(udid: udid),
              let zone = details.timeZone else { return nil }
        jamfSchoolTimeZones[serverID] = zone
        return zone
    }

    /// Finds the device in whichever organization in scope holds it.
    ///
    /// A device belongs to one organization at a time, so the search stops at
    /// the first that reports it — with one exception: a device released from
    /// one organization and re-added to another is reported by both, so an
    /// active record is preferred over a released one. A failure is only
    /// reported when no organization found the device, since one unreachable
    /// organization should not hide a device another one holds.
    private static func fetchABM(context: LookupContext, serial: String) async -> FetchState<ABMInfo> {
        guard !context.abmOrgs.isEmpty else { return .notConfigured }
        var released: ABMInfo?
        var failure: String?
        for org in context.abmOrgs {
            switch await fetchABM(org: org, serial: serial) {
            case .found(let info) where info.isReleased:
                // Kept in case no organization has it as an active device.
                if released == nil { released = info }
            case .found(let info):
                return .found(info)
            case .failed(let message):
                if failure == nil { failure = message }
            case .notFound, .pending, .notConfigured:
                continue
            }
        }
        if let released { return .found(released) }
        if let failure { return .failed(failure) }
        return .notFound
    }

    /// Reads one organization for one serial.
    private static func fetchABM(org: ABMOrgContext, serial: String) async -> FetchState<ABMInfo> {
        // A wanted snapshot that failed is reported as a failure rather than
        // worked around per device: three requests per serial against a
        // twenty-a-minute quota turns a large lookup into a crawl, and the
        // real answer is that the organization could not be read.
        if org.snapshotFailed {
            return .failed("\(org.name) could not be read.")
        }
        // With a snapshot in hand there is nothing to ask Apple: everything
        // except AppleCare coverage is already known, and that is read on
        // demand from the inspector.
        if let snapshot = org.snapshot {
            guard let device = snapshot.devices[serial.uppercased()] else { return .notFound }
            let serverID = snapshot.serverIDBySerial[serial.uppercased()]
            return .found(ABMInfo(
                device: device,
                orgID: org.id,
                orgName: org.name,
                mdmServerID: serverID,
                mdmServerName: serverID.map { org.mdmServerNames[$0] ?? $0 },
                coverage: [],
                coverageLoaded: false
            ))
        }
        do {
            guard let device = try await org.client.device(serial: serial) else { return .notFound }
            let coverage = (try? await org.client.appleCareCoverage(serial: serial)) ?? []
            let serverID = try? await org.client.assignedServerID(serial: serial)
            return .found(ABMInfo(
                device: device,
                orgID: org.id,
                orgName: org.name,
                mdmServerID: serverID ?? nil,
                mdmServerName: (serverID ?? nil).map { org.mdmServerNames[$0] ?? $0 },
                coverage: coverage
            ))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Builds the Jamf side of a report from the Jamf School fleet already in
    /// hand. Nothing is requested here: the whole instance was read once when
    /// the context was made.
    ///
    /// Passcode state is absent, because it is not on the list endpoint. It is
    /// read per device when one is selected, the same way AppleCare coverage
    /// is on the Apple side.
    private static func fetchJamfSchool(context: LookupContext, serial: String) -> FetchState<ManagedDeviceInfo> {
        guard let device = context.schoolFleet[serial.uppercased()] else { return .notFound }
        return .found(ManagedDeviceInfo(
            recordID: device.udid,
            kind: device.kind,
            udid: device.udid,
            name: device.name,
            osVersion: device.osVersion?.isEmpty == false ? device.osVersion : nil,
            osName: device.osPrefix?.isEmpty == false ? device.osPrefix : nil,
            lastContact: DateFormatting.isoFromInstanceLocal(
                device.lastCheckin,
                timeZone: context.schoolTimeZone
            ),
            // Jamf School reports the Apple ADE profile rather than a Jamf
            // PreStage. It fills the same column, under its own name. The
            // profile has no identifier, so its name serves as one; that is
            // only used to group the filter menu, never sent anywhere.
            prestageID: device.depProfile?.isEmpty == false ? device.depProfile : nil,
            prestageName: device.depProfile?.isEmpty == false ? device.depProfile : nil,
            // The console addresses a device by its UDID, which is also what
            // its API keys on, so the link needs nothing the lookup does not
            // already have.
            webURL: context.consoleBaseURL.flatMap { URL(string: "\($0)/devices/details/\(device.udid)") },
            locationID: device.locationID,
            locationName: device.locationID.map { context.schoolLocationNames[$0] ?? "Location \($0)" },
            isManaged: device.isManaged,
            isSupervised: device.isSupervised
        ))
    }

    /// Builds the MDM side of a report from the Intune fleet already in hand.
    /// Nothing is requested here: the tenant was read once when the context
    /// was made.
    ///
    /// No UDID and no management ID: Graph populates `udid` only on a
    /// single-device request, and every Intune action is addressed by the
    /// managed device ID instead, so neither is needed.
    private static func fetchIntune(context: LookupContext, serial: String) -> FetchState<ManagedDeviceInfo> {
        guard let device = context.intuneFleet[serial.uppercased()] else { return .notFound }
        return .found(ManagedDeviceInfo(
            recordID: device.id,
            kind: device.kind,
            name: device.deviceName,
            // One flag, three meanings, so it is routed to the row that
            // says what it actually measures. On a computer it is FileVault
            // (or BitLocker), as a bare boolean the encryption state reads as
            // its fallback. On an iPhone or iPad it is data protection, which
            // iOS enables exactly when a passcode is set, so it fills the
            // same Passcode row the Jamf products fill. On any other mobile
            // platform it is storage encryption and is shown as that.
            encryption: device.kind == .mobileDevice && device.isApplePlatform ? nil : device.isEncrypted.map {
                DiskEncryptionState(
                    fileVaultEnabled: $0,
                    bootPartitionState: nil,
                    bootPartitionPercent: nil,
                    recoveryKeyValidity: nil
                )
            },
            security: device.kind == .mobileDevice && device.isApplePlatform ? device.isEncrypted.map {
                MobileSecurityState(
                    passcodePresent: $0,
                    passcodeCompliant: nil,
                    passcodeCompliantWithProfile: nil,
                    hardwareEncryption: nil
                )
            } : nil,
            osVersion: device.osVersion?.isEmpty == false ? device.osVersion : nil,
            osName: device.operatingSystem?.isEmpty == false ? device.operatingSystem : nil,
            lastEnrolledDate: device.enrolledDateTime,
            // Intune reports one sync time and nothing that separates a
            // check-in from an inventory report, so it fills the contact
            // column and the other two are hidden by capability.
            lastContact: device.lastSyncDateTime,
            mdmProfileExpiration: device.managementCertificateExpirationDate,
            // The Intune console addresses a device by the same managed device
            // ID every action uses, so the link needs nothing extra.
            webURL: URL(string: "https://intune.microsoft.com/#view/Microsoft_Intune_ManagedDevices/ManagedDeviceMenu.MenuView/~/overview/managedDeviceId/\(device.id)"),
            isManaged: device.isManaged,
            isSupervised: device.isSupervised,
            complianceSummary: device.complianceSummary
        ))
    }

    private static func fetchMDM(context: LookupContext, serial: String) async -> FetchState<ManagedDeviceInfo> {
        if context.schoolClient != nil {
            return fetchJamfSchool(context: context, serial: serial)
        }
        if context.intuneClient != nil {
            return fetchIntune(context: context, serial: serial)
        }
        guard let client = context.proClient else { return .notConfigured }
        do {
            if let record = try await client.computer(serial: serial) {
                let prestageID = context.computerPrestageBySerial[serial]
                let webURL = context.consoleBaseURL.flatMap { URL(string: "\($0)/computers.html?id=\(record.id)&o=r") }
                return .found(ManagedDeviceInfo(
                    recordID: record.id,
                    kind: .computer,
                    udid: record.udid,
                    managementID: record.managementID,
                    name: record.name,
                    siteID: record.siteID,
                    siteName: record.siteName,
                    encryption: record.encryption,
                    osVersion: record.osVersion,
                    osBuild: record.osBuild,
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
                let webURL = context.consoleBaseURL.flatMap { URL(string: "\($0)/mobileDevices.html?id=\(record.id)&o=r") }
                return .found(ManagedDeviceInfo(
                    recordID: record.id,
                    kind: .mobileDevice,
                    udid: record.udid,
                    managementID: record.managementID,
                    name: record.name,
                    siteID: record.siteID,
                    siteName: record.siteName,
                    unlockToken: record.unlockToken,
                    security: record.security,
                    osVersion: record.osVersion,
                    osBuild: record.osBuild,
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
