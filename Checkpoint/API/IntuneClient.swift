import Foundation

// MARK: - Models

/// A device as Intune reports it, reduced to the fields Checkpoint shows.
///
/// Graph's `managedDevice` carries well over sixty properties, including a
/// large Windows health-attestation object, so every request asks for the
/// fields below by name. That keeps a fleet read to a fraction of its
/// unfiltered size and makes the activity log readable.
nonisolated struct IntuneDevice: Sendable {
    /// Intune's own managed device ID, which every action is addressed to.
    let id: String
    let serialNumber: String
    let deviceName: String?
    /// Platform name, e.g. macOS, iOS, iPadOS. Intune keeps one collection
    /// for every platform rather than splitting by device kind.
    let operatingSystem: String?
    let osVersion: String?
    let enrolledDateTime: String?
    let lastSyncDateTime: String?
    let managementCertificateExpirationDate: String?
    /// Whole-disk encryption. FileVault on a Mac, BitLocker on Windows, so it
    /// is only shown for the platforms Checkpoint reports on.
    let isEncrypted: Bool?
    let isSupervised: Bool?
    /// Management channel, e.g. `mdm` or `easMdm`. The one signal that says
    /// whether the device is still under MDM at all.
    let managementAgent: String?
    let complianceState: String?

    /// Computer or mobile device, from the platform.
    ///
    /// Intune draws no such distinction, so it is inferred. Windows lands with
    /// the computers: Checkpoint is for Apple fleets and will rarely see one,
    /// but the commands that would reach it are the computer ones.
    var kind: DeviceKind {
        switch operatingSystem?.lowercased() {
        case "macos", "windows": .computer
        default: .mobileDevice
        }
    }

    /// Whether Intune still manages the device. A retired or wiped device
    /// keeps its record for a while with the agent cleared.
    var isManaged: Bool? {
        guard let managementAgent, !managementAgent.isEmpty else { return nil }
        return managementAgent.lowercased().contains("mdm")
    }

    /// Compliance as a sentence rather than Graph's enumeration spelling.
    var complianceSummary: String? {
        guard let complianceState, !complianceState.isEmpty else { return nil }
        switch complianceState {
        case "compliant": return "Compliant"
        case "noncompliant": return "Not compliant"
        case "inGracePeriod": return "In grace period"
        case "configManager": return "Managed by Configuration Manager"
        case "unknown": return "Unknown"
        default: return DisplayText.sentenceCase(complianceState)
        }
    }
}

// MARK: - Client

