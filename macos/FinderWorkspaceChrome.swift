import AppKit
import SwiftUI

/// Provider workspaces share geometry as well as colours. Provider views supply
/// data and actions; they cannot silently replace the navigation or page shell.
enum FinderWorkspaceLayout {
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 12
    static let footerHeight: CGFloat = 34
    static let browserMinimumWidth: CGFloat = 360
    static let previewMinimumWidth: CGFloat = 300
}

struct FinderWorkspaceBody<Content: View, Footer: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { viewport in
                content().frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
            footer()
        }.padding(FinderWorkspaceLayout.inset)
    }
}

struct FinderDriveSidebar<Details: View>: View {
    @ObservedObject var navigation: FinderWorkspaceNavigation
    @ObservedObject var settings: FinderSettings
    var accountTitle = "Account"
    let accountSubtitle: String
    var accountPane = 2
    var showsContentMode = false
    var pikpakAccount: DownloaderModel? = nil
    var sections: [FinderWorkspaceSection] = FinderWorkspaceSection.standard
    let select: (Int) -> Void
    @ViewBuilder var details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: pikpakAccount == nil ? 6 : 4) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 29, height: 29)
                Text("MyCloudDriver").font(.headline)
            }.padding(.horizontal, 12).padding(.top, pikpakAccount == nil ? 16 : 10).padding(.bottom, pikpakAccount == nil ? 16 : 8)
            if let model = pikpakAccount {
                PikPakConnectionSelector(model: model, monitor: model.transferQuotaMonitor)
                    .padding(.horizontal, 6).padding(.bottom, 4)
            }
            Text("WORKSPACES").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).padding(.horizontal, 12)
            ForEach(sections) { section in
                FinderWorkspaceSidebarTab(loading: navigation.loading, title: section.title,
                    symbol: section.symbol, section: section.rawValue, currentSection: navigation.section) {
                    select(section.rawValue)
                }
            }
            Divider().padding(.vertical, pikpakAccount == nil ? 8 : 4)
            if showsContentMode {
                FinderContentModeSelector(settings: settings)
            }
            FinderSettingsButton().buttonStyle(.plain).pointingHandCursor().help("Settings · Command-Comma")
            Spacer(minLength: pikpakAccount == nil ? 12 : 6)
            details().fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 140, alignment: .topLeading)
            if pikpakAccount == nil {
              FinderAccountSettingsLink(settings: settings, pane: accountPane) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountTitle)
                        Text(accountSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: { Image(systemName: "person.crop.circle").foregroundStyle(FinderAppearance.accent) }
                .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().help(accountSubtitle)
            }
        }.padding(.horizontal, 8).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FinderAppearance.sidebarBackground)
            .accessibilityElement(children: .contain).accessibilityLabel("Sidebar")
    }
}

/// A compact, always-visible choice with room to explain fallback in the
/// popover. Fixed template icons keep unrelated progress updates out of layout.
struct FinderContentModeSelector: View {
    @ObservedObject var settings: FinderSettings
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PREVIEW & SCAN MODE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Button { isPresented.toggle() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(nsImage: FinderSymbolImage.template(named: settings.contentMode.symbol, style: .menu))
                            .foregroundStyle(FinderAppearance.accent)
                        Text(settings.contentMode.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(nsImage: FinderSymbolImage.template(named: "chevron.up.chevron.down", style: .menu))
                            .foregroundStyle(.secondary)
                    }
                    Text(settings.contentMode.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.1)) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).pointingHandCursor()
            .accessibilityLabel("Preview and scan mode").accessibilityValue(settings.contentMode.title)
            .accessibilityHint("Choose User, Guest or Dynamic for PikPak previews and similarity scans")
            .help("\(settings.contentMode.detail) Applies to new PikPak previews and similarity scans. Downloads always use Dynamic Mode.")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) { choices }
            .onReceive(NotificationCenter.default.publisher(for: FinderPopover.dismissAllNotification)) { _ in isPresented = false }
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PikPak preview and scan mode").font(.headline)
                Text("Previews, Quick Look, Open and similarity scans")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                ForEach(PikPakContentMode.allCases) { mode in
                    Button {
                        settings.contentMode = mode
                        isPresented = false
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(nsImage: FinderSymbolImage.template(named: mode.symbol, style: .menu))
                                .foregroundStyle(FinderAppearance.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title).font(.system(size: 13, weight: .semibold))
                                Text(mode.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(nsImage: FinderSymbolImage.template(named: "checkmark", style: .menu))
                                .foregroundStyle(FinderAppearance.accent)
                                .opacity(settings.contentMode == mode ? 1 : 0).padding(.top, 2)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(settings.contentMode == mode ? FinderAppearance.accent.opacity(0.1) : Color.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).pointingHandCursor()
                        .accessibilityLabel(mode.title).accessibilityValue(settings.contentMode == mode ? "Selected" : "Not selected")
                        .accessibilityHint(mode.detail)
                }
            }
            Text("Downloads always use Dynamic Mode: Guest first, then User for the remaining bytes. User access uses your account’s downstream quota. Running scans keep their current mode.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 320)
    }
}

