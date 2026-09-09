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

/// One persistent preference for both transfer directions. Existing running
/// processes retain their allocation; the next batch reads this shared value.
@MainActor
final class FinderSettings: ObservableObject {
    static let defaultWorkers = 32
    nonisolated static let workerRange = 1...64
    private let defaults: UserDefaults

    @Published var autoHideSidebar: Bool {
        didSet { defaults.set(autoHideSidebar, forKey: "finderAutoHideSidebar") }
    }
    @Published var showsPreviewPane: Bool {
        didSet { defaults.set(showsPreviewPane, forKey: "finderShowsPreviewPane") }
    }
    @Published private(set) var transferWorkers: Int
    @Published private(set) var concurrentExtractions: Int
    @Published var selectedPane = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoHideSidebar = defaults.bool(forKey: "finderAutoHideSidebar")
        showsPreviewPane = defaults.object(forKey: "finderShowsPreviewPane") as? Bool ?? true
        transferWorkers = Self.clampWorkers(
            (defaults.object(forKey: "finderTransferWorkers") as? NSNumber)?.intValue ?? Self.defaultWorkers
        )
        concurrentExtractions = min(8, max(1,
            (defaults.object(forKey: "finderConcurrentExtractions") as? NSNumber)?.intValue ?? 4))
    }

    nonisolated static func clampWorkers(_ value: Int) -> Int {
        min(max(value, workerRange.lowerBound), workerRange.upperBound)
    }

    func setTransferWorkers(_ value: Int) {
        let bounded = Self.clampWorkers(value)
        guard transferWorkers != bounded else { return }
        transferWorkers = bounded
        defaults.set(transferWorkers, forKey: "finderTransferWorkers")
    }

    func setConcurrentExtractions(_ value: Int) {
        concurrentExtractions = min(8, max(1, value))
        defaults.set(concurrentExtractions, forKey: "finderConcurrentExtractions")
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
    @ViewBuilder let label: () -> LabelView

    var body: some View {
        if #available(macOS 14.0, *) {
            ModernAccountSettingsLink(settings: settings, label: label)
        } else {
            Button {
                settings.selectedPane = 2
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { label() }
        }
    }
}

@available(macOS 14.0, *)
private struct ModernAccountSettingsLink<LabelView: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var settings: FinderSettings
    @ViewBuilder let label: () -> LabelView

    var body: some View {
        Button {
            settings.selectedPane = 2
            openSettings()
        } label: { label() }
    }
}

/// Reject non-digits while typing or pasting, including signs and decimal
/// separators. Clamp a completed integer without overflowing on long input.
private final class WorkerCountFormatter: Formatter {
    var fallbackValue = 1
    var range = FinderSettings.workerRange

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
private struct WorkerCountField: NSViewRepresentable {
    @Binding var value: Int
    var range = FinderSettings.workerRange
    var label = "Workers per direction"

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<Int>
        var lastValue: Int
        var range = FinderSettings.workerRange

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
            let formatter = field.formatter as? WorkerCountFormatter
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
        let formatter = WorkerCountFormatter()
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
        (field.formatter as? WorkerCountFormatter)?.range = range
        (field.formatter as? WorkerCountFormatter)?.fallbackValue = value
        if coordinator.lastValue != value || field.currentEditor() == nil {
            coordinator.lastValue = value
            field.stringValue = String(value)
            field.currentEditor()?.string = String(value)
        }
    }
}

struct FinderSettingsView: View {
    @ObservedObject var settings: FinderSettings
    @ObservedObject var model: DownloaderModel
    @StateObject private var monitor = TaskResourceMonitor()
    private let initialPane: Int?
    private let connections: AnyView?

    init(settings: FinderSettings, model: DownloaderModel, initialPane: Int? = nil, connections: AnyView? = nil) {
        self.settings = settings
        self.model = model
        self.initialPane = initialPane
        self.connections = connections
    }

    var body: some View {
        TabView(selection: $settings.selectedPane) {
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
                    Text("You can also change this in View. Hide the preview to give the file list more space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Transfers") {
                    LabeledContent("Workers per direction") {
                        HStack(spacing: 6) {
                            WorkerCountField(value: Binding(get: { settings.transferWorkers }, set: settings.setTransferWorkers))
                                .frame(width: 60, height: 22)
                            Stepper("Workers per direction",
                                    value: Binding(get: { settings.transferWorkers }, set: settings.setTransferWorkers),
                                    in: FinderSettings.workerRange)
                                .labelsHidden()
                                .pointingHandCursor()
                        }
                    }
                    Text("Default: 32 · Range: 1–64. Applies to both upload and download. Changes take effect on the next batch, not a transfer already running. Each batch is capped to its file count.")
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
                            WorkerCountField(value: $model.archiveConcurrencyLimit, range: 1...8,
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
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(0)

            TaskResourceMonitorView(monitor: monitor)
                .tabItem { Label("Resources", systemImage: "gauge") }
                .tag(1)

            FinderAccountsSettingsView(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(2)
            if let connections {
                connections.tabItem { Label("Drives", systemImage: "externaldrive") }.tag(3)
            }
        }
        .tint(FinderAppearance.accent)
        .buttonStyle(FinderButtonStyle())
        .padding(12)
        .frame(width: 580, height: 580)
        .onAppear { if let initialPane { settings.selectedPane = initialPane } }
        .task(id: settings.selectedPane) {
            if settings.selectedPane == 1 { await monitor.watch { model.resourceActivities } }
            if settings.selectedPane == 2 { model.checkAccountStatus(automatically: true) }
        }
        .sheet(isPresented: Binding(get: { model.isLoginPresented && model.loginFromSettings }, set: {
            if !$0 && model.isLoginPresented && model.loginFromSettings { model.cancelLogin() }
        })) {
            PikPakLoginView(reason: model.loginReason, currentDeviceID: model.loginDeviceID,
                onSession: { model.completeWebLogin(with: $0) }, onCancel: model.cancelLogin)
        }
    }
}

private struct FinderAccountsSettingsView: View {
    @ObservedObject var model: DownloaderModel

    private var statusColor: Color {
        switch model.accountLoginStatus {
        case .signedIn: return .green
        case .needsSignIn, .unavailable: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Form {
            Section("Current account") {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(FinderAppearance.accent)
                    VStack(alignment: .leading, spacing: 5) {
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
                    Text("Sign in to browse your files, save shared files and manage transfers.")
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

            Section("Saved accounts") {
                if model.savedAccounts.isEmpty {
                    Text("Accounts you add will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.savedAccounts) { account in
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .font(.title2).foregroundStyle(FinderAppearance.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName).fontWeight(.medium)
                            if let identifier = account.accountIdentifier {
                                Text("Account \(identifier)").font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if account.needsSignIn {
                                Text("Signed out · sign in to reconnect").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if account.id == model.activeAccountID && !account.needsSignIn {
                            Label("Current", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(FinderAppearance.accent)
                        } else {
                            Button(account.needsSignIn ? "Sign In…" : "Switch") {
                                if account.needsSignIn { model.beginAccountLogin(accountID: account.id) }
                                else { model.switchAccount(to: account.id) }
                            }
                            .disabled(!model.canChangeAccount)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button { model.beginAccountLogin() } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .disabled(!model.canChangeAccount)
            }

            Section {
                if let reason = model.accountChangeBlockedReason {
                    Label(reason, systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                Text("Unfinished transfers stay with their account. Logging out removes that account’s saved sign-in from this Mac.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .formStyle(.grouped)
    }
}
