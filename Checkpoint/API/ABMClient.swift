import Foundation
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
    let purchaseSourceType: String?
    /// Whether the device can be moved between device management services with
    /// a deadline instead of being reassigned outright. Absent on tenants that
    /// do not serve the migration release.
    let isMdmMigrationCapable: Bool?
    /// REQUESTED, STARTED, SUCCESS or FAILED. Only set once a migration has
    /// been requested for the device.
    let mdmMigrationStatus: String?
    let mdmMigrationDeadlineDateTime: String?

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

struct MDMServer: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
}

/// Everything Apple Business will report about an organization in bulk.
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
            .sorted { ($0.count, $1.number) > ($1.count, $0.number) }
    }

    func serials(inOrder order: String) -> [String] {
        devices.values
            .filter { $0.orderNumber == order }
            .map(\.serialNumber)
            .sorted()
    }
}

// MARK: - Client

/// Client for the Apple Business API (`api-business.apple.com`).
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
    private let baseURL = URL(string: "https://api-business.apple.com")!
    private let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/v2/token")!
    private var cachedToken: (value: String, expiry: Date)?
    private let log: ActivityLog?
    /// Organization name, recorded with each entry so a log covering several
    /// organizations says which one it went to.
    private let connectionName: String

    init(clientID: String, keyID: String, privateKeyPEM: String, connectionName: String = "", log: ActivityLog? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKeyPEM = privateKeyPEM
        self.connectionName = connectionName
        self.log = log
    }

    // MARK: Devices

    /// Returns nil when the serial is unknown to this organization
    /// (never enrolled, or already released).
    func device(serial: String) async throws -> ABMDevice? {
        struct Response: Decodable {
            let data: Item
            struct Item: Decodable { let attributes: ABMDevice }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)")
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
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)/appleCareCoverage")
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

    /// The ID of the MDM server the device is assigned to, if any.
    func assignedServerID(serial: String) async throws -> String? {
        struct Response: Decodable {
            let data: Ref?
            struct Ref: Decodable { let id: String }
        }
        let (data, status) = try await send(path: "/v1/orgDevices/\(serial)/relationships/assignedServer")
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
                MDMServer(id: $0.id, name: $0.attributes.serverName ?? $0.id)
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
        "purchaseSourceType", "isMdmMigrationCapable",
        "mdmMigrationStatus", "mdmMigrationDeadlineDateTime",
    ].joined(separator: ",")

    /// Reads the whole organization: every device, and which management
    /// service each is assigned to. `progress` reports devices read so far,
    /// since Apple returns a cursor but never a total.
    func organizationSnapshot(progress: (@Sendable (Int) -> Void)? = nil) async throws -> ABMSnapshot {
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
            progress?(devices.count)
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
        for server in try await mdmServers() {
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

        return ABMSnapshot(devices: devices, serverIDBySerial: serverIDBySerial, capturedAt: Date())
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
        var attributes: [String: Any] = ["activityType": type.rawValue]
        if type.needsDeadline {
            guard let migrationDeadline else {
                throw APIError(message: "\(type.rawValue) requires a migration deadline.")
            }
            guard migrationDeadline.timeIntervalSinceNow <= Self.maximumMigrationDeadline else {
                throw APIError(message: "Apple Business will not accept a migration deadline more than 90 days from now.")
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

    private func send(path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError(message: "Invalid URL for path \(path)")
        }
        return try await send(url: url.absoluteURL, method: method, body: body)
    }

    // Apple limits how many requests an organization may make in a short
    // period. It does not answer with 429 and a Retry-After: past the limit it
    // simply stops completing connections, so the failure arrives as a
    // URLSession error. Measured against a live tenant, roughly twenty
    // consecutive requests exhaust it and it recovers within a few seconds.
    //
    // Requests are therefore paced, and connection failures retried with a
    // widening delay. Without this, a lookup of a few hundred devices fails
    // partway through with every remaining device reported as an error.

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

    /// The single point every Apple Business request goes through, and so the
    /// single point the activity log is fed from. Request headers are
    /// deliberately never recorded, which keeps the bearer token out of the log
    /// by construction rather than by filtering.
    private func send(url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let loggedPath = [url.path(), url.query()].compactMap { $0 }.joined(separator: "?")
        var lastError: Error?
        for attempt in 0..<Self.maximumAttempts {
            await reserveRequestSlot()
            let started = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 429 and 503 are retried on the same terms as a dropped
                // connection, in case Apple starts answering properly.
                if (status == 429 || status == 503), attempt < Self.maximumAttempts - 1 {
                    log?.recordRequest(
                        service: .appleBusiness, connection: connectionName, method: method,
                        path: loggedPath, status: status, duration: Date().timeIntervalSince(started),
                        requestBody: body, responseBody: data, withholdBodies: false
                    )
                    try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
                    continue
                }
                log?.recordRequest(
                    service: .appleBusiness, connection: connectionName, method: method,
                    path: loggedPath, status: status, duration: Date().timeIntervalSince(started),
                    requestBody: body, responseBody: data, withholdBodies: false
                )
                return (data, status)
            } catch {
                lastError = error
                let willRetry = attempt < Self.maximumAttempts - 1
                log?.recordFailure(
                    service: .appleBusiness, connection: connectionName, method: method,
                    path: loggedPath, duration: Date().timeIntervalSince(started),
                    message: willRetry
                        ? "\(error.localizedDescription) Retrying."
                        : error.localizedDescription
                )
                guard willRetry else { break }
                try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
            }
        }
        throw lastError ?? APIError(message: "Apple Business did not answer.")
    }

    /// 5s, 15s, 45s. Once the quota is spent Apple stays quiet for a while,
    /// so a short retry only wastes another request.
    private nonisolated static func backoff(_ attempt: Int) -> Double {
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
        throw APIError(message: "Apple Business: HTTP \(status)\(detail.isEmpty ? "" : " – \(detail)")")
    }

    // MARK: OAuth

    private func bearerToken() async throws -> String {
        if let cachedToken, cachedToken.expiry > Date() { return cachedToken.value }
        // Recorded, but never with its bodies: the request carries the signed
        // client assertion, which is itself a credential, and the response
        // carries the access token.
        do {
            let token = try await fetchToken()
            log?.recordSignIn(
                service: .appleBusiness,
                connection: connectionName,
                summary: "Signed in to Apple Business",
                outcome: .succeeded
            )
            return token
        } catch {
            log?.recordSignIn(
                service: .appleBusiness,
                connection: connectionName,
                summary: "Sign-in failed: \(error.localizedDescription)",
                outcome: .failed
            )
            throw error
        }
    }

    private func fetchToken() async throws -> String {
        let assertion = try makeClientAssertion()
        let params: [(String, String)] = [
            ("grant_type", "client_credentials"),
            ("client_id", clientID),
            ("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            ("client_assertion", assertion),
            ("scope", "business.api"),
        ]
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body(params)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "Apple Business sign-in failed: \(body.prefix(300))")
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

    private func makeClientAssertion() throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw APIError(message: "Could not read the Apple Business private key (expected a PEM-encoded EC P-256 key): \(error.localizedDescription)")
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
