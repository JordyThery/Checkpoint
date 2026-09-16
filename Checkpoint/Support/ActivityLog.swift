import Foundation
import Observation

// MARK: - Entries

/// Which service an entry concerns.
nonisolated enum ActivityService: String, Sendable, CaseIterable, Identifiable {
    case appleBusiness = "Apple Business"
    case appleSchool = "Apple School Manager"
    case jamfPro = "Jamf Pro"
    case jamfSchool = "Jamf School"
    case intune = "Intune"

    var id: String { rawValue }

    /// Both Apple services, as opposed to the device management ones.
    /// Enumerated rather than tested against one case, because it decides
    /// which connection name an entry is attributed to: treating Jamf School
    /// as an Apple service would label its requests with the Apple
    /// organization.
    var isAppleOrganization: Bool {
        switch self {
        case .appleBusiness, .appleSchool: true
        case .jamfPro, .jamfSchool, .intune: false
        }
    }
}

extension MDMProduct {
    /// How traffic to this product is labelled in the log. Separate entries
    /// so a log cannot attribute a request to the wrong one.
    var activityService: ActivityService {
        switch self {
        case .jamfPro: .jamfPro
        case .jamfSchool: .jamfSchool
        case .intune: .intune
        }
    }
}

extension AppleOrgKind {
    /// How traffic to this service is labelled in the log. The two are
    /// separate entries so a log cannot attribute a request to the wrong one.
    var activityService: ActivityService {
        switch self {
        case .business: .appleBusiness
        case .school: .appleSchool
        }
    }
}

nonisolated enum ActivityOutcome: String, Sendable {
    case succeeded
    case failed
}

