import AppKit
import AuthenticationServices
import Foundation

/// The engine's interactive shield challenge is not a failed account login.
struct PikPakVerificationChallenge: Codable, Equatable {
    let url: String
    let clientID: String
    let deviceID: String
    let action: String
    let expiresAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case url, action, clientID = "client_id", deviceID = "device_id", expiresAt = "expires_at"
    }

    static let diagnosticPrefix = "PikPak verification required: "

    static func fromEngine(_ raw: String) -> Self? {
        for line in raw.suffix(131_072).split(separator: "\n") where line.hasPrefix(diagnosticPrefix) {
            let payload = line.dropFirst(diagnosticPrefix.count)
            guard payload.utf8.count <= 65_536,
                  let challenge = try? JSONDecoder().decode(Self.self, from: Data(payload.utf8)),
                  challenge.validURL() != nil else { continue }
            return challenge
        }
        return nil
    }

    func validURL(now: Date = Date()) -> URL? {
        guard url.utf8.count <= 32_768, let parsed = URLComponents(string: url),
              parsed.scheme == "https", let host = parsed.host?.lowercased(),
              host == "mypikpak.com" || host.hasSuffix(".mypikpak.com"),
              parsed.user == nil, parsed.password == nil, parsed.port == nil || parsed.port == 443,
              [PikPakDesktopOAuth.clientID, "YUMx5nI8ZU8Ap8pm"].contains(clientID),
              !deviceID.isEmpty, deviceID.utf8.count <= 128,
              deviceID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              action.range(of: #"^(GET|POST|PATCH|PUT|DELETE):/drive/v1/[A-Za-z0-9_/-]+$"#, options: .regularExpression) != nil,
              expiresAt > now.timeIntervalSince1970, expiresAt <= now.timeIntervalSince1970 + 901
        else { return nil }
        return parsed.url
    }

    func browserURL(state: String) throws -> URL {
        guard let url = validURL(), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PikPakRequestVerificationError.invalidChallenge
        }
        // PikPak's official captcha SDK adds these to the returned URL, rather
        // than to captcha/init. Use a fresh correlation value for each attempt.
        var query = components.queryItems ?? []
        query.removeAll { ["redirect_uri", "state"].contains($0.name) }
        query += [URLQueryItem(name: "redirect_uri", value: PikPakRequestVerifier.callbackURL),
                  URLQueryItem(name: "state", value: state)]
        components.queryItems = query
        guard let result = components.url else { throw PikPakRequestVerificationError.invalidChallenge }
        return result
    }

    func proof(from callback: URL, state: String, now: Date = Date()) throws -> PikPakVerifiedRequest {
        guard validURL(now: now) != nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == PikPakRequestVerifier.callbackScheme,
              components.host == "shield", components.path == "/complete",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { throw PikPakRequestVerificationError.invalidCallback }
        let items = components.queryItems ?? []
        func one(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard one("state") == state, !items.contains(where: { $0.name == "error" }),
              let token = one("captcha_token"), !token.isEmpty, token.utf8.count <= 16_384,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              let rawExpiry = one("expires_in"), let expiry = TimeInterval(rawExpiry), expiry.isFinite, expiry > 30
        else { throw PikPakRequestVerificationError.invalidCallback }
        return PikPakVerifiedRequest(clientID: clientID, deviceID: deviceID, action: action,
            captchaToken: token, expiresAt: now.timeIntervalSince1970 + min(expiry - 30, 1800))
    }
}

enum PikPakRequestVerificationError: LocalizedError {
    case required(PikPakVerificationChallenge), invalidChallenge, invalidCallback, couldNotOpen, cancelled
    var errorDescription: String? {
        switch self {
        case .required: return "PikPak needs verification before this request can continue. Choose Verify Request."
        case .invalidChallenge: return "This verification request expired or is unavailable. Retry the original request to get a new one."
        case .invalidCallback: return "PikPak did not return a valid verification result. Retry verification."
        case .couldNotOpen: return "Could not open the verification browser. Retry verification."
        case .cancelled: return "Verification cancelled. Your saved sign-in has been kept."
        }
    }
}

struct PikPakVerifiedRequest: Codable {
    let clientID: String
    let deviceID: String
    let action: String
    let captchaToken: String
    let expiresAt: TimeInterval
    enum CodingKeys: String, CodingKey {
        case action, clientID = "client_id", deviceID = "device_id", captchaToken = "captcha_token", expiresAt = "expires_at"
    }
}

enum PikPakVerifiedRequestStore {
    private struct Document: Codable { var version = 1; var tokens: [PikPakVerifiedRequest] }

    static func save(_ proof: PikPakVerifiedRequest, to url: URL, now: Date = Date()) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else { throw PikPakAccountError.invalidStorage }
        var tokens: [PikPakVerifiedRequest] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try PikPakAccountStore.readPrivateFile(url)
            guard data.count <= 262_144, let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1, document.tokens.count <= 64 else { throw PikPakAccountError.invalidStorage }
            tokens = document.tokens.filter { $0.expiresAt > now.timeIntervalSince1970
                && !($0.clientID == proof.clientID && $0.deviceID == proof.deviceID && $0.action == proof.action) }
        }
        tokens = Array(tokens.suffix(63)); tokens.append(proof)
        try PikPakAccountStore.writePrivateFile(try JSONEncoder().encode(Document(tokens: tokens)), to: url)
    }
}

/// System browser authentication keeps Keychain/password-manager integration.
/// Only the provider's single captcha callback is returned to the app.
@MainActor
final class PikPakRequestVerifier: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static let callbackScheme = "myclouddriver-verification"
    nonisolated static let callbackURL = "myclouddriver-verification://shield/complete"
    private var session: ASWebAuthenticationSession?
    private var generation = UUID()

    func start(_ challenge: PikPakVerificationChallenge, completion: @escaping (Result<PikPakVerifiedRequest, Error>) -> Void) {
        cancel()
        let attempt = generation
        let state = UUID().uuidString.lowercased()
        do {
            let url = try challenge.browserURL(state: state)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { [weak self] callback, error in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.session = nil
                    self.generation = UUID()
                    if let callback {
                        completion(Result { try challenge.proof(from: callback, state: state) })
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        completion(.failure(PikPakRequestVerificationError.cancelled))
                    } else { completion(.failure(PikPakRequestVerificationError.couldNotOpen)) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { self.session = nil; completion(.failure(PikPakRequestVerificationError.couldNotOpen)) }
        } catch { completion(.failure(error)) }
    }

    func cancel() { generation = UUID(); session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}
