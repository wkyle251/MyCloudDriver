import AppKit
import SwiftUI

struct SimilarityResultsView: View {
    @ObservedObject var results: SimilarityResultsModel
    let report: SimilarityReport
    let coordinator: FileSimilarityCoordinator
    @State private var selectedMatchID: String?
    @State private var showsCoverage = false
    @State private var visibleMatchCount = 200
    private var photos: Bool { coordinator.externalTitle == CloudDriveKind.photos.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan results").font(.headline)
                    Text("\(results.index?.files.count ?? report.files?.count ?? 0) files · Select a file to compare")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !coordinator.duplicatesOnly {
                    HStack(spacing: 7) {
                        Text("Minimum").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $results.minimumScore, in: 0.05...1, step: 0.01).frame(width: 115)
                            .accessibilityLabel("Filter saved similarity scores")
                            .help("Filter saved scores from 5% to 100% without rescanning")
                        Text(String(format: "%.0f%%", results.minimumScore * 100)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 37, alignment: .trailing)
                    }.disabled(results.identicalOnly)
                    Picker("Match type", selection: $results.identicalOnly) {
                        Text("All matches").tag(false); Text("Identical").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 172)
                }
            }.padding(12)
            Divider()
            if results.isIndexing {
                ProgressView("Preparing the file tree…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search scanned files", text: $results.query).textFieldStyle(.plain)
                                .accessibilityLabel("Search scanned files")
                            if !results.query.isEmpty {
                                Button { results.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).help("Clear file search")
                            }
                        }.padding(10)
                        Divider()
                        if results.roots.isEmpty {
                            empty("No files to display", symbol: "doc.text.magnifyingglass", detail: results.query.isEmpty ? "Review scan coverage for skipped or unavailable files." : "Try a different file or folder name.")
                        } else {
                            SimilarityFileTree(roots: results.roots, selectedID: results.selectedID, searching: !results.query.isEmpty,
                                select: { results.select($0) }, preview: { preview($0) })
                        }
                        Divider()
                        Text("↑↓ Select file   Space Preview").font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    }.frame(minWidth: 250, idealWidth: 330, maxWidth: 460)
                    detail.frame(minWidth: 445, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        .onChange(of: results.selectedID) { _ in
            selectedMatchID = nil; visibleMatchCount = 200
            if coordinator.preview.isActive {
                if let file = results.selectedFile { preview(file) } else { coordinator.preview.close() }
            }
        }
        .onChange(of: results.minimumScore) { _ in visibleMatchCount = 200 }
        .onChange(of: results.identicalOnly) { _ in visibleMatchCount = 200 }
        .onDisappear { coordinator.preview.close() }
    }

    @ViewBuilder private var detail: some View {
        if let file = results.selectedFile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    SimilarityFileThumbnail(file: file, photos: photos).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REFERENCE FILE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(file.name).font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.path)
                        HStack(spacing: 12) {
                            Text(SimilarityScanProgress.bytes(file.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { preview(file) } label: { Label("Preview", systemImage: "eye") }.controlSize(.small)
                            Button("Open") { open(file) }.controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(14)
                Divider()
                HStack {
                    Text(coordinator.duplicatesOnly || results.identicalOnly ? "Identical copies" : "Similar files").font(.headline)
                    Text("\(results.related.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if results.isLoading { ProgressView().controlSize(.small); Text("Loading saved scores…").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Strongest matches first").font(.caption).foregroundStyle(.secondary) }
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
                    HStack(spacing: 12) {
                        SimilarityFileThumbnail(file: match.file, photos: photos).frame(width: 70, height: 70)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.file.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Text(match.file.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            HStack {
                                Button("Preview") { preview(match.file) }
                                Button("Open") { open(match.file) }
                                Button("Use as Reference") { results.select(match.id) }
                            }.controlSize(.small)
                        }
                        Spacer(minLength: 0)
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
            empty("Choose a reference file", symbol: "sidebar.left", detail: "Browse the scanned folders on the left. Select a file to see its related files, individual scores and previews.")
        }
    }

    private func matchRow(_ match: SimilarityRelatedFile) -> some View {
        HStack(spacing: 10) {
            Button {
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
        }.padding(.horizontal, 13).padding(.vertical, 10)
            .background(selectedMatchID == match.id ? FinderAppearance.accent.opacity(0.07) : Color.clear)
            .contextMenu {
                Button("Preview") { preview(match.file) }
                Button("Open") { open(match.file) }
                Button("Use as Reference") { results.select(match.id) }
                if let path = match.file.localPath {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
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
        return results.identicalOnly || coordinator.duplicatesOnly ? "No identical copies found" : "No matches at this score"
    }
    private func emptyDetail(_ file: SimilarityFile) -> String {
        if let issue = report.issues.first(where: { $0.path == file.path || $0.path == file.name }) { return issue.reason }
        if let state = file.state, state != "ready" { return "FileTwin reported \(state.replacingOccurrences(of: "_", with: " ")). Identical copies can still appear when a content hash is available." }
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
