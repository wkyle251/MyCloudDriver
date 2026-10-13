import Foundation

/// Share paths and access-code components retain their exact spelling. Only
/// the URL scheme and DNS host have case-insensitive identity.
enum SharedLinkIdentity {
    static func key(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme, let host = components.host else { return value }
        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        return components.string ?? value
    }

    static func equivalent(_ first: String, _ second: String) -> Bool {
        key(first) == key(second)
    }
}