/// One recorded event. Entries are created inside the API actors and handed to
/// the main actor, so they carry only value types.
nonisolated struct ActivityEntry: Identifiable, Sendable {
    /// Entries come in two tiers: what the user asked for, and the individual
    /// requests made to carry it out.
    nonisolated enum Kind: String, Sendable {
        /// Something the user asked for, with its overall result.
        case action = "Action"
        /// A single HTTP request.
        case request = "Request"
        /// A token acquisition. These never carry a body.
        case signIn = "Sign-in"
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let service: ActivityService
    /// Organization or server name, so a log spanning several connections
    /// stays readable.
    let connection: String?
    let summary: String
    let status: Int?
    let duration: TimeInterval?
    let outcome: ActivityOutcome
    /// Already redacted and truncated, or nil when there was nothing to record.
    let requestBody: String?
    let responseBody: String?
    /// Explains an absent response body, e.g. that the endpoint returns a secret.
    let bodyNote: String?
    /// Device identifiers mentioned by this entry, collected so that a redacted
    /// export can replace them consistently.
    let identifiers: Set<String>

    var statusText: String {
        guard let status else { return outcome == .failed ? "Failed" : "—" }
        return String(status)
    }

    var durationText: String {
        guard let duration else { return "—" }
        return String(format: "%.2fs", duration)
    }
}

// MARK: - Log

/// In-memory record of the requests Checkpoint makes and the actions it takes.
///
/// Nothing is written to disk. The clients feeding this log also carry
/// FileVault recovery keys, Recovery Lock passwords and escrowed unlock
/// tokens, and keeping no file means a log cannot outlive the session that
/// produced it. Sharing is deliberate: copy or export from the log window.
@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityEntry] = []

    /// Oldest entries are dropped past this. A lookup of several hundred
    /// serials makes a handful of requests each.
    static let capacity = 1000

    func clear() {
        entries.removeAll()
    }

    // MARK: Recording

    /// Records an action the user asked for, with its overall result.
    nonisolated func recordAction(
        service: ActivityService,
        connection: String?,
        summary: String,
        outcome: ActivityOutcome,
        serials: [String] = []
    ) {
        append(ActivityEntry(
            date: Date(),
            kind: .action,
            service: service,
            connection: connection,
            summary: summary,
            status: nil,
            duration: nil,
            outcome: outcome,
            requestBody: nil,
            responseBody: nil,
            bodyNote: nil,
            identifiers: Set(serials)
        ))
    }

    /// Records a completed HTTP request. Bodies are scrubbed of secrets and
    /// truncated here; `withholdBodies` drops both of them entirely, which is
    /// how endpoints that carry a secret in either direction are handled.
    nonisolated func recordRequest(
        service: ActivityService,
        connection: String?,
        method: String,
        path: String,
        status: Int,
        duration: TimeInterval,
        requestBody: Data?,
        responseBody: Data?,
        withholdBodies: Bool
    ) {
        let request = withholdBodies ? nil : ActivityRedaction.readableBody(requestBody)
        let response = withholdBodies ? nil : ActivityRedaction.readableBody(responseBody)
        append(ActivityEntry(
            date: Date(),
            kind: .request,
            service: service,
            connection: connection,
            summary: "\(method) \(path)",
            status: status,
            duration: duration,
            outcome: (200...299).contains(status) ? .succeeded : .failed,
            requestBody: request?.text,
            responseBody: response?.text,
            bodyNote: withholdBodies ? "Bodies withheld: this endpoint carries a secret." : nil,
            identifiers: ActivityRedaction.identifiers(inPath: path)
                .union(request?.identifiers ?? [])
                .union(response?.identifiers ?? [])
        ))
    }

    /// Records a request that never got a response, e.g. no network.
    nonisolated func recordFailure(
        service: ActivityService,
        connection: String?,
        method: String,
        path: String,
        duration: TimeInterval,
        message: String
    ) {
        append(ActivityEntry(
            date: Date(),
            kind: .request,
            service: service,
            connection: connection,
            summary: "\(method) \(path)",
            status: nil,
            duration: duration,
            outcome: .failed,
            requestBody: nil,
            responseBody: nil,
            bodyNote: message,
            identifiers: ActivityRedaction.identifiers(inPath: path)
        ))
    }

    /// Records a token acquisition. Neither the request nor the response is
    /// recorded: the request carries the client secret or signed assertion,
    /// and the response carries the token itself.
    nonisolated func recordSignIn(
        service: ActivityService,
        connection: String?,
        summary: String,
        outcome: ActivityOutcome,
        duration: TimeInterval? = nil
    ) {
        append(ActivityEntry(
            date: Date(),
            kind: .signIn,
            service: service,
            connection: connection,
            summary: summary,
            status: nil,
            duration: duration,
            outcome: outcome,
            requestBody: nil,
            responseBody: nil,
            bodyNote: nil,
            identifiers: []
        ))
    }

    private nonisolated func append(_ entry: ActivityEntry) {
        Task { @MainActor in self.insert(entry) }
    }

    /// Entries arrive through unordered task hops, and bulk actions make their
    /// requests in parallel, so insert by timestamp rather than appending.
    /// That keeps the oldest entry at the front, which the capacity trim relies
    /// on, and saves the view from sorting.
    private func insert(_ entry: ActivityEntry) {
        let index = entries.lastIndex { $0.date <= entry.date }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: index)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}

// MARK: - Redaction

