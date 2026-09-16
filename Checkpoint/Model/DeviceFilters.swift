import Foundation

/// Which of the looked-up devices the table shows.
///
/// Every criterion lives in this one value so that the view can prune the
/// selection whenever any of them changes. Adding a criterion here cannot
/// miss that pruning, which is what keeps a hidden device from staying
/// selected and being acted on later.
///
/// Filtering only ever reads what a lookup already put in the report.
/// AppleCare coverage and software update status are deliberately absent:
/// neither is present for every row, so filtering on them would quietly
/// exclude devices whose value simply had not been fetched.
nonisolated struct DeviceFilters: Equatable {
    var kind: Kind = .all
    var appleBusiness: ABMStatus = .any
    var mdmServer: Assignment = .any
    var prestage: Assignment = .any
    var site: Assignment = .any
    var osVersion: Assignment = .any
    var lastEnrollment: DateWindow = .any
    var lastInventory: DateWindow = .any
    var lastContact: DateWindow = .any
    /// Applied together: a device must satisfy all of them.
    var issues: Set<Issue> = []

    var isActive: Bool { self != DeviceFilters() }

    /// How many criteria are set, for the button label.
    var activeCount: Int {
        var count = issues.count
        if kind != .all { count += 1 }
        if appleBusiness != .any { count += 1 }
        if mdmServer != .any { count += 1 }
        if prestage != .any { count += 1 }
        if site != .any { count += 1 }
        if osVersion != .any { count += 1 }
        if lastEnrollment != .any { count += 1 }
        if lastInventory != .any { count += 1 }
        if lastContact != .any { count += 1 }
        return count
    }

    func matches(_ report: DeviceReport) -> Bool {
        kind.matches(report)
            && appleBusiness.matches(report)
            && mdmServer.matches(report.abm.value?.mdmServerID, hasRecord: report.abm.value != nil)
            && prestage.matches(report.mdm.value?.prestageID, hasRecord: report.mdm.value != nil)
            && site.matches(report.mdm.value?.groupingID, hasRecord: report.mdm.value != nil)
            && osVersion.matches(report.mdm.value?.osVersion, hasRecord: report.mdm.value != nil)
            && lastEnrollment.matches(report.mdm.value?.lastEnrolledDate, hasRecord: report.mdm.value != nil)
            && lastInventory.matches(report.mdm.value?.reportDate, hasRecord: report.mdm.value != nil)
            && lastContact.matches(report.mdm.value?.lastContact, hasRecord: report.mdm.value != nil)
            && issues.allSatisfy { $0.matches(report) }
    }

    // MARK: Criteria

    nonisolated enum Kind: String, CaseIterable, Identifiable, Equatable {
        case all = "All"
        case computers = "Computers"
        case mobileDevices = "Mobile Devices"

        var id: String { rawValue }

        func matches(_ report: DeviceReport) -> Bool {
            switch self {
            case .all: true
            case .computers: report.deviceKind == .computer
            case .mobileDevices: report.deviceKind == .mobileDevice
            }
        }
    }

    nonisolated enum ABMStatus: String, CaseIterable, Identifiable, Equatable {
        case any = "Any"
        case assigned = "Assigned"
        case unassigned = "Unassigned"
        case released = "Released"
        case notInOrganization = "Not in organization"

        var id: String { rawValue }

        func matches(_ report: DeviceReport) -> Bool {
            switch self {
            case .any:
                return true
            case .notInOrganization:
                if case .notFound = report.abm { return true }
                return false
            case .assigned, .unassigned, .released:
                guard let info = report.abm.value else { return false }
                switch self {
                case .released: return info.isReleased
                case .assigned: return !info.isReleased && info.device.status?.uppercased() == "ASSIGNED"
                default: return !info.isReleased && info.device.status?.uppercased() != "ASSIGNED"
                }
            }
        }
    }

    /// A filter on something a device either has, does not have, or has a
    /// particular one of: an MDM server, a PreStage, a site.
    nonisolated enum Assignment: Hashable {
        case any
        /// Explicitly without one. Devices with no record at all do not match,
        /// since nothing is known about them either way.
        case none
        case id(String)

        func matches(_ value: String?, hasRecord: Bool) -> Bool {
            switch self {
            case .any: true
            case .none: hasRecord && value == nil
            case .id(let wanted): value == wanted
            }
        }
    }

    /// How long ago a date was, as the presets a fleet is usually asked
    /// about: what checked in today, what has been quiet a while.
    ///
    /// The windows overlap deliberately. "Less than 7 days ago" includes
    /// today, because a device that reported this morning also reported this
    /// week, and asking for one rarely means excluding the other.
    nonisolated enum DateWindow: String, CaseIterable, Identifiable, Equatable {
        case any = "Any"
        case today = "Today"
        case sevenDays = "Less than 7 days ago"
        case thirtyDays = "Less than 30 days ago"
        case overThirtyDays = "More than 30 days ago"
        case overNinetyDays = "More than 90 days ago"
        /// Has a record, but no date in this field at all.
        case never = "Never"

        var id: String { rawValue }

        func matches(_ value: String?, hasRecord: Bool) -> Bool {
            if self == .any { return true }
            guard hasRecord else { return false }
            return contains(value.flatMap(DateFormatting.parseISO))
        }

        /// Whether an already-parsed date falls in this window. Taken parsed
        /// so that counting every window over every device costs one parse
        /// per date rather than one per window.
        ///
        /// A date that was absent or unreadable counts as never, not as a
        /// match for every window, so one odd value cannot land in two
        /// buckets at once.
        func contains(_ date: Date?) -> Bool {
            guard let date else { return self == .never }
            switch self {
            case .any: return true
            case .never: return false
            case .today: return Calendar.current.isDateInToday(date)
            case .sevenDays: return Self.days(since: date) < 7
            case .thirtyDays: return Self.days(since: date) < 30
            case .overThirtyDays: return Self.days(since: date) >= 30
            case .overNinetyDays: return Self.days(since: date) >= 90
            }
        }

        /// Whole days between a date and now. A date in the future counts as
        /// zero days old: Jamf occasionally reports one, and it belongs with
        /// the recent devices rather than the quiet ones.
        private static func days(since date: Date) -> Int {
            max(0, Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0)
        }
    }

    /// Conditions worth singling out, each phrased as a problem to look for.
    nonisolated enum Issue: String, CaseIterable, Identifiable, Equatable {
        case mdmProfileExpired
        case appleBusinessOnly
        case mdmOnly
        case migrationInProgress
        case fileVaultOff
        case noPasscode

        var id: String { rawValue }

        func label(for product: MDMProduct = .jamfPro) -> String {
            switch self {
            case .mdmProfileExpired: "MDM profile expired"
            case .appleBusinessOnly: "No \(product.label) record"
            case .mdmOnly: "Not in the Apple organization"
            case .migrationInProgress: "Migration in progress"
            case .fileVaultOff: "FileVault not enabled"
            case .noPasscode: "No passcode set"
            }
        }

        func matches(_ report: DeviceReport) -> Bool {
            switch self {
            case .mdmProfileExpired:
                guard let expiry = report.mdm.value?.mdmProfileExpiration,
                      let date = DateFormatting.parseISO(expiry) else { return false }
                return date < Date()
            case .appleBusinessOnly:
                // Both sides must have answered: a lookup still running, or one
                // that failed, says nothing about whether the device is missing.
                guard report.abm.value != nil else { return false }
                if case .notFound = report.mdm { return true }
                return false
            case .mdmOnly:
                guard report.mdm.value != nil else { return false }
                if case .notFound = report.abm { return true }
                return false
            case .migrationInProgress:
                return report.abm.value?.device.hasActiveMigration == true
            case .fileVaultOff:
                return report.mdm.value?.encryption?.isEncrypted == false
            case .noPasscode:
                return report.mdm.value?.security?.passcodePresent == false
            }
        }
    }
}

