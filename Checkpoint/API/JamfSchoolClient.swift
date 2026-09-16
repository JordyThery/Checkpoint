import Foundation

// MARK: - Models

/// A device as the Jamf School list endpoint reports it.
///
/// Only the fields Checkpoint shows are kept. The record also carries battery,
/// capacity, iCloud backup state, network information and an owner; the owner
/// is a person, and in a school usually a pupil, so it is deliberately not
/// read into the app at all.
struct JamfSchoolDevice: Sendable {
    let udid: String
    let serialNumber: String
    let name: String?
    let locationID: String?
    let modelName: String?
    let osPrefix: String?
    let osVersion: String?
    /// `ipad`, `iphone` or `mac`.
    let deviceClass: String?
    let isManaged: Bool?
    let isSupervised: Bool?
    /// `dep`, `manual`, `ac2` and so on.
    let enrollType: String?
    /// Name of the Apple ADE profile assigned to the device, not a Jamf
    /// PreStage. Jamf School has no PreStages.
    let depProfile: String?
    /// Wall-clock time in the instance's own zone, with no offset attached.
    let lastCheckin: String?
    let groupNames: [String]
    let inTrash: Bool

    /// Computer or mobile device.
    ///
    /// `class` and `os.prefix` agree on every device in the tenant this was
    /// verified against, cross-checked against `isBootstrapStored` appearing
    /// on exactly the Macs. `model.type` is not used: it is a string on this
    /// endpoint and an object on the per-device one, and is empty on some
    /// records. The iPad/iPhone distinction is unreliable too, but Checkpoint
    /// only needs to tell a Mac from everything else.
    var kind: DeviceKind {
        if deviceClass?.lowercased() == "mac" { return .computer }
        if osPrefix?.lowercased() == "macos" { return .computer }
        return .mobileDevice
    }
}

/// The per-device record, which is a different shape from the list entry.
///
/// Passcode state exists only here, so it is read when a device is selected
/// rather than during a lookup. The time zone comes from this endpoint too:
/// it reports `lastCheckin` as an object naming the instance's zone, while
/// the list endpoint gives the same wall-clock string with no zone at all.
struct JamfSchoolDeviceDetails: Sendable {
    let hasPasscode: Bool?
    let passcodeCompliant: Bool?
    let isBootstrapStored: Bool?
    let timeZone: TimeZone?
}

struct JamfSchoolLocation: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDistrict: Bool
}

/// What became of each device in a location move.
///
/// The move endpoint reports per device rather than succeeding or failing as
/// a whole, so the caller has to read these rather than the status: a device
/// that was not found or could not be moved comes back under HTTP 200 with
/// everything else. Devices already in the target location are listed too,
/// and are not a failure.
struct JamfSchoolMoveOutcome: Sendable {
    var moved: [String] = []
    var notFound: [String] = []
    var alreadyThere: [String] = []
    var failed: [String] = []

    /// UDIDs that did not end up where they were asked to go.
    var unmoved: [String] { notFound + failed }
}

/// Decodes a flag that Jamf School reports as a boolean on one endpoint and as
/// 0/1 on another, for the same field.
private struct LenientBool: Decodable, Sendable {
    let value: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            value = string == "1" || string.lowercased() == "true"
        } else {
            value = false
        }
    }
}

/// Decodes an identifier Jamf School reports as a number on one endpoint and
/// as a string on another.
private struct LenientID: Decodable, Sendable {
    let value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            value = ""
        }
    }
}

// MARK: - Client

