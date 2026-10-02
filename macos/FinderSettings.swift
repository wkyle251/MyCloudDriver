import AppKit
import SwiftUI

/// Read the running app's metadata, never a hard-coded release label.
enum FinderAppVersion {
    static func displayText(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        func value(_ key: String) -> String? {
            guard let text = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        switch (value("CFBundleShortVersionString"), value("CFBundleVersion")) {
        case let (version?, build?): return "\(version) (build \(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "Build \(build)"
        case (nil, nil): return "Unavailable"
        }
    }
}

enum FinderPreviewPlacement: String, CaseIterable, Identifiable {
    case right, bottom
    var id: Self { self }
    var title: String { self == .right ? "Right" : "Bottom" }
}

enum PikPakContentMode: String, CaseIterable, Identifiable, Codable {
    case user, guest, dynamic
    var id: Self { self }
    var title: String {
        switch self {
        case .user: return "User Mode"
        case .guest: return "Guest Mode"
        case .dynamic: return "Dynamic Mode"
        }
    }
    var symbol: String {
        switch self {
        case .user: return "person.crop.circle"
        case .guest: return "link"
        case .dynamic: return "arrow.triangle.branch"
        }
    }
    var summary: String {
        switch self {
        case .user: return "Signed-in account only"
        case .guest: return "Public links only"
        case .dynamic: return "Guest first, then account"
        }
    }
    var detail: String {
        switch self {
        case .user: return "Always use your signed-in account."
        case .guest: return "Use public links. Stop if guest access is unavailable."
        case .dynamic: return "Try guest access first. Use your account when a guest link is unavailable."
        }
    }
}

/// Presentation and archive preferences shared by every app window.
@MainActor
final class FinderSettings: ObservableObject {
    private let defaults: UserDefaults
    let playback: MediaPlaybackSettings

    @Published var contentMode: PikPakContentMode {
        didSet { defaults.set(contentMode.rawValue, forKey: "pikpakContentMode") }
    }

    @Published var autoHideSidebar: Bool {
        didSet { defaults.set(autoHideSidebar, forKey: "finderAutoHideSidebar") }
    }
    @Published var showsPreviewPane: Bool {
        didSet { defaults.set(showsPreviewPane, forKey: "finderShowsPreviewPane") }
    }
    @Published var previewPlacement: FinderPreviewPlacement {
        didSet { defaults.set(previewPlacement.rawValue, forKey: "finderPreviewPlacement") }
    }
    @Published private(set) var concurrentExtractions: Int
    @Published var selectedPane = 0
    @Published private(set) var layoutResetRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playback = MediaPlaybackSettings(defaults: defaults)
        contentMode = PikPakContentMode(rawValue: defaults.string(forKey: "pikpakContentMode") ?? "")
            ?? (defaults.bool(forKey: "pikpakGuestMode") ? .guest : .user)
        autoHideSidebar = defaults.bool(forKey: "finderAutoHideSidebar")
        showsPreviewPane = defaults.object(forKey: "finderShowsPreviewPane") as? Bool ?? true
        previewPlacement = FinderPreviewPlacement(rawValue: defaults.string(forKey: "finderPreviewPlacement") ?? "") ?? .right
        concurrentExtractions = min(8, max(1,
            (defaults.object(forKey: "finderConcurrentExtractions") as? NSNumber)?.intValue ?? 4))
        defaults.set(contentMode.rawValue, forKey: "pikpakContentMode")
    }

    func setConcurrentExtractions(_ value: Int) {
        concurrentExtractions = min(8, max(1, value))
        defaults.set(concurrentExtractions, forKey: "finderConcurrentExtractions")
    }

    func resetLayout() {
        // Reset only presentation keys. Keep the selected drive/location,
        // accounts, transfers, download destination and background work intact.
        let values: [String: Any] = [
            "browserSplitFraction": 0.64, "browserBottomSplitFraction": 0.45,
            "previewCanvasHeight": 440.0,
            "browserViewMode": 0, "linksViewMode": 0,
            "browserListItemZoom": 1.0, "browserThumbnailItemZoom": 1.0, "browserItemZoom": 0.0,
            "browserNameColumnWidth": 250.0, "browserSizeColumnWidth": 76.0,
            "browserKindColumnWidth": 104.0, "browserModifiedColumnWidth": 156.0,
            "browserShowsSizeColumn": true, "browserShowsKindColumn": true, "browserShowsModifiedColumn": true,
        ]
        values.forEach { defaults.set($0.value, forKey: $0.key) }
        defaults.removeObject(forKey: "previewCanvasWidth") // Width now always follows the pane.
        autoHideSidebar = false; showsPreviewPane = true; previewPlacement = .right
        layoutResetRevision &+= 1
    }
}

