import AppKit
import SwiftUI
import WebKit

struct PikPakWebSession {
    let refreshToken: String
    let deviceID: String
    var credentialKind: PikPakCredentialKind = .desktopOAuth
}

/// Asynchronous broker and token responses belong to one visible login attempt.
struct PikPakLoginAttemptState {
    private(set) var id = UUID()
    private(set) var isActive = false

    mutating func begin(active: Bool) {
        id = UUID()
        isActive = active
    }

    func accepts(_ capturedID: UUID) -> Bool { isActive && id == capturedID }
}

enum PikPakDesktopOAuth {
    static let clientID = "YvtoWO6GNHiuCl7x"
    /// Injected from ignored local configuration when the app is built.
    /// The credential is never stored in the repository or logged.
    static let clientSecret = ProcessInfo.processInfo.environment["PIKPAK_DESKTOP_CLIENT_SECRET"]
        ?? Bundle.main.object(forInfoDictionaryKey: "PikPakDesktopClientSecret") as? String
        ?? ""
    static let clientVersion = "2.6.11.4955"
    static let sdkVersion = "8.0.3"
    static let redirectURI = "https://pc.mypikpak.com"
    static let scope = "user+pan+offline"
    static let userAgent = "MainWindow Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) PikPak/2.6.11.4955 "
        + "Chrome/100.0.4896.160 Electron/18.3.15 Safari/537.36"
}

enum PikPakLoginDataStore {
    /// The embedded page is only an authorization broker. Its cookies and Web
    /// refresh token stay in memory long enough to request a first-party
    /// desktop authorization code, then disappear with the login window. The
    /// resulting desktop refresh token is stored separately by the native app.
    static let appOnly = WKWebsiteDataStore.nonPersistent()

    /// Clear both the disposable broker and the persistent WebKit store used
    /// by older app builds. WebKit scopes `.default()` to this app's bundle,
    /// so neither store can touch Safari's cookies or Local Storage.
    static func clearPikPakWebsiteData(completion: @escaping () -> Void = {}) {
        clear(
            stores: [appOnly, WKWebsiteDataStore.default()],
            completion: completion
        )
    }

    /// Launch migration for old app-owned Web sessions. Keeping this separate
    /// avoids clearing the live nonpersistent broker while its page is opening.
    static func clearLegacyPersistentPikPakWebsiteData() {
        clear(stores: [WKWebsiteDataStore.default()])
    }

    private static func clear(
        stores: [WKWebsiteDataStore],
        completion: @escaping () -> Void = {}
    ) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()

        for store in stores {
            group.enter()
            store.fetchDataRecords(ofTypes: dataTypes) { records in
                let pikpakRecords = records.filter {
                    let name = $0.displayName.lowercased()
                    return name == "mypikpak.com" || name.hasSuffix(".mypikpak.com")
                }
                guard !pikpakRecords.isEmpty else {
                    group.leave()
                    return
                }
                store.removeData(ofTypes: dataTypes, for: pikpakRecords) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main, execute: completion)
    }
}