struct FinderBrowserSplit<Files: View, Preview: View>: View {
    let showsPreview: Bool
    var expanded = false
    var resetRevision = 0
    @ViewBuilder var files: () -> Files
    @ViewBuilder var preview: () -> Preview
    @AppStorage("finderPreviewPlacement") private var placement = "right"
    @AppStorage("browserSplitFraction") private var rightFraction = 0.64
    @AppStorage("browserBottomSplitFraction") private var bottomFraction = 0.45
    @State private var dragStart: CGFloat?
    @State private var liveFraction: Double?
    private var bottom: Bool { placement == "bottom" }
    private var savedFraction: Double {
        get { bottom ? bottomFraction : rightFraction }
        nonmutating set { if bottom { bottomFraction = newValue } else { rightFraction = newValue } }
    }
    var body: some View {
        GeometryReader { viewport in
            let fileMinimum: CGFloat = bottom ? 180 : FinderWorkspaceLayout.browserMinimumWidth
            let previewMinimum: CGFloat = bottom ? 220 : FinderWorkspaceLayout.previewMinimumWidth
            let extent = bottom ? viewport.size.height : viewport.size.width
            let minimum = fileMinimum + previewMinimum + 8
            let available = max(extent, minimum) - 8
            let fraction = liveFraction ?? (savedFraction.isFinite ? savedFraction : (bottom ? 0.45 : 0.64))
            let fileExtent = min(max(available * fraction, fileMinimum), available - previewMinimum)
            let layout = bottom ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            let content = layout {
                files().frame(width: bottom ? viewport.size.width : fileExtent,
                              height: bottom ? fileExtent : viewport.size.height)
                divider(available: available, fileExtent: fileExtent, minimum: fileMinimum, previewMinimum: previewMinimum)
                preview().frame(width: bottom ? viewport.size.width : available - fileExtent,
                                height: bottom ? available - fileExtent : viewport.size.height)
            }
            Group {
                if !showsPreview { files() }
                else if expanded { preview() }
                else if extent < minimum {
                    ScrollView(bottom ? .vertical : .horizontal) { content }
                } else { content }
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }.background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.055), radius: 12, y: 4)
            .onChange(of: resetRevision) { _ in liveFraction = nil; dragStart = nil }
            .onChange(of: placement) { _ in liveFraction = nil; dragStart = nil; NSCursor.arrow.set() }
    }
    private func divider(available: CGFloat, fileExtent: CGFloat, minimum: CGFloat, previewMinimum: CGFloat) -> some View {
        Color(nsColor: .controlBackgroundColor)
            .overlay { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: bottom ? nil : 1, height: bottom ? 1 : nil) }
            .frame(width: bottom ? nil : 8, height: bottom ? 8 : nil).contentShape(Rectangle())
            .onHover { active in (active ? (bottom ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight) : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = fileExtent }
                    let delta = bottom ? value.translation.height : value.translation.width
                    let size = min(max((dragStart ?? fileExtent) + delta, minimum), available - previewMinimum)
                    liveFraction = Double(size / available)
                }
                .onEnded { _ in
                    if let liveFraction { savedFraction = liveFraction }
                    liveFraction = nil; dragStart = nil; NSCursor.arrow.set()
                })
            .accessibilityElement().accessibilityLabel("Resize file list and preview")
            .accessibilityValue("File list \(Int((fileExtent / available * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.05 : -0.05
                savedFraction = min(max(Double(fileExtent / available) + step, Double(minimum / available)),
                    Double(1 - previewMinimum / available))
            }
            .help("Drag to resize the file list and preview. This layout is shared across drives.")
    }
}

