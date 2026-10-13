import Foundation

@main struct PikPakRequestVerificationTests {
    @MainActor static func main() async throws {
        try callbackAndPrivateStore()
        try await DownloaderModel.testRequestVerificationStatus()
    }

    @MainActor static func callbackAndPrivateStore() throws {
        let now = Date()
        let challenge = PikPakVerificationChallenge(url: "https://user.mypikpak.com/verify?captcha_token=generated-initial&state=old",
            clientID: PikPakDesktopOAuth.clientID, deviceID: String(repeating: "a", count: 32),
            action: "GET:/drive/v1/files", expiresAt: now.timeIntervalSince1970 + 600)
        let raw = PikPakVerificationChallenge.diagnosticPrefix + String(decoding: try JSONEncoder().encode(challenge), as: UTF8.self)
        precondition(PikPakVerificationChallenge.fromEngine("context\n" + raw + "\nerror: additional verification") == challenge)
        let browser = URLComponents(url: try challenge.browserURL(state: "generated-state"), resolvingAgainstBaseURL: false)!
        precondition(browser.queryItems!.filter { $0.name == "state" }.map(\.value) == ["generated-state"])
        precondition(browser.queryItems!.first { $0.name == "redirect_uri" }?.value == PikPakRequestVerifier.callbackURL)
        let callback = URL(string: PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=generated-proof&expires_in=600")!
        let proof = try challenge.proof(from: callback, state: "generated-state", now: now)
        precondition(proof.clientID == challenge.clientID && proof.deviceID == challenge.deviceID && proof.action == challenge.action)
        precondition(proof.captchaToken == "generated-proof" && proof.expiresAt == now.timeIntervalSince1970 + 570)
        func requireFailure(_ work: () throws -> Void) {
            do { try work(); preconditionFailure("Unsafe or stale verification must fail") } catch { }
        }
        for value in [
            "wrong://shield/complete?state=generated-state&captcha_token=x&expires_in=600",
            PikPakRequestVerifier.callbackURL + "?state=other&captcha_token=x&expires_in=600",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&state=other&captcha_token=x&expires_in=600",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=x&captcha_token=y&expires_in=600",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=x&expires_in=0",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=x&expires_in=nan",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=x&expires_in=600&error=denied",
            PikPakRequestVerifier.callbackURL + "?state=generated-state&captcha_token=x&expires_in=600#ignored",
        ] { requireFailure { _ = try challenge.proof(from: URL(string: value)!, state: "generated-state", now: now) } }
        requireFailure { _ = try challenge.proof(from: callback, state: "generated-state", now: now.addingTimeInterval(601)) }
        for url in ["http://user.mypikpak.com/verify", "https://mypikpak.com.evil.test/", "https://user:pass@mypikpak.com/", "https://mypikpak.com:8443/"] {
            let invalid = PikPakVerificationChallenge(url: url, clientID: challenge.clientID, deviceID: challenge.deviceID, action: challenge.action, expiresAt: challenge.expiresAt)
            precondition(invalid.validURL(now: now) == nil)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GeneratedShield-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("verified-requests.json")
        try PikPakVerifiedRequestStore.save(proof, to: url, now: now)
        try PikPakVerifiedRequestStore.save(proof, to: url, now: now)
        let object = try JSONSerialization.jsonObject(with: PikPakAccountStore.readPrivateFile(url)) as! [String: Any]
        precondition((object["tokens"] as! [[String: Any]]).count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue & 0o777 == 0o600)
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        requireFailure { try PikPakVerifiedRequestStore.save(proof, to: link, now: now) }
        print("PASS shield callback: provider URL, correlation, expiry, cancellation-safe result validation, private scoped proof and symlink rejection")
    }
}
