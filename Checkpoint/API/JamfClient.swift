import Foundation

// MARK: - Models

nonisolated enum JamfDeviceKind: String, Sendable {
    case computer
    case mobileDevice
}

struct JamfComputerRecord: Sendable {
    let id: String
    let udid: String?
    /// UUID used by the modern /v2/mdm/commands endpoint.
    let managementID: String?
    let name: String?
    /// Last check-in (Jamf binary).
    let lastContactTime: String?
    /// Last Contact (binary, MDM, or DDM; inventory attribute added in Jamf Pro 11.30).
    let lastContact: String?
    let lastEnrolledDate: String?
    /// Last inventory update.
    let reportDate: String?
    let mdmProfileExpiration: String?
    let siteID: String?
    let siteName: String?
    /// FileVault state from the inventory record. This is the DISK_ENCRYPTION
    /// section, which reports encryption without carrying the recovery key,
    /// so it needs no privilege beyond Read Computers.
    let encryption: JamfDiskEncryption?
}

/// A Mac's FileVault state, as reported by inventory.
struct JamfDiskEncryption: Sendable {
    /// Jamf Pro's `fileVault2Enabled` flag. Not trustworthy on its own: it
    /// reports false for Macs encrypted by the user rather than through Jamf
    /// Pro, even with the boot partition fully encrypted and a valid key
    /// escrowed. Kept only as a fallback for when the partition state is
    /// missing or unknown.
    let fileVaultEnabled: Bool?
    /// Boot partition state, e.g. ENCRYPTED, ENCRYPTING or RESTART_NEEDED.
    /// This is the authoritative signal.
    let bootPartitionState: String?
    let bootPartitionPercent: Int?
    /// Jamf Pro's assessment of the escrowed personal key, e.g. VALID.
    let recoveryKeyValidity: String?

    nonisolated enum Status: Sendable {
        case enabled
        case notEnabled
        /// Encrypting, decrypting, or waiting for a restart.
        case inProgress
        case ineligible
        case unknown
    }

    var status: Status {
        switch bootPartitionState {
        case "ENCRYPTED": .enabled
        case "UNENCRYPTED", "DECRYPTED": .notEnabled
        case "INELIGIBLE": .ineligible
        case "ENCRYPTING", "DECRYPTING", "OPTIMIZING", "RESTART_NEEDED",
             "ENCRYPTING_PAUSED", "DECRYPTING_PAUSED": .inProgress
        default:
            // UNKNOWN or absent: the flag is all there is.
            switch fileVaultEnabled {
            case true: .enabled
            case false: .notEnabled
            default: .unknown
            }
        }
    }

    /// Whether FileVault is on, so far as can be told. Nil while in progress
    /// or unknown, which callers should treat as "do not disable anything".
    var isEncrypted: Bool? {
        switch status {
        case .enabled: true
        case .notEnabled, .ineligible: false
        case .inProgress, .unknown: nil
        }
    }

    var displaySummary: String {
        switch status {
        case .enabled: return "Enabled"
        case .notEnabled: return "Not enabled"
        case .ineligible: return "Ineligible"
        case .unknown: return "—"
        case .inProgress:
            // The state is the whole story here, e.g. Encrypting 42%.
            guard let state = bootPartitionState.map(JamfDisplay.sentenceCase) else { return "In progress" }
            guard let percent = bootPartitionPercent,
                  state.hasSuffix("ing") || state.hasSuffix("paused") else { return state }
            return "\(state) \(percent)%"
        }
    }

    /// Key validity only means something once the disk is encrypted: an
    /// unencrypted Mac reports UNKNOWN, which would read as a problem.
    var keyValidityWarning: String? {
        guard status == .enabled,
              let validity = recoveryKeyValidity,
              !["VALID", "NOT_APPLICABLE"].contains(validity) else { return nil }
        return "Recovery key \(validity.lowercased())"
    }
}

/// A mobile device's passcode and encryption state.
struct JamfMobileSecurity: Sendable {
    let passcodePresent: Bool?
    /// Compliant with Jamf Pro's own requirements.
    let passcodeCompliant: Bool?
    /// Compliant with the passcode profile scoped to the device.
    let passcodeCompliantWithProfile: Bool?
    let hardwareEncryption: Int?
}

struct JamfMobileDeviceRecord: Sendable {
    let id: String
    let udid: String?
    /// UUID used by the modern /v2/mdm/commands endpoint.
    let managementID: String?
    let name: String?
    let lastEnrolledDate: String?
    let lastInventoryDate: String?
    /// Last contact with the Jamf Pro server (inventory attribute added in Jamf Pro 11.30).
    let lastContactTime: String?
    let mdmProfileExpiration: String?
    let siteID: String?
    let siteName: String?
    /// Escrowed unlock token, required by the ClearPasscode MDM command.
    let unlockToken: String?
    let security: JamfMobileSecurity?
}

/// A managed local administrator account that Jamf Pro holds a password for.
/// Jamf Pro calls these Managed Local Administrator Accounts; the API calls
/// the feature LAPS.
struct JamfLocalAdminAccount: Sendable, Identifiable, Hashable {
    let username: String
    let guid: String
    /// MDM for the account created by a PreStage, JMF for one created by the
    /// Jamf binary. A device may have either, both, or neither.
    let source: String

    var id: String { guid.isEmpty ? username : guid }

    /// Matches the wording in the Jamf Pro interface.
    var sourceLabel: String {
        switch source.uppercased() {
        case "JMF": "jamf binary"
        case "MDM": "MDM"
        default: source
        }
    }
}

