import Foundation
import JTKit

// MARK: - Models

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
    let encryption: DiskEncryptionState?
    /// The installed OS, from inventory rather than the declarative report,
    /// which keeps whatever it last saw.
    let osVersion: String?
    let osBuild: String?
    /// User and location assignment. Departments and buildings are reported as
    /// identifiers, which the caller resolves against the server's lists.
    let departmentID: String?
    let buildingID: String?
    let room: String?
    let assetTag: String?
    /// How the record enrolled. The boolean is inventory's own flag; the
    /// method is its name for the flow, e.g. "PreStage enrollment".
    let enrolledViaADE: Bool?
    let enrollmentMethod: String?
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
    /// "-1" for no site. The list read reports the ID only; the caller
    /// resolves the name against the server's sites.
    let siteID: String?
    let security: MobileSecurityState?
    let osVersion: String?
    let osBuild: String?
    /// User and location assignment, as for a computer.
    let departmentID: String?
    let buildingID: String?
    let room: String?
    let assetTag: String?
    /// True when a PreStage enrolled the record, which is the only route to
    /// one. The method is then worded as Jamf Pro's detail page words it,
    /// e.g. "PreStage enrollment: [token] name (id)".
    let enrolledViaADE: Bool
    let enrollmentMethod: String?
}

/// The outcome of a batched read: the records found, keyed by uppercased
/// serial, and the serials whose request failed, with the reason. A serial
/// in neither was asked for and is not on the server.
struct JamfBatch<Record: Sendable>: Sendable {
    var records: [String: Record] = [:]
    var failures: [String: String] = [:]
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

/// A device's software update state, as it last reported it through
/// declarative device management. Jamf Pro's update plans and per-product
/// statuses are deprecated and not used.
///
/// **`install-state` is the state; everything beside it is detail or
/// history.** Apple defines it as the one scalar saying what the device is
/// doing: `none` means nothing is pending and the last update succeeded,
/// while `waiting`, `downloading`, `prepared`, `installing` and `failed` each
/// mean one is in flight.
///
/// `pending-version` and `failure-reason` are dictionaries in Apple's schema,
/// which Jamf flattens into dotted keys, so each arrives with a null value of
/// its own. They are containers rather than signals: read as "nothing is
/// pending", they would report that forever.
///
/// Their sub-keys are real but not self-describing. Apple empties
/// `os-version` and `build-version` and zeroes `failure-reason.count` once
/// nothing is pending, but Jamf keeps the last non-empty value it saw, so a
/// Mac that updated months ago still carries the version it was offered, the
/// deadline it was given, and a count from a resolved attempt.
struct JamfSoftwareUpdateStatus: Sendable {
    /// `softwareupdate.install-state`: none, waiting, downloading, prepared,
    /// installing or failed.
    let installState: String?
    /// `softwareupdate.install-reason.reason`. An array in Apple's schema,
    /// flattened by Jamf. `declaration` means a managed declaration forced the
    /// update; the rest say how the user reached it.
    let installReason: String?
    /// `.os-version` and `.build-version`: the version the device was last
    /// offered, which it may since have installed.
    let offeredOSVersion: String?
    let offeredBuildVersion: String?
    /// `.target-local-date-time`. Apple sends this only while an update is
    /// being enforced, so its presence is itself the signal.
    let deadline: Date?
    /// When the device last reported that offer.
    let offerReportedAt: Date?
    let failureCount: Int?
    let lastFailureReason: String?
    let lastFailureAt: Date?
    /// The beta programme the device is enrolled in. Apple sends an empty
    /// string when there is none, so nil here means either.
    let betaEnrollment: String?
    /// Whether the device reported its beta enrolment at all. Separates "not
    /// enrolled", which is worth stating, from "never said", which is not.
    let betaReported: Bool
    /// Whether the device reported any software update status at all.
    let isReported: Bool

    private var state: String { (installState ?? "").lowercased() }

    /// Anything other than `none` means an update is outstanding, including
    /// one that is currently failing.
    var hasPendingUpdate: Bool {
        !state.isEmpty && state != "none"
    }

    /// The device is actively working on the update rather than stalled on it.
    var isInstalling: Bool {
        hasPendingUpdate && state != "failed"
    }

    /// The device reports the update itself as failed, as opposed to being
    /// mid-attempt with failures behind it.
    var isFailedState: Bool { state == "failed" }

    /// The device is failing to install the update it has now.
    ///
    /// Either it says so outright, or it has an update outstanding and a
    /// non-zero failure count: Apple defines that count as failures of the
    /// *current* update, so while something is pending those failures are
    /// about it. A Mac can sit at `prepared` and retry the install a hundred
    /// times, and calling that history would bury the only sign of it.
    var hasCurrentFailure: Bool {
        state == "failed" || (hasPendingUpdate && (failureCount ?? 0) > 0)
    }

