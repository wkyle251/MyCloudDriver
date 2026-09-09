import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

private enum PreviewResizeAxis {
    case horizontal
    case vertical
    case both
}

private enum BrowserViewMode: Int {
    case list
    case thumbnails
}

private enum BrowserItemZoom {
    static let minimum = 0.75
    static let maximum = 1.80
    static let step = 0.15
}

private enum BrowserWorkspaceLayout {
    static let folderMinimumWidth: CGFloat = 360
    static let previewMinimumWidth: CGFloat = 300
    static let splitDividerAllowance: CGFloat = 8

    static let splitMinimumWidth = folderMinimumWidth
        + previewMinimumWidth
        + splitDividerAllowance
}

private enum TransferWorkspaceLayout {
    /// Keeps the settings card and the complete four-metric dashboard visible
    /// as designed. The app window itself remains freely resizable; narrower
    /// windows scroll this workspace horizontally instead of clipping values.
    static let minimumWidth: CGFloat = 940
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
        .popover(isPresented: $activity.showsDetails, arrowEdge: .top) {
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
                .frame(maxHeight: activity.tasks.isEmpty ? 260 : 420)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
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
            .frame(width: activity.tasks.isEmpty ? 400 : 460)
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
        nsView.enforceMinimumSize()
        nsView.scheduleMinimumSizeReset()
    }
}

