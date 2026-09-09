import AppKit
import SwiftUI

private struct SimilarityProgressView: View {
    @ObservedObject var model: SimilarityScanModel
    private var progress: SimilarityScanProgress { model.progress }
    private var steps: [SimilarityScanStage] {
        model.source == .cloud ? [.inventory, .downloading, .analysing, .comparison, .grouping]
            : [.inventory, .analysing, .comparison, .grouping]
    }
    private var stepIndex: Int { steps.firstIndex(of: progress.stage) ?? steps.count - 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 7) {
                            Image(systemName: index < stepIndex ? "checkmark.circle.fill" : index == stepIndex ? "circle.inset.filled" : "circle")
                            Text(step.stepTitle).font(.callout.weight(index == stepIndex ? .semibold : .regular))
                        }.foregroundStyle(index <= stepIndex ? FinderAppearance.accent : Color.secondary)
                        if index < steps.count - 1 {
                            Rectangle().fill(index < stepIndex ? FinderAppearance.accent.opacity(0.4) : Color.primary.opacity(0.10))
                                .frame(height: 1).padding(.horizontal, 12)
                        }
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(stepIndex + 1) of \(steps.count): \(progress.stage.title)")

                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: model.source.symbol).font(.system(size: 23))
                        .foregroundStyle(FinderAppearance.accent).frame(width: 48, height: 48)
                        .background(FinderAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isCancelling ? "Stopping scan…" : progress.stage.title).font(.title2.weight(.semibold))
                        Text(progress.completedLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(elapsed(at: context.date)).font(.title3.monospacedDigit().weight(.medium))
                            Text("Elapsed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(progress.stage.stepTitle) progress").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let label = progress.percentLabel {
                            Text(label).font(.callout.monospacedDigit().weight(.semibold))
                        } else {
                            Text(progress.stage == .inventory ? "Counting files…" : "In progress…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                            .accessibilityLabel("\(progress.stage.stepTitle) progress")
                    } else {
                        ProgressView().progressViewStyle(.linear).accessibilityLabel(progress.stage.title)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: progress.currentName == nil ? "waveform.path" : "doc")
                            .foregroundStyle(FinderAppearance.accent)
                        Text(progress.currentName ?? stageDetail).font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .help(progress.currentName ?? stageDetail)
                        Spacer(minLength: 0)
                        if progress.currentName != nil { ProgressView().controlSize(.small) }
                    }
                    if progress.currentName != nil {
                        HStack {
                            Text(progress.currentOperation).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if progress.currentSize > 0 || progress.currentBytes > 0 {
                                Text(progress.currentByteLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))

                HStack(spacing: 0) {
                    metric("Analysed", value: progress.analysed.formatted())
                    Divider().frame(height: 34).padding(.horizontal, 20)
                    metric("Skipped", value: progress.skipped.formatted())
                    Divider().frame(height: 34).padding(.horizontal, 20)
                    metric("Matching pairs", value: progress.matches.formatted())
                    if model.source == .cloud {
                        Divider().frame(height: 34).padding(.horizontal, 20)
                        metric("Downloaded", value: SimilarityScanProgress.bytes(progress.downloadedBytes))
                    }
                }
                Text(model.isCancelling ? "Finishing the current operation and clearing temporary files."
                     : "Keep browsing while this runs. You can close this window and follow progress in the status footer.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
    }
    private var stageDetail: String {
        switch progress.stage {
        case .inventory: return "Building the file list before reading content"
        case .downloading: return "Preparing temporary cloud copies"
        case .analysing: return "Preparing the next file"
        case .comparison: return "Checking content similarity and identical copies"
        case .grouping: return "Organising matching files into review groups"
        case .finishing: return "Your results will appear here"
        }
    }
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.startedAt ?? date)))
        return seconds >= 3600 ? String(format: "%dh %02dm %02ds", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : seconds >= 60 ? String(format: "%dm %02ds", seconds / 60, seconds % 60) : "\(seconds)s"
    }
}

struct FileSimilarityView: View {
    @ObservedObject var coordinator: FileSimilarityCoordinator

    var body: some View {
        GeometryReader { geometry in
          VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 25)).foregroundStyle(FinderAppearance.accent)
                    .frame(width: 50, height: 50)
                    .background(FinderAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find Similar Files").font(.title2.weight(.semibold))
                    Text("Compare content. Review related files together.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Scan source", selection: $coordinator.source) {
                    ForEach(SimilaritySource.allCases) { source in Text(source.title).tag(source) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245).help("Cloud and local scans have separate scopes and results")
            }.padding(22)
            Divider()
            SimilarityScanView(model: coordinator.source == .cloud ? coordinator.cloud : coordinator.local,
                coordinator: coordinator).id(coordinator.source)
          }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(minWidth: 900, idealWidth: 1080, minHeight: 710, idealHeight: 800)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(FinderAppearance.accent).accentColor(FinderAppearance.accent)
        .buttonStyle(FinderButtonStyle())
    }
}

private struct SimilarityScanView: View {
    @ObservedObject var model: SimilarityScanModel
    let coordinator: FileSimilarityCoordinator
    @State private var selectedGroupID: String?
    @State private var groupFilter = 0
    @State private var showsIssues = false