/// What the devices currently in the list can be filtered by.
///
/// Options come from the loaded devices rather than from the server, so the
/// menu never offers a PreStage, site or server that nothing in the list
/// uses: a lookup of twenty Macs should not present every iPad PreStage on
/// the instance. Criteria that cannot apply are left out entirely, and ones
/// that would match nothing are shown with a count of zero rather than
/// silently emptying the table.
///
/// Always built from every loaded device, never from the filtered subset, so
/// the menu does not shift underneath a filter as it is applied.
nonisolated struct FilterOptions {
    nonisolated struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    /// A date window with how many devices fall in it.
    nonisolated struct WindowCount: Identifiable, Hashable {
        let window: DeviceFilters.DateWindow
        let count: Int
        var id: String { window.rawValue }
    }

    var servers: [Option] = []
    var prestages: [Option] = []
    var sites: [Option] = []
    /// Installed OS versions. Unlike coverage or update state, these come
    /// with the lookup rather than per device, so they can be filtered on.
    var osVersions: [Option] = []
    /// Whether any device has a record but no value, so None is worth offering.
    var serverNone = 0
    var prestageNone = 0
    var siteNone = 0
    var osVersionNone = 0
    /// Date windows per field, empty when no loaded device reports that
    /// date — which is how Jamf School, having only a check-in, ends up
    /// offering only the one picker.
    var lastEnrollment: [WindowCount] = []
    var lastInventory: [WindowCount] = []
    var lastContact: [WindowCount] = []
    var statuses: [(status: DeviceFilters.ABMStatus, count: Int)] = []
    var issues: [(issue: DeviceFilters.Issue, count: Int)] = []
    var hasComputers = false
    var hasMobileDevices = false

    var showAppleBusiness: Bool { !statuses.isEmpty }
    var showServers: Bool { !servers.isEmpty || serverNone > 0 }
    var showPrestages: Bool { !prestages.isEmpty || prestageNone > 0 }
    var showSites: Bool { !sites.isEmpty || siteNone > 0 }
    var showOSVersions: Bool { !osVersions.isEmpty || osVersionNone > 0 }
    var showDates: Bool { !lastEnrollment.isEmpty || !lastInventory.isEmpty || !lastContact.isEmpty }

    init(reports: [DeviceReport], capabilities: MDMCapabilities = MDMProduct.jamfPro.capabilities) {
        var serverCounts: [String: (name: String, count: Int)] = [:]
        var prestageCounts: [String: (name: String, count: Int)] = [:]
        var siteCounts: [String: (name: String, count: Int)] = [:]
        var osCounts: [String: (name: String, count: Int)] = [:]
        // Windows overlap, so a date is tested against each of them rather
        // than assigned to one bucket. Parsed once per date to keep that from
        // costing a parse per window.
        let windows = DeviceFilters.DateWindow.allCases.filter { $0 != .any }
        var enrollmentCounts = [Int](repeating: 0, count: windows.count)
        var inventoryCounts = enrollmentCounts
        var contactCounts = enrollmentCounts
        var hasEnrollment = false
        var hasInventory = false
        var hasContact = false

        for report in reports {
            switch report.deviceKind {
            case .computer: hasComputers = true
            case .mobileDevice: hasMobileDevices = true
            case nil: break
            }
            if let abm = report.abm.value {
                if let id = abm.mdmServerID {
                    let name = abm.mdmServerName ?? id
                    serverCounts[id] = (name, (serverCounts[id]?.count ?? 0) + 1)
                } else {
                    serverNone += 1
                }
            }
            if let mdm = report.mdm.value {
                if let id = mdm.prestageID {
                    let name = mdm.prestageName ?? id
                    prestageCounts[id] = (name, (prestageCounts[id]?.count ?? 0) + 1)
                } else {
                    prestageNone += 1
                }
                if let id = mdm.groupingID {
                    let name = mdm.locationName ?? mdm.siteName ?? id
                    siteCounts[id] = (name, (siteCounts[id]?.count ?? 0) + 1)
                } else {
                    siteNone += 1
                }
                // Grouped by version rather than by the displayed string, so
                // a Mac and an iPad on the same release fall together.
                if let version = mdm.osVersion, !version.isEmpty {
                    osCounts[version] = (version, (osCounts[version]?.count ?? 0) + 1)
                } else {
                    osVersionNone += 1
                }
                let enrollment = mdm.lastEnrolledDate.flatMap(DateFormatting.parseISO)
                let inventory = mdm.reportDate.flatMap(DateFormatting.parseISO)
                let contact = mdm.lastContact.flatMap(DateFormatting.parseISO)
                hasEnrollment = hasEnrollment || enrollment != nil
                hasInventory = hasInventory || inventory != nil
                hasContact = hasContact || contact != nil
                for (index, window) in windows.enumerated() {
                    if window.contains(enrollment) { enrollmentCounts[index] += 1 }
                    if window.contains(inventory) { inventoryCounts[index] += 1 }
                    if window.contains(contact) { contactCounts[index] += 1 }
                }
            }
        }

        func sorted(_ counts: [String: (name: String, count: Int)]) -> [Option] {
            counts
                .map { Option(id: $0.key, name: $0.value.name, count: $0.value.count) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        servers = sorted(serverCounts)
        // localizedStandardCompare compares numerically, so 26.10 follows
        // 26.9 rather than preceding it.
        osVersions = sorted(osCounts)
        prestages = sorted(prestageCounts)
        sites = sorted(siteCounts)

        func windowOptions(_ counts: [Int], reported: Bool) -> [WindowCount] {
            guard reported else { return [] }
            return zip(windows, counts).map { WindowCount(window: $0, count: $1) }
        }
        lastEnrollment = windowOptions(enrollmentCounts, reported: hasEnrollment)
        lastInventory = windowOptions(inventoryCounts, reported: hasInventory)
        lastContact = windowOptions(contactCounts, reported: hasContact)

        // Only statuses some device is actually in.
        statuses = DeviceFilters.ABMStatus.allCases
            .filter { $0 != .any }
            .map { status in
                (status, reports.count { status.matches($0) })
            }
            .filter { $0.1 > 0 }

        // Issues that could apply to this mix of devices, with how many match.
        //
        // A criterion the connection has no source for is left out entirely
        // rather than offered with a count of zero: on Jamf School, filtering
        // for an expired MDM profile would hide every device, having read no
        // expiry for any of them. Passcode state is excluded for the same
        // reason the coverage and update columns are: Jamf School reports it
        // per device, so a lookup has it for none of them yet, and Intune
        // does not report it at all.
        issues = DeviceFilters.Issue.allCases
            .filter { issue in
                switch issue {
                case .fileVaultOff: hasComputers && capabilities.contains(.fileVault)
                case .noPasscode: hasMobileDevices && capabilities.contains(.passcodeState)
                case .mdmProfileExpired: capabilities.contains(.mdmProfileExpiry)
                default: true
                }
            }
            .map { issue in (issue, reports.count { issue.matches($0) }) }
    }
}

extension ManagedDeviceInfo {
    /// The installed OS as the connected product reports it: a version and
    /// build from Jamf Pro, or a named OS and version from Jamf School, which
    /// reports no build. Each keeps what its product knows rather than being
    /// trimmed to a common shape.
    var osDisplay: String? {
        guard let osVersion, !osVersion.isEmpty else { return nil }
        if let osBuild, !osBuild.isEmpty { return "\(osVersion) (\(osBuild))" }
        if let osName, !osName.isEmpty { return "\(osName) \(osVersion)" }
        return osVersion
    }

    /// Site ID with Jamf Pro's "no site" sentinel treated as absent, so the
    /// filter can offer None alongside the real sites.
    var normalizedSiteID: String? {
        guard let siteID, siteID != "-1" else { return nil }
        return siteID
    }

    /// What the record is grouped under: a Jamf Pro site or a Jamf School
    /// location. One filter covers both, since a record only ever has one of
    /// them and the question being asked is the same.
    var groupingID: String? {
        locationID ?? normalizedSiteID
    }
}
