import SwiftUI

@main @MainActor struct PersonalAccessTokenUITestApp: App {
    @State private var result = ""
    var body: some Scene {
        WindowGroup("MyCloudDriver · Personal Access Token Test") {
            VStack {
                PikPakLoginView(reason: "Connect PikPak", currentDeviceID: String(repeating: "f", count: 32),
                    initialCredentialKind: .personalAccessToken,
                    onSession: { session in result = session.credentialKind == .personalAccessToken ? "Token received securely · fixture only" : "Sign-in received" },
                    onCancel: { result = "Cancelled" })
                if !result.isEmpty { Text(result).padding(.bottom, 16) }
            }
        }
        .windowResizability(.contentSize)
    }
}
