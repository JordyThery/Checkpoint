import Foundation
import JTKit

// Apple Business and Apple School Manager on JTKit (ROADMAP step 9): the
// sign-in, client, limit, paging, errors, records and writes are JTKit's
// `ABM`. What stays here is Checkpoint's wording of the records (summaries,
// statuses, the Activation Lock lines) and a thin client with the calls the
// app already makes.

typealias ABMDevice = ABM.OrgDevice
typealias AppleCareCoverage = ABM.AppleCareCoverage
typealias ABMActivationLock = ABM.ActivationLock
typealias MDMServer = ABM.MDMServer
typealias ABMManagedDevice = ABM.ManagedDevice
typealias ABMManagedDeviceDetail = ABM.ManagedDeviceDetail
typealias ABMAuditEvent = ABM.AuditEvent
typealias ABMAuditPage = ABM.AuditPage
typealias ABMSnapshot = ABM.Snapshot
typealias ABMSnapshotProgress = ABM.SnapshotProgress

extension ABM.OrgDevice {
    /// The IMEI list as one value, nil when Apple sends none — it sends an
    /// empty array rather than omitting the field.
    nonisolated var imeiDisplay: String? {
        guard let imei, !imei.isEmpty else { return nil }
        return imei.joined(separator: ", ")
    }

    /// How a finished migration should be described, or nil when none has been
    /// requested. Apple reports a cancelled migration with the same FAILED
    /// status as an unsuccessful one, so neither is called a failure here.
    nonisolated var migrationOutcome: String? {
        switch mdmMigrationStatus?.uppercased() {
        case "SUCCESS": "Migrated"
        case "FAILED": "Not migrated"
        case .some(let status) where !status.isEmpty: status.capitalized
        default: nil
        }
    }
}

extension ABM.ManagedDevice {
    nonisolated var kind: DeviceKind { isMac ? .computer : .mobileDevice }
}

extension ABM.AppleCareCoverage {
    /// Apple reports non-active coverage as INACTIVE; show "Expired" once the
    /// end date has passed, which is what that almost always means.
    nonisolated var displayStatus: String {
        if isActive { return "Active" }
        if hasExpired() { return "Expired" }
        return status?.capitalized ?? "—"
    }
}

extension ABM.ActivationLock {
    /// Enabled or disabled, as the FileVault and passcode rows word an
    /// on-or-off state. The kind of lock goes in `detail`, so the first word
    /// is always the answer.
    nonisolated var summary: String {
        isLocked ? "Enabled" : "Disabled"
    }

    /// The lock type and what it means for clearing the lock. Worded so that
    /// neither line suggests Checkpoint holds the bypass code: it is escrowed
    /// with Apple and the MDM, and Checkpoint neither reads nor stores it.
    nonisolated var detail: String? {
        guard isLocked else { return nil }
        switch lockType?.uppercased() {
        case "MDM": return "MDM lock. A bypass code is escrowed, so clearing it does not need the owner."
        case "USER": return "User lock. Clearing it needs the owner's Apple Account."
        default: return nil
        }
    }
}