struct FinderSettingsButton: View {
    private var label: some View {
        Label {
            Text("Settings")
        } icon: {
            Image(systemName: "gearshape").foregroundStyle(FinderAppearance.accent)
        }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { label }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                label
            }
        }
    }
}

/// Route the sidebar shortcut to the same native Settings window.
struct FinderAccountSettingsLink<LabelView: View>: View {
    @ObservedObject var settings: FinderSettings
    var pane = 2
    @ViewBuilder let label: () -> LabelView

    var body: some View {
        if #available(macOS 14.0, *) {
            ModernAccountSettingsLink(settings: settings, pane: pane, label: label)
        } else {
            Button {
                settings.selectedPane = pane
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { label() }
        }
    }
}

@available(macOS 14.0, *)
private struct ModernAccountSettingsLink<LabelView: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var settings: FinderSettings
    let pane: Int
    @ViewBuilder let label: () -> LabelView

    var body: some View {
        Button {
            settings.selectedPane = pane
            openSettings()
        } label: { label() }
    }
}

/// Reject non-digits while typing or pasting, including signs and decimal
/// separators. Clamp a completed integer without overflowing on long input.
private final class BoundedCountFormatter: Formatter {
    var fallbackValue = 1
    var range = 1...8

    override func string(for obj: Any?) -> String? {
        (obj as? NSNumber)?.stringValue
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Self.isDigits(string) else {
            error?.pointee = "Enter a whole number from \(range.lowerBound) to \(range.upperBound)." as NSString
            return false
        }
        let bounded = string.isEmpty ? fallbackValue : string.utf8.reduce(0) { value, digit in
            min(value * 10 + Int(digit - 48), range.upperBound)
        }
        obj?.pointee = NSNumber(value: min(max(bounded, range.lowerBound), range.upperBound))
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                      newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        // An empty draft lets the user select/delete the previous value.
        Self.isDigits(partialString)
    }

    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
                                      proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
                                      originalString origString: String, originalSelectedRange origSelRange: NSRange,
                                      errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Self.isDigits(partialStringPtr.pointee as String) else {
            partialStringPtr.pointee = origString as NSString
            proposedSelRangePtr?.pointee = origSelRange
            return false
        }
        return true
    }

    private static func isDigits(_ string: String) -> Bool {
        string.utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// SwiftUI's value/formatter field permits invalid drafts. Use AppKit's native
/// partial validation so disallowed characters never enter the editor.
private struct BoundedCountField: NSViewRepresentable {
    @Binding var value: Int
    var range = 1...8
    var label = "Extractions at once"

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<Int>
        var lastValue: Int
        var range = 1...8

        init(value: Binding<Int>) {
            self.value = value
            lastValue = value.wrappedValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let number = Int(field.stringValue), range.contains(number) else { return }
            lastValue = number
            value.wrappedValue = number
        }

        @objc func commit(_ field: NSTextField) {
            let formatter = field.formatter as? BoundedCountFormatter
            formatter?.fallbackValue = value.wrappedValue
            var number: AnyObject?
            if formatter?.getObjectValue(&number, for: field.stringValue, errorDescription: nil) == true,
               let number = number as? NSNumber {
                lastValue = number.intValue
                value.wrappedValue = lastValue
            }
            let canonical = String(value.wrappedValue)
            field.stringValue = canonical
            field.currentEditor()?.string = canonical
        }

        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            if let field = control as? NSTextField { commit(field) }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { commit(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        let formatter = BoundedCountFormatter()
        formatter.range = range
        context.coordinator.range = range
        formatter.fallbackValue = value
        field.formatter = formatter
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.maximumNumberOfLines = 1
        field.setAccessibilityLabel(label)
        field.toolTip = "Enter a whole number from \(range.lowerBound) to \(range.upperBound)"
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.value = $value
        coordinator.range = range
        (field.formatter as? BoundedCountFormatter)?.range = range
        (field.formatter as? BoundedCountFormatter)?.fallbackValue = value
        if coordinator.lastValue != value || field.currentEditor() == nil {
            coordinator.lastValue = value
            field.stringValue = String(value)
            field.currentEditor()?.string = String(value)
        }
    }
}

/// Keep frequently changing operation state inside its content panes. The
/// native tab toolbar only observes settings/navigation, not transfer ticks.
struct FinderSettingsView: View {
    @ObservedObject var settings: FinderSettings
    private let model: DownloaderModel
    private let initialPane: Int?
    private let hub: CloudDriveHub?

    init(settings: FinderSettings, model: DownloaderModel, initialPane: Int? = nil, hub: CloudDriveHub? = nil) {
        self.settings = settings
        self.model = model
        self.initialPane = initialPane
        self.hub = hub
    }

    var body: some View {
        #if SETTINGS_ICON_TESTS
        let _ = SettingsIconRenderProbe.navigationRendered()
        #endif
        TabView(selection: $settings.selectedPane) {
            FinderGeneralSettingsView(settings: settings, model: model)
                .tabItem { FinderSymbolImage.settingsLabel("General", systemImage: "gearshape") }
                .tag(0)
            FinderResourceSettingsView(model: model, isActive: settings.selectedPane == 1)
                .tabItem { FinderSymbolImage.settingsLabel("Resources", systemImage: "gauge") }
                .tag(1)
            FinderAccountsSettingsView(model: model, hub: hub)
                .buttonStyle(FinderButtonStyle())
                .tabItem { FinderSymbolImage.settingsLabel("Accounts", systemImage: "person.crop.circle") }
                .tag(2)
            if let hub {
                CloudDriveConnectionsView(hub: hub)
                    .buttonStyle(FinderButtonStyle())
                    .tabItem { FinderSymbolImage.settingsLabel("Drives", systemImage: "externaldrive") }
                    .tag(3)
            }
        }
        .tint(FinderAppearance.accent)
        // Native tab buttons own hover/selection; pane buttons keep our style.
        .buttonStyle(.automatic)
        .padding(12)
        .frame(width: 580, height: 580)
        .onAppear { if let initialPane { settings.selectedPane = initialPane } }
        .task(id: settings.selectedPane) {
            if settings.selectedPane == 2 { model.checkAccountStatus(automatically: true) }
        }
        .background { FinderSettingsLoginPresentation(model: model) }
    }
}

private struct FinderGeneralSettingsView: View {
    @ObservedObject var settings: FinderSettings
    @ObservedObject var model: DownloaderModel
    @State private var didResetLayout = false

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("App version") {
                    Text(FinderAppVersion.displayText())
                        .textSelection(.enabled)
                }
            }
            Section("Sidebar") {
                Toggle("Automatically hide the sidebar", isOn: $settings.autoHideSidebar)
                Text("Move to the narrow left edge to reveal it. The reveal strip is outside the file list and does not activate while dragging files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser and Links") {
                Toggle("Show the preview pane", isOn: $settings.showsPreviewPane)
                Picker("Preview placement", selection: $settings.previewPlacement) {
                    ForEach(FinderPreviewPlacement.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("Applies to every drive and all workspace windows.").font(.caption).foregroundStyle(.secondary)
                Text("You can also change this in View. Hide the preview to give the file list more space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                HStack {
                    Text("Default workspace layout")
                    Spacer()
                    Button("Reset Layout") {
                        settings.resetLayout(); didResetLayout = true
                    }.pointingHandCursor()
                }
                Text("Restore the sidebar, split view, preview height, file columns, list view and item sizes across all drives.")
                    .font(.caption).foregroundStyle(.secondary)
                if didResetLayout {
                    Label("Layout reset", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Section("Transfers") {
                Text("Uploads and downloads adjust automatically to your connection. You can pause or resume them in Transfers. iCloud Drive and Photos transfers are managed by macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("This Mac", value: "\(ProcessInfo.processInfo.activeProcessorCount) cores · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB memory")
                LabeledContent("Download folder") {
                    Text(model.outputURL.path).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…") { model.chooseOutputFolder() }
                        .disabled(model.isDownloading)
                }
            }
            Section("Archives") {
                LabeledContent("Extractions at once") {
                    HStack(spacing: 6) {
                        BoundedCountField(value: $model.archiveConcurrencyLimit, range: 1...8,
                            label: "Extractions at once")
                            .frame(width: 60, height: 22)
                        Stepper("Extractions at once", value: $model.archiveConcurrencyLimit, in: 1...8)
                            .labelsHidden().pointingHandCursor()
                    }
                }
                Text("Extract ZIP, RAR and 7z files from Browser. Password-protected archives ask for a password. Progress stays in the footer while you keep working. Range: 1–8; running extractions keep their slot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .buttonStyle(FinderButtonStyle())
    }
}

private struct FinderResourceSettingsView: View {
    let model: DownloaderModel
    let isActive: Bool
    @StateObject private var monitor = TaskResourceMonitor()

    var body: some View {
        TaskResourceMonitorView(monitor: monitor)
            .buttonStyle(FinderButtonStyle())
            .task(id: isActive) {
                if isActive {
                    await monitor.watch { WorkspaceSessionManager.current?.resourceActivities ?? model.resourceActivities }
                }
            }
    }
}

/// Account/login changes must still present their sheet without invalidating
/// the tab toolbar for every unrelated model update.
private struct FinderSettingsLoginPresentation: View {
    @ObservedObject var model: DownloaderModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { model.isLoginPresented && model.loginFromSettings }, set: {
                if !$0 && model.isLoginPresented && model.loginFromSettings { model.cancelLogin() }
            })) {
                PikPakLoginView(reason: model.loginReason, currentDeviceID: model.loginDeviceID,
                    initialCredentialKind: model.loginCredentialKind,
                    onSession: { model.completeWebLogin(with: $0) }, onCancel: model.cancelLogin)
            }
    }
}

private struct FinderAccountsSettingsView: View {
    @ObservedObject var model: DownloaderModel
    let hub: CloudDriveHub?

    private var statusColor: Color {
        switch model.accountLoginStatus {
        case .signedIn: return .green
        case .needsSignIn, .unavailable: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Form {
            Section("Current PikPak account") {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(FinderAppearance.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("PikPak", systemImage: CloudDriveKind.pikpak.symbol)
                            .font(.caption.weight(.semibold)).foregroundStyle(FinderAppearance.accent)
                        Text(model.activeSavedAccount?.displayName ?? "Connect to PikPak")
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            if model.isCheckingAccount { ProgressView().controlSize(.mini) }
                            else { Circle().fill(statusColor).frame(width: 7, height: 7) }
                            Text(model.isChangingAccount ? "Checking account…" : model.accountLoginStatus.title)
                                .font(.callout).foregroundStyle(statusColor)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)

                if !model.hasAccountSession {
                    Text("Sign in to PikPak to browse your files, save shared files and manage transfers.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Sign In…") { model.beginAccountLogin(accountID: model.activeAccountID) }
                            .buttonStyle(.borderedProminent).pointingHandCursor()
                            .disabled(!model.canChangeAccount)
                        Spacer()
                        if model.activeAccountID != nil {
                            Button("Log Out", role: .destructive) { model.logOutAccount() }
                                .disabled(!model.canChangeAccount)
                        }
                    }
                } else {
                    HStack {
                        Button("Check Login Status") { model.checkAccountStatus() }
                            .disabled(!model.canCheckAccountStatus)
                        Spacer()
                        Button("Log Out", role: .destructive) { model.logOutAccount() }
                            .disabled(!model.canChangeAccount)
                    }
                    if let checked = model.activeSavedAccount?.lastChecked {
                        Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.isCheckingAccount {
                    Button("Cancel Check", action: model.cancelAccountCheck)
                }
                if let error = model.accountSettingsError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Login method") {
                ForEach(PikPakCredentialKind.allCases) { kind in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.loginTitle).fontWeight(.medium)
                            Text(kind.quotaExplanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let current = model.hasAccountSession && model.activeCredentialKind == kind
                        let saved = model.activeAccountGroup?.connection(kind)
                        if current {
                            Label("Active", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(FinderAppearance.accent)
                            Button(kind == .personalAccessToken ? "Replace Token…" : "Reconnect…") {
                                model.beginAccountLogin(accountID: model.activeAccountID, credentialKind: kind)
                            }.disabled(!model.canChangeAccount)
                        } else {
                            Button(saved == nil || saved?.needsSignIn == true ? "Connect…" : "Switch") {
                                model.selectPikPakConnection(kind, fromSettings: true)
                            }.disabled(!model.canChangeAccount)
                        }
                    }
                }
                Text("Both login methods stay saved. You can switch accounts and login methods in the left sidebar. The selected connection applies to account requests in downloads, previews and scans.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.hasAccountSession {
                PikPakAccountDetailsSection(model: model, management: model.pikpakManagement, quotas: model.transferQuotaMonitor)
            }

            Section("Saved PikPak accounts") {
                if model.savedAccounts.isEmpty {
                    Text("PikPak accounts you add will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.savedAccountGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(FinderAppearance.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.displayName).fontWeight(.medium)
                                if let identifier = group.connections.first?.accountIdentifier {
                                    Text("Account ID: \(identifier)").font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                        }
                        ForEach(group.connections) { account in
                            HStack {
                                Text(account.connectionKind.loginTitle).font(.callout)
                                Spacer()
                                if account.id == model.activeAccountID && model.hasAccountSession {
                                    Label("Current", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(FinderAppearance.accent)
                                } else {
                                    Button(account.needsSignIn ? "Sign In…" : "Switch") {
                                        model.selectPikPakConnection(account.connectionKind, accountID: account.id, fromSettings: true)
                                    }.disabled(!model.canChangeAccount)
                                }
                            }.padding(.leading, 30)
                        }
                    }.padding(.vertical, 4)
                }
                Button { model.beginAccountLogin() } label: {
                    Label("Add PikPak Account…", systemImage: "plus")
                }
                .disabled(!model.canChangeAccount)
            }

            Section {
                if let reason = model.accountChangeBlockedReason {
                    Label(reason, systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                Text("Unfinished PikPak transfers stay with their account. Log Out removes only the selected login method from this Mac; other saved connections are kept.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            if let hub {
                Section("Apple services") {
                    CloudDriveAccountsSummary(hub: hub)
                }
            }
        }
        .formStyle(.grouped)
    }
}
