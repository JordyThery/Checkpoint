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
    }

    private let clientID: String
    private let keyID: String
    private let privateKeyPEM: String
    private let baseURL = URL(string: "https://api-business.apple.com")!
    private let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/v2/token")!
    private var cachedToken: (value: String, expiry: Date)?

    init(clientID: String, keyID: String, privateKeyPEM: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKeyPEM = privateKeyPEM
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

    // MARK: Activities

    /// Submits an org device activity. ABM processes these asynchronously,
    /// so the new state may take a moment to become visible.
    func submitActivity(_ type: ActivityType, serials: [String], mdmServerID: String? = nil) async throws {
        var relationships: [String: Any] = [
            "devices": ["data": serials.map { ["type": "orgDevices", "id": $0] }]
        ]
        if let mdmServerID {
            relationships["mdmServer"] = ["data": ["type": "mdmServers", "id": mdmServerID]]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [
                "type": "orgDeviceActivities",
                "attributes": ["activityType": type.rawValue],
                "relationships": relationships,
            ]
        ])
        let (data, status) = try await send(path: "/v1/orgDeviceActivities", method: "POST", body: body)
        try throwIfError(status: status, data: data)
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

    private func send(url: URL, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
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
            throw APIError(message: "Could not read the ABM private key (expected a PEM-encoded EC P-256 key): \(error.localizedDescription)")
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