nonisolated enum ActivityRedaction {
    /// Values under these keys never reach the log, wherever they appear.
    ///
    /// This is a backstop, not the defence. Endpoints known to return a secret
    /// withhold their whole body at the call site, because a list of key names
    /// stops matching the day a field is renamed or a new one is added.
    static let secretKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token",
        "client_secret", "client_assertion", "assertion",
        "password", "secret", "passcode",
        "personalRecoveryKey", "recoveryLockPassword", "recoveryPassword",
        "pin", "unlockToken", "escrowToken",
    ]

    /// Keys holding someone's personal details rather than a device's.
    ///
    /// Jamf School attaches an owner to every device record, carrying a name,
    /// e-mail address and username, and in a school those are pupils. The log
    /// is exportable and meant to be attachable to a bug report, so the whole
    /// sub-object goes rather than its individual fields: one key covers every
    /// name inside it, and it keeps covering them if Jamf adds another.
    static let personalKeys: Set<String> = ["owner", "notes"]

    /// Keys holding a device identifier. Not secrets, but they name the
    /// devices a log covers, so a redacted export replaces them.
    ///
    /// Jamf School spells the hardware addresses `WiFiMAC` and `bluetoothMAC`
    /// rather than Jamf Pro's `wifiMacAddress`. Matching is case-insensitive,
    /// so one spelling of each is enough.
    static let identifierKeys: Set<String> = [
        "serialNumber", "serial_number", "serialnumber", "serials", "serialNumbers",
        "udid", "udids", "imei", "meid", "eid",
        "wifiMacAddress", "ethernetMacAddress", "bluetoothMacAddress",
        "macAddress", "mac_address",
        "WiFiMAC", "bluetoothMAC",
    ]

    /// Declarative status items that name the device.
    ///
    /// These carry the identifier as a value rather than under a telling key —
    /// `{"key": "device.identifier.udid", "value": "…"}` — so matching key
    /// names alone never sees them.
    static let identifierStatusItems: Set<String> = [
        "device.identifier.serial-number",
        "device.identifier.udid",
    ]

    static let placeholder = "••••••"
    static let maximumBodyLength = 20_000

    /// Bodies larger than this are not recorded at all.
    ///
    /// Parsing and re-serialising every response has to stay cheap: walking the
    /// device-enrolment pages produces the largest bodies in the app, 500
    /// devices at a time, and none of them are read by eye. Recording an
    /// excerpt instead would be worse than nothing, because identifiers are
    /// collected during the parse, so an unparsed excerpt could carry serial
    /// numbers that a masked export would then not know to replace.
    static let maximumRecordedBodySize = 256 * 1024

    struct Body: Sendable {
        let text: String
        let identifiers: Set<String>
    }

    /// Turns a body into something readable, with secrets replaced. JSON is
    /// pretty-printed with sorted keys so entries can be compared by eye.
    static func readableBody(_ data: Data?) -> Body? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count <= maximumRecordedBodySize else {
            let size = ByteCountFormatStyle().format(Int64(data.count))
            return Body(text: "Not recorded: the body is \(size).", identifiers: [])
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // Not JSON: record it as text, without trying to find secrets in it.
            let text = String(data: data, encoding: .utf8) ?? "(\(data.count) bytes)"
            return Body(text: truncated(text), identifiers: [])
        }
        var found: Set<String> = []
        let scrubbed = scrubbed(parsed, identifiers: &found)
        let text: String
        if let pretty = try? JSONSerialization.data(
            withJSONObject: scrubbed,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ), let string = String(data: pretty, encoding: .utf8) {
            text = string
        } else {
            text = String(describing: scrubbed)
        }
        return Body(text: truncated(text), identifiers: found)
    }

    private static func scrubbed(_ value: Any, identifiers: inout Set<String>) -> Any {
        if let dictionary = value as? [String: Any] {
            // A status item names the device in its value, so it is matched on
            // what the item is rather than on what the key is called.
            if let name = dictionary["key"] as? String,
               matches(name, identifierStatusItems) {
                collect(dictionary["value"], into: &identifiers)
            }
            var result: [String: Any] = [:]
            for (key, inner) in dictionary {
                if matches(key, secretKeys) || matches(key, personalKeys) {
                    result[key] = placeholder
                    continue
                }
                if matches(key, identifierKeys) {
                    collect(inner, into: &identifiers)
                }
                result[key] = scrubbed(inner, identifiers: &identifiers)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { scrubbed($0, identifiers: &identifiers) }
        }
        return value
    }

    private static func matches(_ key: String, _ set: Set<String>) -> Bool {
        set.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    private static func collect(_ value: Any, into identifiers: inout Set<String>) {
        if let string = value as? String, !string.isEmpty {
            identifiers.insert(string)
        } else if let array = value as? [Any] {
            for element in array { collect(element, into: &identifiers) }
        }
    }

    /// Serial numbers and UDIDs also appear in paths and query strings, where
    /// there is no key to go by, so pick out the tokens shaped like one.
    ///
    /// The query string matters as much as the path: a lookup that finds
    /// nothing mentions its serial only in a filter, and that is precisely the
    /// log someone attaches to a bug report. Tokens are split on the
    /// punctuation those filters use, so `filter=hardware.serialNumber=="C02…"`
    /// yields the serial on its own. Over-matching here only means masking
    /// something that did not need it.
    static func identifiers(inPath path: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/?&=\"',;:.()[]{} ")
        var found: Set<String> = []
        for segment in path.components(separatedBy: separators) {
            let uppercased = segment.uppercased()
            let isSerial = (10...12).contains(segment.count)
                && segment == uppercased
                && segment.allSatisfy { $0.isLetter || $0.isNumber }
                && segment.contains(where: \.isNumber)
            let isUDID = segment.count == 36 && UUID(uuidString: segment) != nil
            if isSerial || isUDID { found.insert(segment) }
        }
        return found
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maximumBodyLength else { return text }
        return text.prefix(maximumBodyLength) + "\n… truncated"
    }
}

