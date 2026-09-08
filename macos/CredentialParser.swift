import Foundation

enum CredentialParserError: LocalizedError {
    case empty
    case accessToken
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a PikPak refresh token first."
        case .accessToken:
            return "That appears to be access_token. Copy refresh_token from the credentials entry instead."
        case .missingRefreshToken:
            return "The pasted credentials data does not contain refresh_token."
        }
    }
}

enum CredentialParser {
    /// Accept a raw refresh token, a JSON string copied from the console, or
    /// the complete PikPak `credentials_*` Local Storage JSON value.
    static func refreshToken(from input: String) throws -> String {
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw CredentialParserError.empty }

        if let data = candidate.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            if let dictionary = json as? [String: Any] {
                if let refresh = dictionary["refresh_token"] as? String,
                   !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidate = refresh
                } else if dictionary["access_token"] != nil {
                    throw CredentialParserError.missingRefreshToken
                }
            } else if let string = json as? String {
                candidate = string
            }
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw CredentialParserError.empty }

        let lowered = candidate.lowercased()
        let jwtParts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        if lowered.hasPrefix("bearer ") || (candidate.hasPrefix("eyJ") && jwtParts.count == 3) {
            throw CredentialParserError.accessToken
        }
        if candidate.contains("\"access_token\"") || candidate.contains("\"refresh_token\"") {
            throw CredentialParserError.missingRefreshToken
        }
        return candidate
    }
}