/// Device approval leaves password entry, passkeys and AutoFill in the user's
/// browser. Only the separately issued desktop refresh token reaches the app.
@MainActor final class PikPakBrowserLogin: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var verificationURL: URL?
    @Published private(set) var status = "Sign in on PikPak’s website, then approve this connection."
    @Published private(set) var error: String?

    typealias Request = (URLRequest) async throws -> (Data, URLResponse)
    typealias OpenBrowser = (URL, Bool) async throws -> Void
    private let request: Request
    private let openBrowser: OpenBrowser
    private let pause: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var attempt = PikPakLoginAttemptState()

    init(request: Request? = nil, openBrowser: OpenBrowser? = nil,
         pause: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        self.request = request ?? { try await session.data(for: $0) }
        self.openBrowser = openBrowser ?? { url, safari in
            if safari {
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
                    throw BrowserLoginError.message("Safari is unavailable. Choose Use Default Browser instead.")
                }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: application,
                    configuration: NSWorkspace.OpenConfiguration())
            } else if !NSWorkspace.shared.open(url) {
                throw BrowserLoginError.message("Could not open your browser. Try Safari instead.")
            }
        }
        self.pause = pause
    }

    func start(deviceID: String, safari: Bool, onSession: @escaping (PikPakWebSession) -> Void) {
        cancel()
        attempt.begin(active: true)
        let id = attempt.id
        isWorking = true
        error = nil
        status = "Preparing secure browser sign-in…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.attempt.accepts(id) { self.isWorking = false; self.task = nil } }
            do {
                guard PikPakAccountSessionFiles.validDeviceID(deviceID) else {
                    throw BrowserLoginError.message("The app device identity is unavailable. Close and reopen sign-in.")
                }
                let (data, response) = try await self.request(Self.makeRequest("device/code", deviceID: deviceID,
                    body: ["client_id": PikPakDesktopOAuth.clientID, "scope": "user pan offline"]))
                try self.checkAttempt(id)
                try Self.requireSuccess(response, data: data)
                let approval = try JSONDecoder().decode(BrowserDeviceApproval.self, from: data)
                guard let url = Self.validVerificationURL(approval.verificationURI),
                      !approval.deviceCode.isEmpty, approval.deviceCode.utf8.count <= 65_536,
                      (1...1800).contains(approval.expiresIn) else {
                    throw BrowserLoginError.message("PikPak returned an invalid approval page. Try again.")
                }
                self.verificationURL = url
                self.status = "Waiting for you to approve the connection in your browser…"
                try await self.openBrowser(url, safari)
                try self.checkAttempt(id)
                let deadline = Date().addingTimeInterval(TimeInterval(approval.expiresIn))
                var interval = TimeInterval(min(60, max(1, approval.interval)))
                while Date() < deadline {
                    try await self.pause(interval)
                    try self.checkAttempt(id)
                    guard Date() < deadline else { break }
                    let result: (Data, URLResponse)
                    do {
                        result = try await self.request(Self.makeRequest("token", deviceID: deviceID, body: [
                            "client_id": PikPakDesktopOAuth.clientID,
                            "client_secret": PikPakDesktopOAuth.clientSecret,
                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                            "device_code": approval.deviceCode,
                        ]))
                    } catch let failure as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(failure.code) {
                        try self.checkAttempt(id)
                        self.status = "Connection interrupted. Waiting to reconnect…"
                        interval = max(5, interval)
                        continue
                    }
                    try self.checkAttempt(id)
                    let (tokenData, tokenResponse) = result
                    let http = tokenResponse as? HTTPURLResponse
                    if http.map({ (200...299).contains($0.statusCode) }) == true {
                        let tokens = try JSONDecoder().decode(DesktopTokenResponse.self, from: tokenData)
                        let token = try PikPakCredentialKind.desktopOAuth.parse(tokens.refreshToken)
                        self.status = "Browser sign-in complete. Saving this connection…"
                        self.verificationURL = nil
                        onSession(.init(refreshToken: token, deviceID: deviceID))
                        return
                    }
                    let failure = try? JSONDecoder().decode(BrowserOAuthFailure.self, from: tokenData)
                    if failure?.error == "authorization_pending" {
                        self.status = "Waiting for you to approve the connection in your browser…"
                        continue
                    }
                    if failure?.error == "slow_down" || http?.statusCode == 429 {
                        interval = min(60, interval + 5)
                        continue
                    }
                    if http.map({ (500...599).contains($0.statusCode) }) == true {
                        interval = max(5, interval)
                        self.status = "PikPak is temporarily unavailable. Retrying approval…"
                        continue
                    }
                    try Self.requireSuccess(tokenResponse, data: tokenData)
                }
                throw BrowserLoginError.message("This approval expired. Choose Continue in Safari to start again.")
            } catch {
                guard self.attempt.accepts(id), !Task.isCancelled else { return }
                self.verificationURL = nil
                self.error = (error as? BrowserLoginError)?.localizedDescription
                    ?? "Could not finish browser sign-in. Check your connection and try again."
                self.status = "Browser sign-in was not completed."
            }
        }
    }

    func reopen(safari: Bool) {
        guard let url = verificationURL else { return }
        let id = attempt.id
        Task {
            do { try await openBrowser(url, safari) }
            catch {
                guard attempt.accepts(id) else { return }
                self.error = (error as? BrowserLoginError)?.localizedDescription ?? "Could not reopen your browser."
            }
        }
    }

    func cancel() {
        attempt.begin(active: false)
        task?.cancel()
        task = nil
        isWorking = false
        verificationURL = nil
        error = nil
    }

    private func checkAttempt(_ id: UUID) throws {
        guard attempt.accepts(id), !Task.isCancelled else { throw CancellationError() }
    }

    static func validVerificationURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "mypikpak.com" || host.hasSuffix(".mypikpak.com"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private static func makeRequest(_ path: String, deviceID: String, body: [String: String]) throws -> URLRequest {
        var components = URLComponents(string: "https://user.mypikpak.com/v1/auth/\(path)")!
        components.queryItems = [URLQueryItem(name: "client_id", value: PikPakDesktopOAuth.clientID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("", forHTTPHeaderField: "User-Agent")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        return request
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BrowserLoginError.message("PikPak returned an invalid response. Try again.")
        }
        guard (200...299).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(BrowserOAuthFailure.self, from: data)
            switch failure?.error {
            case "access_denied": throw BrowserLoginError.message("The connection was declined in the browser. Try again when ready.")
            case "expired_token": throw BrowserLoginError.message("This approval expired. Start browser sign-in again.")
            default: throw BrowserLoginError.message("PikPak could not complete browser sign-in (HTTP \(http.statusCode)). Try again or use Sign in Here.")
            }
        }
    }
}