/// Client for the Jamf School API.
///
/// A different product from Jamf Pro rather than a variant of it: HTTP Basic
/// authentication with the Network ID as the user and an API key as the
/// password, one device resource covering Macs and mobile devices alike, and
/// locations in place of sites.
///
/// Two things about this API drive the shape of everything below.
///
/// First, **HTTP 200 does not mean the request succeeded**, and neither does
/// the `code` in the body, which is not always there: the documentation shows
/// one on every response but `/locations` returns none. The `message` is the
/// only signal always present, so `throwIfError` weighs all three.
///
/// Second, the list and per-device endpoints disagree, on field names and on
/// JSON types, for the same values: `depProfile` against `deviceDepProfile`,
/// `lastCheckin` as a string against an object, flags as booleans against
/// 0/1. They are therefore decoded separately rather than through one model,
/// with `LenientBool` and `LenientID` covering the fields whose type moves.
actor JamfSchoolClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let baseURL: URL
    private let authorization: String
    private let log: ActivityLog?
    /// Server name, recorded with each entry so a log covering several
    /// connections says which one it went to.
    private let connectionName: String

    init?(config: MDMConnection, secret: String, log: ActivityLog? = nil) {
        guard let url = URL(string: config.apiBaseURL), url.host() != nil else { return nil }
        let networkID = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !networkID.isEmpty, !apiKey.isEmpty else { return nil }
        self.baseURL = url
        self.authorization = "Basic " + Data("\(networkID):\(apiKey)".utf8).base64EncodedString()
        self.log = log
        self.connectionName = config.displayName
    }

    // MARK: Devices

    /// Every device in the instance, keyed by serial number.
    ///
    /// Jamf School serves the whole fleet in one request and offers no
    /// pagination, which inverts the economics of the Apple side: reading
    /// everything at once is cheaper than asking per device, and there is no
    /// request quota to pace against. A lookup of any size therefore costs
    /// one request here.
    func fleet() async throws -> [String: JamfSchoolDevice] {
        let devices = try await deviceList(queryItems: [])
        return Dictionary(devices.map { ($0.serialNumber.uppercased(), $0) }) { first, _ in first }
    }

    func device(serial: String) async throws -> JamfSchoolDevice? {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = try await deviceList(queryItems: [URLQueryItem(name: "serialnumber", value: trimmed)])
        return devices.first { $0.serialNumber.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Members of a device group. The list endpoint answers with full records,
    /// so the serial numbers come with them and no second request is needed.
    func devices(inGroup groupID: String) async throws -> [JamfSchoolDevice] {
        try await deviceList(queryItems: [URLQueryItem(name: "groups", value: groupID)])
    }

    private func deviceList(queryItems: [URLQueryItem]) async throws -> [JamfSchoolDevice] {
        struct Response: Decodable {
            let devices: [Item]?
            struct Item: Decodable {
                let UDID: String
                let serialNumber: String?
                let name: String?
                let locationId: LenientID?
                let model: Model?
                let os: OS?
                let `class`: String?
                let isManaged: LenientBool?
                let isSupervised: LenientBool?
                let enrollType: String?
                let depProfile: String?
                let lastCheckin: String?
                let groups: [String]?
                let inTrash: LenientBool?
            }
            struct Model: Decodable {
                let name: String?
            }
            struct OS: Decodable {
                let prefix: String?
                let version: String?
            }
        }
        let (data, status) = try await send(path: "/api/devices", queryItems: queryItems)
        try throwIfError(status: status, data: data)
        let items = try JSONDecoder().decode(Response.self, from: data).devices ?? []
        return items.compactMap { item in
            guard let serial = item.serialNumber, !serial.isEmpty else { return nil }
            return JamfSchoolDevice(
                udid: item.UDID,
                serialNumber: serial,
                name: item.name,
                locationID: item.locationId?.value,
                modelName: item.model?.name,
                osPrefix: item.os?.prefix,
                osVersion: item.os?.version,
                deviceClass: item.class,
                isManaged: item.isManaged?.value,
                isSupervised: item.isSupervised?.value,
                enrollType: item.enrollType,
                depProfile: item.depProfile,
                lastCheckin: item.lastCheckin,
                groupNames: item.groups ?? [],
                inTrash: item.inTrash?.value ?? false
            )
        }
    }

    /// The per-device record, for the values the list endpoint omits.
    func deviceDetails(udid: String) async throws -> JamfSchoolDeviceDetails? {
        struct Response: Decodable {
            let device: Item?
            struct Item: Decodable {
                let hasPasscode: LenientBool?
                let passcodeCompliant: LenientBool?
                let isBootstrapStored: LenientBool?
                let lastCheckin: CheckIn?
            }
            /// This endpoint reports the check-in as an object naming the
            /// instance's time zone, which is the only place the zone appears.
            struct CheckIn: Decodable {
                let timezone: String?
            }
        }
        let (data, status) = try await send(path: "/api/devices/\(udid)")
        try throwIfError(status: status, data: data)
        guard let item = try JSONDecoder().decode(Response.self, from: data).device else { return nil }
        return JamfSchoolDeviceDetails(
            hasPasscode: item.hasPasscode?.value,
            passcodeCompliant: item.passcodeCompliant?.value,
            isBootstrapStored: item.isBootstrapStored?.value,
            timeZone: item.lastCheckin?.timezone.flatMap(TimeZone.init(identifier:))
        )
    }

    // MARK: Locations

    func locations() async throws -> [JamfSchoolLocation] {
        struct Response: Decodable {
            let locations: [Item]?
            struct Item: Decodable {
                let id: LenientID
                let name: String?
                let isDistrict: LenientBool?
            }
        }
        let (data, status) = try await send(path: "/api/locations")
        try throwIfError(status: status, data: data)
        let items = try JSONDecoder().decode(Response.self, from: data).locations ?? []
        return items.map {
            JamfSchoolLocation(
                id: $0.id.value,
                name: $0.name ?? $0.id.value,
                isDistrict: $0.isDistrict?.value ?? false
            )
        }
    }

    // MARK: Groups

    /// Device groups. Jamf School does not split them by device kind, so they
    /// come back as one list.
    func groups() async throws -> [JamfGroup] {
        struct Response: Decodable {
            // The documentation calls this DeviceGroups; the API answers with
            // deviceGroups. Both are accepted so neither spelling breaks it.
            let deviceGroups: [Item]?
            let DeviceGroups: [Item]?
            struct Item: Decodable {
                let id: LenientID
                let name: String?
                let isSmartGroup: LenientBool?
                let members: Int?
            }
        }
        let (data, status) = try await send(path: "/api/devices/groups")
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let items = decoded.deviceGroups ?? decoded.DeviceGroups ?? []
        return items.map {
            JamfGroup(
                id: $0.id.value,
                name: $0.name ?? $0.id.value,
                isSmart: $0.isSmartGroup?.value ?? false,
                kind: nil,
                memberCount: $0.members
            )
        }
    }

    // MARK: Commands

    /// Asks the device for a fresh inventory report.
    func refreshInventory(udid: String) async throws {
        try await command(udid: udid, action: "refresh")
    }

    /// Restarts the device. `clearPasscode` is required by the endpoint, so it
    /// is always sent; it is left false because clearing a passcode is a
    /// separate, destructive act that nobody asked for by restarting.
    func restart(udid: String) async throws {
        try await command(udid: udid, action: "restart", parameters: [("clearPasscode", "false")])
    }

    /// Erases the device. `clearActivationLock` is required by the endpoint
    /// and is always false: dropping Activation Lock is not something a wipe
    /// should decide, and Checkpoint offers no way to clear it, because Jamf
    /// Pro has no equivalent. A locked device therefore stays locked after a
    /// wipe until someone clears it in the Jamf School or Apple console.
    func wipe(udid: String) async throws {
        try await command(udid: udid, action: "wipe", parameters: [("clearActivationLock", "false")])
    }

    /// Removes the management profile, so Jamf School can no longer manage the
    /// device. The record stays until it is trashed.
    func unenroll(udid: String) async throws {
        try await command(udid: udid, action: "unenroll")
    }

    private func command(
        udid: String,
        action: String,
        parameters: [(String, String)] = []
    ) async throws {
        let (data, status) = try await send(
            path: "/api/devices/\(udid)/\(action)",
            method: "POST",
            body: parameters.isEmpty ? nil : FormURLEncoding.body(parameters)
        )
        try throwIfError(status: status, data: data)
    }

    // MARK: Record changes

    /// Moves the device record to the trash. Unlike a Jamf Pro deletion this
    /// is reversible: Jamf School keeps the record and can restore it.
    func trash(udid: String) async throws {
        // The trailing slash is what the API documents for this path.
        let (data, status) = try await send(path: "/api/devices/\(udid)/", method: "DELETE")
        try throwIfError(status: status, data: data)
    }

    /// Moves devices to another location.
    ///
    /// Always the bulk endpoint, even for one device. The single-device path
    /// takes an `:id` parameter that is documented nowhere and is spelled
    /// differently from the `:udid` every sibling endpoint uses, whereas this
    /// one takes UDIDs explicitly. The cap of twenty per request is the API's
    /// own, so callers are chunked.
    ///
    /// The body here is JSON, unlike the commands, which take form encoding.
    /// This is the one endpoint that is a PUT, and a form-encoded PUT is
    /// rejected with `UDIDArrayEmpty`: the service never sees the array,
    /// because PHP populates its form data for POST requests only.
    @discardableResult
    func move(udids: [String], toLocation locationID: String) async throws -> JamfSchoolMoveOutcome {
        struct Response: Decodable {
            let devicesMoved: [String]?
            let devicesNotFound: [String]?
            let devicesLocationSame: [String]?
            let devicesMoveFailed: [String]?
        }
        var outcome = JamfSchoolMoveOutcome()
        for chunk in stride(from: 0, to: udids.count, by: Self.moveChunkSize).map({
            Array(udids[$0..<min($0 + Self.moveChunkSize, udids.count)])
        }) {
            let body = try JSONSerialization.data(
                withJSONObject: ["udids": chunk, "locationId": locationID]
            )
            let (data, status) = try await send(
                path: "/api/devices/migrate",
                method: "PUT",
                body: body,
                contentType: "application/json"
            )
            try throwIfError(status: status, data: data)
            // Read the per-device result rather than trusting the status: a
            // device that could not be moved is reported inside a success.
            let reported = try? JSONDecoder().decode(Response.self, from: data)
            outcome.moved += reported?.devicesMoved ?? []
            outcome.notFound += reported?.devicesNotFound ?? []
            outcome.alreadyThere += reported?.devicesLocationSame ?? []
            outcome.failed += reported?.devicesMoveFailed ?? []
        }
        return outcome
    }

    /// The API rejects a move of more than twenty devices with TooManyDevices.
    private static let moveChunkSize = 20

    // MARK: Connection test

    /// Confirms the credentials and that the key may read. Locations are the
    /// cheapest thing to ask for, and the count is worth showing back.
    func verify() async throws -> Int {
        try await locations().count
    }

    // MARK: Transport

    private func send(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/x-www-form-urlencoded; charset=utf-8"
    ) async throws -> (Data, Int) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid Jamf School URL")
        }
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError(message: "Invalid Jamf School request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        // X-Server-Protocol-Version is deliberately not sent. The documented
        // endpoint versions suggest it matters, but the devices and locations
        // responses are byte-for-byte identical with and without it.

        let loggedPath = [components.path, components.query].compactMap { $0 }.joined(separator: "?")
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log?.recordRequest(
                service: .jamfSchool,
                connection: connectionName,
                method: method,
                path: loggedPath,
                status: status,
                duration: Date().timeIntervalSince(started),
                requestBody: body,
                responseBody: data,
                withholdBodies: false
            )
            return (data, status)
        } catch {
            log?.recordFailure(
                service: .jamfSchool,
                connection: connectionName,
                method: method,
                path: loggedPath,
                duration: Date().timeIntervalSince(started),
                message: error.localizedDescription
            )
            throw error
        }
    }

    /// Messages that mean the request did not do what was asked.
    ///
    /// Matched as a known-bad list rather than checking against a list of
    /// known-good ones, so a message this app has never seen still counts as
    /// a success. The alternative turns every future addition to the API into
    /// a spurious failure.
    private static let failureMessages: Set<String> = [
        "UnlockFailed", "DeviceNotFound", "LocationNotFound", "DeviceNotActive",
        "DeviceNotMigratable", "MigrationFailed", "UDIDArrayEmpty", "TooManyDevices",
        "MissingParameter", "LocationSame",
    ]

    /// Fails on anything that is not a success, whichever way the API says so.
    ///
    /// Neither signal is sufficient alone.
    ///
    /// The HTTP status is not, because Jamf School answers a failed command
    /// with `200 OK` and a different `code` in the body — a wipe that never
    /// happened would be reported as sent.
    ///
    /// The body's `code` is not either, because it is not always there. The
    /// documentation shows one on every response, including a success example
    /// of `{"code": 200, "message": "Unlocked"}`, but `/locations` and the
    /// activation-lock endpoint return no `code` at all. Since the docs are
    /// wrong about the field on the success path they cannot be trusted about
    /// it on the failure path, so a recognised failure `message` counts even
    /// when no code accompanies it.
    private func throwIfError(status: Int, data: Data) throws {
        struct Envelope: Decodable {
            let code: LenientID?
            let message: String?
            let reason: String?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let bodyCode = envelope?.code.flatMap { Int($0.value) }
        let message = envelope?.message
        let httpOK = (200...299).contains(status)
        let codeOK = bodyCode.map { (200...299).contains($0) } ?? true
        let messageOK = !(message.map(Self.failureMessages.contains) ?? false)
        guard !(httpOK && codeOK && messageOK) else { return }

        let detail = [message, envelope?.reason]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " – ")
        // The code that describes the failure, whichever carried it. A failure
        // known only by its message has no code of its own to report.
        let reported = codeOK ? status : (bodyCode ?? status)
        throw APIError(message: "Jamf School: \(Self.explain(reported, message: message))"
            + (detail.isEmpty ? "" : " (\(detail))"))
    }

    /// Turns what this API returns into something a user can act on.
    ///
    /// Keyed on the message rather than the code, because the message is the
    /// signal that is always present. Reporting "HTTP 200" for a failure the
    /// body named would say nothing at all.
    private static func explain(_ code: Int, message: String?) -> String {
        switch message {
        case "DeviceNotFound":
            return "the device is not in this Jamf School instance."
        case "LocationNotFound":
            return "that location no longer exists."
        case "DeviceNotActive":
            return "the device is trashed or inactive, so it cannot be sent commands."
        case "TooManyDevices":
            return "too many devices in one request."
        case "DeviceNotMigratable", "MigrationFailed":
            return "the device cannot be moved, because its owner is not in the district and cross-location enrollment is off."
        case "UnlockFailed":
            return "Apple would not clear the lock. Its service may be unreachable, or no bypass code is escrowed for this device."
        case "UDIDArrayEmpty":
            return "the request carried no devices."
        case "MissingParameter":
            return "the request was missing a required value."
        default:
            // An API key carries its own list of permitted methods, so a
            // rejection usually means the key was never granted the method
            // rather than that the credentials are wrong.
            if code == 401 || code == 403 {
                return "HTTP \(code). Check that the API key is granted this method in Organization → Settings → API."
            }
            return "HTTP \(code)"
        }
    }
}
