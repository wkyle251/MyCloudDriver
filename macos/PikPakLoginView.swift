import AppKit
import SwiftUI
import WebKit

struct PikPakWebSession {
    let refreshToken: String
    let deviceID: String
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

struct PikPakLoginView: View {
    let reason: String
    let currentDeviceID: String
    let onSession: (PikPakWebSession) -> Void
    let onCancel: () -> Void

    @State private var pageStatus = "Opening PikPak Web Drive…"
    @State private var pageErrorDetails: String?
    @State private var reloadRequest = 0

    var body: some View {
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
            tokenTimer?.invalidate()
            tokenTimer = nil
            desktopExchangeTask?.cancel()
            desktopExchangeTask = nil
            desktopTokenSession?.invalidateAndCancel()
            desktopTokenSession = nil
            webView = nil
        }

        func loadPikPakDrive() {
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
            parent.errorDetails = nil
            guard let host = url?.host?.lowercased(), !host.isEmpty else {
                parent.status = loading ? "Loading PikPak sign-in…" : "Waiting for PikPak sign-in…"
                return
            }
            parent.status = loading ? "Loading \(host)…" : "Viewing \(host)"
        }

        private func inspectForAuthenticatedWebSession() {
            guard
                !deliveredSession,
                !desktopAuthorizationInFlight,
                !desktopAuthorizationAttempted,
                let webView,
                Self.isPikPakHost(webView.url?.host)
            else { return }

            webView.evaluateJavaScript(Self.authenticationStateScript) { [weak self] result, _ in
                guard
                    let self,
                    !self.deliveredSession,
                    let values = result as? [String: Any],
                    values["signedIn"] as? Bool == true
                else { return }

                self.requestDesktopAuthorization(using: webView)
            }
        }

        private func requestDesktopAuthorization(using webView: WKWebView) {
            guard
                !deliveredSession,
                !desktopAuthorizationInFlight,
                !desktopAuthorizationAttempted
            else { return }

            desktopAuthorizationInFlight = true
            desktopAuthorizationAttempted = true
            parent.errorDetails = nil
            parent.status = "Creating an independent desktop session…"

            webView.callAsyncJavaScript(
                Self.desktopAuthorizationScript,
                arguments: [:],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self, !self.deliveredSession else { return }

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
                    guard let self, !self.deliveredSession else { return }
                    self.desktopExchangeTask = nil
                    self.desktopTokenSession?.finishTasksAndInvalidate()
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