// MARK: - Export

/// Replaces device identifiers with stable placeholders. The same device keeps
/// the same placeholder throughout an export, so a log stays diagnosable
/// without naming the devices it covers.
nonisolated struct IdentifierMasker {
    private var assigned: [String: String] = [:]

    /// Registers identifiers longest-first, so that a value containing another
    /// one is replaced before its substring is.
    init(identifiers: Set<String>) {
        for (offset, value) in identifiers.sorted(by: { ($0.count, $0) > ($1.count, $1) }).enumerated() {
            assigned[value] = "<device \(offset + 1)>"
        }
    }

    func masking(_ text: String) -> String {
        var result = text
        for (value, replacement) in assigned {
            result = result.replacingOccurrences(of: value, with: replacement, options: [.caseInsensitive])
        }
        return result
    }
}

extension ActivityLog {
    /// Renders the log as plain text. With `maskingIdentifiers`, serial
    /// numbers, UDIDs and hardware addresses are replaced with placeholders so
    /// the result can be attached to a bug report.
    func exportText(maskingIdentifiers: Bool) -> String {
        let masker = maskingIdentifiers
            ? IdentifierMasker(identifiers: entries.reduce(into: Set<String>()) { $0.formUnion($1.identifiers) })
            : nil
        func rendered(_ text: String) -> String {
            masker?.masking(text) ?? text
        }

        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        var lines = [
            "Checkpoint activity log",
            "Exported \(stamp)",
            "\(entries.count) entr\(entries.count == 1 ? "y" : "ies"). Secrets are never recorded.",
        ]
        if maskingIdentifiers {
            lines.append("Device identifiers have been replaced with placeholders.")
        }
        lines.append("")

        let timestamp = Date.FormatStyle(date: .numeric, time: .standard)
        for entry in entries.reversed() {
            lines.append(String(repeating: "-", count: 72))
            var header = "\(entry.date.formatted(timestamp))  \(entry.kind.rawValue)  \(entry.service.rawValue)"
            if let connection = entry.connection { header += "  (\(connection))" }
            lines.append(header)
            lines.append(rendered(entry.summary))
            var facts: [String] = []
            if entry.status != nil { facts.append("status \(entry.statusText)") }
            if entry.duration != nil { facts.append(entry.durationText) }
            if entry.outcome == .failed { facts.append("failed") }
            if !facts.isEmpty { lines.append(facts.joined(separator: "  ·  ")) }
            if let note = entry.bodyNote { lines.append(note) }
            if let body = entry.requestBody {
                lines.append("Request body:")
                lines.append(rendered(body))
            }
            if let body = entry.responseBody {
                lines.append("Response body:")
                lines.append(rendered(body))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
