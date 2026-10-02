import AppKit
import SwiftUI

struct SimilarityResultsView: View {
    @ObservedObject var results: SimilarityResultsModel
    let report: SimilarityReport
    let coordinator: FileSimilarityCoordinator
    @State private var selectedMatchID: String?
    @State private var showsCoverage = false
    @State private var visibleMatchCount = 200
    @State private var pendingTrash: SimilarityFile?
    @FocusState private var searchFocused: Bool
    private var photos: Bool { coordinator.externalTitle == CloudDriveKind.photos.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Similarity results").font(.headline)
                    Text("\(results.visibleFileCount.formatted()) files · \((report.scoresRetained ?? 0).formatted()) saved comparisons")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                summaryNumber(results.isGrouping ? "—" : results.groups.count.formatted(), title: "Groups")
                summaryNumber(results.isGrouping ? "—" : results.groupedFileCount.formatted(), title: "Grouped files")
                summaryNumber(results.isGrouping ? "—" : max(0, results.visibleFileCount - results.groupedFileCount).formatted(), title: "Outside groups")
            }.padding(14)
            Divider()
            HStack(spacing: 12) {
                Picker("Browse results", selection: $results.browseGroups) {
                    Text("Groups").tag(true); Text("All files").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 175)
                Spacer(minLength: 4)
                if !coordinator.duplicatesOnly {
                    HStack(spacing: 7) {
                        Text("Similarity").font(.callout)
                        Slider(value: Binding(get: { results.minimumScore }, set: { results.setMinimumScoreFromSlider($0) }), in: 0.05...1).frame(width: 115)
                            .accessibilityLabel("Filter saved similarity scores")
                            .accessibilityValue(String(format: "%.0f%%", results.minimumScore * 100))
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: results.setMinimumScoreFromSlider(results.minimumScore + 0.01)
                                case .decrement: results.setMinimumScoreFromSlider(results.minimumScore - 0.01)
                                @unknown default: break
                                }
                            }
                            .help("Filter saved scores from 5% to 100% without rescanning")
                        Text(String(format: "%.0f%%", results.minimumScore * 100)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 37, alignment: .trailing)
                    }.disabled(results.identicalOnly || !results.trashingIDs.isEmpty)
                    Picker("Match type", selection: $results.identicalOnly) {
                        Text("All matches").tag(false); Text("Identical").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 172).disabled(!results.trashingIDs.isEmpty)
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            HStack(spacing: 7) {
                if results.isGrouping { ProgressView().controlSize(.small) }
                else { Image(systemName: report.status == "completed" ? "checkmark.circle" : "info.circle") }
                Text(results.isGrouping ? "Regrouping saved comparisons…" : report.status == "cancelled"
                     ? "Scan cancelled. Files analysed so far are available; comparisons may be incomplete."
                     : report.status == "failed" ? "The scan could not finish. Review coverage before interpreting these results."
                     : coordinator.duplicatesOnly ? "Select a group or file to review identical copies."
                     : "Adjust 5–100% to regroup saved comparisons. No rescan needed.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if results.browseGroups, coordinator.keepSmallest != nil {
                    Menu {
                        if let plan = results.keepSmallestPlan() {
                            Button("Keep Smallest in \(plan.groupIDs.count == 1 ? "1 Group" : "All \(plan.groupIDs.count) Groups") — Move \(plan.removals.count) to \(photos ? "Recently Deleted" : "Trash")") {
                                keepSmallest(plan)
                            }
                        }
                    } label: {
                        Label("Group Actions", systemImage: "ellipsis.circle")
                    }.fixedSize().controlSize(.small)
                        .disabled(results.keepSmallestPlan() == nil)
                        .help("Applies to every group at this similarity, including groups hidden by search")
                }
            }.foregroundStyle(report.status == "cancelled" || report.status == "failed" ? Color.orange : Color.secondary)
                .padding(.horizontal, 14).padding(.bottom, 10)
            if !results.trashingIDs.isEmpty || results.fileActionMessage != nil || results.fileActionError != nil {
                HStack(spacing: 8) {
                    if !results.trashingIDs.isEmpty { ProgressView().controlSize(.small) }
                    else { Image(systemName: results.fileActionError == nil ? "checkmark.circle" : "exclamationmark.triangle") }
                    Text(!results.trashingIDs.isEmpty ? "Moving \(results.trashingIDs.count) \(results.trashingIDs.count == 1 ? "file" : "files") to \(photos ? "Recently Deleted" : "Trash")…"
                         : results.fileActionError ?? results.fileActionMessage ?? "")
                        .font(.caption).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if results.trashingIDs.isEmpty {
                        Button { results.fileActionMessage = nil; results.fileActionError = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Dismiss file action status")
                    }
                }.foregroundStyle(results.fileActionError == nil ? Color.secondary : .red)
                    .padding(12).background(FinderAppearance.accent.opacity(0.04))
            }
            if let error = results.groupingError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer(); Button("Retry Groups") { results.regroup(immediate: true) }.controlSize(.small)
                    Button("All Files") { results.showAllFiles() }.controlSize(.small)
                }.padding(10).background(Color.orange.opacity(0.07))
            }
            Divider()
            if results.isIndexing {
                ProgressView("Preparing the file tree…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(results.browseGroups ? "Find a file in groups" : "Search scanned files", text: $results.query).textFieldStyle(.plain)
                                .focused($searchFocused)
                                .accessibilityLabel("Search scanned files")
                            if !results.query.isEmpty {
                                Button { results.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).help("Clear file search")
                            }
                            if results.browseGroups {
                                Divider().frame(height: 16)
                                Button { results.setAllGroupsExpanded(true) } label: {
                                    Image(systemName: "chevron.down.2").frame(width: 20, height: 20)
                                }
                                .buttonStyle(.borderless).pointingHandCursor()
                                .help("Expand all groups").accessibilityLabel("Expand All Groups")
                                .disabled(results.isGrouping || results.roots.isEmpty)
                                Button { results.setAllGroupsExpanded(false) } label: {
                                    Image(systemName: "chevron.up.2").frame(width: 20, height: 20)
                                }
                                .buttonStyle(.borderless).pointingHandCursor()
                                .help("Collapse all groups").accessibilityLabel("Collapse All Groups")
                                .disabled(results.isGrouping || results.roots.isEmpty)
                            }
                        }.padding(10)
                        Divider()
                        if results.roots.isEmpty {
                            VStack(spacing: 0) {
                                empty(results.isGrouping ? "Preparing groups…" : results.browseGroups ? "No groups at this similarity" : "No files to display", symbol: "doc.text.magnifyingglass",
                                    detail: !results.query.isEmpty ? "Try a different file or folder name." : results.browseGroups
                                        ? "Lower the similarity or browse all scanned files, including files without a match." : "Review scan coverage for skipped or unavailable files.")
                                if results.browseGroups { Button("Browse All Files") { results.showAllFiles() }.padding(.bottom, 18) }
                            }
                        } else {
                            SimilarityFileTree(roots: results.roots, selectedID: results.selectedNodeID, searching: !results.query.isEmpty,
                                groupExpansion: results.browseGroups ? results.groupExpansion : nil,
                                select: { selectedMatchID = nil; results.selectNode($0) }, preview: { preview($0) })
                                .disabled(results.browseGroups && results.isGrouping)
                        }
                        Divider()
                        Text("↑↓ Select   Space Preview   ⌘⌫ Trash").font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    }.frame(minWidth: 250, idealWidth: 310, maxWidth: 380)
                    detail.frame(minWidth: 445, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        .background(SimilarityResultTrashShortcut(enabled: trashSelection.map(canTrash) ?? false) {
            if let file = trashSelection { requestTrash(file) }
        })
        .onChange(of: results.selectedID) { _ in
            selectedMatchID = nil; visibleMatchCount = 200
            if coordinator.preview.isActive {
                if let file = results.selectedFile { preview(file) } else { coordinator.preview.close() }
            }
        }
        .onChange(of: results.minimumScore) { _ in visibleMatchCount = 200 }
        .onChange(of: results.identicalOnly) { _ in visibleMatchCount = 200 }
        .confirmationDialog(photos ? "Move to Recently Deleted?" : "Move to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible, presenting: pendingTrash) { file in
                Button(photos ? "Move to Recently Deleted" : "Move to Trash", role: .destructive) {
                    pendingTrash = nil
                    guard let operation = coordinator.moveToTrash else { return }
                    coordinator.preview.close()
                    results.moveToTrash(file, using: operation)
                }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { pendingTrash = nil }.keyboardShortcut(.cancelAction)
            } message: { file in
                Text(trashConfirmation(file))
            }
        .onDisappear { coordinator.preview.close() }
    }

    @ViewBuilder private var detail: some View {
        if let group = results.selectedGroup {
            groupDetail(group)
        } else if let file = results.selectedFile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    SimilarityFileThumbnail(file: file, photos: photos).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REFERENCE FILE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(file.name).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.path)
                        Text(SimilarityScanProgress.bytes(file.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(14)
                fileActions(file).padding(.horizontal, 14).padding(.bottom, 12)
                Divider()
                HStack {
                    Text(coordinator.duplicatesOnly || results.identicalOnly ? "Identical copies" : results.showAllScores ? "Saved score row" : "Matches across all files").font(.headline)
                    Text("\(results.related.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if results.isLoading { ProgressView().controlSize(.small); Text("Loading saved scores…").font(.caption).foregroundStyle(.secondary) }
                    else if !coordinator.duplicatesOnly && !results.identicalOnly {
                        Toggle("All scores", isOn: $results.showAllScores).toggleStyle(.checkbox).controlSize(.small)
                            .help("Show every available score for this file, including scores below the grouping threshold")
                    }
                }.padding(.horizontal, 14).padding(.vertical, 11)
                if let error = results.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).font(.caption).lineLimit(3)
                        Spacer(minLength: 4); Button("Retry") { results.retry() }.controlSize(.small)
                    }.padding(12).background(Color.orange.opacity(0.07))
                }
                if results.related.isEmpty && !results.isLoading {
                    empty(emptyTitle(file), symbol: file.state == "ready" || file.state == nil ? "doc.text.magnifyingglass" : "exclamationmark.doc",
                        detail: emptyDetail(file))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results.related.prefix(visibleMatchCount)) { match in
                                matchRow(match)
                                Divider().padding(.leading, 64)
                            }
                            if results.related.count > visibleMatchCount {
                                HStack {
                                    Text("\(visibleMatchCount) of \(results.related.count) matches shown").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Show More") { visibleMatchCount += 200 }.controlSize(.small)
                                }.padding(13)
                            }
                        }
                    }
                }
                if let match = results.related.first(where: { $0.id == selectedMatchID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            SimilarityFileThumbnail(file: match.file, photos: photos).frame(width: 60, height: 60)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(match.file.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                Text(match.file.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                Button("Use as Reference") { selectReference(match.id) }.controlSize(.small)
                            }
                            Spacer(minLength: 0)
                        }
                        fileActions(match.file)
                    }.padding(12).background(FinderAppearance.accent.opacity(0.035))
                }
                if !results.unavailable.isEmpty || results.omitted > 0 {
                    Divider()
                    DisclosureGroup(isExpanded: $showsCoverage) {
                        Text(coverageDetail).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    } label: {
                        Text("Comparison coverage").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        } else {
            empty(results.browseGroups ? "Review a similarity group" : "Choose a reference file", symbol: "sidebar.left",
                detail: results.browseGroups ? "Select a group to review its files, or select a file to compare it with every other file in this scan."
                    : "Select any scanned file to see its saved comparisons and previews. Unavailable comparisons are kept separate from low scores.")
        }
    }

    private func summaryNumber(_ number: String, title: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(number).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(FinderAppearance.accent)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func groupDetail(_ group: SimilarityResultGroup) -> some View {
        let smallest = SimilarityKeepSmallestPlan.smallest(in: group.members)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: group.identical ? "doc.on.doc" : "square.stack.3d.up")
                    .font(.system(size: 25)).foregroundStyle(FinderAppearance.accent)
                    .frame(width: 50, height: 50).background(FinderAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Group \((results.groups.firstIndex(where: { $0.id == group.id }) ?? 0) + 1)").font(.title3.weight(.semibold))
                    Text("\(group.members.count) files · \(group.strengthLabel)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if results.isGrouping { ProgressView().controlSize(.small) }
            }.padding(16)
            Text(group.identical ? "These files have the same verified content hash."
                 : "Every pair in this group meets the selected similarity. Select a file to review its individual comparisons.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 14)
            if !results.allowsSizeBasedCleanup {
                Text("Original sizes are unavailable in Fast Previews. Use an Originals scan to choose the smallest file.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 14)
            }
            if coordinator.keepSmallest != nil, results.allowsSizeBasedCleanup, let keeper = smallest {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep \(keeper.name)").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            .help(keeper.path)
                        Text("Smallest: \(SimilarityScanProgress.bytes(keeper.bytes)) · Move \(group.members.count - 1) \(group.members.count == 2 ? "other file" : "other files") to \(photos ? "Recently Deleted" : "Trash")")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if let plan = results.keepSmallestPlan(groupID: group.id) { keepSmallest(plan) }
                    } label: { Label("Keep Smallest", systemImage: "trash") }
                        .disabled(results.keepSmallestPlan(groupID: group.id) == nil)
                        .help("Keep the displayed file and move the others in this group to \(photos ? "Recently Deleted" : "Trash"). Equal sizes are resolved by path, then file ID.")
                }.padding(12).background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(group.members) { file in
                        Button { selectReference(file.id) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                SimilarityFileThumbnail(file: file, photos: photos).frame(maxWidth: .infinity).frame(height: 95)
                                    .background(FinderAppearance.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                                Text(file.name).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle).foregroundStyle(.primary)
                                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    Text(SimilarityScanProgress.bytes(file.bytes)).font(.caption2).foregroundStyle(.secondary)
                                    if file.id == smallest?.id {
                                        Text("Smallest").font(.caption2.weight(.medium)).foregroundStyle(FinderAppearance.accent)
                                    }
                                    Spacer(); Image(systemName: "arrow.right").foregroundStyle(FinderAppearance.accent)
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHandCursor().help("Compare \(file.name) with all scanned files")
                            .accessibilityLabel("Compare \(file.name)")
                            .contextMenu {
                                Button("Preview") { preview(file) }
                                Button("Open") { open(file) }
                                Button("Show in Folder") { coordinator.reveal(file) }.disabled(coordinator.revealInBrowser == nil)
                                Divider()
                                trashButton(file)
                            }
                    }
                }.padding(14)
            }.disabled(results.isGrouping)
            Divider()
            Text("Groups are a review aid. Matching pairs can also exist across different groups; selecting a file always shows all its matches.")
                .font(.caption2).foregroundStyle(.secondary).padding(12)
        }
    }

    private func keepSmallest(_ plan: SimilarityKeepSmallestPlan) {
        guard let operation = coordinator.keepSmallest else { return }
        coordinator.preview.close()
        results.keepSmallest(plan, destination: photos ? "Recently Deleted" : "Trash", using: operation)
    }

    private func matchRow(_ match: SimilarityRelatedFile) -> some View {
        HStack(spacing: 10) {
            Button {
                searchFocused = false
                selectedMatchID = selectedMatchID == match.id ? nil : match.id
                if coordinator.preview.isActive { preview(match.file) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: match.file.symbol).font(.system(size: 21)).foregroundStyle(FinderAppearance.accent)
                        .frame(width: 34, height: 38).background(FinderAppearance.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.file.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        Text(match.file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(SimilarityScanProgress.bytes(match.file.bytes) + (match.identical ? " · Identical content" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(match.scoreLabel).font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(FinderAppearance.accent).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(FinderAppearance.accent.opacity(0.09), in: Capsule())
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor().help("Show details for \(match.file.name)")
                .accessibilityLabel("\(match.file.name), \(match.scoreLabel)\(match.identical ? ", identical content" : " similarity")")
            Button { preview(match.file) } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Preview \(match.file.name)")
            Button { coordinator.reveal(match.file) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).disabled(coordinator.revealInBrowser == nil)
                .help("Show \(match.file.name) in its drive folder")
                .accessibilityLabel("Show \(match.file.name) in Folder")
            trashButton(match.file, iconOnly: true).buttonStyle(.borderless)
        }.padding(.horizontal, 13).padding(.vertical, 10)
            .background(selectedMatchID == match.id ? FinderAppearance.accent.opacity(0.07) : Color.clear)
            .contextMenu {
                Button("Preview") { preview(match.file) }
                Button("Open") { open(match.file) }
                Button("Show in Folder") { coordinator.reveal(match.file) }.disabled(coordinator.revealInBrowser == nil)
                Button("Use as Reference") { selectReference(match.id) }
                if let path = match.file.localPath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Divider()
                trashButton(match.file)
            }
    }
    private func fileActions(_ file: SimilarityFile) -> some View {
        HStack(spacing: 10) {
            Button { coordinator.reveal(file) } label: { Label("Show in Folder", systemImage: "folder") }
                .disabled(coordinator.revealInBrowser == nil)
                .help("Bring this file’s drive window forward and select it in its folder")
            Button("Preview") { preview(file) }
            Button("Open") { open(file) }
            Spacer(minLength: 0)
            trashButton(file)
        }.controlSize(.small)
    }
    private func trashButton(_ file: SimilarityFile, iconOnly: Bool = false) -> some View {
        Button(role: .destructive) { requestTrash(file) } label: {
            if iconOnly { Image(systemName: "trash") }
            else { Label("Move to Trash", systemImage: "trash") }
        }
        .disabled(!canTrash(file))
        .help("Move \(file.name) to \(photos ? "Recently Deleted in Apple Photos" : "Trash")")
        .accessibilityLabel("Move \(file.name) to Trash")
    }
    private var trashSelection: SimilarityFile? {
        guard !results.isIndexing, !(results.browseGroups && results.isGrouping), results.selectedGroup == nil else { return nil }
        if let selectedMatchID { return results.related.first { $0.id == selectedMatchID }?.file }
        return results.selectedFile
    }
    private func selectReference(_ id: String) {
        searchFocused = false
        selectedMatchID = nil
        results.select(id)
    }
    private func canTrash(_ file: SimilarityFile) -> Bool {
        pendingTrash == nil && coordinator.moveToTrash != nil && results.trashingIDs.isEmpty && !results.trashedIDs.contains(file.id)
    }
    private func requestTrash(_ file: SimilarityFile) {
        guard canTrash(file) else { return }
        pendingTrash = file
    }
    private func trashConfirmation(_ file: SimilarityFile) -> String {
        if photos { return "Move “\(file.name)” to Recently Deleted in Apple Photos? This also affects iCloud Photos if enabled. Restore it from Photos → Recently Deleted." }
        if file.cloudId != nil { return "Move “\(file.name)” to PikPak Trash? You can undo this change in its drive window with Command-Z." }
        let sync = coordinator.externalTitle == CloudDriveKind.icloud.title ? " This change will sync to iCloud." : ""
        return "Move “\(file.name)” to Finder’s Trash?\(sync) You can undo this change in its drive window with Command-Z."
    }
    private func preview(_ file: SimilarityFile) {
        let reference = results.selectedFile
        let files = (reference.map { [$0] } ?? []) + results.related.map(\.file)
        coordinator.preview.move = { offset in
            let current = coordinator.preview.quickLook.itemID
            guard let index = files.firstIndex(where: { $0.id == current }), files.indices.contains(index + offset) else { return }
            let next = files[index + offset]
            selectedMatchID = next.id == reference?.id ? nil : next.id
            coordinator.preview.show(next, prepare: coordinator.preparePreview)
        }
        coordinator.preview.show(file, prepare: coordinator.preparePreview, in: NSApp.keyWindow)
    }
    private func open(_ file: SimilarityFile) {
        if let open = coordinator.openExternalFile { open(file) }
        else if let path = file.localPath { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else { coordinator.openCloudFile(file) }
    }
    private func emptyTitle(_ file: SimilarityFile) -> String {
        if results.error != nil { return "Scores are unavailable" }
        if let state = file.state, state != "ready" { return "No similarity score for this file" }
        if !results.trashedIDs.isEmpty { return results.identicalOnly || coordinator.duplicatesOnly ? "No remaining identical copies" : "No remaining matches at this score" }
        if !results.hasSavedComparisons && !coordinator.duplicatesOnly { return "Comparisons did not run" }
        return results.identicalOnly || coordinator.duplicatesOnly ? "No identical copies found" : "No matches at this score"
    }
    private func emptyDetail(_ file: SimilarityFile) -> String {
        if let issue = report.issues.first(where: { $0.path == file.path || $0.path == file.name }) { return issue.reason }
        if let state = file.state, state != "ready" { return "FileTwin reported \(state.replacingOccurrences(of: "_", with: " ")). Identical copies can still appear when a content hash is available." }
        if !results.trashedIDs.isEmpty { return "Files moved to Trash are hidden from results. Select another file to continue reviewing the scan." }
        if report.status != "completed" { return "This scan has incomplete coverage. Review the skipped files and comparison coverage before drawing conclusions." }
        return results.identicalOnly || coordinator.duplicatesOnly ? "No other file in this scan has the same verified content hash." : "Lower the minimum score to review more saved comparisons, or select another file. Different content types cannot always be compared."
    }
    private var coverageDetail: String {
        let labels = ["file_unavailable":"without usable analysis", "incompatible_profile":"with a different content type", "outside_scope":"outside the pair scope", "not_computed":"not computed"]
        let parts = results.unavailable.sorted { $0.key < $1.key }.map { "\($0.value.formatted()) \(labels[$0.key] ?? $0.key)" }
        return parts.joined(separator: " · ") + (results.omitted > 0 ? " · \(results.omitted) scores exceed the display limit" : "") + ". Missing scores are not treated as zero."
    }
    private func empty(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(FinderAppearance.accent.opacity(0.7))
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
