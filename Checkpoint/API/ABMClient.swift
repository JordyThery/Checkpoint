import Foundation
import JTKit
import CryptoKit

// MARK: - Models

struct ABMDevice: Decodable, Sendable {
    let serialNumber: String
    let deviceModel: String?
    let productFamily: String?
    /// ASSIGNED or UNASSIGNED (to a device management service).
    let status: String?
    let addedToOrgDateTime: String?
    let releasedFromOrgDateTime: String?
    let orderNumber: String?
    let orderDateTime: String?
    let purchaseSourceType: String?
    /// Apple Customer Number or Reseller Number, depending on the source type.
    let purchaseSourceId: String?
    let color: String?
    let deviceCapacity: String?
    /// The product type identifier, e.g. iPad14,1.
    let productType: String?
    let partNumber: String?
    /// Cellular identifiers; arrays because a device can hold more than one.
    let imei: [String]?
    let meid: [String]?
    let eid: String?
    let wifiMacAddress: String?
    let bluetoothMacAddress: String?
    let ethernetMacAddress: [String]?
    /// Whether the device can be moved between device management services with
    /// a deadline instead of being reassigned outright. Absent on tenants that
    /// do not serve the migration release.
    let isMdmMigrationCapable: Bool?
    /// REQUESTED, STARTED, SUCCESS or FAILED. Only set once a migration has
    /// been requested for the device.
    let mdmMigrationStatus: String?
    let mdmMigrationDeadlineDateTime: String?

    /// The IMEI list as one value, nil when Apple sends none — it sends an
    /// empty array rather than omitting the field.
    var imeiDisplay: String? {
        guard let imei, !imei.isEmpty else { return nil }
        return imei.joined(separator: ", ")
    }

    /// A migration Apple has accepted but not yet completed.
    var hasActiveMigration: Bool {
        let status = mdmMigrationStatus?.uppercased()
        return status == "REQUESTED" || status == "STARTED"
    }

    /// How a finished migration should be described, or nil when none has been
    /// requested. Apple reports a cancelled migration with the same FAILED
    /// status as an unsuccessful one, so neither is called a failure here.
    var migrationOutcome: String? {
        switch mdmMigrationStatus?.uppercased() {
        case "SUCCESS": "Migrated"
        case "FAILED": "Not migrated"
        case .some(let status) where !status.isEmpty: status.capitalized
        default: nil
        }
    }
}



/// A device enrolled in Apple's built-in device management, as its list
/// reports it. The interesting state lives on the per-device detail.
nonisolated struct ABMManagedDevice: Sendable {
    /// The opaque resource ID the detail endpoint is addressed by — not the
    /// serial number.
    let id: String
    let serialNumber: String
    let deviceName: String?
    let productFamily: String?

    var kind: DeviceKind {
        productFamily?.uppercased() == "MAC" ? .computer : .mobileDevice
    }
}

/// The management state of one device under Apple's built-in management.
/// Read-only throughout: the API publishes no commands for these devices,
/// so this is reporting, never control.
nonisolated struct ABMManagedDeviceDetail: Sendable, Decodable {
    let lastCheckInDateTime: String?
    let osVersion: String?
    let platform: String?
    let isFileVaultEnabled: Bool?
    let isFirewallEnabled: Bool?
    let deviceLockStatus: String?
    let deviceEraseStatus: String?
    let lostModeStatus: String?
}