private struct BrowserDeviceApproval: Decodable {
    let deviceCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", verificationURI = "verification_uri_complete"
        case expiresIn = "expires_in", interval
    }
}

private struct BrowserOAuthFailure: Decodable { let error: String? }
private enum BrowserLoginError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

struct PikPakLoginView: View {
    let reason: String
    let currentDeviceID: String
    var initialCredentialKind: PikPakCredentialKind = .desktopOAuth
    let onSession: (PikPakWebSession) -> Void
    let onCancel: () -> Void

    @State private var pageStatus = "Opening PikPak Web Drive…"
    @State private var pageErrorDetails: String?
    @State private var reloadRequest = 0
    @State private var credentialKind: PikPakCredentialKind = .desktopOAuth
    @State private var usesEmbeddedSignIn = false
    @StateObject private var browserLogin = PikPakBrowserLogin()

    init(reason: String, currentDeviceID: String, initialCredentialKind: PikPakCredentialKind = .desktopOAuth,
         onSession: @escaping (PikPakWebSession) -> Void, onCancel: @escaping () -> Void) {
        self.reason = reason
        self.currentDeviceID = currentDeviceID
        self.initialCredentialKind = initialCredentialKind
        self.onSession = onSession
        self.onCancel = onCancel
        _credentialKind = State(initialValue: initialCredentialKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Connection method", selection: $credentialKind) {
                Text("PikPak Sign-in").tag(PikPakCredentialKind.desktopOAuth)
                Text("Personal Access Token").tag(PikPakCredentialKind.personalAccessToken)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Connection method")
            .frame(width: 370)
            .padding(.top, 20)
            if credentialKind == .personalAccessToken {
                PikPakPersonalAccessTokenView(currentDeviceID: currentDeviceID, onSession: onSession, onCancel: onCancel)
            } else if !usesEmbeddedSignIn {
                browserLoginBody
            } else {
                webLoginBody
            }
        }
        .onChange(of: credentialKind) { _ in browserLogin.cancel() }
        .onChange(of: usesEmbeddedSignIn) { _ in browserLogin.cancel() }
        .onDisappear { browserLogin.cancel() }
    }

