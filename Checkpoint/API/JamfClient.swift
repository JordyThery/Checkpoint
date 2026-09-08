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
    /// Last Contact (binary, MDM, or DDM — inventory attribute added in Jamf Pro 11.30).
    let lastContact: String?
    let lastEnrolledDate: String?
    /// Last inventory update.
    let reportDate: String?
    let mdmProfileExpiration: String?
    let siteID: String?
    let siteName: String?
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
}

struct JamfSite: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
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
        case .mobileDevice: ["v2", "v1"]
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
    private var cachedToken: (value: String, expiry: Date)?

    init?(config: JamfServerConfig, secret: String) {
        guard let url = URL(string: config.normalizedBaseURL), url.host() != nil else { return nil }
        self.baseURL = url
        self.authMethod = config.authMethod
        self.account = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
    }

    // MARK: Computers

    func computer(serial: String) async throws -> JamfComputerRecord? {
        // v3 is the current computers-inventory endpoint; fall back to v1 for
        // older Jamf Pro versions.
        do {
            return try await computerLookup(apiVersion: "v3", serial: serial)
        } catch {
            return try await computerLookup(apiVersion: "v1", serial: serial)
        }
    }

    private func computerLookup(apiVersion: String, serial: String) async throws -> JamfComputerRecord? {
        struct Response: Decodable {
            let results: [Item]
            struct Item: Decodable {
                let id: String
                let udid: String?
                let general: General?
            }
            struct General: Decodable {
                let name: String?
                let lastContactTime: String?
                let lastEnrolledDate: String?
                let reportDate: String?
                // v1 name / v3 name for the same value.
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
        let (data, status) = try await send(
            path: "/api/\(apiVersion)/computers-inventory",
            queryItems: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "page-size", value: "10"),
                URLQueryItem(name: "filter", value: "hardware.serialNumber==\"\(serial)\""),
            ]
        )
        try throwIfError(status: status, data: data)
        guard let item = try JSONDecoder().decode(Response.self, from: data).results.first else { return nil }

        // Computers have no distinct Last Contact field in the API —
        // lastContactTime is the check-in. Accept any future general key
        // starting with "lastContact" other than the check-in field, so a
        // dedicated attribute is picked up automatically if Jamf adds one.
        var lastContact: String?
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            lastContactTime: item.general?.lastContactTime,
            lastContact: lastContact,
            lastEnrolledDate: item.general?.lastEnrolledDate,
            reportDate: item.general?.reportDate,
            mdmProfileExpiration: item.general?.mdmProfileExpiration ?? item.general?.mdmCertificateExpiration,
            siteID: item.general?.site?.id,
            siteName: item.general?.site?.name
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
            }
            var unlockToken: String? {
                [ios, tvos, watchos, visionos].compactMap { $0?.unlockToken }.first { !$0.isEmpty }
            }
        }
        var detail: Detail?
        if let (detailData, detailStatus) = try? await send(path: "/api/v2/mobile-devices/\(general.id)/detail"),
           (200...299).contains(detailStatus) {
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
            unlockToken: detail?.unlockToken
        )
    }

    func deleteMobileDevice(id: String) async throws {
        let (data, status) = try await send(path: "/JSSResource/mobiledevices/id/\(id)", method: "DELETE")
        try throwIfError(status: status, data: data)
    }

    // MARK: MDM commands

    /// Sends a Classic API computer command (e.g. DeviceLock, EraseDevice,
    /// BlankPush). Lock and erase require a 6-digit passcode.
    func sendComputerCommand(_ command: String, computerID: String, passcode: String? = nil) async throws {
        var path = "/JSSResource/computercommands/command/\(command)"
        if let passcode { path += "/passcode/\(passcode)" }
        path += "/id/\(computerID)"
        let (data, status) = try await send(path: path, method: "POST")
        try throwIfError(status: status, data: data)
    }

    /// Sends a Classic API mobile device command (e.g. UpdateInventory,
    /// DeviceLock, ClearPasscode, RestartDevice, EraseDevice, BlankPush).
    func sendMobileDeviceCommand(_ command: String, deviceID: String) async throws {
        let (data, status) = try await send(
            path: "/JSSResource/mobiledevicecommands/command/\(command)/id/\(deviceID)",
            method: "POST"
        )
        try throwIfError(status: status, data: data)
    }

    /// Sends an MDM command through the modern endpoint. Jamf Pro removed the
    /// security-sensitive commands (lock, wipe, clear passcode, restart) from
    /// the Classic API, which now rejects them with HTTP 400.
    func sendModernCommand(commandData: [String: any Sendable], managementIDs: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "clientData": managementIDs.map { ["managementId": $0] },
            "commandData": commandData,
        ] as [String: Any])
        let (data, status) = try await send(path: "/api/v2/mdm/commands", method: "POST", body: body)
        try throwIfError(status: status, data: data)
    }

    /// Renews the MDM enrollment profile for the given device UDIDs.
    func renewMDMProfile(udids: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["udids": udids])
        let (data, status) = try await send(path: "/api/v1/mdm/renew-profile", method: "POST", body: body)
        try throwIfError(status: status, data: data)
    }

    /// Sends a blank push to the given management IDs — the same endpoint the
    /// Jamf Pro UI uses, which surfaces as a DeclarativeManagement entry in
    /// the device's management history. Returns the management IDs the server
    /// could not push to.
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
            // A failure here means this API version isn't served — try the next one.
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

    private func send(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> (Data, Int) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid Jamf Pro server URL")
        }
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw APIError(message: "Invalid Jamf Pro request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
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
        switch authMethod {
        case .apiClient:
            return try await fetchOAuthToken()
        case .usernamePassword:
            return try await fetchBasicAuthToken()
        }
    }

    private func fetchOAuthToken() async throws -> String {
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        var request = URLRequest(url: baseURL.appending(path: "/api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body([
            ("client_id", account),
            ("client_secret", secret),
            ("grant_type", "client_credentials"),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(message: "Jamf Pro sign-in failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the API client ID and secret.")
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
