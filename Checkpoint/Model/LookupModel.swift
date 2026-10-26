import Foundation
import JTKit
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

/// What a combined lookup concluded about one device's MDM records, read off
/// Apple's assignment, each record's enrollment method, and each record's
/// activity. Only a lookup across several connections produces one.
nonisolated enum MDMVerdict: Hashable, Sendable {
    /// The records and Apple's assignment agree.
    case consistent
    /// Apple assigns the device to `expected`, and the device's working
    /// record is not there — the named connections hold one instead.
    case assignedElsewhere(expected: String, actual: [String])
    /// The record on the assigned connection is accompanied by records on the
    /// named connections. A device enrolls in one MDM at a time, so those
    /// are stale.
    case staleElsewhere(stale: [String])
    /// The device sits in an Apple organization unassigned to any device
    /// management service, or released from the organization, yet records
    /// exist.
    case unassignedWithRecords
    /// The signals disagree, or cannot settle it, and the reason says why.
    case unverified(String)

    /// One sentence for the finding column and the inspector.
    var summary: String? {
        switch self {
        case .consistent:
            nil
        case .assignedElsewhere(let expected, let actual):
            "Assigned to \(expected); record on \(actual.formatted(.list(type: .and)))"
        case .staleElsewhere(let stale):
            "Stale record on \(stale.formatted(.list(type: .and)))"
        case .unassignedWithRecords:
            "Unassigned in Apple, yet has an MDM record"
        case .unverified(let reason):
            reason
        }
    }

    /// Whether the verdict is a definite finding, as opposed to the neutral
    /// badge for what could not be settled.
    var isFinding: Bool {
        switch self {
        case .assignedElsewhere, .staleElsewhere, .unassignedWithRecords: true
        case .consistent, .unverified: false
        }
    }
}

struct DeviceReport: Identifiable, Sendable {
    let serial: String
    var id: String { serial }
    var abm: FetchState<ABMInfo> = .pending
    /// The device's working record — on the Apple-assigned connection when
    /// one is known, otherwise the most recently active one.
    var mdm: FetchState<ManagedDeviceInfo> = .pending
    /// Records on other connections than the primary's. Filled only by a
    /// lookup across several connections.
    var otherRecords: [ManagedDeviceInfo] = []
    /// See `MDMVerdict`. Nil for a single-connection lookup, a device with no
    /// records, or one in no configured Apple organization.
    var mdmVerdict: MDMVerdict?

    /// Every record the lookup found, primary first.
    var allRecords: [ManagedDeviceInfo] {
        (mdm.value.map { [$0] } ?? []) + otherRecords
    }

    /// Whether any record did not come from Automated Device Enrollment —
    /// worth flagging on its own, whatever the verdict.
    var hasNonADERecord: Bool {
        allRecords.contains { $0.enrolledViaADE == false }
    }

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

/// The commands Checkpoint offers, on JTKit's command list (ROADMAP step 7):
/// JTKit has the titles, consequences, PIN and confirmation rules and the
/// routing; which commands each product offers, and in which order, is
/// Checkpoint's.
extension MDMCommand {
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
    static func commands(for kind: Checkpoint.DeviceKind, product: MDMProduct = .jamfPro) -> [MDMCommand] {
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

    func applies(to kind: Checkpoint.DeviceKind, product: MDMProduct = .jamfPro) -> Bool {
        Self.commands(for: kind, product: product).contains(self)
    }

    /// Why this command cannot be sent over the given connection, or nil when
    /// it can be. The list of what the gateway cannot carry is repeated for
    /// users in `docs/platform-api.md`, and in the warning shown when a
    /// Platform API connection is chosen in Settings; change them together.
    func unavailabilityReason(via authMethod: MDMAuthMethod) -> String? {
        guard authMethod == .platformGateway, !worksOverPlatformAPI else { return nil }
        return Self.unavailableOverPlatformAPI
    }

    /// Why this command would do nothing to this particular device, or nil.
    /// Distinct from the connection check above: this one is about the state
    /// of the device rather than what the connection can carry.
    func inapplicabilityReason(for info: ManagedDeviceInfo) -> String? {
        guard self == .clearPasscode, info.security?.passcodePresent == false else { return nil }
        return "This device has no passcode set."
    }

    /// Computer lock and wipe require a 6-digit PIN, on Jamf Pro only: Jamf
    /// School's wipe takes no PIN.
    func needsPIN(product: MDMProduct = .jamfPro) -> Bool {
        product.commandProduct.map { needsPIN(on: $0) } ?? false
    }

    func message(for product: MDMProduct = .jamfPro) -> String {
        if self == .unmanage, product == .intune {
            return "The device is retired: company data and the management profile are removed, so Intune can no longer manage it. Unlike the Jamf products, the record goes too once the device acknowledges."
        }
        return consequence(on: product.commandProduct ?? .jamfPro)
    }
}

extension MDMProduct {
    /// The product in JTKit's command list; nil for Intune, whose commands
    /// stay Checkpoint's until step 8.
    nonisolated var commandProduct: MDMCommand.Product? {
        switch self {
        case .jamfPro: .jamfPro
        case .jamfSchool: .jamfSchool
        case .intune: nil
        }
    }
}

extension DeviceKind {
    nonisolated var commandKind: MDMCommand.DeviceKind {
        switch self {
        case .computer: .computer
        case .mobileDevice: .mobileDevice
        }
    }

