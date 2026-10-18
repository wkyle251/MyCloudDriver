import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

enum DownloadProgressPresentation {
    static func waitingForDiscovery(state: DownloadRunState, totalsIncomplete: Bool) -> Bool {
        totalsIncomplete && state == .completed
    }

    static func stateTitle(state: DownloadRunState, totalsIncomplete: Bool) -> String {
        if waitingForDiscovery(state: state, totalsIncomplete: totalsIncomplete) {
            return "Waiting for remaining files"
        }
        if totalsIncomplete, state == .scanning || state == .downloading { return "Discovering files" }
        return state.title
    }

    static func completedSpeedTitle(totalsIncomplete: Bool) -> String {
        totalsIncomplete ? "Waiting…" : "Finished"
    }

    static func percentage(fraction: Double?, state: DownloadRunState, totalsIncomplete: Bool,
                           estimatedFraction: Double? = nil) -> String {
        if totalsIncomplete {
            guard let estimatedFraction, estimatedFraction.isFinite else { return "—" }
            return "≈\(Int((min(max(estimatedFraction, 0), 1) * 100).rounded(.down)))%"
        }
        guard let fraction, fraction.isFinite else { return state == .scanning ? "…" : "—" }
        if state == .completed { return "100%" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// While discovery is unfinished the exact remainder is unknown. A cached folder size may stand in for it,
    /// marked approximate; without one the label keeps saying the total is still being discovered.
    static func remaining(state: DownloadRunState, totalsIncomplete: Bool, bytes: String?, duration: String?,
                          estimatedBytes: String? = nil, estimatedDuration: String? = nil) -> String {
        guard !totalsIncomplete else {
            guard let estimatedBytes else { return "Discovering total size… • Calculating time…" }
            guard let estimatedDuration else { return "≈ \(estimatedBytes) left • Calculating time…" }
            return "≈ \(estimatedBytes) left • ~\(estimatedDuration)"
        }
        if state == .scanning { return "Calculating…" }
        if state == .completed { return "0 B left" }
        guard let bytes else { return "—" }
        guard let duration else { return "\(bytes) left • Calculating time…" }
        return "\(bytes) left • \(duration)"
    }
}

private enum BrowserViewMode: Int {
    case list
    case thumbnails
}

enum BrowserItemZoom {
    static let minimum = 0.75
    static let maximum = 1.80
    static let step = 0.15
}

/// Carry the complete merge choice into the sheet as one value. Presenting an
/// `isPresented` sheet while separately mutating its folders and destination
/// can let SwiftUI capture the previous empty values for the first frame.
private struct MergeFoldersRequest: Identifiable {
    let id = UUID()
    let folders: [BrowserItem]
    let initialDestinationID: String
}

struct ErrorDiagnosticBlock: View {
    let diagnostic: AppErrorDiagnostic
    let summary: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Error details", systemImage: "info.circle")
                    .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    copyPlainText(diagnostic.copyText(summary: summary))
                } label: {
                    if compact {
                        Image(systemName: "doc.on.doc")
                    } else {
                        Label("Copy Error", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderless).pointingHandCursor()
                .controlSize(.small)
                .help("Copy the error summary, code, and message")
            }

            Text(diagnostic.displayText)
                .font(.system(compact ? .caption2 : .caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(compact ? 7 : 9)
        .background(
            Color.red.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.17), lineWidth: 1)
        }
    }

    private func copyPlainText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Keep routine updates in the path footer. Full, selectable messages and
/// diagnostics are available without making the file viewport change height.
private struct FinderFooterStatus: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var activity: FinderTaskActivityStore
    let message: String
    let isError: Bool
    let isBusy: Bool
    let diagnostic: AppErrorDiagnostic?
    let compact: Bool
    let openTransfers: () -> Void
    let openActivity: (() -> Void)?
    @State private var isHovered = false

    private var showsError: Bool { isError || (activity.activeTasks.isEmpty && activity.tasks.first?.state == .failed) }
    private var busy: Bool { isBusy || !activity.activeTasks.isEmpty }
    private var title: String { showsError ? "Error" : (busy ? "In progress" : "Status") }
    private var displayMessage: String {
        if isError || model.isRunning || model.isPreparingQuickLook { return message }
        return activity.summary ?? (message.isEmpty ? "Ready" : message)
    }
    private var copyMessage: String {
        ([message] + activity.tasks.map { "\($0.kind.title) · \($0.state.label)\n\($0.scope)\n\($0.message)\n\($0.detail)" })
            .joined(separator: "\n\n")
    }

    var body: some View {
        Button { activity.showsDetails.toggle() } label: {
            HStack(spacing: 6) {
                if showsError {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                } else if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                }
                if !compact || showsError || !activity.tasks.isEmpty {
                    Text(compact && activity.tasks.isEmpty ? "Error" : displayMessage)
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(showsError ? Color.red : Color.secondary)
                        .frame(maxWidth: compact ? 180 : nil, alignment: .leading)
                }
            }
            .font(.caption)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 6)
            .background(
                showsError ? Color.red.opacity(0.07)
                    : (isHovered ? FinderAppearance.accent.opacity(0.08) : .clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { isHovered = $0 }
        .help("\(displayMessage)\nClick for details")
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title): \(displayMessage)")
        .accessibilityHint("Show progress, results and available actions")
        #if FINDER_FOOTER_TESTS
        .task {
            if Bundle.main.object(forInfoDictionaryKey: "FooterInspectionDetails") as? Bool == true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                activity.showsDetails = true
            }
        }
        #endif
        .finderPopover(isPresented: $activity.showsDetails, contentSize: .init(width: 460, height: 520),
                       presentationID: ObjectIdentifier(activity), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { activity.showsDetails = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).pointingHandCursor()
                        .help("Close status details").accessibilityLabel("Close status details")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if activity.tasks.isEmpty || isError || model.isRunning || model.isPreparingQuickLook {
                            Text(displayMessage)
                                .font(.callout)
                                .foregroundStyle(isError ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let diagnostic {
                                ErrorDiagnosticBlock(diagnostic: diagnostic, summary: displayMessage)
                            }
                        }
                        FinderTaskActivityRows(model: model, activity: activity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button {
                        activity.showsDetails = false
                        openTransfers()
                    } label: { Label("Transfers", systemImage: "arrow.up.arrow.down") }
                        .buttonStyle(.borderless).pointingHandCursor()
                    if diagnostic == nil {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyMessage, forType: .string)
                        } label: {
                            Label(isError ? "Copy Error" : "Copy Message", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).pointingHandCursor()
                    }
                    Spacer()
                    if let openActivity {
                        Button {
                            activity.showsDetails = false
                            openActivity()
                        } label: { Label("Activity Log", systemImage: "list.bullet.rectangle") }
                            .buttonStyle(.borderless).pointingHandCursor()
                    }
                }
                .font(.caption)
            }
            .padding(16)
            .frame(width: 460, height: 520)
            .background(Color(nsColor: .controlBackgroundColor))
            .tint(FinderAppearance.accent)
        }
    }
}

/// NSTextView provides Finder-like selection, copy, and Find behavior for
/// plain-text cloud previews while remaining efficient for the bounded 2 MB
/// document assembled by DownloaderModel.
private struct SelectableTextPreview: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var renderedText: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor.withAlphaComponent(0.84)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Selectable text file contents")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.renderedText != text else { return }
        context.coordinator.renderedText = text
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// SwiftUI can restore a window's content-derived minimum size after the app
/// delegate launch callbacks have finished. Keeping this zero-sized AppKit view
/// inside the main content lets us clear that constraint on the actual window
/// after every relevant layout/update without affecting login sheets.
private struct WindowMinimumSizeController: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMinimumSizeControllerView {
        WindowMinimumSizeControllerView()
    }

    func updateNSView(
        _ nsView: WindowMinimumSizeControllerView,
        context: Context
    ) {
        nsView.scheduleMinimumSizeReset()
    }
}

private final class WindowMinimumSizeControllerView: NSView {
    private weak var observedWindow: NSWindow?
    private var updateObserver: NSObjectProtocol?
    private var resetScheduled = false
    private var resetID = UUID()

    override var intrinsicContentSize: NSSize {
        .zero
    }

    // This view only observes the window. It must never become an input
    // surface if AppKit temporarily gives it a nonzero frame during layout.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToCurrentWindow()
    }

    override func layout() {
        super.layout()
        scheduleMinimumSizeReset()
    }

    fileprivate func enforceMinimumSize() {
        guard let window else { return }

        if window.contentMinSize != .zero {
            window.contentMinSize = .zero
        }

        let nativeChromeSize = window.frameRect(forContentRect: .zero).size
        if window.minSize != nativeChromeSize {
            window.minSize = nativeChromeSize
        }
    }

    fileprivate func scheduleMinimumSizeReset() {
        guard !resetScheduled, let window, observedWindow === window else { return }
        let nativeChromeSize = window.frameRect(forContentRect: .zero).size
        guard window.contentMinSize != .zero || window.minSize != nativeChromeSize else { return }
        resetScheduled = true
        let request = resetID
        // SwiftUI can reinstall its minimum during layout. Adjust it once
        // after that update, without mutating window geometry in the callback.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.resetID == request else { return }
            self.resetScheduled = false
            guard let window, self.window === window, self.observedWindow === window,
                  window.isVisible else { return }
            self.enforceMinimumSize()
        }
    }

    private func attachToCurrentWindow() {
        resetID = UUID(); resetScheduled = false
        if let updateObserver {
            NotificationCenter.default.removeObserver(updateObserver)
            self.updateObserver = nil
        }

        observedWindow = window
        guard let window else { return }

        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleMinimumSizeReset()
        }

        scheduleMinimumSizeReset()
    }

    deinit {
        if let updateObserver {
            NotificationCenter.default.removeObserver(updateObserver)
        }
    }
}

