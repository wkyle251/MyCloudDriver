import Foundation

@main struct PikPakBrowserLoginTests {
    @MainActor static func main() async throws {
        try await approvalAndRestoration()
        try await cancellation()
        try await failures()
    }

    private static func response(_ request: URLRequest, _ status: Int, _ value: [String: Any]) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: value),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static let approval: [String: Any] = [
        "device_code": "generated-approval-code", "expires_in": 300, "interval": 2,
        "verification_uri_complete": "https://mypikpak.com/drive/qr-login?user_code=generated",
    ]

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Browser approval fixture did not settle")
    }

    @MainActor static func approvalAndRestoration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserApproval-\(UUID())")
        let store = try PikPakAccountStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var requests: [URLRequest] = [], opens: [(URL, Bool)] = [], intervals: [TimeInterval] = []
        var polls = 0, sessions: [PikPakWebSession] = [], savedID: UUID?
        let login = PikPakBrowserLogin(request: { request in
            requests.append(request)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(request.value(forHTTPHeaderField: "X-Device-Id") == deviceID)
            if request.url!.path.hasSuffix("device/code") {
                precondition(body["scope"] == "user pan offline" && body["client_id"] == PikPakDesktopOAuth.clientID)
                precondition(body["client_secret"] == nil, "The browser never receives the app secret")
                return try response(request, 200, approval)
            }
            precondition(body["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
            precondition(body["device_code"] == "generated-approval-code")
            polls += 1
            switch polls {
            case 1: return try response(request, 400, ["error": "authorization_pending"])
            case 2: return try response(request, 400, ["error": "slow_down"])
            case 3: throw URLError(.timedOut)
            case 4: return try response(request, 503, ["error": "temporarily_unavailable"])
            default: return try response(request, 200, ["refresh_token": "fixture-browser-approved"])
            }
        }, openBrowser: { opens.append(($0, $1)) }, pause: {
            intervals.append($0); await Task.yield()
        })
        login.start(deviceID: deviceID, safari: true) { session in
            sessions.append(session)
            let files = try! store.stage(token: session.refreshToken, deviceID: session.deviceID, credentialKind: session.credentialKind)
            _ = try! store.commit(files, profile: .init(sub: "generated-browser-account", name: "Generated"))
            savedID = files.id
        }
        try await waitUntil { !login.isWorking }
        precondition(sessions.count == 1 && login.error == nil && login.verificationURL == nil)
        precondition(sessions[0].deviceID == deviceID && sessions[0].credentialKind == .desktopOAuth)
        precondition(opens.count == 1 && opens[0].1 && opens[0].0.host == "mypikpak.com")
        precondition(polls == 5 && requests.count == 6 && intervals == [2, 2, 7, 7, 7])
        let id = savedID!
        // Simulate a helper's atomic rotation, then a wholly new store after
        // quitting the app. Restoration must use the replacement, not the
        // original value held by the login view.
        try PikPakAccountStore.writePrivateFile(Data("fixture-browser-rotated".utf8), to: store.files(for: id).tokenURL)
        let reopened = try PikPakAccountStore(directory: root)
        let restored = try reopened.files(for: id).load()
        let restoredAccounts = try reopened.load()
        precondition(restored.token == "fixture-browser-rotated" && restored.deviceID == deviceID)
        precondition(restoredAccounts.accounts.first?.needsSignIn == false)
        login.cancel()
        print("PASS browser approval: pending/backoff/network recovery, one delivery, consistent device identity, rotated session survives restart")
    }

    @MainActor static func cancellation() async throws {
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var captured: URLRequest?, opens = 0, deliveries = 0
        let login = PikPakBrowserLogin(request: { request in
            captured = request
            return try await withCheckedThrowingContinuation { pending = $0 }
        }, openBrowser: { _, _ in opens += 1 }, pause: { _ in await Task.yield() })
        login.start(deviceID: String(repeating: "a", count: 32), safari: true) { _ in deliveries += 1 }
        try await waitUntil { pending != nil }
        login.cancel()
        pending!.resume(returning: try response(captured!, 200, approval))
        for _ in 0..<10 { await Task.yield() }
        precondition(opens == 0 && deliveries == 0 && !login.isWorking && login.verificationURL == nil)

        var tokenReply: CheckedContinuation<(Data, URLResponse), Error>?
        var tokenRequest: URLRequest?
        let waiting = PikPakBrowserLogin(request: { request in
            if request.url!.path.hasSuffix("device/code") { return try response(request, 200, approval) }
            tokenRequest = request
            return try await withCheckedThrowingContinuation { tokenReply = $0 }
        }, openBrowser: { _, _ in }, pause: { _ in await Task.yield() })
        waiting.start(deviceID: String(repeating: "b", count: 32), safari: false) { _ in deliveries += 1 }
        try await waitUntil { tokenReply != nil }
        waiting.cancel()
        tokenReply!.resume(returning: try response(tokenRequest!, 200, ["refresh_token": "fixture-late-token"]))
        for _ in 0..<10 { await Task.yield() }
        precondition(deliveries == 0 && !waiting.isWorking && waiting.verificationURL == nil)
        print("PASS cancelled browser approvals ignore late device and token responses")
    }

    @MainActor static func failures() async throws {
        for url in ["http://mypikpak.com/drive", "https://mypikpak.com.evil.invalid/", "https://user:secret@mypikpak.com/",
                    "https://mypikpak.com:8443/", "file:///tmp/generated", "https://evil.invalid/?return=https://mypikpak.com"] {
            precondition(PikPakBrowserLogin.validVerificationURL(url) == nil)
        }
        precondition(PikPakBrowserLogin.validVerificationURL("https://mypikpak.com/drive/qr-login") != nil)
        for kind in 0..<4 {
            var opens = 0, deliveries = 0
            let login = PikPakBrowserLogin(request: { request in
                if kind == 0 { return try response(request, 403, ["error": "permission_denied"]) }
                var value = approval
                if kind == 1 { value["verification_uri_complete"] = "https://evil.invalid/" }
                if kind == 2 { value["expires_in"] = 0 }
                if request.url!.path.hasSuffix("device/code") { return try response(request, 200, value) }
                return try response(request, 400, ["error": "access_denied"])
            }, openBrowser: { _, _ in opens += 1 }, pause: { _ in await Task.yield() })
            login.start(deviceID: String(repeating: "c", count: 32), safari: true) { _ in deliveries += 1 }
            try await waitUntil { !login.isWorking }
            precondition(login.error != nil && login.verificationURL == nil && deliveries == 0)
            precondition(opens == (kind == 3 ? 1 : 0))
        }
        print("PASS invalid, untrusted, expired and declined approvals cannot save a session")
    }
}