/// A device's software update state, as the device itself last reported it
/// through declarative device management.
///
/// Read from the device's declarative status report rather than from Jamf
/// Pro's managed software update plans or statuses. Software updates are
/// declarative now; the plan is Jamf Pro's orchestration record, while this
/// is what the device says about itself.
///
/// The report keeps sub-keys after the value above them clears, so a Mac can
/// still carry a pending version and deadline from months ago. Each value
/// therefore travels with the time the device reported it, and the failure
/// block is gated on the current failure count rather than on the presence of
/// a reason.
struct JamfSoftwareUpdateStatus: Sendable {
    /// `softwareupdate.install-state`, e.g. none, downloading, installing.
    let installState: String?
    let pendingOSVersion: String?
    let pendingBuildVersion: String?
    let deadline: Date?
    /// When the device last reported the pending version, so a stale value is
    /// visible as stale rather than presented as current.
    let pendingReportedAt: Date?
    let failureCount: Int?
    let failureReason: String?
    let failureAt: Date?
    /// Non-empty when the Mac is enrolled in a beta programme.
    let betaEnrollment: String?

    /// Whether the device is doing something about an update right now.
    var isInstalling: Bool {
        guard let state = installState?.lowercased() else { return false }
        return !state.isEmpty && state != "none"
    }

    var hasPendingUpdate: Bool {
        !(pendingOSVersion ?? "").isEmpty
    }

    /// A current failure, as opposed to a reason left behind by an old one.
    var hasFailure: Bool {
        (failureCount ?? 0) > 0
    }

    /// Nothing was reported at all: the device is not managed declaratively,
    /// or has not yet sent a status report.
    var isReported: Bool {
        installState != nil || hasPendingUpdate || hasFailure || betaEnrollment != nil
    }

    var displayState: String {
        if isInstalling { return JamfDisplay.sentenceCase(installState ?? "") }
        if hasPendingUpdate { return "Update pending" }
        return "No pending update"
    }

    /// Target version with its build, when the device reported one.
    var pendingVersion: String? {
        guard hasPendingUpdate, let version = pendingOSVersion else { return nil }
        guard let build = pendingBuildVersion, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

nonisolated enum JamfDisplay {
    /// Jamf Pro reports states as UPPER_SNAKE_CASE. Shown as sentence case so
    /// they read as prose: RESTART_NEEDED becomes Restart needed.
    static func sentenceCase(_ value: String) -> String {
        let words = value.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

nonisolated enum JamfGroupKind: String, Sendable, CaseIterable, Identifiable {
    case computer
    case mobileDevice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .computer: "Computers"
        case .mobileDevice: "Mobile Devices"
        }
    }

    /// Classic API resource. The modern endpoints return computer group
    /// membership as bare record IDs, which would need a request per device
    /// to resolve; the Classic ones carry the serial numbers directly.
    var groupResource: String {
        switch self {
        case .computer: "computergroups"
        case .mobileDevice: "mobiledevicegroups"
        }
    }
}

struct JamfGroup: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let isSmart: Bool
    let kind: JamfGroupKind

    var typeLabel: String { isSmart ? "Smart" : "Static" }
}

struct JamfSite: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct JamfFileVaultKey: Sendable {
    let personalRecoveryKey: String
    /// Jamf Pro's assessment of the stored key, e.g. VALID or UNKNOWN.
    let validityStatus: String?
    let configurationName: String?
}

/// The two PreStage families in Jamf Pro. Endpoint versions differ per family,
/// and older Jamf Pro versions serve older ones, hence the fallback lists.
nonisolated enum JamfPrestageFamily: Sendable {
    case computer
    case mobileDevice

    var pathComponent: String {
        switch self {
        case .computer: "computer-prestages"
        case .mobileDevice: "mobile-device-prestages"
        }
    }

    var listVersions: [String] {
        switch self {
        case .computer: ["v3", "v2"]
        // v3 is the only mobile PreStage version still in the published spec;
        // the older ones remain as fallbacks for older servers.
        case .mobileDevice: ["v3", "v2", "v1"]
        }
    }

    var scopeVersions: [String] {
        switch self {
        case .computer: ["v2"]
        case .mobileDevice: ["v2", "v1"]
        }
    }
}

struct JamfPrestage: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    /// The device-enrollment (ADE) instance the PreStage belongs to. Only
    /// devices synced through the same instance can be scoped to it.
    let enrollmentInstanceID: String?
}

// MARK: - Client

