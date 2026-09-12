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
        return count
    }

    func matches(_ report: DeviceReport) -> Bool {
        kind.matches(report)
            && appleBusiness.matches(report)
            && mdmServer.matches(report.abm.value?.mdmServerID, hasRecord: report.abm.value != nil)
            && prestage.matches(report.jamf.value?.prestageID, hasRecord: report.jamf.value != nil)
            && site.matches(report.jamf.value?.normalizedSiteID, hasRecord: report.jamf.value != nil)
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

    /// Conditions worth singling out, each phrased as a problem to look for.
    nonisolated enum Issue: String, CaseIterable, Identifiable, Equatable {
        case mdmProfileExpired
        case appleBusinessOnly
        case jamfProOnly
        case migrationInProgress
        case fileVaultOff
        case noPasscode

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mdmProfileExpired: "MDM profile expired"
            case .appleBusinessOnly: "In Apple Business, no Jamf Pro record"
            case .jamfProOnly: "In Jamf Pro, not in Apple Business"
            case .migrationInProgress: "Migration in progress"
            case .fileVaultOff: "FileVault not enabled"
            case .noPasscode: "No passcode set"
            }
        }

        func matches(_ report: DeviceReport) -> Bool {
            switch self {
            case .mdmProfileExpired:
                guard let expiry = report.jamf.value?.mdmProfileExpiration,
                      let date = DateFormatting.parseISO(expiry) else { return false }
                return date < Date()
            case .appleBusinessOnly:
                // Both sides must have answered: a lookup still running, or one
                // that failed, says nothing about whether the device is missing.
                guard report.abm.value != nil else { return false }
                if case .notFound = report.jamf { return true }
                return false
            case .jamfProOnly:
                guard report.jamf.value != nil else { return false }
                if case .notFound = report.abm { return true }
                return false
            case .migrationInProgress:
                return report.abm.value?.device.hasActiveMigration == true
            case .fileVaultOff:
                return report.jamf.value?.encryption?.isEncrypted == false
            case .noPasscode:
                return report.jamf.value?.security?.passcodePresent == false
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

    var servers: [Option] = []
    var prestages: [Option] = []
    var sites: [Option] = []
    /// Whether any device has a record but no value, so None is worth offering.
    var serverNone = 0
    var prestageNone = 0
    var siteNone = 0
    var statuses: [(status: DeviceFilters.ABMStatus, count: Int)] = []
    var issues: [(issue: DeviceFilters.Issue, count: Int)] = []
    var hasComputers = false
    var hasMobileDevices = false

    var showAppleBusiness: Bool { !statuses.isEmpty }
    var showServers: Bool { !servers.isEmpty || serverNone > 0 }
    var showPrestages: Bool { !prestages.isEmpty || prestageNone > 0 }
    var showSites: Bool { !sites.isEmpty || siteNone > 0 }

    init(reports: [DeviceReport]) {
        var serverCounts: [String: (name: String, count: Int)] = [:]
        var prestageCounts: [String: (name: String, count: Int)] = [:]
        var siteCounts: [String: (name: String, count: Int)] = [:]

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
            if let jamf = report.jamf.value {
                if let id = jamf.prestageID {
                    let name = jamf.prestageName ?? id
                    prestageCounts[id] = (name, (prestageCounts[id]?.count ?? 0) + 1)
                } else {
                    prestageNone += 1
                }
                if let id = jamf.normalizedSiteID {
                    let name = jamf.siteName ?? id
                    siteCounts[id] = (name, (siteCounts[id]?.count ?? 0) + 1)
                } else {
                    siteNone += 1
                }
            }
        }

        func sorted(_ counts: [String: (name: String, count: Int)]) -> [Option] {
            counts
                .map { Option(id: $0.key, name: $0.value.name, count: $0.value.count) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        servers = sorted(serverCounts)
        prestages = sorted(prestageCounts)
        sites = sorted(siteCounts)

        // Only statuses some device is actually in.
        statuses = DeviceFilters.ABMStatus.allCases
            .filter { $0 != .any }
            .map { status in
                (status, reports.count { status.matches($0) })
            }
            .filter { $0.1 > 0 }

        // Issues that could apply to this mix of devices, with how many match.
        issues = DeviceFilters.Issue.allCases
            .filter { issue in
                switch issue {
                case .fileVaultOff: hasComputers
                case .noPasscode: hasMobileDevices
                default: true
                }
            }
            .map { issue in (issue, reports.count { issue.matches($0) }) }
    }
}

extension JamfInfo {
    /// Site ID with Jamf Pro's "no site" sentinel treated as absent, so the
    /// filter can offer None alongside the real sites.
    var normalizedSiteID: String? {
        guard let siteID, siteID != "-1" else { return nil }
        return siteID
    }
}