private final class WindowMinimumSizeControllerView: NSView {
    private weak var observedWindow: NSWindow?
    private var updateObserver: NSObjectProtocol?
    private var resetScheduled = false

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
        enforceMinimumSize()
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
        guard !resetScheduled else { return }
        resetScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resetScheduled = false
            self.enforceMinimumSize()
        }
    }

    private func attachToCurrentWindow() {
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
            self?.enforceMinimumSize()
        }

        enforceMinimumSize()
        scheduleMinimumSizeReset()
    }

    deinit {
        if let updateObserver {
            NotificationCenter.default.removeObserver(updateObserver)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: DownloaderModel
    @EnvironmentObject private var finderSettings: FinderSettings
    @State private var advancedExpanded = false
    @State private var activityExpanded = false
    @StateObject private var workspaceNavigation = FinderWorkspaceNavigation()
    init(navigation: FinderWorkspaceNavigation? = nil) {
        _workspaceNavigation = StateObject(wrappedValue: navigation ?? FinderWorkspaceNavigation())
    }
    private var selectedTab: Int {
        get { workspaceNavigation.section }
        nonmutating set { workspaceNavigation.showImmediately(newValue) }
    }
    @AppStorage("selectedTransferMode") private var selectedTransferMode = 0
    @AppStorage("browserViewMode") private var browserViewModeRaw = BrowserViewMode.list.rawValue
    @AppStorage("linksViewMode") private var linksViewModeRaw = BrowserViewMode.list.rawValue
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
    @State private var isChoosingUploadDestination = false
    @AppStorage("previewCanvasWidth") private var previewCanvasWidth = 720.0
    @AppStorage("previewCanvasHeight") private var previewCanvasHeight = 440.0
    @State private var previewResizeStartSize: CGSize?
    @State private var livePreviewCanvasSize: CGSize?
    @State private var isPreviewResizeHovered = false
    @FocusState private var browserListFocused: Bool

    #if HEADER_LAYOUT_TESTS
    // Legacy layout harness now exercises the replacement sidebar.
    var body: some View {
        FinderSidebarLayout(automaticallyHidden: finderSettings.autoHideSidebar) {
            finderSidebar
        } workspace: { Text("Offline workspace").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    #else
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            FinderSidebarLayout(automaticallyHidden: finderSettings.autoHideSidebar) {
                finderSidebar
            } workspace: {
              VStack(alignment: .leading, spacing: 8) {
                GeometryReader { workspace in
                    Group {
                        if selectedTab == 0 {
                            cloudBrowser
                        } else if selectedTab == 1 {
                            downloader
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

                workspaceFooter
            }
              .padding(10)
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
        #if WORKSPACE_SWITCH_PROFILING
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PikPakSwitchBenchmark"))) { note in
            if let section = note.object as? Int { selectFinderSection(section) }
        }
        #endif
        .disabled(model.isChangingAccount)
        .onChange(of: model.activeAccountID) { _ in
            selectedTab = 0
            isChoosingUploadDestination = false
            isBrowserTrashConfirmationPresented = false; pendingTrashItems = []
            isEmptyFolderConfirmationPresented = false; pendingEmptyFolderScope = nil
            isDSStoreConfirmationPresented = false; pendingDSStoreScope = nil
            mergeFoldersRequest = nil; pendingNewFolderParent = nil; isNewFolderPresented = false
            pendingRenameItem = nil; editSharedLinkRequest = nil
        }
        .onDisappear { workspaceNavigation.cancel() }
        .background {
            WindowMinimumSizeController()
                .frame(width: 0, height: 0)
        }
        .onAppear {
            browserViewModeRaw = BrowserViewMode(rawValue: browserViewModeRaw)?.rawValue
                ?? BrowserViewMode.list.rawValue
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
            model.loadBrowserIfReady()
        }
        // Leaving this drive must not cancel transfers. AppDelegate owns shutdown.
        .onDisappear { _ = model.cancelQuickLook(); model.previewPlayer?.pause() }
        .sheet(isPresented: Binding(get: { model.isLoginPresented && !model.loginFromSettings }, set: {
            if !$0 && model.isLoginPresented && !model.loginFromSettings { model.cancelLogin() }
        })) {
            PikPakLoginView(
                reason: model.loginReason,
                currentDeviceID: model.loginDeviceID,
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
                model.trashSelectedBrowserItems()
                pendingTrashItems = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingTrashItems = []
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 29, height: 29)
                Text("MyCloudDriver").font(.headline)
            }
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 16)

            Text("WORKSPACES").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).padding(.horizontal, 12)
            ForEach(FinderWorkspaceSection.allCases) { section in
                FinderWorkspaceSidebarTab(loading: workspaceNavigation.loading, title: section.title, symbol: section.symbol,
                    section: section.rawValue, currentSection: selectedTab) {
                    selectFinderSection(section.rawValue)
                }
            }
            Divider().padding(.vertical, 8)
            FinderSettingsButton()
                .buttonStyle(.plain).pointingHandCursor()
                .help("Settings · Command-Comma")
            Spacer(minLength: 12)
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
                }
                .padding(12)
            }
            FinderAccountSettingsLink(settings: finderSettings) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sessionNeedsAttention ? "Sign In / Account" : "Account")
                        if hasStoredSession, !sessionNeedsAttention {
                            Text(model.accountDisplayName ?? "Signed in to PikPak")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                } icon: {
                    Image(systemName: "person.crop.circle").foregroundStyle(FinderAppearance.accent)
                }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .help([model.accountDisplayName, accountStateSubtitle].compactMap { $0 }.joined(separator: "\n"))
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FinderAppearance.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private func selectFinderSection(_ section: Int) {
        workspaceNavigation.select(section, needsLoading: model.workspaceSwitchNeedsLoading(to: section)) {
            prepareBrowserSource(for: section)
        }
    }

    private var finderWindowActions: FinderWindowActions {
        let fileWorkspace = selectedTab == 0 || selectedTab == 3
        let maintenanceAllowed = selectedTab == 0 && !workspaceNavigation.isSwitching && !isChoosingUploadDestination
        return FinderWindowActions(section: selectedTab, viewMode: browserViewMode.rawValue,
            zoom: browserItemZoom,
            undoTitle: model.fileUndoHistory.undoTitle, redoTitle: model.fileUndoHistory.redoTitle,
            canUndo: !workspaceNavigation.isSwitching && !isChoosingUploadDestination && model.canUndoFileAction,
            canRedo: !workspaceNavigation.isSwitching && !isChoosingUploadDestination && model.canRedoFileAction,
            undo: { model.performFileUndo(redo: false) }, redo: { model.performFileUndo(redo: true) },
            canRefresh: fileWorkspace && model.canBrowse,
            canGoBack: fileWorkspace && model.canGoBack,
            canUpload: fileWorkspace && selectedTab == 0 && model.canUploadFiles && !isChoosingUploadDestination,
            canDownload: fileWorkspace && model.canDownloadSelectedBrowserItem && !isChoosingUploadDestination,
            canCreateFolder: fileWorkspace && selectedTab == 0 && model.canCreateFolder && !isChoosingUploadDestination,
            canTrash: fileWorkspace && selectedTab == 0 && model.canTrashSelectedBrowserItem && !isChoosingUploadDestination,
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
            findSimilarFiles: { model.fileSimilarity.present() },
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
            trash: { if !workspaceNavigation.isSwitching { requestTrashForBrowserSelection() } })
    }

    private func setFinderViewMode(_ value: Int) {
        guard !workspaceNavigation.isSwitching else { return }
        if model.isBrowsingSharedLink { linksViewModeRaw = value }
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
            let fileWorkspace = selectedTab == 0 || selectedTab == 3
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
                    openActivity: model.log.isEmpty ? nil : showActivityLog
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

                if !model.log.isEmpty {
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
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace footer")
    }

    private func showActivityLog() {
        selectedTab = 1
        activityExpanded = true
    }

    private var compactBrowserSelectionSummary: String {
        let count = model.browserActionSelectionCount
        if count > 0 { return "\(count.formatted()) selected" }
        if model.isBrowsingSharedLink { return "\(model.sharedLinks.count.formatted()) links" }
        return "\(model.visibleBrowserItemCount.formatted()) shown"
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


    private func quotaUsageColor(for fraction: Double) -> Color {
        if fraction >= 0.95 { return .red }
        if fraction >= 0.8 { return .orange }
        return Color(red: 0.96, green: 0.72, blue: 0.28)
    }


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
            if isChoosingUploadDestination {
                uploadDestinationChooserBar
                    .appCard(padding: 10)
            }

            if !model.isBrowsingSharedLink && !hasStoredSession {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 72, height: 72)
                    Text("Your cloud files are one sign-in away")
                        .font(.title3.weight(.semibold))
                    Text("PikPak opens temporarily to create a desktop session used only by this app.")
                        .foregroundStyle(.secondary)
                    Button("Sign In to PikPak…") {
                        model.signIn()
                    }
                    .buttonStyle(.borderedProminent).pointingHandCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appCard(padding: 24)
            } else {
                GeometryReader { viewport in
                    let requiredWidth = !finderSettings.showsPreviewPane
                        ? BrowserWorkspaceLayout.folderMinimumWidth
                        : isPreviewExpanded && model.selectedBrowserItem != nil
                        ? BrowserWorkspaceLayout.previewMinimumWidth
                        : BrowserWorkspaceLayout.splitMinimumWidth
                    let workspaceWidth = max(viewport.size.width, requiredWidth)

                    ScrollView(.horizontal) {
                        Group {
                            if !finderSettings.showsPreviewPane {
                                browserContent
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(nsColor: .controlBackgroundColor))
                            } else if isPreviewExpanded, model.selectedBrowserItem != nil {
                                previewPane
                                    .frame(
                                        minWidth: BrowserWorkspaceLayout.previewMinimumWidth,
                                        maxWidth: .infinity,
                                        maxHeight: .infinity
                                    )
                                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                            } else {
                                HSplitView {
                                    browserContent
                                        .frame(
                                            minWidth: BrowserWorkspaceLayout.folderMinimumWidth,
                                            idealWidth: 650,
                                            maxWidth: .infinity
                                        )
                                        .background(Color(nsColor: .controlBackgroundColor))
                                    previewPane
                                        .frame(
                                            minWidth: BrowserWorkspaceLayout.previewMinimumWidth,
                                            idealWidth: 340,
                                            maxWidth: .infinity
                                        )
                                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                                }
                            }
                        }
                        .frame(
                            width: workspaceWidth,
                            height: viewport.size.height,
                            alignment: .topLeading
                        )
                    }
                    .scrollIndicators(.automatic)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.055), radius: 12, y: 4)
                .onChange(of: model.selectedBrowserItemID) { selectedID in
                    if selectedID == nil {
                        isPreviewExpanded = false
                    }
                }
            }
        }
    }

    private var uploadDestinationCandidate: BrowserLocation {
        if let item = model.selectedBrowserItem, item.isFolder {
            return model.browserLocation(for: item)
        }
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
        isChoosingUploadDestination = true
        selectedTab = 0
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            if let progress = model.browserFolderExpansionProgress {
                BrowserFolderExpansionBar(progress: progress) {
                    model.cancelBrowserFolderExpansion()
                }
                Divider()
            }
            if browserViewMode == .thumbnails {
                if model.isBrowsingSharedLink { sharedLinkThumbnailGrid }
                else { browserThumbnailGrid }
            } else {
                browserList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.isBrowsingSharedLink, browserViewMode == .list,
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
        let adjusted = min(
            max(browserItemZoom + delta, BrowserItemZoom.minimum),
            BrowserItemZoom.maximum
        )
        withAnimation(.easeOut(duration: 0.14)) {
            setBrowserItemZoom((adjusted * 100).rounded() / 100)
        }
    }

    private func resetBrowserZoom() {
        guard !workspaceNavigation.isSwitching else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            setBrowserItemZoom(1)
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
        HStack(spacing: 9) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
            }
            .help("Back")
            .disabled(!model.canGoBack)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.blue.opacity(0.1))
                Image(systemName: model.isBrowsingSharedLink ? "link" : "folder.fill")
                    .foregroundStyle(.blue)
            }
            .frame(width: 30, height: 30)
            .browserDropCanvas(
                model: model,
                destination: model.browserStack.last,
                compact: true
            ) {
                selectedTransferMode = 1
                selectedTab = 1
            }
            .help("Current folder; drop Finder files to upload, or PikPak items to move here")

            browserBreadcrumb
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if !model.isBrowsingSharedLink {
                Picker("Browser view", selection: $browserViewModeRaw) {
                    Image(systemName: "list.bullet")
                        .accessibilityLabel("List")
                        .tag(BrowserViewMode.list.rawValue)
                    Image(systemName: "square.grid.3x3.fill")
                        .accessibilityLabel("Thumbnails")
                        .tag(BrowserViewMode.thumbnails.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help("Switch between List and Thumbnails")
            }

            Menu {
                Button("Make Items Larger") {
                    adjustBrowserZoom(by: BrowserItemZoom.step)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(browserItemZoom >= BrowserItemZoom.maximum)

                Button("Make Items Smaller") {
                    adjustBrowserZoom(by: -BrowserItemZoom.step)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(browserItemZoom <= BrowserItemZoom.minimum)

                Divider()

                Button("Actual Size") {
                    resetBrowserZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(abs(browserItemZoom - 1) < 0.001)

                Text(
                    "\(zoomedBrowserViewMode == .thumbnails ? "Thumbnails" : "List") "
                        + "item size: \(browserZoomPercent)%"
                )
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Item size: \(browserZoomPercent)% (Command-Plus / Command-Minus)")

            Text(browserSelectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())

            if model.isScanningDuplicates {
                Button {
                    model.cancelDuplicateScan()
                } label: {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Stop checking this folder for duplicate files")
            }

            if !model.isBrowsingSharedLink {
                Button {
                    if model.chooseFilesToUploadInCurrentBrowserFolder() {
                        selectedTransferMode = 1
                        selectedTab = 1
                    }
                } label: {
                    Label("Upload", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
                .disabled(!model.canUploadFiles || isChoosingUploadDestination)
                .help("Choose local files or folders to upload into \(model.currentBrowserPath)")
            }

            if model.isBrowsingSharedLink {
                Button {
                    model.saveSelectedSharedItems()
                } label: {
                    if model.isSavingSelectedSharedSelection {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving…")
                        }
                    } else if model.isSelectedSharedSelectionSaved {
                        Label(
                            "Saved to My PikPak",
                            systemImage: "checkmark.circle.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                    } else {
                        Label(
                            model.browserActionSelectionCount > 1
                                ? "Save \(model.browserActionSelectionCount) Items to My PikPak"
                                : "Save to My PikPak",
                            systemImage: "square.and.arrow.down.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                    }
                }
                .disabled(!model.canSaveSharedSelection)
                .help("Save the selected shared files or folders to Pack From Shared in My PikPak")
                .fixedSize()
                .layoutPriority(4)
            }

            Button {
                model.downloadSelectedBrowserItem()
                selectedTransferMode = 0
                selectedTab = 1
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent).pointingHandCursor()
            .disabled(!model.canDownloadSelectedBrowserItem || isChoosingUploadDestination)
            .help("Add the selected file or folder to the download queue")

            if !model.isBrowsingSharedLink {
                Button(role: .destructive) {
                    requestTrashForBrowserSelection()
                } label: {
                    Label("Trash", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canTrashSelectedBrowserItem || isChoosingUploadDestination)
                .help("Move selected items to PikPak Trash (Command-Delete)")
                .accessibilityLabel("Move Selected Items to Trash")

                Button {
                    requestNewFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 22, height: 22)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canCreateFolder || isChoosingUploadDestination)
                .help("Create a folder in the current PikPak folder")
                .accessibilityLabel("New Folder")
            }

            if model.hasMoreBrowserItems {
                Button("Load More") {
                    model.loadMoreBrowserItems()
                }
                .disabled(!model.canBrowse)
            }

            Button {
                model.refreshBrowser()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .help("Refresh folder")
            .disabled(!model.canBrowse)
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
        let entries = model.browserTreeEntries
        let hasOutlineRows = model.isBrowsingSharedLink
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
                                .frame(width: columns.tableWidth, alignment: .center)
                                .frame(maxHeight: .infinity, alignment: .center)
                            } else {
                                ScrollView(.vertical) {
                                    ZStack(alignment: .topLeading) {
                                        browserBlankSelectionTarget

                                        Group {
                                            if model.isBrowsingSharedLink {
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
                // Identity resets the scroll offset, which the account Browser
                // wants when it navigates into a different folder. The Links
                // outline renders every link at once, so making the active
                // link or its restored `browserStack` part of this identity
                // tore the whole scroll view down — and with it the scroll
                // position and keyboard focus — merely for expanding a folder
                // under a link that was not the active one.
                .id(
                    model.isBrowsingSharedLink
                        ? "shared-links"
                        : "account|\(model.currentBrowserPath)"
                )
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
                    model.isBrowsingSharedLink
                        ? "Each top-level URL is an expandable shared-link root. Its files and folders appear directly beneath it."
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
                        ownsQuickLookPanel: model.ownsQuickLookPanel
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
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                browserTreeRow(
                    entry,
                    rowIndex: index,
                    columns: columns,
                    actionSelectionCount: actionSelectionCount
                )
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
                    isExpanded: sharedLinkIsExpanded(link),
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
                    onToggle: {
                        toggleSharedLinkRoot(link)
                    },
                    onMeasure: {
                        model.setSharedLinkExpanded(link.id, expanded: true)
                        model.measureSharedLink(link.id)
                    },
                    onEditLink: {
                        beginSharedLinkEdit(link)
                    },
                    onCopyLink: {
                        model.copySharedLinkURL(link.id)
                    },
                    onRetry: {
                        model.setSharedLinkExpanded(link.id, expanded: true)
                        model.retrySharedLink(link.id)
                    },
                    onDisconnect: {
                        model.removeSharedLink(link.id)
                    }
                )
                .id("shared-link-\(link.id.uuidString)")

                if sharedLinkIsExpanded(link) {
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
    /// expanded link roots or borrowing the active link's metadata/selection.
    private var sharedLinkThumbnailGrid: some View {
        GeometryReader { viewport in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    browserBlankSelectionTarget
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedSharedLinks) { link in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Button { toggleSharedLinkRoot(link) } label: {
                                        Image(systemName: sharedLinkIsExpanded(link) ? "chevron.down" : "chevron.right")
                                    }
                                    .buttonStyle(.borderless).pointingHandCursor()
                                    .accessibilityLabel(sharedLinkIsExpanded(link) ? "Collapse link" : "Expand link")
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
                                if sharedLinkIsExpanded(link) {
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
    }

    private var sortedSharedLinks: [SharedLinkEntry] { model.sortedSharedLinks }

    private func sharedLinkIsExpanded(_ entry: SharedLinkEntry) -> Bool {
        model.isSharedLinkExpanded(entry.id)
    }

    private func activateSharedLinkRoot(_ entry: SharedLinkEntry) {
        model.setSharedLinkExpanded(entry.id, expanded: true)
        model.selectSharedLinkRoot(entry.id)
    }

    private func toggleSharedLinkRoot(_ entry: SharedLinkEntry) {
        switch entry.state {
        case .loading:
            return
        case .failed:
            model.setSharedLinkExpanded(entry.id, expanded: true)
            model.retrySharedLink(entry.id)
        case .ready:
            if model.isSharedLinkExpanded(entry.id) {
                model.setSharedLinkExpanded(entry.id, expanded: false)
            } else {
                model.setSharedLinkExpanded(entry.id, expanded: true)
                model.activateSharedLink(entry.id)
            }
        }
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
        let items = model.browserItems
        let scale = browserZoomScale
        return ScrollViewReader { scrollProxy in
            ZStack {
                if items.isEmpty && !model.isBrowserLoading {
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
                                            actionSelectionCount: actionSelectionCount
                                        )
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
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if model.hasMoreBrowserItems
                                || (model.isBrowserLoading && !items.isEmpty) {
                                browserThumbnailPaginationFooter
                            }
                        }
                        .id("thumbnails-\(model.currentBrowserPath)")
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
                                scrollProxy.scrollTo(selected, anchor: .center)
                            }
                        }
                        .task(id: model.browserScrollRestoreRequest?.id) {
                            guard let request = model.browserScrollRestoreRequest else { return }
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            guard
                                !Task.isCancelled,
                                model.browserScrollRestoreRequest?.id == request.id
                            else { return }
                            scrollProxy.scrollTo(request.itemID, anchor: .center)
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
                                ownsQuickLookPanel: model.ownsQuickLookPanel
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
                    Label("Load Next 200", systemImage: "ellipsis.circle")
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
                selectBrowserItem(item, visibleItems: sharedLinkID == nil ? model.browserItems : model.browserTreeEntries.map(\.item))
            },
            onToggleSelection: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                browserListFocused = true
                model.toggleBrowserCheckbox(item)
            },
            onActivate: {
                guard activateSharedLinkContext(sharedLinkID) else { return }
                activateBrowserItem(item)
            }
        )
        .accessibilityHint(
            item.isFolder
                ? "Use the checkbox to include this folder and all its contents. Double-click or press Return to open it."
                : "Use the checkbox to add this file to the selection. Double-click to preview it."
        )
        .contextMenu {
            if !item.isFolder {
                browserFileOpenMenu(item, sharedLinkID: sharedLinkID)
            }
            if item.isFolder {
                BrowserFolderExpansionMenu { levels in
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    expandBrowserSubfolders(item, levels: levels)
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

                    if model.isBrowserItemSelected(item.id),
                       model.selectedFoldersForMerge.count >= 2 {
                        Button {
                            requestMergeSelectedFolders(preferredDestination: item)
                        } label: {
                            BrowserContextMenuStyle.label(
                                "Merge \(model.selectedFoldersForMerge.count.formatted()) Folders…",
                                systemImage: "arrow.triangle.merge"
                            )
                        }
                        .disabled(!model.canMergeSelectedFolders)
                    }
                }

                Button {
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    model.measureFolder(item)
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
        sharedLinkID: UUID? = nil
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
                guard activateSharedLinkContext(sharedLinkID) else { return }
                model.measureFolder(item)
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
        .contextMenu {
            if !item.isFolder {
                browserFileOpenMenu(item, sharedLinkID: sharedLinkID)
            }
            if item.isFolder {
                BrowserFolderExpansionMenu { levels in
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    expandBrowserSubfolders(item, levels: levels)
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

                    if model.isBrowserItemSelected(item.id),
                       model.selectedFoldersForMerge.count >= 2 {
                        Button {
                            requestMergeSelectedFolders(preferredDestination: item)
                        } label: {
                            BrowserContextMenuStyle.label(
                                "Merge \(model.selectedFoldersForMerge.count.formatted()) Folders…",
                                systemImage: "arrow.triangle.merge"
                            )
                        }
                        .disabled(!model.canMergeSelectedFolders)
                    }
                }

                Button {
                    guard activateSharedLinkContext(sharedLinkID) else { return }
                    model.measureFolder(item)
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
            visibleItems: model.browserItems
        ) else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            scrollProxy.scrollTo(targetID, anchor: .center)
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
            VStack(alignment: .leading, spacing: 12) {
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

                previewSurface(for: item)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !item.isFolder,
                           model.previewFileID == item.id,
                           let previewError = model.previewPlaybackError {
                            previewFailureSection(for: item, message: previewError)
                        }

                        if !item.isFolder,
                           (item.mediaKind == .video || item.mediaKind == .audio),
                           model.previewFileID == item.id {
                            previewStreamingPanel(for: item)
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
                                            model.previewFileID == item.id ? "Reload Preview" : "Load Preview",
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
                                            Label("Open in \(playerName)", systemImage: "play.rectangle.on.rectangle")
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
                                } else {
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
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.automatic)
            }
            .padding(16)
        } else {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.08))
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 34))
                        .foregroundStyle(.blue.opacity(0.8))
                }
                .frame(width: 74, height: 74)
                Text("Select a file or folder")
                    .font(.title3.weight(.semibold))
                Text("Use ↑ or ↓ to select files and folders. Press Return to open a folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    model.previewStreamingState.title,
                    systemImage: model.previewStreamingState.systemImage
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(previewStreamingStateColor)

                if let sourceLabel = model.previewSourceLabel {
                    Text(sourceLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                }

                if model.previewStreamingState == .paused {
                    Text("Buffering continues")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.09), in: Capsule())
                }

                Spacer(minLength: 4)

                if model.previewStreamingState == .compatibility {
                    Text(model.previewCompatibilityPlayerName ?? "Compatibility player")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(
                            model.previewStreamedBytes > 0
                                ? model.previewUsesRetainedCache
                                    ? "\(formatBytes(model.previewRetainedBytes)) retained"
                                    : "\(formatBytes(model.previewStreamedBytes)) streamed"
                                : "Waiting for media data"
                        )
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        if model.previewTransferBytesPerSecond > 0 {
                            Text("\(formatByteRate(model.previewTransferBytesPerSecond)) now")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if model.previewStreamedBytes > 0 {
                            Text("No network activity")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.previewStreamingState == .compatibility {
                Text(
                    "PikPak supplied only the original AVI. Open the secure, temporary stream in IINA for legacy AVI codec support; the file is not saved to Downloads."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if model.previewUsesRetainedCache {
                    previewSegmentedRow(
                        title: "Retained buffer",
                        systemImage: "icloud.and.arrow.down",
                        segments: model.previewRetainedSegments,
                        detail: previewBufferDetail,
                        color: .cyan
                    )
                } else {
                    previewProgressRow(
                        title: "Available buffer",
                        systemImage: "icloud.and.arrow.down",
                        fraction: model.previewBufferedFraction,
                        detail: previewBufferDetail,
                        color: .cyan
                    )
                }

                previewProgressRow(
                    title: "Playback",
                    systemImage: "play.fill",
                    fraction: model.previewPlaybackFraction,
                    detail: previewPlaybackDetail,
                    color: .blue
                )

                Text(
                    model.previewUsesRetainedCache
                        ? "Background buffering continues when playback is paused. Each cyan segment is a byte range actually held, drawn where it sits in the file — a gap is a range not retained, and a segment at the right edge is usually the movie header AVPlayer fetched first. Seeking backward into a segment reuses it; segments are cleared only when another file is previewed. Optimized streams can be smaller than the original \(formatBytes(item.size)) file."
                        : "Buffering continues when playback is paused. Available buffer combines the timeline ranges AVPlayer currently reports as ready. HLS may replace those ranges while seeking."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.07), Color.blue.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
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

    /// Draws each retained span where it actually sits in the file. A single
    /// left-anchored bar cannot do this: AVFoundation often holds a movie
    /// header at the very end before any media at the start, which the old
    /// bar rendered as though it were at the beginning.
    private func previewSegmentedRow(
        title: String,
        systemImage: String,
        segments: [PreviewBufferSegment],
        detail: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 102, alignment: .leading)

            GeometryReader { geometry in
                let width = max(geometry.size.width, 0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    ForEach(segments) { segment in
                        Capsule()
                            .fill(color)
                            // Keep a hairline visible so a tiny retained span
                            // (a header of a few KB) does not vanish entirely.
                            .frame(width: max(segment.width * width, 2))
                            .offset(x: segment.start * width)
                    }
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            .accessibilityLabel(title)
            .accessibilityValue(detail)

            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 145, alignment: .trailing)
        }
    }

    private func previewProgressRow(
        title: String,
        systemImage: String,
        fraction: Double?,
        detail: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 102, alignment: .leading)

            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(color)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(color)
            }

            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 145, alignment: .trailing)
        }
    }

    private var previewBufferDetail: String {
        if model.previewUsesRetainedCache {
            guard model.previewRetainedBytes > 0 else { return "Starting…" }
            guard let fraction = model.previewBufferedFraction else {
                return formatBytes(model.previewRetainedBytes)
            }
            return "\(Int((fraction * 100).rounded()))% • \(formatBytes(model.previewRetainedBytes))"
        }
        guard let fraction = model.previewBufferedFraction else {
            return model.previewBufferedSeconds > 0
                ? formatMediaTime(model.previewBufferedSeconds)
                : "Starting…"
        }
        return "\(Int((fraction * 100).rounded()))% • \(formatMediaTime(model.previewBufferedSeconds))"
    }

    private var previewPlaybackDetail: String {
        let current = formatMediaTime(model.previewPlaybackSeconds)
        guard model.previewDurationSeconds > 0 else { return current }
        return "\(current) / \(formatMediaTime(model.previewDurationSeconds))"
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
        let seconds = Int(interval.rounded(.down))
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
        let bounded = UInt64(min(bytesPerSecond, Double(UInt64.max)).rounded())
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
    private func previewSurface(for item: BrowserItem) -> some View {
        GeometryReader { geometry in
            let canvasSize = effectivePreviewCanvasSize(availableWidth: geometry.size.width)
            previewCanvas(for: item)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .separatorColor)
                                .opacity(isPreviewResizeHovered ? 0.72 : 0.42),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .trailing) {
                    previewResizeEdge(axis: .horizontal, canvasSize: canvasSize)
                        .frame(width: 10)
                        .offset(x: 5)
                }
                .overlay(alignment: .bottom) {
                    previewResizeEdge(axis: .vertical, canvasSize: canvasSize)
                        .frame(height: 10)
                        .offset(y: 5)
                }
                .overlay(alignment: .bottomTrailing) {
                    previewResizeCorner(canvasSize: canvasSize)
                        .offset(x: 5, y: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: effectivePreviewHeight)
        .padding(.trailing, 5)
        .padding(.bottom, 5)
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
                    fit: true
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
                      let player = model.previewPlayer {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RemoteArtwork(
                    url: item.artworkURL,
                    systemName: previewSymbol(for: item),
                    fit: true
                )
                .padding(8)
            }

            if !item.isFolder,
               (item.mediaKind == .video || item.mediaKind == .audio),
               model.previewFileID == item.id,
               model.isPreviewLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading \(item.mediaKind == .audio ? "audio" : "video") preview…")
                        .font(.callout.weight(.semibold))
                    if let sourceLabel = model.previewSourceLabel {
                        Text(sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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

    private var effectivePreviewHeight: CGFloat {
        let liveHeight = livePreviewCanvasSize.map { Double($0.height) }
        let configured = liveHeight
            ?? (previewCanvasHeight.isFinite ? previewCanvasHeight : 440)
        return CGFloat(max(configured, 180))
    }

    private func effectivePreviewCanvasSize(availableWidth: CGFloat) -> CGSize {
        let maximumWidth = max(availableWidth - 5, 1)
        let liveWidth = livePreviewCanvasSize?.width
        let configuredWidth = liveWidth
            ?? (previewCanvasWidth.isFinite ? CGFloat(previewCanvasWidth) : maximumWidth)
        return CGSize(
            width: min(max(configuredWidth, 1), maximumWidth),
            height: effectivePreviewHeight
        )
    }

    private func previewResizeEdge(
        axis: PreviewResizeAxis,
        canvasSize: CGSize
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isPreviewResizeHovered = hovering
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(previewResizeGesture(axis: axis, canvasSize: canvasSize))
            .help(axis == .horizontal ? "Drag to resize preview width" : "Drag to resize preview height")
    }

    private func previewResizeCorner(canvasSize: CGSize) -> some View {
        Canvas { context, size in
            var path = Path()
            for inset in stride(from: CGFloat(4), through: 12, by: 4) {
                path.move(to: CGPoint(x: size.width - inset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - inset))
            }
            context.stroke(
                path,
                with: .color(
                    Color.secondary.opacity(isPreviewResizeHovered ? 0.8 : 0.48)
                ),
                lineWidth: 1
            )
        }
        .frame(width: 16, height: 16)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isPreviewResizeHovered = hovering
            (hovering ? NSCursor.crosshair : NSCursor.arrow).set()
        }
        .gesture(previewResizeGesture(axis: .both, canvasSize: canvasSize))
        .help("Drag to resize preview")
        .accessibilityLabel("Resize Preview")
        .accessibilityHint("Drag to change the preview width and height")
    }

    private func previewResizeGesture(
        axis: PreviewResizeAxis,
        canvasSize: CGSize
    ) -> some Gesture {
        // The handle moves as the preview changes size. Global translation
        // excludes that movement and prevents feedback under the pointer.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let startSize = previewResizeStartSize ?? canvasSize
                if previewResizeStartSize == nil { previewResizeStartSize = startSize }
                livePreviewCanvasSize = resizedPreviewCanvas(
                    from: startSize,
                    translation: value.translation,
                    axis: axis
                )
            }
            .onEnded { value in
                let startSize = previewResizeStartSize ?? canvasSize
                let finalSize = resizedPreviewCanvas(
                    from: startSize,
                    translation: value.translation,
                    axis: axis
                )
                if axis == .horizontal || axis == .both {
                    previewCanvasWidth = Double(finalSize.width)
                }
                if axis == .vertical || axis == .both {
                    previewCanvasHeight = Double(finalSize.height)
                }
                livePreviewCanvasSize = nil
                previewResizeStartSize = nil
                NSCursor.arrow.set()
            }
    }

    private func resizedPreviewCanvas(
        from startSize: CGSize,
        translation: CGSize,
        axis: PreviewResizeAxis
    ) -> CGSize {
        var result = startSize
        if axis == .horizontal || axis == .both {
            result.width = min(max(startSize.width + translation.width, 1), 1_600)
        }
        if axis == .vertical || axis == .both {
            result.height = max(startSize.height + translation.height, 180)
        }
        return result
    }

    private var downloader: some View {
        VStack(alignment: .leading, spacing: 12) {
            transferModeHeader
            GeometryReader { viewport in
                ScrollView(.horizontal) {
                    Group {
                        if selectedTransferMode == 0 {
                            downloadWorkspace
                        } else {
                            uploadWorkspace
                        }
                    }
                    .frame(
                        width: max(viewport.size.width, TransferWorkspaceLayout.minimumWidth),
                        height: viewport.size.height,
                        alignment: .topLeading
                    )
                }
                .scrollIndicators(.automatic)
            }
            activity
        }
    }

    private var transferModeHeader: some View {
        HStack(spacing: 12) {
            Picker("Transfer direction", selection: $selectedTransferMode) {
                Label("Downloads", systemImage: "arrow.down.circle.fill").tag(0)
                Label("Uploads", systemImage: "arrow.up.circle.fill").tag(1)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)

            Spacer()

            if selectedTransferMode == 1 {
                Label(
                    model.effectiveUploadDestination.path,
                    systemImage: "folder.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Upload destination")
            } else {
                Label(model.outputURL.path, systemImage: "externaldrive.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Download destination")
            }
        }
        .appCard(padding: 9)
    }

    private var downloadWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                downloadSettings
                    .frame(minWidth: 520, maxWidth: .infinity)
                downloadProgressDashboard
                    .frame(width: 400)
            }
            controls
                .appCard(padding: 11)
            if model.restoredDownloadQueue || model.interruptedDownloadCount > 0 {
                HStack(spacing: 10) {
                    Label("Unfinished downloads are saved across app restarts.", systemImage: "arrow.clockwise.circle")
                    Text("Resume uses existing partial files; completed files are skipped.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.interruptedDownloadCount > 0 {
                        Button("Return \(model.interruptedDownloadCount) Interrupted to Queue") {
                            model.requeueInterruptedDownloads()
                        }
                    }
                }
                .font(.caption)
                .appCard(padding: 11)
            }
            downloadTransferBoard
                .frame(minHeight: 260, maxHeight: .infinity)
        }
    }

    private var uploadWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                uploadSettings
                    .frame(minWidth: 520, maxWidth: .infinity)
                uploadProgressDashboard
                    .frame(width: 400)
            }
            uploadControls
                .appCard(padding: 11)
            if !model.resumableUploadBatches.isEmpty {
                savedUploadBatches
            }
            uploadTransferBoard
                .frame(minHeight: 260, maxHeight: .infinity)
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
            Label("Saved Uploads", systemImage: "arrow.clockwise.circle")
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
                            Button("Resume") { model.resumeSavedUpload(batch.id) }
                                .buttonStyle(.borderedProminent).pointingHandCursor()
                                .disabled(!model.canUploadFiles)
                            Button("Remove", role: .destructive) { model.discardSavedUpload(batch.id) }
                                .help("Forget this saved batch without deleting any local or cloud files")
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
        HStack {
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
                model.stopUpload()
            } label: {
                Label("Cancel Upload", systemImage: "stop.circle")
            }
            .disabled(!model.isUploading)

            if !model.failedUploadTransfers.isEmpty, !model.isUploading {
                Text("Use Retry on a failed file below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
        HStack(alignment: .top, spacing: 12) {
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
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
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
                    Text(uploadTransferStateTitle(transfer.state))
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
        case .retrying(let attempt, let maximum): return "Retry \(attempt) of \(maximum)"
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Download setup", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text("Select files in Browser or Links; manage the transfer here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Label("Save to", systemImage: "folder.fill")
                        .frame(width: 110, alignment: .trailing)
                    HStack {
                        Text(model.outputURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            model.chooseOutputFolder()
                        }
                        .disabled(model.isRunning || model.isDownloading)
                    }
                }
                GridRow {
                    Text("")
                    DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        HStack {
                            Text("Proxy")
                            TextField("Optional, e.g. http://127.0.0.1:7890", text: $model.proxyURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .appCard(padding: 14)
    }

    private var controls: some View {
        HStack {
            Button {
                selectedTab = model.isBrowsingSharedLink ? 3 : 0
            } label: {
                Label(
                    model.isBrowsingSharedLink ? "Choose in Links" : "Choose in Browser",
                    systemImage: model.isBrowsingSharedLink ? "link" : "folder"
                )
            }
            .buttonStyle(.bordered).pointingHandCursor()

            Button {
                model.startPendingDownloads()
            } label: {
                Label(model.restoredDownloadQueue ? "Resume Downloads" : "Start Download", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent).pointingHandCursor()
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canStartPendingDownloads)
            .help("Start every item currently waiting in the download queue")

            Button(role: .destructive) {
                model.stop()
            } label: {
                Label("Stop and Keep Partial", systemImage: "stop.circle")
            }
            .disabled(!model.isDownloading)

            if model.pendingDownloadBatchCount > 0 {
                Label(
                    "\(model.pendingDownloadItemCount.formatted()) queued item(s)",
                    systemImage: "tray.full"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Compatible selections share the next concurrent worker batch. You can remove these items before that batch starts.")
            }

            if !model.failedDownloadTransfers.isEmpty {
                Button {
                    model.retryFailedDownloads()
                } label: {
                    Label("Retry All Failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent).pointingHandCursor()
                .disabled(!model.canRetryFailedDownloads)
                .help("Retry every failed file in its original local destination")
            }

            Spacer()
            Button("Open Download Folder") {
                model.openOutputFolder()
            }
        }
    }

    private var downloadProgressDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(downloadStateColor.opacity(0.13))
                    Image(systemName: downloadStateSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(downloadStateColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Download progress")
                        .font(.headline)
                    Text(downloadStateSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(downloadPercentText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(downloadStateColor)
            }

            if model.downloadRunState == .scanning && model.downloadTotalFiles == 0 {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(downloadStateColor)
            } else {
                ProgressView(value: model.downloadOverallFraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(downloadStateColor)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    downloadMetric(
                        title: "Progress",
                        value: downloadBytesSummary,
                        systemImage: "arrow.down"
                    )
                    downloadMetric(
                        title: "Speed",
                        value: downloadSpeedSummary,
                        systemImage: "speedometer"
                    )
                }
                GridRow {
                    downloadMetric(
                        title: "Files",
                        value: downloadFilesSummary,
                        systemImage: "doc.on.doc"
                    )
                    downloadMetric(
                        title: "Remaining",
                        value: downloadRemainingSummary,
                        systemImage: "clock"
                    )
                }
            }
        }
        .appCard(padding: 14)
    }

    private var downloadTransferBoard: some View {
        HStack(alignment: .top, spacing: 12) {
            downloadStack(
                title: "Downloading",
                systemImage: "arrow.down.circle.fill",
                color: .blue,
                emptyTitle: model.isDownloading ? "Waiting for a worker" : "No active downloads",
                emptySystemImage: "bolt.horizontal.circle",
                transfers: model.downloadingTransfers
            )
            downloadQueueStack
            VStack(spacing: 12) {
                downloadStack(
                    title: "Completed",
                    systemImage: "checkmark.circle.fill",
                    color: .green,
                    emptyTitle: "Completed files appear here",
                    emptySystemImage: "checkmark.circle",
                    transfers: model.successfulDownloadTransfers.reversed()
                )
                .layoutPriority(1)

                if !model.failedDownloadTransfers.isEmpty {
                    downloadStack(
                        title: "Failed",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red,
                        emptyTitle: "Failed downloads appear here",
                        emptySystemImage: "exclamationmark.circle",
                        transfers: model.failedDownloadTransfers.reversed()
                    )
                    .frame(minHeight: 140, idealHeight: 195, maxHeight: 235)
                }
            }
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var downloadQueueStack: some View {
        let totalCount = model.pendingDownloadItemCount + model.queuedDownloadCount
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text("Queue")
                    .font(.headline)
                Spacer()
                if model.canClearPendingDownloads {
                    Button("Clear") {
                        model.clearPendingDownloads()
                    }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .help("Remove all selections that have not started")
                }
                Text(totalCount.formatted())
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)

            Divider()

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
                List {
                    ForEach(model.pendingDownloadItems) { item in
                        pendingDownloadRow(item)
                            .padding(.vertical, 4)
                            .listRowInsets(
                                EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
                            )
                    }
                    ForEach(model.queuedDownloadTransfers) { transfer in
                        downloadTransferRow(transfer)
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
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .appCard(padding: 0)
    }

    private func pendingDownloadRow(_ item: PendingDownloadItem) -> some View {
        HStack(spacing: 9) {
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
                    Text(model.isDownloading ? "Next batch" : "Ready")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .help(model.isDownloading
                            ? "Starts automatically in the next compatible worker batch. The current batch is not interrupted."
                            : "Press Start Download to run compatible queued selections together.")
                }
                Text((item.isShared ? "Shared link • " : "PikPak • ") + item.remotePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Cloud source: \(item.remotePath)\nLocal destination: \(item.destinationPath)")
            }

            Button {
                model.removePendingDownloadItem(item.id)
            } label: {
                Label("Remove", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless).pointingHandCursor()
            .controlSize(.small)
            .foregroundStyle(.red)
            .help("Remove \(item.name) from the download queue")
            .accessibilityLabel("Remove \(item.name) from download queue")
        }
        .accessibilityElement(children: .contain)
    }

    private func downloadStack<Transfers: RandomAccessCollection>(
        title: String,
        systemImage: String,
        color: Color,
        emptyTitle: String,
        emptySystemImage: String,
        transfers: Transfers
    ) -> some View where Transfers.Element == DownloadTransfer {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(transfers.count.formatted())
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
                        downloadTransferRow(transfer)
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
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .appCard(padding: 0)
    }

    private func downloadMetric(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadTransferRow(_ transfer: DownloadTransfer) -> some View {
        HStack(spacing: 9) {
            Image(systemName: downloadTransferSymbol(transfer.state))
                .foregroundStyle(downloadTransferColor(transfer.state))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(transfer.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.name)
                    Spacer()
                    Text(downloadTransferStateTitle(transfer.state))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(downloadTransferColor(transfer.state))
                }
                downloadTransferProgress(transfer)
                Text(transferBytesSummary(transfer))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if transfer.state == .failed || transfer.state == .stopped {
                    HStack {
                        Spacer()
                        Button {
                            model.retryFailedDownload(transfer)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent).pointingHandCursor()
                        .controlSize(.small)
                        .disabled(!model.canRetryFailedDownload(transfer))
                        .help(
                            model.canRetryFailedDownload(transfer)
                                ? "Retry only this file in its original local destination"
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
        switch model.downloadRunState {
        case .ready: return .secondary
        case .scanning, .downloading: return .blue
        case .stopping, .stopped: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var downloadStateSymbol: String {
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
        if model.activeDownloadCount > 0 {
            return "\(model.activeDownloadCount) active • \(model.downloadRunState.title)"
        }
        if model.downloadFailedFiles > 0 {
            return "\(model.downloadFailedFiles) failed • \(model.downloadRunState.title)"
        }
        return model.downloadRunState.title
    }

    private var downloadPercentText: String {
        guard let fraction = model.downloadOverallFraction else {
            return model.downloadRunState == .scanning ? "…" : "—"
        }
        if model.downloadRunState == .completed { return "100%" }
        return "\(Int((fraction * 100).rounded(.down)))%"
    }

    private var downloadBytesSummary: String {
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
                return model.activeDownloadCount > 0 ? "Starting…" : "Preparing…"
            }
            return "\(formatBytes(UInt64(model.downloadBytesPerSecond)))/s"
        case .completed:
            return "Finished"
        case .ready, .stopping, .stopped, .failed:
            return "—"
        }
    }

    private var downloadFilesSummary: String {
        guard model.downloadTotalFiles > 0 else {
            return model.downloadRunState == .scanning ? "Scanning…" : "—"
        }
        let processed = model.downloadProcessedFiles
        if model.downloadFailedFiles > 0 {
            return "\(processed) / \(model.downloadTotalFiles) • \(model.downloadFailedFiles) failed"
        }
        if model.downloadSkippedFiles > 0 {
            return "\(processed) / \(model.downloadTotalFiles) • \(model.downloadSkippedFiles) skipped"
        }
        return "\(processed) / \(model.downloadTotalFiles)"
    }

    private var downloadRemainingSummary: String {
        if model.downloadRunState == .scanning { return "Calculating…" }
        if model.downloadRunState == .completed { return "0 B left" }
        guard model.downloadTotalBytes > 0 else { return "—" }
        let bytes = "\(formatBytes(model.downloadRemainingBytes)) left"
        guard let seconds = model.downloadEstimatedSecondsRemaining else { return bytes }
        return "\(bytes) • \(formatDuration(seconds))"
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
        case .retrying(let attempt): return "Retry \(attempt)"
        case .completed: return "Complete"
        case .skipped: return "Already saved"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
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
        let seconds = max(Int(interval.rounded(.up)), 0)
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private var activity: some View {
        DisclosureGroup(isExpanded: $activityExpanded) {
            VStack(spacing: 9) {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "Ready for your next download." : model.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Color.clear.frame(height: 1).id("activity-end")
                    }
                    .onReceive(model.$log) { _ in
                        proxy.scrollTo("activity-end", anchor: .bottom)
                    }
                }
                .frame(height: 110)
                HStack {
                    Spacer()
                    Button("Clear Activity") {
                        model.clearLog()
                    }
                    .disabled(model.log.isEmpty)
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 9) {
                Image(
                    systemName: model.isRunning || model.hasBackgroundActivity
                        ? "bolt.horizontal.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(
                    model.isRunning || model.hasBackgroundActivity
                        ? Color.orange : Color.green
                )
                Text("Activity Log")
                    .font(.callout.weight(.semibold))
                Text(
                    model.isRunning || model.hasBackgroundActivity
                        ? "Working" : "Idle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appCard(padding: 11)
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
        if model.isBrowsingSharedLink {
            let linkCount = model.sharedLinks.count
            let visibleItemCount = model.sharedLinks.reduce(into: 0) { count, link in
                guard model.isSharedLinkExpanded(link.id) else { return }
                count += model.sharedLinkTreeEntries(for: link.id).count
            }
            let linkLabel = "\(linkCount.formatted()) \(linkCount == 1 ? "link" : "links")"
            guard visibleItemCount > 0 else { return linkLabel }
            return linkLabel
                + " • \(visibleItemCount.formatted()) \(visibleItemCount == 1 ? "item" : "items")"
        }
        return "\(model.visibleBrowserItemCount) shown"
            + (model.hasMoreBrowserItems ? " + more" : "")
    }

    private func requestTrashForBrowserSelection() {
        guard !workspaceNavigation.isSwitching, model.canTrashSelectedBrowserItem else { return }
        let items = model.browserItemsSelectedForTrash
        guard !items.isEmpty else { return }
        pendingTrashItems = items
        isBrowserTrashConfirmationPresented = true
    }

    private func expandBrowserSubfolders(_ item: BrowserItem, levels: Int?) {
        // Nested contents need an outline; preserve the current location and
        // selection while switching a thumbnail context-menu action to List.
        setFinderViewMode(BrowserViewMode.list.rawValue)
        isPreviewExpanded = false
        browserListFocused = true
        model.expandBrowserSubfolders(item, levels: levels)
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
        trimmedURL.caseInsensitiveCompare(originalURL) != .orderedSame
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
            .sheet(isPresented: $activity.showsDuplicateResults) {
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
    }
}

private struct DuplicateResultsView: View {
    @ObservedObject var model: DownloaderModel
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let scan = model.duplicateScan {
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
                Text("These results are no longer current. Choose File → Check for Duplicates to scan again.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
                Text("Scanned Folder")
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
                    "\(scan.failedFolders.formatted()) folder(s) could not be read after retries. Duplicate results below cover every folder PikPak returned successfully."
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
        VStack(spacing: 0) {
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
                .help("Select all redundant exact-content copies while retaining one copy per group")

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
                ForEach(scan.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            duplicateFileRow(file, in: group)
                        }
                    } header: {
                        duplicateGroupHeader(group)
                            .padding(.vertical, 5)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

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
                Image(systemName: "doc.fill")
                    .foregroundStyle(group.matchKind == .exactContent ? Color.green : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(file.name)
                    Text(file.path)
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
        .disabled(model.isRunning)
        .padding(.vertical, 4)
    }

    private func selectionBinding(for fileID: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedDuplicateFileIDs.contains(fileID) },
            set: { model.setDuplicateFileSelected(fileID, selected: $0) }
        )
    }

    private func selectedCount(in group: DuplicateGroup) -> Int {
        group.files.filter { model.selectedDuplicateFileIDs.contains($0.id) }.count
    }

    private func selectionLabel(for file: DuplicateFile, in group: DuplicateGroup) -> String {
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
private struct BrowserKeyboardMonitor: NSViewRepresentable {
    var handlesRangeSelection: Bool
    var handlesDelete: Bool
    var handlesZoom: Bool
    var handlesQuickLook: Bool
    let onShiftMove: (MoveCommandDirection) -> Void
    let onCommandDelete: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onActualSize: () -> Void
    /// Returns `true` when Space was consumed, so an unhandled Space still
    /// reaches whatever the responder chain would normally do with it.
    let onQuickLook: (NSWindow?) -> Bool
    let onCancelQuickLook: () -> Bool
    let ownsQuickLookPanel: (NSWindow) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitoredView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var parent: BrowserKeyboardMonitor
        weak var monitoredView: NSView?
        private var eventMonitor: Any?

        init(parent: BrowserKeyboardMonitor) {
            self.parent = parent
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, let browserWindow = self.monitoredView?.window,
                      let eventWindow = event.window ?? NSApp.keyWindow else { return event }
                let isFileWindow = eventWindow === browserWindow
                let isPreviewPanel = self.parent.ownsQuickLookPanel(eventWindow)
                guard isFileWindow || isPreviewPanel else { return event }
                let responder = eventWindow.firstResponder
                let isTextInput = (responder as? NSTextView).map { $0.isEditable || isFileWindow }
                    ?? (responder is NSText || responder is NSTextField || responder is NSControl)
                if self.parent.handlesQuickLook || isPreviewPanel,
                   let action = FinderQuickLookKeyboard.action(keyCode: event.keyCode,
                       modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                       isFileWindow: isFileWindow, isOwnedPreviewPanel: isPreviewPanel,
                       hasSheet: eventWindow.isSheet || eventWindow.attachedSheet != nil,
                       isTextInput: isTextInput) {
                    switch action {
                    case .toggle: if self.parent.onQuickLook(browserWindow) { return nil }
                    case .cancel: if self.parent.onCancelQuickLook() { return nil }
                    case .consumeRepeat: return nil
                    case .previous, .next: break // The panel's controller moves the selection.
                    }
                }
                guard isFileWindow, !eventWindow.isSheet, eventWindow.attachedSheet == nil else { return event }
                // Native editing, including quick-open, owns text shortcuts.
                if NSApp.keyWindow?.firstResponder is NSText { return event }
                let modifiers = event.modifierFlags.intersection(
                    .deviceIndependentFlagsMask
                )

                if self.parent.handlesZoom,
                   modifiers.contains(.command),
                   !modifiers.contains(.control),
                   !modifiers.contains(.option) {
                    switch event.keyCode {
                    case 24, 69: // Main keyboard =/+ and numeric keypad +.
                        self.parent.onZoomIn()
                        return nil
                    case 27, 78: // Main keyboard -/_ and numeric keypad -.
                        self.parent.onZoomOut()
                        return nil
                    case 29, 82: // Main keyboard 0 and numeric keypad 0.
                        self.parent.onActualSize()
                        return nil
                    default:
                        break
                    }
                }

                if self.parent.handlesDelete,
                   modifiers.contains(.command),
                   !modifiers.contains(.control),
                   !modifiers.contains(.option),
                   (event.keyCode == 51 || event.keyCode == 117) {
                    self.parent.onCommandDelete()
                    return nil
                }

                guard
                    self.parent.handlesRangeSelection,
                    modifiers.contains(.shift),
                    !modifiers.contains(.command),
                    !modifiers.contains(.control),
                    !modifiers.contains(.option)
                else { return event }

                switch event.keyCode {
                case 126:
                    self.parent.onShiftMove(.up)
                    return nil
                case 125:
                    self.parent.onShiftMove(.down)
                    return nil
                default:
                    return event
                }
            }
        }

        func stop() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        deinit {
            stop()
        }
    }
}

private enum BrowserTreeColumnLimits {
    static let name: ClosedRange<CGFloat> = 150...720
    static let size: ClosedRange<CGFloat> = 58...180
    static let kind: ClosedRange<CGFloat> = 72...280
    static let modified: ClosedRange<CGFloat> = 108...360

    static func range(for column: BrowserSortColumn) -> ClosedRange<CGFloat> {
        switch column {
        case .name: return name
        case .size: return size
        case .kind: return kind
        case .modified: return modified
        }
    }

    static func clamped(_ width: CGFloat, for column: BrowserSortColumn) -> CGFloat {
        let bounds = range(for: column)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }
}

/// One resolved set of column dimensions shared by the sticky header and
/// every outline row. Keeping one source of truth prevents the header from
/// drifting out of alignment when a column is resized or hidden.
private struct BrowserTreeColumnLayout {
    var name: CGFloat
    let size: CGFloat
    let kind: CGFloat
    let modified: CGFloat
    let showsSize: Bool
    let showsKind: Bool
    let showsModified: Bool
    let scale: CGFloat
    let action: CGFloat
    var trailingFill: CGFloat = 0

    var separator: CGFloat { max(7, 10 * scale) }
    var horizontalPadding: CGFloat { max(6, 9 * scale) }
    var headerHeight: CGFloat { max(24, 28 * scale) }

    private var minimumTableWidth: CGFloat {
        var width = horizontalPadding * 2 + name + action
        if showsSize { width += separator + size }
        if showsKind { width += separator + kind }
        if showsModified { width += separator + modified }
        return width
    }

    var tableWidth: CGFloat { minimumTableWidth + trailingFill }

    init(
        name: Double,
        size: Double,
        kind: Double,
        modified: Double,
        showsSize: Bool,
        showsKind: Bool,
        showsModified: Bool,
        scale: CGFloat,
        actionWidth: CGFloat
    ) {
        self.scale = scale
        self.action = max(28, actionWidth * scale)
        self.name = BrowserTreeColumnLimits.clamped(CGFloat(name), for: .name) * scale
        self.size = BrowserTreeColumnLimits.clamped(CGFloat(size), for: .size) * scale
        self.kind = BrowserTreeColumnLimits.clamped(CGFloat(kind), for: .kind) * scale
        self.modified = BrowserTreeColumnLimits.clamped(CGFloat(modified), for: .modified) * scale
        self.showsSize = showsSize
        self.showsKind = showsKind
        self.showsModified = showsModified
    }

    func filling(width: CGFloat) -> BrowserTreeColumnLayout {
        var result = self
        result.trailingFill = max(width - minimumTableWidth, 0)
        return result
    }

    func unscaledWidth(for column: BrowserSortColumn) -> CGFloat {
        let width: CGFloat
        switch column {
        case .name: width = name
        case .size: width = size
        case .kind: width = kind
        case .modified: width = modified
        }
        return width / max(scale, 0.01)
    }
}

private struct BrowserTreeHeader: View {
    @State private var hoveredColumn: BrowserSortColumn?

    let columns: BrowserTreeColumnLayout
    let sortColumn: BrowserSortColumn
    let sortDirection: BrowserSortDirection
    let onSort: (BrowserSortColumn) -> Void
    let onResize: (BrowserSortColumn, CGFloat) -> Void
    let onResizeEnded: (BrowserSortColumn, CGFloat) -> Void
    let onToggleVisibility: (BrowserSortColumn) -> Void
    let onResetColumns: () -> Void
    let actionTitle: String?

    private var scale: CGFloat {
        columns.scale
    }

    var body: some View {
        HStack(spacing: 0) {
            sortableHeader("Name", column: .name, alignment: .leading)
                .frame(width: columns.name, alignment: .leading)
            resizeHandle(for: .name)

            if columns.showsSize {
                sortableHeader("Size", column: .size, alignment: .trailing)
                    .frame(width: columns.size, alignment: .trailing)
                resizeHandle(for: .size)
            }

            if columns.showsKind {
                sortableHeader("Kind", column: .kind, alignment: .leading)
                    .frame(width: columns.kind, alignment: .leading)
                resizeHandle(for: .kind)
            }

            if columns.showsModified {
                sortableHeader("Date Modified", column: .modified, alignment: .leading)
                    .frame(width: columns.modified, alignment: .leading)
                resizeHandle(for: .modified)
            }

            Color.clear
                .frame(width: columns.trailingFill)

            actionHeader
        }
        .font(.system(size: max(9, 11 * scale), weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, height: columns.headerHeight, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File columns")
        .contextMenu {
            columnVisibilityMenu
        }
    }

    private func sortableHeader(
        _ title: String,
        column: BrowserSortColumn,
        alignment: Alignment
    ) -> some View {
        Button {
            onSort(column)
        } label: {
            HStack(spacing: 4 * scale) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortDirection.systemImage)
                        .font(.system(size: 7 * scale, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if alignment != .trailing {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, max(3, 5 * scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(
                hoveredColumn == column
                    ? Color.primary.opacity(0.055)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { isHovered in
            hoveredColumn = isHovered ? column : nil
        }
        .help(
            sortColumn == column
                ? "Sort by \(title), \(sortDirection == .ascending ? "descending" : "ascending")"
                : "Sort by \(title), ascending"
        )
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(
            sortColumn == column
                ? "Sorted \(sortDirection.title)"
                : "Not sorted"
        )
    }

    private func resizeHandle(for column: BrowserSortColumn) -> some View {
        BrowserColumnResizeHandle(
            column: column,
            currentWidth: columns.unscaledWidth(for: column),
            scale: scale,
            width: columns.separator,
            onResize: onResize,
            onResizeEnded: onResizeEnded
        )
    }

    private var columnsMenu: some View {
        Menu {
            columnVisibilityMenu
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: max(9, 11 * scale), weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Choose visible columns")
        .accessibilityLabel("Choose visible columns")
    }

    private var actionHeader: some View {
        HStack(spacing: max(2, 4 * scale)) {
            if let actionTitle {
                Text(actionTitle)
                    .lineLimit(1)
            }
            columnsMenu
                .frame(width: max(22, 24 * scale))
        }
        .frame(width: columns.action, alignment: .trailing)
    }

    @ViewBuilder
    private var columnVisibilityMenu: some View {
        Text("Show Columns")
        columnToggle("Size", column: .size, isVisible: columns.showsSize)
        columnToggle("Kind", column: .kind, isVisible: columns.showsKind)
        columnToggle(
            "Date Modified",
            column: .modified,
            isVisible: columns.showsModified
        )
        Divider()
        Button("Reset Column Layout", action: onResetColumns)
    }

    private func columnToggle(
        _ title: String,
        column: BrowserSortColumn,
        isVisible: Bool
    ) -> some View {
        Button {
            onToggleVisibility(column)
        } label: {
            if isVisible {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct BrowserColumnResizeHandle: View {
    let column: BrowserSortColumn
    let currentWidth: CGFloat
    let scale: CGFloat
    let width: CGFloat
    let onResize: (BrowserSortColumn, CGFloat) -> Void
    let onResizeEnded: (BrowserSortColumn, CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(
                    isHovered || dragStartWidth != nil
                        ? Color.accentColor.opacity(0.7)
                        : Color.primary.opacity(0.1)
                )
                .frame(width: isHovered || dragStartWidth != nil ? 2 : 1)
                .padding(.vertical, max(4, 6 * scale))
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .highPriorityGesture(
            // This divider moves while its column changes width. A stationary
            // coordinate space keeps that motion out of the drag translation.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? currentWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    onResize(column, start + value.translation.width / max(scale, 0.01))
                }
                .onEnded { value in
                    let start = dragStartWidth ?? currentWidth
                    let finalWidth = start
                        + value.translation.width / max(scale, 0.01)
                    onResizeEnded(column, finalWidth)
                    dragStartWidth = nil
                }
        )
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to resize the \(column.title) column")
        .accessibilityLabel("Resize \(column.title) column")
    }
}

/// A shared URL behaves like a virtual filesystem root. Its disclosure reveals
/// the active link's ordinary BrowserTreeRow children, while the leading tool
/// disconnects only the local link session and never deletes cloud content.
private struct SharedLinkTreeRow: View {
    @State private var isRowHovered = false
    @State private var isDisclosureHovered = false
    @State private var isDisconnectHovered = false

    let entry: SharedLinkEntry
    let zoomScale: CGFloat
    let columns: BrowserTreeColumnLayout
    let isSelected: Bool
    let isExpanded: Bool
    let usesAlternateBackground: Bool
    let measurement: FolderMeasurement?
    let isMeasuring: Bool
    let isQueued: Bool
    let canMeasure: Bool
    let canEditLink: Bool
    let canDisconnect: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onMeasure: () -> Void
    let onEditLink: () -> Void
    let onCopyLink: () -> Void
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    private var scale: CGFloat {
        min(max(zoomScale, CGFloat(BrowserItemZoom.minimum)), CGFloat(BrowserItemZoom.maximum))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5 * scale) {
                disclosure

                // Use the checkbox slot beside the link icon, preserving the
                // name alignment with the nested file/folder rows.
                FinderRowAction(title: "Remove link from this app (keeps cloud files)",
                                symbol: "xmark", tint: .red, enabled: canDisconnect,
                                side: max(18, 22 * scale), hintOnRight: true,
                                onHover: { isDisconnectHovered = $0 },
                                action: onDisconnect)
                    .accessibilityLabel("Disconnect shared link \(entry.url)")

                Button(action: onSelect) {
                    HStack(spacing: 5 * scale) {
                        Image(systemName: "link")
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 19 * scale)

                        Text(entry.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.url)

                        if entry.savedItemCount > 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(.green)
                                .help("\(entry.savedItemCount.formatted()) item(s) saved to your PikPak")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHandCursor()
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
            .frame(width: columns.name, alignment: .leading)
            .zIndex(isDisconnectHovered ? 1 : 0)

            if columns.showsSize {
                columnGap
                sizeCell
                    .frame(width: columns.size, alignment: .trailing)
            }

            if columns.showsKind {
                columnGap
                Text("Link")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: columns.kind, alignment: .leading)
            }

            if columns.showsModified {
                columnGap
                Text(Self.addedDateFormatter.string(from: entry.addedAt))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Added \(Self.addedDateFormatter.string(from: entry.addedAt))")
                    .frame(width: columns.modified, alignment: .leading)
            }

            Color.clear
                .frame(width: columns.trailingFill)

            Color.clear
                .frame(width: columns.action)
        }
        .font(.system(size: max(10, 12.5 * scale)))
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, alignment: .leading)
        .frame(height: max(24, 29 * scale))
        .background(rowBackground.animation(.easeOut(duration: 0.1), value: isRowHovered))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isRowHovered = hovering
        }
        .contextMenu {
            Button(action: onEditLink) {
                BrowserContextMenuStyle.label("Edit Link…", systemImage: "pencil")
            }
            .disabled(!canEditLink)

            // Copies the public share URL only. Any access code stays in the
            // app's owner-only local state.
            Button(action: onCopyLink) {
                BrowserContextMenuStyle.label("Copy Link", systemImage: "doc.on.doc")
            }

            if case .failed = entry.state {
                Button(action: onRetry) {
                    BrowserContextMenuStyle.label("Retry Link", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive, action: onDisconnect) {
                BrowserContextMenuStyle.label("Disconnect Link", systemImage: "xmark.circle")
            }
            .disabled(!canDisconnect)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var disclosure: some View {
        Button(action: disclosureAction) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isDisclosureHovered
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )

                switch entry.state {
                case .loading:
                    ProgressView()
                        .controlSize(.mini)
                case .ready:
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundStyle(
                            isDisclosureHovered ? Color.accentColor : Color.secondary
                        )
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { isDisclosureHovered = $0 }
        .help(disclosureHelp)
        .accessibilityLabel(disclosureHelp)
    }

    private func disclosureAction() {
        if case .failed = entry.state {
            onRetry()
        } else {
            onToggle()
        }
    }

    private var disclosureHelp: String {
        switch entry.state {
        case .loading:
            return "Loading shared link"
        case .ready:
            return isExpanded ? "Collapse shared link" : "Expand shared link"
        case .failed(let message):
            return "Retry shared link: \(message)"
        }
    }

    @ViewBuilder
    private var sizeCell: some View {
        if isMeasuring {
            HStack(spacing: 5 * scale) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning…")
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Calculating the complete shared-link size")
        } else if isQueued {
            Label("Queued…", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("This link will be scanned after the current folder-size calculation")
        } else if let measurement {
            Text(formatBytes(measurement.totalBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    "\(measurement.fileCount.formatted()) file(s), "
                        + "\(measurement.folderCount.formatted()) subfolder(s)"
                )
        } else if canMeasure {
            Button("Calculate", action: onMeasure)
                .buttonStyle(.link)
                .controlSize(.mini)
                .help("Recursively calculate this shared link's size")
        } else {
            Text("--")
                .foregroundStyle(.tertiary)
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        if isRowHovered && !isDisconnectHovered {
            return Color.accentColor.opacity(0.055)
        }
        return usesAlternateBackground ? Color.primary.opacity(0.018) : Color.clear
    }

    private var columnGap: some View {
        Color.clear
            .frame(width: columns.separator)
    }

    private static let addedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

private struct BrowserTreeRow: View {
    @State private var isRowHovered = false
    @State private var isDisclosureHovered = false
    @State private var isCheckboxHovered = false
    @State private var isActionHovered = false

    let item: BrowserItem
    let depth: Int
    let zoomScale: CGFloat
    let columns: BrowserTreeColumnLayout
    let isActive: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let hasMoreItems: Bool
    let isLoadedAndEmpty: Bool
    let loadError: String?
    let usesAlternateBackground: Bool
    let canDownload: Bool
    let folderMeasurement: FolderMeasurement?
    let isMeasuringSize: Bool
    let isMeasurementQueued: Bool
    let canMeasureSize: Bool
    let isSavedToPikPak: Bool
    let showsShareActions: Bool
    let isSavingToPikPak: Bool
    let canSaveToPikPak: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onActivate: () -> Void
    let onToggle: () -> Void
    let onLoadMore: () -> Void
    let onRetry: () -> Void
    let onMeasure: () -> Void
    let onSave: () -> Void
    let onDownload: () -> Void

    private var scale: CGFloat {
        min(max(zoomScale, CGFloat(BrowserItemZoom.minimum)), CGFloat(BrowserItemZoom.maximum))
    }

    var body: some View {
        #if BROWSER_SCROLL_PROFILING
        let _ = BrowserScrollDiagnostics.rowBodies += 1
        #endif
        HStack(spacing: 0) {
            HStack(spacing: 5 * scale) {
                Color.clear
                    .frame(width: CGFloat(depth) * 16 * scale)

                disclosure

                Button(action: onToggleSelection) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                isCheckboxHovered
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: max(18, 22 * scale), height: max(18, 22 * scale))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHandCursor()
                .onHover { isCheckboxHovered = $0 }
                .help(
                    isSelected
                        ? "Deselect this selection (folders include all contents)"
                        : "Add to selection (folders include all contents)"
                )
                .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")

                selectableCell(
                    HStack(spacing: 5 * scale) {
                        Image(systemName: symbol)
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(symbolColor)
                            .frame(width: 19 * scale)

                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.name)

                        if isLoadedAndEmpty && isExpanded {
                            Text("Empty")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5 * scale)
                                .padding(.vertical, 2 * scale)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                )

                if let loadError {
                    Button(action: onRetry) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .help("\(loadError) Click to retry.")
                    .accessibilityLabel("Retry loading \(item.name)")
                } else if hasMoreItems && isExpanded && !isLoading {
                    Button("More…", action: onLoadMore)
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .help("Load more items from \(item.name)")
                }
            }
            .frame(width: columns.name, alignment: .leading)
            .clipped()

            if columns.showsSize {
                columnGap
                folderSizeCell
                    .frame(width: columns.size, alignment: .trailing)
            }

            if columns.showsKind {
                columnGap
                selectableCell(
                    Text(kindTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(kindTitle)
                        .frame(width: columns.kind, alignment: .leading)
                )
            }

            if columns.showsModified {
                columnGap
                selectableCell(
                    Text(modifiedTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(modifiedTitle)
                        .frame(width: columns.modified, alignment: .leading)
                )
            }

            Color.clear
                .frame(width: columns.trailingFill)

            HStack(spacing: 4 * scale) {
                if showsShareActions {
                    FinderRowAction(title: isSavedToPikPak ? "Saved to My PikPak" : (isSavingToPikPak ? "Saving to My PikPak…" : "Save to My PikPak"),
                        symbol: isSavedToPikPak ? "checkmark.circle.fill" : "icloud.and.arrow.up",
                        tint: isSavedToPikPak ? .green : .accentColor,
                        busy: isSavingToPikPak, enabled: canSaveToPikPak && !isSavedToPikPak,
                        side: max(21, 24 * scale), onHover: { isActionHovered = $0 }, action: onSave)
                }
                FinderRowAction(title: "Add \(item.isFolder ? "folder" : "file") to download queue",
                    symbol: "arrow.down.circle", enabled: canDownload,
                    side: max(21, 24 * scale), onHover: { isActionHovered = $0 }, action: onDownload)
            }
            .frame(width: columns.action)
        }
        .font(.system(size: max(10, 12.5 * scale)))
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, alignment: .leading)
        .frame(height: max(24, 29 * scale))
        // Animate the highlight only, not the row's inherited font or its
        // context-menu symbols when macOS opens/closes the menu.
        .background(rowBackground.animation(.easeOut(duration: 0.1), value: isRowHovered))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isRowHovered = hovering
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var folderSizeCell: some View {
        if !item.isFolder {
            selectableCell(
                Text(formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            )
        } else if isMeasuringSize {
            HStack(spacing: 5 * scale) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning…")
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Scanning this folder and all subfolders")
        } else if isMeasurementQueued {
            Label("Queued…", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("This folder will be scanned after the current size calculation")
        } else if let folderMeasurement {
            selectableCell(
                Text(formatBytes(folderMeasurement.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(
                        "\(folderMeasurement.fileCount.formatted()) file(s), "
                            + "\(folderMeasurement.folderCount.formatted()) subfolder(s)"
                    )
            )
        } else {
            Button(action: onMeasure) {
                Text("Calculate")
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .controlSize(.mini)
            .disabled(!canMeasureSize)
            .help("Recursively calculate this folder's size")
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if item.isFolder {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isDisclosureHovered
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .foregroundStyle(
                                isDisclosureHovered ? Color.accentColor : Color.secondary
                            )
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.12), value: isExpanded)
                    }
                }
                .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .scaleEffect(isDisclosureHovered ? 1.06 : 1)
            .animation(.easeOut(duration: 0.1), value: isDisclosureHovered)
            .onHover { isDisclosureHovered = $0 }
            .help(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
            .accessibilityLabel(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
        } else {
            Color.clear
                .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
        }
    }

    private func selectableCell<Content: View>(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onActivate()
                    }
            )
    }

    private var symbol: String {
        if item.isFolder { return "folder.fill" }
        if item.isTextPreviewable { return "doc.plaintext" }
        switch item.mediaKind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }

    private var symbolColor: Color {
        if item.isFolder { return .blue }
        if item.isTextPreviewable { return .indigo }
        switch item.mediaKind {
        case .image: return .teal
        case .video: return .purple
        case .audio: return .orange
        case .other: return .secondary
        }
    }

    private var kindTitle: String {
        item.kindDisplayTitle
    }

    private var modifiedTitle: String {
        guard let modifiedTime = item.modifiedTime, !modifiedTime.isEmpty else { return "--" }
        return Self.displayDate(from: modifiedTime) ?? modifiedTime
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(isActive ? 0.2 : 0.13)
        }
        if isActive {
            return Color.accentColor.opacity(0.08)
        }
        if isRowHovered && !isActionHovered {
            return Color.accentColor.opacity(0.055)
        }
        return usesAlternateBackground ? Color.primary.opacity(0.018) : Color.clear
    }

    private var columnGap: some View {
        Color.clear
            .frame(width: columns.separator)
    }

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISOFormatter = ISO8601DateFormatter()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func displayDate(from value: String) -> String? {
        let date = fractionalISOFormatter.date(from: value) ?? basicISOFormatter.date(from: value)
        return date.map(displayDateFormatter.string(from:))
    }

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

private struct BrowserThumbnailTile: View {
    @State private var isHovered = false
    @State private var isCheckboxHovered = false

    let item: BrowserItem
    let scale: CGFloat
    let sizeLabel: String
    let systemImage: String
    let isActive: Bool
    let isSelected: Bool
    let isMeasuringSize: Bool
    let isMeasurementQueued: Bool
    let isSavedToPikPak: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onActivate: () -> Void

    private var thumbnailSide: CGFloat { 82 * scale }

    var body: some View {
        VStack(spacing: max(5, 7 * scale)) {
            thumbnail
                .frame(width: thumbnailSide, height: thumbnailSide)

            Text(item.name)
                .font(.system(size: max(10, 12 * scale), weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: max(25, 30 * scale), alignment: .top)
                .help(item.name)

            if isMeasuringSize {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning…")
                }
                .font(.system(size: max(8.5, 10 * scale)))
                .foregroundStyle(.secondary)
            } else if isMeasurementQueued {
                Label("Queued…", systemImage: "clock")
                    .font(.system(size: max(8.5, 10 * scale)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(sizeLabel)
                    .font(.system(size: max(8.5, 10 * scale)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, max(5, 7 * scale))
        .padding(.vertical, max(7, 9 * scale))
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 11 * scale)
                .fill(tileBackground)
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }
        // Attach the tile gesture before adding the checkbox overlay. This
        // keeps a checkbox click from also firing the tile's row-selection
        // gesture, whose order was nondeterministic in SwiftUI.
        .contentShape(RoundedRectangle(cornerRadius: 11 * scale))
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    onActivate()
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11 * scale)
                .strokeBorder(tileBorder, lineWidth: isActive ? 2 : 1)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onToggleSelection) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isCheckboxHovered
                                ? Color.accentColor.opacity(0.14)
                                : Color(nsColor: .windowBackgroundColor).opacity(0.88)
                        )
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(width: max(22, 25 * scale), height: max(22, 25 * scale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .onHover { isCheckboxHovered = $0 }
            .help(
                isSelected
                    ? "Deselect this selection (folders include all contents)"
                    : "Add to selection (folders include all contents)"
            )
            .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
            .padding(max(3, 4 * scale))
        }
        .overlay(alignment: .topTrailing) {
            if isSavedToPikPak {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(.white, .green)
                    .padding(max(5, 6 * scale))
                .help("Saved to your PikPak in this app session")
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(sizeLabel)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.isFolder {
            ZStack {
                RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                    .fill(Color.blue.opacity(isSelected ? 0.12 : 0.06))
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.62, blue: 1), .blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(10 * scale)
                    .shadow(color: .blue.opacity(0.18), radius: 3 * scale, y: 2 * scale)
            }
        } else {
            RemoteArtwork(
                url: item.artworkURL,
                systemName: systemImage,
                fit: item.mediaKind == .audio || item.mediaKind == .other
            )
            .frame(width: thumbnailSide, height: thumbnailSide)
            .background(Color.secondary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.mediaKind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6 * scale)
                        .background(.black.opacity(0.58), in: Circle())
                        .padding(5 * scale)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 3 * scale, y: 2 * scale)
        }
    }

    private var tileBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(isActive ? 0.16 : 0.1)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return .clear
    }

    private var tileBorder: Color {
        if isActive {
            return Color.accentColor.opacity(0.75)
        }
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        return Color.clear
    }
}

private struct RemoteArtwork: View {
    let url: URL?
    let systemName: String
    let fit: Bool

    var body: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                switch phase {
                case .empty:
                    placeholder
                        .overlay { ProgressView().controlSize(.small) }
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }
}

/// Adds two representations to one Finder-style drag: an own-process token for
/// moving items between PikPak folders and a lazy file promise for downloading
/// the same selection when it is dropped into Finder. Credentials and remote
/// URLs never enter the pasteboard.
struct BrowserMoveDragSourceModifier: ViewModifier {
    @ObservedObject var model: DownloaderModel
    let item: BrowserItem

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.canBeginBrowserDrag {
            content
                .contentShape(Rectangle())
                .onDrag {
                    guard let token = model.beginBrowserDrag(item) else {
                        return NSItemProvider()
                    }
                    let provider: NSItemProvider
                    if let promiseProvider = model.makeBrowserDownloadPromiseProvider() {
                        provider = promiseProvider
                    } else {
                        provider = NSItemProvider()
                        provider.suggestedName = model.browserDragTitle(startingWith: item)
                    }
                    provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.pikPakBrowserItems.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(token.utf8), nil)
                        return nil
                    }
                    return provider
                } preview: {
                    BrowserMoveDragPreview(
                        title: model.browserDragTitle(startingWith: item),
                        itemCount: model.browserDragItemCount(startingWith: item),
                        containsFolder: model.browserDragContainsFolder(startingWith: item)
                    )
                }
        } else {
            content
        }
    }
}

/// A compact Finder-like stack makes it explicit that dragging one checked
/// row carries the complete multi-selection rather than only the row under the
/// pointer.
private struct BrowserMoveDragPreview: View {
    let title: String
    let itemCount: Int
    let containsFolder: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: containsFolder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                if itemCount > 1 {
                    Text(itemCount.formatted())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 10, y: -7)
                }
            }
            .frame(width: 36, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    itemCount == 1
                        ? "Move in PikPak or download to Finder"
                        : "Move selection or download it to Finder"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }
}

private extension View {
    func browserMoveDragSource(model: DownloaderModel, item: BrowserItem) -> some View {
        modifier(BrowserMoveDragSourceModifier(model: model, item: item))
    }

    func appCard(padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.075), lineWidth: 1)
                    // Decorative outlines must not compete with the card's
                    // buttons, checkboxes or scroll view for pointer events.
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.045), radius: 10, y: 3)
    }
}