private enum DownloadQueueDisplayRow: Identifiable {
    case pending(PendingDownloadItem, preparing: Bool)
    case file(DownloadTransfer)
    var id: String {
        switch self {
        case .pending(let item, _): return "pending:" + item.id.uuidString
        case .file(let transfer): return "file:" + transfer.id
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: DownloaderModel
    @EnvironmentObject private var finderSettings: FinderSettings
    @State private var advancedExpanded = false
    @AppStorage("downloads.downloadingExpanded") private var downloadingExpanded = true
    @AppStorage("downloads.queueExpanded") private var downloadQueueExpanded = false
    @AppStorage("downloads.completedExpanded") private var downloadCompletedExpanded = false
    @AppStorage("downloads.retryExpanded") private var downloadRetryExpanded = false
    @AppStorage("downloads.failedExpanded") private var downloadFailedExpanded = false
    @State private var activityExpanded = false
    @StateObject private var workspaceNavigation = FinderWorkspaceNavigation()
    @ObservedObject private var sharedBookmarks = FinderBookmarkStore.shared
    @Environment(\.finderBookmarkStore) private var injectedBookmarks
    private var bookmarks: FinderBookmarkStore { injectedBookmarks ?? sharedBookmarks }
    init(navigation: FinderWorkspaceNavigation? = nil) {
        _workspaceNavigation = StateObject(wrappedValue: navigation ?? FinderWorkspaceNavigation())
    }
    private var selectedTab: Int {
        get { workspaceNavigation.section }
        nonmutating set {
            workspaceNavigation.showImmediately(newValue)
        }
    }
    private var browserSourceIsReady: Bool {
        selectedTab == 1 || selectedTab >= 4 || model.isBrowsingSharedLink == (selectedTab == 3)
    }
    @AppStorage("selectedTransferMode") private var selectedTransferMode = 0
    @AppStorage("browserViewMode") private var browserViewModeRaw = BrowserViewMode.list.rawValue
    @AppStorage("linksViewMode") private var linksViewModeRaw = BrowserViewMode.list.rawValue
    @AppStorage("bookmarkViewMode") private var bookmarkViewModeRaw = BrowserViewMode.list.rawValue
    @AppStorage("bookmarkItemZoom") private var bookmarkItemZoom = 1.0
    @State private var bookmarkBrowserIsOpen = false
    @AppStorage("browserListItemZoom") private var browserListItemZoom = 1.0
    @AppStorage("browserThumbnailItemZoom") private var browserThumbnailItemZoom = 1.0
    /// Pre-split shared size. Zero means it has already been carried over.
    @AppStorage("browserItemZoom") private var legacyBrowserItemZoom = 0.0
    @AppStorage("browserNameColumnWidth") private var browserNameColumnWidth = 250.0
    @AppStorage("browserSizeColumnWidth") private var browserSizeColumnWidth = 76.0
    @AppStorage("browserKindColumnWidth") private var browserKindColumnWidth = 104.0
    @AppStorage("browserModifiedColumnWidth") private var browserModifiedColumnWidth = 156.0
    @State private var liveBrowserNameColumnWidth: Double?
    @State private var liveBrowserSizeColumnWidth: Double?
    @State private var liveBrowserKindColumnWidth: Double?
    @State private var liveBrowserModifiedColumnWidth: Double?
    @AppStorage("browserShowsSizeColumn") private var browserShowsSizeColumn = true
    @AppStorage("browserShowsKindColumn") private var browserShowsKindColumn = true
    @AppStorage("browserShowsModifiedColumn") private var browserShowsModifiedColumn = true
    @State private var isPreviewExpanded = false
    @State private var pendingTrashItems: [BrowserItem] = []
    @State private var pendingTrashContext: UUID?
    @State private var isBrowserTrashConfirmationPresented = false
    @State private var pendingEmptyFolderScope: BrowserLocation?
    @State private var isEmptyFolderConfirmationPresented = false
    @State private var pendingDSStoreScope: BrowserLocation?
    @State private var isDSStoreConfirmationPresented = false
    @State private var mergeFoldersRequest: MergeFoldersRequest?
    @State private var pendingNewFolderParent: BrowserLocation?
    @State private var newFolderName = ""
    @State private var isNewFolderPresented = false
    @State private var pendingRenameItem: BrowserItem?
    @State private var renameItemName = ""
    @State private var isRenameItemPresented = false
    @State private var editSharedLinkRequest: EditSharedLinkRequest?
    @State private var createOwnedShareRequest: PikPakShareDraft?
    @State private var isChoosingUploadDestination = false
    @FocusState private var browserListFocused: Bool
    @StateObject private var browserNativeMenuPresenter = BrowserNativeMenuPresenter()

    #if HEADER_LAYOUT_TESTS
    // Legacy layout harness now exercises the replacement sidebar.
    var body: some View {
        FinderSidebarLayout(automaticallyHidden: finderSettings.autoHideSidebar) {
            finderSidebar
        } workspace: { Text("Offline workspace").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    #else
    var body: some View {
        workspaceBody
    }
    private var workspaceBody: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            FinderSidebarLayout(automaticallyHidden: finderSettings.autoHideSidebar) {
                finderSidebar
            } workspace: {
              FinderWorkspaceBody {
                GeometryReader { workspace in
                    Group {
                        if !browserSourceIsReady {
                            FinderWorkspaceLoadingOverlay(title: "Waiting for the current PikPak request…")
                        } else if selectedTab == 0 {
                            cloudBrowser
                        } else if selectedTab == 1 {
                            downloader
                        } else if selectedTab == FinderWorkspaceSection.bookmarks.rawValue {
                            bookmarkWorkspace
                        } else if selectedTab >= 4 {
                            PikPakManagementWorkspace(model: model, management: model.pikpakManagement, section: selectedTab,
                                openBrowser: { selectFinderSection(0) },
                                openLocalTransfers: { selectedTransferMode = 2; selectFinderSection(1) })
                        } else {
                            sharedLinkBrowser
                        }
                    }
                    .frame(
                        width: workspace.size.width,
                        height: workspace.size.height,
                        alignment: .topLeading
                    )
                    .task(id: workspaceNavigation.presentationKey) {
                        let presentedSection = selectedTab
                        let request = workspaceNavigation.request
                        await Task.yield()
                        guard !Task.isCancelled, selectedTab == presentedSection else { return }
                        if let request, request.section == presentedSection {
                            workspaceNavigation.didPresent(request.id)
                        }
                        #if WORKSPACE_SWITCH_PROFILING
                        NotificationCenter.default.post(name: .init("PikPakWorkspacePresented"), object: presentedSection)
                        #endif
                    }
                }

            } footer: {
                if FinderWorkspaceSection(rawValue: selectedTab)?.isPikPakManagement == true || (selectedTab == FinderWorkspaceSection.bookmarks.rawValue && !bookmarkBrowserIsOpen) {
                    HStack {
                        Label(model.accountDisplayName ?? "PikPak", systemImage: "person.crop.circle")
                        Spacer()
                        Text("\(FinderWorkspaceSection(rawValue: selectedTab)?.title ?? "PikPak") · Current account")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                        .finderFooterSurface()
                } else if selectedTab == 1 && selectedTransferMode != 2 {
                    activity
                } else { workspaceFooter }
            }
              .overlay { FinderWorkspaceTransitionOverlay(loading: workspaceNavigation.loading) }
            }
        }
        .background { ArchivePasswordPresentation(model: model, activity: model.extractionActivity) }
        .background { FinderDuplicateResultsPresentation(model: model, activity: model.taskActivity) }
        .overlay {
            FileSearchOverlay(search: model.fileSearch) { navigation in
                selectedTab = navigation.match.linkID == nil ? 0 : 3
                // A nested result needs the outline to show its expanded
                // parents. Direct children can retain thumbnail mode.
                if (navigation.match.ancestors.last?.id ?? "") != (model.browserStack.last?.id ?? "") {
                    if navigation.match.linkID == nil { browserViewModeRaw = BrowserViewMode.list.rawValue }
                    else { linksViewModeRaw = BrowserViewMode.list.rawValue }
                }
                model.revealFileSearchResult(navigation)
            }
        }
        .tint(FinderAppearance.accent)
        .accentColor(FinderAppearance.accent)
        .buttonStyle(FinderButtonStyle())
        .focusedSceneValue(\.finderWindowActions, finderWindowActions)
        .background(FinderWindowActionRegistration(actions: finderWindowActions))
        .task(id: "\(selectedTab):\(model.isRunning):\(model.isBrowsingSharedLink)") {
            // A drive switch preserves the chosen tab even while PikPak's
            // foreground request owns its previous source. Activate the
            // requested source as soon as that request releases it.
            guard !browserSourceIsReady, !model.isRunning else { return }
            _ = prepareBrowserSource(for: selectedTab)
        }
        #if WORKSPACE_SWITCH_PROFILING
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PikPakSwitchBenchmark"))) { note in
            if let section = note.object as? Int { selectFinderSection(section) }
        }
        #endif
        .disabled(model.isChangingAccount)
        .onChange(of: finderSettings.layoutResetRevision) { _ in
            isPreviewExpanded = false
            liveBrowserNameColumnWidth = nil; liveBrowserSizeColumnWidth = nil
            liveBrowserKindColumnWidth = nil; liveBrowserModifiedColumnWidth = nil
        }
        .onChange(of: browserViewModeRaw) { value in
            model.setBrowserFilterViewMode(includingExpanded: value == BrowserViewMode.list.rawValue)
        }
        .onChange(of: model.activeAccountID) { _ in
            bookmarkBrowserIsOpen = false
            selectedTab = 0
            isChoosingUploadDestination = false
            isBrowserTrashConfirmationPresented = false; pendingTrashItems = []; pendingTrashContext = nil
            isEmptyFolderConfirmationPresented = false; pendingEmptyFolderScope = nil
            isDSStoreConfirmationPresented = false; pendingDSStoreScope = nil
            mergeFoldersRequest = nil; pendingNewFolderParent = nil; isNewFolderPresented = false
            pendingRenameItem = nil; editSharedLinkRequest = nil
            createOwnedShareRequest = nil
            model.preparePikPakManagement()
        }
        .onDisappear { workspaceNavigation.cancel() }
        .background {
            WindowMinimumSizeController()
                .frame(width: 0, height: 0)
        }
        .onAppear {
            browserViewModeRaw = BrowserViewMode(rawValue: browserViewModeRaw)?.rawValue
                ?? BrowserViewMode.list.rawValue
            model.setBrowserFilterViewMode(includingExpanded: browserViewModeRaw == BrowserViewMode.list.rawValue)
            linksViewModeRaw = BrowserViewMode(rawValue: linksViewModeRaw)?.rawValue
                ?? BrowserViewMode.list.rawValue
            if legacyBrowserItemZoom > 0 {
                // Carry the pre-split size into both modes so the first launch
                // after this change looks unchanged.
                browserListItemZoom = legacyBrowserItemZoom
                browserThumbnailItemZoom = legacyBrowserItemZoom
                legacyBrowserItemZoom = 0
            }
            browserListItemZoom = min(
                max(browserListItemZoom, BrowserItemZoom.minimum),
                BrowserItemZoom.maximum
            )
            browserThumbnailItemZoom = min(
                max(browserThumbnailItemZoom, BrowserItemZoom.minimum),
                BrowserItemZoom.maximum
            )
            _ = prepareBrowserSource(for: selectedTab)
            model.loadBrowserIfReady()
        }
        // Leaving this drive must not cancel transfers. AppDelegate owns shutdown.
        .onDisappear { _ = model.cancelQuickLook(); model.previewPlayer?.pause() }
        .sheet(item: $createOwnedShareRequest) { draft in
            PikPakCreateShareSheet(management: model.pikpakManagement, initialFiles: draft.files)
        }
        .sheet(isPresented: Binding(get: { model.isLoginPresented && !model.loginFromSettings }, set: {
            if !$0 && model.isLoginPresented && !model.loginFromSettings { model.cancelLogin() }
        })) {
            PikPakLoginView(
                reason: model.loginReason,
                currentDeviceID: model.loginDeviceID,
                initialCredentialKind: model.loginCredentialKind,
                onSession: { session in
                    model.completeWebLogin(with: session)
                },
                onCancel: {
                    model.cancelLogin()
                }
            )
        }
        .sheet(item: $mergeFoldersRequest) { request in
            MergeFoldersSheet(
                folders: request.folders,
                initialDestinationID: request.initialDestinationID,
                onMerge: { destinationID in
                    if model.mergeSelectedFolders(keeping: destinationID) {
                        showTaskStatusAfterPresentation()
                    }
                    mergeFoldersRequest = nil
                },
                onCancel: {
                    mergeFoldersRequest = nil
                }
            )
        }
        .alert(browserTrashConfirmationTitle, isPresented: $isBrowserTrashConfirmationPresented) {
            Button("Move to Trash", role: .destructive) {
                if let context = pendingTrashContext {
                    model.trashBrowserItems(pendingTrashItems, expectedContext: context)
                }
                pendingTrashItems = []
                pendingTrashContext = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingTrashItems = []
                pendingTrashContext = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(trashConfirmationMessage(for: pendingTrashItems))
        }
        .alert(
            "Remove Empty Folders?",
            isPresented: $isEmptyFolderConfirmationPresented
        ) {
            Button("Move Empty Folders to Trash", role: .destructive) {
                if let scope = pendingEmptyFolderScope {
                    model.removeEmptyFolders(in: scope)
                    showTaskStatusAfterPresentation()
                }
                pendingEmptyFolderScope = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingEmptyFolderScope = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            let scopeName = pendingEmptyFolderScope?.name ?? "this folder"
            Text(
                "The app will completely scan everything below “\(scopeName)”, then recheck every folder found empty immediately before moving it to PikPak Trash. Any folder containing a file or subfolder is kept. An incomplete or unreadable scan stops safely, and the selected scope itself is always preserved."
            )
        }
        .alert("New Folder", isPresented: $isNewFolderPresented) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                if let parent = pendingNewFolderParent {
                    model.createFolder(named: newFolderName, in: parent)
                }
                pendingNewFolderParent = nil
                newFolderName = ""
            }
            .keyboardShortcut(.defaultAction)
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingNewFolderParent = nil
                newFolderName = ""
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text("Create a folder inside \(pendingNewFolderParent?.path ?? model.currentBrowserPath).")
        }
        .alert(
            pendingRenameItem?.isFolder == true ? "Rename Folder" : "Rename File",
            isPresented: $isRenameItemPresented
        ) {
            TextField("Name", text: $renameItemName)
            Button("Rename") {
                if let item = pendingRenameItem {
                    model.renameBrowserItem(item, to: renameItemName)
                }
                pendingRenameItem = nil
                renameItemName = ""
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                renameItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || renameItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                        == pendingRenameItem?.name
            )
            Button("Cancel", role: .cancel) {
                pendingRenameItem = nil
                renameItemName = ""
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text("Enter a new name for “\(pendingRenameItem?.name ?? "this item")”.")
        }
        .sheet(item: $editSharedLinkRequest) { request in
            EditSharedLinkSheet(
                originalURL: request.url,
                originalPassCode: request.passCode,
                onSave: { url, passCode in
                    model.editSharedLink(request.id, url: url, passCode: passCode)
                    editSharedLinkRequest = nil
                },
                onCancel: { editSharedLinkRequest = nil }
            )
        }
        .alert(
            "Remove .DS_Store Files?",
            isPresented: $isDSStoreConfirmationPresented
        ) {
            Button("Move .DS_Store Files to Trash", role: .destructive) {
                if let scope = pendingDSStoreScope {
                    model.removeDSStoreFiles(in: scope)
                    showTaskStatusAfterPresentation()
                }
                pendingDSStoreScope = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDSStoreScope = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            let scopeName = pendingDSStoreScope?.name ?? "this folder"
            Text(
                "The app will scan everything below “\(scopeName)” and move only regular files whose complete name is exactly “.DS_Store” to PikPak Trash. Every containing folder is checked again before removal; folders and all other files are kept."
            )
        }
    }

    #endif

    private var finderSidebar: some View {
        FinderDriveSidebar(navigation: workspaceNavigation, settings: finderSettings,
            accountTitle: sessionNeedsAttention ? "Sign In / Account" : "Account",
            accountSubtitle: model.accountDisplayName ?? "PikPak", showsContentMode: true, pikpakAccount: model,
            sections: FinderWorkspaceSection.allCases, select: selectFinderSection) {
            if hasStoredSession {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Storage").font(.caption.weight(.semibold))
                        Spacer()
                        Button { model.refreshQuota() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).pointingHandCursor().disabled(model.isQuotaLoading)
                            .help("Refresh storage usage")
                    }
                    if let quota = model.storageQuota {
                        ProgressView(value: quota.usedFraction).tint(quotaUsageColor(for: quota.usedFraction))
                        Text("\(formatStorageBytes(quota.used)) / \(formatStorageBytes(quota.total))")
                            .font(.caption2).monospacedDigit()
                    }
                    Text(quotaRemainingLabel).font(.caption2).foregroundStyle(.secondary)
                    PikPakTransferQuotaSidebar(model: model, monitor: model.transferQuotaMonitor)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func selectFinderSection(_ section: Int) {
        if section == 1 { showTransfers(); return }
        if section == FinderWorkspaceSection.bookmarks.rawValue {
            bookmarkBrowserIsOpen = false
            workspaceNavigation.showImmediately(section)
            return
        }
        if section >= 4 {
            model.preparePikPakManagement()
            workspaceNavigation.showImmediately(section)
            return
        }
        workspaceNavigation.select(section, needsLoading: model.workspaceSwitchNeedsLoading(to: section)) {
            prepareBrowserSource(for: section)
        }
    }

    @ViewBuilder private var bookmarkWorkspace: some View {
        if bookmarkBrowserIsOpen {
            VStack(spacing: 10) {
                HStack {
                    Button { bookmarkBrowserIsOpen = false; _ = model.cancelQuickLook() } label: {
                        Label("Bookmarks", systemImage: "chevron.left")
                    }.help("Back to bookmarked files and folders")
                    Spacer()
                }
                cloudBrowser
            }
        } else { FinderBookmarksWorkspace(store: bookmarks, provider: "pikpak", scope: model.bookmarkScope,
            sourceTitle: model.accountDisplayName ?? "PikPak", canOpen: model.canOpenBookmarks,
            open: { bookmark in
                if model.openBookmark(bookmark, store: bookmarks) { bookmarkBrowserIsOpen = true }
            }, showBrowser: { selectFinderSection(0) }) }
    }

    private var isBookmarkFileBrowser: Bool {
        selectedTab == FinderWorkspaceSection.bookmarks.rawValue && bookmarkBrowserIsOpen
    }

    private func showTransfers() {
        workspaceNavigation.showImmediately(FinderWorkspaceSection.transfers.rawValue)
    }

    private var finderWindowActions: FinderWindowActions {
        let fileWorkspace = browserSourceIsReady && (selectedTab == 0 || selectedTab == 3 || isBookmarkFileBrowser)
        let accountWorkspace = selectedTab == 0 || isBookmarkFileBrowser
        let maintenanceAllowed = browserSourceIsReady && accountWorkspace && !workspaceNavigation.isSwitching && !isChoosingUploadDestination
        return FinderWindowActions(section: selectedTab, viewMode: selectedTab == 7 && !bookmarkBrowserIsOpen ? bookmarkViewModeRaw : browserViewMode.rawValue,
            zoom: selectedTab == 7 && !bookmarkBrowserIsOpen ? bookmarkItemZoom : browserItemZoom,
            undoTitle: model.fileUndoHistory.undoTitle, redoTitle: model.fileUndoHistory.redoTitle,
            canUndo: !workspaceNavigation.isSwitching && !isChoosingUploadDestination && model.canUndoFileAction,
            canRedo: !workspaceNavigation.isSwitching && !isChoosingUploadDestination && model.canRedoFileAction,
            undo: { model.performFileUndo(redo: false) }, redo: { model.performFileUndo(redo: true) },
            canRefresh: fileWorkspace && model.canBrowse,
            canGoBack: fileWorkspace && model.canGoBack,
            canUpload: fileWorkspace && accountWorkspace && model.canUploadFiles && !isChoosingUploadDestination,
            canDownload: fileWorkspace && model.canDownloadSelectedBrowserItem && !isChoosingUploadDestination,
            canCreateFolder: fileWorkspace && accountWorkspace && model.canCreateFolder && !isChoosingUploadDestination,
            canTrash: fileWorkspace && accountWorkspace && model.canTrashSelectedBrowserItem && !isChoosingUploadDestination,
            canCheckDuplicates: maintenanceAllowed && model.canScanCurrentFolderForDuplicates,
            canReviewDuplicates: model.duplicateScan != nil,
            canRemoveEmptyFolders: maintenanceAllowed && model.canRemoveEmptyFolders,
            canRemoveDSStoreFiles: maintenanceAllowed && model.canRemoveDSStoreFiles,
            canMergeFolders: maintenanceAllowed && model.canMergeSelectedFolders,
            checkDuplicates: {
                guard maintenanceAllowed, !workspaceNavigation.isSwitching else { return }
                model.scanCurrentFolderForDuplicates()
                showTaskStatusAfterPresentation()
            },
            findSimilarFiles: { model.fileSimilarity.presentNewScan() },
            reviewDuplicates: { model.taskActivity.showsDuplicateResults = true },
            removeEmptyFolders: requestEmptyFolderCleanup,
            removeDSStoreFiles: requestDSStoreCleanup,
            mergeFolders: { requestMergeSelectedFolders() },
            showStatus: { model.taskActivity.showsDetails = true },
            selectSection: selectFinderSection,
            setViewMode: setFinderViewMode, adjustZoom: adjustBrowserZoom,
            resetZoom: resetBrowserZoom,
            refresh: { if !workspaceNavigation.isSwitching { model.refreshBrowser() } },
            goBack: { if !workspaceNavigation.isSwitching { model.goBack() } },
            upload: {
                guard !workspaceNavigation.isSwitching else { return }
                if model.chooseFilesToUploadInCurrentBrowserFolder() {
                    selectedTransferMode = 1; selectedTab = 1
                }
            },
            download: {
                guard !workspaceNavigation.isSwitching else { return }
                model.downloadSelectedBrowserItem(); selectedTransferMode = 0; selectedTab = 1
            },
            newFolder: { if !workspaceNavigation.isSwitching { requestNewFolder() } },
            trash: { if !workspaceNavigation.isSwitching { requestTrashForBrowserSelection() } },
            supportsPikPakManagement: true,
            canToggleFolder: fileWorkspace && browserViewMode == .list && !workspaceNavigation.isSwitching
                && !isChoosingUploadDestination && model.canToggleFocusedBrowserFolder,
            toggleFolderTitle: model.focusedBrowserFolderToggleTitle,
            toggleFolder: { model.toggleFocusedBrowserFolder() })
    }

    private func setFinderViewMode(_ value: Int) {
        guard !workspaceNavigation.isSwitching else { return }
        if selectedTab == 7 && !bookmarkBrowserIsOpen { bookmarkViewModeRaw = value }
        else if model.isBrowsingSharedLink { linksViewModeRaw = value }
        else { browserViewModeRaw = value }
    }

    private func finderPathFooter(compact: Bool) -> some View {
        let path = model.browserFooterLocations
        return HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).pointingHandCursor().disabled(!model.canGoBack)
                .help("Back · Command-[")
            if compact, let current = path.last, path.count > 1 {
                Menu {
                    ForEach(Array(path.dropLast().enumerated()), id: \.offset) { depth, location in
                        Button("\(String(repeating: "\u{2003}", count: depth))\(location.name)") {
                            model.navigateFooter(to: location)
                        }
                    }
                } label: { Text("…") }
                .menuStyle(.borderlessButton).fixedSize().help("All parent folders")
                footerPathButton(current, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else { ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    ForEach(Array(path.enumerated()), id: \.offset) { index, location in
                        if index > 0 { browserBreadcrumbSeparator }
                        footerPathButton(location, compact: false)
                    }
                }.fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 5) {
                    if path.count > 2 {
                        Menu {
                            ForEach(Array(path.dropLast().enumerated()), id: \.offset) { depth, location in
                                Button("\(String(repeating: "\u{2003}", count: depth))\(location.name)") {
                                    model.navigateFooter(to: location)
                                }
                            }
                        } label: { Text("…") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("All parent folders")
                        browserBreadcrumbSeparator
                    }
                    ForEach(Array(path.suffix(2).enumerated()), id: \.offset) { index, location in
                        if index > 0 { browserBreadcrumbSeparator }
                        footerPathButton(location, compact: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private func footerPathButton(_ location: BrowserLocation, compact: Bool) -> some View {
        let isFile = location.id == model.selectedBrowserItem?.id && model.selectedBrowserItem?.isFolder == false
        return Button { model.navigateFooter(to: location) } label: {
            Label(location.name, systemImage: isFile ? "doc" : (location.id.isEmpty ? "externaldrive" : "folder"))
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: compact ? 24 : nil, maxWidth: compact ? 210 : nil, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .disabled(isFile || !model.canBrowse)
        .browserDropCanvas(model: model, destination: isFile ? nil : location, compact: true) {
            selectedTransferMode = 1; selectedTab = 1
        }
        .help(location.path)
    }


    private func prepareBrowserSource(for tab: Int) -> Bool {
        switch tab {
        case 0:
            return model.activateAccountBrowser()
        case 3:
            return model.activateSharedLinkBrowser()
        default:
            return true
        }
    }

    /// Navigation, selection and operation feedback share one stable row.
    /// Narrow windows keep an explicit Error label and put long text in details.
    private var workspaceFooter: some View {
        GeometryReader { geometry in
            let fileWorkspace = browserSourceIsReady && (selectedTab == 0 || selectedTab == 3 || isBookmarkFileBrowser)
            let compact = fileWorkspace && geometry.size.width < 880
            let compactPath = geometry.size.width < 700
            HStack(spacing: 10) {
                if fileWorkspace {
                    finderPathFooter(compact: compactPath)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(compactPath ? compactBrowserSelectionSummary : browserSelectionSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(browserSelectionSummary)
                        .layoutPriority(1)
                    Divider().frame(height: 14)
                }
                FinderFooterStatus(
                    model: model, activity: model.taskActivity,
                    message: model.status,
                    isError: model.statusIsError,
                    isBusy: model.isRunning || model.hasOtherBackgroundActivity || model.isPreparingQuickLook,
                    diagnostic: model.statusErrorDiagnostic,
                    compact: compact,
                    openTransfers: showTransfers,
                    openActivity: model.activityLog.entries.isEmpty ? nil : showActivityLog
                )
                .frame(maxWidth: fileWorkspace && !compact ? 280 : (compact ? nil : .infinity))
                .fixedSize(horizontal: compact, vertical: false)
                .layoutPriority(2)

                ArchiveActivityFooter(model: model, activity: model.extractionActivity,
                    compact: geometry.size.width < 880) { id in
                    if model.revealArchiveOutput(id) {
                        model.extractionActivity.showsActivity = false
                        selectedTab = 0
                    }
                }

                FinderFileOpenStatus(opener: model.fileOpener, compact: geometry.size.width < 880)

                if !model.activityLog.entries.isEmpty {
                    Button(action: showActivityLog) {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .fixedSize()
                    .help("Open Activity Log")
                    .accessibilityLabel("Open Activity Log")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .finderFooterSurface()
    }

    private func showActivityLog() {
        selectedTab = 1
        activityExpanded = true
    }

    private var compactBrowserSelectionSummary: String {
        let count = model.browserActionSelectionCount
        if count > 0 { return "\(count.formatted()) selected" }
        if model.isBrowsingSharedLink { return "\(model.sharedLinks.count.formatted()) links" }
        return "\(displayedBrowserItemCount.formatted()) shown"
    }

    private var displayedBrowserItemCount: Int {
        browserViewMode == .thumbnails ? model.displayedBrowserItems.count : model.displayedBrowserTreeEntries.count
    }


    private var quotaRemainingLabel: String {
        if let quota = model.storageQuota {
            return "\(formatStorageBytes(quota.remaining)) remaining"
        }
        if model.isQuotaLoading {
            return "Loading capacity…"
        }
        return model.storageQuotaError == nil ? "Click to refresh" : "Unavailable — click to retry"
    }


    private func quotaUsageColor(for fraction: Double) -> Color { storageUsageColor(for: fraction) }


    private var hasStoredSession: Bool { model.hasAccountSession }

    private var sessionNeedsAttention: Bool {
        model.requiresDedicatedSignIn || model.accountLoginStatus == .needsSignIn
    }

    private var accountStateSubtitle: String {
        if sessionNeedsAttention { return "Open Accounts in Settings to sign in again" }
        return hasStoredSession ? "Manage accounts in Settings" : "Sign in to browse your cloud files"
    }

    private var sharedLinkBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SharedLinkInputBar(
                    url: $model.shareURLInput,
                    passcode: $model.sharePasscodeInput,
                    canSubmit: model.canOpenShareLink,
                    onSubmit: { model.openSharedLink() }
                )

                HStack(spacing: 12) {
                    Label(
                        "Links use this app's private desktop session, including Save to My PikPak. Safari's separate Web session is never read or refreshed.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let progress = model.sharedLinkRetryProgress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Retrying links: \(progress.completed.formatted()) of \(progress.total.formatted())")
                                .font(.caption).monospacedDigit()
                        }
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Retrying failed links")
                        .accessibilityValue("\(progress.completed) of \(progress.total) completed")
                    } else if model.failedSharedLinkCount > 0 {
                        Button { model.retryAllFailedSharedLinks() } label: {
                            Label("Retry Failed Links (\(model.failedSharedLinkCount.formatted()))", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered).pointingHandCursor()
                        .fixedSize()
                        .disabled(!model.canRetryFailedSharedLinks)
                        .help("Retry every failed link using its saved access code. Links already open or loading are skipped.")
                        .accessibilityLabel("Retry All Failed Links")
                        .accessibilityValue("\(model.failedSharedLinkCount) failed \(model.failedSharedLinkCount == 1 ? "link" : "links")")
                    }
                }

                if let message = model.shareLinkFeedbackMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if model.shareLinkFeedbackTone == .progress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: shareLinkFeedbackSymbol)
                                .foregroundStyle(shareLinkFeedbackColor)
                        }
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(
                                model.shareLinkFeedbackTone == .error
                                    ? Color.red
                                    : Color.primary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if model.shareLinkFeedbackTone == .error {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless).pointingHandCursor()
                            .controlSize(.small)
                            .help("Copy error")
                            .accessibilityLabel("Copy shared-link error")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        shareLinkFeedbackColor.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityElement(children: .contain)
                }
            }
            .appCard(padding: 10)

            if !model.sharedLinks.isEmpty {
                cloudBrowser
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.blue.opacity(0.09))
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 68, height: 68)

                    Text("Add a PikPak shared folder")
                        .font(.title3.weight(.semibold))
                    Text("Paste an official https://mypikpak.com/s/… link above. Every URL becomes an expandable root in the Finder-style file tree.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .appCard(padding: 0)
            }
        }
    }

    private var shareLinkFeedbackColor: Color {
        switch model.shareLinkFeedbackTone {
        case .progress: return .blue
        case .success: return .green
        case .error: return .red
        case .info: return .secondary
        }
    }

    private var shareLinkFeedbackSymbol: String {
        switch model.shareLinkFeedbackTone {
        case .progress: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var cloudBrowser: some View {
        VStack(spacing: 12) {
            if !model.showsSharedLinkOverview { browserToolbar }
            if isChoosingUploadDestination { uploadDestinationChooserBar.appCard(padding: 10) }
            if !model.isBrowsingSharedLink && !hasStoredSession {
                FinderDriveConnection(kind: .pikpak, busy: model.isLoginPresented) { model.signIn() }
            } else {
                FinderBrowserSplit(showsPreview: finderSettings.showsPreviewPane,
                    expanded: isPreviewExpanded && model.selectedBrowserItem != nil,
                    resetRevision: finderSettings.layoutResetRevision) {
                    browserContent
                } preview: { previewPane }
                .onChange(of: model.selectedBrowserItemID) { if $0 == nil { isPreviewExpanded = false } }
            }
        }
    }

    private var uploadDestinationCandidate: BrowserLocation {
        if let item = model.selectedBrowserItem, item.isFolder { return model.browserLocation(for: item) }
        return model.browserStack.last ?? .root
    }

    private var uploadDestinationChooserBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.blue)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Choose upload destination")
                    .font(.callout.weight(.semibold))
                Text(uploadDestinationCandidate.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(uploadDestinationCandidate.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel") {
                isChoosingUploadDestination = false
                selectedTransferMode = 1
                selectedTab = 1
            }
            .keyboardShortcut(.cancelAction)

            Button {
                model.setUploadDestination(uploadDestinationCandidate)
                isChoosingUploadDestination = false
                selectedTransferMode = 1
                selectedTab = 1
            } label: {
                Label(
                    model.selectedBrowserItem?.isFolder == true
                        ? "Use Selected Folder"
                        : "Use This Folder",
                    systemImage: "checkmark.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent).pointingHandCursor()
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRunning || model.isBrowsingSharedLink)
        }
    }

    private func beginUploadDestinationSelection() {
        guard model.canChooseUploadDestination,
              model.activateAccountBrowser()
        else { return }
        model.browserFileFilter = .all
        isChoosingUploadDestination = true
        selectedTab = 0
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            if model.activeBrowserFileFilter.isActive {
                BrowserFileFilterBar(filter: $model.browserFileFilter,
                    count: model.displayedBrowserFileCount(includingExpanded: browserViewMode == .list),
                    hiddenFolders: model.displayedBrowserHiddenFolderCount(includingExpanded: browserViewMode == .list))
                Divider()
            }
            if let progress = model.browserFolderExpansionProgress {
                BrowserFolderExpansionBar(progress: progress) {
                    model.cancelBrowserFolderExpansion()
                }
                Divider()
            }
            if browserViewMode == .thumbnails {
                if model.showsSharedLinkOverview { sharedLinkThumbnailGrid }
                else { browserThumbnailGrid }
            } else {
                browserList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.showsSharedLinkOverview,
               model.hasMoreBrowserItems || (model.isBrowserLoading && !model.browserItems.isEmpty) {
                browserThumbnailPaginationFooter
            }
        }
        .browserDropCanvas(
            model: model,
            destination: model.isBrowsingSharedLink ? nil : model.browserStack.last,
            springLoadsFolders: browserViewMode == .list
        ) {
            selectedTransferMode = 1
            selectedTab = 1
        }
        .onChange(of: model.browserFileFilter) { _ in
            if model.selectedBrowserItem != nil { browserListFocused = true }
        }
    }

    private var browserViewMode: BrowserViewMode {
        BrowserViewMode(rawValue: model.isBrowsingSharedLink ? linksViewModeRaw : browserViewModeRaw) ?? .list
    }

    /// Native View commands apply to either file workspace. Each workspace
    /// remembers its own mode; item sizes remain shared per presentation type.
    private var zoomedBrowserViewMode: BrowserViewMode {
        browserViewMode
    }

    private var browserItemZoom: Double {
        zoomedBrowserViewMode == .thumbnails
            ? browserThumbnailItemZoom
            : browserListItemZoom
    }

    private func setBrowserItemZoom(_ value: Double) {
        if zoomedBrowserViewMode == .thumbnails {
            browserThumbnailItemZoom = value
        } else {
            browserListItemZoom = value
        }
    }

    private var browserZoomScale: CGFloat {
        CGFloat(
            min(
                max(browserItemZoom, BrowserItemZoom.minimum),
                BrowserItemZoom.maximum
            )
        )
    }

    private var browserZoomPercent: Int {
        Int((browserZoomScale * 100).rounded())
    }

    private func adjustBrowserZoom(by delta: Double) {
        guard !workspaceNavigation.isSwitching else { return }
        let isBookmarkRoot = selectedTab == 7 && !bookmarkBrowserIsOpen
        let adjusted = min(
            max((isBookmarkRoot ? bookmarkItemZoom : browserItemZoom) + delta, BrowserItemZoom.minimum),
            BrowserItemZoom.maximum
        )
        withAnimation(.easeOut(duration: 0.14)) {
            if isBookmarkRoot { bookmarkItemZoom = (adjusted * 100).rounded() / 100 }
            else { setBrowserItemZoom((adjusted * 100).rounded() / 100) }
        }
    }

    private func resetBrowserZoom() {
        guard !workspaceNavigation.isSwitching else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            if selectedTab == 7 && !bookmarkBrowserIsOpen { bookmarkItemZoom = 1 }
            else { setBrowserItemZoom(1) }
        }
    }

    private func browserTreeColumns(fitting viewportWidth: CGFloat) -> BrowserTreeColumnLayout {
        BrowserTreeColumnLayout(
            name: liveBrowserNameColumnWidth ?? browserNameColumnWidth,
            size: liveBrowserSizeColumnWidth ?? browserSizeColumnWidth,
            kind: liveBrowserKindColumnWidth ?? browserKindColumnWidth,
            modified: liveBrowserModifiedColumnWidth ?? browserModifiedColumnWidth,
            showsSize: browserShowsSizeColumn,
            showsKind: browserShowsKindColumn,
            showsModified: browserShowsModifiedColumn,
            scale: browserZoomScale,
            actionWidth: model.isBrowsingSharedLink ? 64 : 32
        )
        .filling(width: viewportWidth)
    }

    private func resizeBrowserColumn(_ column: BrowserSortColumn, to width: CGFloat) {
        let bounded = BrowserTreeColumnLimits.clamped(width, for: column)
        switch column {
        case .name:
            liveBrowserNameColumnWidth = Double(bounded)
        case .size:
            liveBrowserSizeColumnWidth = Double(bounded)
        case .kind:
            liveBrowserKindColumnWidth = Double(bounded)
        case .modified:
            liveBrowserModifiedColumnWidth = Double(bounded)
        }
    }

    /// Persist only the pointer-up width. AppStorage publishes through
    /// UserDefaults, so writing on every mouse move can deliver competing
    /// layout generations to rows retained by LazyVStack.
    private func finishBrowserColumnResize(
        _ column: BrowserSortColumn,
        at width: CGFloat
    ) {
        let bounded = Double(BrowserTreeColumnLimits.clamped(width, for: column))
        switch column {
        case .name:
            browserNameColumnWidth = bounded
            liveBrowserNameColumnWidth = nil
        case .size:
            browserSizeColumnWidth = bounded
            liveBrowserSizeColumnWidth = nil
        case .kind:
            browserKindColumnWidth = bounded
            liveBrowserKindColumnWidth = nil
        case .modified:
            browserModifiedColumnWidth = bounded
            liveBrowserModifiedColumnWidth = nil
        }
    }

    private func toggleBrowserColumn(_ column: BrowserSortColumn) {
        let willHide: Bool
        switch column {
        case .name:
            return
        case .size:
            browserShowsSizeColumn.toggle()
            willHide = !browserShowsSizeColumn
        case .kind:
            browserShowsKindColumn.toggle()
            willHide = !browserShowsKindColumn
        case .modified:
            browserShowsModifiedColumn.toggle()
            willHide = !browserShowsModifiedColumn
        }
        if willHide, model.browserSortColumn == column {
            model.toggleBrowserSort(.name)
        }
    }

    private func resetBrowserColumns() {
        liveBrowserNameColumnWidth = nil
        liveBrowserSizeColumnWidth = nil
        liveBrowserKindColumnWidth = nil
        liveBrowserModifiedColumnWidth = nil
        browserNameColumnWidth = 250
        browserSizeColumnWidth = 76
        browserKindColumnWidth = 104
        browserModifiedColumnWidth = 156
        browserShowsSizeColumn = true
        browserShowsKindColumn = true
        browserShowsModifiedColumn = true
    }

    private var browserToolbar: some View {
        FinderBrowserToolbar(viewMode: Binding(
            get: { model.isBrowsingSharedLink ? linksViewModeRaw : browserViewModeRaw },
            set: setFinderViewMode), zoom: browserItemZoom,
            connected: model.canBrowse, canGoBack: model.canGoBack,
            canImport: model.canUploadFiles && !isChoosingUploadDestination,
            canExport: model.canDownloadSelectedBrowserItem && !isChoosingUploadDestination,
            canTrash: model.canTrashSelectedBrowserItem && !isChoosingUploadDestination,
            canCreate: model.canCreateFolder && !isChoosingUploadDestination,
            share: model.isBrowsingSharedLink ? nil : { requestOwnedShare() },
            canShare: !model.selectedBrowserItems.isEmpty && !model.isManagingCloudItems && !isChoosingUploadDestination,
            merge: model.isBrowsingSharedLink ? nil : { requestMergeSelectedFolders() },
            canMerge: finderWindowActions.canMergeFolders,
            fileTypeFilter: model.isBrowsingSharedLink ? nil : $model.browserFileFilter,
            fileExtensions: model.availableBrowserFileExtensions(includingExpanded: browserViewMode == .list),
            hidesEmptyFolders: model.isBrowsingSharedLink ? nil : $model.hidesEmptyFolders,
            back: { model.goBack() }, search: { model.presentFileSearch(scope: .expanded) },
            importFiles: {
                if model.chooseFilesToUploadInCurrentBrowserFolder() { selectedTransferMode = 1; selectedTab = 1 }
            }, exportFiles: {
                model.downloadSelectedBrowserItem(); selectedTransferMode = 0; selectedTab = 1
            }, trash: requestTrashForBrowserSelection, create: { requestNewFolder() },
            refresh: { model.refreshBrowser() }, adjustZoom: adjustBrowserZoom, resetZoom: resetBrowserZoom,
            sort: model.toggleBrowserSort) {
                browserBreadcrumb
            }
    }

    /// Finder-style path control. `ViewThatFits` tests the complete intrinsic
    /// path first; once it no longer fits the toolbar, the fallback always
    /// keeps the current folder and its immediate parent visible. The omitted
    /// ancestry remains available from the leading ellipsis menu.
    private var browserBreadcrumb: some View {
        ViewThatFits(in: .horizontal) {
            fullBrowserBreadcrumb
                .fixedSize(horizontal: true, vertical: false)
            compactBrowserBreadcrumb
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current PikPak path: \(browserBreadcrumbPathLabel)")
    }

    private var fullBrowserBreadcrumb: some View {
        HStack(spacing: 5) {
            ForEach(Array(model.browserStack.enumerated()), id: \.offset) { index, location in
                if index > 0 {
                    browserBreadcrumbSeparator
                }
                browserBreadcrumbButton(location, compact: false)
            }
        }
    }

    private var compactBrowserBreadcrumb: some View {
        let visibleLocations = Array(model.browserStack.suffix(2))
        return HStack(spacing: 5) {
            if model.browserStack.count > visibleLocations.count {
                browserBreadcrumbAncestorMenu
                browserBreadcrumbSeparator
            }

            ForEach(Array(visibleLocations.enumerated()), id: \.offset) { index, location in
                if index > 0 {
                    browserBreadcrumbSeparator
                }
                browserBreadcrumbButton(location, compact: true)
                    .layoutPriority(index == visibleLocations.count - 1 ? 2 : 1)
            }
        }
    }

    private var browserBreadcrumbAncestorMenu: some View {
        Menu {
            ForEach(Array(model.browserStack.dropLast().enumerated()), id: \.offset) { depth, location in
                Button {
                    model.selectBreadcrumb(location)
                } label: {
                    Label {
                        Text("\(String(repeating: "\u{2003}", count: depth))\(location.name)")
                    } icon: {
                        Image(systemName: depth == 0
                            ? (model.isBrowsingSharedLink ? "link" : "externaldrive.fill")
                            : "folder.fill")
                    }
                }
                .disabled(model.isRunning)
            }
        } label: {
            Text("…")
                .font(.headline)
                .frame(minWidth: 24, minHeight: 22)
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isRunning)
        .help("Show all parent folders")
        .accessibilityLabel("Show all parent folders")
    }

    private var browserBreadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func browserBreadcrumbButton(
        _ location: BrowserLocation,
        compact: Bool
    ) -> some View {
        let isCurrent = location == model.browserStack.last
        return Button {
            if !isCurrent {
                model.selectBreadcrumb(location)
            }
        } label: {
            Text(location.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !compact, vertical: false)
                .frame(
                    minWidth: compact ? 52 : nil,
                    maxWidth: compact ? 190 : nil,
                    alignment: .leading
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain).pointingHandCursor()
        .foregroundStyle(isCurrent ? Color.primary : Color.blue)
        .disabled(model.isRunning)
        .browserDropCanvas(
            model: model,
            destination: location,
            compact: true
        ) {
            selectedTransferMode = 1
            selectedTab = 1
        }
        .help(isCurrent ? "Current folder: \(location.path)" : "Go to \(location.path)")
        .accessibilityLabel(isCurrent
            ? "Current folder, \(location.name)"
            : "Go to \(location.name)")
    }

    private var browserBreadcrumbPathLabel: String {
        model.browserStack.map(\.name).joined(separator: " > ")
    }

    private var browserList: some View {
        let entries = model.displayedBrowserTreeEntries
        let hasOutlineRows = model.showsSharedLinkOverview
            ? !model.sharedLinks.isEmpty
            : !entries.isEmpty
        return ScrollViewReader { scrollProxy in
            ZStack {
                GeometryReader { viewport in
                    let columns = browserTreeColumns(fitting: viewport.size.width)
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            BrowserTreeHeader(
                                columns: columns,
                                sortColumn: model.browserSortColumn,
                                sortDirection: model.browserSortDirection,
                                onSort: model.toggleBrowserSort,
                                onResize: resizeBrowserColumn,
                                onResizeEnded: finishBrowserColumnResize,
                                onToggleVisibility: toggleBrowserColumn,
                                onResetColumns: resetBrowserColumns,
                                actionTitle: model.isBrowsingSharedLink ? "Tools" : nil
                            )

                            Divider()

                            if !hasOutlineRows && !model.isBrowserLoading {
                                ZStack {
                                    browserBlankSelectionTarget

                                    if model.activeBrowserFileFilter.isActive {
                                        BrowserFileFilterEmptyState(filter: $model.browserFileFilter, hasMore: model.hasMoreBrowserItems)
                                    } else if model.displayedBrowserHiddenFolderCount(includingExpanded: true) > 0 {
                                        BrowserEmptyFoldersEmptyState(hidesEmptyFolders: $model.hidesEmptyFolders)
                                    } else {
                                    VStack(spacing: 10) {
                                        ZStack {
                                            Circle()
                                                .fill(Color.secondary.opacity(0.08))
                                            Image(systemName: "folder")
                                                .font(.system(size: 30))
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(width: 66, height: 66)
                                        Text("This folder is empty")
                                            .font(.headline)
                                        Text("Refresh to check for newly added files.")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Button("Refresh") {
                                            model.refreshBrowser()
                                        }
                                        .disabled(!model.canBrowse)
                                    }
                                    }
                                }
                                .frame(width: columns.tableWidth, alignment: .center)
                                .frame(maxHeight: .infinity, alignment: .center)
                            } else {
                                ScrollView(.vertical) {
                                    ZStack(alignment: .topLeading) {
                                        browserBlankSelectionTarget

                                        Group {
                                            if model.showsSharedLinkOverview {
                                                sharedLinkTreeRows(
                                                    columns: columns
                                                )
                                            } else {
                                                browserTreeRows(entries, columns: columns)
                                            }
                                        }
                                        .frame(width: columns.tableWidth, alignment: .leading)
                                    }
                                    .frame(width: columns.tableWidth, alignment: .leading)
                                    .frame(
                                        minHeight: max(
                                            viewport.size.height - columns.headerHeight - 1,
                                            0
                                        ),
                                        alignment: .top
                                    )
                                }
                            }
                        }
                        .frame(
                            width: columns.tableWidth,
                            height: viewport.size.height,
                            alignment: .topLeading
                        )
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                // The Links overview keeps its scroll/focus while another
                // link is selected. Entered folders reset just like Browser.
                .id(model.browserPresentationIdentity)
                .focusable()
                .focused($browserListFocused)
                .hideKeyboardFocusEffectWhenAvailable()
                .onMoveCommand { direction in
                    let modifiers = NSEvent.modifierFlags.intersection(
                        .deviceIndependentFlagsMask
                    )
                    moveBrowserSelection(
                        direction,
                        extendingSelection: modifiers.contains(.shift),
                        scrollProxy: scrollProxy
                    )
                }
                .accessibilityLabel("Cloud files")
                .accessibilityHint(
                    model.showsSharedLinkOverview
                        ? "Each link shows its files and folders. Use folder disclosure buttons to expand or collapse, or double-click a folder to open it."
                        : "Use Up and Down to select rows, Shift with Up or Down to extend the selection, Left and Right to collapse or expand folders, Return to open a folder, Space to Quick Look the selected file, and Command Delete to move selected items to Trash."
                )
                .onChange(of: model.selectedBrowserItemID) { _ in
                    model.browserSelectionChanged()
                    if model.isQuickLookSessionActive, let selected = model.selectedBrowserItemID {
                        scrollProxy.scrollTo(browserRowScrollID(selected), anchor: .center)
                    }
                }
                .task(id: model.browserScrollRestoreRequest?.id) {
                    guard let request = model.browserScrollRestoreRequest else { return }
                    // Allow the LazyVStack to lay out the restored folder page
                    // before jumping directly to the remembered row.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard
                        !Task.isCancelled,
                        model.browserScrollRestoreRequest?.id == request.id
                    else { return }
                    scrollProxy.scrollTo(
                        browserRowScrollID(request.itemID),
                        anchor: .center
                    )
                    if request.focusesBrowser { browserListFocused = true }
                    model.completeBrowserScrollRestoration(request.id)
                }
                .background {
                    BrowserKeyboardMonitor(
                        handlesRangeSelection: browserListFocused
                            && model.canChangeBrowserSelection
                            && !model.isLoginPresented
                            && !isBrowserTrashConfirmationPresented,
                        handlesDelete: model.canTrashSelectedBrowserItem
                            && !model.isLoginPresented
                            && !isBrowserTrashConfirmationPresented,
                        handlesZoom: true,
                        handlesQuickLook: !model.isLoginPresented
                            && !isBrowserTrashConfirmationPresented,
                        onShiftMove: { direction in
                            moveBrowserSelection(
                                direction,
                                extendingSelection: true,
                                scrollProxy: scrollProxy
                            )
                        },
                        onCommandDelete: {
                            requestTrashForBrowserSelection()
                        },
                        onZoomIn: {
                            adjustBrowserZoom(by: BrowserItemZoom.step)
                        },
                        onZoomOut: {
                            adjustBrowserZoom(by: -BrowserItemZoom.step)
                        },
                        onActualSize: {
                            resetBrowserZoom()
                        },
                        onQuickLook: { window in
                            guard !workspaceNavigation.isSwitching else { return false }
                            return model.toggleQuickLookForSelection(in: window)
                        },
                        onCancelQuickLook: model.cancelQuickLook,
                        ownsQuickLookPanel: model.ownsQuickLookPanel,
                        handlesSelectAll: canSelectAllBrowserFolders,
                        onSelectAllFolders: selectAllBrowserFolders,
                        handlesPreviewNavigation: canMovePreviewSelection && !browserListFocused,
                        handlesPreviewNavigationFromControls: canMovePreviewSelection,
                        onPreviewMove: { offset in
                            movePreviewSelection(by: offset, scrollProxy: scrollProxy)
                        }
                    )
                    .frame(width: 0, height: 0)
                }

                if model.isBrowserLoading && !model.isBrowsingSharedLink {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Contacting PikPak…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func browserTreeRows(
        _ entries: [BrowserTreeEntry],
        columns: BrowserTreeColumnLayout
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // Use the cloud item's stable id, not its current flattened index.
            // Expanding a folder inserts child rows and shifts every following
            // index; index identity can make SwiftUI recycle a collapsed
            // disclosure for a different, expanded folder.
            let actionSelectionCount = model.browserActionSelectionCount
            ForEach(BrowserIndexedRows(rows: entries)) { indexed in
                browserTreeRow(
                    indexed.entry,
                    rowIndex: indexed.index,
                    columns: columns,
                    actionSelectionCount: actionSelectionCount,
                    sharedLinkID: model.isBrowsingSharedLink ? model.activeSharedLinkID : nil,
                    usesMenuCanvas: true
                )
                .accessibilityAction(named: Text("Show Context Menu")) {
                    browserNativeMenuPresenter.show(row: indexed.index)
                }
            }
        }
        .overlay {
            BrowserNativeContextMenuCanvas(rowHeight: max(24, 29 * browserZoomScale), rowCount: entries.count,
                presenter: browserNativeMenuPresenter) { index in
                let item = entries[index].item
                let linkID = model.isBrowsingSharedLink ? model.activeSharedLinkID : nil
                return item.isFolder
                    ? browserFolderNativeMenu(item, sharedLinkID: linkID, actionSelectionCount: model.browserActionSelectionCount,
                        showsCollapse: model.expandedBrowserFolderIDs.contains(item.id))
                    : browserFileNativeMenu(item, sharedLinkID: linkID, actionSelectionCount: model.browserActionSelectionCount)
            }
        }
    }

    private func sharedLinkTreeRows(
        columns: BrowserTreeColumnLayout
    ) -> some View {
        let links = sortedSharedLinks
        let actionSelectionCount = model.browserActionSelectionCount
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { linkIndex, link in
                SharedLinkTreeRow(
                    entry: link,
                    zoomScale: browserZoomScale,
                    columns: columns,
                    isSelected: model.selectedSharedLinkRootID == link.id,
                    usesAlternateBackground: linkIndex.isMultiple(of: 2),
                    measurement: model.cachedSharedLinkMeasurement(for: link.id),
                    isMeasuring: model.isMeasuringSharedLink(link.id),
                    isQueued: model.isSharedLinkMeasurementQueued(link.id),
                    canMeasure: model.canMeasureSharedLink(link.id),
                    canEditLink: model.canEditSharedLink(link.id),
                    canDisconnect: model.canDisconnectSharedLink(link.id),
                    onSelect: {
                        activateSharedLinkRoot(link)
                    },
                    onMeasure: {
                        model.measureSharedLink(link.id)
                    },
                    onEditLink: {
                        beginSharedLinkEdit(link)
                    },
                    onCopyLink: {
                        model.copySharedLinkURL(link.id)
                    },
                    onRetry: {
                        model.retrySharedLink(link.id)
                    },
                    onDisconnect: {
                        model.removeSharedLink(link.id)
                    }
                )
                .id("shared-link-\(link.id.uuidString)")

                if model.sharedLinkHasContents(link.id) {
                    let linkEntries = model.sharedLinkTreeEntries(for: link.id)
                    ForEach(Array(linkEntries.enumerated()), id: \.element.id) { itemIndex, entry in
                        browserTreeRow(
                            BrowserTreeEntry(item: entry.item, depth: entry.depth + 1),
                            rowIndex: linkIndex + itemIndex + 1,
                            columns: columns,
                            actionSelectionCount: actionSelectionCount,
                            sharedLinkID: link.id
                        )
                    }
                }
            }
        }
    }

    /// The View menu can switch Links to thumbnails without dropping other
    /// link headers or borrowing the active link's metadata/selection.
    private var sharedLinkThumbnailGrid: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { viewport in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        browserBlankSelectionTarget
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(sortedSharedLinks) { link in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 8) {
                                        FinderRowAction(title: "Remove link from this app (keeps cloud files)",
                                            symbol: "xmark", tint: .red, enabled: model.canDisconnectSharedLink(link.id), hintOnRight: true) {
                                            model.removeSharedLink(link.id)
                                        }
                                        .accessibilityLabel("Disconnect shared link \(link.url)")
                                        Button { activateSharedLinkRoot(link) } label: {
                                            Label(link.url, systemImage: "link")
                                                .lineLimit(1).truncationMode(.middle)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain).pointingHandCursor().help(link.url)
                                        if link.state == .loading { ProgressView().controlSize(.small) }
                                    }
                                    .padding(10)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                    if model.sharedLinkHasContents(link.id) {
                                        let entries = model.sharedLinkTreeEntries(for: link.id)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132 * browserZoomScale), spacing: 12)], spacing: 12) {
                                            ForEach(entries) { entry in
                                                browserThumbnailItem(entry.item, scale: browserZoomScale,
                                                    actionSelectionCount: model.browserActionSelectionCount,
                                                    sharedLinkID: link.id)
                                                .id("\(link.id.uuidString)|\(entry.item.id)")
                                            }
                                        }
                                        if entries.isEmpty {
                                            Text("This folder is empty").font(.caption).foregroundStyle(.secondary).padding(10)
                                        }
                                    } else if case .failed = link.state {
                                        Button("Retry Link") { model.retrySharedLink(link.id) }
                                    }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
                }
            }
            .accessibilityLabel("Shared-link thumbnails")
            .task(id: model.browserScrollRestoreRequest?.id) {
                guard let request = model.browserScrollRestoreRequest else { return }
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled,
                      model.browserScrollRestoreRequest?.id == request.id else { return }
                scrollProxy.scrollTo(browserRowScrollID(request.itemID), anchor: .center)
                if request.focusesBrowser { browserListFocused = true }
                model.completeBrowserScrollRestoration(request.id)
            }
        }
    }

    private var sortedSharedLinks: [SharedLinkEntry] { model.sortedSharedLinks }

    private func activateSharedLinkRoot(_ entry: SharedLinkEntry) {
        model.selectSharedLinkRoot(entry.id)
    }

    /// Child rows from inactive expanded links render from their own cached
    /// workspaces. Activate that link immediately before applying an action so
    /// selection, preview, download, and nested disclosure state are routed to
    /// the correct PikPak share session.
    @discardableResult
    private func activateSharedLinkContext(_ linkID: UUID?) -> Bool {
        guard let linkID else { return true }
        if !model.isBrowsingSharedLink || model.activeSharedLinkID != linkID {
            model.activateSharedLink(linkID)
        }
        return model.isBrowsingSharedLink && model.activeSharedLinkID == linkID
    }

    private var browserThumbnailGrid: some View {
        let items = model.displayedBrowserItems
        let scale = browserZoomScale
        return ScrollViewReader { scrollProxy in
            ZStack {
                if items.isEmpty && !model.isBrowserLoading {
                    if model.activeBrowserFileFilter.isActive {
                        BrowserFileFilterEmptyState(filter: $model.browserFileFilter, hasMore: model.hasMoreBrowserItems)
                    } else if model.displayedBrowserHiddenFolderCount(includingExpanded: false) > 0 {
                        BrowserEmptyFoldersEmptyState(hidesEmptyFolders: $model.hidesEmptyFolders)
                    } else {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.08))
                            Image(systemName: "folder")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 66, height: 66)
                        Text("This folder is empty")
                            .font(.headline)
                        Text("Refresh to check for newly added files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Refresh") {
                            model.refreshBrowser()
                        }
                        .disabled(!model.canBrowse)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    GeometryReader { viewport in
                        let spacing = max(8, 12 * scale)
                        let horizontalPadding = max(10, 14 * scale)
                        let minimumTileWidth = 104 * scale
                        let usableWidth = max(
                            viewport.size.width - horizontalPadding * 2,
                            minimumTileWidth
                        )
                        let columnCount = max(
                            Int((usableWidth + spacing) / (minimumTileWidth + spacing)),
                            1
                        )
                        let columns = Array(
                            repeating: GridItem(
                                .flexible(
                                    minimum: minimumTileWidth,
                                    maximum: minimumTileWidth + 24 * scale
                                ),
                                spacing: spacing,
                                alignment: .top
                            ),
                            count: columnCount
                        )

                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                browserBlankSelectionTarget

                                LazyVGrid(
                                    columns: columns,
                                    alignment: .leading,
                                    spacing: max(12, 16 * scale)
                                ) {
                                    let actionSelectionCount =
                                        model.browserActionSelectionCount
                                    ForEach(items) { item in
                                        browserThumbnailItem(
                                            item,
                                            scale: scale,
                                            actionSelectionCount: actionSelectionCount,
                                            sharedLinkID: model.isBrowsingSharedLink ? model.activeSharedLinkID : nil
                                        )
                                        .id(browserRowScrollID(item.id))
                                    }
                                }
                                .padding(.horizontal, horizontalPadding)
                                .padding(.vertical, max(12, 16 * scale))
                            }
                            .frame(
                                minWidth: viewport.size.width,
                                minHeight: viewport.size.height,
                                alignment: .topLeading
                            )
                        }
                        .id("thumbnails-\(model.browserPresentationIdentity)")
                        .focusable()
                        .focused($browserListFocused)
                        .hideKeyboardFocusEffectWhenAvailable()
                        .onMoveCommand { direction in
                            let modifiers = NSEvent.modifierFlags.intersection(
                                .deviceIndependentFlagsMask
                            )
                            moveBrowserGridSelection(
                                direction,
                                columns: columnCount,
                                extendingSelection: modifiers.contains(.shift),
                                scrollProxy: scrollProxy
                            )
                        }
                        .accessibilityLabel("Cloud thumbnails")
                        .accessibilityHint(
                            "Use the arrow keys to select items, Shift with an arrow to extend the selection, Return to open a folder, Space to Quick Look the selected file, and Command Delete to move selected items to Trash."
                        )
                        .onChange(of: model.selectedBrowserItemID) { _ in
                            model.browserSelectionChanged()
                            if model.isQuickLookSessionActive, let selected = model.selectedBrowserItemID {
                                scrollProxy.scrollTo(browserRowScrollID(selected), anchor: .center)
                            }
                        }
                        .task(id: model.browserScrollRestoreRequest?.id) {
                            guard let request = model.browserScrollRestoreRequest else { return }
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            guard
                                !Task.isCancelled,
                                model.browserScrollRestoreRequest?.id == request.id
                            else { return }
                            scrollProxy.scrollTo(browserRowScrollID(request.itemID), anchor: .center)
                            if request.focusesBrowser { browserListFocused = true }
                            model.completeBrowserScrollRestoration(request.id)
                        }
                        .background {
                            BrowserKeyboardMonitor(
                                handlesRangeSelection: browserListFocused
                                    && model.canChangeBrowserSelection
                                    && !model.isLoginPresented
                                    && !isBrowserTrashConfirmationPresented,
                                handlesDelete: model.canTrashSelectedBrowserItem
                                    && !model.isLoginPresented
                                    && !isBrowserTrashConfirmationPresented,
                                handlesZoom: true,
                                handlesQuickLook: !model.isLoginPresented
                                    && !isBrowserTrashConfirmationPresented,
                                onShiftMove: { direction in
                                    moveBrowserGridSelection(
                                        direction,
                                        columns: columnCount,
                                        extendingSelection: true,
                                        scrollProxy: scrollProxy
                                    )
                                },
                                onCommandDelete: {
                                    requestTrashForBrowserSelection()
                                },
                                onZoomIn: {
                                    adjustBrowserZoom(by: BrowserItemZoom.step)
                                },
                                onZoomOut: {
                                    adjustBrowserZoom(by: -BrowserItemZoom.step)
                                },
                                onActualSize: {
                                    resetBrowserZoom()
                                },
                                onQuickLook: { window in
                                    guard !workspaceNavigation.isSwitching else { return false }
                                    return model.toggleQuickLookForSelection(in: window)
                                },
                                onCancelQuickLook: model.cancelQuickLook,
                                ownsQuickLookPanel: model.ownsQuickLookPanel,
                                handlesSelectAll: canSelectAllBrowserFolders,
                                onSelectAllFolders: selectAllBrowserFolders,
                                handlesPreviewNavigation: canMovePreviewSelection && !browserListFocused,
                                handlesPreviewNavigationFromControls: canMovePreviewSelection,
                                onPreviewMove: { offset in
                                    movePreviewSelection(by: offset, scrollProxy: scrollProxy)
                                }
                            )
                            .frame(width: 0, height: 0)
                        }
                    }
                }

                if model.isBrowserLoading && !model.isBrowsingSharedLink {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Contacting PikPak…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A sibling behind the real rows/tiles receives only clicks made in unused
    /// canvas space. Putting the gesture on the enclosing ScrollView would also
    /// fire after row buttons and cause freshly selected items to be cleared.
    private var browserBlankSelectionTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                browserListFocused = true
                model.clearBrowserSelectionFromCanvas()
            }
            .accessibilityHidden(true)
    }

    /// Thumbnail mode cannot rely on the crowded Browser toolbar for
    /// pagination. Keep a Finder-style footer visible at the bottom of the
    /// viewport whenever PikPak reports another 200-item page.
    private var browserThumbnailPaginationFooter: some View {
        HStack(spacing: 12) {
            Text("\(model.browserItems.count.formatted()) items loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 12)

            if model.isBrowserLoading {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more items…")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    model.loadMoreBrowserItems()
                } label: {
                    Label("Load Next \(DownloaderModel.browserPageSize)", systemImage: "ellipsis.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent).pointingHandCursor()
                .disabled(!model.canBrowse)
                .help("Load the next page of files and folders from PikPak")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thumbnail pagination")
    }

    private func browserThumbnailItem(
        _ item: BrowserItem,
        scale: CGFloat,
        actionSelectionCount: Int,
        sharedLinkID: UUID? = nil
    ) -> some View {
        let measurement = model.cachedFolderMeasurement(for: item.id, in: sharedLinkID)
        let isActiveLink = sharedLinkID == nil || model.activeSharedLinkID == sharedLinkID
        return BrowserThumbnailTile(
            item: item,
            scale: scale,
            sizeLabel: item.isFolder
                ? measurement.map { formatBytes($0.totalBytes) } ?? "Folder"
                : formatBytes(item.size),
            systemImage: item.isFolder ? "folder.fill" : previewSymbol(for: item),
            isActive: isActiveLink && model.selectedBrowserItemID == item.id,
            isSelected: model.isBrowserItemSelected(item.id, in: sharedLinkID),
            isMeasuringSize: model.isMeasuringFolder(item.id, in: sharedLinkID),
            isMeasurementQueued: model.isFolderMeasurementQueued(item.id, in: sharedLinkID),
            isSavedToPikPak: model.isSharedItemSaved(item.id, in: sharedLinkID),
            onSelect: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                selectBrowserItem(item, visibleItems: model.showsSharedLinkOverview ? model.browserTreeEntries.map(\.item) : model.displayedBrowserItems)
            },
            onToggleSelection: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                browserListFocused = true
                model.toggleBrowserCheckbox(item)
            },
            onActivate: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                activateBrowserItem(item)
            },
            thumbnailProxyURL: model.proxyURL,
            thumbnailCache: model.thumbnailCache
        )
        .accessibilityHint(
            item.isFolder
                ? "Use the checkbox to include this folder and all its contents. Double-click or press Return to open it."
                : "Use the checkbox to add this file to the selection. Double-click to preview it."
        )
        .browserContextMenu(nativeMenu: {
            item.isFolder
                ? browserFolderNativeMenu(item, sharedLinkID: sharedLinkID, actionSelectionCount: actionSelectionCount, showsCollapse: false)
                : browserFileNativeMenu(item, sharedLinkID: sharedLinkID, actionSelectionCount: actionSelectionCount)
        }) {
            if !item.isFolder {
                browserFileOpenMenu(item, sharedLinkID: sharedLinkID)
            }
            if item.isFolder {
                let targets = browserExpansionTargets(for: item, sharedLinkID: sharedLinkID)
                BrowserFolderExpansionAction(folderCount: targets.count) { levels in
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    expandBrowserSubfolders(targets, levels: levels)
                }
                .disabled(!model.canExpandBrowserSubfolders(in: sharedLinkID))

                Button {
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    model.openFolder(item)
                } label: {
                    BrowserContextMenuStyle.label("Open Folder", systemImage: "folder")
                }
                .disabled(model.isRunning)

                if !model.isBrowsingSharedLink {
                    Button {
                        requestNewFolder(in: model.browserLocation(for: item))
                    } label: {
                        BrowserContextMenuStyle.label("New Folder Inside…", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canCreateFolder)

                    browserMergeFoldersButton(item)
                }

                Button {
                    model.measureFolder(item, in: sharedLinkID)
                } label: {
                    BrowserContextMenuStyle.label(
                        model.cachedFolderMeasurement(for: item.id, in: sharedLinkID) == nil
                            ? "Calculate Folder Size"
                            : "Recalculate Folder Size",
                        systemImage: "sum"
                    )
                }
                .disabled(!model.canMeasureFolder(item, in: sharedLinkID))
                if let sharedLinkID, model.sharedLinkFolderHasMoreItems(item.id, in: sharedLinkID) {
                    Button("Load More Contents") {
                        guard activateSharedLinkContext(sharedLinkID) else { return }
                        model.loadMoreBrowserTreeItems(in: item)
                    }
                }
            }

            if !model.isBrowsingSharedLink {
                Button { requestOwnedShare(item) } label: {
                    BrowserContextMenuStyle.label("Create Shared Link…", systemImage: "link")
                }.disabled(!model.hasAccountSession || model.isManagingCloudItems)

                Button {
                    requestRename(item)
                } label: {
                    BrowserContextMenuStyle.label("Rename…", systemImage: "pencil")
                }
                .disabled(!model.canRenameBrowserItem(item))

                Divider()
            }

            if let sharedLinkID {
                sharedSaveContextMenu(item, linkID: sharedLinkID)
            }

            Button {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                if !model.isBrowserItemSelected(item.id) {
                    model.selectBrowserItem(item)
                }
                model.downloadSelectedBrowserItem()
                selectedTransferMode = 0
                selectedTab = 1
            } label: {
                BrowserContextMenuStyle.label(
                    actionSelectionCount > 1
                        ? "Add Selected Items to Queue"
                        : (item.isFolder ? "Add Folder to Queue" : "Add File to Queue"),
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(
                !model.canQueueBrowserDownload
            )

            if !model.isBrowsingSharedLink, item.isCloudExtractableArchive {
                Button {
                    requestArchiveExtraction(for: item)
                } label: {
                    BrowserContextMenuStyle.label(
                        extractionActionTitle(for: item),
                        systemImage: "archivebox"
                    )
                }
                .disabled(!model.canOpenArchiveExtraction(item))
            }

            if !model.isBrowsingSharedLink {
                Divider()

                Button(role: .destructive) {
                    if !model.isBrowserItemSelected(item.id) {
                        model.selectBrowserItem(item)
                    }
                    requestTrashForBrowserSelection()
                } label: {
                    BrowserContextMenuStyle.label(
                        actionSelectionCount > 1
                            ? "Move Selected Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
                .disabled(
                    !model.canTrashBrowserItem(item)
                )
            }
        }
        .browserMoveDragSource(model: model, item: item)
        .browserDropRegion(id: item.id, destination: model.browserDropDestination(for: item),
                           isFolder: item.isFolder, cornerRadius: 11 * scale)
    }

    /// Outline row identity. Must match `.id(...)` on the rows exactly, or
    /// ScrollViewReader silently fails to find its target.
    private func browserRowScrollID(_ itemID: String) -> String {
        guard model.isBrowsingSharedLink, let linkID = model.activeSharedLinkID else {
            return itemID
        }
        return "\(linkID.uuidString)|\(itemID)"
    }

    private func browserTreeRow(
        _ entry: BrowserTreeEntry,
        rowIndex: Int,
        columns: BrowserTreeColumnLayout,
        // SwiftUI builds `.contextMenu` content eagerly for every row it
        // materializes, so the menu must not derive this from the model itself.
        actionSelectionCount: Int,
        sharedLinkID: UUID? = nil,
        usesMenuCanvas: Bool = false
    ) -> some View {
        let item = entry.item
        #if BROWSER_SCROLL_PROFILING
        let _ = BrowserScrollDiagnostics.constructRow(item.id)
        #endif
        let isActiveLinkContext = sharedLinkID == nil
            || (model.isBrowsingSharedLink && model.activeSharedLinkID == sharedLinkID)
        let expanded = item.isFolder && {
            if let sharedLinkID {
                return model.isSharedLinkFolderExpanded(item.id, in: sharedLinkID)
            }
            return model.isBrowserFolderExpanded(item.id)
        }()
        let isLoading = sharedLinkID.map {
            model.isSharedLinkFolderLoading(item.id, in: $0)
        } ?? model.isBrowserFolderLoading(item.id)
        let hasMoreItems = sharedLinkID.map {
            model.sharedLinkFolderHasMoreItems(item.id, in: $0)
        } ?? model.browserFolderHasMoreItems(item.id)
        let isLoadedAndEmpty = sharedLinkID.map {
            model.sharedLinkFolderIsLoadedAndEmpty(item.id, in: $0)
        } ?? model.browserFolderIsLoadedAndEmpty(item.id)
        let loadError = sharedLinkID.map {
            model.sharedLinkFolderLoadError(item.id, in: $0)
        } ?? model.browserTreeLoadErrors[item.id]
        return BrowserTreeRow(
            item: item,
            depth: entry.depth,
            zoomScale: browserZoomScale,
            columns: columns,
            isActive: isActiveLinkContext && model.selectedBrowserItemID == item.id,
            isSelected: model.isBrowserItemSelected(item.id, in: sharedLinkID),
            isExpanded: expanded,
            isLoading: isLoading,
            hasMoreItems: hasMoreItems,
            isLoadedAndEmpty: isLoadedAndEmpty,
            loadError: loadError,
            usesAlternateBackground: rowIndex.isMultiple(of: 2),
            canDownload: model.canQueueBrowserDownload,
            folderMeasurement: model.cachedFolderMeasurement(
                for: item.id,
                in: sharedLinkID
            ),
            isMeasuringSize: model.isMeasuringFolder(item.id, in: sharedLinkID),
            isMeasurementQueued: model.isFolderMeasurementQueued(
                item.id,
                in: sharedLinkID
            ),
            canMeasureSize: model.canMeasureFolder(item, in: sharedLinkID),
            isSavedToPikPak: model.isSharedItemSaved(item.id, in: sharedLinkID),
            showsShareActions: sharedLinkID != nil,
            isSavingToPikPak: sharedLinkID.map { model.isSharedItemSavingOrQueued(item.id, in: $0) } ?? false,
            canSaveToPikPak: model.canSaveSharedItem(item, in: sharedLinkID),
            onSelect: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                selectBrowserItem(item)
            },
            onToggleSelection: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                browserListFocused = true
                model.toggleBrowserCheckbox(item)
            },
            onActivate: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                activateBrowserItem(item)
            },
            onToggle: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                // Match the checkbox: expanding a folder keeps the outline
                // focused so arrow keys and Space still work afterward.
                browserListFocused = true
                model.toggleBrowserFolderExpansion(item)
            },
            onLoadMore: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.loadMoreBrowserTreeItems(in: item)
            },
            onRetry: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.retryBrowserTreeFolder(item)
            },
            onMeasure: {
                model.measureFolder(item, in: sharedLinkID)
            },
            onSave: {
                model.saveSharedItem(item, in: sharedLinkID)
            },
            onDownload: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.selectBrowserItem(item)
                model.downloadBrowserItem(item)
                selectedTransferMode = 0
                selectedTab = 1
            }
        )
        // PikPak can return the same folder id for several share URLs, so an
        // un-namespaced identity collides between two expanded links inside the
        // one LazyVStack — and a colliding view identity is undefined behaviour
        // for both layout and ScrollViewReader.scrollTo.
        .id(sharedLinkID.map { "\($0.uuidString)|\(item.id)" } ?? item.id)
        .accessibilityHint(
            item.isFolder
                ? "Use the checkbox to add this folder and all of its contents to the selection. Use its disclosure button to expand it inline, or double-click or press Return to open it."
                : "Use the checkbox to add this file to the selection. Double-click to preview it."
        )
        .browserContextMenu(nativeMenu: {
            item.isFolder
                ? browserFolderNativeMenu(item, sharedLinkID: sharedLinkID, actionSelectionCount: actionSelectionCount)
                : browserFileNativeMenu(item, sharedLinkID: sharedLinkID, actionSelectionCount: actionSelectionCount)
        }, usesNativeCanvas: usesMenuCanvas) {
            if !item.isFolder {
                browserFileOpenMenu(item, sharedLinkID: sharedLinkID)
            }
            if item.isFolder {
                let targets = browserExpansionTargets(for: item, sharedLinkID: sharedLinkID)
                BrowserFolderExpansionAction(folderCount: targets.count) { levels in
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    expandBrowserSubfolders(targets, levels: levels)
                }
                .disabled(!model.canExpandBrowserSubfolders(in: sharedLinkID))

                if expanded {
                    Button {
                        guard activateSharedLinkContext(sharedLinkID) else { return }
                        model.toggleBrowserFolderExpansion(item)
                    } label: {
                        BrowserContextMenuStyle.label("Collapse Folder", systemImage: "chevron.down")
                    }
                    .disabled(!model.canChangeBrowserSelection)
                }

                Button {
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    model.openFolder(item)
                } label: {
                    BrowserContextMenuStyle.label("Open Folder", systemImage: "folder")
                }
                .disabled(model.isRunning)

                if !model.isBrowsingSharedLink {
                    Button {
                        requestNewFolder(in: model.browserLocation(for: item))
                    } label: {
                        BrowserContextMenuStyle.label("New Folder Inside…", systemImage: "folder.badge.plus")
                    }
                    .disabled(!model.canCreateFolder)

                    browserMergeFoldersButton(item)
                }

                Button {
                    model.measureFolder(item, in: sharedLinkID)
                } label: {
                    BrowserContextMenuStyle.label(
                        model.cachedFolderMeasurement(for: item.id, in: sharedLinkID) == nil
                            ? "Calculate Folder Size"
                            : "Recalculate Folder Size",
                        systemImage: "sum"
                    )
                }
                .disabled(!model.canMeasureFolder(item, in: sharedLinkID))
            }

            if sharedLinkID == nil, !model.isBrowsingSharedLink {
                Button { requestOwnedShare(item) } label: {
                    BrowserContextMenuStyle.label("Create Shared Link…", systemImage: "link")
                }.disabled(!model.hasAccountSession || model.isManagingCloudItems)

                Button {
                    requestRename(item)
                } label: {
                    BrowserContextMenuStyle.label("Rename…", systemImage: "pencil")
                }
                .disabled(!model.canRenameBrowserItem(item))

                Divider()
            }

            if let sharedLinkID {
                sharedSaveContextMenu(item, linkID: sharedLinkID)
            }

            Button {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                if !model.isBrowserItemSelected(item.id) {
                    model.selectBrowserItem(item)
                }
                model.downloadSelectedBrowserItem()
                selectedTransferMode = 0
                selectedTab = 1
            } label: {
                BrowserContextMenuStyle.label(
                    actionSelectionCount > 1
                        ? "Add Selected Items to Queue"
                        : (item.isFolder ? "Add Folder to Queue" : "Add File to Queue"),
                    systemImage: "arrow.down.circle"
                )
            }
            .disabled(
                !model.canQueueBrowserDownload
            )

            if !model.isBrowsingSharedLink, item.isCloudExtractableArchive {
                Button {
                    requestArchiveExtraction(for: item)
                } label: {
                    BrowserContextMenuStyle.label(
                        extractionActionTitle(for: item),
                        systemImage: "archivebox"
                    )
                }
                .disabled(!model.canOpenArchiveExtraction(item))
            }

            if !model.isBrowsingSharedLink {
                Divider()

                Button(role: .destructive) {
                    if !model.isBrowserItemSelected(item.id) {
                        model.selectBrowserItem(item)
                    }
                    requestTrashForBrowserSelection()
                } label: {
                    BrowserContextMenuStyle.label(
                        actionSelectionCount > 1
                            ? "Move Selected Items to Trash"
                            : "Move to Trash",
                        systemImage: "trash"
                    )
                }
                .disabled(
                    !model.canTrashBrowserItem(item)
                )
            }
        }
        .id(
            sharedLinkID.map { "shared-link-item-\($0.uuidString)-\(item.id)" }
                ?? item.id
        )
        .browserMoveDragSource(model: model, item: item)
        .browserDropRegion(id: item.id, destination: model.browserDropDestination(for: item),
                           isFolder: item.isFolder)
    }

    @ViewBuilder
    private func browserFileOpenMenu(_ item: BrowserItem, sharedLinkID: UUID?) -> some View {
        if sharedLinkID == nil, !model.isBrowsingSharedLink {
            Button {
                model.toggleBookmark(item, store: bookmarks)
            } label: {
                BrowserContextMenuStyle.label(
                    bookmarks.contains(provider: "pikpak", scope: model.bookmarkScope, itemID: item.id)
                        ? "Remove from Bookmarks" : "Add to Bookmarks",
                    systemImage: "bookmark")
            }.disabled(model.bookmarkScope == nil)
            Divider()
        }
        FinderFileOpenMenu(item: item,
            enabled: model.canOpenBrowserFile(item, in: sharedLinkID),
            open: { application in
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.openBrowserFile(item, application: application)
            },
            chooseApplication: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.openBrowserFile(item, chooseApplication: true)
            })
        Button {
            guard activateSharedLinkContext(sharedLinkID) else { return }
            if model.selectedBrowserItemID != item.id { model.selectBrowserItem(item) }
            model.requestQuickLook(for: item)
        } label: { BrowserContextMenuStyle.label("Quick Look", systemImage: "eye") }
        .disabled(!model.canRequestQuickLook(for: item))
        .help("Preview this file · Space")
        Divider()
    }

    private func browserFileNativeMenu(_ item: BrowserItem, sharedLinkID: UUID?, actionSelectionCount: Int) -> NSMenu {
        let menu = BrowserNativeMenu(title: "File actions")
        let accountFile = sharedLinkID == nil && !model.isBrowsingSharedLink
        if accountFile {
            menu.addAction(bookmarks.contains(provider: "pikpak", scope: model.bookmarkScope, itemID: item.id)
                ? "Remove from Bookmarks" : "Add to Bookmarks", symbol: "bookmark", enabled: model.bookmarkScope != nil) {
                model.toggleBookmark(item, store: bookmarks)
            }
            menu.addItem(.separator())
        }
        FinderFileApplications.addOpenActions(to: menu, item: item, enabled: model.canOpenBrowserFile(item, in: sharedLinkID),
            open: { application in
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.openBrowserFile(item, application: application)
            }, chooseApplication: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.openBrowserFile(item, chooseApplication: true)
            })
        menu.addAction("Quick Look", symbol: "eye", enabled: model.canRequestQuickLook(for: item)) {
            guard activateSharedLinkContext(sharedLinkID), model.canRequestQuickLook(for: item) else { return }
            if model.selectedBrowserItemID != item.id { model.selectBrowserItem(item) }
            model.requestQuickLook(for: item)
        }
        menu.addItem(.separator())
        if accountFile {
            menu.addAction("Create Shared Link…", symbol: "link", enabled: model.hasAccountSession && !model.isManagingCloudItems) {
                requestOwnedShare(item)
            }
            menu.addAction("Rename…", symbol: "pencil", enabled: model.canRenameBrowserItem(item)) {
                guard model.canRenameBrowserItem(item) else { return }
                requestRename(item)
            }
            menu.addItem(.separator())
        }
        if let sharedLinkID {
            menu.addAction(model.sharedSaveContextMenuTitle(for: item, in: sharedLinkID), symbol: "icloud.and.arrow.up",
                enabled: model.canSaveSharedItemsFromContextMenu(item, in: sharedLinkID)) {
                model.saveSharedItemsFromContextMenu(item, in: sharedLinkID)
            }
        }
        menu.addAction(actionSelectionCount > 1 ? "Add Selected Items to Queue" : "Add File to Queue",
            symbol: "arrow.down.circle", enabled: model.canQueueBrowserDownload) {
            guard model.canQueueBrowserDownload, activateSharedLinkContext(sharedLinkID) else { return }
            if !model.isBrowserItemSelected(item.id) { model.selectBrowserItem(item) }
            model.downloadSelectedBrowserItem(); selectedTransferMode = 0; selectedTab = 1
        }
        if accountFile, item.isCloudExtractableArchive {
            menu.addAction(extractionActionTitle(for: item), symbol: "archivebox", enabled: model.canOpenArchiveExtraction(item)) {
                requestArchiveExtraction(for: item)
            }
        }
        if accountFile {
            menu.addItem(.separator())
            menu.addAction(actionSelectionCount > 1 ? "Move Selected Items to Trash" : "Move to Trash", symbol: "trash",
                enabled: model.canTrashBrowserItem(item)) {
                guard model.canTrashBrowserItem(item) else { return }
                if !model.isBrowserItemSelected(item.id) { model.selectBrowserItem(item) }
                requestTrashForBrowserSelection()
            }
        }
        return menu
    }

    private func browserMergeFoldersButton(_ item: BrowserItem) -> some View {
        Button { requestMergeSelectedFolders(preferredDestination: item) } label: {
            BrowserContextMenuStyle.label("Merge Selected Folders…", systemImage: "arrow.triangle.merge")
        }
        .disabled(!model.canMergeSelectedFolders || !model.selectedFoldersForMerge.contains(where: { $0.id == item.id }))
        .help("Select two or more sibling folders to merge")
    }

    /// Read current capabilities when the menu opens. Its native items stay
    /// fixed until dismissal; commands still validate against the live model.
    private func browserFolderNativeMenu(_ item: BrowserItem, sharedLinkID: UUID?,
                                         actionSelectionCount: Int, showsCollapse: Bool = true) -> NSMenu {
        let menu = BrowserNativeMenu()
        let expansionTargets = browserExpansionTargets(for: item, sharedLinkID: sharedLinkID)
        BrowserFolderExpansionAction.add(to: menu, enabled: model.canExpandBrowserSubfolders(in: sharedLinkID),
                                         folderCount: expansionTargets.count) { levels in
            guard model.canExpandBrowserSubfolders(in: sharedLinkID), activateSharedLinkContext(sharedLinkID) else { return }
            expandBrowserSubfolders(expansionTargets, levels: levels)
        }
        let expanded = sharedLinkID.map { model.isSharedLinkFolderExpanded(item.id, in: $0) }
            ?? model.isBrowserFolderExpanded(item.id)
        if showsCollapse && expanded {
            menu.addAction("Collapse Folder", symbol: "chevron.down", enabled: model.canChangeBrowserSelection) {
                guard model.canChangeBrowserSelection, activateSharedLinkContext(sharedLinkID) else { return }
                model.toggleBrowserFolderExpansion(item)
            }
        }
        menu.addAction("Open Folder", symbol: "folder", enabled: !model.isRunning) {
            guard !model.isRunning, activateSharedLinkContext(sharedLinkID) else { return }
            model.openFolder(item)
        }
        let accountFolder = sharedLinkID == nil && !model.isBrowsingSharedLink
        if accountFolder {
            menu.addAction(bookmarks.contains(provider: "pikpak", scope: model.bookmarkScope, itemID: item.id)
                           ? "Remove from Bookmarks" : "Add to Bookmarks", symbol: "bookmark", enabled: model.bookmarkScope != nil) {
                model.toggleBookmark(item, store: bookmarks)
            }
            menu.addAction("New Folder Inside…", symbol: "folder.badge.plus", enabled: model.canCreateFolder) {
                guard model.canCreateFolder else { return }
                requestNewFolder(in: model.browserLocation(for: item))
            }
            let merge = menu.addAction("Merge Selected Folders…", symbol: "arrow.triangle.merge",
                enabled: model.canMergeSelectedFolders && model.selectedFoldersForMerge.contains(where: { $0.id == item.id })) {
                    requestMergeSelectedFolders(preferredDestination: item)
                }
            merge.toolTip = "Select two or more sibling folders to merge"
        }
        menu.addAction(model.cachedFolderMeasurement(for: item.id, in: sharedLinkID) == nil
                       ? "Calculate Folder Size" : "Recalculate Folder Size", symbol: "sum",
                       enabled: model.canMeasureFolder(item, in: sharedLinkID)) {
            model.measureFolder(item, in: sharedLinkID)
        }
        if let sharedLinkID, model.sharedLinkFolderHasMoreItems(item.id, in: sharedLinkID) {
            menu.addAction("Load More Contents") {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.loadMoreBrowserTreeItems(in: item)
            }
        }
        if accountFolder {
            menu.addAction("Create Shared Link…", symbol: "link", enabled: model.hasAccountSession && !model.isManagingCloudItems) {
                requestOwnedShare(item)
            }
            menu.addAction("Rename…", symbol: "pencil", enabled: model.canRenameBrowserItem(item)) {
                guard model.canRenameBrowserItem(item) else { return }
                requestRename(item)
            }
            menu.addItem(.separator())
        }
        if let sharedLinkID {
            menu.addAction(model.sharedSaveContextMenuTitle(for: item, in: sharedLinkID), symbol: "icloud.and.arrow.up",
                           enabled: model.canSaveSharedItemsFromContextMenu(item, in: sharedLinkID)) {
                model.saveSharedItemsFromContextMenu(item, in: sharedLinkID)
            }
        }
        menu.addAction(actionSelectionCount > 1 ? "Add Selected Items to Queue" : "Add Folder to Queue",
                       symbol: "arrow.down.circle", enabled: model.canQueueBrowserDownload) {
            guard model.canQueueBrowserDownload, activateSharedLinkContext(sharedLinkID) else { return }
            if !model.isBrowserItemSelected(item.id) { model.selectBrowserItem(item) }
            model.downloadSelectedBrowserItem()
            selectedTransferMode = 0; selectedTab = 1
        }
        if accountFolder {
            menu.addItem(.separator())
            menu.addAction(actionSelectionCount > 1 ? "Move Selected Items to Trash" : "Move to Trash",
                           symbol: "trash", enabled: model.canTrashBrowserItem(item)) {
                guard model.canTrashBrowserItem(item) else { return }
                if !model.isBrowserItemSelected(item.id) { model.selectBrowserItem(item) }
                requestTrashForBrowserSelection()
            }
        }
        return menu
    }

    private func requestOwnedShare(_ item: BrowserItem? = nil) {
        guard model.hasAccountSession, !model.isChangingAccount, !model.isBrowsingSharedLink, !model.isManagingCloudItems else { return }
        if let item, !model.isBrowserItemSelected(item.id) { model.selectBrowserItem(item) }
        let files = model.browserItemActionRoots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
            PikPakManagedFile(id: $0.id, name: $0.name, isFolder: $0.isFolder, size: $0.size)
        }
        guard !files.isEmpty, files.count <= 100 else { return }
        model.preparePikPakManagement()
        createOwnedShareRequest = .init(files: files)
    }

    private func moveBrowserSelection(
        _ direction: MoveCommandDirection,
        extendingSelection: Bool = false,
        scrollProxy: ScrollViewProxy
    ) {
        guard !workspaceNavigation.isSwitching else { return }
        let targetID: String?
        switch direction {
        case .up:
            targetID = model.selectAdjacentBrowserItem(
                by: -1,
                extendingSelection: extendingSelection
            )
        case .down:
            targetID = model.selectAdjacentBrowserItem(
                by: 1,
                extendingSelection: extendingSelection
            )
        case .left:
            targetID = model.moveBrowserTreeSelectionHorizontally(by: -1)
        case .right:
            targetID = model.moveBrowserTreeSelectionHorizontally(by: 1)
        @unknown default:
            targetID = nil
        }

        guard let targetID else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            scrollProxy.scrollTo(browserRowScrollID(targetID))
        }
    }

    private func moveBrowserGridSelection(
        _ direction: MoveCommandDirection,
        columns: Int,
        extendingSelection: Bool = false,
        scrollProxy: ScrollViewProxy
    ) {
        guard !workspaceNavigation.isSwitching else { return }
        let offset: Int
        switch direction {
        case .up:
            offset = -max(columns, 1)
        case .down:
            offset = max(columns, 1)
        case .left:
            offset = -1
        case .right:
            offset = 1
        @unknown default:
            return
        }

        guard let targetID = model.selectAdjacentBrowserItem(
            by: offset,
            extendingSelection: extendingSelection,
            visibleItems: model.displayedBrowserItems
        ) else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            scrollProxy.scrollTo(browserRowScrollID(targetID), anchor: .center)
        }
    }

