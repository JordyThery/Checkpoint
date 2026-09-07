import Foundation

/// Percent-encodes key/value pairs as an `application/x-www-form-urlencoded`
/// request body, used by the OAuth token endpoints of both API clients.
nonisolated enum FormURLEncoding {
    static func body(_ params: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = params
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}