    private var groups: [SimilarityGroup] {
        (model.report?.groups ?? []).filter { groupFilter == 0 || (groupFilter == 1 ? !$0.isExact : $0.isExact) }
    }
    private var selectedGroup: SimilarityGroup? { groups.first { $0.id == selectedGroupID } ?? groups.first }

    var body: some View {
        VStack(spacing: 14) {
            scopeCard
            scanControls
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss message")
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            resultArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }.padding(18)
        .onReceive(model.$report) { report in selectedGroupID = report?.groups.first?.id; groupFilter = 0 }
        .onChange(of: groupFilter) { _ in selectedGroupID = groups.first?.id }
        .sheet(isPresented: $showsIssues) { issuesSheet }
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.source.symbol).foregroundStyle(FinderAppearance.accent)
                Text(model.source == .cloud ? "Cloud scan scope" : "Files and folders on this Mac").font(.headline)
                Spacer()
                if model.source == .cloud {
                    Button("Use Browser Folder") { coordinator.useBrowserSelection(false) }
                        .help("Recursively scan the folder currently open in Browser")
                    Button("Use Browser Selection") { coordinator.useBrowserSelection(true) }
                        .help("Compare the selected cloud files and all contents of selected folders")
                } else {
                    Button { model.chooseLocalFiles() } label: { Label("Choose Files or Folders…", systemImage: "plus") }
                }
            }.disabled(model.isRunning)
            scopeLocations
            Text(model.source == .cloud
                 ? "Cloud files are downloaded temporarily for analysis, then removed. Choose a scope in Browser; local files are compared in a separate scan."
                 : "Selected folders include their subfolders. Analysis runs on this Mac; local file content is not uploaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var scopeLocations: some View {
        let isEmpty = model.source == .local ? model.localURLs.isEmpty : model.cloudRoots.isEmpty
        if isEmpty {
            Text(model.source == .cloud ? "Sign in from Settings → Accounts, then choose a folder in Browser."
                 : "Choose two or more files, or a folder containing files to compare.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.source == .cloud {
                        ForEach(model.cloudRoots) { root in
                            scopeRow(root.path == "/" ? "All PikPak files" : root.path, symbol: root.isFolder ? "folder" : "doc") {
                                model.cloudRoots.removeAll { $0.id == root.id }
                            }
                        }
                    } else {
                        ForEach(model.localURLs, id: \.self) { url in
                            scopeRow(url.path, symbol: "folder") { model.localURLs.removeAll { $0 == url } }
                        }
                    }
                }
            }.frame(height: min(60, CGFloat(max(1, model.source == .cloud ? model.cloudRoots.count : model.localURLs.count)) * 26))
        }
    }

    private func scopeRow(_ path: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(FinderAppearance.accent)
            Text(path).lineLimit(1).truncationMode(.middle).help(path)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).disabled(model.isRunning).help("Remove this location from the scan")
        }.padding(.horizontal, 3).frame(height: 22)
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONTENT TYPES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        familyToggle("text", "Documents", "doc.text")
                        familyToggle("image", "Images", "photo")
                        familyToggle("audio", "Audio", "waveform")
                        familyToggle("video", "Video", "film")
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("MINIMUM SCORE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", model.threshold * 100)).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: $model.threshold, in: 0.05...1, step: 0.01).frame(width: 185).disabled(model.isRunning)
                        .accessibilityLabel("Minimum similarity score")
                        .accessibilityValue(String(format: "%.0f percent", model.threshold * 100))
                        .help("Choose a score from 5% to 100%. Higher scores show closer matches. Scores are experimental cosine similarity, not probabilities.")
                }
                if model.isRunning {
                    Button("Cancel Scan") { model.cancel() }.disabled(model.isCancelling).frame(width: 112)
                } else {
                    Button { coordinator.start(model) } label: { Label("Start Scan", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).disabled(!model.canStart).frame(width: 112)
                        .help("Start a background scan of the selected locations")
                }
            }
            HStack {
                Toggle("Include byte-identical copies (all file types)", isOn: $model.exactDuplicates).disabled(model.isRunning)
                    .font(.callout).help("Also compare SHA-256 content hashes, including formats without a similarity decoder")
                Spacer()
                Toggle("Include hidden files", isOn: $model.includeHidden)
                    .font(.callout).disabled(model.isRunning)
            }
            if SimilarityScanModel.mediaTool("ffmpeg") == nil || SimilarityScanModel.mediaTool("ffprobe") == nil {
                Text("Audio, video and HEIF images require FFmpeg 9 and ffprobe on this Mac. Missing decoders are reported as skipped files.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !SimilarityScanModel.visualSimilarityAvailable {
                Text("Image and video similarity requires macOS 14 or later. Document, audio and byte-identical comparisons are available on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func familyToggle(_ family: String, _ label: String, _ symbol: String) -> some View {
        Toggle(isOn: Binding(get: { model.families.contains(family) }, set: { selected in
            if selected { model.families.insert(family) } else { model.families.remove(family) }
        })) { Label(label, systemImage: symbol) }
            .toggleStyle(.button).disabled(model.isRunning
                || (["image", "video"].contains(family) && !SimilarityScanModel.visualSimilarityAvailable))
            .help(family == "text" ? "UTF-8 text, DOCX and PDFs with a text layer" : "Compare \(label.lowercased()) by content")
    }

    @ViewBuilder private var resultArea: some View {
        if model.isRunning {
            SimilarityProgressView(model: model)
        } else if let report = model.report {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.totalGroups.formatted()) match groups").font(.headline)
                        Text("Last scan · \(report.scope.joined(separator: ", ")) · minimum score \(String(format: "%.0f%%", report.threshold * 100))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(report.scope.joined(separator: "\n"))
                    }
                    Spacer()
                    Picker("Match type", selection: $groupFilter) {
                        Text("All").tag(0); Text("Similar").tag(1); Text("Identical").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                }.padding(12)
                Divider()
                if groups.isEmpty {
                    emptyState(symbol: "checkmark.circle", title: report.status == "cancelled" ? "Scan cancelled" : "No matches to show",
                               message: report.skippedFiles > 0 ? "Some files were skipped. Review coverage before drawing conclusions." : "Try a lower minimum score or choose more files.")
                } else {
                    GeometryReader { geometry in
                        HSplitView {
                            groupList.frame(minWidth: 245, idealWidth: 305, maxWidth: 390)
                            if let group = selectedGroup { memberList(group).frame(minWidth: 400, maxWidth: .infinity) }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        } else {
            emptyState(symbol: "doc.on.doc", title: "Find related content, even with different names",
                       message: "Choose a scope and start a scan. Matches stay grouped here for you to review.")
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var groupList: some View {
        List(selection: $selectedGroupID) {
            ForEach(groups) { group in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: group.isExact ? "equal.square" : group.members.first?.symbol ?? "doc")
                        .font(.title3).foregroundStyle(FinderAppearance.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.title).lineLimit(1).truncationMode(.middle).font(.callout.weight(.medium))
                        Text("\(group.memberCount) files · \(group.scoreLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6).tag(group.id)
            }
        }.listStyle(.inset)
    }

    private func memberList(_ group: SimilarityGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(group.isExact ? "Byte-identical copies" : "Similar content").font(.headline)
                    Spacer()
                    Text(group.scoreLabel).font(.caption.weight(.semibold)).foregroundStyle(FinderAppearance.accent)
                }
                Text(group.isExact ? "These files have the same SHA-256 content hash."
                     : "Every pair in this group meets the scan’s score threshold. Review before making changes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(15)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(group.members) { file in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: file.symbol).font(.title2).foregroundStyle(FinderAppearance.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(file.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(file.path)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.bytes), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if let path = file.localPath {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "folder") }
                                    .help("Show \(file.name) in Finder")
                            }
                            Button("Open") { open(file) }.disabled(file.localPath == nil && file.cloudId == nil)
                                .help(model.source == .local ? "Open this file in its default app" : "Fetch this cloud file and open it in its default app")
                        }.padding(13)
                        Divider().padding(.leading, 53)
                    }
                }
            }
            if group.members.count < group.memberCount {
                Text("Showing \(group.members.count) of \(group.memberCount) files. Scan a smaller scope to review the remaining members.")
                    .font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    private func open(_ file: SimilarityFile) {
        if let path = file.localPath {
            if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) { model.error = "This file could not be opened. It may have moved since the scan." }
        } else { coordinator.openCloudFile(file) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let report = model.report {
                HStack(spacing: 12) {
                    Image(systemName: report.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(report.status == "completed" ? Color.green : Color.orange)
                    Text("\(report.analysedFiles.formatted()) analysed · \(report.skippedFiles.formatted()) skipped · \(Int(report.elapsedSeconds))s")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Coverage & Skipped Files…") { showsIssues = true }
                    Button("Export Results…") { model.exportReport() }
                }
                if report.truncated {
                    Text("Showing the first \(report.groups.count) groups, up to 20,000 members. Narrow the scan to review remaining matches. Exports contain the displayed results.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Powered by FileTwin · Scores are experimental, not probabilities. Image/video matching uses visual content; text extraction does not include OCR.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Scan Coverage").font(.title2.weight(.semibold)); Spacer(); Button("Done") { showsIssues = false } }
            if let report = model.report {
                Text(report.coverage).font(.callout).textSelection(.enabled)
                Text("\(report.scannedFiles.formatted()) discovered · \(report.analysedFiles.formatted()) analysed · \(report.skippedFiles.formatted()) skipped")
                    .foregroundStyle(.secondary)
                if !report.issues.isEmpty {
                    List(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.path).font(.callout.weight(.medium)).lineLimit(2).truncationMode(.middle)
                            Text(issue.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                } else { Text("No skipped items were reported.").foregroundStyle(.secondary); Spacer() }
                Text("Up to 500 issues are listed. Unsupported formats can still appear in byte-identical groups. Audio uses sampled sound; video uses sampled frames, without audio or sequence order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 690, height: 490)
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(FinderAppearance.accent.opacity(0.7))
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