    /// A failure the report still remembers from an attempt that is no longer
    /// current. With nothing pending, Apple's definition says the count should
    /// be zero, so a non-zero one is a leftover: worth showing, as history.
    var hasPastFailure: Bool {
        !hasCurrentFailure && (failureCount ?? 0) > 0 && lastFailureAt != nil
    }

    /// Whether the update is being enforced rather than left to the user.
    /// Apple signals this two ways and either is enough.
    var isEnforced: Bool {
        deadline != nil || (installReason ?? "").lowercased().contains("declaration")
    }

    /// Apple's states, in prose. Unknown values are sentence-cased rather than
    /// dropped, so a state added later still shows something truthful.
    var displayState: String {
        switch state {
        case "", "none": "No pending update"
        case "waiting": "Waiting to start"
        case "downloading": "Downloading"
        case "prepared": "Ready to install"
        case "installing": "Installing"
        case "failed": "Update failed"
        default: DisplayText.sentenceCase(state)
        }
    }

    /// The beta programme, or that there is none. Nil only when the device
    /// has not reported either way.
    ///
    /// Unlike the version and the deadline, this is not stale: Apple requires
    /// the key on every report, so what it last said is what is true now.
    var betaDisplay: String? {
        if let betaEnrollment, !betaEnrollment.isEmpty { return betaEnrollment }
        return betaReported ? "Not enrolled" : nil
    }

    var isInBetaProgram: Bool {
        !(betaEnrollment ?? "").isEmpty
    }

    /// The failure in one readable sentence.
    ///
    /// macOS reports these as a whole `NSError` description — domain, code,
    /// debug text and localised text, several hundred characters of it. The
    /// sentence worth showing is the localised one, which macOS has already
    /// written for a person and in their language; the rest belongs in a
    /// tooltip. Anything that is already a plain sentence passes through.
    var failureSummary: String? {
        guard let raw = lastFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let sentence = Self.localizedDescription(in: raw) else { return raw }
        guard let code = Self.errorCode(in: raw) else { return sentence }
        return "\(sentence) (\(code))"
    }