/// A single toolbar order for every drive, including its disconnected state.
/// The smaller actions use icons so the path and primary action remain visible.
struct FinderBrowserToolbar<Location: View>: View {
    @Binding var viewMode: Int
    let zoom: Double
    let connected: Bool
    let canGoBack: Bool
    let canImport: Bool
    let canExport: Bool
    let canTrash: Bool
    let canCreate: Bool
    var share: (() -> Void)? = nil
    var canShare = false
    var merge: (() -> Void)? = nil
    var canMerge = false
    var containerName = "Folder"
    var importHelp = "Upload files or folders into this location"
    var exportHelp = "Download selected items to this Mac"
    var trashHelp = "Move selected items to Trash"
    var fileTypeFilter: Binding<BrowserFileFilter>? = nil
    var fileExtensions: [String] = []
    var hidesEmptyFolders: Binding<Bool>? = nil
    let back: () -> Void
    let search: () -> Void
    let importFiles: () -> Void
    let exportFiles: () -> Void
    let trash: () -> Void
    let create: () -> Void
    let refresh: () -> Void
    let adjustZoom: (Double) -> Void
    let resetZoom: () -> Void
    let sort: (BrowserSortColumn) -> Void
    @ViewBuilder var location: () -> Location

    var body: some View {
        GeometryReader { viewport in
        ScrollView(.horizontal) {
            controls.frame(width: max((fileTypeFilter == nil ? 660 : 740) + (merge == nil ? 0 : 34), viewport.size.width))
        }
        }.frame(height: 52)
    }
    private var controls: some View {
        HStack(spacing: 9) {
            tool("Back", "chevron.left", enabled: canGoBack, action: back)
            Image(systemName: "folder.fill").foregroundStyle(FinderAppearance.accent)
                .frame(width: 30, height: 30)
                .background(FinderAppearance.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            location().frame(minWidth: 70, maxWidth: .infinity, alignment: .leading)
            Picker("Browser view", selection: $viewMode) {
                Image(systemName: "list.bullet").accessibilityLabel("List").tag(0)
                Image(systemName: "square.grid.3x3.fill").accessibilityLabel("Thumbnails").tag(1)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 76).help("Switch between List and Thumbnails")
            Menu {
                Button("Make Items Larger") { adjustZoom(0.15) }.disabled(zoom >= 1.8)
                Button("Make Items Smaller") { adjustZoom(-0.15) }.disabled(zoom <= 0.75)
                Divider()
                Button("Actual Size", action: resetZoom).disabled(abs(zoom - 1) < 0.001)
                Text("Item size: \(Int((zoom * 100).rounded()))%")
                Divider()
                Menu("Sort By") {
                    Button("Name") { sort(.name) }
                    Button("Size") { sort(.size) }
                    Button("Kind") { sort(.kind) }
                    Button("Date Modified") { sort(.modified) }
                }
            } label: { Image(systemName: "textformat.size").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).fixedSize().help("Item size")
            tool("Find Files", "magnifyingglass", enabled: connected, action: search)
            if let fileTypeFilter {
                BrowserFileFilterMenu(filter: fileTypeFilter, extensions: fileExtensions, hidesEmptyFolders: hidesEmptyFolders)
                    .disabled(!connected)
            }
            Divider().frame(height: 18)
            tool("Upload", "arrow.up.circle", enabled: canImport, help: importHelp, action: importFiles)
            Button(action: exportFiles) { Label("Download", systemImage: "arrow.down.circle.fill").fixedSize() }
                .buttonStyle(.borderedProminent).pointingHandCursor().disabled(!canExport).help(exportHelp)
            if let share { tool("Create Shared Link", "link", enabled: canShare, action: share) }
            tool("Move Selected Items to Trash", "trash", enabled: canTrash, help: trashHelp, action: trash)
            tool("New \(containerName)", "folder.badge.plus", enabled: canCreate, action: create)
            if let merge {
                tool("Merge Selected \(containerName)s…", "arrow.triangle.merge", enabled: canMerge,
                     help: "Select two or more \(containerName.lowercased())s to merge", action: merge)
            }
            tool("Refresh", "arrow.clockwise", enabled: connected, action: refresh)
        }.finderCard(padding: 9).accessibilityElement(children: .contain).accessibilityLabel("Browser toolbar")
    }
    private func tool(_ title: String, _ symbol: String, enabled: Bool, help: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 24) }
            .disabled(!enabled).help(help ?? title).accessibilityLabel(title)
    }
}