extension ABM.AuditEvent {
    /// One sentence, in the app's own voice. The payload names the server or
    /// source where the event carries one; the type alone still reads as a
    /// sentence when it does not.
    nonisolated var summary: String {
        switch type?.uppercased() {
        case "DEVICE_ADDED_TO_ORG":
            switch purchaseSourceType?.uppercased() {
            case "RESELLER": "Added from a reseller"
            case "APPLE": "Added from Apple"
            case "MANUALLY_ADDED": "Added manually"
            default: "Added to the organization"
            }
        case "DEVICE_ASSIGNED_TO_SERVER":
            targetServerName.map { "Assigned to \($0)" } ?? "Assigned to a device management service"
        case "DEVICE_UNASSIGNED_FROM_SERVER":
            sourceServerName.map { "Unassigned from \($0)" } ?? "Unassigned from device management"
        case "DEVICE_REMOVED_FROM_ORG":
            releaseEntityType?.uppercased() == "RESELLER"
                ? "Released by the reseller" : "Released from the organization"
        case "DEVICE_IS_ERASED": "Erased"
        case "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED": "AppleCare coverage added"
        case "SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED": "AppleCare coverage removed"
        case "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED": "iCloud storage added"
        case "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_REMOVED": "iCloud storage removed"
        default:
            (type ?? "Event").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension ABM.Snapshot {
    /// Order numbers present in the organization, most devices first.
    nonisolated var orders: [(number: String, count: Int)] {
        var counts: [String: Int] = [:]
        for device in devices.values {
            guard let order = device.orderNumber?.trimmingCharacters(in: .whitespaces), !order.isEmpty else { continue }
            counts[order, default: 0] += 1
        }
        return counts
            .map { (number: $0.key, count: $0.value) }
            // Count descending, then number ascending: the swapped members in
            // the right-hand tuple are what flip the second comparison.
            .sorted { ($0.count, $1.number) > ($1.count, $0.number) }
    }

    /// Trimmed comparison, matching how `orders` counts them.
    nonisolated func serials(inOrder order: String) -> [String] {
        devices.values
            .filter { $0.orderNumber?.trimmingCharacters(in: .whitespaces) == order }
            .map(\.serialNumber)
            .sorted()
    }
}

extension AppleOrgKind {
    nonisolated var service: ABM.Service {
        switch self {
        case .business: .business
        case .school: .school
        }
    }
}

/// Where the Apple client gets the time and how it waits. Tests pass a
/// virtual clock, so the 60 s window and the 5, 15 and 45 s waits take no
/// real time.
nonisolated struct ABMClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (Double) async throws -> Void

    static let live = ABMClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}

/// Checkpoint's calls on JTKit's Apple client, one per organization.
nonisolated final class ABMClient: Sendable {
    typealias ActivityType = ABM.ActivityType

    static let maximumMigrationDeadline = ABM.maximumMigrationDeadline

    let client: ABM.Client
    let tokens: ABM.TokenProvider

    /// - Parameter privateKey: read at each sign-in, so a new key is used at once.
    init(
        clientID: String,
        keyID: String,
        privateKey: @escaping @Sendable () throws -> String,
        kind: AppleOrgKind = .business,
        connectionName: String = "",
        log: ActivityLog? = nil,
        session: URLSession = .shared,
        clock: ABMClock = .live
    ) {
        let recorder = ABM.recorder(kind.service, session: session, log: log, connection: connectionName)
        tokens = ABM.TokenProvider(service: kind.service, clientID: clientID, keyID: keyID, privateKey: privateKey,
                                   recorder: recorder, now: clock.now)
        let sleep = clock.sleep
        client = ABM.Client(service: kind.service, tokens: tokens, recorder: recorder,
                            sleep: { try await sleep(Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) },
                            now: clock.now)
    }

    convenience init(clientID: String, keyID: String, privateKeyPEM: String, kind: AppleOrgKind = .business,
                     connectionName: String = "", log: ActivityLog? = nil, session: URLSession = .shared,
                     clock: ABMClock = .live) {
        self.init(clientID: clientID, keyID: keyID, privateKey: { privateKeyPEM }, kind: kind,
                  connectionName: connectionName, log: log, session: session, clock: clock)
    }

    func device(serial: String) async throws -> ABMDevice? { try await client.device(serial: serial) }
    func appleCareCoverage(serial: String) async throws -> [AppleCareCoverage] { try await client.appleCareCoverage(serial: serial) }
    func activationLock(serial: String) async throws -> ABMActivationLock? { try await client.activationLock(serial: serial) }
    func assignedServerID(serial: String) async throws -> String? { try await client.assignedServerID(serial: serial) }
    func mdmServers() async throws -> [MDMServer] { try await client.mdmServers() }
    func verify() async throws -> Int { try await client.verify() }
    func appleManagedDevices() async throws -> [String: ABMManagedDevice] { try await client.appleManagedDevices() }
    func appleManagedDeviceDetails(id: String) async throws -> ABMManagedDeviceDetail? {
        try await client.appleManagedDeviceDetails(id: id)
    }

    func auditEvents(serial: String, start: Date, end: Date, cursor: String? = nil, limit: Int = 100) async throws -> ABMAuditPage {
        try await client.auditEvents(serial: serial, start: start, end: end, cursor: cursor, limit: limit)
    }

    func organizationSnapshot(progress: (@Sendable (ABMSnapshotProgress) -> Void)? = nil) async throws -> ABMSnapshot {
        try await client.organizationSnapshot(progress: progress)
    }

    /// Sends a write; Apple's activity ID, nil when it returned none.
    @discardableResult
    func submitActivity(_ type: ActivityType, serials: [String], mdmServerID: String? = nil,
                        migrationDeadline: Date? = nil) async throws -> String? {
        try await client.submit(try ABM.Activity(type, serials: serials, serverID: mdmServerID, deadline: migrationDeadline))
    }

    /// Watches a write until Apple has finished with it (2 minutes at most).
    func watch(activityID: String?) async throws -> ABM.ActivityOutcome {
        try await client.watch(activityID: activityID)
    }
}