/// Client for the Jamf Pro API. Supports both API client (OAuth client
/// credentials) and username/password (bearer token) authentication.
actor JamfClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let baseURL: URL
    private let authMethod: JamfAuthMethod
    private let account: String
    private let secret: String
    /// Platform API only: sent as `X-Environment-Id` on every request.
    private let environmentID: String
    private var cachedToken: (value: String, expiry: Date)?
    private let log: ActivityLog?
    /// Server name, recorded with each entry so a log covering several
    /// connections says which one it went to.
    private let connectionName: String

    init?(config: JamfServerConfig, secret: String, log: ActivityLog? = nil) {
        guard let url = URL(string: config.apiBaseURL), url.host() != nil else { return nil }
        self.baseURL = url
        self.authMethod = config.authMethod
        self.account = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
        self.environmentID = config.environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.log = log
        self.connectionName = config.displayName
    }

    // MARK: Computers

    func computer(serial: String) async throws -> JamfComputerRecord? {
        // v4 is current. v3 and v1 are still served but no longer published, so
        // they remain only as fallbacks for older servers. The first version to
        // answer cleanly wins, including when it finds no match.
        var lastError: Error?
        for version in ["v4", "v3", "v1"] {
            do {
                return try await computerLookup(apiVersion: version, serial: serial)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(message: "Could not look up the computer.")
    }

    private func computerLookup(apiVersion: String, serial: String) async throws -> JamfComputerRecord? {
        struct Response: Decodable {
            let results: [Item]
            struct Item: Decodable {
                let id: String
                let udid: String?
                let general: General?
                let diskEncryption: DiskEncryption?
            }
            struct DiskEncryption: Decodable {
                let fileVault2Enabled: Bool?
                let individualRecoveryKeyValidityStatus: String?
                let bootPartitionEncryptionDetails: Partition?
            }
            struct Partition: Decodable {
                let partitionFileVault2State: String?
                let partitionFileVault2Percent: Int?
            }
            struct General: Decodable {
                let name: String?
                /// v4 name for the Jamf binary check-in. v1 and v3 call the
                /// same value lastContactTime.
                let lastCheckIn: String?
                let lastContactTime: String?
                /// Dedicated Last Contact attribute, present from the v4 schema.
                let lastContact: String?
                let lastEnrolledDate: String?
                let reportDate: String?
                // v1 name / v3+ name for the same value.
                let mdmProfileExpiration: String?
                let mdmCertificateExpiration: String?
                let managementId: String?
                let site: Site?
            }
            struct Site: Decodable {
                let id: String?
                let name: String?
            }
        }
        // DISK_ENCRYPTION reports FileVault state and costs about 500 bytes.
        // It deliberately carries no recovery key, so the lookup stays within
        // Read Computers and the response is safe to record in the log.
        //
        // Asked for on v4 only. v3 and v1 are unpublished fallbacks for older
        // servers, so whether they accept the section cannot be checked; one
        // rejecting it would fail the whole lookup rather than omit a row.
        var queryItems = [URLQueryItem(name: "section", value: "GENERAL")]
        if apiVersion == "v4" {
            queryItems.append(URLQueryItem(name: "section", value: "DISK_ENCRYPTION"))
        }
        queryItems += [
            URLQueryItem(name: "page-size", value: "10"),
            URLQueryItem(name: "filter", value: "hardware.serialNumber==\"\(serial)\""),
        ]
        let (data, status) = try await send(
            path: "/api/\(apiVersion)/computers-inventory",
            queryItems: queryItems
        )
        try throwIfError(status: status, data: data)
        guard let item = try JSONDecoder().decode(Response.self, from: data).results.first else { return nil }

        // v4 has a dedicated Last Contact attribute. v3 and v1 do not, so fall
        // back to scanning for a "lastContact" key other than the check-in one.
        var lastContact = item.general?.lastContact
        if lastContact == nil,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = root["results"] as? [[String: Any]],
           let general = results.first?["general"] as? [String: Any] {
            lastContact = general.first { key, value in
                key.lowercased().hasPrefix("lastcontact") && key != "lastContactTime" && value is String
            }?.value as? String
        }

        return JamfComputerRecord(
            id: item.id,
            udid: item.udid,
            managementID: item.general?.managementId,
            name: item.general?.name,
            lastContactTime: item.general?.lastCheckIn ?? item.general?.lastContactTime,
            lastContact: lastContact,
            lastEnrolledDate: item.general?.lastEnrolledDate,
            reportDate: item.general?.reportDate,
            mdmProfileExpiration: item.general?.mdmProfileExpiration ?? item.general?.mdmCertificateExpiration,
            siteID: item.general?.site?.id,
            siteName: item.general?.site?.name,
            encryption: item.diskEncryption.map {
                JamfDiskEncryption(
                    fileVaultEnabled: $0.fileVault2Enabled,
                    bootPartitionState: $0.bootPartitionEncryptionDetails?.partitionFileVault2State,
                    bootPartitionPercent: $0.bootPartitionEncryptionDetails?.partitionFileVault2Percent,
                    recoveryKeyValidity: $0.individualRecoveryKeyValidityStatus
                )
            }
        )
    }

    /// Looks up a mobile device (iPhone/iPad/Apple TV) record. The Classic API
    /// resolves the serial to a record ID; the modern detail endpoint provides
    /// the timestamps, including Last Contact (Jamf Pro 11.30+).
    func mobileDevice(serial: String) async throws -> JamfMobileDeviceRecord? {
        struct ClassicResponse: Decodable {
            let mobile_device: Device
            struct Device: Decodable { let general: General }
            struct General: Decodable {
                let id: Int
                let display_name: String?
                let udid: String?
                let last_inventory_update_epoch: Int64?
                let last_enrollment_epoch: Int64?
            }
        }
        let (data, status) = try await send(path: "/JSSResource/mobiledevices/serialnumber/\(serial)")
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let general = try JSONDecoder().decode(ClassicResponse.self, from: data).mobile_device.general

        struct Detail: Decodable {
            let name: String?
            let udid: String?
            let managementId: String?
            let lastInventoryUpdateTimestamp: String?
            let lastContactTimestamp: String?
            let lastEnrollmentTimestamp: String?
            let mdmProfileExpirationTimestamp: String?
            let site: Site?
            // The escrowed unlock token lives in the per-OS detail object.
            let ios: OSDetails?
            let tvos: OSDetails?
            let watchos: OSDetails?
            let visionos: OSDetails?
            struct Site: Decodable {
                let id: String?
                let name: String?
            }
            struct OSDetails: Decodable {
                let unlockToken: String?
                let security: Security?
            }
            struct Security: Decodable {
                let passcodePresent: Bool?
                let passcodeCompliant: Bool?
                let passcodeCompliantWithProfile: Bool?
                let hardwareEncryption: Int?
            }
            var unlockToken: String? {
                [ios, tvos, watchos, visionos].compactMap { $0?.unlockToken }.first { !$0.isEmpty }
            }
            /// The security block lives under whichever per-OS object applies.
            var security: Security? {
                [ios, tvos, watchos, visionos].compactMap { $0?.security }.first
            }
        }
        // Withheld from the activity log because the response carries the
        // escrowed unlock token, which an ordinary lookup would otherwise
        // record for every mobile device the user searches for.
        var detail: Detail?
        if let (detailData, detailStatus) = try? await send(
            path: "/api/v2/mobile-devices/\(general.id)/detail",
            withholdBodies: true
        ), (200...299).contains(detailStatus) {
            detail = try? JSONDecoder().decode(Detail.self, from: detailData)
        }

        return JamfMobileDeviceRecord(
            id: String(general.id),
            udid: detail?.udid ?? general.udid,
            managementID: detail?.managementId,
            name: detail?.name ?? general.display_name,
            lastEnrolledDate: detail?.lastEnrollmentTimestamp
                ?? DateFormatting.isoFromEpochMilliseconds(general.last_enrollment_epoch),
            lastInventoryDate: detail?.lastInventoryUpdateTimestamp
                ?? DateFormatting.isoFromEpochMilliseconds(general.last_inventory_update_epoch),
            lastContactTime: detail?.lastContactTimestamp,
            mdmProfileExpiration: detail?.mdmProfileExpirationTimestamp,
            siteID: detail?.site?.id,
            siteName: detail?.site?.name,
            unlockToken: detail?.unlockToken,
            security: detail?.security.map {
                JamfMobileSecurity(
                    passcodePresent: $0.passcodePresent,
                    passcodeCompliant: $0.passcodeCompliant,
                    passcodeCompliantWithProfile: $0.passcodeCompliantWithProfile,
                    hardwareEncryption: $0.hardwareEncryption
                )
            }
        )
    }

    func deleteMobileDevice(id: String) async throws {
        let (data, status) = try await send(path: "/JSSResource/mobiledevices/id/\(id)", method: "DELETE")
        try throwIfError(status: status, data: data)
    }

    // MARK: MDM commands

    /// Sends a Classic API mobile device command. Only UpdateInventory still
    /// goes through this route: Jamf Pro removed the security-sensitive
    /// commands from the Classic API (they return HTTP 400 now).
    func sendMobileDeviceCommand(_ command: String, deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/JSSResource/mobiledevicecommands/command/\(command)/id/\(deviceID)",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    /// Sends an MDM command through the modern /v2/mdm/commands endpoint,
    /// batched across the given management IDs.
    func sendModernCommand(commandData: [String: any Sendable], managementIDs: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "clientData": managementIDs.map { ["managementId": $0] },
            "commandData": commandData,
        ] as [String: Any])
        let (data, status) = try await send(path: "/api/v2/mdm/commands", method: "POST", body: body)
        try throwIfError(status: status, data: data)
    }

    /// Renews the MDM enrollment profile for the given device UDIDs.
    /// Returns the UDIDs Jamf Pro declined to renew. The endpoint answers 200
    /// even when it renewed nothing, listing the ones it skipped, so the status
    /// alone would report success wrongly.
    @discardableResult
    func renewMDMProfile(udids: [String]) async throws -> [String] {
        struct Response: Decodable {
            let udidsNotProcessed: Wrapper?
            struct Wrapper: Decodable { let udids: [String]? }
        }
        let body = try JSONSerialization.data(withJSONObject: ["udids": udids])
        let (data, status) = try await send(path: "/api/v1/mdm/renew-profile", method: "POST", body: body)
        try throwIfError(status: status, data: data)
        return (try? JSONDecoder().decode(Response.self, from: data))?.udidsNotProcessed?.udids ?? []
    }

    /// Queues a DeclarativeManagement sync command for the device, which is what the
    /// Jamf Pro UI's blank push shows in the management history. Requires the
    /// "Send Declarative Management Command" privilege.
    func ddmSync(managementID: String) async throws {
        let (data, status) = try await send(path: "/api/v1/ddm/\(managementID)/sync", method: "POST")
        try throwIfError(status: status, data: data)
    }

    /// Sends a blank push to the given management IDs. Returns the management
    /// IDs the server could not push to.
    func blankPush(managementIDs: [String]) async throws -> [String] {
        let body = try JSONSerialization.data(withJSONObject: ["clientManagementIds": managementIDs])
        let (data, status) = try await send(path: "/api/v2/mdm/blank-push", method: "POST", body: body)
        try throwIfError(status: status, data: data)
        struct Response: Decodable { let errorUuids: [String]? }
        return (try? JSONDecoder().decode(Response.self, from: data))?.errorUuids ?? []
    }

    /// Reinstalls the Jamf management framework (jamf binary) on a computer
    /// through an MDM InstallEnterpriseApplication command.
    func redeployFramework(computerID: String) async throws {
        let (data, status) = try await send(
            path: "/api/v1/jamf-management-framework/redeploy/\(computerID)",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    func deleteComputer(id: String) async throws {
        let (data, status) = try await send(path: "/api/v1/computers-inventory/\(id)", method: "DELETE")
        try throwIfError(status: status, data: data)
    }

    // MARK: PreStages

    func prestages(family: JamfPrestageFamily) async throws -> [JamfPrestage] {
        var lastError: Error?
        for version in family.listVersions {
            do {
                return try await prestageList(family: family, apiVersion: version)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(message: "Could not load PreStages.")
    }

    private func prestageList(family: JamfPrestageFamily, apiVersion: String) async throws -> [JamfPrestage] {
        struct Response: Decodable {
            let totalCount: Int
            let results: [Item]
            struct Item: Decodable {
                let id: String
                let displayName: String
                let deviceEnrollmentProgramInstanceId: String?
            }
        }
        var all: [JamfPrestage] = []
        var page = 0
        while true {
            let (data, status) = try await send(
                path: "/api/\(apiVersion)/\(family.pathComponent)",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: "100"),
                    URLQueryItem(name: "sort", value: "id:asc"),
                ]
            )
            try throwIfError(status: status, data: data)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            all += decoded.results.map {
                JamfPrestage(id: $0.id, displayName: $0.displayName, enrollmentInstanceID: $0.deviceEnrollmentProgramInstanceId)
            }
            if all.count >= decoded.totalCount || decoded.results.isEmpty { break }
            page += 1
        }
        return all
    }

    /// Maps serial number → device-enrollment (ADE) instance ID for every
    /// device synced through any of the server's ADE tokens. Used to filter
    /// PreStages to the ones a device can actually be scoped to.
    func adeInstanceBySerial() async throws -> [String: String] {
        struct ListResponse: Decodable {
            let totalCount: Int
            let results: [Item]
            struct Item: Decodable { let id: String }
        }
        struct DevicesResponse: Decodable {
            let totalCount: Int
            let results: [Item]
            struct Item: Decodable { let serialNumber: String? }
        }

        var instanceIDs: [String] = []
        var page = 0
        while true {
            let (data, status) = try await send(
                path: "/api/v1/device-enrollments",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: "100"),
                ]
            )
            try throwIfError(status: status, data: data)
            let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
            instanceIDs += decoded.results.map(\.id)
            if instanceIDs.count >= decoded.totalCount || decoded.results.isEmpty { break }
            page += 1
        }

        var map: [String: String] = [:]
        for instanceID in instanceIDs {
            var page = 0
            var seen = 0
            while true {
                let (data, status) = try await send(
                    path: "/api/v1/device-enrollments/\(instanceID)/devices",
                    queryItems: [
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "page-size", value: "500"),
                    ]
                )
                try throwIfError(status: status, data: data)
                let decoded = try JSONDecoder().decode(DevicesResponse.self, from: data)
                for item in decoded.results {
                    if let serial = item.serialNumber?.uppercased() { map[serial] = instanceID }
                }
                seen += decoded.results.count
                if seen >= decoded.totalCount || decoded.results.isEmpty { break }
                page += 1
            }
        }
        return map
    }

    /// Maps serial number → PreStage ID for every scoped device in the family.
    func prestageAssignments(family: JamfPrestageFamily) async throws -> [String: String] {
        struct Response: Decodable { let serialsByPrestageId: [String: String] }
        var lastError: Error?
        for version in family.scopeVersions {
            do {
                let (data, status) = try await send(path: "/api/\(version)/\(family.pathComponent)/scope")
                try throwIfError(status: status, data: data)
                return try JSONDecoder().decode(Response.self, from: data).serialsByPrestageId
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(message: "Could not load PreStage assignments.")
    }

    func addToPrestage(family: JamfPrestageFamily, prestageID: String, serials: [String]) async throws {
        try await changeScope(family: family, prestageID: prestageID, serials: serials, deleting: false)
    }

    func removeFromPrestage(family: JamfPrestageFamily, prestageID: String, serials: [String]) async throws {
        try await changeScope(family: family, prestageID: prestageID, serials: serials, deleting: true)
    }

    private func changeScope(family: JamfPrestageFamily, prestageID: String, serials: [String], deleting: Bool) async throws {
        struct ScopeResponse: Decodable { let versionLock: Int }
        var lastError: Error?
        for version in family.scopeVersions {
            let scopePath = "/api/\(version)/\(family.pathComponent)/\(prestageID)/scope"
            // Scope writes are optimistic-locked: read the current versionLock first.
            // A failure here means this API version isn't served, so try the next one.
            let versionLock: Int
            do {
                let (scopeData, scopeStatus) = try await send(path: scopePath)
                try throwIfError(status: scopeStatus, data: scopeData)
                versionLock = try JSONDecoder().decode(ScopeResponse.self, from: scopeData).versionLock
            } catch {
                lastError = error
                continue
            }

            let body = try JSONSerialization.data(withJSONObject: [
                "serialNumbers": serials,
                "versionLock": versionLock,
            ] as [String: Any])
            let (data, status) = try await send(
                path: deleting ? "\(scopePath)/delete-multiple" : scopePath,
                method: "POST",
                body: body
            )
            try throwIfError(status: status, data: data)
            return
        }
        throw lastError ?? APIError(message: "Could not update the PreStage scope.")
    }

    // MARK: Destructive per-device actions

    // Each takes the Jamf Pro record ID and has its own endpoint, rather than
    // going through the batched /v2/mdm/commands route the gateway withholds,
    // which is why these work over the Platform API.

    /// Erases a Mac. `pin` is the six digits needed to unlock it afterwards,
    /// and is the reason this call keeps its bodies out of the activity log.
    func eraseComputer(computerID: String, pin: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: pin.map { ["pin": $0] } ?? [:])
        let (data, status) = try await send(
            path: "/api/v4/computers-inventory/\(computerID)/erase",
            method: "POST",
            body: body,
            withholdBodies: true
        )
        try throwIfError(status: status, data: data)
    }

    func eraseMobileDevice(deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/api/v2/mobile-devices/\(deviceID)/erase",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: [:] as [String: Any])
        )
        try throwIfError(status: status, data: data)
    }

    /// Removes a Mac's MDM profile, which unmanages it. Jamf Pro names the
    /// mobile device equivalent differently; see `unmanageMobileDevice`.
    func removeMDMProfile(computerID: String) async throws {
        let (data, status) = try await send(
            path: "/api/v4/computers-inventory/\(computerID)/remove-mdm-profile",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    func unmanageMobileDevice(deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/api/v2/mobile-devices/\(deviceID)/unmanage",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    // MARK: Platform device actions

    // Restart and shut down live on Jamf's platform APIs rather than the Jamf
    // Pro passthrough, so they are reachable only through the gateway, and
    // only with an environment-scoped integration. Each platform API has its
    // own prefix, and the paths in Jamf's reference are relative to it: the
    // documented /v1/devices/{id}/restart is really /device-actions/v1/... .
    // They also address devices by platform UUID rather than Jamf Pro record
    // ID, hence the lookup below.

    /// Resolves a serial to the platform device UUID the actions below expect.
    /// Nil when the platform inventory does not know the serial.
    func platformDeviceID(serial: String) async throws -> String? {
        struct Response: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let id: String
                let serialNumber: String?
            }
        }
        let (data, status) = try await send(
            path: "/devices/v1/devices",
            queryItems: [URLQueryItem(name: "filter", value: "serialNumber==\"\(serial)\"")]
        )
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let results = try JSONDecoder().decode(Response.self, from: data).results ?? []
        // Match on the serial rather than trusting the first row. These IDs are
        // handed to restart and shut down, so a filter the server ignored must
        // not become an action against somebody else's device.
        guard let match = results.first(where: {
            $0.serialNumber?.caseInsensitiveCompare(serial) == .orderedSame
        }) else {
            if results.isEmpty { return nil }
            throw APIError(message: "The platform device inventory returned \(results.count) result(s) for \(serial), none with that serial number. No command was sent.")
        }
        return match.id
    }

    func platformRestart(deviceID: String) async throws {
        try await platformAction(deviceID: deviceID, path: "restart", verb: "restart")
    }

    func platformShutDown(deviceID: String) async throws {
        try await platformAction(deviceID: deviceID, path: "shutdown", verb: "shut down")
    }

    private func platformAction(deviceID: String, path: String, verb: String) async throws {
        let (data, status) = try await send(path: "/device-actions/v1/devices/\(deviceID)/\(path)", method: "POST")
        // 422 is Jamf's answer for a device it will not act on, which is worth
        // explaining rather than reporting as a bare status.
        if status == 422 {
            throw APIError(message: "Jamf Pro will not \(verb) this device. It may be unmanaged, personally owned, or running an OS version that does not support the command.")
        }
        try throwIfError(status: status, data: data)
    }

    // MARK: Recovery secrets

    /// A computer's FileVault personal recovery key. Requires the "View Disk
    /// Encryption Recovery Key" privilege, or `disk-encryption-recovery-key:read`
    /// through the Platform API gateway. Nil when Jamf Pro holds no key.
    func fileVaultRecoveryKey(computerID: String) async throws -> JamfFileVaultKey? {
        struct Response: Decodable {
            let personalRecoveryKey: String?
            let individualRecoveryKeyValidityStatus: String?
            let diskEncryptionConfigurationName: String?
        }
        let (data, status) = try await send(
            path: "/api/v4/computers-inventory/\(computerID)/filevault",
            withholdBodies: true
        )
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let key = decoded.personalRecoveryKey, !key.isEmpty else { return nil }
        return JamfFileVaultKey(
            personalRecoveryKey: key,
            validityStatus: decoded.individualRecoveryKeyValidityStatus,
            configurationName: decoded.diskEncryptionConfigurationName
        )
    }

    /// The PIN a Mac was locked with, needed to unlock it. Requires "View
    /// Computer Device Lock Pin", or `computer-device-lock-pin:read` through
    /// the gateway. Nil when the Mac has never been locked. Macs only: iOS and
    /// iPadOS lock with the owner's own passcode, so no PIN exists to hold.
    func deviceLockPIN(computerID: String) async throws -> String? {
        struct Response: Decodable { let pin: String? }
        let (data, status) = try await send(
            path: "/api/v4/computers-inventory/\(computerID)/view-device-lock-pin",
            withholdBodies: true
        )
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let pin = try JSONDecoder().decode(Response.self, from: data).pin
        return (pin?.isEmpty ?? true) ? nil : pin
    }

    /// A computer's Recovery Lock password, static or rotating. Requires the "View
    /// Recovery Lock" privilege, or `recovery-lock:read` through the gateway.
    /// Nil when no password is escrowed.
    func recoveryLockPassword(computerID: String) async throws -> String? {
        struct Response: Decodable { let recoveryLockPassword: String? }
        let (data, status) = try await send(
            path: "/api/v4/computers-inventory/\(computerID)/view-recovery-lock-password",
            withholdBodies: true
        )
        if status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let password = try JSONDecoder().decode(Response.self, from: data).recoveryLockPassword
        return (password?.isEmpty ?? true) ? nil : password
    }

    // MARK: Managed local administrator accounts

    // Jamf Pro's LAPS endpoints. A device can carry an account created by its
    // PreStage (source MDM), one created by the Jamf binary (source JMF),
    // both, or neither, and their usernames need not match, so the accounts
    // are always enumerated rather than assumed.

    /// The managed local administrator accounts Jamf Pro knows for a device.
    /// Requires the "View Local Admin Password" privilege; an empty list is
    /// returned when the privilege is missing, since the accounts are shown
    /// as part of an ordinary lookup and their absence is not an error.
    func localAdminAccounts(managementID: String) async throws -> [JamfLocalAdminAccount] {
        struct Response: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let username: String?
                let guid: String?
                let userSource: String?
            }
        }
        let (data, status) = try await send(path: "/api/v2/local-admin-password/\(managementID)/accounts")
        if status == 403 || status == 404 { return [] }
        try throwIfError(status: status, data: data)
        return (try JSONDecoder().decode(Response.self, from: data).results ?? []).compactMap {
            guard let username = $0.username, !username.isEmpty else { return nil }
            return JamfLocalAdminAccount(
                username: username,
                guid: $0.guid ?? "",
                source: $0.userSource ?? ""
            )
        }
    }

    /// The current password for a managed local administrator account.
    ///
    /// Viewing queues a rotation: the value stays valid for the instance's
    /// rotation time and is then replaced. The account GUID is used rather
    /// than the username alone, because Jamf Pro resolves a bare username to
    /// the MDM source when two accounts share one.
    ///
    /// Nil when Jamf Pro holds no password for the account. That case answers
    /// HTTP 400 with code NOT_FOUND rather than a 404.
    func localAdminPassword(managementID: String, account: JamfLocalAdminAccount) async throws -> String? {
        struct Response: Decodable { let password: String? }
        let path = account.guid.isEmpty
            ? "/api/v2/local-admin-password/\(managementID)/account/\(account.username)/password"
            : "/api/v2/local-admin-password/\(managementID)/account/\(account.username)/\(account.guid)/password"
        let (data, status) = try await send(path: path, withholdBodies: true)
        if status == 404 || (status == 400 && Self.isNotFound(data)) { return nil }
        try throwIfError(status: status, data: data)
        let password = try JSONDecoder().decode(Response.self, from: data).password
        return (password?.isEmpty ?? true) ? nil : password
    }

    /// How long after being viewed a password is rotated, in seconds. Nil when
    /// the setting cannot be read, in which case the caller says only that a
    /// rotation follows.
    func localAdminRotationTime() async throws -> Int? {
        struct Response: Decodable { let passwordRotationTime: Int? }
        let (data, status) = try await send(path: "/api/v2/local-admin-password/settings")
        guard (200...299).contains(status) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data).passwordRotationTime
    }

    /// Whether an error body carries the NOT_FOUND code Jamf Pro returns, with
    /// HTTP 400, for an account it holds no password for.
    private nonisolated static func isNotFound(_ data: Data) -> Bool {
        struct ErrorResponse: Decodable {
            let errors: [Item]?
            struct Item: Decodable { let code: String? }
        }
        let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        return parsed?.errors?.contains { $0.code == "NOT_FOUND" } ?? false
    }

    // MARK: Groups

    /// Every computer or mobile device group on the server, smart and static
    /// alike. Both kinds are listed together because either can be a useful
    /// source of serial numbers.
    func groups(kind: JamfGroupKind) async throws -> [JamfGroup] {
        struct Response: Decodable {
            let computer_groups: [Item]?
            let mobile_device_groups: [Item]?
            struct Item: Decodable {
                let id: Int
                let name: String?
                let is_smart: Bool?
            }
        }
        let (data, status) = try await send(path: "/JSSResource/\(kind.groupResource)")
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let items = decoded.computer_groups ?? decoded.mobile_device_groups ?? []
        return items.map {
            JamfGroup(
                id: String($0.id),
                name: $0.name ?? "Group \($0.id)",
                isSmart: $0.is_smart ?? false,
                kind: kind
            )
        }
    }

    /// The serial numbers of a group's members, in one request. Members
    /// without a serial, which Jamf Pro reports for records that never
    /// completed inventory, are left out.
    func groupSerials(_ group: JamfGroup) async throws -> [String] {
        struct Response: Decodable {
            let computer_group: Group?
            let mobile_device_group: Group?
            struct Group: Decodable {
                let computers: [Member]?
                let mobile_devices: [Member]?
            }
            struct Member: Decodable { let serial_number: String? }
        }
        let (data, status) = try await send(path: "/JSSResource/\(group.kind.groupResource)/id/\(group.id)")
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let container = decoded.computer_group ?? decoded.mobile_device_group
        let members = container?.computers ?? container?.mobile_devices ?? []
        var seen = Set<String>()
        return members
            .compactMap { $0.serial_number?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Software updates

    /// The device's software update state from its declarative status report.
    ///
    /// This is the only supported source: Apple has moved software updates to
    /// declarative management, and Jamf Pro's managed software update plans
    /// and per-product statuses are both deprecated. Needs nothing beyond the
    /// read privileges a lookup already uses.
    ///
    /// Nil when the device has sent no report, which is the answer for a
    /// device that is not declaratively managed.
    func softwareUpdateStatus(managementID: String) async throws -> JamfSoftwareUpdateStatus? {
        struct Response: Decodable {
            let statusItems: [Item]?
            struct Item: Decodable {
                let key: String?
                let value: String?
                let lastUpdateTime: String?
            }
        }
        let (data, status) = try await send(path: "/api/v1/ddm/\(managementID)/status-items")
        if status == 403 || status == 404 { return nil }
        try throwIfError(status: status, data: data)
        let items = try JSONDecoder().decode(Response.self, from: data).statusItems ?? []

        // Exact keys only. The report can also carry malformed leftovers such
        // as softwareupdate.pending-version.softwareupdate.target-local-date-time,
        // which must not be mistaken for the real value.
        var values: [String: (value: String?, reportedAt: Date?)] = [:]
        for item in items {
            guard let key = item.key else { continue }
            values[key] = (item.value, item.lastUpdateTime.flatMap(DateFormatting.parseDeviceLocal))
        }
        func text(_ key: String) -> String? {
            guard let value = values[key]?.value, !value.isEmpty else { return nil }
            return value
        }

        let result = JamfSoftwareUpdateStatus(
            installState: text("softwareupdate.install-state"),
            pendingOSVersion: text("softwareupdate.pending-version.os-version"),
            pendingBuildVersion: text("softwareupdate.pending-version.build-version"),
            deadline: text("softwareupdate.pending-version.target-local-date-time")
                .flatMap(DateFormatting.parseStatusItemDate),
            pendingReportedAt: values["softwareupdate.pending-version.os-version"]?.reportedAt,
            failureCount: text("softwareupdate.failure-reason.count").flatMap(Int.init),
            failureReason: text("softwareupdate.failure-reason.reason"),
            failureAt: text("softwareupdate.failure-reason.timestamp")
                .flatMap(DateFormatting.parseStatusItemDate),
            betaEnrollment: text("softwareupdate.beta-enrollment")
        )
        return result.isReported ? result : nil
    }

    // MARK: Sites

    /// All sites on the server. The full-access site is represented by
    /// Jamf with the ID "-1" and is not included in the response.
    func sites() async throws -> [JamfSite] {
        struct Item: Decodable {
            let id: String
            let name: String
        }
        struct Wrapped: Decodable { let results: [Item] }
        let (data, status) = try await send(path: "/api/v1/sites")
        try throwIfError(status: status, data: data)
        let items = (try? JSONDecoder().decode([Item].self, from: data))
            ?? (try? JSONDecoder().decode(Wrapped.self, from: data))?.results
            ?? []
        return items.map { JamfSite(id: $0.id, name: $0.name) }
    }

    /// Moves a computer to the given site ("-1" for none).
    func setComputerSite(computerID: String, siteID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["general": ["siteId": siteID]])
        let (data, status) = try await send(
            path: "/api/v1/computers-inventory-detail/\(computerID)",
            method: "PATCH",
            body: body
        )
        try throwIfError(status: status, data: data)
    }

    /// Moves a mobile device to the given site ("-1" for none).
    func setMobileDeviceSite(deviceID: String, siteID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["siteId": siteID])
        let (data, status) = try await send(
            path: "/api/v2/mobile-devices/\(deviceID)",
            method: "PATCH",
            body: body
        )
        try throwIfError(status: status, data: data)
    }

    /// Cheap connectivity/credentials check.
    func verify() async throws {
        _ = try await bearerToken()
    }

    // MARK: Plumbing

    /// The single point every Jamf Pro request goes through, and so the single
    /// point the activity log is fed from. Request headers are deliberately
    /// never recorded: nothing needs them, and leaving them out keeps the
    /// bearer token out of the log by construction rather than by filtering.
    ///
    /// `withholdBodies` drops both bodies, for the endpoints that carry a
    /// secret in either direction.
    private func send(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        withholdBodies: Bool = false
    ) async throws -> (Data, Int) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid Jamf Pro server URL")
        }
        components.path = authMethod == .platformGateway ? Self.gatewayPath(for: path) : path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError(message: "Invalid Jamf Pro request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authMethod == .platformGateway, !environmentID.isEmpty {
            request.setValue(environmentID, forHTTPHeaderField: "X-Environment-Id")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Logged with the query string, since a filter that the server ignored
        // is exactly the kind of thing a log has to be able to show.
        let loggedPath = [components.path, components.query].compactMap { $0 }.joined(separator: "?")
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log?.recordRequest(
                service: .jamfPro,
                connection: connectionName,
                method: method,
                path: loggedPath,
                status: status,
                duration: Date().timeIntervalSince(started),
                requestBody: body,
                responseBody: data,
                withholdBodies: withholdBodies
            )
            return (data, status)
        } catch {
            log?.recordFailure(
                service: .jamfPro,
                connection: connectionName,
                method: method,
                path: loggedPath,
                duration: Date().timeIntervalSince(started),
                message: error.localizedDescription
            )
            throw error
        }
    }

    /// Maps a Jamf Pro path onto the Platform API gateway, which fronts the
    /// Jamf Pro API under `/pro` and the Classic API under `/proclassic`. Both
    /// prefixes replace the product segment rather than prefixing it, so
    /// `/JSSResource/mobiledevices` becomes `/proclassic/mobiledevices`.
    /// Keeping `/JSSResource` in place returns 403.
    ///
    /// This prefix behaviour is described for users in `docs/platform-api.md`.
    nonisolated static func gatewayPath(for path: String) -> String {
        if path.hasPrefix("/api/") {
            return "/pro/" + path.dropFirst("/api/".count)
        }
        if path.hasPrefix("/JSSResource/") {
            return "/proclassic/" + path.dropFirst("/JSSResource/".count)
        }
        return path
    }

    private func throwIfError(status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        struct ErrorResponse: Decodable {
            let errors: [Item]?
            struct Item: Decodable {
                let code: String?
                let description: String?
            }
        }
        var detail = ""
        if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let first = parsed.errors?.first {
            detail = first.description ?? first.code ?? ""
        }
        throw APIError(message: "Jamf Pro: HTTP \(status)\(detail.isEmpty ? "" : " – \(detail)")")
    }

    // MARK: Auth

    private func bearerToken() async throws -> String {
        if let cachedToken, cachedToken.expiry > Date() { return cachedToken.value }
        // Sign-ins are recorded, but never their bodies: the request carries
        // the client secret or password, the response carries the token.
        do {
            let token = try await fetchToken()
            log?.recordSignIn(
                service: .jamfPro,
                connection: connectionName,
                summary: "Signed in with \(authMethod.label)",
                outcome: .succeeded
            )
            return token
        } catch {
            log?.recordSignIn(
                service: .jamfPro,
                connection: connectionName,
                summary: "Sign-in failed: \(error.localizedDescription)",
                outcome: .failed
            )
            throw error
        }
    }

    private func fetchToken() async throws -> String {
        switch authMethod {
        case .apiClient:
            return try await fetchOAuthToken()
        case .usernamePassword:
            return try await fetchBasicAuthToken()
        case .platformGateway:
            return try await fetchGatewayToken()
        }
    }

    private func fetchOAuthToken() async throws -> String {
        try await fetchClientCredentialsToken(
            url: baseURL.appending(path: "/api/oauth/token"),
            hint: "Check the API client ID and secret."
        )
    }

    /// Same client-credentials form and response fields as the Jamf Pro API
    /// client flow, so only the URL differs. Tokens are region-locked, hence
    /// the same regional host the requests go to.
    private func fetchGatewayToken() async throws -> String {
        try await fetchClientCredentialsToken(
            url: baseURL.appending(path: "/auth/token"),
            hint: "Check the Platform API client ID and secret, and that the region matches your environment."
        )
    }

    private func fetchClientCredentialsToken(url: URL, hint: String) async throws -> String {
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body([
            ("client_id", account),
            ("client_secret", secret),
            ("grant_type", "client_credentials"),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(message: "Jamf Pro sign-in failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). \(hint)")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = (token.access_token, Date().addingTimeInterval(TimeInterval(max(token.expires_in - 60, 60))))
        return token.access_token
    }

    private func fetchBasicAuthToken() async throws -> String {
        struct TokenResponse: Decodable {
            let token: String
            let expires: String?
        }
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/auth/token"))
        request.httpMethod = "POST"
        let credentials = Data("\(account):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(message: "Jamf Pro sign-in failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the username and password.")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = token.expires.flatMap(DateFormatting.parseISO)?.addingTimeInterval(-60)
            ?? Date().addingTimeInterval(15 * 60)
        cachedToken = (token.token, expiry)
        return token.token
    }
}