/// Microsoft Graph client for Intune, scoped to what Checkpoint needs: read
/// the managed devices, send the device actions, delete a record.
///
/// Authentication is the Entra client-credentials flow, so the app acts as
/// itself rather than as a signed-in administrator. Graph therefore applies
/// application permissions, which is why every command needs
/// `DeviceManagementManagedDevices.PrivilegedOperations.All`.
///
/// Unlike Jamf Pro there is no filtering by serial number: Graph documents
/// `$filter` support per property, and `serialNumber` is not among them. The
/// fleet is read once per lookup and matched locally, the same shape Jamf
/// School takes for a different reason.
actor IntuneClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let graphHost = URL(string: "https://graph.microsoft.com")!
    private static let loginHost = URL(string: "https://login.microsoftonline.com")!

    private let tenantID: String
    private let clientID: String
    private let secret: String
    private let log: ActivityLog?
    /// Connection name, recorded with each entry so a log covering several
    /// connections says which one it went to.
    private let connectionName: String
    private var cachedToken: (value: String, expiry: Date)?

    init?(config: MDMConnection, secret: String, log: ActivityLog? = nil) {
        let tenant = config.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, !client.isEmpty, !key.isEmpty else { return nil }
        self.tenantID = tenant
        self.clientID = client
        self.secret = key
        self.log = log
        self.connectionName = config.displayName
    }

    // MARK: Devices

    /// Fields asked for by name on every device read. Anything not listed
    /// here is not shown, and several of Graph's properties are only ever
    /// populated on a single-device request anyway.
    ///
    /// `enrollmentProfileName` is deliberately absent. It reports the profile
    /// a device enrolled with, which is not the profile the console shows as
    /// assigned to it — a Mac enrolled before its ADE profile existed reports
    /// nothing here while the console names one. The assignment itself lives
    /// on the ADE token, which Graph serves only in beta.
    private static let deviceFields = [
        "id", "serialNumber", "deviceName", "operatingSystem", "osVersion",
        "enrolledDateTime", "lastSyncDateTime", "managementCertificateExpirationDate",
        "isEncrypted", "isSupervised", "managementAgent", "complianceState",
    ].joined(separator: ",")

    /// Every managed device in the tenant, keyed by serial number.
    ///
    /// Paged at Graph's maximum so a few thousand devices cost a handful of
    /// requests rather than one per device. Devices with no serial number are
    /// dropped: Checkpoint is keyed on serials throughout, and Intune reports
    /// an empty one for some virtual and personally-enrolled devices.
    func fleet() async throws -> [String: IntuneDevice] {
        var bySerial: [String: IntuneDevice] = [:]
        var next: URL? = nil
        var page = 0
        repeat {
            let (devices, following) = try await devicePage(url: next)
            for device in devices {
                let key = device.serialNumber.uppercased()
                // First wins, matching every other lookup path. A duplicate
                // serial means the same hardware enrolled twice.
                if bySerial[key] == nil { bySerial[key] = device }
            }
            next = following
            page += 1
            // A guard against a nextLink that never terminates, which would
            // otherwise loop for as long as the app is open.
            if page > Self.maximumPages { break }
        } while next != nil
        return bySerial
    }

    /// Enough for a fleet of a hundred thousand devices at Graph's page size.
    private static let maximumPages = 100

    private func devicePage(url: URL?) async throws -> ([IntuneDevice], URL?) {
        struct Response: Decodable {
            let value: [Item]
            /// Graph's own continuation URL, carrying its paging state. Passed
            /// back verbatim rather than rebuilt: it is opaque by contract.
            let nextLink: String?

            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }

            struct Item: Decodable {
                let id: String
                let serialNumber: String?
                let deviceName: String?
                let operatingSystem: String?
                let osVersion: String?
                let enrolledDateTime: String?
                let lastSyncDateTime: String?
                let managementCertificateExpirationDate: String?
                let isEncrypted: Bool?
                let isSupervised: Bool?
                let managementAgent: String?
                let complianceState: String?
            }
        }

        let (data, status): (Data, Int)
        if let url {
            (data, status) = try await send(absolute: url)
        } else {
            (data, status) = try await send(
                path: "/v1.0/deviceManagement/managedDevices",
                queryItems: [
                    URLQueryItem(name: "$select", value: Self.deviceFields),
                    URLQueryItem(name: "$top", value: "1000"),
                ]
            )
        }
        try throwIfError(status: status, data: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let devices = decoded.value.compactMap { item -> IntuneDevice? in
            guard let serial = item.serialNumber, !serial.isEmpty else { return nil }
            return IntuneDevice(
                id: item.id,
                serialNumber: serial,
                deviceName: item.deviceName,
                operatingSystem: item.operatingSystem,
                osVersion: item.osVersion,
                enrolledDateTime: item.enrolledDateTime,
                lastSyncDateTime: item.lastSyncDateTime,
                managementCertificateExpirationDate: item.managementCertificateExpirationDate,
                isEncrypted: item.isEncrypted,
                isSupervised: item.isSupervised,
                managementAgent: item.managementAgent,
                complianceState: item.complianceState
            )
        }
        return (devices, decoded.nextLink.flatMap(URL.init(string:)))
    }

    // MARK: Device actions

    /// Graph action names, each a POST to the device with no body.
    ///
    /// Every one of these is documented under
    /// `DeviceManagementManagedDevices.PrivilegedOperations.All`, including
    /// the non-destructive ones: Microsoft groups by what reaches the device,
    /// not by how much damage it does.
    nonisolated enum DeviceAction: String, Sendable {
        case sync = "syncDevice"
        case restart = "rebootNow"
        case shutDown = "shutDown"
        case remoteLock = "remoteLock"
        case resetPasscode = "resetPasscode"
        /// Removes company data and the management profile. The record goes
        /// once the device acknowledges, so this is the closest equivalent to
        /// removing an MDM profile, not to deleting a record.
        case retire = "retire"
    }

    func perform(_ action: DeviceAction, deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/v1.0/deviceManagement/managedDevices/\(deviceID)/\(action.rawValue)",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    /// Erases the device.
    ///
    /// Sent with an explicit empty body rather than none: the action takes
    /// optional parameters, all of which change what survives the wipe, and
    /// omitting them is what asks for a plain erase. `keepEnrollmentData` and
    /// `keepUserData` are deliberately not offered — Checkpoint's wipe means
    /// the same thing on every product it talks to.
    func wipe(deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/v1.0/deviceManagement/managedDevices/\(deviceID)/wipe",
            method: "POST",
            body: Data("{}".utf8)
        )
        try throwIfError(status: status, data: data)
    }

    /// Deletes the Intune record, leaving the device itself untouched. It will
    /// reappear if the device checks in again while still enrolled.
    func deleteDevice(id: String) async throws {
        let (data, status) = try await send(
            path: "/v1.0/deviceManagement/managedDevices/\(id)",
            method: "DELETE"
        )
        try throwIfError(status: status, data: data)
    }

    // MARK: Connection test

    /// Confirms the credentials and that the app registration may read
    /// devices.
    ///
    /// Asks for one device, which is the cheapest read that still exercises
    /// the permission. Deliberately no `$count`: that is an OData feature for
    /// directory objects, and asking for it here risks a 400 on the first
    /// thing anyone does with a new connection.
    func verify() async throws {
        let (data, status) = try await send(
            path: "/v1.0/deviceManagement/managedDevices",
            queryItems: [
                URLQueryItem(name: "$select", value: "id"),
                URLQueryItem(name: "$top", value: "1"),
            ]
        )
        try throwIfError(status: status, data: data)
    }

    // MARK: Transport

    private func send(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> (Data, Int) {
        guard var components = URLComponents(url: Self.graphHost, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid Microsoft Graph URL")
        }
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError(message: "Invalid Microsoft Graph request URL")
        }
        return try await perform(url: url, method: method, body: body)
    }

    /// For a URL Graph handed back, such as a paging continuation.
    private func send(absolute url: URL) async throws -> (Data, Int) {
        try await perform(url: url, method: "GET", body: nil)
    }

    private func perform(
        url: URL,
        method: String,
        body: Data?
    ) async throws -> (Data, Int) {
        let token = try await bearerToken()
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let loggedPath = [url.path(), url.query()].compactMap { $0 }.joined(separator: "?")
            let started = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                log?.recordRequest(
                    service: .intune,
                    connection: connectionName,
                    method: method,
                    path: loggedPath,
                    status: status,
                    duration: Date().timeIntervalSince(started),
                    requestBody: body,
                    responseBody: data,
                    withholdBodies: false
                )
                // Graph throttles per app per tenant and says how long to wait.
                // Retried a bounded number of times: a fleet read of several
                // pages, or a bulk command, can cross the limit legitimately.
                guard status == 429, attempt < Self.maximumRetries else { return (data, status) }
                attempt += 1
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(for: .seconds(min(retryAfter ?? 5, 30)))
            } catch {
                log?.recordFailure(
                    service: .intune,
                    connection: connectionName,
                    method: method,
                    path: loggedPath,
                    duration: Date().timeIntervalSince(started),
                    message: error.localizedDescription
                )
                throw error
            }
        }
    }

    private static let maximumRetries = 3

    private func throwIfError(status: Int, data: Data) throws {
        guard !(200...299).contains(status) else { return }
        struct Envelope: Decodable {
            let error: Failure?
            struct Failure: Decodable {
                let code: String?
                let message: String?
            }
        }
        let failure = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        // Graph's message is a sentence written for developers, and it names
        // the missing permission when that is the problem, so it is passed
        // through rather than replaced.
        let detail = [failure?.code, failure?.message]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " – ")
        throw APIError(message: "Intune: \(Self.explain(status))"
            + (detail.isEmpty ? "" : " (\(detail))"))
    }

    private static func explain(_ status: Int) -> String {
        switch status {
        case 401:
            return "HTTP 401. The app registration's credentials were rejected; check the tenant ID, client ID and secret, and whether the secret has expired."
        case 403:
            return "HTTP 403. The app registration is missing a permission, or admin consent has not been granted for it."
        case 404:
            return "HTTP 404. The device record no longer exists in Intune."
        case 429:
            return "HTTP 429. Microsoft Graph is throttling this app; try again shortly."
        default:
            return "HTTP \(status)"
        }
    }

    // MARK: Auth

    private func bearerToken() async throws -> String {
        if let cachedToken, cachedToken.expiry > Date() { return cachedToken.value }
        // Sign-ins are recorded, never their bodies: the request carries the
        // client secret and the response carries the token.
        do {
            let token = try await fetchToken()
            log?.recordSignIn(
                service: .intune,
                connection: connectionName,
                summary: "Signed in with the Entra app registration",
                outcome: .succeeded
            )
            return token
        } catch {
            log?.recordSignIn(
                service: .intune,
                connection: connectionName,
                summary: "Sign-in failed: \(error.localizedDescription)",
                outcome: .failed
            )
            throw error
        }
    }

    /// Entra client credentials. `.default` asks for every application
    /// permission the app registration has been granted and consented to,
    /// which is the only form the client-credentials flow accepts.
    private func fetchToken() async throws -> String {
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        struct TokenFailure: Decodable {
            let error: String?
            let error_description: String?
        }
        let url = Self.loginHost.appending(path: "/\(tenantID)/oauth2/v2.0/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body([
            ("client_id", clientID),
            ("client_secret", secret),
            ("grant_type", "client_credentials"),
            ("scope", "https://graph.microsoft.com/.default"),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Entra's error_description is long and starts with its own error
            // code, but its first line names the real fault, which is usually
            // a wrong tenant or an expired secret.
            let failure = try? JSONDecoder().decode(TokenFailure.self, from: data)
            let first = failure?.error_description?
                .split(separator: "\n", maxSplits: 1).first
                .map(String.init)
            throw APIError(message: "Intune sign-in failed (HTTP \(status)). "
                + (first ?? "Check the tenant ID, client ID and client secret."))
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Refreshed a minute early, so a long bulk action cannot have a token
        // expire underneath it.
        cachedToken = (token.access_token, Date().addingTimeInterval(TimeInterval(max(token.expires_in - 60, 60))))
        return token.access_token
    }
}