    nonisolated init(_ kind: MDMCommand.DeviceKind) {
        switch kind {
        case .computer: self = .computer
        case .mobileDevice: self = .mobileDevice
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

    /// The parsed date, or nil for an absent, unparseable or epoch value —
    /// "never" must not read as "longest ago".
    static func plausibleDate(_ iso: String?) -> Date? {
        guard let iso, let date = parseISO(iso), date > earliestPlausibleDate else { return nil }
        return date
    }

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
}

// MARK: - Lookup model

@MainActor
@Observable
final class LookupModel {
    let settings: AppSettings
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

    /// The organization last chosen, which is saved, or "All" for this
    /// session (JTKit's `AllConnectionsChoice`, never saved). A saved
    /// organization that no longer exists falls back to the first.
    var abmScope: ABMScope {
        get {
            let ids = settings.abmOrgs.map(\.id)
            if appleAll.isInEffect(connectionCount: ids.count) { return .allOrganizations }
            return ConnectionChoiceResolver.single(saved: settings.appleChoiceID, among: ids)
                .map(ABMScope.organization) ?? .allOrganizations
        }
        set {
            switch newValue {
            case .allOrganizations:
                appleAll.isChosen = true
            case .organization(let id):
                appleAll.isChosen = false
                settings.appleChoiceID = id
            }
        }
    }

    /// "All Organizations", for this session only.
    let appleAll = AllConnectionsChoice(title: "All Organizations")

    /// Which MDM connections a lookup reads. Reading all of them answers
    /// where a device's records live — including the stale ones — and is
    /// effectively read-only: an MDM action still needs one connection to
    /// act through. See `mdmActionConnection(for:)`.
    nonisolated enum MDMScope: Hashable, Sendable {
        case connection(UUID)
        case allConnections
    }

    /// The connection last chosen, which is saved, or "All" for this session
    /// only, as for `abmScope`.
    var mdmScope: MDMScope {
        get {
            let ids = settings.mdmConnections.map(\.id)
            if mdmAll.isInEffect(connectionCount: ids.count) { return .allConnections }
            return ConnectionChoiceResolver.single(saved: settings.mdmChoiceID, among: ids)
                .map(MDMScope.connection) ?? .allConnections
        }
        set {
            switch newValue {
            case .allConnections:
                mdmAll.isChosen = true
            case .connection(let id):
                mdmAll.isChosen = false
                settings.mdmChoiceID = id
            }
        }
    }

    /// "All Connections", for this session only.
    let mdmAll = AllConnectionsChoice(title: "All Connections")

    /// Compatibility spelling of the single-connection scope, for the code
    /// that reads or sets the selection as an identifier.
    var selectedConnectionID: UUID? {
        get {
            guard case .connection(let id) = mdmScope else { return nil }
            return id
        }
        set {
            mdmScope = newValue.map { .connection($0) } ?? .allConnections
        }
    }
    /// Device management services per Apple organization. A service ID means
    /// nothing outside the organization that issued it, so they are never
    /// pooled for an action — only for resolving a name.
    private(set) var mdmServersByOrg: [UUID: [MDMServer]] = [:]
    /// The name lists one connection serves, read with its lookups. Keyed per
    /// connection so one server's lists can never fill another's pickers —
    /// the structural form of what used to be "replaced even on failure".
    struct ConnectionTaxonomy: Sendable {
        var computerPrestages: [JamfPrestage] = []
        var mobilePrestages: [JamfPrestage] = []
        var sites: [JamfSite] = []
        /// Jamf School locations, that product's equivalent of sites.
        var locations: [JamfSchoolLocation] = []
    }

    private(set) var taxonomyByConnection: [UUID: ConnectionTaxonomy] = [:]

    /// The selected connection's lists, which is what the pickers show.
    /// Empty until that connection has run a lookup.
    private var selectedTaxonomy: ConnectionTaxonomy {
        selectedConnection.flatMap { taxonomyByConnection[$0.id] } ?? ConnectionTaxonomy()
    }

    var prestages: [JamfPrestage] { selectedTaxonomy.computerPrestages }
    var mobilePrestages: [JamfPrestage] { selectedTaxonomy.mobilePrestages }
    var sites: [JamfSite] { selectedTaxonomy.sites }
    var jamfLocations: [JamfSchoolLocation] { selectedTaxonomy.locations }

    /// The lists of the connection a report's record came from, for the
    /// pickers the inspector offers on that record.
    private func taxonomy(for report: DeviceReport) -> ConnectionTaxonomy {
        connection(for: report).flatMap { taxonomyByConnection[$0.id] } ?? selectedTaxonomy
    }

    func prestages(for report: DeviceReport) -> [JamfPrestage] { taxonomy(for: report).computerPrestages }
    func mobilePrestages(for report: DeviceReport) -> [JamfPrestage] { taxonomy(for: report).mobilePrestages }
    func sites(for report: DeviceReport) -> [JamfSite] { taxonomy(for: report).sites }
    func locations(for report: DeviceReport) -> [JamfSchoolLocation] { taxonomy(for: report).locations }

    // One client per connection ID, with the connection as it was when the
    // client was made, reused across lookups and actions. Each new ABMClient
    // requests a fresh OAuth token and Apple rate-limits that endpoint hard
    // (HTTP 429 after a few sign-ins), so switching organization or server
    // must not cost a re-authentication. No secret is part of a key: when a
    // connection or its secret is saved or deleted, its client is dropped and
    // forgets its token (`forgetClients(for:)`), so the next request signs in
    // with what is saved now.
    private var abmClients: [UUID: (config: ABMConfig, client: ABMClient)] = [:]
    private var jamfClients: [UUID: (config: MDMConnection, client: JamfClient)] = [:]
    private var jamfSchoolClients: [UUID: (config: MDMConnection, client: JamfSchoolClient)] = [:]
    private var intuneClients: [UUID: (config: MDMConnection, client: IntuneClient)] = [:]
    /// Where the clients send; replaced in tests.
    private let session: URLSession
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
    /// ADE serial membership and token identities per connection, for the
    /// combined lookup's classification. Session caches, like the above.
    private var adeSerialsCache: [UUID: Set<String>] = [:]
    private var adeServerUUIDsCache: [UUID: Set<String>] = [:]
    /// Apple's built-in device management fleet, per Business organization.
    /// Session cache like the ADE sets; nil entry means not read yet.
    private var appleManagedFleetCache: [UUID: [String: ABMManagedDevice]] = [:]
    /// One read in flight per server, so a device selection and a bulk
    /// selection arriving together do not both ask for it. Nil on failure,
    /// which is kept distinct from an instance that has no ADE devices.
    private var adeInstanceReads: [UUID: Task<[String: String]?, Never>] = [:]
    /// Each connection's target from the last lookup, which the refresh
    /// after an action reuses rather than re-reading the server's lists.
    private var lookupTargets: [UUID: MDMTargetContext] = [:]

    /// Above this many devices, Apple Business is read in bulk rather than
    /// one device at a time. Apple allows roughly twenty requests a minute
    /// per organization, and a per-device lookup costs three of them, so the
    /// whole organization becomes cheaper than about seven devices.
    static let snapshotThreshold = 15

    /// What the organization read is currently doing, for the progress text.
    private(set) var snapshotStatus: String?
    private(set) var isBuildingSnapshot = false

    init(settings: AppSettings, log: ActivityLog? = nil, session: URLSession = .shared) {
        self.settings = settings
        self.log = log ?? ActivityLog()
        self.session = session
        // One organization and one connection at launch: the last single
        // ones chosen. Searching them all is a choice per session rather than
        // the default: most fleets are served by one organization at a time
        // — an MSP works per customer — and a combined read should never be
        // the surprise. JTKit's "All" is never saved, which guarantees it.
        settings.edits.onChange = { [weak self] id in self?.forgetClients(for: id) }
    }

    /// Drops the connection's client after it was edited (its secret
    /// included) or deleted. A Jamf Pro client still in use by a running
    /// lookup forgets its token too, so its next request signs in with the
    /// secret saved now.
    func forgetClients(for id: UUID) {
        abmClients[id] = nil
        jamfSchoolClients[id] = nil
        intuneClients[id] = nil
        guard let jamf = jamfClients.removeValue(forKey: id)?.client else { return }
        pendingForget = Task { await jamf.forgetToken() }
    }

    /// The last Jamf Pro client's forgetting, for tests to wait on.
    @ObservationIgnored private(set) var pendingForget: Task<Void, Never>?

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
        orgName: String? = nil,
        connectionName: String? = nil
    ) {
        log.recordAction(
            service: service,
            connection: service.isAppleOrganization
                ? (orgName ?? selectedABMOrg?.displayName)
                : (connectionName ?? selectedConnection?.displayName),
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
        connectionName: String? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            recordAction(service, summary, serials: serials, orgName: orgName, connectionName: connectionName)
            return result
        } catch {
            recordAction(
                service,
                "\(summary) — \(error.localizedDescription)",
                serials: serials,
                outcome: .failed,
                orgName: orgName,
                connectionName: connectionName
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

    /// The one connection in scope, or nil when every connection is.
    var selectedConnection: MDMConnection? {
        guard case .connection(let id) = mdmScope else { return nil }
        return settings.mdmConnections.first { $0.id == id } ?? settings.mdmConnections.first
    }

    /// True when a lookup reads every configured connection, which adds the
    /// Connection column, the findings, and restricts bulk MDM actions to
    /// selections within a single connection.
    var readsAllConnections: Bool {
        mdmScope == .allConnections && settings.mdmConnections.count > 1
    }

    /// Brings the scope back to something that exists, after connections are
    /// added or removed — the MDM side of `reconcileABMScope`.
    ///
    /// A deleted connection already falls back to the first (see
    /// `mdmScope`); this ends "All" once one connection is left, so adding a
    /// second one later doesn't bring a combined read back unasked.
    func reconcileMDMScope() {
        if settings.mdmConnections.count < AllConnectionsChoice.minimumConnections {
            mdmAll.isChosen = false
        }
    }

    /// Two entries addressing the same instance collapse to one, or every
    /// device there would count its record twice. The direct entry wins over
    /// a Platform API one because it carries more commands.
    static func dedupedByInstance(_ connections: [MDMConnection]) -> [MDMConnection] {
        var seen: [String: Int] = [:]
        var result: [MDMConnection] = []
        for connection in connections {
            let instance = connection.product == .intune
                ? connection.tenantID.lowercased()
                : connection.normalizedBaseURL.lowercased()
            let key = "\(connection.product.rawValue)|\(instance)"
            if let index = seen[key] {
                if result[index].authMethod == .platformGateway, connection.authMethod != .platformGateway {
                    result[index] = connection
                }
            } else {
                seen[key] = result.count
                result.append(connection)
            }
        }
        return result
    }

    var isABMConfigured: Bool {
        abmOrgsInScope.contains { settings.secret(for: .apple($0)) != nil }
    }

    /// Brings the scope back to something that exists, after organizations
    /// are added or removed. A deleted organization already falls back to the
    /// first (see `abmScope`); searching them all makes no sense once one is
    /// left — the popup stops offering that entry — so "All" ends then.
    func reconcileABMScope() {
        if settings.abmOrgs.count < AllConnectionsChoice.minimumConnections {
            appleAll.isChosen = false
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

    /// What the scope can report and do. Drives which columns, rows and
    /// actions exist at all: what a product cannot do is left out rather than
    /// shown disabled. With every connection in scope this is their union —
    /// a column some rows can fill is offered, and the rows whose product
    /// lacks the source stay empty.
    var mdmCapabilities: MDMCapabilities {
        if case .allConnections = mdmScope {
            let union = mdmConnectionsInScope.reduce(into: MDMCapabilities()) { $0.formUnion($1.capabilities) }
            return union.isEmpty ? MDMProduct.jamfPro.capabilities : union
        }
        return selectedConnection?.capabilities ?? MDMProduct.jamfPro.capabilities
    }

    /// What to call the MDM side in generic wording: the product when one
    /// connection is in scope, plainly "MDM" when they all are.
    var mdmScopeLabel: String {
        readsAllConnections ? "MDM" : mdmProduct.label
    }

    /// Column headers that name a product's own term in single scope and a
    /// neutral one across products.
    var enrollmentProfileColumnLabel: String {
        readsAllConnections ? "Enrollment Profile" : mdmProduct.enrollmentProfileLabel
    }

    var lastContactColumnLabel: String {
        readsAllConnections ? "Last Contact" : mdmProduct.lastContactLabel
    }

    var deviceNameColumnLabel: String {
        readsAllConnections ? "Device Name" : "\(mdmProduct.label) Device Name"
    }

    /// The connection a record came from, else the selected one. A record
    /// from Apple's built-in management has no connection at all: it must
    /// never inherit the selected one, or its record would be offered
    /// another product's actions.
    func connection(for info: ManagedDeviceInfo?) -> MDMConnection? {
        if info?.managedByApple == true { return nil }
        if let id = info?.connectionID, let match = settings.mdmConnections.first(where: { $0.id == id }) {
            return match
        }
        return selectedConnection
    }

    /// What to call the place a record lives, for sentences and cells:
    /// the connection's name, or Apple's built-in management.
    func sourceName(for info: ManagedDeviceInfo?) -> String? {
        if info?.managedByApple == true { return "Apple Device Management" }
        return connection(for: info)?.displayName
    }

    func connection(for report: DeviceReport) -> MDMConnection? {
        connection(for: report.mdm.value)
    }

    /// The product and capabilities of one report's record. These, not the
    /// scope-wide ones, decide what the inspector offers for the record in
    /// front of it.
    func product(for report: DeviceReport) -> MDMProduct {
        connection(for: report)?.product ?? mdmProduct
    }

    func capabilities(for report: DeviceReport) -> MDMCapabilities {
        // Apple's built-in management is read-only reporting: none of the
        // capability-gated rows, pickers or commands apply to its records.
        if report.mdm.value?.managedByApple == true { return [] }
        return connection(for: report)?.capabilities ?? mdmCapabilities
    }

    /// The one connection an MDM action can act through for these reports, or
    /// nil when the selection gives no single answer — the MDM side of
    /// `appleActionOrg(for:)`. Actions follow the records, so a bulk action
    /// is valid exactly when every selected record is on one connection.
    func mdmActionConnection(for reports: [DeviceReport]) -> MDMConnection? {
        let ids = Set(reports.compactMap { $0.mdm.value?.connectionID })
        if ids.count == 1, let id = ids.first {
            // An identifier no configured connection matches — a record from
            // Apple's built-in management, or a connection since removed —
            // must not quietly act through the selected connection instead.
            return settings.mdmConnections.first { $0.id == id }
        }
        return ids.isEmpty ? selectedConnection : nil
    }

    /// Why the MDM actions are unavailable for this selection, or nil.
    func mdmActionUnavailableReason(for reports: [DeviceReport]) -> String? {
        guard mdmActionConnection(for: reports) == nil else { return nil }
        if reports.allSatisfy({ $0.mdm.value?.managedByApple != false }) {
            return "These devices are enrolled in Apple's built-in device management, which takes no MDM commands. The Apple actions above still apply."
        }
        let names = Set(reports.compactMap { sourceName(for: $0.mdm.value) }).sorted()
        return "The selected records are on \(names.formatted(.list(type: .and))). "
            + "MDM actions work through one connection at a time, so narrow the selection to one of them."
    }

    /// Why the given command cannot be sent for these reports, or nil.
    func unavailabilityReason(for command: MDMCommand, reports: [DeviceReport]) -> String? {
        let connection = mdmActionConnection(for: reports) ?? selectedConnection
        guard connection?.product ?? mdmProduct == .jamfPro else { return nil }
        return command.unavailabilityReason(via: connection?.authMethod ?? .apiClient)
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

        let context = await makeContext(serials: serials)
        typealias RowResult = (String, FetchState<ABMInfo>, FetchState<ManagedDeviceInfo>, [ManagedDeviceInfo], MDMVerdict?)
        await withTaskGroup(of: RowResult.self) { group in
            var pending = serials.makeIterator()
            func addNext() {
                guard let serial = pending.next() else { return }
                group.addTask {
                    let abmState = await Self.fetchABM(context: context, serial: serial)
                    let mdmStates = Self.fetchMDMStates(context: context, serial: serial)
                    let resolved = Self.resolveRecords(serial: serial, abm: abmState, states: mdmStates, context: context)
                    return (serial, abmState, resolved.mdm, resolved.others, resolved.verdict)
                }
            }
            for _ in 0..<Self.maximumConcurrentLookups { addNext() }
            for await (serial, abmState, mdmState, others, verdict) in group {
                if let index = reports.firstIndex(where: { $0.serial == serial }) {
                    reports[index].abm = abmState
                    reports[index].mdm = mdmState
                    reports[index].otherRecords = others
                    reports[index].mdmVerdict = verdict
                }
                completedLookups += 1
                addNext()
            }
        }
    }

    /// Passes the row count so a refresh after a bulk change rebuilds the
    /// organization snapshot instead of asking Apple per device, which the
    /// request quota would stretch to hours.
    ///
    /// The devices' records are read again; the servers' lists are reused
    /// from the lookup, since no action changes them. The one exception is
    /// PreStage scope, which `prestageScopeChanged` re-reads.
    func refreshRows(_ serials: [String], prestageScopeChanged: Bool = false) async {
        // The organizations those devices were found in. A refresh after an
        // action need not search the others: nothing happened to them, and
        // re-reading one costs a minute of its quota.
        let affected = Set(serials.compactMap { serial in
            reports.first { $0.serial == serial }?.abm.value?.orgID
        })
        let orgs = affected.isEmpty ? nil : settings.abmOrgs.filter { affected.contains($0.id) }
        let context = await makeContext(
            serials: serials,
            orgs: orgs,
            refreshing: true,
            prestageScopeChanged: prestageScopeChanged
        )
        for serial in serials {
            guard let index = reports.firstIndex(where: { $0.serial == serial }) else { continue }
            let abmState = await Self.fetchABM(context: context, serial: serial)
            let states = Self.fetchMDMStates(context: context, serial: serial)
            let resolved = Self.resolveRecords(serial: serial, abm: abmState, states: states, context: context)
            reports[index].abm = abmState
            reports[index].mdm = resolved.mdm
            reports[index].otherRecords = resolved.others
            reports[index].mdmVerdict = resolved.verdict
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
        guard let jamf = makeJamfClient(for: report) else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
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
        guard let jamf = makeJamfClient(for: report) else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
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
        guard let jamf = makeJamfClient(for: report) else { throw ActionError(message: "No Jamf Pro server is selected or configured.") }
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
        guard capabilities(for: report).contains(.complianceOnDemand),
              let info = report.mdm.value,
              let server = connection(for: report),
              let jamf = makeJamfClient(for: report) else { return nil }
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
    func adeInstance(for report: DeviceReport) -> String? {
        guard let id = connection(for: report)?.id else { return nil }
        return adeInstances[id]?[report.serial.uppercased()]
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
        guard let server = selectedConnection else { return }
        await loadADEInstances(for: server)
    }

    func loadADEInstances(for server: MDMConnection) async {
        guard server.capabilities.contains(.prestageScope),
              adeInstances[server.id] == nil else { return }
        if let inFlight = adeInstanceReads[server.id] {
            _ = await inFlight.value
            return
        }
        guard let jamf = makeJamfClient(for: server) else { return }
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

    /// Whether a lookup of this size has to read an organization first, which
    /// is what makes a lookup take a minute. True while any organization in
    /// scope still needs reading; false once every snapshot is in hand, since
    /// they are reused.
    func needsOrganizationRead(forDeviceCount count: Int) -> Bool {
        guard isABMConfigured else { return false }
        guard count >= Self.snapshotThreshold else { return false }
        return abmOrgsInScope.contains { cachedSnapshot(for: $0) == nil }
    }

    /// Discards one organization's snapshot, after a change to it, so the
    /// next bulk lookup does not report the state from before the change.
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

    /// Whether the device's organization serves audit events: Apple Business
    /// does, Apple School Manager's API has no audit endpoint at all, so the
    /// history is absent there rather than empty.
    func supportsDeviceHistory(for report: DeviceReport) -> Bool {
        guard let id = report.abm.value?.orgID else { return false }
        return settings.abmOrgs.first { $0.id == id }?.kind == .business
    }

    /// One page of the device's history, newest first. Nil when the
    /// organization has no audit endpoint or will not answer. Fetched when
    /// the inspector's History disclosure opens, never during a lookup: it
    /// costs one request against the same per-minute budget the coverage and
    /// Activation Lock reads already draw on.
    func deviceHistory(for report: DeviceReport, cursor: String? = nil) async -> ABMAuditPage? {
        guard supportsDeviceHistory(for: report),
              let info = report.abm.value,
              let abm = clientForOrg(of: info) else { return nil }
        // From the day the device joined the organization; a device whose
        // added date is unknown still gets a year of history.
        let start = info.device.addedToOrgDateTime.flatMap(DateFormatting.parseISO)
            ?? Date().addingTimeInterval(-365 * 24 * 3600)
        return try? await abm.auditEvents(serial: report.serial, start: start, end: Date(), cursor: cursor)
    }

    /// The management state of a device under Apple's built-in management,
    /// read on selection — the per-device detail is where check-in, FileVault
    /// and the lock, Lost Mode and erase statuses live.
    func appleManagementDetail(for report: DeviceReport) async -> ABMManagedDeviceDetail? {
        guard let info = report.mdm.value, info.managedByApple,
              let abmInfo = report.abm.value,
              let abm = clientForOrg(of: abmInfo) else { return nil }
        return try? await abm.appleManagedDeviceDetails(id: info.recordID)
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
        guard let info = report.mdm.value, let school = makeJamfSchoolClient(for: report),
              let udid = info.udid, !udid.isEmpty else { return nil }
        return try? await school.deviceDetails(udid: udid)
    }

    /// What the device last reported about itself declaratively: its software
    /// update state and the declarations it has processed. One request serves
    /// both. Nil when it has reported nothing.
    func ddmStatus(for report: DeviceReport) async -> JamfDDMStatus? {
        guard let info = report.mdm.value, let jamf = makeJamfClient(for: report),
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
    func updateEnforcement(in status: JamfDDMStatus, for report: DeviceReport) async -> JamfUpdateEnforcement? {
        guard let jamf = makeJamfClient(for: report) else { return nil }
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
    func blueprintName(for id: String, report: DeviceReport) async -> String? {
        guard let server = connection(for: report),
              server.capabilities.contains(.blueprintNames),
              let jamf = makeJamfClient(for: report) else { return nil }
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
              let jamf = makeJamfClient(for: report) else { return [] }
        return (try? await jamf.localAdminAccounts(managementID: managementID)) ?? []
    }

    /// How long after being viewed Jamf Pro rotates a local administrator
    /// password. Nil when the setting cannot be read.
    ///
    /// This is a server-wide setting, so it is read once per server rather
    /// than each time a device is selected.
    func localAdminRotationTime(for report: DeviceReport) async -> TimeInterval? {
        guard let serverID = connection(for: report)?.id else { return nil }
        if let cached = rotationTimes[serverID] { return cached }
        guard let jamf = makeJamfClient(for: report),
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
        guard let jamf = makeJamfClient(for: report) else {
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
        if let reason = mdmActionUnavailableReason(for: reports) {
            throw ActionError(message: reason)
        }
        guard let connection = mdmActionConnection(for: reports) else {
            throw ActionError(message: "No MDM connection is selected or configured.")
        }
        let withRecords = reports.compactMap { report in
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }
        guard !withRecords.isEmpty else {
            throw ActionError(message: "None of the selected devices have a \(connection.product.label) record.")
        }
        let failures = await removeRecords(withRecords, connection: connection)
        await refreshRows(withRecords.map(\.serial))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    /// Removes one record wherever it lives — the inspector's path for a
    /// stale record found beside the working one. Routed by the record.
    func removeRecord(_ info: ManagedDeviceInfo, serial: String) async throws {
        guard let connection = connection(for: info) else {
            throw ActionError(message: "The connection this record came from is no longer configured.")
        }
        let failures = await removeRecords([(serial, info)], connection: connection)
        await refreshRows([serial])
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    /// The stale records in a selection: every record beside the working one
    /// on devices whose verdict settled as stale. Unverified rows are left to
    /// the inspector, where the records can be weighed one by one, and a
    /// mismatch is not a removal candidate at all — its one record is where
    /// the device actually lives.
    func staleRecords(in reports: [DeviceReport]) -> [(serial: String, info: ManagedDeviceInfo)] {
        reports.flatMap { report -> [(String, ManagedDeviceInfo)] in
            guard case .staleElsewhere = report.mdmVerdict else { return [] }
            // A record in Apple's built-in management cannot be removed by
            // API, so it is never a cleanup candidate.
            return report.otherRecords.filter { !$0.managedByApple }.map { (report.serial, $0) }
        }
    }

    /// Removes every settled stale record in the selection, grouped per
    /// connection so each product's removal is sent where it belongs. The
    /// working records are never touched. Failures are collected per device
    /// and thrown together once every connection has been tried.
    func removeStaleRecords(reports: [DeviceReport]) async throws {
        let entries = staleRecords(in: reports)
        guard !entries.isEmpty else {
            throw ActionError(message: "The selection has no stale records to remove.")
        }
        var failures: [String] = []
        let byConnection = Dictionary(grouping: entries) { $0.info.connectionID }
        for (id, group) in byConnection.sorted(by: { ($0.key?.uuidString ?? "") < ($1.key?.uuidString ?? "") }) {
            guard let connection = id.flatMap({ id in settings.mdmConnections.first { $0.id == id } }) else {
                failures += group.map { "\($0.serial): the record's connection is no longer configured." }
                continue
            }
            failures += await removeRecords(group, connection: connection)
        }
        await refreshRows(Array(Set(entries.map(\.serial))))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    /// How the stale records distribute over connections, for the
    /// confirmation: "2 on Jamf School and 1 on Intune Test".
    func staleRecordSummary(in reports: [DeviceReport]) -> String {
        let entries = staleRecords(in: reports)
        let counts = Dictionary(grouping: entries) { entry in
            connection(for: entry.info)?.displayName ?? "an unconfigured connection"
        }
        return counts
            .map { "\($0.value.count) on \($0.key)" }
            .sorted()
            .formatted(.list(type: .and))
    }

    /// Deletes or trashes records on one connection, per that product's
    /// meaning of removal, returning per-device failures rather than
    /// stopping at the first. The shared engine for Delete Record and the
    /// stale-record cleanup.
    private func removeRecords(
        _ entries: [(serial: String, info: ManagedDeviceInfo)],
        connection: MDMConnection
    ) async -> [String] {
        // Defence in depth: nothing routes these here, and nothing may.
        if let appleManaged = entries.first(where: { $0.info.managedByApple }) {
            return ["\(appleManaged.serial): records in Apple's built-in device management cannot be removed by API."]
        }
        let product = connection.product
        let school = makeJamfSchoolClient(for: connection)
        let intune = makeIntuneClient(for: connection)
        let jamf = (school == nil && intune == nil) ? makeJamfClient(for: connection) : nil
        guard school != nil || intune != nil || jamf != nil else {
            return entries.map { "\($0.serial): \(connection.displayName) has no usable credentials." }
        }
        var failures: [String] = []
        for entry in entries {
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
                of: entries.count,
                failed: failures.count,
                from: connection.displayName
            ),
            serials: entries.map(\.serial),
            outcome: failures.isEmpty ? .succeeded : .failed,
            connectionName: connection.displayName
        )
        return failures
    }

    /// Moves the devices to another Jamf School location, that product's
    /// equivalent of a site.
    ///
    /// Sent through the bulk endpoint in chunks, which is also what makes a
    /// single-device move safe: the per-device path takes an identifier that
    /// is documented nowhere, while the bulk one takes UDIDs explicitly.
    func setLocation(reports: [DeviceReport], to locationID: String) async throws {
        if let reason = mdmActionUnavailableReason(for: reports) { throw ActionError(message: reason) }
        guard let connection = mdmActionConnection(for: reports),
              let school = makeJamfSchoolClient(for: connection) else {
            throw ActionError(message: "No Jamf School server is selected or configured.")
        }
        let moving = reports.compactMap { report in
            report.mdm.value.map { (serial: report.serial, info: $0) }
        }.filter { $0.info.locationID != locationID }
        guard !moving.isEmpty else { return }
        let locations = taxonomyByConnection[connection.id]?.locations ?? []
        let name = locations.first { $0.id == locationID }?.name ?? locationID
        let summary = "Moved \(Self.deviceCount(moving.map(\.serial))) to \(name)"
        try await recording(.jamfSchool, summary, serials: moving.map(\.serial), connectionName: connection.displayName) {
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
        if let reason = mdmActionUnavailableReason(for: reports) { throw ActionError(message: reason) }
        guard let connection = mdmActionConnection(for: reports),
              let jamf = makeJamfClient(for: connection) else {
            throw ActionError(message: "No Jamf Pro server is selected or configured.")
        }
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
        let taxonomy = taxonomyByConnection[connection.id] ?? ConnectionTaxonomy()
        let all = kind == .computer ? taxonomy.computerPrestages : taxonomy.mobilePrestages
        let name = newID.flatMap { id in all.first { $0.id == id }?.displayName }
        let summary = name.map { "Added \(Self.deviceCount(affected)) to PreStage \($0)" }
            ?? "Removed \(Self.deviceCount(affected)) from their PreStage"
        try await recording(.jamfPro, summary, serials: affected, connectionName: connection.displayName) {
            for (prestage, serials) in removeByPrestage {
                try await jamf.removeFromPrestage(family: family, prestageID: prestage, serials: serials)
            }
            if let newID {
                try await jamf.addToPrestage(family: family, prestageID: newID, serials: affected)
            }
        }
        await refreshRows(affected, prestageScopeChanged: true)
    }

    /// Sets or clears one device's asset tag, on whichever Jamf product holds
    /// the record. A single-device action: tags identify devices one by one,
    /// so writing one tag across a selection would answer no real question.
    func setAssetTag(_ assetTag: String, for report: DeviceReport) async throws {
        guard let info = report.mdm.value, let connection = connection(for: report) else {
            throw ActionError(message: "\(report.serial) has no MDM record.")
        }
        let tag = assetTag.trimmingCharacters(in: .whitespaces)
        let summary = tag.isEmpty
            ? "Cleared the asset tag on \(report.serial)"
            : "Set the asset tag on \(report.serial) to \(tag)"
        try await recording(
            connection.product.activityService,
            summary,
            serials: [report.serial],
            connectionName: connection.displayName
        ) {
            switch connection.product {
            case .jamfPro:
                guard let jamf = makeJamfClient(for: connection) else {
                    throw ActionError(message: "\(connection.displayName) has no usable credentials.")
                }
                switch info.kind {
                case .computer:
                    try await jamf.setComputerAssetTag(computerID: info.recordID, assetTag: tag)
                case .mobileDevice:
                    try await jamf.setMobileDeviceAssetTag(deviceID: info.recordID, assetTag: tag)
                }
            case .jamfSchool:
                guard let school = makeJamfSchoolClient(for: connection) else {
                    throw ActionError(message: "\(connection.displayName) has no usable credentials.")
                }
                try await school.setAssetTag(udid: info.recordID, assetTag: tag)
            case .intune:
                throw ActionError(message: "Intune's API carries no asset tag.")
            }
        }
        await refreshRows([report.serial])
    }

    /// Moves the devices' Jamf Pro records to another site ("-1" for none).
    /// Note this does not change which PreStages a device can join. That is
    /// determined by the ADE token that synced it, not by the record's site.
    func setSite(reports: [DeviceReport], to siteID: String) async throws {
        if let reason = mdmActionUnavailableReason(for: reports) { throw ActionError(message: reason) }
        guard let connection = mdmActionConnection(for: reports),
              let jamf = makeJamfClient(for: connection) else {
            throw ActionError(message: "No Jamf Pro server is selected or configured.")
        }
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
        let allSites = taxonomyByConnection[connection.id]?.sites ?? []
        let siteName = siteID == "-1" ? "no site" : (allSites.first { $0.id == siteID }?.name ?? siteID)
        recordAction(
            .jamfPro,
            Self.partialSummary("Moved", noun: "device", of: withRecords.count, failed: failures.count, from: nil)
                + " to \(siteName)",
            serials: withRecords.map(\.serial),
            outcome: failures.isEmpty ? .succeeded : .failed,
            connectionName: connection.displayName
        )
        await refreshRows(withRecords.map(\.serial))
        if !failures.isEmpty { throw ActionError(message: failures.joined(separator: "\n")) }
    }

    // MARK: MDM commands

    /// The devices a command would go to, as JTKit plans them (ROADMAP step
    /// 7): which receive it, which don't and why. What the confirmation shows
    /// before anything is sent, and what the Action entry names afterwards.
    struct CommandPlan {
        let connection: MDMConnection
        let targets: [MDMCommand.Target]
        let plan: MDMCommand.Plan
        /// Selected devices with no record on the connection.
        let withoutRecord: Int
    }

    /// The selection as command targets: every device with a record.
    private func commandTargets(_ reports: [DeviceReport]) -> [MDMCommand.Target] {
        reports.compactMap { report in
            report.mdm.value.map {
                MDMCommand.Target(serial: report.serial, recordID: $0.recordID, kind: $0.kind.commandKind,
                                  udid: $0.udid, managementID: $0.managementID)
            }
        }
    }

    /// Nil when the selection gives no single connection to send through.
    func commandPlan(_ command: MDMCommand, reports: [DeviceReport]) -> CommandPlan? {
        guard mdmActionUnavailableReason(for: reports) == nil,
              let connection = mdmActionConnection(for: reports) else { return nil }
        let targets = commandTargets(reports)
        let plan: MDMCommand.Plan
        if let product = connection.product.commandProduct {
            plan = command.plan(for: targets, on: product, overPlatformAPI: connection.isUsingPlatformGateway)
        } else {
            // Intune (Checkpoint's own until step 8): only the kind decides.
            plan = MDMCommand.Plan(
                receiving: targets.filter { command.applies(to: DeviceKind($0.kind), product: connection.product) },
                skipped: targets.filter { !command.applies(to: DeviceKind($0.kind), product: connection.product) }
                    .map { MDMCommand.Skipped(target: $0, reason: .notApplicable($0.kind)) })
        }
        return CommandPlan(connection: connection, targets: targets, plan: plan,
                           withoutRecord: reports.count - targets.count)
    }

    /// The confirmation for a command, by JTKit's rules: the connection named
    /// when it can't be undone, the number typed from two devices, a PIN
    /// twice, and why fewer devices than selected receive it.
    func commandConfirmation(_ command: MDMCommand, reports: [DeviceReport]) -> MDMCommand.Confirmation? {
        guard let planned = commandPlan(command, reports: reports) else { return nil }
        let product = planned.connection.product
        var confirmation = MDMCommand.Confirmation(
            command, plan: planned.plan, on: product.commandProduct ?? .jamfPro,
            connectionName: planned.connection.displayName,
            extra: planned.withoutRecord > 0 ? [.noRecord: planned.withoutRecord] : [:])
        confirmation.message = command.message(for: product)
        confirmation.asksPINTwice = command.needsPIN(product: product)
        return confirmation
    }

    /// Sends an MDM command to every selected device it applies to, through
    /// JTKit (Jamf Pro, Jamf School) or Checkpoint's Intune client. Returns
    /// the number of devices it was sent to. One Action entry says how many
    /// it reached and names every other device with the reason.
    @discardableResult
    func sendCommand(_ command: MDMCommand, reports: [DeviceReport], passcode: String? = nil) async throws -> Int {
        // The connection the records are on, not the one the toolbar shows:
        // actions follow the records.
        if let reason = mdmActionUnavailableReason(for: reports) {
            throw ActionError(message: reason)
        }
        guard let connection = mdmActionConnection(for: reports) else {
            throw ActionError(message: "No MDM connection is selected or configured.")
        }
        let product = connection.product
        let school = makeJamfSchoolClient(for: connection)
        let intune = makeIntuneClient(for: connection)
        let jamf = (school == nil && intune == nil) ? makeJamfClient(for: connection) : nil
        guard school != nil || intune != nil || jamf != nil else {
            throw ActionError(message: "\(connection.displayName) has no usable credentials.")
        }
        // Fail before doing any work, so a command the connection cannot carry
        // never gets as far as a confirmation prompt.
        if let reason = unavailabilityReason(for: command, reports: reports) {
            throw ActionError(message: reason)
        }
        let targets = commandTargets(reports)
        guard targets.contains(where: { command.applies(to: DeviceKind($0.kind), product: product) }) else {
            throw ActionError(message: "\(command.title) doesn't apply to any of the selected devices.")
        }

        let result: MDMCommand.Result
        do {
            if let school {
                result = try await school.send(command, to: targets)
            } else if let intune {
                result = try await routeIntune(command, intune: intune, targets: targets)
            } else if let jamf {
                result = try await jamf.send(command, to: targets, pin: command.needsPIN(product: product) ? passcode : nil)
            } else {
                result = MDMCommand.Result(command: command.title, outcomes: [])
            }
        } catch {
            log.recordCommand(command.title, outcomes: targets.map { .init(target: $0, outcome: .failed(error.localizedDescription)) },
                              failure: error.localizedDescription,
                              service: product.activityService.rawValue, connection: connection.displayName)
            throw error
        }
        log.recordCommand(command.title, outcomes: result.outcomes, warning: result.warning,
                          service: product.activityService.rawValue, connection: connection.displayName)
        if let problems = result.problems { throw ActionError(message: problems) }
        return result.sent.count
    }

    /// Routes a command to its Intune action.
    ///
    /// One request per device, because Graph's device actions take no device
    /// list. Every action answers 204 with no body, so there is no per-device
    /// outcome hidden inside a success; whether the device then acts on it is
    /// reported by Intune as a device action result, which Checkpoint does
    /// not poll.
    private func routeIntune(
        _ command: MDMCommand,
        intune: IntuneClient,
        targets: [MDMCommand.Target]
    ) async throws -> MDMCommand.Result {
        var outcomes: [MDMCommand.DeviceOutcome] = []
        for target in targets {
            guard command.applies(to: DeviceKind(target.kind), product: .intune) else {
                outcomes.append(.init(target: target, outcome: .skipped(.notApplicable(target.kind))))
                continue
            }
            let id = target.recordID
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
                outcomes.append(.init(target: target, outcome: .sent))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(.init(target: target, outcome: .failed(error.localizedDescription)))
            }
        }
        return MDMCommand.Result(command: command.title, outcomes: outcomes)
    }

    // MARK: Clients & shared context

    private func makeABMClient() -> ABMClient? {
        referenceABMOrg.flatMap { makeABMClient(for: $0) }
    }

    func makeABMClient(for config: ABMConfig) -> ABMClient? {
        guard config.isConfigured,
              let pem = settings.secret(for: .apple(config)), !pem.isEmpty else { return nil }
        if let kept = abmClients[config.id], kept.config == config { return kept.client }
        let client = ABMClient(
            clientID: config.clientID,
            keyID: config.keyID,
            privateKeyPEM: pem,
            kind: config.kind,
            connectionName: config.displayName,
            log: log,
            session: session
        )
        abmClients[config.id] = (config, client)
        return client
    }


    /// The Jamf Pro client for the connection a report's record came from.
    private func makeJamfClient(for report: DeviceReport) -> JamfClient? {
        connection(for: report).flatMap { makeJamfClient(for: $0) }
    }

    /// The Jamf School client for the connection a report's record came from.
    private func makeJamfSchoolClient(for report: DeviceReport) -> JamfSchoolClient? {
        connection(for: report).flatMap { makeJamfSchoolClient(for: $0) }
    }

    /// The Jamf Pro client, or nil when the selected server is not a Jamf Pro
    /// one. The product guard matters: without it a Jamf Pro request would be
    /// sent to a Jamf School host, which answers something unrecognisable
    /// rather than refusing.
    private func makeJamfClient() -> JamfClient? {
        selectedConnection.flatMap { makeJamfClient(for: $0) }
    }

    func makeJamfClient(for config: MDMConnection) -> JamfClient? {
        guard config.product == .jamfPro,
              let saved = settings.secret(for: .mdm(config)), !saved.isEmpty else { return nil }
        if let kept = jamfClients[config.id], kept.config == config { return kept.client }
        // Read from the Keychain at each sign-in, so a changed secret is used
        // at the next one.
        let store = settings.secretStore
        let account = CheckpointSecrets.account(for: CheckpointConnection.mdm(config).connection)
        let name = config.displayName
        guard let client = JamfClient(config: config, secret: {
            guard let secret = store.secret(for: account), !secret.isEmpty else {
                throw JamfClient.APIError(message: "No secret is saved for “\(name)”.")
            }
            return secret
        }, log: log, session: session) else { return nil }
        jamfClients[config.id] = (config, client)
        return client
    }

    private func makeIntuneClient() -> IntuneClient? {
        selectedConnection.flatMap { makeIntuneClient(for: $0) }
    }

    func makeIntuneClient(for config: MDMConnection) -> IntuneClient? {
        guard config.product == .intune,
              let secret = settings.secret(for: .mdm(config)), !secret.isEmpty else { return nil }
        if let kept = intuneClients[config.id], kept.config == config { return kept.client }
        guard let client = IntuneClient(config: config, secret: secret, log: log, session: session) else { return nil }
        intuneClients[config.id] = (config, client)
        return client
    }

    private func makeJamfSchoolClient() -> JamfSchoolClient? {
        selectedConnection.flatMap { makeJamfSchoolClient(for: $0) }
    }

    func makeJamfSchoolClient(for config: MDMConnection) -> JamfSchoolClient? {
        guard config.product == .jamfSchool,
              let secret = settings.secret(for: .mdm(config)), !secret.isEmpty else { return nil }
        if let kept = jamfSchoolClients[config.id], kept.config == config { return kept.client }
        guard let client = JamfSchoolClient(config: config, secret: secret, log: log, session: session) else { return nil }
        jamfSchoolClients[config.id] = (config, client)
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

    /// One MDM connection as a lookup sees it: its client, and the per-server
    /// data read once before the devices, so the per-device work only ever
    /// consults what is already in hand. Exactly one of the three clients is
    /// set, matching the product.
    private struct MDMTargetContext: Sendable {
        let connectionID: UUID
        let connectionName: String
        let product: MDMProduct
        /// For links into the product's web interface.
        let consoleBaseURL: String?
        var proClient: JamfClient?
        var schoolClient: JamfSchoolClient?
        var intuneClient: IntuneClient?
        // Jamf Pro: PreStage scope, and the name lists that resolve the
        // identifiers inventory reports. The name maps are empty when the
        // account cannot read the lists, which leaves the rows out rather
        // than showing an identifier.
        var computerPrestageBySerial: [String: String] = [:]
        var computerPrestageNames: [String: String] = [:]
        var mobilePrestageBySerial: [String: String] = [:]
        var mobilePrestageNames: [String: String] = [:]
        var departmentNames: [String: String] = [:]
        var buildingNames: [String: String] = [:]
        var siteNames: [String: String] = [:]
        /// The lookup's serials, read from Jamf Pro in chunks before the
        /// rows rather than a request or three per device.
        var proComputers = JamfBatch<JamfComputerRecord>()
        var proMobileDevices = JamfBatch<JamfMobileDeviceRecord>()
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
        /// Every managed device in the Intune tenant, keyed by serial. Read in
        /// pages rather than per device because Graph documents no $filter on
        /// serialNumber, so there is no per-serial query to make.
        var intuneFleet: [String: IntuneDevice] = [:]
    }

    private struct LookupContext: Sendable {
        /// Every organization in scope, in configured order. A device belongs
        /// to at most one, so the first that reports it wins — except that a
        /// device released from one and re-added to another appears in both,
        /// which is why an active record is preferred over a released one.
        var abmOrgs: [ABMOrgContext] = []
        /// The MDM connections a lookup reads, in configured order. One per
        /// connection in scope, each carrying its own prologue data.
        var mdmTargets: [MDMTargetContext] = []
        /// True when the lookup spans several connections, which is what
        /// turns on record aggregation and the verdicts.
        var readsAllConnections = false
        /// Which serials each connection's ADE tokens hold. Apple assigns a
        /// device to one service, and the token syncing that service holds
        /// exactly the assigned devices, so membership identifies the
        /// assigned connection — allowing for sync lag after a reassignment.
        var adeSerialsByConnection: [UUID: Set<String>] = [:]
        /// Apple service ID → the connection whose token carries it. Jamf Pro
        /// publishes the ID on its tokens; the other products do not. Apple's
        /// built-in service maps to its organization's ID, exactly.
        var connectionIDByServerUUID: [String: UUID] = [:]
        var connectionNames: [UUID: String] = [:]
        /// Devices enrolled in Apple's built-in device management, per
        /// Business organization that has the service. Read once per session;
        /// contributes records in combined lookups only.
        var appleManagedByOrg: [UUID: [String: ABMManagedDevice]] = [:]
    }

    /// Builds the clients and snapshots a lookup reads from.
    ///
    /// `orgs` narrows the Apple side to particular organizations, which is
    /// what a refresh after an action passes: the devices it is refreshing
    /// are known to belong to one organization, and the others have not
    /// changed. `refreshing` reuses the last lookup's per-connection lists
    /// for the same reason.
    private func makeContext(
        serials: [String],
        orgs: [ABMConfig]? = nil,
        refreshing: Bool = false,
        prestageScopeChanged: Bool = false
    ) async -> LookupContext {
        let deviceCount = serials.count
        var context = LookupContext()
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
        for connection in mdmConnectionsInScope {
            var target = refreshing
                ? await refreshedMDMTarget(for: connection, serials: serials, prestageScopeChanged: prestageScopeChanged)
                : nil
            if target == nil { target = await makeMDMTarget(for: connection, serials: serials) }
            if let target {
                lookupTargets[connection.id] = target
                context.mdmTargets.append(target)
                context.connectionNames[connection.id] = connection.displayName
            }
        }
        // The classification layer, read only when connections are compared.
        // The ADE walks are cached per connection for the session, so the
        // cost is paid by the first combined lookup alone.
        if context.mdmTargets.count > 1 {
            context.readsAllConnections = true
            for connection in mdmConnectionsInScope {
                context.adeSerialsByConnection[connection.id] = await adeSerials(for: connection)
                for uuid in await adeServerUUIDs(for: connection) {
                    context.connectionIDByServerUUID[uuid] = connection.id
                }
            }
        }
        // Apple's built-in device management joins as a source of its own
        // wherever a Business organization in scope carries the service —
        // automatically, because the service's existence is the whole
        // answer, and in every scope, because it belongs to the Apple
        // organization rather than to the connection picker. The service ID
        // maps to the organization exactly, so classification needs no
        // inference here.
        for org in context.abmOrgs where org.kind == .business {
            guard let service = (mdmServersByOrg[org.id] ?? []).first(where: \.isAppleManagement) else { continue }
            let fleet = await appleManagedFleet(for: org)
            context.appleManagedByOrg[org.id] = fleet
            context.connectionNames[org.id] = "Apple Device Management"
            context.connectionIDByServerUUID[Self.normalizedServiceID(service.id)] = org.id
            context.adeSerialsByConnection[org.id] = Set(fleet.keys)
        }
        return context
    }

    /// The built-in management fleet of one organization, read once per
    /// session. Empty both for an organization without the service and for
    /// one whose service has no enrolled devices.
    private func appleManagedFleet(for org: ABMOrgContext) async -> [String: ABMManagedDevice] {
        if let cached = appleManagedFleetCache[org.id] { return cached }
        let fleet = (try? await org.client.appleManagedDevices()) ?? [:]
        appleManagedFleetCache[org.id] = fleet
        return fleet
    }

    /// ADE serial membership for one connection, read once per session. The
    /// Jamf Pro walk doubles as the PreStage pickers' token map.
    private func adeSerials(for connection: MDMConnection) async -> Set<String> {
        if let cached = adeSerialsCache[connection.id] { return cached }
        var serials = Set<String>()
        switch connection.product {
        case .jamfPro:
            await loadADEInstances(for: connection)
            serials = Set((adeInstances[connection.id] ?? [:]).keys)
        case .jamfSchool:
            if let school = makeJamfSchoolClient(for: connection) {
                serials = (try? await school.adeSerials()) ?? []
            }
        case .intune:
            // Graph v1.0 publishes no per-token device list, so Intune
            // contributes no membership; classification falls back to the
            // per-record enrollment inference there.
            break
        }
        adeSerialsCache[connection.id] = serials
        return serials
    }

    /// The Apple service IDs a Jamf Pro connection's ADE tokens carry, read
    /// once per session. Empty for the other products, which publish none.
    private func adeServerUUIDs(for connection: MDMConnection) async -> Set<String> {
        guard connection.product == .jamfPro else { return [] }
        if let cached = adeServerUUIDsCache[connection.id] { return cached }
        let raw = (try? await makeJamfClient(for: connection)?.adeServerUUIDs()) ?? []
        let uuids = Set((raw ?? []).map(Self.normalizedServiceID))
        adeServerUUIDsCache[connection.id] = uuids
        return uuids
    }

    /// Apple and Jamf write the same service ID with and without dashes.
    nonisolated static func normalizedServiceID(_ id: String) -> String {
        id.uppercased().replacingOccurrences(of: "-", with: "")
    }

    /// The MDM connections a lookup reads, in configured order.
    private var mdmConnectionsInScope: [MDMConnection] {
        switch mdmScope {
        case .connection: selectedConnection.map { [$0] } ?? []
        case .allConnections: Self.dedupedByInstance(settings.mdmConnections)
        }
    }

    /// Builds one connection's target: its client plus the per-server data a
    /// lookup consults per device, and on Jamf Pro the records for `serials`.
    /// Nil when the connection has no usable credentials, which reads as not
    /// configured.
    private func makeMDMTarget(for connection: MDMConnection, serials: [String]) async -> MDMTargetContext? {
        var target = MDMTargetContext(
            connectionID: connection.id,
            connectionName: connection.displayName,
            product: connection.product,
            consoleBaseURL: connection.normalizedBaseURL.isEmpty ? nil : connection.normalizedBaseURL
        )
        switch connection.product {
        case .jamfPro:
            guard let jamf = makeJamfClient(for: connection) else { return nil }
            target.proClient = jamf
            // Started together rather than one after another. All are
            // independent, and every one has to finish before the first row
            // is filled, so serially they were a round trip each of dead
            // time at the head of every lookup.
            async let computerPrestages = try? jamf.prestages(family: .computer)
            async let mobileDevicePrestages = try? jamf.prestages(family: .mobileDevice)
            async let siteList = try? jamf.sites()
            async let computerScope = try? jamf.prestageAssignments(family: .computer)
            async let mobileScope = try? jamf.prestageAssignments(family: .mobileDevice)
            async let departmentList = try? jamf.departmentNames()
            async let buildingList = try? jamf.buildingNames()
            async let computers = jamf.computers(serials: serials)
            async let mobileDevices = jamf.mobileDevices(serials: serials)
            // Stored even when a read fails: an empty entry for this server
            // beats keeping an older one, and the keying per connection is
            // what stops one server's taxonomy from serving another's pickers.
            var taxonomy = ConnectionTaxonomy()
            taxonomy.computerPrestages = await computerPrestages ?? []
            taxonomy.mobilePrestages = await mobileDevicePrestages ?? []
            taxonomy.sites = await siteList ?? []
            taxonomyByConnection[connection.id] = taxonomy
            target.computerPrestageNames = Dictionary(taxonomy.computerPrestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            target.mobilePrestageNames = Dictionary(taxonomy.mobilePrestages.map { ($0.id, $0.displayName) }) { first, _ in first }
            target.computerPrestageBySerial = await computerScope ?? [:]
            target.mobilePrestageBySerial = await mobileScope ?? [:]
            target.departmentNames = await departmentList ?? [:]
            target.buildingNames = await buildingList ?? [:]
            target.siteNames = Dictionary(taxonomy.sites.map { ($0.id, $0.name) }) { first, _ in first }
            target.proComputers = await computers
            target.proMobileDevices = await mobileDevices
        case .jamfSchool:
            guard let school = makeJamfSchoolClient(for: connection) else { return nil }
            target.schoolClient = school
            // The whole fleet in one request. Jamf School offers no
            // pagination and no per-device serial route worth using, and has
            // no request quota, so this is both simpler and cheaper than
            // asking device by device.
            async let fleet = try? school.fleet()
            async let locationList = try? school.locations()
            target.schoolFleet = await fleet ?? [:]
            var taxonomy = ConnectionTaxonomy()
            taxonomy.locations = await locationList ?? []
            taxonomyByConnection[connection.id] = taxonomy
            target.schoolLocationNames = Dictionary(taxonomy.locations.map { ($0.id, $0.name) }) { first, _ in first }
            // Left until last: it reads one device out of the fleet above.
            target.schoolTimeZone = await jamfSchoolTimeZone(
                school: school,
                connectionID: connection.id,
                fleet: target.schoolFleet
            )
        case .intune:
            guard let intune = makeIntuneClient(for: connection) else { return nil }
            target.intuneClient = intune
            // One read for the tenant, however many serials are being looked
            // up. Graph pages at a thousand, so a few thousand devices cost a
            // handful of requests against a per-device cost of one each.
            target.intuneFleet = (try? await intune.fleet()) ?? [:]
            taxonomyByConnection[connection.id] = ConnectionTaxonomy()
        }
        return target
    }

    /// The last lookup's target for a connection with its records read
    /// again, or nil when there is none to reuse — including when the
    /// connection's credentials changed since, which gives it a new client.
    /// Jamf School and Intune records come from the fleet read, so the
    /// fleet is what is read again there.
    private func refreshedMDMTarget(
        for connection: MDMConnection,
        serials: [String],
        prestageScopeChanged: Bool
    ) async -> MDMTargetContext? {
        guard var target = lookupTargets[connection.id] else { return nil }
        switch connection.product {
        case .jamfPro:
            guard let jamf = makeJamfClient(for: connection), jamf === target.proClient else { return nil }
            async let computers = jamf.computers(serials: serials)
            async let mobileDevices = jamf.mobileDevices(serials: serials)
            if prestageScopeChanged {
                async let computerScope = try? jamf.prestageAssignments(family: .computer)
                async let mobileScope = try? jamf.prestageAssignments(family: .mobileDevice)
                target.computerPrestageBySerial = await computerScope ?? [:]
                target.mobilePrestageBySerial = await mobileScope ?? [:]
            }
            target.proComputers = await computers
            target.proMobileDevices = await mobileDevices
        case .jamfSchool:
            guard let school = makeJamfSchoolClient(for: connection), school === target.schoolClient else { return nil }
            target.schoolFleet = (try? await school.fleet()) ?? [:]
        case .intune:
            guard let intune = makeIntuneClient(for: connection), intune === target.intuneClient else { return nil }
            target.intuneFleet = (try? await intune.fleet()) ?? [:]
        }
        return target
    }

    /// The zone a Jamf School instance stamps its times in.
    ///
    /// Only the per-device endpoint names it, and it is the same for the whole
    /// instance, so it is read from one arbitrary device and then kept for the
    /// session. Nil leaves times to be read as local, which is right often
    /// enough and wrong only by an offset.
    private func jamfSchoolTimeZone(
        school: JamfSchoolClient,
        connectionID: UUID,
        fleet: [String: JamfSchoolDevice]
    ) async -> TimeZone? {
        if let cached = jamfSchoolTimeZones[connectionID] { return cached }
        guard let udid = fleet.values.first?.udid,
              let details = try? await school.deviceDetails(udid: udid),
              let zone = details.timeZone else { return nil }
        jamfSchoolTimeZones[connectionID] = zone
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
    nonisolated private static func fetchJamfSchool(target: MDMTargetContext, serial: String) -> FetchState<ManagedDeviceInfo> {
        guard let device = target.schoolFleet[serial.uppercased()] else { return .notFound }
        return .found(ManagedDeviceInfo(
            recordID: device.udid,
            connectionID: target.connectionID,
            kind: device.kind,
            udid: device.udid,
            name: device.name,
            assetTag: device.assetTag?.isEmpty == false ? device.assetTag : nil,
            enrolledViaADE: device.enrollType.map { $0 == "dep" },
            enrollmentMethod: device.enrollType?.isEmpty == false ? device.enrollType : nil,
            osVersion: device.osVersion?.isEmpty == false ? device.osVersion : nil,
            osName: device.osPrefix?.isEmpty == false ? device.osPrefix : nil,
            lastContact: DateFormatting.isoFromInstanceLocal(
                device.lastCheckin,
                timeZone: target.schoolTimeZone
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
            webURL: target.consoleBaseURL.flatMap { URL(string: "\($0)/devices/details/\(device.udid)") },
            locationID: device.locationID,
            locationName: device.locationID.map { target.schoolLocationNames[$0] ?? "Location \($0)" },
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
    nonisolated private static func fetchIntune(target: MDMTargetContext, serial: String) -> FetchState<ManagedDeviceInfo> {
        guard let device = target.intuneFleet[serial.uppercased()] else { return .notFound }
        return .found(ManagedDeviceInfo(
            recordID: device.id,
            connectionID: target.connectionID,
            kind: device.kind,
            name: device.deviceName,
            enrolledViaADE: device.enrolledViaADE,
            enrollmentMethod: device.deviceEnrollmentType,
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

    /// Every connection in scope's record for one serial, in configured
    /// order. Nothing is requested here: each connection's records were read
    /// when the context was made.
    nonisolated private static func fetchMDMStates(
        context: LookupContext,
        serial: String
    ) -> [(connectionID: UUID, state: FetchState<ManagedDeviceInfo>)] {
        var states = context.mdmTargets.map {
            (connectionID: $0.connectionID, state: fetchMDM(target: $0, serial: serial))
        }
        // Apple's built-in management contributes a record like any other
        // source, in every scope; being read-only, it never contributes an
        // action.
        for (orgID, fleet) in context.appleManagedByOrg {
            guard let device = fleet[serial.uppercased()] else { continue }
            states.append((orgID, .found(ManagedDeviceInfo(
                recordID: device.id,
                connectionID: orgID,
                managedByApple: true,
                kind: device.kind,
                name: device.deviceName,
                // Enrollment into the built-in service only happens through
                // Apple's own assignment, so membership is the method.
                enrolledViaADE: true,
                isManaged: true
            ))))
        }
        return states
    }

    /// Chooses a device's working record and classifies the rest.
    ///
    /// The assigned connection is identified without configuration: Apple
    /// assigns a device to one service, and the token syncing that service
    /// holds exactly the assigned devices, so ADE membership names it — with
    /// Jamf Pro's token identities as a second witness. Enrollment method
    /// says how a record got there, never whether the device is still there:
    /// a stale record keeps the method it enrolled with, which is why
    /// activity breaks the ties and an unsettled case says so instead of
    /// guessing.
    nonisolated private static func resolveRecords(
        serial: String,
        abm: FetchState<ABMInfo>,
        states: [(connectionID: UUID, state: FetchState<ManagedDeviceInfo>)],
        context: LookupContext
    ) -> (mdm: FetchState<ManagedDeviceInfo>, others: [ManagedDeviceInfo], verdict: MDMVerdict?) {
        let records = states.compactMap(\.state.value)
        guard !records.isEmpty else {
            // No record anywhere. A failure outranks not-found, because "no
            // record" must not be claimed while a connection went unread.
            for (_, state) in states { if case .failed = state { return (state, [], nil) } }
            for (_, state) in states { if case .notFound = state { return (state, [], nil) } }
            return (states.first?.state ?? .notConfigured, [], nil)
        }
        guard context.readsAllConnections else {
            // One connection in scope: its record stays the row's record, and
            // Apple's built-in management fills in only where the connection
            // has none — it belongs to the organization, so hiding it behind
            // a connection choice would misreport a managed device as
            // recordless. No verdicts here; findings are the combined
            // lookup's job.
            let primary = records.first { !$0.managedByApple } ?? records[0]
            return (.found(primary), [], nil)
        }

        let name = { (id: UUID?) in id.flatMap { context.connectionNames[$0] } ?? "another connection" }
        let upper = serial.uppercased()
        // The connection Apple's assignment points at. The assigned service's
        // identity is current and exact where a token publishes it, so it is
        // consulted first; token membership can lag a reassignment, so it is
        // the fallback, walked in configured order to stay deterministic.
        let expectedID = abm.value?.mdmServerID
            .flatMap { context.connectionIDByServerUUID[normalizedServiceID($0)] }
            ?? context.mdmTargets.first {
                context.adeSerialsByConnection[$0.connectionID]?.contains(upper) == true
            }?.connectionID

        let live = records.filter { $0.isManaged != false }
        func recency(_ record: ManagedDeviceInfo) -> Date? {
            DateFormatting.plausibleDate(record.lastContact)
                ?? DateFormatting.plausibleDate(record.lastContactTime)
                ?? DateFormatting.plausibleDate(record.reportDate)
        }
        let mostRecentFirst = records.sorted {
            (recency($0) ?? .distantPast) > (recency($1) ?? .distantPast)
        }

        // The working record: the assigned connection's, else the one live
        // record, else the most recently heard from.
        let primary = records.first { $0.connectionID == expectedID }
            ?? (live.count == 1 ? live[0] : nil)
            ?? mostRecentFirst[0]
        let others = records.filter {
            $0.connectionID != primary.connectionID || $0.recordID != primary.recordID
        }

        let verdict = classify(
            abm: abm.value,
            records: records,
            live: live,
            expectedID: expectedID,
            recency: recency,
            name: name
        )
        return (.found(primary), others, verdict)
    }

    nonisolated private static func classify(
        abm: ABMInfo?,
        records: [ManagedDeviceInfo],
        live: [ManagedDeviceInfo],
        expectedID: UUID?,
        recency: (ManagedDeviceInfo) -> Date?,
        name: (UUID?) -> String
    ) -> MDMVerdict? {
        // Outside every configured Apple organization: neutral, not a
        // finding. The Apple column and its filter already make it visible.
        guard let abm, !abm.isReleased else {
            return abm == nil ? nil : .unassignedWithRecords
        }
        guard abm.mdmServerID != nil else { return .unassignedWithRecords }

        if let expectedID {
            let onExpected = records.filter { $0.connectionID == expectedID }
            let elsewhere = records.filter { $0.connectionID != expectedID }
            if onExpected.isEmpty {
                return .assignedElsewhere(
                    expected: name(expectedID),
                    actual: elsewhere.map { name($0.connectionID) }
                )
            }
            guard !elsewhere.isEmpty else { return .consistent }
            // Records on the assigned connection and elsewhere. If the one
            // over there was heard from more recently than the assigned
            // one, the device may genuinely live there — say so rather than
            // calling it stale.
            let expectedSeen = onExpected.compactMap(recency).max()
            let elsewhereSeen = elsewhere.compactMap(recency).max()
            if let expectedSeen, let elsewhereSeen, elsewhereSeen > expectedSeen,
               elsewhere.contains(where: { $0.isManaged != false }) {
                return .unverified("Records on \(name(expectedID)) and elsewhere both look active")
            }
            return .staleElsewhere(stale: elsewhere.map { name($0.connectionID) })
        }

        // Assigned, but to a service no configured connection's tokens
        // cover — an Intune tenant, or a server outside Checkpoint. An
        // active ADE-enrolled record can only exist on the assigned
        // service, so a sole one vouches for itself; anything else cannot
        // be settled from here.
        let adeLive = live.filter { $0.enrolledViaADE == true }
        if records.count == 1, adeLive.count == 1 { return .consistent }
        if adeLive.count == 1 {
            let stale = records.filter { $0.connectionID != adeLive[0].connectionID }
            return .staleElsewhere(stale: stale.map { name($0.connectionID) })
        }
        let service = abm.mdmServerName ?? "a device management service"
        if records.count == 1 {
            return .unverified("Assigned to \(service); the record's enrollment cannot confirm it")
        }
        return .unverified("Records on \(records.map { name($0.connectionID) }.formatted(.list(type: .and))); the assignment cannot settle which is current")
    }

    /// One connection's record for one serial, from what the context read.
    nonisolated private static func fetchMDM(target: MDMTargetContext, serial: String) -> FetchState<ManagedDeviceInfo> {
        if target.schoolClient != nil {
            return fetchJamfSchool(target: target, serial: serial)
        }
        if target.intuneClient != nil {
            return fetchIntune(target: target, serial: serial)
        }
        guard target.proClient != nil else { return .notConfigured }
        let upper = serial.uppercased()
        // A computer record wins, as it did when each serial was asked for
        // in turn. A failed read is reported rather than passed over, so a
        // serial is only called absent once both reads have answered.
        if let failure = target.proComputers.failures[upper] { return .failed(failure) }
        if let record = target.proComputers.records[upper] {
            let prestageID = target.computerPrestageBySerial[serial]
            let webURL = target.consoleBaseURL.flatMap { URL(string: "\($0)/computers.html?id=\(record.id)&o=r") }
            return .found(ManagedDeviceInfo(
                recordID: record.id,
                connectionID: target.connectionID,
                kind: .computer,
                udid: record.udid,
                managementID: record.managementID,
                name: record.name,
                siteID: record.siteID,
                siteName: record.siteName,
                department: record.departmentID.flatMap { target.departmentNames[$0] },
                building: record.buildingID.flatMap { target.buildingNames[$0] },
                room: record.room,
                assetTag: record.assetTag?.isEmpty == false ? record.assetTag : nil,
                enrolledViaADE: record.enrolledViaADE,
                enrollmentMethod: record.enrollmentMethod,
                encryption: record.encryption,
                osVersion: record.osVersion,
                osBuild: record.osBuild,
                lastEnrolledDate: record.lastEnrolledDate,
                reportDate: record.reportDate,
                lastContactTime: record.lastContactTime,
                lastContact: record.lastContact,
                mdmProfileExpiration: record.mdmProfileExpiration,
                prestageID: prestageID,
                prestageName: prestageID.map { target.computerPrestageNames[$0] ?? "PreStage \($0)" },
                webURL: webURL
            ))
        }
        if let failure = target.proMobileDevices.failures[upper] { return .failed(failure) }
        if let record = target.proMobileDevices.records[upper] {
            let prestageID = target.mobilePrestageBySerial[serial]
            let webURL = target.consoleBaseURL.flatMap { URL(string: "\($0)/mobileDevices.html?id=\(record.id)&o=r") }
            return .found(ManagedDeviceInfo(
                recordID: record.id,
                connectionID: target.connectionID,
                kind: .mobileDevice,
                udid: record.udid,
                managementID: record.managementID,
                name: record.name,
                siteID: record.siteID,
                siteName: record.siteID.flatMap { $0 == "-1" ? nil : target.siteNames[$0] ?? "Site \($0)" },
                department: record.departmentID.flatMap { target.departmentNames[$0] },
                building: record.buildingID.flatMap { target.buildingNames[$0] },
                room: record.room,
                assetTag: record.assetTag?.isEmpty == false ? record.assetTag : nil,
                enrolledViaADE: record.enrolledViaADE,
                enrollmentMethod: record.enrollmentMethod,
                security: record.security,
                osVersion: record.osVersion,
                osBuild: record.osBuild,
                lastEnrolledDate: record.lastEnrolledDate,
                reportDate: record.lastInventoryDate,
                lastContactTime: nil,
                lastContact: record.lastContactTime,
                mdmProfileExpiration: record.mdmProfileExpiration,
                prestageID: prestageID,
                prestageName: prestageID.map { target.mobilePrestageNames[$0] ?? "PreStage \($0)" },
                webURL: webURL
            ))
        }
        return .notFound
    }

}