    /// The value of `NSLocalizedDescription`, which ends where the next
    /// `UserInfo` field or the enclosing brace begins.
    ///
    /// Stopping at the brace alone is not enough: these errors nest, and a
    /// field after the sentence carries the scan into the inner error's text.
    /// The sentence itself contains commas, so only a comma that starts
    /// another field ends it.
    private static func localizedDescription(in raw: String) -> String? {
        guard let start = raw.range(of: "NSLocalizedDescription=") else { return nil }
        let rest = raw[start.upperBound...]
        var end = rest.endIndex
        var index = rest.startIndex
        while index < rest.endIndex {
            if rest[index] == "}" {
                end = index
                break
            }
            if rest[index] == ",", beginsField(rest[rest.index(after: index)...]) {
                end = index
                break
            }
            index = rest.index(after: index)
        }
        let sentence = rest[rest.startIndex..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    /// Whether the text opens a new `Identifier=` field.
    private static func beginsField(_ text: Substring) -> Bool {
        var index = text.startIndex
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex, text[index].isLetter else { return false }
        var scan = index
        while scan < text.endIndex, text[scan].isLetter || text[scan].isNumber {
            scan = text.index(after: scan)
        }
        return scan < text.endIndex && text[scan] == "="
    }

    /// The numeric code, kept because it is the handle for looking a failure
    /// up: 7507 is the software update lock being held elsewhere.
    private static func errorCode(in raw: String) -> String? {
        guard let start = raw.range(of: "Code=") else { return nil }
        let digits = raw[start.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : "error \(digits)"
    }

    /// The pending version with its build. Nil unless something is actually
    /// pending, so a version the device has already installed is never shown
    /// as one still due.
    var pendingVersion: String? {
        guard hasPendingUpdate, let version = offeredOSVersion, !version.isEmpty else { return nil }
        guard let build = offeredBuildVersion, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

/// Whether the device accepted a declaration.
nonisolated enum JamfDeclarationValidity: String, Sendable {
    case valid
    case invalid
    case unknown
}

/// One declaration as the device reports it in `management.declarations`.
///
/// This is the device's own verdict, not the server's intent, which is what
/// makes it worth reading: Jamf Pro reports a blueprint as deployed once it
/// has delivered the declaration, while the device says whether it could
/// actually be applied.
struct JamfDeclaration: Sendable, Identifiable {
    let identifier: String
    let active: Bool
    let validity: JamfDeclarationValidity
    /// The device's failure text, kept verbatim. Apple words these better
    /// than any paraphrase, and they name the offending version.
    let reasons: [String]

    var id: String { identifier }

    /// The blueprint this came from, when Jamf built the identifier from one.
    /// They are shaped `Blueprint_<uuid>_s1_c1_sys_cfg1`.
    var blueprintID: String? {
        let prefix = "Blueprint_"
        guard identifier.hasPrefix(prefix) else { return nil }
        let candidate = identifier.dropFirst(prefix.count).prefix(36)
        return UUID(uuidString: String(candidate)) == nil ? nil : String(candidate)
    }

    /// Whether the failure text names a target OS version.
    ///
    /// A guess from the device's wording, used only until the declaration
    /// itself has been read back, which settles it by type. It holds for the
    /// rejection that matters — a target the device has already passed — and
    /// costs nothing when it does not.
    var concernsUpdateEnforcement: Bool {
        reasons.contains { $0.localizedCaseInsensitiveContains("target OS version") }
    }
}

/// A software update enforcement declaration as the server holds it.
///
/// Apple defines no "latest version" declaration: only
/// `com.apple.configuration.softwareupdate.enforcement.specific`, carrying a
/// concrete version and install-by date. A management service offering
/// "enforce the latest" resolves it to one of these and is responsible for
/// re-issuing it as versions ship, so reading the target back is the only way
/// to see what a device is actually being held to.
struct JamfUpdateEnforcement: Sendable {
    let declarationID: String
    let targetOSVersion: String?
    let targetBuildVersion: String?
    let targetLocalDateTime: Date?

    /// The target with its build, as the software update row shows versions.
    var targetVersion: String? {
        guard let targetOSVersion, !targetOSVersion.isEmpty else { return nil }
        guard let targetBuildVersion, !targetBuildVersion.isEmpty else { return targetOSVersion }
        return "\(targetOSVersion) (\(targetBuildVersion))"
    }

    /// Whether the device already runs what it is being held to.
    ///
    /// Without this, an enforced target and a date in the past read as a
    /// missed deadline whether the device complied or not — and a satisfied
    /// declaration is the common case, since a service that re-issues these
    /// leaves the old one behind once it succeeds.
    func isSatisfied(byOSVersion installed: String?, build: String?) -> Bool {
        guard let target = targetOSVersion, !target.isEmpty else { return false }
        // A build match is exact; nothing else needs checking.
        if let targetBuildVersion, !targetBuildVersion.isEmpty,
           let build, !build.isEmpty, targetBuildVersion == build {
            return true
        }
        guard let installed, !installed.isEmpty else { return false }
        // Numeric comparison, so 26.10 sorts above 26.9 rather than below it.
        return installed.compare(target, options: .numeric) != .orderedAscending
    }

    /// Whether reaching the target means crossing to another major release,
    /// which many organizations enforce separately from minor updates.
    func isMajorUpgrade(fromOSVersion installed: String?) -> Bool {
        guard let target = targetOSVersion?.split(separator: ".").first,
              let current = installed?.split(separator: ".").first else { return false }
        return target != current
    }
}

/// Everything one declarative status report says, from a single request.
struct JamfDDMStatus: Sendable {
    let softwareUpdate: JamfSoftwareUpdateStatus?
    /// Configuration declarations, as the device reports them.
    let declarations: [JamfDeclaration]
    /// The newest report time across every status item, which is how stale
    /// the whole picture is.
    let reportedAt: Date?

    var invalidDeclarations: [JamfDeclaration] {
        declarations.filter { $0.validity == .invalid }
    }

    var activeDeclarations: [JamfDeclaration] {
        declarations.filter { $0.active && $0.validity != .invalid }
    }

    /// Declarations the device holds but has not put into effect, almost
    /// always because their activation failed. They are neither active nor
    /// rejected, so counting only those two hides them — and on a device
    /// where an activation has broken, they can be nearly all of them.
    var notAppliedDeclarations: [JamfDeclaration] {
        declarations.filter { !$0.active && $0.validity != .invalid }
    }

    /// The invalid declaration that concerns software update enforcement, if
    /// any. This is the one worth calling out: while it is rejected, nothing
    /// is enforcing updates on the device however the server reports it.
    var rejectedUpdateEnforcement: JamfDeclaration? {
        invalidDeclarations.first { $0.concernsUpdateEnforcement }
    }

    /// Declarations worth asking the server about, most useful first.
    ///
    /// The status report gives identifiers and verdicts but not payloads, so
    /// the enforced version has to be fetched. Rejected ones come first
    /// because they matter most; the list is capped because a device can hold
    /// two dozen and only one of them enforces software updates.
    ///
    /// Blueprint components are left out. Jamf Pro answers `500` with an
    /// empty error list for every `Blueprint_…` identifier, so asking costs a
    /// request per declaration and returns nothing. A blueprint-driven
    /// enforcement that the device has *rejected* is still reported, since
    /// that comes from the status report rather than from this lookup.
    func declarationsWorthResolving(limit: Int = 8) -> [JamfDeclaration] {
        let resolvable = declarations.filter { $0.blueprintID == nil }
        let ordered = resolvable.filter { $0.validity == .invalid }
            + resolvable.filter { $0.validity != .invalid }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.identifier).inserted }.prefix(limit).map { $0 }
    }
}

nonisolated enum DisplayText {
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
    /// Nil for Jamf School, which keeps one list of device groups rather than
    /// splitting them by device kind.
    let kind: JamfGroupKind?
    /// Member count, when the service reports one without being asked. Jamf
    /// Pro does not; Jamf School does.
    let memberCount: Int?

    init(id: String, name: String, isSmart: Bool, kind: JamfGroupKind?, memberCount: Int? = nil) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.kind = kind
        self.memberCount = memberCount
    }

    var typeLabel: String { isSmart ? "Smart" : "Static" }
}

/// Device compliance as the Device Compliance integration reports it.
///
/// Jamf Pro's own term. The vendor is carried because Jamf Pro does not
/// evaluate compliance itself — it relays a verdict, and knowing whose it is
/// matters when that verdict is not what an administrator expects.
nonisolated struct JamfDeviceCompliance: Sendable {
    /// False when the device is outside the integration's scope, which is not
    /// the same as being non-compliant.
    let applicable: Bool
    /// `COMPLIANT`, `NON_COMPLIANT` or `UNKNOWN`.
    let state: String?
    let vendor: String?

    /// The verdict worded for display, or nil when there is nothing to show.
    var summary: String? {
        guard applicable else { return nil }
        switch state {
        case "COMPLIANT": return "Compliant"
        case "NON_COMPLIANT": return "Not compliant"
        case "UNKNOWN", nil: return "Unknown"
        default: return DisplayText.sentenceCase(state ?? "")
        }
    }
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

/// The two PreStage families in Jamf Pro. Both list at v3 and scope at v2.
nonisolated enum JamfPrestageFamily: Sendable {
    case computer
    case mobileDevice

    var pathComponent: String {
        switch self {
        case .computer: "computer-prestages"
        case .mobileDevice: "mobile-device-prestages"
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

/// Client for the Jamf Pro API, connected directly or through the Platform
/// API gateway. Authenticates with an API client (OAuth client credentials),
/// a username and password (bearer token), or a gateway integration.
///
/// Runs on JTKit's `JamfPlatform.Client` (ROADMAP step 7): its sign-in, the
/// shared retry rules, JTKit's error format with the Trace ID and the hints
/// (a refused request names the missing privilege), and an activity log entry
/// for every attempt. The lookups, asset tags, MDM commands, record deletes,
/// Platform API device calls and Classic groups are JTKit's; the other reads
/// and writes below are Checkpoint's own until they move in JTKit 0.8.2.
actor JamfClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let authMethod: MDMAuthMethod
    /// Refuses every MDM command under tests (a second check after the model's).
    private let commandGuard: ActionGuard
    /// JTKit's client, or why the connection can't make one (e.g. an
    /// Environment ID that isn't a UUID), thrown at the first request.
    private let client: Result<JamfPlatform.Client, JamfPlatform.APIError>

    /// - Parameters:
    ///   - secret: the client secret or password, read at each sign-in.
    ///   - log: where requests are recorded; nil records nothing.
    ///   - session: replaced in tests.
    init?(config: MDMConnection, secret: @escaping @Sendable () throws -> String,
          log: ActivityLog? = nil, session: URLSession = .shared, commandGuard: ActionGuard = .off) {
        // An Entra app registration can't sign in to Jamf Pro; the editor
        // offers it only for Intune.
        guard config.authMethod != .entraApp,
              let url = URL(string: config.apiBaseURL), url.host() != nil else { return nil }
        let recorder = RequestRecorder(session: session, log: log,
                                       service: ActivityService.jamfPro.rawValue, connection: config.displayName)
        authMethod = config.authMethod
        self.commandGuard = commandGuard
        do {
            client = .success(try JamfPlatform.Client(connection: config.connection, secret: secret, recorder: recorder))
        } catch let error as JamfPlatform.APIError {
            client = .failure(error)
        } catch {
            client = .failure(JamfPlatform.APIError(.invalidResponse(error.localizedDescription)))
        }
    }

    private func jamf() throws -> JamfPlatform.Client {
        try client.get()
    }

    /// Drops the token, so the next request signs in again with the secret
    /// saved now. Called when the connection or its secret is edited.
    func forgetToken() async {
        if case .success(let client) = client { await client.forgetToken() }
    }

    /// Signs in, for Test Connection. A refusal shows JTKit's hint: on a
    /// direct server without the region, on the Platform API with it.
    func verify() async throws {
        try await jamf().signIn()
    }

    // MARK: Device records

    /// The sections a lookup asks for. DISK_ENCRYPTION reports FileVault
    /// state without the recovery key, so the read stays within Read
    /// Computers; USER_AND_LOCATION is hidden whole in the activity log.
    static let computerSections: [JamfPro.InventorySection] = [.general, .hardware, .diskEncryption, .operatingSystem, .userAndLocation]
    static let mobileDeviceSections: [JamfPro.InventorySection] = [.general, .hardware, .security, .userAndLocation]

    /// The computer records for these serials: JTKit's batches of fifty, one
    /// serial at a time when the filter is refused. Their answers are
    /// recorded, trimmed to the sections asked for (ROADMAP step 5).
    func computers(serials: [String]) async -> JamfBatch<JamfComputerRecord> {
        await batch(serials) {
            try await $0.computers(serials: serials, sections: Self.computerSections, recording: .results)
        } map: { Self.record($0) }
    }

    /// The mobile device records for these serials. The list read carries
    /// everything a lookup shows except the escrowed unlock token, which
    /// Clear Passcode reads for the devices it is sent to.
    func mobileDevices(serials: [String]) async -> JamfBatch<JamfMobileDeviceRecord> {
        await batch(serials) {
            try await $0.mobileDevices(serials: serials, sections: Self.mobileDeviceSections, recording: .results)
        } map: { Self.record($0) }
    }

    private func batch<Found: Sendable, Record: Sendable>(
        _ serials: [String],
        read: (JamfPlatform.Client) async throws -> JamfPro.Batch<Found>,
        map: (Found) -> Record?
    ) async -> JamfBatch<Record> {
        do {
            let found = try await read(jamf())
            return JamfBatch(records: found.records.compactMapValues(map),
                             failures: found.failures.mapValues(\.localizedDescription))
        } catch {
            // No sign-in at all (no secret, an unusable Environment ID): every
            // serial failed, so none reads as absent.
            let keys = Set(serials.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })
            return JamfBatch(failures: Dictionary(uniqueKeysWithValues: keys.map { ($0, error.localizedDescription) }))
        }
    }

    private static func iso(_ date: Date?) -> String? {
        date?.ISO8601Format()
    }

    private static func record(_ computer: JamfPro.Computer) -> JamfComputerRecord? {
        guard let id = computer.id else { return nil }
        let general = computer.general
        return JamfComputerRecord(
            id: id,
            udid: computer.udid,
            managementID: general?.managementID,
            name: general?.name,
            lastContactTime: iso(general?.lastCheckIn),
            lastContact: iso(general?.lastContact),
            lastEnrolledDate: iso(general?.lastEnrolledDate),
            reportDate: iso(general?.reportDate),
            mdmProfileExpiration: iso(general?.mdmProfileExpiration),
            siteID: general?.site?.id,
            siteName: general?.site?.name,
            encryption: computer.diskEncryption.map {
                DiskEncryptionState(
                    fileVaultEnabled: $0.fileVault2Enabled,
                    bootPartitionState: $0.bootPartitionFileVault2State,
                    bootPartitionPercent: $0.bootPartitionFileVault2Percent,
                    recoveryKeyValidity: $0.individualRecoveryKeyValidityStatus
                )
            },
            osVersion: computer.operatingSystem?.version,
            osBuild: computer.operatingSystem?.build,
            departmentID: computer.userAndLocation?.departmentID,
            buildingID: computer.userAndLocation?.buildingID,
            room: computer.userAndLocation?.room,
            assetTag: general?.assetTag,
            enrolledViaADE: general?.enrolledViaAutomatedDeviceEnrollment,
            enrollmentMethod: general?.enrollmentMethod?.objectType
        )
    }

    private static func record(_ device: JamfPro.MobileDevice) -> JamfMobileDeviceRecord? {
        guard let id = device.id else { return nil }
        let general = device.general
        let prestage = general?.enrollmentPreStageID ?? general?.enrollmentPreStageName
        return JamfMobileDeviceRecord(
            id: id,
            udid: device.udid,
            managementID: general?.managementID,
            name: general?.displayName,
            lastEnrolledDate: iso(general?.lastEnrolledDate),
            lastInventoryDate: iso(general?.lastInventoryUpdateDate),
            lastContactTime: iso(general?.lastContactDate),
            mdmProfileExpiration: iso(general?.mdmProfileExpirationDate),
            siteID: general?.siteID ?? "-1",
            security: device.security.map {
                MobileSecurityState(
                    passcodePresent: $0.passcodePresent,
                    passcodeCompliant: $0.passcodeCompliant,
                    passcodeCompliantWithProfile: $0.passcodeCompliantWithProfile,
                    hardwareEncryption: $0.hardwareEncryption
                )
            },
            osVersion: general?.osVersion,
            osBuild: general?.osBuild,
            departmentID: device.userAndLocation?.departmentID,
            buildingID: device.userAndLocation?.buildingID,
            room: device.userAndLocation?.room,
            assetTag: general?.assetTag,
            enrolledViaADE: prestage != nil,
            enrollmentMethod: prestage.map { _ in
                "PreStage enrollment: \(general?.enrollmentPreStageName ?? "") (\(general?.enrollmentPreStageID ?? ""))"
            }
        )
    }

    // MARK: Commands and record deletes (JTKit)

    /// Sends an MDM command; JTKit routes it, per device. The approval (with
    /// the PIN of Lock and Wipe Computer) comes from the confirmation.
    func send(_ command: MDMCommand, to targets: [MDMCommand.Target],
              approval: MDMCommand.Confirmation.Approval?) async throws -> MDMCommand.Result {
        try commandGuard.check("\(command.title) (Jamf Pro client), \(targets.count) device(s)")
        return try await jamf().send(command, to: targets, approval: approval)
    }

    /// Where the requests go, which decides how Restart and Shut Down are sent.
    var overPlatformAPI: Bool { authMethod == .platformGateway }

    func deleteComputer(id: String) async throws {
        try await jamf().deleteComputer(id: id)
    }

    func deleteMobileDevice(id: String) async throws {
        try await jamf().deleteMobileDevice(id: id)
    }

    // MARK: Asset tags (JTKit)

    func setComputerAssetTag(computerID: String, assetTag: String) async throws {
        try await jamf().setAssetTag(assetTag, computerID: computerID)
    }

    func setMobileDeviceAssetTag(deviceID: String, assetTag: String) async throws {
        try await jamf().setAssetTag(assetTag, mobileDeviceID: deviceID)
    }

    // MARK: Platform API devices (JTKit)

    /// The platform device UUID for a serial, nil when the inventory doesn't
    /// know it; refused when devices come back but none has the serial.
    func platformDeviceID(serial: String) async throws -> String? {
        try await jamf().device(serial: serial)?.id
    }

    /// Declarations from the platform's reporting API, typed JSON instead of
    /// the flattened status item. Gateway connections only; nil when the
    /// platform can't answer, so the caller keeps the declarations parsed
    /// out of the status report.
    func platformDeclarations(serial: String) async throws -> [JamfDeclaration]? {
        guard authMethod == .platformGateway, let deviceID = try await platformDeviceID(serial: serial),
              let declarations = try await jamf().declarations(deviceID: deviceID) else { return nil }
        return declarations.map {
            JamfDeclaration(identifier: $0.identifier, active: $0.active,
                            validity: JamfDeclarationValidity(rawValue: $0.validity) ?? .unknown, reasons: $0.reasons)
        }
    }

    // MARK: Groups (JTKit's Classic API)

    /// Every computer or mobile device group on the server, smart and static.
    func groups(kind: JamfGroupKind) async throws -> [JamfGroup] {
        try await jamf().classicGroups(kind.classic).map {
            JamfGroup(id: $0.id, name: $0.name, isSmart: $0.isSmart, kind: kind)
        }
    }

    /// The serial numbers of a group's members, in one request. Members
    /// without a serial (records that never completed inventory) are left out.
    func groupSerials(_ group: JamfGroup) async throws -> [String] {
        guard let kind = group.kind else {
            throw APIError(message: "\(group.name) is not a Jamf Pro group.")
        }
        let members = try await jamf().classicGroupMembers(
            JamfClassic.Group(id: group.id, name: group.name, isSmart: group.isSmart, kind: kind.classic))
        var seen = Set<String>()
        return members
            .compactMap { $0.serialNumber?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: PreStages (JTKit)

    func prestages(family: JamfPrestageFamily) async throws -> [JamfPrestage] {
        try await jamf().preStages(family.jtkit).map {
            JamfPrestage(id: $0.id, displayName: $0.displayName, enrollmentInstanceID: $0.enrollmentInstanceID)
        }
    }

    /// Serial number → PreStage ID for every scoped device in the family.
    func prestageAssignments(family: JamfPrestageFamily) async throws -> [String: String] {
        try await jamf().preStageScope(family.jtkit)
    }

    func addToPrestage(family: JamfPrestageFamily, prestageID: String, serials: [String]) async throws {
        try await jamf().addToPreStage(family.jtkit, id: prestageID, serials: serials)
    }

    func removeFromPrestage(family: JamfPrestageFamily, prestageID: String, serials: [String]) async throws {
        try await jamf().removeFromPreStage(family.jtkit, id: prestageID, serials: serials)
    }

    // MARK: Device compliance (JTKit)

    /// Whether the Device Compliance integration is on. It needs its own
    /// privilege, so a failure isn't read as "off": the caller falls through
    /// to the per-device read.
    func deviceComplianceEnabled() async throws -> Bool {
        try await jamf().deviceComplianceEnabled()
    }

    /// Compliance for one device, as the compliance vendor last reported it.
    func deviceCompliance(kind: DeviceKind, deviceID: String) async throws -> JamfDeviceCompliance? {
        try await jamf().deviceCompliance(kind.commandKind, id: deviceID).map {
            JamfDeviceCompliance(applicable: $0.applicable, state: $0.state, vendor: $0.vendor)
        }
    }

    // MARK: Automated Device Enrollment (JTKit)

    /// The Apple service identity of every ADE token, which links a
    /// connection to Apple's assignment without any configuration.
    func adeServerUUIDs() async throws -> Set<String> {
        try await jamf().deviceEnrollmentServerIDs()
    }

    /// Serial number → ADE instance ID, to filter PreStages to the ones a
    /// device can join.
    func adeInstanceBySerial() async throws -> [String: String] {
        try await jamf().deviceEnrollmentInstanceBySerial()
    }

    // MARK: Recovery secrets (JTKit)

    // Recorded without contents; a failure carries only the status.

    func fileVaultRecoveryKey(computerID: String) async throws -> JamfFileVaultKey? {
        try await jamf().fileVaultKey(computerID: computerID).map {
            JamfFileVaultKey(personalRecoveryKey: $0.personalRecoveryKey, validityStatus: $0.validityStatus,
                             configurationName: $0.configurationName)
        }
    }

    func deviceLockPIN(computerID: String) async throws -> String? {
        try await jamf().deviceLockPIN(computerID: computerID)
    }

    func recoveryLockPassword(computerID: String) async throws -> String? {
        try await jamf().recoveryLockPassword(computerID: computerID)
    }

    // MARK: Managed local administrator accounts (JTKit)

    /// Empty without the privilege: the accounts are part of an ordinary
    /// lookup, and their absence is no error.
    func localAdminAccounts(managementID: String) async throws -> [JamfLocalAdminAccount] {
        try await jamf().localAdminAccounts(managementID: managementID).map {
            JamfLocalAdminAccount(username: $0.username, guid: $0.guid, source: $0.source)
        }
    }

    /// Viewing queues a rotation: ask first (`JamfPro.Secret.localAdminPassword`).
    func localAdminPassword(managementID: String, account: JamfLocalAdminAccount) async throws -> String? {
        try await jamf().localAdminPassword(managementID: managementID,
                                            account: JamfPro.LocalAdminAccount(username: account.username, guid: account.guid, source: account.source))
    }

    func localAdminRotationTime() async throws -> Int? {
        await (try jamf()).localAdminRotationTime()
    }

    // MARK: Declarative status (JTKit's reads, Checkpoint's reading of them)

    /// What the device last reported declaratively: its software update state
    /// and the declarations it processed, from one report. Nil when the device
    /// sent none (not declaratively managed) or it can't be read here.
    func ddmStatus(managementID: String, kind: DeviceKind = .computer) async throws -> JamfDDMStatus? {
        guard let items = try await jamf().ddmStatusItems(managementID: managementID, kind: kind.commandKind),
              !items.isEmpty else { return nil }
        // Exact keys only. The report can also carry malformed leftovers such
        // as softwareupdate.pending-version.softwareupdate.target-local-date-time,
        // which must not be mistaken for the real value.
        var values: [String: (value: String?, reportedAt: Date?)] = [:]
        for item in items {
            values[item.key] = (item.value, item.lastUpdateTime.flatMap(DateFormatting.parseDeviceLocal))
        }
        func text(_ key: String) -> String? {
            guard let value = values[key]?.value, !value.isEmpty else { return nil }
            return value
        }
        let declarations = JamfPro.flattenedDeclarations(values["management.declarations.configurations"]?.value).map {
            JamfDeclaration(identifier: $0.identifier, active: $0.active,
                            validity: JamfDeclarationValidity(rawValue: $0.validity) ?? .unknown, reasons: $0.reasons)
        }
        let newestReport = values.values.compactMap(\.reportedAt).max()
        return JamfDDMStatus(softwareUpdate: softwareUpdate(values: values, text: text),
                             declarations: declarations, reportedAt: newestReport)
    }

    /// The software update half of a status report, or nil when the device
    /// reported none of those keys.
    private func softwareUpdate(
        values: [String: (value: String?, reportedAt: Date?)],
        text: (String) -> String?
    ) -> JamfSoftwareUpdateStatus? {
        guard values.keys.contains(where: { $0.hasPrefix("softwareupdate.") }) else { return nil }

        // The deadline belongs to the offer beside it. Jamf keeps whichever
        // value it last saw, so a deadline recorded before the current offer
        // was reported is a leftover from an earlier enforcement.
        let offerReportedAt = values["softwareupdate.pending-version.os-version"]?.reportedAt
        let deadlineReportedAt = values["softwareupdate.pending-version.target-local-date-time"]?.reportedAt
        let deadlineIsCurrent: Bool = {
            guard let offerReportedAt, let deadlineReportedAt else { return true }
            return deadlineReportedAt >= offerReportedAt
        }()

        return JamfSoftwareUpdateStatus(
            // The one scalar that says what the device is doing; Jamf
            // flattens the two dictionaries, so they always arrive null.
            installState: text("softwareupdate.install-state"),
            installReason: text("softwareupdate.install-reason.reason"),
            offeredOSVersion: text("softwareupdate.pending-version.os-version"),
            offeredBuildVersion: text("softwareupdate.pending-version.build-version"),
            deadline: deadlineIsCurrent
                ? text("softwareupdate.pending-version.target-local-date-time").flatMap(DateFormatting.parseStatusItemDate)
                : nil,
            offerReportedAt: offerReportedAt,
            failureCount: text("softwareupdate.failure-reason.count").flatMap(Int.init),
            lastFailureReason: text("softwareupdate.failure-reason.reason"),
            lastFailureAt: text("softwareupdate.failure-reason.timestamp").flatMap(DateFormatting.parseStatusItemDate),
            betaEnrollment: text("softwareupdate.beta-enrollment"),
            // Presence, not value: Apple sends an empty string for a device
            // in no beta programme.
            betaReported: values.keys.contains("softwareupdate.beta-enrollment"),
            isReported: true
        )
    }

    /// The software update enforcement declaration among those given, or nil.
    /// Nothing here throws: a declaration the server won't hand over is
    /// skipped rather than failing the row.
    func updateEnforcement(among declarations: [JamfDeclaration], kind: DeviceKind = .computer) async -> JamfUpdateEnforcement? {
        for declaration in declarations {
            if let found = ((try? await updateEnforcement(declarationID: declaration.identifier, kind: kind)) ?? nil) {
                return found
            }
        }
        return nil
    }

    /// Reads one declaration, returning it only if it enforces a software update.
    private func updateEnforcement(declarationID: String, kind: DeviceKind) async throws -> JamfUpdateEnforcement? {
        struct Payload: Decodable {
            let TargetOSVersion: String?
            let TargetBuildVersion: String?
            let TargetLocalDateTime: String?
        }
        guard let details = try? await jamf().declaration(id: declarationID, kind: kind.commandKind),
              let item = details.first(where: { $0.type == "com.apple.configuration.softwareupdate.enforcement.specific" })
        else { return nil }
        let payload = item.payload
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        return JamfUpdateEnforcement(
            declarationID: item.uuid ?? declarationID,
            targetOSVersion: payload?.TargetOSVersion,
            targetBuildVersion: payload?.TargetBuildVersion,
            // No time zone: the device's own wall clock.
            targetLocalDateTime: payload?.TargetLocalDateTime.flatMap(DateFormatting.parseDeviceLocal)
        )
    }

    /// Blueprint names, keyed by identifier (JTKit's Blueprint list).
    /// Platform API only; empty when they can't be read.
    func blueprintNames() async throws -> [String: String] {
        guard let blueprints = try? await JamfPlatform.Blueprints(client: jamf()).list() else { return [:] }
        return Dictionary(blueprints.filter { !$0.name.isEmpty }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Sites, departments, buildings (JTKit)

    /// All sites on the server; the full-access site ("-1") isn't listed.
    func sites() async throws -> [JamfSite] {
        try await jamf().sites().compactMap { site in site.id.map { JamfSite(id: $0, name: site.name ?? $0) } }
    }

    /// Moves a computer to a site ("-1" for none). Safe to repeat.
    func setComputerSite(computerID: String, siteID: String) async throws {
        try await jamf().setSite(siteID, computerID: computerID)
    }

    /// Moves a mobile device to a site ("-1" for none). Safe to repeat.
    func setMobileDeviceSite(deviceID: String, siteID: String) async throws {
        try await jamf().setSite(siteID, mobileDeviceID: deviceID)
    }

    /// Department names, keyed by identifier. Without Read Departments the
    /// row is omitted rather than shown unresolved, so a failure is no names.
    func departmentNames() async throws -> [String: String] {
        (try? await jamf().departmentNames()) ?? [:]
    }

    /// Building names, as departments; needs Read Buildings.
    func buildingNames() async throws -> [String: String] {
        (try? await jamf().buildingNames()) ?? [:]
    }

    // MARK: Paths

    /// A Jamf Pro path in the gateway's form: the Jamf Pro API under `/pro`,
    /// the Classic API under `/proclassic`. Both replace the product segment,
    /// so `/JSSResource/mobiledevices` becomes `/proclassic/mobiledevices`.
    /// Platform paths pass through as they are.
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
}

extension JamfPrestageFamily {
    /// The same family in JTKit.
    var jtkit: JamfPro.PreStageFamily {
        switch self {
        case .computer: .computer
        case .mobileDevice: .mobileDevice
        }
    }
}

extension JamfGroupKind {
    /// The same kind in JTKit's Classic API.
    var classic: JamfClassic.GroupKind {
        switch self {
        case .computer: .computer
        case .mobileDevice: .mobileDevice
        }
    }
}