    private var browserLoginBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sign in to PikPak", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text(reason).foregroundStyle(.secondary)
            Text("Use Safari for Sign in with Apple and Touch ID, Passwords, iCloud Keychain or passkeys. Approve the connection on PikPak’s website; this app will continue automatically.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if browserLogin.isWorking { ProgressView().controlSize(.small) }
                Text(browserLogin.status).font(.callout).foregroundStyle(.secondary)
            }
            if let error = browserLogin.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(browserLogin.verificationURL == nil ? "Continue in Safari" : "Open Safari Again") {
                    continueInBrowser(safari: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(browserLogin.isWorking && browserLogin.verificationURL == nil)
                Button("Use Default Browser") { continueInBrowser(safari: false) }
                    .disabled(browserLogin.isWorking && browserLogin.verificationURL == nil)
            }
            Text("Your browser handles passwords. MyCloudDriver saves a separate connection on this Mac, so you can stay signed in after closing the app.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Sign in Here") { usesEmbeddedSignIn = true }
                    .help("Use the embedded sign-in page if browser approval is unavailable")
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 590)
    }

    private func continueInBrowser(safari: Bool) {
        if browserLogin.verificationURL != nil { browserLogin.reopen(safari: safari) }
        else { browserLogin.start(deviceID: currentDeviceID, safari: safari, onSession: onSession) }
    }

    private var webLoginBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to PikPak")
                        .font(.title2.weight(.semibold))
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Label(
                "Sign in on PikPak’s page below. You can manage your saved accounts in Settings.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("Use Safari for Apple & Touch ID") { usesEmbeddedSignIn = false }
                .font(.callout)

            PikPakLoginWebView(
                status: $pageStatus,
                errorDetails: $pageErrorDetails,
                reloadRequest: reloadRequest,
                currentDeviceID: currentDeviceID,
                onSession: onSession
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        pageStatus,
                        systemImage: pageErrorDetails == nil
                            ? "globe"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(pageErrorDetails == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                    if let pageErrorDetails {
                        Text(pageErrorDetails)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Use Browser") { usesEmbeddedSignIn = false }
                if let pageErrorDetails {
                    Button {
                        copyLoginError(pageErrorDetails)
                    } label: {
                        Label("Copy Error", systemImage: "doc.on.doc")
                    }
                    .help("Copy the error code and message")
                    Button("Try Again") {
                        reloadRequest += 1
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Reload") {
                        reloadRequest += 1
                    }
                }
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 680)
    }

    private func copyLoginError(_ details: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(pageStatus)\n\(details)", forType: .string)
    }
}

struct PikPakPersonalAccessTokenView: View {
    let currentDeviceID: String
    let onSession: (PikPakWebSession) -> Void
    let onCancel: () -> Void
    @State private var token = ""
    @State private var error: String?
    @FocusState private var tokenIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: FinderSymbolImage.template(named: "key.fill", style: .settingsTab))
                    .foregroundStyle(FinderAppearance.accent)
                    .frame(width: 48, height: 48)
                    .background(FinderAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect with a token").font(.title2.weight(.semibold))
                    Text("Use a Personal Access Token created by PikPak.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("1. Create a token in PikPak").font(.headline)
                Text("Open Account & Security → Connected Apps → Personal Access Tokens. Name it MyCloudDriver and choose an expiry.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Read files covers downloads, previews and similarity scans. Moving, uploading or deleting files needs additional permissions.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Open PikPak Account & Security ↗", destination: URL(string: "https://mypikpak.com/drive/account")!)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("2. Paste your token here").font(.headline)
                SecureField("Personal Access Token", text: $token)
                    .textFieldStyle(.roundedBorder).focused($tokenIsFocused)
                    .accessibilityLabel("Personal Access Token")
                    .onSubmit(connect)
                    .onChange(of: token) { _ in error = nil }
                Text("Stored privately on this Mac after checking your account. Your normal login stays saved.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("Connected Apps transfer allowance", systemImage: "info.circle")
                    .font(.callout.weight(.semibold))
                Text("PikPak gives Connected Apps a shared 25% of your account’s transfer quota. Token usage also counts toward the account total.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Verify & Connect", action: connect)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
        .onAppear { tokenIsFocused = true }
        .onDisappear { token = "" }
    }

    private func connect() {
        do {
            let parsed = try CredentialParser.personalAccessToken(from: token)
            token = ""
            onSession(.init(refreshToken: parsed, deviceID: currentDeviceID, credentialKind: .personalAccessToken))
        } catch { self.error = error.localizedDescription }
    }
}

private struct PikPakLoginWebView: NSViewRepresentable {
    @Binding var status: String
    @Binding var errorDetails: String?
    let reloadRequest: Int
    let currentDeviceID: String
    let onSession: (PikPakWebSession) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PikPakLoginDataStore.appOnly
        if let bootstrapScript = Coordinator.webDeviceBootstrapScript() {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: bootstrapScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        context.coordinator.loadPikPakDrive()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadRequest != reloadRequest else { return }
        context.coordinator.lastReloadRequest = reloadRequest
        context.coordinator.loadPikPakDrive()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: PikPakLoginWebView
        var lastReloadRequest: Int

        private weak var webView: WKWebView?
        private var tokenTimer: Timer?
        private var deliveredSession = false
        private var desktopAuthorizationInFlight = false
        private var desktopAuthorizationAttempted = false
        private var desktopExchangeTask: URLSessionDataTask?
        private var desktopTokenSession: URLSession?
        private var attemptState = PikPakLoginAttemptState()

        init(parent: PikPakLoginWebView) {
            self.parent = parent
            lastReloadRequest = parent.reloadRequest
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            tokenTimer?.invalidate()
            tokenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.inspectForAuthenticatedWebSession()
            }
        }

        func stop() {
            attemptState.begin(active: false)
            tokenTimer?.invalidate()
            tokenTimer = nil
            desktopExchangeTask?.cancel()
            desktopExchangeTask = nil
            desktopTokenSession?.invalidateAndCancel()
            desktopTokenSession = nil
            webView = nil
        }

        func loadPikPakDrive() {
            attemptState.begin(active: webView != nil)
            deliveredSession = false
            desktopAuthorizationInFlight = false
            desktopAuthorizationAttempted = false
            desktopExchangeTask?.cancel()
            desktopExchangeTask = nil
            desktopTokenSession?.invalidateAndCancel()
            desktopTokenSession = nil
            guard let url = URL(string: "https://mypikpak.com/drive/all") else { return }
            parent.errorDetails = nil
            parent.status = "Opening PikPak Web Drive…"
            webView?.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            updateStatus(for: webView.url, loading: true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateStatus(for: webView.url, loading: false)
            inspectForAuthenticatedWebSession()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            reportPageLoadFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            reportPageLoadFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func updateStatus(for url: URL?, loading: Bool) {
            guard attemptState.isActive else { return }
            parent.errorDetails = nil
            guard let host = url?.host?.lowercased(), !host.isEmpty else {
                parent.status = loading ? "Loading PikPak sign-in…" : "Waiting for PikPak sign-in…"
                return
            }
            parent.status = loading ? "Loading \(host)…" : "Viewing \(host)"
        }

        private func inspectForAuthenticatedWebSession() {
            guard
                attemptState.isActive,
                !deliveredSession,
                !desktopAuthorizationInFlight,
                !desktopAuthorizationAttempted,
                let webView,
                Self.isPikPakHost(webView.url?.host)
            else { return }

            let attempt = attemptState.id
            webView.evaluateJavaScript(Self.authenticationStateScript) { [weak self] result, _ in
                guard
                    let self,
                    self.attemptState.accepts(attempt), self.webView === webView,
                    !self.deliveredSession,
                    let values = result as? [String: Any],
                    values["signedIn"] as? Bool == true
                else { return }

                self.requestDesktopAuthorization(using: webView)
            }
        }

        private func requestDesktopAuthorization(using webView: WKWebView) {
            guard
                attemptState.isActive,
                !deliveredSession,
                !desktopAuthorizationInFlight,
                !desktopAuthorizationAttempted
            else { return }

            desktopAuthorizationInFlight = true
            desktopAuthorizationAttempted = true
            parent.errorDetails = nil
            parent.status = "Creating an independent desktop session…"
            let attempt = attemptState.id

            webView.callAsyncJavaScript(
                Self.desktopAuthorizationScript,
                arguments: [:],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self, self.attemptState.accepts(attempt), self.webView === webView, !self.deliveredSession else { return }

                switch result {
                case .success(let rawValue):
                    guard let values = rawValue as? [String: Any] else {
                        self.failDesktopAuthorization(
                            "PikPak did not return a desktop authorization. Choose Reload to try again."
                        )
                        return
                    }
                    if values["ready"] as? Bool != true {
                        // PikPak's login SDK can appear shortly after the
                        // document load event. Let the timer poll again.
                        self.desktopAuthorizationInFlight = false
                        self.desktopAuthorizationAttempted = false
                        self.parent.status = "Signed in. Waiting for PikPak authorization…"
                        return
                    }
                    guard
                        let code = values["code"] as? String,
                        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        self.failDesktopAuthorization(
                            "Desktop authorization was not completed. Choose Reload to try again."
                        )
                        return
                    }
                    self.exchangeDesktopAuthorizationCode(
                        code.trimmingCharacters(in: .whitespacesAndNewlines)
                    )

                case .failure(let error):
                    self.failDesktopAuthorization(
                        "Could not create the independent desktop session. Choose Try Again to retry.",
                        code: "WEBKIT_JAVASCRIPT_ERROR",
                        detailMessage: error.localizedDescription
                    )
                }
            }
        }

        private func exchangeDesktopAuthorizationCode(_ code: String) {
            guard attemptState.isActive, !deliveredSession else { return }
            let attempt = attemptState.id
            let deviceID = parent.currentDeviceID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !deviceID.isEmpty else {
                failDesktopAuthorization("The app device identity is unavailable. Close and reopen the app.")
                return
            }

            var components = URLComponents(
                string: "https://user.mypikpak.com/v1/auth/token"
            )
            components?.queryItems = [
                URLQueryItem(name: "client_id", value: PikPakDesktopOAuth.clientID),
            ]
            guard let url = components?.url else {
                failDesktopAuthorization("The PikPak authorization address is invalid.")
                return
            }

            let body: [String: String] = [
                "client_id": PikPakDesktopOAuth.clientID,
                "client_secret": PikPakDesktopOAuth.clientSecret,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": PikPakDesktopOAuth.redirectURI,
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                failDesktopAuthorization("Could not prepare the desktop authorization request.")
                return
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            desktopTokenSession = session

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(PikPakDesktopOAuth.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(PikPakDesktopOAuth.clientID, forHTTPHeaderField: "X-Client-Id")
            request.setValue(
                PikPakDesktopOAuth.clientVersion,
                forHTTPHeaderField: "X-Client-Version"
            )
            request.setValue(PikPakDesktopOAuth.sdkVersion, forHTTPHeaderField: "X-Sdk-Version")
            request.setValue("301", forHTTPHeaderField: "X-Protocol-Version")
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")

            desktopExchangeTask = session.dataTask(with: request) { [weak self] data, response, error in
                let exchangeResult: DesktopExchangeResult
                if let error {
                    let nsError = error as NSError
                    exchangeResult = .failure(
                        message: "PikPak could not be reached while creating the desktop session.",
                        details: Self.errorDetailsText(
                            source: nsError.domain,
                            code: "\(nsError.domain) \(nsError.code)",
                            message: nsError.localizedDescription
                        )
                    )
                } else if let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode),
                          let data,
                          let tokenResponse = try? JSONDecoder().decode(
                              DesktopTokenResponse.self,
                              from: data
                          ),
                          !tokenResponse.refreshToken.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty {
                    exchangeResult = .success(tokenResponse.refreshToken)
                } else {
                    let apiError = data.flatMap {
                        try? JSONDecoder().decode(DesktopOAuthError.self, from: $0)
                    }
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode
                    let message = apiError?.message
                        ?? "PikPak rejected the desktop authorization."
                    var codes: [String] = []
                    if let httpStatus { codes.append("HTTP \(httpStatus)") }
                    if let apiCode = apiError?.code { codes.append("API \(apiCode)") }
                    if codes.isEmpty { codes.append("DESKTOP_AUTHORIZATION_REJECTED") }
                    exchangeResult = .failure(
                        message: "\(message) Choose Try Again to retry.",
                        details: Self.errorDetailsText(
                            source: "PikPak API",
                            code: codes.joined(separator: " • "),
                            message: message
                        )
                    )
                }

                DispatchQueue.main.async {
                    guard let self, self.attemptState.accepts(attempt),
                          self.desktopTokenSession === session, !self.deliveredSession else { return }
                    self.desktopExchangeTask = nil
                    session.finishTasksAndInvalidate()
                    self.desktopTokenSession = nil
                    self.desktopAuthorizationInFlight = false

                    switch exchangeResult {
                    case .success(let refreshToken):
                        self.deliveredSession = true
                        self.tokenTimer?.invalidate()
                        self.tokenTimer = nil
                        self.parent.status = "Independent desktop session created. Saving…"
                        self.parent.errorDetails = nil
                        self.parent.onSession(
                            PikPakWebSession(
                                refreshToken: refreshToken,
                                deviceID: deviceID
                            )
                        )
                    case .failure(let message, let details):
                        self.parent.status = message
                        self.parent.errorDetails = details
                    }
                }
            }
            desktopExchangeTask?.resume()
        }

        private func failDesktopAuthorization(
            _ message: String,
            code: String = "DESKTOP_AUTHORIZATION_FAILED",
            detailMessage: String? = nil
        ) {
            desktopAuthorizationInFlight = false
            parent.status = message
            parent.errorDetails = Self.errorDetailsText(
                source: "PikPak authorization broker",
                code: code,
                message: detailMessage ?? message
            )
        }

        private func reportPageLoadFailure(_ error: Error) {
            guard attemptState.isActive else { return }
            let nsError = error as NSError
            parent.status = "Page failed to load: \(error.localizedDescription)"
            parent.errorDetails = Self.errorDetailsText(
                source: nsError.domain,
                code: "\(nsError.domain) \(nsError.code)",
                message: nsError.localizedDescription
            )
        }

        private static func errorDetailsText(
            source: String,
            code: String,
            message: String
        ) -> String {
            let safeMessage = message
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return "Source: \(source)\nCode: \(code)\nMessage: \(String(safeMessage.prefix(500)))"
        }

        private static func isPikPakHost(_ host: String?) -> Bool {
            guard let host = host?.lowercased() else { return false }
            return host == "mypikpak.com" || host.hasSuffix(".mypikpak.com")
        }

        private static let authenticationStateScript = """
        (() => {
          try {
            for (let index = 0; index < localStorage.length; index += 1) {
              const key = localStorage.key(index);
              if (key !== "credentials" && !key?.startsWith("credentials_")) continue;
              const raw = localStorage.getItem(key);
              if (!raw) continue;
              try {
                const value = JSON.parse(raw);
                if (
                  (typeof value?.access_token === "string" && value.access_token.trim()) ||
                  (typeof value?.refresh_token === "string" && value.refresh_token.trim())
                ) {
                  return { signedIn: true };
                }
              } catch (_) {}
            }
          } catch (_) {}
          return { signedIn: false };
        })();
        """

        private static let desktopAuthorizationScript = """
        const auth = window.loginUI?.login?.auth;
        if (!auth || typeof auth.userAuthorize !== "function") {
          return { ready: false, code: "" };
        }
        const value = await auth.userAuthorize({
          client_id: "\(PikPakDesktopOAuth.clientID)",
          state: "ignored",
          scope: "\(PikPakDesktopOAuth.scope)",
          response_type: "code",
          redirect_uri: "\(PikPakDesktopOAuth.redirectURI)"
        });
        const code = typeof value === "string"
          ? value
          : (typeof value?.code === "string"
              ? value.code
              : (typeof value?.data?.code === "string" ? value.data.code : ""));
        return { ready: true, code };
        """

        static func webDeviceBootstrapScript() -> String? {
            let transientWebDeviceID = "wdi10."
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let payload: [String: String] = ["deviceID": transientWebDeviceID]
            guard
                JSONSerialization.isValidJSONObject(payload),
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let encoded = String(data: data, encoding: .utf8)
            else { return nil }

            return """
            (() => {
              try {
                const host = location.hostname.toLowerCase();
                if (host !== "mypikpak.com" && !host.endsWith(".mypikpak.com")) return;
                const broker = \(encoded);
                if (broker.deviceID) localStorage.setItem("deviceid", broker.deviceID);
              } catch (_) {}
            })();
            """
        }
    }
}

private enum DesktopExchangeResult {
    case success(String)
    case failure(message: String, details: String)
}

private struct DesktopTokenResponse: Decodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct DesktopOAuthError: Decodable {
    let error: String?
    let errorDescription: String?
    let errorCode: FlexibleErrorCode?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorCode = "error_code"
    }

    var message: String? {
        let candidate = errorDescription ?? error
        let normalized = candidate?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return String(normalized.prefix(500))
    }

    var code: String? {
        if let errorCode { return errorCode.value }
        guard let error else { return nil }
        let normalized = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(80))
    }
}

private struct FlexibleErrorCode: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or integer error code"
                )
            )
        }
    }
}