struct FinderPreviewEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext").font(.system(size: 34)).foregroundStyle(FinderAppearance.accent.opacity(0.8))
                .frame(width: 74, height: 74).background(FinderAppearance.accent.opacity(0.08), in: Circle())
            Text("Select a file or folder").font(.title3.weight(.semibold))
            Text("Use ↑ or ↓ to select items. Press Space for Quick Look.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FinderDriveConnection: View {
    let kind: CloudDriveKind
    let busy: Bool
    let connect: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: kind.symbol).font(.system(size: 44)).foregroundStyle(FinderAppearance.accent)
                .frame(width: 96, height: 96).background(FinderAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            Text("Connect \(kind.title)").font(.title2.weight(.semibold))
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button(kind == .pikpak ? "Sign In to PikPak…" : kind == .photos ? "Allow Photos Access…" : kind == .local ? "Choose Folder or Disk…" : "Choose iCloud Drive Folder…", action: connect)
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
            if busy { ProgressView().controlSize(.small) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).finderCard(padding: 0)
    }
    private var description: String {
        switch kind {
        case .pikpak: return "Sign in to browse your files, open shared links and manage transfers. Your session is saved automatically."
        case .local: return "Choose a folder or disk on this Mac. Browse, organise and compare files using the same workspace."
        case .icloud: return "Choose iCloud Drive or a folder within it. Files and changes sync through the Apple Account on this Mac."
        case .photos: return "Allow access to browse photos, videos and albums. Uses the Apple Account already configured on this Mac."
        }
    }
}

struct FinderTransferHeader: View {
    @Binding var direction: Int
    let destination: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                directionPicker.frame(width: 350)
                Spacer(minLength: 0)
                destinationLabel
            }
            VStack(alignment: .leading, spacing: 8) {
                directionPicker.frame(maxWidth: 350)
                destinationLabel
            }
        }.finderCard(padding: 9)
    }

    private var directionPicker: some View {
        Picker("Transfer direction", selection: $direction) {
            Label("Downloads", systemImage: "arrow.down.circle.fill").tag(0)
            Label("Uploads", systemImage: "arrow.up.circle.fill").tag(1)
            Label("Torrents", systemImage: "arrow.down.doc").tag(2)
        }.labelsHidden().pickerStyle(.segmented)
    }

    private var destinationLabel: some View {
        Label(destination, systemImage: direction == 1 ? "folder.fill" : "externaldrive.fill")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .help(direction == 2 ? "Local BitTorrent downloads" : direction == 1 ? "Upload destination" : "Download destination")
    }
}

struct FinderTransferCanvas<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                content()
                    .environment(\.finderTransferViewport, viewport.size)
                    .frame(width: viewport.size.width, alignment: .topLeading)
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
            }.scrollIndicators(.automatic)
        }
    }
}

struct FinderTransferOverview<Setup: View, Progress: View>: View {
    @Environment(\.finderTransferViewport) private var viewport
    var emphasizeProgress = false
    @ViewBuilder var setup: () -> Setup
    @ViewBuilder var progress: () -> Progress
    var body: some View {
        let widths = FinderTransferGeometry.overviewCardWidths(for: viewport.width, emphasizeProgress: emphasizeProgress)
        let horizontal = widths != nil
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
            setup().frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                .frame(width: widths?.setup)
            progress().frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                .frame(width: widths?.progress)
        }
    }
}

extension View {
    func finderCard(padding: CGFloat) -> some View {
        self.padding(padding)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.075)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.045), radius: 10, y: 3)
    }
    func finderFooterSurface() -> some View {
        self.frame(height: FinderWorkspaceLayout.footerHeight)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain).accessibilityLabel("Workspace footer")
    }
}
