import Foundation

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
    let security: MobileSecurityState?
    let osVersion: String?
    let osBuild: String?
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

/// Parses the declaration status value, which is not JSON.
///
/// Jamf flattens Apple's `management.declarations` dictionary and renders each
/// entry with a Java-style `toString`: unquoted keys and values, nested `{}`
/// and `[]`, and free-text errors containing brackets, colons and commas.
///
/// ```
/// {active=true, identifier=…, valid=valid, server-token=…},{reasons=[{details=
/// {Error=[kSUCoreErrorDDMInvalidDeclarationFailure] Invalid declaration: target
/// OS version (15.7.3) is older than current version (15.7.9)}, …}], …}
/// ```
///
/// None of it is documented, so every step degrades rather than fails: an
/// unparsable record contributes what can be salvaged, and an unreadable
/// value yields an empty list. A missing warning is bad; losing the software
/// update row to a parse error is worse.
nonisolated enum JamfDeclarationParsing {
    static func declarations(from value: String?) -> [JamfDeclaration] {
        guard let value, !value.isEmpty else { return [] }
        return splitTopLevel(value, separator: ",")
            .compactMap(declaration(from:))
    }

    private static func declaration(from record: String) -> JamfDeclaration? {
        let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        let fields = map(from: trimmed)

        // Salvage rather than give up: a record whose identifier cannot be
        // read is still worth reporting if it says it is invalid.
        let identifier = fields["identifier"] ?? fields["Identifier"]
        let validity = fields["valid"].flatMap(JamfDeclarationValidity.init(rawValue:))
        guard identifier != nil || validity == .invalid else { return nil }

        return JamfDeclaration(
            identifier: identifier ?? "Unidentified declaration",
            active: fields["active"] == "true",
            validity: validity ?? .unknown,
            reasons: reasons(from: fields["reasons"])
        )
    }

    /// The human-readable half of each reason. Apple puts the useful sentence
    /// in `details.Error`; `description` is the generic form of the same thing.
    private static func reasons(from value: String?) -> [String] {
        guard let value else { return [] }
        let inner = unwrap(value, open: "[", close: "]")
        return splitTopLevel(inner, separator: ",").compactMap { record in
            let fields = map(from: record.trimmingCharacters(in: .whitespacesAndNewlines))
            let details = map(from: fields["details"] ?? "")
            let text = details["Error"] ?? fields["description"] ?? fields["code"]
            guard let text, !text.isEmpty else { return nil }
            return text
        }
    }

    /// Reads `{key=value, key=value}` into a dictionary, keeping nested
    /// structures intact as their raw text.
    private static func map(from value: String) -> [String: String] {
        let inner = unwrap(value.trimmingCharacters(in: .whitespacesAndNewlines), open: "{", close: "}")
        var result: [String: String] = [:]
        for field in splitTopLevel(inner, separator: ",") {
            let piece = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let text = String(piece[piece.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else { continue }
            result[key] = text
        }
        return result
    }

    private static func unwrap(_ value: String, open: Character, close: Character) -> String {
        guard value.first == open, value.last == close, value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Splits on a separator that is not inside braces or brackets. Free text
    /// in these values contains both, so a naive split tears records apart.
    private static func splitTopLevel(_ value: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in value {
            switch character {
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
            if character == separator, depth <= 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
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

/// Client for the Jamf Pro API, connected directly or through the Platform
/// API gateway. Authenticates with an API client (OAuth client credentials),
/// a username and password (bearer token), or a gateway integration.
actor JamfClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let baseURL: URL
    private let authMethod: MDMAuthMethod
    private let account: String
    private let secret: String
    /// Platform API only: sent as `X-Environment-Id` on every request.
    private let environmentID: String
    private var cachedToken: (value: String, expiry: Date)?
    /// The sign-in in flight, so concurrent callers share one.
    private var signIn: Task<String, any Error>?
    private let log: ActivityLog?
    /// Server name, recorded with each entry so a log covering several
    /// connections says which one it went to.
    private let connectionName: String

    init?(config: MDMConnection, secret: String, log: ActivityLog? = nil) {
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
                let operatingSystem: OperatingSystem?
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
            struct OperatingSystem: Decodable {
                let version: String?
                let build: String?
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
            // Asked for alongside the others rather than in a second request.
            // Reported as the installed OS, and compared against an enforced
            // update to tell one the device already has from one it still owes.
            queryItems.append(URLQueryItem(name: "section", value: "OPERATING_SYSTEM"))
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
                DiskEncryptionState(
                    fileVaultEnabled: $0.fileVault2Enabled,
                    bootPartitionState: $0.bootPartitionEncryptionDetails?.partitionFileVault2State,
                    bootPartitionPercent: $0.bootPartitionEncryptionDetails?.partitionFileVault2Percent,
                    recoveryKeyValidity: $0.individualRecoveryKeyValidityStatus
                )
            },
            osVersion: item.operatingSystem?.version,
            osBuild: item.operatingSystem?.build
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
            let osVersion: String?
            let osBuild: String?
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
                MobileSecurityState(
                    passcodePresent: $0.passcodePresent,
                    passcodeCompliant: $0.passcodeCompliant,
                    passcodeCompliantWithProfile: $0.passcodeCompliantWithProfile,
                    hardwareEncryption: $0.hardwareEncryption
                )
            },
            osVersion: detail?.osVersion,
            osBuild: detail?.osBuild
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
        let (data, status) = try await send(path: "/api/v4/computers-inventory/\(id)", method: "DELETE")
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

    // MARK: Platform declaration reporting

    /// Declarations from the platform's own reporting API, which serves them
    /// as typed JSON instead of the flattened status item the Jamf Pro API
    /// gives.
    ///
    /// Gateway connections only: both endpoints are platform-native, under
    /// their own product prefixes. Returns nil when the platform cannot
    /// answer, so the caller keeps the declarations parsed out of the status
    /// report rather than losing the row.
    ///
    /// Two requests, because the platform keys devices by its own UUID rather
    /// than by the management ID the status report uses, and the only way to
    /// reach it from a serial number is to ask. The resolver is the one the
    /// platform restart and shut down actions already use, including its
    /// refusal to accept a row whose serial does not match.
    func platformDeclarations(serial: String) async throws -> [JamfDeclaration]? {
        guard authMethod == .platformGateway,
              let deviceID = try await platformDeviceID(serial: serial) else { return nil }
        struct Response: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let declarationIdentifier: String?
                let active: Bool?
                let validityState: String?
                let reasons: [Reason]?
            }
            struct Reason: Decodable {
                let code: String?
                let description: String?
                let details: [Detail]?
            }
            struct Detail: Decodable {
                let key: String?
                let description: String?
            }
        }
        let (data, status) = try await send(
            path: "/ddm/report/v1/devices/\(deviceID)/declarations",
            queryItems: [
                // Required by the endpoint. Configurations only, matching what
                // the status report's own configurations item carries. The
                // filter field is declarationType — the response property is
                // named type, but that is not a filterable field.
                URLQueryItem(name: "filter", value: "declarationType==CONFIGURATION"),
                // No paging: a device carries a few dozen declarations at
                // most, so one page holds them all.
                URLQueryItem(name: "size", value: "200"),
            ]
        )
        if status == 403 || status == 404 { return nil }
        try throwIfError(status: status, data: data)
        guard let results = try? JSONDecoder().decode(Response.self, from: data).results else { return nil }
        return results.compactMap { item in
            guard let identifier = item.declarationIdentifier, !identifier.isEmpty else { return nil }
            // The same precedence the status-item parser uses — the Error
            // detail, else the summary, else the code — so a gateway
            // connection shows the identical text a direct one does. The
            // Error detail is Apple's own wording and names the offending
            // version.
            let reasons: [String] = (item.reasons ?? []).compactMap { reason in
                reason.details?.first { $0.key == "Error" }?.description
                    ?? reason.description
                    ?? reason.code
            }
            return JamfDeclaration(
                identifier: identifier,
                active: item.active ?? false,
                validity: JamfDeclarationValidity(rawValue: (item.validityState ?? "unknown").lowercased()) ?? .unknown,
                reasons: reasons.filter { !$0.isEmpty }
            )
        }
    }

    // MARK: Device compliance

    /// Whether the Device Compliance integration is switched on for the
    /// instance.
    ///
    /// Read once before asking per device: with the feature off, every
    /// per-device call answers with an inapplicable record, and the row is
    /// better left out than shown as unknown. It needs its own privilege, so
    /// a failure here is not read as "off" — the caller falls through to the
    /// per-device read and lets that decide.
    func deviceComplianceEnabled() async throws -> Bool {
        struct Response: Decodable { let sharedDeviceFeatureEnabled: Bool? }
        let (data, status) = try await send(path: "/api/v1/conditional-access/device-compliance/feature-toggle")
        try throwIfError(status: status, data: data)
        return try JSONDecoder().decode(Response.self, from: data).sharedDeviceFeatureEnabled ?? false
    }

    /// Compliance for one device, as the compliance vendor last reported it.
    ///
    /// The response is documented as an array, and a device outside the
    /// integration's scope comes back with `applicable: false` rather than as
    /// an error.
    func deviceCompliance(kind: DeviceKind, deviceID: String) async throws -> JamfDeviceCompliance? {
        struct Item: Decodable {
            let applicable: Bool?
            let complianceState: String?
            let complianceVendor: String?
        }
        let family = kind == .computer ? "computer" : "mobile"
        let (data, status) = try await send(
            path: "/api/v1/conditional-access/device-compliance-information/\(family)/\(deviceID)"
        )
        try throwIfError(status: status, data: data)
        // An array by contract; a single object is accepted too, in case the
        // shape is ever tightened.
        let items: [Item]
        if let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else if let one = try? JSONDecoder().decode(Item.self, from: data) {
            items = [one]
        } else {
            return nil
        }
        guard let item = items.first(where: { $0.applicable == true }) ?? items.first else { return nil }
        return JamfDeviceCompliance(
            applicable: item.applicable ?? false,
            state: item.complianceState,
            vendor: item.complianceVendor
        )
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
        // Every group this client produces carries a kind; only Jamf School's
        // do not, and those never reach here.
        guard let resource = group.kind?.groupResource else {
            throw APIError(message: "\(group.name) is not a Jamf Pro group.")
        }
        let (data, status) = try await send(path: "/JSSResource/\(resource)/id/\(group.id)")
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let container = decoded.computer_group ?? decoded.mobile_device_group
        let members = container?.computers ?? container?.mobile_devices ?? []
        var seen = Set<String>()
        return members
            .compactMap { $0.serial_number?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Declarative status

    /// What the device last reported about itself declaratively: its software
    /// update state and the declarations it has processed.
    ///
    /// Both come from one request because they come from one report, and they
    /// explain each other — a rejected enforcement declaration is why a device
    /// with nothing pending is nonetheless not being updated.
    ///
    /// This is the only supported source for software updates: Apple has moved
    /// them to declarative management, and Jamf Pro's managed software update
    /// plans and per-product statuses are both deprecated. Needs nothing
    /// beyond the read privileges a lookup already uses.
    ///
    /// Nil when the device has sent no report, which is the answer for a
    /// device that is not declaratively managed.
    func ddmStatus(managementID: String) async throws -> JamfDDMStatus? {
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
        guard !items.isEmpty else { return nil }

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

        let declarations = JamfDeclarationParsing.declarations(
            from: values["management.declarations.configurations"]?.value
        )
        let newestReport = values.values.compactMap(\.reportedAt).max()

        return JamfDDMStatus(
            softwareUpdate: softwareUpdate(values: values, text: text),
            declarations: declarations,
            reportedAt: newestReport
        )
    }

    /// The software update half of a status report, or nil when the device
    /// reported none of those keys. Reporting nothing is different from
    /// reporting that there is nothing to do.
    private func softwareUpdate(
        values: [String: (value: String?, reportedAt: Date?)],
        text: (String) -> String?
    ) -> JamfSoftwareUpdateStatus? {
        guard values.keys.contains(where: { $0.hasPrefix("softwareupdate.") }) else { return nil }

        // The deadline belongs to the offer beside it. Jamf keeps whichever
        // value it last saw, so a deadline recorded before the current offer
        // was reported is a leftover from an earlier enforcement and saying
        // "was due" from it would be inventing a deadline for this update.
        let offerReportedAt = values["softwareupdate.pending-version.os-version"]?.reportedAt
        let deadlineReportedAt = values["softwareupdate.pending-version.target-local-date-time"]?.reportedAt
        let deadlineIsCurrent: Bool = {
            guard let offerReportedAt, let deadlineReportedAt else { return true }
            return deadlineReportedAt >= offerReportedAt
        }()

        return JamfSoftwareUpdateStatus(
            // The one scalar that says what the device is doing. The two
            // dictionaries are deliberately not read as signals: Jamf flattens
            // them, so softwareupdate.pending-version and
            // softwareupdate.failure-reason always arrive null whatever the
            // device reported.
            installState: text("softwareupdate.install-state"),
            installReason: text("softwareupdate.install-reason.reason"),
            offeredOSVersion: text("softwareupdate.pending-version.os-version"),
            offeredBuildVersion: text("softwareupdate.pending-version.build-version"),
            deadline: deadlineIsCurrent
                ? text("softwareupdate.pending-version.target-local-date-time")
                    .flatMap(DateFormatting.parseStatusItemDate)
                : nil,
            offerReportedAt: offerReportedAt,
            failureCount: text("softwareupdate.failure-reason.count").flatMap(Int.init),
            lastFailureReason: text("softwareupdate.failure-reason.reason"),
            lastFailureAt: text("softwareupdate.failure-reason.timestamp")
                .flatMap(DateFormatting.parseStatusItemDate),
            betaEnrollment: text("softwareupdate.beta-enrollment"),
            // Presence, not value: Apple sends an empty string for a device
            // that is in no beta programme, and text() cannot tell that from
            // a key the device never sent.
            betaReported: values.keys.contains("softwareupdate.beta-enrollment"),
            isReported: true
        )
    }

    /// The software update enforcement declaration among those given, or nil
    /// when none of them is one.
    ///
    /// The status report names declarations but does not say what they
    /// contain, so each has to be read back. Nothing here throws: this runs
    /// while someone browses a device, and a declaration the server will not
    /// hand over is worth skipping rather than failing the whole row.
    func updateEnforcement(among declarations: [JamfDeclaration]) async -> JamfUpdateEnforcement? {
        for declaration in declarations {
            // Two levels of optional: the request can fail, and a declaration
            // that reads fine may simply not be an enforcement one.
            if let found = ((try? await updateEnforcement(declarationID: declaration.identifier)) ?? nil) {
                return found
            }
        }
        return nil
    }

    /// Reads one declaration, returning it only if it enforces a software
    /// update. Others are legitimate — `management.status-subscriptions` is
    /// the one most devices carry — so the type must be checked rather than
    /// assumed from the declaration being valid.
    private func updateEnforcement(declarationID: String) async throws -> JamfUpdateEnforcement? {
        struct Response: Decodable {
            let declarations: [Item]?
            struct Item: Decodable {
                let type: String?
                /// The declaration's own payload, delivered as a JSON string
                /// inside the JSON, so it needs decoding a second time.
                let payloadJson: String?
                let uuid: String?
            }
        }
        struct Payload: Decodable {
            let TargetOSVersion: String?
            let TargetBuildVersion: String?
            let TargetLocalDateTime: String?
        }
        let (data, status) = try await send(path: "/api/v1/dss-declarations/\(declarationID)")
        guard (200...299).contains(status) else { return nil }
        let items = (try? JSONDecoder().decode(Response.self, from: data))?.declarations ?? []
        guard let item = items.first(where: {
            $0.type == "com.apple.configuration.softwareupdate.enforcement.specific"
        }) else { return nil }

        let payload = item.payloadJson
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        return JamfUpdateEnforcement(
            declarationID: item.uuid ?? declarationID,
            targetOSVersion: payload?.TargetOSVersion,
            targetBuildVersion: payload?.TargetBuildVersion,
            // Apple's format carries no time zone, so it is the device's own
            // wall clock, like the deadline in the status report.
            targetLocalDateTime: payload?.TargetLocalDateTime
                .flatMap(DateFormatting.parseDeviceLocal)
        )
    }

    /// Blueprint names, keyed by identifier.
    ///
    /// Platform API only: blueprints are a platform feature with no endpoint
    /// on a Jamf Pro instance, so a direct connection can show only the
    /// identifier a declaration carries. Server-wide and small, so callers
    /// read it once per session.
    func blueprintNames() async throws -> [String: String] {
        struct Response: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let id: String?
                let name: String?
            }
        }
        // Blueprints sit behind their own product prefix on the gateway, so
        // the path is /blueprints/v1/blueprints. It is not one of the
        // prefixes gatewayPath rewrites, and passes through as it stands.
        let (data, status) = try await send(
            path: "/blueprints/v1/blueprints",
            queryItems: [URLQueryItem(name: "page-size", value: "200")]
        )
        guard (200...299).contains(status) else { return [:] }
        let items = (try? JSONDecoder().decode(Response.self, from: data))?.results
            ?? (try? JSONDecoder().decode([Response.Item].self, from: data))
            ?? []
        return Dictionary(
            items.compactMap { item in
                guard let id = item.id, let name = item.name, !name.isEmpty else { return nil }
                return (id, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
            path: "/api/v4/computers-inventory-detail/\(computerID)",
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

    private func signingIn() async throws -> String {
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
        case .entraApp:
            // Not reachable: this client is only built for a Jamf Pro
            // connection, and the editor offers Entra only for Intune.
            throw APIError(message: "An Entra app registration cannot sign in to Jamf Pro.")
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