    private func sharedSaveContextMenu(_ item: BrowserItem, linkID: UUID) -> some View {
        Button {
            model.saveSharedItemsFromContextMenu(item, in: linkID)
        } label: {
            BrowserContextMenuStyle.label(
                model.sharedSaveContextMenuTitle(for: item, in: linkID),
                systemImage: "icloud.and.arrow.up"
            )
        }
        .disabled(!model.canSaveSharedItemsFromContextMenu(item, in: linkID))
    }

    private func selectBrowserItem(
        _ item: BrowserItem,
        visibleItems: [BrowserItem]? = nil
    ) {
        browserListFocused = true
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        model.selectBrowserItem(
            item,
            extending: modifiers.contains(.shift),
            toggling: modifiers.contains(.command),
            visibleItems: visibleItems
        )
    }

    private func activateBrowserItem(_ item: BrowserItem) {
        browserListFocused = true
        model.selectBrowserItem(item)
        if item.isFolder {
            model.openFolder(item)
        } else {
            model.requestPreview(for: item)
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let item = model.selectedBrowserItem {
            FinderPreviewPane(resetRevision: finderSettings.layoutResetRevision,
                mediaPlayback: item.mediaKind == .video || item.mediaKind == .audio ? model.mediaPlayback : nil,
                onPreviewMove: { offset in
                    guard canMovePreviewSelection else { return }
                    model.movePreviewSelection(by: offset)
                }) {
                HStack(alignment: .center, spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.1))
                        Image(systemName: item.isFolder ? "folder.fill" : previewSymbol(for: item))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(2)
                            .help(item.name)
                        HStack(spacing: 7) {
                            Text(
                                item.isFolder
                                    ? "Folder"
                                    : (item.mimeType ?? item.fileExtension?.uppercased() ?? "File")
                            )
                            if let modified = item.modifiedTime {
                                Text("•")
                                Label(modified, systemImage: "clock")
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    selectionSizeSummary(for: item)
                    if !item.isFolder {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPreviewExpanded.toggle()
                            }
                        } label: {
                            Image(
                                systemName: isPreviewExpanded
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right"
                            )
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).pointingHandCursor()
                        .help(isPreviewExpanded ? "Restore Split View" : "Expand Preview")
                        .accessibilityLabel(
                            isPreviewExpanded ? "Restore Split View" : "Expand Preview"
                        )
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            } media: {
                VStack(spacing: 0) {
                    previewCanvas(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !item.isFolder, item.mediaKind == .video || item.mediaKind == .audio {
                        previewStreamingPanel(for: item)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .overlay(alignment: .top) { Divider() }
                    }
                }
            } details: {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.isFolder,
                       model.previewFileID == item.id,
                       let previewError = model.previewPlaybackError {
                        previewFailureSection(for: item, message: previewError)
                    }

                    if item.isFolder {
                        Button {
                            model.openFolder(item)
                        } label: {
                            Label("Open Folder", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(model.isRunning)
                    } else {
                        if !model.isBrowsingSharedLink, item.isCloudExtractableArchive {
                            HStack {
                                Button {
                                    requestArchiveExtraction(for: item)
                                } label: {
                                    Label(
                                        extractionActionTitle(for: item),
                                        systemImage: "archivebox"
                                    )
                                }
                                .buttonStyle(.borderedProminent).pointingHandCursor()
                                .disabled(!model.canOpenArchiveExtraction(item))

                                Spacer()

                                Label("Server-side extraction", systemImage: "cloud")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            if item.supportsInlinePreview {
                                Button {
                                    model.requestPreview(for: item)
                                } label: {
                                    Label(
                                        item.mediaKind == .video || item.mediaKind == .audio
                                            ? (model.previewFileID == item.id ? "Reload" : "Load Preview")
                                            : (model.previewFileID == item.id ? "Reload Preview" : "Load Preview"),
                                        systemImage: item.isTextPreviewable
                                            ? "doc.plaintext"
                                            : (item.mediaKind == .image ? "photo" : "play.rectangle")
                                    )
                                }
                                .buttonStyle(.borderedProminent).pointingHandCursor()
                                .disabled(model.isRunning)
                            }

                            if item.mediaKind == .video || item.mediaKind == .audio {
                                if let playerName = model.externalPreviewPlayerName {
                                    Button {
                                        model.openPreviewExternally()
                                    } label: {
                                        Label(playerName, systemImage: "play.rectangle.on.rectangle")
                                    }
                                    .disabled(!model.canOpenPreviewExternally)
                                    .help("Stream this signed PikPak source in \(playerName)")
                                }
                            }

                            // Quick Look has no standing button: Space and
                            // the row's context menu drive it, as in Finder.
                            // Only its preparing state stays visible here.
                            if model.isPreparingQuickLook {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Preparing Quick Look…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if item.isTextPreviewable,
                               model.previewFileID == item.id,
                               model.previewText != nil {
                                HStack(spacing: 5) {
                                    Image(systemName: "text.quote")
                                    Text(
                                        model.previewTextWasTruncated
                                            ? "Selectable text • first 2 MB • \(model.previewTextEncodingName ?? "Text")"
                                            : "Selectable text • \(model.previewTextEncodingName ?? "Text")"
                                    )
                                    .lineLimit(1)
                                    .help(
                                        model.previewTextWasTruncated
                                            ? "The file is larger than 2 MB; this native preview shows its first 2 MB. Quick Look opens the complete temporary file."
                                            : "The text can be selected and copied."
                                    )
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else if item.mediaKind != .video && item.mediaKind != .audio {
                                Label(
                                    item.supportsInlinePreview
                                        ? "Secure on-demand preview"
                                        : "Press Space for Quick Look",
                                    systemImage: item.supportsInlinePreview
                                        ? "lock.shield"
                                        : "eye"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        if !item.supportsInlinePreview,
                           !item.isCloudExtractableArchive || model.isBrowsingSharedLink {
                            Text("This type has no inline renderer. Press Space, or right-click the file, to open a private temporary copy in Quick Look.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 5) {
                        Label("Download destination", systemImage: "folder.badge.arrow.down")
                            .font(.caption.weight(.semibold))
                        Text(model.outputURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))

                    HStack {
                        Button("Choose…") {
                            model.chooseOutputFolder()
                        }
                        .disabled(model.isRunning || model.isDownloading)

                        if !model.isBrowsingSharedLink {
                            Button(role: .destructive) {
                                requestTrashForBrowserSelection()
                            } label: {
                                Label(
                                    model.browserActionSelectionCount > 1
                                        ? "Trash Selected"
                                        : "Trash",
                                    systemImage: "trash"
                                )
                            }
                            .disabled(
                                !model.canTrashBrowserItem(item)
                            )
                            .help("Move selected items to PikPak Trash")
                        }

                        Spacer()

                        Button {
                            model.downloadSelectedBrowserItem()
                            selectedTransferMode = 0
                            selectedTab = 1
                        } label: {
                            Label(
                                model.browserActionSelectionCount > 1
                                    ? "Add Selected to Queue"
                                    : (item.isFolder ? "Add Folder to Queue" : "Add File to Queue"),
                                systemImage: "arrow.down.circle.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .disabled(
                            !model.canDownloadSelectedBrowserItem
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else { FinderPreviewEmptyState() }
    }

    @ViewBuilder
    private func selectionSizeSummary(for item: BrowserItem) -> some View {
        if item.isFolder {
            if let measurement = model.selectedFolderMeasurement {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatBytes(measurement.totalBytes))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(folderContentsSummary(measurement))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Recalculate") {
                        model.measureSelectedFolder()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .disabled(!model.canMeasureSelectedFolder)
                }
            } else if model.isMeasuringFolder(item.id) {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Calculating size…")
                            .font(.caption.weight(.medium))
                    }
                    Button("Cancel") {
                        model.cancelFolderMeasurement()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Folder size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Calculate") {
                        model.measureSelectedFolder()
                    }
                    .controlSize(.small)
                    .disabled(!model.canMeasureSelectedFolder)
                    .help("Scan this folder and its subfolders without downloading anything")
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(item.size))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("File size")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewStreamingPanel(for item: BrowserItem) -> some View {
        let matches = model.previewFileID == item.id
        let state = matches ? model.previewStreamingState : .preparing
        let preparation = matches ? model.previewPreparationProgress : nil
        let usesCache = matches && model.previewUsesRetainedCache
        let fraction = preparation != nil ? preparation?.fraction : matches ? model.previewBufferedFraction : nil
        let isComplete = usesCache && fraction == 1 && state != .failed
        let totalBytes = usesCache && model.previewRetainedTotalBytes > 0 ? model.previewRetainedTotalBytes : item.size
        let transferring = preparation?.activity == .transferring
        let provider = model.isBrowsingSharedLink ? "Link" : "PikPak"
        let sourceName = matches && preparation == nil
            ? model.previewSourceLabel?.components(separatedBy: " • ").first : nil
        var summary = MediaPreviewBufferSummary(
            title: preparation.map { $0.activity == .transferring ? "Downloading preview" : "Preparing preview" }
                ?? (isComplete ? "Fully buffered" : state.title),
            symbol: preparation != nil ? (transferring ? "arrow.down.circle" : "gearshape.2")
                : isComplete ? "checkmark.circle.fill" : state.systemImage,
            color: isComplete ? .green : matches ? previewStreamingStateColor : .orange,
            source: [provider, sourceName].compactMap { $0 }.joined(separator: " · "),
            sourceDetails: matches ? model.previewSourceLabel : nil,
            fraction: fraction,
            showsProgress: state != .failed && state != .compatibility
        )
        if summary.showsProgress {
            let speed = preparation != nil ? model.previewPreparationBytesPerSecond
                : matches ? model.previewTransferBytesPerSecond : 0
            if (preparation == nil || transferring), !isComplete, let speed, speed.isFinite {
                summary.speed = speed > 0 ? formatByteRate(speed) : "0 B/s"
            }
            if let preparation {
                if transferring {
                    summary.amount = formatBytes(preparation.bytes)
                    summary.amountSuffix = preparation.fileSize > 0
                        ? "of \(formatBytes(preparation.fileSize)) downloaded" : "downloaded"
                } else {
                    summary.footnote = preparation.message
                }
            } else if usesCache {
                summary.amount = formatBytes(model.previewRetainedBytes)
                summary.amountSuffix = totalBytes > 0 && !isComplete ? "of \(formatBytes(totalBytes)) buffered" : "buffered"
                summary.ranges = model.previewRetainedSegments.map { $0.start..<$0.end }
                summary.help = isComplete
                    ? "The whole file is buffered for this preview. Choosing another file clears the buffer."
                    : "Cyan segments show downloaded parts of this file; gaps are still loading. Buffering continues while paused. Choosing another file clears the buffer."
            } else {
                if matches && model.previewBufferedSeconds > 0 {
                    summary.amount = formatMediaTime(model.previewBufferedSeconds)
                    summary.amountSuffix = "ready to play"
                } else if totalBytes > 0 {
                    summary.amount = formatBytes(totalBytes)
                    summary.amountSuffix = "file size"
                }
                summary.help = "Available media ranges may change when you seek. Buffering continues while paused."
                if matches && model.previewStreamedBytes > 0 {
                    summary.help = "\(formatBytes(model.previewStreamedBytes)) received. " + (summary.help ?? "")
                }
            }
            if preparation == nil && state == .paused && !isComplete {
                summary.footnote = "Buffering continues while paused."
            }
        } else {
            summary.fraction = nil
        }
        return MediaPreviewBufferDetails {
            MediaPreviewBufferStatusView(summary) {
                if state == .failed {
                    Text(model.previewPlaybackError ?? "The preview could not be loaded. Try again or download the file.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diagnostic = model.previewErrorDiagnostic {
                        DisclosureGroup("Error details") {
                            ErrorDiagnosticBlock(diagnostic: diagnostic,
                                summary: model.previewPlaybackError ?? "Preview unavailable", compact: true)
                        }.font(.caption2)
                    }
                } else if state == .compatibility {
                    Text(model.previewCompatibilityPlayerName ?? "Compatibility player")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Open the temporary stream in IINA for legacy AVI codec support.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func previewFailureSection(
        for item: BrowserItem,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.11))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview unavailable")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let diagnostic = model.previewErrorDiagnostic {
                ErrorDiagnosticBlock(
                    diagnostic: diagnostic,
                    summary: message
                )
            }

            HStack(spacing: 8) {
                Button("Dismiss") {
                    model.dismissPreviewFailure()
                }
                .keyboardShortcut(.cancelAction)

                Button("Try Again") {
                    model.requestPreview(for: item)
                }
                .buttonStyle(.borderedProminent).pointingHandCursor()
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)

                Spacer(minLength: 8)

                if let playerName = model.externalPreviewPlayerName {
                    Button("Open in \(playerName)") {
                        model.openPreviewExternally()
                    }
                    .disabled(!model.canOpenPreviewExternally)
                }

                Button(model.isPreparingQuickLook ? "Preparing Quick Look…" : "Quick Look") {
                    model.requestQuickLook(for: item)
                }
                .disabled(!model.canRequestQuickLook(for: item))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.red.opacity(0.065), Color.orange.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview error")
    }

    private var previewStreamingStateColor: Color {
        switch model.previewStreamingState {
        case .playing: return .blue
        case .buffering, .preparing: return .orange
        case .finished: return .green
        case .compatibility: return .blue
        case .failed: return .red
        case .idle, .ready, .paused: return .secondary
        }
    }

    private func formatMediaTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let seconds = SafeDisplayNumber.integer(interval)
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds % 3_600) / 60,
                seconds % 60
            )
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func formatByteRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        let bounded = SafeDisplayNumber.bytes(bytesPerSecond)
        return "\(formatBytes(bounded))/s"
    }

    private func folderContentsSummary(_ measurement: FolderMeasurement) -> String {
        let files = measurement.fileCount
        let folders = measurement.folderCount
        let fileLabel = files == 1 ? "file" : "files"
        let folderLabel = folders == 1 ? "subfolder" : "subfolders"
        return "\(files.formatted()) \(fileLabel) • \(folders.formatted()) \(folderLabel)"
    }

    @ViewBuilder
    private func previewCanvas(for item: BrowserItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.07), Color.secondary.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if item.isFolder {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
                    .padding(70)
            } else if item.mediaKind == .image {
                // Keep the same presentation mounted before/during/after the
                // API resolves the full image. A new AsyncImage here used to
                // discard the thumbnail and flash its empty phase a second time.
                let generation = model.imagePreviewRequestGeneration
                ImagePreviewSurface(
                    model: model.imagePreview,
                    request: ImagePreviewRequest(
                        fileID: item.id,
                        thumbnailURL: item.artworkURL,
                        contentURL: model.previewFileID == item.id ? model.previewInfo?.contentURL : nil,
                        generation: generation,
                        proxyURL: model.proxyURL
                    ),
                    onFailure: { error in
                        model.reportImagePreviewFailure(error, fileID: item.id, generation: generation)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(8)
            } else if model.previewFileID == item.id,
                      model.previewPlaybackError != nil {
                RemoteArtwork(
                    url: item.artworkURL,
                    systemName: previewSymbol(for: item),
                    fit: true,
                    proxyURL: model.proxyURL,
                    cache: model.thumbnailCache
                )
                .padding(8)
            } else if item.isTextPreviewable,
                      model.previewFileID == item.id,
                      let text = model.previewText {
                SelectableTextPreview(text: text)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
            } else if item.mediaKind == .video || item.mediaKind == .audio,
                      model.previewFileID == item.id,
                      model.previewPlayer != nil {
                MediaPreviewView(playback: model.mediaPlayback, isAudio: item.mediaKind == .audio,
                    onVideoFailure: { error, player in
                        model.reportVideoPreviewFailure(error, fileID: item.id, player: player)
                    })
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RemoteArtwork(
                    url: item.artworkURL,
                    systemName: previewSymbol(for: item),
                    fit: true,
                    proxyURL: model.proxyURL,
                    cache: model.thumbnailCache
                )
                .padding(8)
            }

            if !item.isFolder,
               (item.mediaKind == .video || item.mediaKind == .audio),
               model.previewFileID == item.id,
               model.isPreviewLoading, model.previewPlayer == nil {
                let preparation = model.previewPreparationProgress
                let fraction = preparation != nil ? preparation?.fraction : model.previewBufferedFraction
                MediaPreviewLoadingStatusView(isAudio: item.mediaKind == .audio, message: model.previewSourceLabel,
                    fraction: fraction,
                        bytesPerSecond: preparation != nil ? model.previewPreparationBytesPerSecond : model.previewTransferBytesPerSecond,
                        receivedBytes: preparation.flatMap { $0.activity == .transferring ? $0.bytes : nil }
                            ?? (preparation == nil ? model.previewStreamedBytes : nil),
                        totalBytes: preparation.flatMap { $0.fileSize > 0 ? $0.fileSize : nil }
                            ?? (preparation == nil && item.size > 0 ? item.size : nil))
                .allowsHitTesting(false)
            }

            if !item.isFolder,
               item.isTextPreviewable,
               model.previewFileID == item.id,
               model.isPreviewLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading selectable text preview…")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .allowsHitTesting(false)
            }

            if !item.isFolder,
               model.previewFileID == item.id,
               model.previewRequiresCompatibilityPlayer {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("AVI compatibility preview")
                        .font(.headline)
                    Text(
                        "This AVI uses a legacy codec that macOS AVPlayer cannot decode. Open its temporary cloud stream in \(model.previewCompatibilityPlayerName ?? "IINA")."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                    HStack(spacing: 8) {
                        Button("Open in \(model.previewCompatibilityPlayerName ?? "IINA")") {
                            model.openCompatibilityPreview()
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .disabled(!model.canOpenCompatibilityPreview)

                        Button(model.isPreparingQuickLook ? "Preparing Quick Look…" : "Quick Look") {
                            model.openPreviewInQuickLook()
                        }
                        .disabled(!model.canOpenPreviewInQuickLook)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
        }
        .shadow(color: .black.opacity(0.055), radius: 8, y: 3)
    }

    private var downloader: some View {
        VStack(alignment: .leading, spacing: 12) {
            FinderTransferHeader(direction: $selectedTransferMode,
                destination: selectedTransferMode == 2 ? "BitTorrent → This Mac or PikPak" : selectedTransferMode == 1 ? model.effectiveUploadDestination.path : model.outputURL.path)
            FinderTransferCanvas {
                if selectedTransferMode == 0 { downloadWorkspace }
                else if selectedTransferMode == 2 { LocalTorrentWorkspace(pikpak: model) }
                else { uploadWorkspace }
            }
        }
    }

    private var downloadWorkspace: some View {
        FinderTransferWorkspace(fillsViewport: downloadingExpanded || downloadQueueExpanded || downloadCompletedExpanded
            || (downloadRetryExpanded && !model.retryingDownloadTransfers.isEmpty)
            || (downloadFailedExpanded && !model.visibleFailedDownloadTransfers.isEmpty)) {
            downloadSettings
            VStack(alignment: .leading, spacing: 16) {
                downloadProgressDashboard
                Divider()
                downloadBufferDashboard
            }.appCard(padding: 16)
            DownloadSpeedChart(history: model.downloadSpeedHistory,
                remainingBytes: model.downloadSpeedChartRemaining?.bytes,
                estimatedSize: model.downloadSpeedChartRemaining?.estimated ?? true,
                lowerBound: model.downloadSpeedChartRemaining?.lowerBound ?? true,
                isRunning: model.downloadSpeedChartIsRunning,
                waitingMessage: model.downloadSpeedChartWaitingMessage)
                .appCard(padding: 12)
            downloadTransferBoard
                .layoutValue(key: FinderTransferExpandsVerticallyKey.self, value: true)
        }
    }

    private var uploadWorkspace: some View {
        FinderTransferWorkspace {
            FinderTransferOverview { uploadSettings } progress: { uploadProgressDashboard }
            uploadControls
                .appCard(padding: 11)
            if !model.resumableUploadBatches.isEmpty {
                savedUploadBatches
            }
            uploadTransferBoard
        }
    }

    private var uploadSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Upload setup", systemImage: "arrow.up.doc.fill")
                    .font(.headline)
                Spacer()
                Text("Local files and folders → chosen cloud folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Label("Destination", systemImage: "cloud.fill")
                        .frame(width: 110, alignment: .trailing)
                    HStack(spacing: 10) {
                        Text(model.effectiveUploadDestination.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(model.effectiveUploadDestination.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            beginUploadDestinationSelection()
                        }
                        .disabled(!model.canChooseUploadDestination)
                        .help("Choose any folder in your PikPak account")
                    }
                }
                GridRow {
                    Label("Sources", systemImage: "doc.on.doc.fill")
                        .frame(width: 110, alignment: .trailing)
                    HStack(spacing: 10) {
                        Button("Choose…") {
                            _ = model.chooseFilesToUpload()
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .disabled(!model.canUploadFiles)
                        Text("Select files, folders, or both")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Label("Preparation", systemImage: "number.circle.fill")
                        .frame(width: 110, alignment: .trailing)
                    Text("Folders are scanned once, files are hashed concurrently for instant-upload detection, and large files use parallel multipart transfer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Label("Proxy", systemImage: "network")
                        .frame(width: 110, alignment: .trailing)
                    TextField("Optional, e.g. http://127.0.0.1:7890", text: $model.proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning || model.isUploading)
                }
            }
        }
        .appCard(padding: 14)
    }

    private var savedUploadBatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Queued & Paused Uploads", systemImage: "tray.full")
                .font(.headline)
            Text("Resume after quitting or stopping. Completed files and cloud folders are reused; an interrupted file may restart. Keep the original local files in place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.resumableUploadBatches) { batch in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.arrow.up")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.sources.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .help(batch.sources.joined(separator: "\n"))
                                Text("To \(batch.destination.path) · \(batch.completedFiles) of \(batch.totalFiles) files complete at last save")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            let queued = model.automaticUploadBatchIDs.contains(batch.id)
                            Button(queued ? "Pause" : "Resume") {
                                if queued { model.pauseSavedUpload(batch.id) } else { model.resumeSavedUpload(batch.id) }
                            }.buttonStyle(.borderedProminent).pointingHandCursor()
                                .disabled(!queued && !model.canUploadFiles)
                            Button("Cancel", role: .destructive) { model.discardSavedUpload(batch.id) }
                                .help("Cancel this queued upload; local originals and completed cloud files are kept")
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(height: min(CGFloat(model.resumableUploadBatches.count) * 66, 150))
        }
        .appCard(padding: 12)
    }

    private var uploadControls: some View {
        FinderTransferActionLayout {
            Button {
                _ = model.chooseFilesToUpload()
            } label: {
                Label(
                    "Choose Files or Folders…",
                    systemImage: "arrow.up.circle"
                )
            }
            .buttonStyle(.borderedProminent).pointingHandCursor()
            .disabled(!model.canUploadFiles)

            Button {
                if model.isUploadPaused {
                    model.resumeUpload()
                } else {
                    model.pauseUpload()
                }
            } label: {
                Label(
                    model.isUploadPaused ? "Continue Upload" : "Pause Upload",
                    systemImage: model.isUploadPaused ? "play.circle" : "pause.circle"
                )
            }
            .disabled(model.isUploadPaused ? !model.canResumeUpload : !model.canPauseUpload)

            Button(role: .destructive) {
                model.cancelAllUploads()
            } label: {
                Label("Cancel Upload", systemImage: "stop.circle")
            }
            .disabled(!model.isUploading)

            if !model.failedUploadTransfers.isEmpty, !model.isUploading {
                Text("Use Retry on a failed file below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                selectedTab = 0
            } label: {
                Label("Show Cloud Folder", systemImage: "folder")
            }
            .disabled(model.isRunning)
        }
    }

    private var uploadProgressDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(uploadStateColor.opacity(0.13))
                    Image(systemName: uploadStateSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(uploadStateColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload progress")
                        .font(.headline)
                    Text(uploadStateSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text(uploadPercentText)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(uploadStateColor)
                    if let uploadProgressBasisLabel {
                        Text(uploadProgressBasisLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.uploadRunState == .hashing, model.uploadTotalFiles == 0 {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(uploadStateColor)
            } else {
                ProgressView(value: model.uploadOverallFraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(uploadStateColor)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    downloadMetric(
                        title: "Completed data",
                        value: uploadBytesSummary,
                        systemImage: "arrow.up"
                    )
                    downloadMetric(
                        title: "Speed",
                        value: uploadSpeedSummary,
                        systemImage: "speedometer"
                    )
                }
                GridRow {
                    uploadFilesMetric
                    downloadMetric(
                        title: "Remaining",
                        value: uploadRemainingSummary,
                        systemImage: "clock"
                    )
                }
            }
        }
        .appCard(padding: 14)
    }

    private var uploadTransferBoard: some View {
        FinderTransferBoardLayout(finishedMinimumHeight: model.failedUploadTransfers.isEmpty ? 210 : 330) {
            uploadStack(
                title: "Uploading",
                systemImage: "arrow.up.circle.fill",
                color: .blue,
                emptyTitle: model.isUploading ? "Preparing the next file" : "No active uploads",
                emptySystemImage: "bolt.horizontal.circle",
                totalCount: model.activeUploadCount,
                visibleSubsetLabel: "Active",
                transfers: model.uploadingTransfers
            )
            uploadStack(
                title: "Queue",
                systemImage: "text.line.first.and.arrowtriangle.forward",
                color: .orange,
                emptyTitle: "No files waiting",
                emptySystemImage: "tray",
                totalCount: model.queuedUploadCount,
                visibleSubsetLabel: "Next",
                transfers: model.queuedUploadTransfers
            )
            VStack(spacing: 12) {
                uploadStack(
                    title: "Completed",
                    systemImage: "checkmark.circle.fill",
                    color: .green,
                    emptyTitle: "Uploaded files appear here",
                    emptySystemImage: "checkmark.circle",
                    totalCount: model.uploadCompletedFiles + model.uploadInstantFiles,
                    visibleSubsetLabel: "Latest",
                    transfers: model.completedUploadTransfers.reversed()
                )
                .frame(minHeight: 160)
                .layoutPriority(1)

                if !model.failedUploadTransfers.isEmpty {
                    uploadStack(
                        title: "Failed",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red,
                        emptyTitle: "Failed uploads appear here",
                        emptySystemImage: "exclamationmark.circle",
                        totalCount: model.failedUploadTransfers.count,
                        visibleSubsetLabel: "Latest",
                        transfers: model.failedUploadTransfers.reversed()
                    )
                    .frame(minHeight: 150, idealHeight: 210, maxHeight: 250)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func uploadStack<Transfers: RandomAccessCollection>(
        title: String,
        systemImage: String,
        color: Color,
        emptyTitle: String,
        emptySystemImage: String,
        totalCount: Int,
        visibleSubsetLabel: String,
        transfers: Transfers
    ) -> some View where Transfers.Element == UploadTransfer {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    if totalCount > transfers.count {
                        Text("\(visibleSubsetLabel) \(transfers.count.formatted()) shown")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(totalCount.formatted())
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)

            Divider()

            if transfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: emptySystemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(emptyTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                List {
                    ForEach(transfers) { transfer in
                        uploadTransferRow(transfer)
                            .padding(.vertical, 4)
                            .listRowInsets(
                                EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appCard(padding: 0)
    }

    private func uploadTransferRow(_ transfer: UploadTransfer) -> some View {
        HStack(spacing: 9) {
            Image(systemName: uploadTransferSymbol(transfer.state))
                .foregroundStyle(uploadTransferColor(transfer.state))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(transfer.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.name)
                    Spacer()
                    Text(model.cancelledUploadIDs.contains(transfer.id) ? "Cancelled" : model.pausedUploadIDs.contains(transfer.id) ? "Paused" : uploadTransferStateTitle(transfer.state))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(uploadTransferColor(transfer.state))
                }
                if transfer.state == .hashing || transfer.state == .uploading,
                   let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(uploadTransferColor(transfer.state))
                } else if case .retrying = transfer.state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                }
                Text(uploadTransferBytesSummary(transfer))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if transfer.state != .completed && transfer.state != .instant && !model.cancelledUploadIDs.contains(transfer.id) {
                    HStack(spacing: 10) {
                        Spacer()
                        let paused = model.pausedUploadIDs.contains(transfer.id)
                        Button { if paused { model.resumeUploadFile(transfer) } else { model.pauseUploadFile(transfer) } } label: {
                            Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.circle" : "pause.circle")
                        }.help(paused ? "Resume this file" : "Pause this file")
                        Button(role: .destructive) { model.cancelUploadFile(transfer) } label: { Label("Cancel", systemImage: "xmark.circle") }
                            .help("Cancel this upload; the local source is kept")
                    }.font(.caption).buttonStyle(.borderless).pointingHandCursor()
                }
                if let diagnostic = transfer.failureDiagnostic {
                    ErrorDiagnosticBlock(
                        diagnostic: diagnostic,
                        summary: "Upload failed: \(transfer.name)",
                        compact: true
                    )
                    HStack {
                        Spacer()
                        Button {
                            model.retryFailedUpload(transfer)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .controlSize(.small)
                        .disabled(!model.canRetryFailedUpload(transfer))
                        .help(
                            model.canRetryFailedUpload(transfer)
                                ? "Retry this file in its original PikPak folder"
                                : "The local source is unavailable or another operation is active"
                        )
                    }
                }
            }
        }
    }

    private var uploadStateColor: Color {
        switch model.uploadRunState {
        case .ready: return .secondary
        case .hashing, .uploading: return .blue
        case .paused: return .orange
        case .stopping, .stopped: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var uploadStateSymbol: String {
        switch model.uploadRunState {
        case .ready: return "arrow.up"
        case .hashing: return "number.circle"
        case .uploading: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var uploadStateSummary: String {
        if model.isUploadPaused {
            return model.activeUploadCount > 0
                ? "Paused • \(model.activeUploadCount) active"
                : "Paused"
        }
        if model.activeUploadCount > 0 {
            let uploading = model.uploadingTransfers.filter { $0.state == .uploading }.count
            let checking = model.uploadingTransfers.filter { $0.state == .hashing }.count
            if model.activeUploadCount > 1 || model.uploadInstantFiles > 0 {
                var activities: [String] = []
                if uploading > 0 {
                    activities.append("\(uploading) uploading")
                }
                if checking > 0 {
                    activities.append("\(checking) checking")
                }
                if model.uploadInstantFiles > 0 {
                    activities.append("\(model.uploadInstantFiles.formatted()) instant")
                }
                return activities.joined(separator: " • ")
            }
        }
        if let transfer = model.uploadingTransfers.first {
            let action = transfer.state == .hashing ? "Checking" : "Uploading"
            return "\(action) \(transfer.name)"
        }
        if model.uploadFailedFiles > 0 {
            return "\(model.uploadFailedFiles) failed • \(model.uploadRunState.title)"
        }
        if model.uploadInstantFiles > 0 {
            return "\(model.uploadInstantFiles) instant • \(model.uploadRunState.title)"
        }
        return model.uploadRunState.title
    }

    private var uploadPercentText: String {
        guard let fraction = model.uploadOverallFraction else {
            return model.uploadRunState == .hashing ? "…" : "—"
        }
        return "\(Int((fraction * 100).rounded(.down)))%"
    }

    private var uploadProgressBasisLabel: String? {
        if model.uploadTotalBytes > 0 { return "of data" }
        if model.uploadTotalFiles > 0 { return "of files" }
        return nil
    }

    private var uploadBytesSummary: String {
        guard model.uploadTotalBytes > 0 else {
            return model.uploadUploadedBytes > 0 ? formatBytes(model.uploadUploadedBytes) : "—"
        }
        return "\(formatBytes(model.uploadUploadedBytes)) / \(formatBytes(model.uploadTotalBytes))"
    }

    private var uploadSpeedSummary: String {
        if model.isUploadPaused { return "Paused" }
        guard model.isUploading else { return "—" }
        if model.uploadBytesPerSecond > 1 {
            return "\(formatBytes(UInt64(model.uploadBytesPerSecond)))/s upload"
        }
        if model.uploadHashBytesPerSecond > 1 {
            return "\(formatBytes(UInt64(model.uploadHashBytesPerSecond)))/s checking"
        }
        return model.uploadRunState == .uploading
            ? "Starting upload…"
            : "Measuring checks…"
    }

    private var uploadFilesPrimarySummary: String {
        if model.uploadTotalFiles == 0, model.uploadTotalFolders > 0 {
            return "\(model.uploadCreatedFolders.formatted()) / \(model.uploadTotalFolders.formatted()) folders"
        }
        guard model.uploadTotalFiles > 0 else { return "—" }
        let complete = model.uploadCompletedFiles + model.uploadInstantFiles
        return "\(complete.formatted()) / \(model.uploadTotalFiles.formatted()) completed"
    }

    private var uploadFilesSecondarySummary: String {
        guard model.uploadTotalFiles > 0 else {
            return model.uploadTotalFolders > 0 ? "Creating cloud folders" : "No upload selected"
        }
        var pieces: [String] = []
        if model.uploadInstantFiles > 0 {
            pieces.append("\(model.uploadInstantFiles.formatted()) instant")
        }
        if model.uploadFailedFiles > 0 {
            pieces.append("\(model.uploadFailedFiles.formatted()) failed")
        }
        if pieces.isEmpty, model.uploadTotalFolders > 0,
           model.uploadCreatedFolders < model.uploadTotalFolders {
            pieces.append(
                "\(model.uploadCreatedFolders.formatted()) / \(model.uploadTotalFolders.formatted()) folders ready"
            )
        }
        if pieces.isEmpty {
            let remaining = max(model.uploadTotalFiles - model.uploadProcessedFiles, 0)
            pieces.append(remaining > 0 ? "\(remaining.formatted()) remaining" : "All files processed")
        }
        return pieces.joined(separator: " • ")
    }

    private var uploadFilesMetric: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Files", systemImage: "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(uploadFilesPrimarySummary)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(uploadFilesSecondarySummary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(model.uploadFailedFiles > 0 ? Color.red : Color.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(uploadFilesPrimarySummary)\n\(uploadFilesSecondarySummary)")
    }

    private var uploadRemainingSummary: String {
        guard model.uploadTotalBytes > 0 else { return "—" }
        let bytes = "\(formatBytes(model.uploadRemainingBytes)) left"
        if model.isUploadPaused { return "\(bytes) • Paused" }
        guard let seconds = model.uploadEstimatedSecondsRemaining else { return bytes }
        return "\(bytes) • \(formatDuration(seconds))"
    }

    private func uploadTransferBytesSummary(_ transfer: UploadTransfer) -> String {
        switch transfer.state {
        case .queued:
            return transfer.totalBytes > 0 ? formatBytes(transfer.totalBytes) : "Empty file"
        case .hashing:
            guard transfer.totalBytes > 0 else { return "Preparing empty file" }
            return "Hashed \(formatBytes(transfer.hashedBytes)) of \(formatBytes(transfer.totalBytes))"
        case .uploading, .retrying, .failed, .stopped:
            guard transfer.totalBytes > 0 else { return "Empty file" }
            return "\(formatBytes(transfer.uploadedBytes)) of \(formatBytes(transfer.totalBytes))"
        case .instant:
            return transfer.totalBytes > 0
                ? "Instant upload • \(formatBytes(transfer.totalBytes))"
                : "Instant upload • Empty file"
        case .completed:
            return transfer.totalBytes > 0 ? formatBytes(transfer.totalBytes) : "Empty file"
        }
    }

    private func uploadTransferStateTitle(_ state: UploadTransferState) -> String {
        switch state {
        case .queued: return "Waiting"
        case .hashing: return "Hashing"
        case .uploading: return "Uploading"
        case .retrying(let attempt, let maximum): return maximum > 0 ? "Retry \(attempt) of \(maximum)" : "Retry \(attempt)"
        case .instant: return "Instant"
        case .completed: return "Complete"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    private func uploadTransferSymbol(_ state: UploadTransferState) -> String {
        switch state {
        case .queued: return "clock"
        case .hashing: return "number.circle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .retrying: return "arrow.clockwise.circle.fill"
        case .instant: return "bolt.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    private func uploadTransferColor(_ state: UploadTransferState) -> Color {
        switch state {
        case .queued: return .secondary
        case .hashing, .uploading: return .blue
        case .retrying: return .orange
        case .instant: return .purple
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    private var downloadSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { downloadDestination; downloadCleanupOption }
                VStack(alignment: .leading, spacing: 10) { downloadDestination; downloadCleanupOption }
            }
            controls
            if let preparationStatus = model.downloadPreparationStatus ?? model.downloadSpeedChartWaitingMessage {
                Label(preparationStatus, systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let destinationStatus = model.downloadDestinationStatus {
                HStack {
                    Label(destinationStatus, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if let replaced = model.downloadDestinationReplacement {
                        Button("Use This Disk") { model.acceptReplacementDisk() }.controlSize(.small)
                            .help("Continue the unfinished downloads on the disk now mounted at \(replaced). Choose this only if you restored them onto it.")
                    }
                }
            }
            if advancedExpanded {
                Divider()
                HStack(spacing: 8) {
                    Text("Proxy").font(.caption)
                    TextField("Optional, e.g. http://127.0.0.1:7890", text: $model.proxyURL)
                        .textFieldStyle(.roundedBorder)
                }
                Label("Guest access first, then the selected account connection", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.appCard(padding: 12)
    }

    private var downloadDestination: some View {
        HStack(spacing: 8) {
            Label("Save to", systemImage: "folder").font(.callout.weight(.medium)).fixedSize()
            Text(model.outputURL.path).font(.callout).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).help(model.outputURL.path)
            Button("Choose…") { model.chooseOutputFolder() }.fixedSize()
                .disabled(model.isRunning || model.isDownloading)
            Image(systemName: "arrow.clockwise.circle").foregroundStyle(.secondary)
                .help("Unfinished downloads are saved across app restarts. Resume uses existing partial files; completed files are skipped.")
        }.frame(minWidth: 250)
    }

    private var downloadCleanupOption: some View {
        Toggle("Move to PikPak Trash after verification", isOn: $finderSettings.deleteAfterDownload)
            .toggleStyle(.checkbox).font(.callout).fixedSize()
            .help("Move each file in your account to PikPak Trash only after its local download is verified complete. Shared-link originals are kept. Applies to queued and active downloads.")
    }

    private var controls: some View {
        let pausing = !model.downloadsPaused && (model.isDownloading || model.hasAutomaticDownloadRetries)
        let stopping = model.downloadRunState == .stopping
        return FinderTransferActionLayout {
            Button {
                if pausing { model.stop() }
                else { model.startPendingDownloads() }
            } label: {
                Label(stopping ? (model.downloadsPaused ? "Pausing…" : "Stopping…") : pausing ? "Pause All" : "Resume Downloads",
                    systemImage: pausing || stopping ? "pause.circle" : "play.circle.fill")
            }
            .buttonStyle(.borderedProminent).pointingHandCursor()
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(stopping || (!pausing && !model.canStartPendingDownloads))
            .help(pausing ? "Pause cloud reception and automatic retries. Buffered writes and disk verification continue."
                : "Resume downloads from the waiting queue using existing partial files.")

            Button(role: .destructive) { model.cancelAllDownloads() } label: {
                Label("Cancel All", systemImage: "xmark.circle")
            }.disabled(!model.isDownloading && model.pendingDownloadItems.isEmpty && model.interruptedDownloadCount == 0
                && model.queuedDownloadTransfers.isEmpty && model.downloadingTransfers.isEmpty
                && model.retryingDownloadTransfers.isEmpty && model.failedDownloadTransfers.isEmpty)
                .help("Clear unfinished downloads from the queue. Their partial files are removed when the original destination disk is available; completed files are kept.")

            if model.pendingDownloadItemCount > 0 {
                Label(
                    "\(model.pendingDownloadItemCount.formatted()) queued selections",
                    systemImage: "tray.full"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Files start as soon as a connection is available. Paused items wait until resumed.")
            }

            if !model.failedDownloadTransfers.isEmpty {
                if model.hasAutomaticDownloadRetries {
                    Label("Failed files retry automatically", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    model.retryFailedDownloads()
                } label: {
                    Label(model.hasAutomaticDownloadRetries ? "Retry All Now" : "Retry All Failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent).pointingHandCursor()
                .disabled(!model.canRetryFailedDownloads)
                .help("Retry eligible files now in their original local destination. Failed downloads also retry automatically; paused files wait for Resume.")
            }

            Button("Open Download Folder") { model.openOutputFolder() }
            Button { advancedExpanded.toggle() } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }.help("Proxy and connection settings")
            if model.interruptedDownloadCount > 0 {
                Button("Return \(model.interruptedDownloadCount) Interrupted to Queue") { model.requeueInterruptedDownloads() }
            }
        }
    }

    private var downloadProgressDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(downloadStateColor.opacity(0.13))
                    Image(systemName: downloadStateSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(downloadStateColor)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Download progress")
                        .font(.headline)
                    Text(downloadStateSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text(downloadPercentText)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(downloadStateColor)
                    if model.downloadEstimatedFraction != nil {
                        Text("estimated").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if let fraction = model.downloadOverallFraction ?? model.downloadEstimatedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(downloadStateColor)
            } else if model.downloadTotalsAreIncomplete || (model.downloadRunState == .scanning && model.downloadTotalFiles == 0) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(downloadStateColor)
            } else {
                ProgressView(value: model.downloadOverallFraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(downloadStateColor)
            }

            FinderTransferMetricLayout {
                downloadMetric(
                    title: "Downloaded",
                    value: downloadBytesSummary,
                    systemImage: "arrow.down", wrapsValue: true
                )
                downloadMetric(
                    title: "Speed",
                    value: downloadSpeedSummary,
                    systemImage: "speedometer", wrapsValue: true
                )
                downloadMetric(
                    title: model.downloadTotalsAreIncomplete ? "Files discovered" : "Files",
                    value: downloadFilesSummary,
                    systemImage: "doc.on.doc", wrapsValue: true
                )
                downloadMetric(
                    title: "Remaining",
                    value: downloadRemainingSummary,
                    systemImage: "clock", wrapsValue: true
                )
            }

        }
    }

    private var downloadBufferDashboard: some View {
        DownloadBufferDashboard(usage: model.downloadBufferUsage, isDownloading: model.isDownloading,
            isPaused: model.downloadsPaused,
            configuredLimit: model.finderSettings.downloadBufferLimit, destination: model.outputURL)
    }

    private var downloadTransferBoard: some View {
        VStack(spacing: 10) {
            downloadStack(title: "Downloading", systemImage: "arrow.down.circle.fill", color: .blue,
                emptyTitle: model.isDownloading ? "Preparing downloads" : "No active downloads",
                emptySystemImage: "bolt.horizontal.circle", transfers: model.downloadingTransfers,
                isExpanded: $downloadingExpanded)
            downloadQueueStack
            if !model.retryingDownloadTransfers.isEmpty {
                downloadStack(title: "Retry", systemImage: "arrow.clockwise.circle.fill", color: .orange,
                    emptyTitle: "Files waiting to retry appear here", emptySystemImage: "clock.arrow.circlepath",
                    transfers: model.retryingDownloadTransfers, isExpanded: $downloadRetryExpanded)
            }
            downloadStack(title: "Completed", systemImage: "checkmark.circle.fill", color: .green,
                emptyTitle: "Completed files appear here", emptySystemImage: "checkmark.circle",
                transfers: model.successfulDownloadTransfers.reversed(), isExpanded: $downloadCompletedExpanded)
            if !model.visibleFailedDownloadTransfers.isEmpty {
                downloadStack(title: "Failed", systemImage: "exclamationmark.triangle.fill", color: .red,
                    emptyTitle: "Failed downloads appear here", emptySystemImage: "exclamationmark.circle",
                    transfers: model.visibleFailedDownloadTransfers.reversed(), isExpanded: $downloadFailedExpanded)
            }
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private var downloadQueueStack: some View {
        // Capture coherent source snapshots without rebuilding every display
        // row on each progress update. The pager asks for at most fifty rows.
        let preparing = model.preparingDownloadItems
        let pending = model.pendingDownloadItems
        let queued = model.queuedDownloadTransfers
        let pendingOffset = preparing.count
        let queuedOffset = pendingOffset + pending.count
        let totalCount = queuedOffset + queued.count
        return DownloadTransferSection(title: "Queue", symbol: "tray.full", color: .orange,
            count: totalCount, isExpanded: $downloadQueueExpanded) {
            if model.canClearPendingDownloads {
                Button("Clear") { model.clearPendingDownloads() }.foregroundStyle(.red)
                    .help("Remove all selections that have not started")
            }
        } content: {
            if totalCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(
                        model.downloadRunState == .scanning
                            ? "Scanning the selected folder…"
                            : "Choose Download in Browser or Links to add items"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                TransferPagedRows(itemCount: totalCount, itemAt: { index in
                    if index < pendingOffset { return DownloadQueueDisplayRow.pending(preparing[index], preparing: true) }
                    if index < queuedOffset { return DownloadQueueDisplayRow.pending(pending[index - pendingOffset], preparing: false) }
                    return DownloadQueueDisplayRow.file(queued[queued.index(queued.startIndex, offsetBy: index - queuedOffset)])
                }) { row in
                    Group {
                        switch row {
                        case .pending(let item, let preparing): pendingDownloadRow(item, preparing: preparing)
                        case .file(let transfer): downloadTransferRow(transfer)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
            }
        }
        .appCard(padding: 0)
    }

    private func pendingDownloadRow(_ item: PendingDownloadItem, preparing: Bool = false) -> some View {
        let paused = model.pendingDownloadIsPaused(item)
        return HStack(spacing: 9) {
            Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isFolder ? Color.blue : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.name)
                    Spacer()
                    Text(paused || model.downloadsPaused ? "Paused" : preparing ? "Preparing…" : "Queued")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(preparing ? Color.blue : .orange)
                        .help(paused || model.downloadsPaused ? "This selection is paused. Use Resume to start it." : preparing ? "Preparing this selection for download; its files appear as they become ready." : model.isDownloading
                            ? "Starts as soon as a download connection is available."
                            : "Files start automatically. Use Resume Downloads if the queue is paused.")
                }
                if let size = item.knownSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .binary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text((item.isShared ? "Shared link • " : "PikPak • ") + item.remotePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Cloud source: \(item.remotePath)\nLocal destination: \(item.destinationPath)")
            }

            Button { if paused { model.resumePendingDownload(item) } else { model.pausePendingDownload(item) } } label: {
                Image(systemName: paused ? "play.circle" : "pause.circle")
            }.help(paused ? "Resume \(item.name)" : "Pause \(item.name)")
                .accessibilityLabel(paused ? "Resume \(item.name)" : "Pause \(item.name)")
            Button(role: .destructive) { model.cancelPendingDownload(item) } label: { Image(systemName: "xmark.circle") }
                .help("Cancel \(item.name) and remove any partial download")
                .accessibilityLabel("Cancel \(item.name)")

        }
        .accessibilityElement(children: .contain)
    }

    private func downloadStack<Transfers: RandomAccessCollection>(
        title: String,
        systemImage: String,
        color: Color,
        emptyTitle: String,
        emptySystemImage: String,
        transfers: Transfers,
        isExpanded: Binding<Bool>
    ) -> some View where Transfers.Element == DownloadTransfer {
        DownloadTransferSection(title: title, symbol: systemImage, color: color,
            count: transfers.count, isExpanded: isExpanded) { EmptyView() } content: {
            if transfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: emptySystemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(emptyTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                TransferPagedRows(items: transfers) { transfer in
                    downloadTransferRow(transfer)
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
            }
        }
        .appCard(padding: 0)
    }

    private func downloadMetric(title: String, value: String, systemImage: String, wrapsValue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(wrapsValue ? nil : 1)
                .fixedSize(horizontal: false, vertical: wrapsValue)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadTransferDisplayTitle(_ transfer: DownloadTransfer) -> String {
        DownloadTransferPresentation.title(transfer.state,
            cancelled: model.cancelledDownloadIDs.contains(transfer.id),
            paused: model.pausedDownloadIDs.contains(transfer.id) || model.downloadsPaused || model.pausedDownloadSelection(containing: transfer) != nil,
            automaticRetry: model.automaticDownloadRetryStatus(transfer),
            finalFailure: model.downloadFailureIsFinal(transfer))
    }

    private func downloadTransferRow(_ transfer: DownloadTransfer) -> some View {
        let displayTitle = downloadTransferDisplayTitle(transfer)
        let waiting = displayTitle == "Waiting to retry" || displayTitle == "Retry queued"
        return HStack(spacing: 9) {
            Image(systemName: waiting ? "arrow.clockwise.circle.fill" : downloadTransferSymbol(transfer.state))
                .foregroundStyle(waiting ? Color.orange : downloadTransferColor(transfer.state))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(transfer.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.name)
                    Spacer()
                    Text(displayTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(waiting ? Color.orange : downloadTransferColor(transfer.state))
                        .help(downloadTransferStateHelp(transfer.state, title: displayTitle))
                }
                downloadTransferProgress(transfer)
                HStack(spacing: 8) {
                    Text(transferBytesSummary(transfer))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if transfer.state == .downloading {
                        let speed = "\(formatBytes(UInt64(max(0, min(transfer.bytesPerSecond, Double(Int64.max))))))/s"
                        Text(speed).fixedSize()
                            .help("Current network speed for this file")
                            .accessibilityLabel("Download speed: \(speed)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if let notice = transfer.recoveredCopyNotice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = transfer.sourceCleanupMessage {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(transfer.sourceCleanupFailed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = transfer.completedFileURL {
                    HStack {
                        Spacer()
                        Button { model.revealDownloadedFile(transfer) } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .help("Show \(url.lastPathComponent) in Finder")
                    }
                    .font(.caption).buttonStyle(.borderless).pointingHandCursor()
                }

                if transfer.state != .completed && transfer.state != .skipped && !model.cancelledDownloadIDs.contains(transfer.id) {
                    HStack(spacing: 10) {
                        Spacer()
                        let pausedSelection = model.pausedDownloadSelection(containing: transfer)
                        let paused = model.pausedDownloadIDs.contains(transfer.id) || transfer.state == .stopped || model.downloadsPaused || pausedSelection != nil
                        let resumeFolder = pausedSelection?.isFolder == true
                        Button { if paused { model.resumeDownloadFile(transfer) } else { model.pauseDownloadFile(transfer) } } label: {
                            Label(paused ? (resumeFolder ? "Resume Folder" : "Resume") : "Pause", systemImage: paused ? "play.circle" : "pause.circle")
                        }.help(paused ? (resumeFolder ? "Resume \(pausedSelection!.name) and its files" : "Resume this file") : "Pause this file and keep its partial download")
                            .accessibilityLabel(paused && resumeFolder ? "Resume folder \(pausedSelection!.name) and its files" : paused ? "Resume this file" : "Pause this file")
                        Button(role: .destructive) { model.cancelDownloadFile(transfer) } label: { Label("Cancel", systemImage: "xmark.circle") }
                            .help("Cancel this file and delete its partial download")
                    }.font(.caption).buttonStyle(.borderless).pointingHandCursor()
                }
                if transfer.state == .failed && !model.cancelledDownloadIDs.contains(transfer.id) {
                    if let reason = transfer.finalFailureReason {
                        Text(reason).font(.caption.weight(.semibold)).foregroundStyle(.red).textSelection(.enabled)
                        if let error = transfer.error {
                            Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else {
                        if let detail = model.downloadRetryDetail(transfer) {
                            Text(detail).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = transfer.error {
                            Text("Last error: \(error)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            model.retryFailedDownload(transfer)
                        } label: {
                            Label(model.automaticDownloadRetryStatus(transfer) != nil ? "Retry Now" : "Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .controlSize(.small)
                        .disabled(!model.canRetryFailedDownload(transfer) || model.automaticDownloadRetryStatus(transfer) == "Retry queued")
                        .help(
                            model.canRetryFailedDownload(transfer)
                                ? "Retry this file now. Automatic recovery preserves its existing progress and original destination."
                                : "This older failure does not include enough source information to retry individually"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadTransferProgress(_ transfer: DownloadTransfer) -> some View {
        switch transfer.state {
        case .preparing:
            ProgressView()
                .progressViewStyle(.linear)
                .tint(downloadTransferColor(transfer.state))
        case .downloading, .retrying:
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(downloadTransferColor(transfer.state))
            }
        case .queued, .completed, .skipped, .failed, .stopped:
            EmptyView()
        }
    }

    private var downloadStateColor: Color {
        if DownloadProgressPresentation.waitingForDiscovery(state: model.downloadRunState,
            totalsIncomplete: model.downloadTotalsAreIncomplete) { return .secondary }
        switch model.downloadRunState {
        case .ready: return .secondary
        case .scanning, .downloading: return .blue
        case .stopping, .stopped: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var downloadStateSymbol: String {
        if DownloadProgressPresentation.waitingForDiscovery(state: model.downloadRunState,
            totalsIncomplete: model.downloadTotalsAreIncomplete) { return "clock" }
        switch model.downloadRunState {
        case .ready: return "arrow.down"
        case .scanning: return "magnifyingglass"
        case .downloading: return "arrow.down.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var downloadStateSummary: String {
        let state = DownloadProgressPresentation.stateTitle(state: model.downloadRunState,
            totalsIncomplete: model.downloadTotalsAreIncomplete)
        if model.activeDownloadCount > 0 {
            return "\(model.activeDownloadCount) active • \(state)"
        }
        return state
    }

    private var downloadPercentText: String {
        DownloadProgressPresentation.percentage(fraction: model.downloadOverallFraction,
            state: model.downloadRunState, totalsIncomplete: model.downloadTotalsAreIncomplete,
            estimatedFraction: model.downloadEstimatedFraction)
    }

    private var downloadBytesSummary: String {
        if let estimate = model.downloadEstimatedTotal {
            return "\(formatBytes(model.downloadDownloadedBytes)) / ≈ \(formatBytes(estimate.totalBytes))" + (estimate.unmeasuredRoots > 0 ? "+" : "")
        }
        guard model.downloadTotalBytes > 0 else {
            if model.downloadRunState == .scanning { return "Calculating…" }
            if model.downloadDownloadedBytes > 0 {
                return "\(formatBytes(model.downloadDownloadedBytes)) downloaded"
            }
            if model.downloadRunState == .completed, model.downloadTotalFiles > 0 {
                return "0 B complete"
            }
            return model.downloadTotalFiles > 0 ? "Size unavailable" : "—"
        }
        return "\(formatBytes(model.downloadDownloadedBytes)) / \(formatBytes(model.downloadTotalBytes))"
    }

    private var downloadSpeedSummary: String {
        switch model.downloadRunState {
        case .scanning:
            return "Waiting…"
        case .downloading:
            guard model.downloadBytesPerSecond > 1 else {
                // Finished files read in full to prove they are the originals transfer nothing, but are working.
                if let verification = model.downloadVerification {
                    let files = "\(verification.files) file\(verification.files == 1 ? "" : "s")"
                    guard verification.totalBytes > 0 else { return "Verifying \(files)…" }
                    return "Verifying \(files) · \(Int(Double(verification.verifiedBytes) / Double(verification.totalBytes) * 100))%"
                }
                return model.activeDownloadCount > 0 ? "Starting…" : "Preparing…"
            }
            return "\(formatBytes(UInt64(model.downloadBytesPerSecond)))/s"
        case .completed:
            return DownloadProgressPresentation.completedSpeedTitle(totalsIncomplete: model.downloadTotalsAreIncomplete)
        case .ready, .stopping, .stopped, .failed:
            return "—"
        }
    }

    private var downloadFilesSummary: String {
        guard model.downloadTotalFiles > 0 else {
            return model.downloadRunState == .scanning ? "Scanning…" : "—"
        }
        let processed = model.downloadProcessedFiles
        if model.downloadSkippedFiles > 0 {
            return "\(processed) / \(model.downloadTotalFiles) • \(model.downloadSkippedFiles) skipped"
        }
        return "\(processed) / \(model.downloadTotalFiles)"
    }

    private var downloadRemainingSummary: String {
        DownloadProgressPresentation.remaining(state: model.downloadRunState,
            totalsIncomplete: model.downloadTotalsAreIncomplete,
            bytes: model.downloadTotalBytes > 0 ? formatBytes(model.downloadRemainingBytes) : nil,
            duration: model.downloadEstimatedSecondsRemaining.map(formatDuration),
            estimatedBytes: model.downloadDiscoveryEstimatedRemaining.map { formatBytes($0.bytes) + ($0.lowerBound ? "+" : "") },
            estimatedDuration: model.downloadDiscoveryEstimatedRemaining?.seconds.map(formatDuration))
    }

    private func transferBytesSummary(_ transfer: DownloadTransfer) -> String {
        switch transfer.state {
        case .queued, .preparing, .completed, .skipped:
            return transfer.totalBytes > 0 ? formatBytes(transfer.totalBytes) : "Size unavailable"
        case .downloading, .retrying, .failed, .stopped:
            break
        }
        guard transfer.totalBytes > 0 else { return formatBytes(transfer.downloadedBytes) }
        return "\(formatBytes(transfer.downloadedBytes)) of \(formatBytes(transfer.totalBytes))"
    }

    private func downloadTransferStateTitle(_ state: DownloadTransferState) -> String {
        switch state {
        case .queued: return "Waiting"
        case .preparing: return "Preparing"
        case .downloading: return "Downloading"
        case .retrying: return "Waiting to retry"
        case .completed: return "Complete"
        case .skipped: return "Already saved"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    private func downloadTransferStateHelp(_ state: DownloadTransferState, title: String) -> String {
        if title == "Waiting to retry", case .retrying(let attempt) = state {
            return "Retry attempt \(attempt). Downloading resumes automatically when the wait ends."
        }
        if title == "Waiting to retry" || title == "Retry queued" {
            return "The next download attempt will resume automatically. Existing progress is kept."
        }
        return title
    }

    private func downloadTransferSymbol(_ state: DownloadTransferState) -> String {
        switch state {
        case .queued: return "clock"
        case .preparing: return "ellipsis.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .retrying: return "arrow.clockwise.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "checkmark.circle"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    private func downloadTransferColor(_ state: DownloadTransferState) -> Color {
        switch state {
        case .queued: return .secondary
        case .preparing: return .blue
        case .downloading: return .blue
        case .retrying, .stopped: return .orange
        case .completed, .skipped: return .green
        case .failed: return .red
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = SafeDisplayNumber.integer(interval, rounding: .up)
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private var activity: some View {
        ActivityLogPanel(log: model.activityLog, busy: model.isRunning || model.hasBackgroundActivity,
                         expanded: $activityExpanded, clear: model.clearLog,
                         status: AnyView(transferFooterStatus))
    }

    private var transferFooterStatus: some View {
        HStack(spacing: 8) {
            if !model.statusIsError {
                FinderFooterStatus(model: model, activity: model.taskActivity,
                    message: model.status, isError: false,
                    isBusy: model.isRunning || model.hasOtherBackgroundActivity || model.isPreparingQuickLook,
                    diagnostic: nil, compact: false, openTransfers: showTransfers, openActivity: nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(model.isDownloading || model.isUploading ? "Transfers continue" : "Ready")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ArchiveActivityFooter(model: model, activity: model.extractionActivity, compact: true) { id in
                if model.revealArchiveOutput(id) {
                    model.extractionActivity.showsActivity = false
                    selectedTab = 0
                }
            }
            FinderFileOpenStatus(opener: model.fileOpener, compact: true)
        }
    }

    private var browserTrashConfirmationTitle: String {
        if let item = pendingTrashItems.first, pendingTrashItems.count == 1 {
            return "Move \(item.isFolder ? "Folder" : "File") to Trash?"
        }
        guard !pendingTrashItems.isEmpty else { return "Move to Trash?" }
        return "Move \(pendingTrashItems.count.formatted()) Items to Trash?"
    }

    private var browserSelectionSummary: String {
        let count = model.browserActionSelectionCount
        if count > 0 {
            let containsFolder = model.browserSelectionIncludesFolders
            return "\(count.formatted()) selected" + (containsFolder ? " + contents" : "")
        }
        if model.showsSharedLinkOverview {
            let linkCount = model.sharedLinks.count
            let visibleItemCount = model.sharedLinks.reduce(into: 0) { count, link in
                guard model.sharedLinkHasContents(link.id) else { return }
                count += model.sharedLinkTreeEntries(for: link.id).count
            }
            let linkLabel = "\(linkCount.formatted()) \(linkCount == 1 ? "link" : "links")"
            guard visibleItemCount > 0 else { return linkLabel }
            return linkLabel
                + " • \(visibleItemCount.formatted()) \(visibleItemCount == 1 ? "item" : "items")"
        }
        return "\(displayedBrowserItemCount) shown"
            + (model.hasMoreBrowserItems ? " + more" : "")
    }

    private func requestTrashForBrowserSelection() {
        guard !workspaceNavigation.isSwitching, model.canTrashSelectedBrowserItem else { return }
        let items = model.browserItemsSelectedForTrash
        guard !items.isEmpty else { return }
        pendingTrashItems = items
        pendingTrashContext = model.browserActionContext
        isBrowserTrashConfirmationPresented = true
    }

    private func expandBrowserSubfolders(_ items: [BrowserItem], levels: Int?) {
        // Nested contents need an outline; preserve the current location and
        // selection while switching a thumbnail context-menu action to List.
        setFinderViewMode(BrowserViewMode.list.rawValue)
        isPreviewExpanded = false
        browserListFocused = true
        model.expandBrowserSubfolders(items, levels: levels)
    }

    /// Finder-style: a menu opened on a row that is part of the selection acts
    /// on the whole selection; one opened elsewhere acts on that row alone.
    /// Link rows in the Links overview keep their own per-link selection.
    private func browserExpansionTargets(for item: BrowserItem, sharedLinkID: UUID?) -> [BrowserItem] {
        guard sharedLinkID == nil, model.isBrowserItemSelected(item.id) else { return [item] }
        let folders = model.selectedBrowserItems.filter(\.isFolder)
        return folders.contains { $0.id == item.id } ? folders : [item]
    }

    private var canSelectAllBrowserFolders: Bool {
        selectedTab == 0 && !workspaceNavigation.isSwitching
            && model.canChangeBrowserSelection && !model.showsSharedLinkOverview
            && !model.isLoginPresented && !isBrowserTrashConfirmationPresented
    }

    private func selectAllBrowserFolders() {
        guard canSelectAllBrowserFolders else { return }
        if model.selectAllBrowserFolders() > 0 { browserListFocused = true }
    }

    /// The preview pane is the context these arrows belong to, so its being
    /// open is the gate — not whether a preview happens to be loaded at the
    /// moment a key arrives.
    private var canMovePreviewSelection: Bool {
        PreviewKeyRouting.isFilePreviewTab(selectedTab, bookmarkBrowserIsOpen: isBookmarkFileBrowser) && !workspaceNavigation.isSwitching && !isChoosingUploadDestination
            && finderSettings.showsPreviewPane && model.canChangeBrowserSelection
            && !model.isLoginPresented && !isBrowserTrashConfirmationPresented
    }

    /// Keep the row the preview moved to on screen, so the list still follows
    /// along while the pane holds focus.
    private func movePreviewSelection(by offset: Int, scrollProxy: ScrollViewProxy) {
        guard canMovePreviewSelection, let targetID = model.movePreviewSelection(by: offset) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            scrollProxy.scrollTo(browserRowScrollID(targetID), anchor: .center)
        }
    }

    private func requestMergeSelectedFolders(preferredDestination: BrowserItem? = nil) {
        guard selectedTab == 0, !workspaceNavigation.isSwitching, !isChoosingUploadDestination, model.canMergeSelectedFolders else { return }
        let folders = model.selectedFoldersForMerge
        guard folders.count >= 2 else { return }
        let destinationID: String
        if let preferredDestination,
           folders.contains(where: { $0.id == preferredDestination.id }) {
            destinationID = preferredDestination.id
        } else {
            destinationID = folders[0].id
        }
        mergeFoldersRequest = MergeFoldersRequest(
            folders: folders,
            initialDestinationID: destinationID
        )
    }

    private func showTaskStatusAfterPresentation() {
        Task { @MainActor in
            // Let the originating menu or confirmation close before presenting.
            try? await Task.sleep(nanoseconds: 180_000_000)
            model.taskActivity.showsDetails = true
        }
    }

    private func requestEmptyFolderCleanup() {
        guard selectedTab == 0, !workspaceNavigation.isSwitching, !isChoosingUploadDestination, model.canRemoveEmptyFolders else { return }
        pendingEmptyFolderScope = model.emptyFolderCleanupScope
        isEmptyFolderConfirmationPresented = true
    }

    private func requestDSStoreCleanup() {
        guard selectedTab == 0, !workspaceNavigation.isSwitching, !isChoosingUploadDestination, model.canRemoveDSStoreFiles else { return }
        pendingDSStoreScope = model.dsStoreCleanupScope
        isDSStoreConfirmationPresented = true
    }

    private func requestNewFolder(in explicitParent: BrowserLocation? = nil) {
        guard model.canCreateFolder,
              let parent = explicitParent ?? model.browserStack.last
        else { return }
        pendingNewFolderParent = parent
        newFolderName = ""
        isNewFolderPresented = true
    }

    private func beginSharedLinkEdit(_ link: SharedLinkEntry) {
        guard model.canEditSharedLink(link.id) else { return }
        editSharedLinkRequest = EditSharedLinkRequest(
            id: link.id,
            url: link.url,
            passCode: model.sharedLinkAccessCode(for: link.id)
        )
    }

    private func requestRename(_ item: BrowserItem) {
        guard model.canRenameBrowserItem(item) else { return }
        if !model.isBrowserItemSelected(item.id) {
            model.selectBrowserItem(item)
        }
        pendingRenameItem = item
        renameItemName = item.name
        isRenameItemPresented = true
    }

    private func requestArchiveExtraction(for item: BrowserItem) {
        guard !workspaceNavigation.isSwitching, model.canOpenArchiveExtraction(item) else { return }
        let archives = model.archivesForExtraction(contextItem: item)
        if archives.count == 1, model.hasArchiveTask(for: item) {
            model.extractionActivity.showsActivity = true
            return
        }
        model.extractArchives(archives)
    }

    private func extractionActionTitle(for item: BrowserItem) -> String {
        let count = model.archivesForExtraction(contextItem: item).count
        if count > 1 { return "Extract \(count) Selected Archives" }
        return model.hasArchiveTask(for: item) ? "Show Extraction Progress" : "Extract in PikPak"
    }

    private func trashConfirmationMessage(for items: [BrowserItem]) -> String {
        guard items.count != 1 else {
            let item = items[0]
            if item.isFolder {
                return "The folder “\(item.name)” and everything inside it will be moved to PikPak Trash. You can restore it from an official PikPak client until Trash is emptied."
            }
            return "The file “\(item.name)” will be moved to PikPak Trash. You can restore it from an official PikPak client until Trash is emptied."
        }
        let folderNote = items.contains(where: \.isFolder)
            ? " Selected folders include everything inside them."
            : ""
        return "The \(items.count.formatted()) selected items will be moved to PikPak Trash.\(folderNote) You can restore them from an official PikPak client until Trash is emptied."
    }

    private func previewSymbol(for item: BrowserItem) -> String {
        if item.isTextPreviewable { return "doc.plaintext" }
        switch item.mediaKind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        // Use the same binary scale as PikPak's quota meter. Mixing Finder's
        // decimal `.file` style with the quota's binary style made one byte
        // count appear larger when the values were compared in TB.
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }

    private func formatStorageBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        // PikPak markets this plan as 10 TB while reporting 10 TiB in bytes;
        // binary formatting therefore matches the official UI (for example,
        // roughly 7.41 TB used out of 10 TB).
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

private extension View {
    /// SwiftUI's default macOS focus halo is much heavier than Finder's list
    /// view treatment. Keep keyboard focus and arrow navigation, but suppress
    /// the large blue rectangle on systems that expose this API.
    @ViewBuilder
    func hideKeyboardFocusEffectWhenAvailable() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

private struct EditSharedLinkRequest: Identifiable {
    /// The link's own id, so re-presenting the same row is stable.
    let id: UUID
    let url: String
    let passCode: String
}

/// A sheet rather than an alert: a macOS alert is pinned to roughly 260 points
/// and ignores width hints, which truncates a PikPak share URL to the point of
/// being uneditable.
private struct EditSharedLinkSheet: View {
    let originalURL: String
    let originalPassCode: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var url: String
    @State private var passCode: String
    @FocusState private var urlFieldFocused: Bool

    init(
        originalURL: String,
        originalPassCode: String,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalURL = originalURL
        self.originalPassCode = originalPassCode
        self.onSave = onSave
        self.onCancel = onCancel
        _url = State(initialValue: originalURL)
        _passCode = State(initialValue: originalPassCode)
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPassCode: String {
        passCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var urlChanged: Bool {
        !SharedLinkIdentity.equivalent(trimmedURL, originalURL)
    }

    /// Save stays disabled until something actually differs, so Return cannot
    /// silently reopen an unchanged link.
    private var canSave: Bool {
        !trimmedURL.isEmpty && (urlChanged || trimmedPassCode != originalPassCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: "link")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Link")
                        .font(.title3.weight(.semibold))
                    Text("Change this link's URL or access code, then reopen it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Link URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("https://mypikpak.com/s/…", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .focused($urlFieldFocused)
                        .accessibilityLabel("Shared link URL")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Access code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $passCode)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .accessibilityLabel("Shared link access code")
                }
            }

            Label(
                urlChanged
                    ? "The URL changed, so this link's saved-item marks and cached folder sizes are cleared — they describe the previous share."
                    : "Saving reopens this link. Its saved-item marks and cached folder sizes are kept, because it still points at the same share.",
                systemImage: urlChanged ? "exclamationmark.triangle" : "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedURL, trimmedPassCode)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { urlFieldFocused = true }
    }
}

private struct MergeFoldersSheet: View {
    let folders: [BrowserItem]
    @State private var destinationID: String
    let onMerge: (String) -> Void
    let onCancel: () -> Void

    init(
        folders: [BrowserItem],
        initialDestinationID: String,
        onMerge: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.folders = folders
        let resolvedDestinationID = folders.contains {
            $0.id == initialDestinationID
        } ? initialDestinationID : (folders.first?.id ?? "")
        _destinationID = State(initialValue: resolvedDestinationID)
        self.onMerge = onMerge
        self.onCancel = onCancel
    }

    private var destination: BrowserItem? {
        folders.first { $0.id == destinationID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Merge Selected Folders")
                        .font(.title3.weight(.semibold))
                    Text("Choose the folder name and location that will remain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Keep as", selection: $destinationID) {
                ForEach(folders) { folder in
                    Text(folder.name).tag(folder.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(folders) { folder in
                    Button {
                        destinationID = folder.id
                    } label: {
                        HStack(spacing: 9) {
                            Image(
                                systemName: folder.id == destinationID
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                folder.id == destinationID ? Color.blue : Color.secondary
                            )
                            Image(systemName: "folder.fill")
                                .foregroundStyle(
                                    folder.id == destinationID ? Color.blue : Color.secondary
                                )
                            Text(folder.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder.name)
                            Spacer()
                            Text(
                                folder.id == destinationID
                                    ? "Keep"
                                    : "Merge into selected folder"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            folder.id == destinationID
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain).pointingHandCursor()
                    .accessibilityLabel("Keep \(folder.name) as the merged folder")
                    .accessibilityValue(
                        folder.id == destinationID ? "Selected" : "Not selected"
                    )
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            Label(
                "Every item is moved into “\(destination?.name ?? "the destination")”. A source folder is moved to PikPak Trash only after a fresh check confirms it is empty. Same-named items are kept as separate PikPak items.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Merge Folders", role: .destructive) {
                    onMerge(destinationID)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || folders.count < 2)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct FinderDuplicateResultsPresentation: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var activity: FinderTaskActivityStore

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $activity.showsDuplicateResults, onDismiss: model.crossDriveDuplicateResultsDidDismiss) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Duplicate Results").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Done") { activity.showsDuplicateResults = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    DuplicateResultsView(model: model)
                }
                .padding(18)
                .frame(minWidth: 800, idealWidth: 940, maxWidth: 1100, minHeight: 480, idealHeight: 640, maxHeight: 820)
                .background(Color(nsColor: .windowBackgroundColor))
                .tint(FinderAppearance.accent)
            }
            .sheet(isPresented: $model.showsCrossDriveDuplicateScope, onDismiss: model.crossDriveDuplicateScopeDidDismiss) {
                CrossDriveDuplicateScopeView(model: model)
            }
    }
}

private struct DuplicateResultsView: View {
    @ObservedObject var model: DownloaderModel
    @State private var isDeleteConfirmationPresented = false
    @State private var resultPage = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("Exact matches compare content IDs and file size. Disk copies are kept; recommended selections prefer PikPak copies in newer folders.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isPreparingDuplicateResults {
                ProgressView("Preparing duplicate results…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scan = model.duplicateScan {
                scanSummary(scan)
                if scan.failedFolders > 0 {
                    partialScanNotice(scan)
                }
                if scan.groups.isEmpty {
                    noDuplicates(scan)
                } else {
                    results(scan)
                }
            } else {
                Text("These results are no longer current. Choose File → Check Duplicates Across Drives… to scan again.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.duplicateResultsIndex.id) { _ in resultPage = 0 }
        .alert("Move Selected Duplicates to Trash?", isPresented: $isDeleteConfirmationPresented) {
            Button("Move to Trash", role: .destructive) {
                model.deleteSelectedDuplicates()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                "\(model.selectedDuplicateFileIDs.count) selected file(s) "
                    + "(\(formatBytes(model.selectedDuplicateBytes))) will be moved to PikPak Trash. "
                    + "One copy is kept in every group, and trashed files can be restored from an official PikPak client until Trash is emptied."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(FinderAppearance.accent.opacity(0.12))
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Scanned Locations")
                    .font(.title3.weight(.semibold))
                Text(
                    model.duplicateScan?.rootPath
                        ?? (model.isScanningDuplicates
                            ? model.duplicateScanRootPath
                            : model.currentBrowserPath)
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Change Drives…") { model.presentCrossDriveDuplicateScope(reusingScan: true) }
                .disabled(!model.canScanCurrentFolderForDuplicates)

            if model.isDeletingDuplicates {
                ProgressView().controlSize(.small)
                Text("Moving to Trash…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .appCard(padding: 13)
    }

    private func scanSummary(_ scan: DuplicateScan) -> some View {
        HStack(spacing: 12) {
            summaryTile(
                title: "Exact groups",
                value: scan.exactGroups.formatted(),
                systemImage: "checkmark.seal.fill",
                color: .green
            )
            summaryTile(
                title: "Possible groups",
                value: scan.possibleGroups.formatted(),
                systemImage: "questionmark.diamond.fill",
                color: .orange
            )
            summaryTile(
                title: "Files in groups",
                value: scan.duplicateFiles.formatted(),
                systemImage: "doc.on.doc.fill",
                color: .blue
            )
            summaryTile(
                title: "Exact reclaimable",
                value: formatBytes(scan.reclaimableBytes),
                systemImage: "internaldrive.fill",
                color: .purple
            )
        }
    }

    private func partialScanNotice(_ scan: DuplicateScan) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Partial scan — previous progress was preserved")
                    .font(.callout.weight(.semibold))
                Text(
                    "\(scan.failedFolders.formatted()) location(s) could not be read. Results cover the files successfully checked on the selected drives."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }

    private func results(_ scan: DuplicateScan) -> some View {
        let page = ResultPage(total: model.duplicateResultsIndex.fileCount, requestedPage: resultPage)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.selectedDuplicateFileIDs.count.formatted()) selected")
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(formatBytes(model.selectedDuplicateBytes)) will be reclaimed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Select Recommended") {
                    model.selectRecommendedDuplicates()
                }
                .disabled(model.isRunning || scan.exactGroups == 0)
                .help("Keep disk copies and older PikPak folders; select redundant PikPak copies")

                Button("Clear Selection") {
                    model.clearDuplicateSelection()
                }
                .disabled(model.isRunning || model.selectedDuplicateFileIDs.isEmpty)

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Move All Selected to Trash", systemImage: "trash.fill")
                }
                .buttonStyle(.borderedProminent).pointingHandCursor()
                .tint(.red)
                .disabled(!model.canDeleteSelectedDuplicates)
            }
            .padding(13)

            Divider()

            List {
                ForEach(model.duplicateResultsIndex.slices(for: page)) { slice in
                    Section {
                        ForEach(slice.group.files[slice.range]) { file in
                            duplicateFileRow(file, in: slice.group)
                        }
                    } header: {
                        duplicateGroupHeader(slice.group)
                            .padding(.vertical, 5)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            if page.count > 1 {
                ResultPageControls(page: page, selection: $resultPage).padding(12)
                Divider()
            }

            HStack(spacing: 8) {
                Image(systemName: scan.possibleGroups > 0 ? "info.circle.fill" : "checkmark.shield.fill")
                    .foregroundStyle(scan.possibleGroups > 0 ? Color.orange : Color.green)
                Text(
                    scan.possibleGroups > 0
                        ? "Exact redundant copies are preselected. Possible name-and-size matches stay unselected until you review them."
                        : "Every exact group keeps one unselected copy; only redundant copies are preselected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Text(
                    "\(scan.scannedFiles.formatted()) files checked in \(scan.scannedFolders.formatted()) folders"
                        + (scan.failedFolders > 0
                            ? " • \(scan.failedFolders.formatted()) unavailable"
                            : "")
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .appCard(padding: 0)
    }

    private func noDuplicates(_ scan: DuplicateScan) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.11))
                Image(systemName: "checkmark")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.green)
            }
            .frame(width: 66, height: 66)
            Text(scan.failedFolders > 0 ? "No duplicates found in scanned folders" : "No duplicate files found")
                .font(.title3.weight(.semibold))
            Text(
                "Checked \(scan.scannedFiles.formatted()) files in \(scan.scannedFolders.formatted()) folders."
                    + (scan.failedFolders > 0
                        ? " \(scan.failedFolders.formatted()) folder(s) were unavailable."
                        : "")
            )
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appCard(padding: 20)
    }

    private func summaryTile(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
    }

    private func duplicateGroupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: group.matchKind == .exactContent ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                .foregroundStyle(group.matchKind == .exactContent ? Color.green : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(group.matchKind.title)
                        .font(.headline)
                    Text("\(group.copies) copies")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(group.matchKind.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(group.size))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("\(selectedCount(in: group)) selected • \(formatBytes(group.reclaimableBytes)) extra")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func duplicateFileRow(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        Toggle(isOn: selectionBinding(for: file.id)) {
            HStack(spacing: 10) {
                Image(systemName: file.isLocal ? "externaldrive" : "cloud.fill")
                    .foregroundStyle(group.matchKind == .exactContent ? Color.green : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(file.name)
                    Text(file.isLocal ? file.path : "PikPak: \(file.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(selectionLabel(for: file, in: group))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(model.selectedDuplicateFileIDs.contains(file.id) ? Color.red : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        (model.selectedDuplicateFileIDs.contains(file.id) ? Color.red : Color.secondary)
                            .opacity(0.09),
                        in: Capsule()
                    )
                Text(formatBytes(file.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(model.isRunning || file.isLocal)
        .padding(.vertical, 4)
    }

    private func selectionBinding(for fileID: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedDuplicateFileIDs.contains(fileID) },
            set: { model.setDuplicateFileSelected(fileID, selected: $0) }
        )
    }

    private func selectedCount(in group: DuplicateGroup) -> Int {
        model.selectedDuplicateCount(in: group.id)
    }

    private func selectionLabel(for file: DuplicateFile, in group: DuplicateGroup) -> String {
        if file.isLocal { return "Keep on Disk" }
        if model.selectedDuplicateFileIDs.contains(file.id) {
            return "Trash"
        }
        return group.matchKind == .exactContent ? "Keep" : "Review"
    }

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

/// SwiftUI's `onMoveCommand` does not consistently receive the AppKit
/// `moveUpAndModifySelection:` / `moveDownAndModifySelection:` selectors on
/// every supported macOS release. A window-local monitor makes Shift+Arrow
/// and Command+Delete reliable while leaving all unrelated key events alone.