/// One audit event about a device, reduced to what the history shows: when,
/// what, by whom, and whether it succeeded. The organization records far more
/// event types; only device events carry a serial as their subject, so only
/// they ever appear here.
nonisolated struct ABMAuditEvent: Sendable, Identifiable {
    let id: String
    let dateTime: String?
    let type: String?
    let actorName: String?
    let outcome: String?
    /// Event payload details, each present only on its own event type.
    let targetServerName: String?
    let sourceServerName: String?
    let releaseEntityType: String?
    let purchaseSourceType: String?

    var isFailure: Bool { outcome?.uppercased() == "FAILURE" }

    /// One sentence, in the app's own voice. The payload names the server or
    /// source where the event carries one; the type alone still reads as a
    /// sentence when it does not.
    var summary: String {
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

/// A page of a device's history, with the cursor that continues it.
nonisolated struct ABMAuditPage: Sendable {
    let events: [ABMAuditEvent]
    let nextCursor: String?
}

struct AppleCareCoverage: Sendable, Identifiable, Hashable {
    let id: String
    let description: String?
    let status: String?
    let startDateTime: String?
    let endDateTime: String?

    /// Apple reports non-active coverage as INACTIVE; show "Expired" once the
    /// end date has passed, which is what that almost always means.
    var displayStatus: String {
        if status?.uppercased() == "ACTIVE" { return "Active" }
        if let end = endDateTime, let date = DateFormatting.parseISO(end), date < Date() {
            return "Expired"
        }
        return status?.capitalized ?? "—"
    }
}

/// A device's Activation Lock state, as the Apple organization reports it.
///
/// Added to both Apple services in September 2026, and the authoritative
/// source: the organization reports the live state, covers Macs as well as
/// mobile devices, and is the only one that says which kind of lock it is.
nonisolated struct ABMActivationLock: Sendable {
    let isLocked: Bool
    /// `MDM`, `USER` or `NONE`. Only meaningful while locked.
    let lockType: String?

    /// Enabled or disabled, as the FileVault and passcode rows word an
    /// on-or-off state. The kind of lock goes in `detail`, so the first word
    /// is always the answer.
    var summary: String {
        isLocked ? "Enabled" : "Disabled"
    }

    /// The lock type and what it means for clearing the lock. Worded so that
    /// neither line suggests Checkpoint holds the bypass code: it is escrowed
    /// with Apple and the MDM, and Checkpoint neither reads nor stores it.
    var detail: String? {
        guard isLocked else { return nil }
        switch lockType?.uppercased() {
        case "MDM": return "MDM lock. A bypass code is escrowed, so clearing it does not need the owner."
        case "USER": return "User lock. Clearing it needs the owner's Apple Account."
        default: return nil
        }
    }
}

struct MDMServer: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    /// MDM, APPLE_CONFIGURATOR or APPLE_MDM — the last is Apple's built-in
    /// device management. Nil on entries read before the field existed.
    let serverType: String?
    let status: String?

    var isAppleManagement: Bool { serverType?.uppercased() == "APPLE_MDM" }
}

nonisolated enum ABMSnapshotProgress: Sendable {
    /// Devices read so far. Apple returns a cursor but never a total, so this
    /// can only count up.
    case devices(Int)
    /// Management services whose device assignments have been read.
    case assignments(done: Int, total: Int)

    var description: String {
        switch self {
        case .devices(let count):
            "Reading devices… \(count.formatted())"
        case .assignments(let done, let total):
            "Reading assignments… \(done) of \(total) services"
        }
    }
}

/// Everything Apple reports about an organization in bulk.
///
/// Apple allows an organization only about twenty requests a minute and
/// offers no way to filter the device list, so asking per device does not
/// scale: a few hundred devices would take the best part of an hour. Reading
/// the whole organization instead costs one request per thousand devices plus
/// one per device management service, which is about twenty requests for any
/// realistic organization.
///
/// AppleCare coverage is the one thing not included: it has no bulk endpoint
/// and is fetched per device, on demand.
nonisolated struct ABMSnapshot: Sendable {
    /// Keyed by serial number, uppercased.
    let devices: [String: ABMDevice]
    /// Serial number to the ID of the device management service it is
    /// assigned to. Absent means unassigned.
    let serverIDBySerial: [String: String]
    /// The organization's device management services, which the read needs
    /// anyway to map the assignments above. Carried so that a caller wanting
    /// their names does not ask for the same list again.
    let servers: [MDMServer]
    let capturedAt: Date

    /// Order numbers present in the organization, most devices first.
    var orders: [(number: String, count: Int)] {
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
    func serials(inOrder order: String) -> [String] {
        devices.values
            .filter { $0.orderNumber?.trimmingCharacters(in: .whitespaces) == order }
            .map(\.serialNumber)
            .sorted()
    }
}

// MARK: - Client

/// Client for the Apple Business and Apple School Manager APIs, which are
/// the same API behind `api-business.apple.com` and `api-school.apple.com`.
/// Authenticates with the OAuth 2 client-credentials grant using an
/// ES256-signed JWT client assertion.
actor ABMClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum ActivityType: String, Sendable {
        case assign = "ASSIGN_DEVICES"
        case unassign = "UNASSIGN_DEVICES"
        /// Apple Business only: Apple School Manager defines no such activity.
        case release = "RELEASE_DEVICES"
        /// Assigns to a device management service and schedules a migration by
        /// a deadline. The device stays enrolled in its current service until
        /// it migrates, so nothing is erased.
        case assignWithMigrationDeadline = "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE"
        /// Moves the deadline of a migration already in progress. A deadline
        /// earlier than the current one, or in the past, is enforced at once
        /// without offering the user a chance to delay.
        case updateMigrationDeadline = "UPDATE_MDM_MIGRATION_DEADLINE"
        case cancelMigration = "CANCEL_MDM_MIGRATION"

        /// Apple rejects the request without an `mdmServer` relationship.
        var needsMDMServer: Bool {
            self == .assign || self == .unassign || self == .assignWithMigrationDeadline
        }

        var needsDeadline: Bool {
            self == .assignWithMigrationDeadline || self == .updateMigrationDeadline
        }
    }

    /// Apple rejects deadlines further out than this.
    static let maximumMigrationDeadline: TimeInterval = 90 * 24 * 60 * 60

    /// Apple's examples use an ISO 8601 timestamp in UTC with milliseconds.
    private static let deadlineFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private let clientID: String
    private let keyID: String
    private let privateKeyPEM: String
    /// Apple Business and Apple School Manager are the same API behind two
    /// hosts: same paths, same device attributes, same OAuth flow. Only the
    /// host, the scope, and the availability of Release differ.
    private let kind: AppleOrgKind
    private let baseURL: URL
    private let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/v2/token")!
    private var cachedToken: (value: String, expiry: Date)?
    /// The sign-in in flight, so concurrent callers share one.
    private var signIn: Task<String, any Error>?
    /// Sends each request and records it in the activity log (JTKit), with
    /// the organization's name so a log covering several says which one.
    private let recorder: RequestRecorder

    init(
        clientID: String,
        keyID: String,
        privateKeyPEM: String,
        kind: AppleOrgKind = .business,
        connectionName: String = "",
        log: ActivityLog? = nil,
        session: URLSession = .shared
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKeyPEM = privateKeyPEM
        self.kind = kind
        self.baseURL = kind.host
        self.recorder = RequestRecorder(session: session, log: log, service: kind.activityService.rawValue,
                                        connection: connectionName.isEmpty ? nil : connectionName)
    }

    // MARK: Devices

    /// Returns nil when the serial is unknown to this organization
    /// (never enrolled, or already released).
    func device(serial: String) async throws -> ABMDevice? {
        struct Response: Decodable {
            let data: Item
            struct Item: Decodable { let attributes: ABMDevice }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)", recordsBodies: true)
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        return try JSONDecoder().decode(Response.self, from: data).data.attributes
    }

    func appleCareCoverage(serial: String) async throws -> [AppleCareCoverage] {
        struct Response: Decodable {
            let data: [Item]
            struct Item: Decodable {
                let id: String
                let attributes: Attributes
            }
            struct Attributes: Decodable {
                let description: String?
                let startDateTime: String?
                let endDateTime: String?
                let status: String?
            }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)/appleCareCoverage", recordsBodies: true)
        if status == 404 { return [] }
        try throwIfError(status: status, data: data)
        return try JSONDecoder().decode(Response.self, from: data).data.map {
            AppleCareCoverage(
                id: $0.id,
                description: $0.attributes.description,
                status: $0.attributes.status,
                startDateTime: $0.attributes.startDateTime,
                endDateTime: $0.attributes.endDateTime
            )
        }
    }

    /// Activation Lock state for one device, or nil when the organization
    /// will not say.
    ///
    /// Apple documents a server error for a device reporting an internal-only
    /// lock state, so a 5xx is treated as "no answer" rather than surfaced:
    /// it is a quirk of the device's report, not a fault the user can act on.
    func activationLock(serial: String) async throws -> ABMActivationLock? {
        struct Response: Decodable {
            let data: Item
            struct Item: Decodable { let attributes: Attributes }
            struct Attributes: Decodable {
                let isLocked: Bool?
                let lockType: String?
            }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)/activationLockStatus", recordsBodies: true)
        if status == 404 || status >= 500 { return nil }
        try throwIfError(status: status, data: data)
        let attributes = try JSONDecoder().decode(Response.self, from: data).data.attributes
        return ABMActivationLock(isLocked: attributes.isLocked ?? false, lockType: attributes.lockType)
    }



    /// Every device enrolled in Apple's built-in device management, keyed by
    /// serial. The endpoint offers no filters, so the list is read whole and
    /// matched locally — these fleets are small by nature.
    func appleManagedDevices() async throws -> [String: ABMManagedDevice] {
        struct Response: Decodable {
            let data: [Item]
            let links: Links?
            struct Item: Decodable {
                let id: String
                let attributes: Attributes
            }
            struct Attributes: Decodable {
                let serialNumber: String?
                let deviceName: String?
                let productFamily: String?
            }
            struct Links: Decodable { let next: String? }
        }
        var devices: [String: ABMManagedDevice] = [:]
        var nextURL: URL? = URL(string: "/v1/mdmDevices?limit=100", relativeTo: baseURL)?.absoluteURL
        while let url = nextURL {
            let (data, status) = try await send(url: url)
            try throwIfError(status: status, data: data)
            let page = try JSONDecoder().decode(Response.self, from: data)
            for item in page.data {
                guard let serial = item.attributes.serialNumber, !serial.isEmpty else { continue }
                devices[serial.uppercased()] = ABMManagedDevice(
                    id: item.id,
                    serialNumber: serial,
                    deviceName: item.attributes.deviceName,
                    productFamily: item.attributes.productFamily
                )
            }
            nextURL = page.links?.next.flatMap { URL(string: $0) }
        }
        return devices
    }

    /// The management state of one enrolled device, read on selection.
    func appleManagedDeviceDetails(id: String) async throws -> ABMManagedDeviceDetail? {
        struct Response: Decodable {
            let data: Item
            struct Item: Decodable { let attributes: ABMManagedDeviceDetail }
        }
        let (data, status) = try await send(path: "/v1/mdmDevices/\(id)/details", recordsBodies: true)
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        return try JSONDecoder().decode(Response.self, from: data).data.attributes
    }

    /// The device's audit events, newest first, one page at a time.
    ///
    /// Apple requires the time window and takes the serial as the event
    /// subject. The payload shape varies per event type — one `eventData…`
    /// object keyed by `eventDataPropertyKey` — so this reads the body with
    /// JSONSerialization rather than modelling every variant.
    func auditEvents(
        serial: String,
        start: Date,
        end: Date,
        cursor: String? = nil,
        limit: Int = 100
    ) async throws -> ABMAuditPage {
        let formatter = ISO8601DateFormatter()
        var query = "filter%5BstartTimestamp%5D=\(formatter.string(from: start))"
            + "&filter%5BendTimestamp%5D=\(formatter.string(from: end))"
            + "&filter%5BsubjectId%5D=\(serial)&limit=\(limit)"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&cursor=\(encoded)"
        }
        let (data, status) = try await send(path: "/v1/auditEvents?\(query)")
        try throwIfError(status: status, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ABMAuditPage(events: [], nextCursor: nil)
        }
        let events = (root["data"] as? [[String: Any]] ?? []).compactMap { item -> ABMAuditEvent? in
            guard let id = item["id"] as? String,
                  let attributes = item["attributes"] as? [String: Any] else { return nil }
            let payload = (attributes["eventDataPropertyKey"] as? String)
                .flatMap { attributes[$0] as? [String: Any] } ?? [:]
            return ABMAuditEvent(
                id: id,
                dateTime: attributes["eventDateTime"] as? String,
                type: attributes["type"] as? String,
                actorName: attributes["actorName"] as? String,
                outcome: attributes["outcome"] as? String,
                targetServerName: payload["targetServerName"] as? String,
                // The unassignment payload names the server it left; accept
                // either spelling in case Apple settles on one later.
                sourceServerName: (payload["serverName"] ?? payload["sourceServerName"]) as? String,
                releaseEntityType: payload["releaseEntityType"] as? String,
                purchaseSourceType: payload["purchaseSourceType"] as? String
            )
        }
        let nextCursor = ((root["meta"] as? [String: Any])?["paging"] as? [String: Any])?["nextCursor"] as? String
        // Newest first, however Apple orders the page.
        let sorted = events.sorted { ($0.dateTime ?? "") > ($1.dateTime ?? "") }
        return ABMAuditPage(events: sorted, nextCursor: nextCursor)
    }

    /// The ID of the MDM server the device is assigned to, if any.
    func assignedServerID(serial: String) async throws -> String? {
        struct Response: Decodable {
            let data: Ref?
            struct Ref: Decodable { let id: String }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)/relationships/assignedServer", recordsBodies: true)
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        return try JSONDecoder().decode(Response.self, from: data).data?.id
    }

    func mdmServers() async throws -> [MDMServer] {
        struct Response: Decodable {
            let data: [Item]
            let links: Links?
            struct Item: Decodable {
                let id: String
                let attributes: Attributes
            }
            struct Attributes: Decodable {
                let serverName: String?
                let serverType: String?
                let status: String?
            }
            struct Links: Decodable { let next: String? }
        }

        var servers: [MDMServer] = []
        var nextURL: URL? = URL(string: "/v1/mdmServers?limit=100", relativeTo: baseURL)?.absoluteURL
        while let url = nextURL {
            let (data, status) = try await send(url: url)
            try throwIfError(status: status, data: data)
            let page = try JSONDecoder().decode(Response.self, from: data)
            servers += page.data.map {
                MDMServer(
                    id: $0.id,
                    name: $0.attributes.serverName ?? $0.id,
                    serverType: $0.attributes.serverType,
                    status: $0.attributes.status
                )
            }
            nextURL = page.links?.next.flatMap { URL(string: $0) }
        }
        return servers
    }

    // MARK: Organization snapshot

    /// The attributes `ABMDevice` decodes. Asking for only these cuts the
    /// device list by about 80%, which matters when reading thousands.
    private static let deviceFields = [
        "serialNumber", "deviceModel", "productFamily", "status",
        "addedToOrgDateTime", "releasedFromOrgDateTime", "orderNumber",
        "orderDateTime", "purchaseSourceType", "purchaseSourceId",
        "color", "deviceCapacity", "productType", "partNumber",
        "imei", "meid", "eid",
        "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress",
        "isMdmMigrationCapable",
        "mdmMigrationStatus", "mdmMigrationDeadlineDateTime",
    ].joined(separator: ",")

    /// Reads the whole organization: every device, and which management
    /// service each is assigned to.
    ///
    /// Both phases report progress, because the second is the slow one. The
    /// device list is a handful of large pages, while assignments are one
    /// request per management service and so spend most of their time
    /// waiting on the quota.
    func organizationSnapshot(progress: (@Sendable (ABMSnapshotProgress) -> Void)? = nil) async throws -> ABMSnapshot {
        struct DeviceResponse: Decodable {
            let data: [Item]
            let links: Links?
            struct Item: Decodable { let attributes: ABMDevice }
            struct Links: Decodable { let next: String? }
        }
        var devices: [String: ABMDevice] = [:]
        var next: URL? = URL(
            string: "/v1/orgDevices?limit=1000&fields%5BorgDevices%5D=\(Self.deviceFields)",
            relativeTo: baseURL
        )?.absoluteURL
        while let url = next {
            let (data, status) = try await send(url: url)
            try throwIfError(status: status, data: data)
            let page = try JSONDecoder().decode(DeviceResponse.self, from: data)
            for item in page.data {
                devices[item.attributes.serialNumber.uppercased()] = item.attributes
            }
            progress?(.devices(devices.count))
            next = page.links?.next.flatMap { URL(string: $0) }
        }

        // Assignments come from the other direction: the device list carries
        // only a link per device, but each management service can list its
        // own devices, and there are few of those.
        struct AssignmentResponse: Decodable {
            let data: [Item]
            let links: Links?
            struct Item: Decodable { let id: String }
            struct Links: Decodable { let next: String? }
        }
        var serverIDBySerial: [String: String] = [:]
        let servers = try await mdmServers()
        for (index, server) in servers.enumerated() {
            progress?(.assignments(done: index, total: servers.count))
            var page: URL? = URL(
                string: "/v1/mdmServers/\(server.id)/relationships/devices?limit=1000",
                relativeTo: baseURL
            )?.absoluteURL
            while let url = page {
                let (data, status) = try await send(url: url)
                // A service the account cannot read must not fail the snapshot.
                guard (200...299).contains(status) else { break }
                guard let decoded = try? JSONDecoder().decode(AssignmentResponse.self, from: data) else { break }
                for item in decoded.data {
                    serverIDBySerial[item.id.uppercased()] = server.id
                }
                page = decoded.links?.next.flatMap { URL(string: $0) }
            }
        }

        return ABMSnapshot(
            devices: devices,
            serverIDBySerial: serverIDBySerial,
            servers: servers,
            capturedAt: Date()
        )
    }

    // MARK: Activities

    /// Submits an org device activity and returns its ID. ABM processes these
    /// asynchronously. Poll with `waitForActivity` before re-reading state.
    @discardableResult
    func submitActivity(
        _ type: ActivityType,
        serials: [String],
        mdmServerID: String? = nil,
        migrationDeadline: Date? = nil
    ) async throws -> String? {
        var relationships: [String: Any] = [
            "devices": ["data": serials.map { ["type": "orgDevices", "id": $0] }]
        ]
        if let mdmServerID {
            relationships["mdmServer"] = ["data": ["type": "mdmServers", "id": mdmServerID]]
        }
        guard type != .release || kind.supportsRelease else {
            throw APIError(message: "\(kind.label) cannot release devices from the organization.")
        }
        var attributes: [String: Any] = ["activityType": type.rawValue]
        if type.needsDeadline {
            guard let migrationDeadline else {
                throw APIError(message: "\(type.rawValue) requires a migration deadline.")
            }
            guard migrationDeadline.timeIntervalSinceNow <= Self.maximumMigrationDeadline else {
                throw APIError(message: "\(kind.label) will not accept a migration deadline more than 90 days from now.")
            }
            attributes["activityTypeMetadata"] = [
                "mdmMigrationDeadlineDateTime": Self.deadlineFormatter.string(from: migrationDeadline)
            ]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [
                "type": "orgDeviceActivities",
                "attributes": attributes,
                "relationships": relationships,
            ]
        ])
        let (data, status) = try await send(path: "/v1/orgDeviceActivities", method: "POST", body: body)
        try throwIfError(status: status, data: data)
        struct Response: Decodable {
            let data: Item?
            struct Item: Decodable { let id: String }
        }
        return (try? JSONDecoder().decode(Response.self, from: data))?.data?.id
    }

    /// Waits until the activity leaves the in-progress states or the timeout
    /// elapses, so a follow-up device fetch sees the new assignment. Returns
    /// without throwing on timeout, so the caller refreshes with whatever state
    /// ABM reports at that point.
    func waitForActivity(id: String, timeout: TimeInterval = 30) async {
        struct Response: Decodable {
            let data: Item?
            struct Item: Decodable { let attributes: Attributes? }
            struct Attributes: Decodable { let status: String? }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let (data, status) = try? await send(path: "/v1/orgDeviceActivities/\(id)"),
                  (200...299).contains(status),
                  let activityStatus = (try? JSONDecoder().decode(Response.self, from: data))?.data?.attributes?.status
            else { return }
            switch activityStatus.uppercased() {
            case "IN_PROGRESS", "PENDING", "SUBMITTED":
                try? await Task.sleep(for: .seconds(2))
            default:
                return
            }
        }
    }

    /// Cheap connectivity/credentials check.
    func verify() async throws -> Int {
        try await mdmServers().count
    }

    // MARK: Plumbing

    /// - Parameter recordsBodies: record a successful answer too; only for
    ///   the read-only device lookups (ROADMAP step 5, "Checkpoint").
    private func send(path: String, method: String = "GET", body: Data? = nil,
                      recordsBodies: Bool = false) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError(message: "Invalid URL for path \(path)")
        }
        return try await send(url: url.absoluteURL, method: method, body: body, recordsBodies: recordsBodies)
    }

    // Apple limits how many requests an organization may make per minute. It
    // does not answer with 429 and a Retry-After: past the limit it simply
    // stops completing connections, so the failure arrives as a URLSession
    // error, and it stays that way until the window has passed. Measured
    // against a live tenant: about twenty requests, at any pacing.
    //
    // Requests are therefore held inside the window below, and reads that
    // fail anyway are retried with a widening delay. Without this, a lookup
    // of a few hundred devices fails partway through.

    /// Requests allowed in any rolling minute.
    ///
    /// Measured against a live organization: the twenty-first request in
    /// quick succession fails, and slowing the pace does not help, so this is
    /// a quota on count rather than a rate. Eighteen leaves a little room for
    /// the token request and for whatever else the account is doing.
    private static let windowLimit = 18
    private static let window: TimeInterval = 60
    private static let maximumAttempts = 4
    /// When the recent requests were sent, oldest first.
    private var recentRequests: [Date] = []

    /// Waits until sending another request would stay inside the quota.
    /// Small lookups never wait; large ones pace themselves.
    private func reserveRequestSlot() async {
        while true {
            let now = Date()
            recentRequests.removeAll { now.timeIntervalSince($0) >= Self.window }
            if recentRequests.count < Self.windowLimit {
                recentRequests.append(now)
                return
            }
            guard let oldest = recentRequests.first else { return }
            let wait = Self.window - now.timeIntervalSince(oldest) + 0.1
            try? await Task.sleep(for: .seconds(max(wait, 0.1)))
        }
    }

    /// The single point every Apple Business request goes through. JTKit's
    /// recorder records each attempt (the bearer token redacted, request
    /// bodies never); the pacing and retries are Apple's own, below.
    private func send(url: URL, method: String = "GET", body: Data? = nil,
                      recordsBodies: Bool = false) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var lastError: Error?
        for attempt in 0..<Self.maximumAttempts {
            await reserveRequestSlot()
            do {
                let (data, response) = try await recorder.send(request, attempt: attempt + 1, of: Self.maximumAttempts,
                                                               recordsBodies: recordsBodies)
                let status = response.statusCode
                // 429 and 503 are retried on the same terms as a dropped
                // connection, in case Apple starts answering properly.
                if (status == 429 || status == 503), attempt < Self.maximumAttempts - 1 {
                    await noteWait(attempt, reason: "HTTP \(status)", method: method, url: url)
                    try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
                    continue
                }
                return (data, status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // A lost connection is ambiguous: Apple may have processed the
                // request before dropping it. Reads are safe to repeat; a
                // repeated activity submission would apply twice, so writes
                // surface the error instead. (429 and 503 above are different:
                // they mean the request was not processed.)
                let willRetry = method == "GET" && attempt < Self.maximumAttempts - 1
                guard willRetry else { break }
                await noteWait(attempt, reason: "Network error", method: method, url: url)
                try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
            }
        }
        throw lastError ?? APIError(message: "\(kind.label) did not answer.")
    }

    /// Writes the wait before the next attempt to the activity log.
    private func noteWait(_ attempt: Int, reason: String, method: String, url: URL) async {
        await recorder.note(method, url.path(),
                            note: "\(reason): waiting \(Int(Self.backoff(attempt))) s, attempt \(attempt + 2) of \(Self.maximumAttempts).",
                            category: "Retry", isWarning: true)
    }

    /// 5s, 15s, 45s. Once the quota is spent Apple stays quiet for a while,
    /// so a short retry only wastes another request.
    nonisolated static func backoff(_ attempt: Int) -> Double {
        [5, 15, 45][min(attempt, 2)]
    }

    private func throwIfError(status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        struct ErrorResponse: Decodable {
            let errors: [Item]?
            struct Item: Decodable {
                let title: String?
                let detail: String?
            }
        }
        var detail = ""
        if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let first = parsed.errors?.first {
            detail = first.detail ?? first.title ?? ""
        }
        throw APIError(message: "\(kind.label): HTTP \(status)\(detail.isEmpty ? "" : " – \(detail)")")
    }

    // MARK: OAuth

    /// One token request at a time.
    ///
    /// A lookup starts several reads at once, and each would otherwise find
    /// no cached token and ask for its own — five sign-ins in the same
    /// second, four of them wasted. Callers arriving while one is in flight
    /// wait for it instead.
    private func bearerToken() async throws -> String {
        if let cachedToken, cachedToken.expiry > Date() { return cachedToken.value }
        if let signIn { return try await signIn.value }
        let task = Task { try await signingIn() }
        signIn = task
        defer { signIn = nil }
        return try await task.value
    }

    /// Recorded as a "Sign-in" request, but never with its bodies: the
    /// request carries the signed client assertion, which is itself a
    /// credential, and the response carries the access token.
    private func signingIn() async throws -> String {
        try await fetchToken()
    }

    private func fetchToken() async throws -> String {
        let assertion = try makeClientAssertion()
        let params = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_assertion_type", value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            URLQueryItem(name: "client_assertion", value: assertion),
            URLQueryItem(name: "scope", value: kind.scope),
        ]
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(params).utf8)

        let (data, response) = try await recorder.send(request, category: "Sign-in")
        guard response.statusCode == 200 else {
            let body = Redaction.text(String(data: data, encoding: .utf8) ?? "")
            throw APIError(message: "\(kind.label) sign-in failed: \(body.prefix(300))")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(TimeInterval(max(token.expires_in - 120, 60)))
        cachedToken = (token.access_token, expiry)
        return token.access_token
    }

    /// Reads the downloaded private key.
    ///
    /// Apple School Manager hands out a key whose armour says
    /// `EC PRIVATE KEY`, the SEC1 label, wrapped around a PKCS#8 body. CryptoKit
    /// believes the label, parses it as SEC1 and fails; OpenSSL accepts the
    /// same file because it inspects the contents instead. The armour is
    /// therefore swapped and retried, which costs nothing when the label was
    /// right to begin with and still rejects a key that is genuinely wrong.
    private nonisolated static func readPrivateKey(_ pem: String) throws -> P256.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return key }

        let swapped: String
        if trimmed.contains("BEGIN EC PRIVATE KEY") {
            swapped = trimmed
                .replacingOccurrences(of: "BEGIN EC PRIVATE KEY", with: "BEGIN PRIVATE KEY")
                .replacingOccurrences(of: "END EC PRIVATE KEY", with: "END PRIVATE KEY")
        } else {
            swapped = trimmed
                .replacingOccurrences(of: "BEGIN PRIVATE KEY", with: "BEGIN EC PRIVATE KEY")
                .replacingOccurrences(of: "END PRIVATE KEY", with: "END EC PRIVATE KEY")
        }
        return try P256.Signing.PrivateKey(pemRepresentation: swapped)
    }

    private func makeClientAssertion() throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try Self.readPrivateKey(privateKeyPEM)
        } catch {
            throw APIError(message: "Could not read the \(kind.label) private key. Expected the PEM-encoded EC P-256 key downloaded when the API account was created.")
        }
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": clientID,
            "sub": clientID,
            "aud": tokenURL.absoluteString,
            "iat": now,
            "exp": now + 1200,
            "jti": UUID().uuidString,
        ]
        let signingInput = try Self.base64URL(json: header) + "." + Self.base64URL(json: claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    private static func base64URL(json object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
