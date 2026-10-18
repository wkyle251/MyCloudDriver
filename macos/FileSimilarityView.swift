import AppKit
import SwiftUI

enum SimilarityRecoveryCountdown {
    static func interval(until deadline: Date, now: Date = Date()) -> ClosedRange<Date> {
        now...max(now, deadline)
    }
}

private struct SimilarityProgressView: View {
    @ObservedObject var model: SimilarityScanModel
    var scrollToDownloads: () -> Void
    @State private var showDownloadList = true
    private var progress: SimilarityScanProgress { model.progress }
    private var steps: [SimilarityScanStage] {
        model.externalDuplicatesOnly ? [.inventory, .downloading, .analysing, .comparison, .finishing]
            : [.analysing, .comparison, .finishing]
    }
    private var stepIndex: Int { progress.stage == .inventory && !model.externalDuplicatesOnly ? 0 : steps.firstIndex(of: progress.stage) ?? steps.count - 1 }

    var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 7) {
                            Image(systemName: index < stepIndex ? "checkmark.circle.fill" : index == stepIndex ? "circle.inset.filled" : "circle")
                            Text(step == .analysing && !model.externalDuplicatesOnly ? "Find & Analyse" : step.stepTitle)
                                .font(.callout.weight(index == stepIndex ? .semibold : .regular))
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
                        Text(model.isPaused ? "Scan paused · downloads retained" : model.isFinishing ? "Finishing current analysis…" : model.isCancelling ? "Deleting scan…" : progress.displayTitle).font(.title2.weight(.semibold))
                        Text(progress.completedLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        if progress.downloadCount > 0 {
                            Button("View Downloads (\(progress.downloadCount.formatted()))") {
                                showDownloadList = true
                                scrollToDownloads()
                            }.buttonStyle(.borderless).font(.callout)
                        }
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(elapsed(at: context.date)).font(.title3.monospacedDigit().weight(.medium))
                            Text("Active scan time").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.externalDuplicatesOnly && (progress.stage == .inventory || progress.stage == .analysing) {
                    VStack(alignment: .leading, spacing: 15) {
                      HStack(spacing: 22) {
                        metric(progress.discoveryComplete ? "Discovery complete" : model.isPaused ? "Files found" : "Finding files…", value: progress.foundFiles.formatted())
                        Divider().frame(height: 34)
                        metric("Queued", value: progress.queuedFiles.formatted())
                            .help("All waiting files, including ready originals and files waiting for downloads or memory.")
                        Divider().frame(height: 34)
                        metric("Analysing", value: progress.encodingFiles.formatted())
                            .help("Files hashing or analysing now, using Analysis RAM. Ready files start when their estimated memory needs fit the analysis RAM budget.")
                        Divider().frame(height: 34)
                        metric("Processed", value: progress.completed.formatted())
                      }
                      if progress.hasWorkPhases {
                        Divider()
                        HStack(alignment: .top, spacing: 22) {
                            VStack(alignment: .leading, spacing: 8) {
                                metric(model.hasRemoteSources ? "Download RAM reserved" : "Read RAM reserved", value: progress.originalMemoryLabel)
                                    .help("RAM reserved only while originals are downloaded or copied from disk, or waiting to enter Analysis RAM. Once a complete original is admitted to hashing, its buffer moves to Analysis RAM without a second copy. Reservations are not measured process memory.")
                                if progress.originalMemoryLimit > 0 {
                                    ProgressView(value: progress.originalMemoryFraction).progressViewStyle(.linear)
                                        .accessibilityLabel("Download RAM reserved")
                                }
                            }.frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 8) {
                                metric("Analysis RAM reserved", value: progress.analysisMemoryLabel)
                                    .help("Complete originals being hashed or analysed, plus memory reserved for calculations, decoders and required copies. Download/Read RAM is released before hashing starts. This is an allowance, not measured process RAM.")
                                if progress.memoryScheduling && progress.analysisMemoryLimit > 0 {
                                    ProgressView(value: progress.analysisMemoryFraction).progressViewStyle(.linear)
                                        .accessibilityLabel("Analysis RAM reserved")
                                }
                            }.frame(maxWidth: .infinity)
                            metric("Ready for analysis", value: progress.readyFiles.formatted())
                                .help("Fully read originals waiting to enter Analysis RAM. File paths still waiting to be read are shown separately below.")
                            VStack(alignment: .leading, spacing: 8) {
                                metric("Reading", value: progress.readingFiles.formatted())
                                if let hashing = progress.hashingFiles {
                                    Text("\(hashing.formatted()) hashing in Analysis RAM").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            let downloading = model.hasRemoteSources
                            let speed = downloading ? progress.downloadSpeed : model.readSpeed
                            let rateBytes = SafeDisplayNumber.bytes(speed)
                            Text("Download speed: \(rateBytes == 0 ? "0 B/s" : SimilarityScanProgress.bytes(rateBytes) + "/s")")
                                .help("Bytes arriving from the source drive or service into RAM. Hashing and analysis reads are excluded.")
                            Spacer()
                            if !downloading, let bytes = progress.originalBytesRead {
                                Text("\(SimilarityScanProgress.bytes(bytes)) read")
                            }
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if progress.originalMemoryLimit > 0 {
                            HStack {
                                Text(!model.hasRemoteSources
                                     ? "\(progress.readingFiles.formatted()) reading · \(progress.availableOriginalMemoryLabel) available"
                                     : "\(progress.fetchingFiles.formatted()) \(model.isPaused ? "downloads paused" : model.nativeScope?.drive == .photos ? "Photos requests" : "downloading") · \(progress.availableOriginalMemoryLabel) available")
                                Spacer()
                                Text("\(SimilarityScanProgress.memoryGB(progress.analysisMemoryLimit)) for analysis")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        if !progress.waitingSummary.isEmpty {
                            Text(progress.waitingSummary)
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if (progress.memoryPressure ?? 1) >= 2 {
                            Text((progress.memoryPressure ?? 1) >= 4 ? "Waiting for system memory pressure to ease. Downloaded data stays in RAM."
                                 : "System memory is under pressure. Pausing new downloads while analysis drains the buffer.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if progress.analysisMemoryLimit > 0 && progress.analysisMemoryBytes > progress.analysisMemoryLimit {
                            Text("Memory allowance is adapting. Active analysis finishes before more files are admitted.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if model.source == .cloud && progress.originalMemoryLimit > 0 {
                            Text("Downloads share RAM as data arrives. Starting analysis moves each original to Analysis RAM, freeing space for more downloads.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                      }
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }

                if progress.usesCloudByteProgress || progress.usesOnDemandCloudProgress || ![.inventory, .analysing, .comparison].contains(progress.stage) {
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(progress.progressTitle).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let label = progress.percentLabel {
                            Text(label).font(.callout.monospacedDigit().weight(.semibold))
                        } else {
                            Text(model.isPaused ? "Paused" : progress.stage == .inventory ? "Counting files…" : "In progress…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                            .accessibilityLabel(progress.progressTitle)
                    } else if model.isPaused {
                        ProgressView(value: 0).progressViewStyle(.linear).accessibilityLabel("Scan paused")
                    } else {
                        ProgressView().progressViewStyle(.linear).accessibilityLabel(progress.stage.title)
                    }
                    if progress.usesCloudByteProgress || progress.usesOnDemandCloudProgress, let label = progress.cloudByteLabel {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let estimate = progress.cloudDownloadTimeLabel(at: context.date,
                                running: model.isRunning && !model.isPausing && !model.isCancelling,
                                restoring: model.isRestoringProgress) {
                                Label(estimate, systemImage: "clock")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help("Estimated from the remaining cloud file size and recent total download speed. Cached and skipped files reduce the remaining size. Months use 30 days. Analysis and comparison may continue after downloads finish.")
                            }
                        }
                    }
                  }
                }

                SimilarityProcessingView(progress: progress, history: model.processingSpeed,
                    running: model.isRunning && !model.isPausing && !model.isCancelling, restoring: model.isRestoringProgress)

                if progress.hasDownloadTelemetry {
                    SimilarityDownloadsView(progress: progress, running: model.isRunning && !model.isPausing && !model.isCancelling, expanded: $showDownloadList)
                        .id("similarity-downloads")
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: model.isPaused ? "pause.circle" : progress.currentName == nil ? "waveform.path" : "doc")
                            .foregroundStyle(FinderAppearance.accent)
                        Text(model.isPaused ? "Downloads and queued files are retained in RAM" : progress.currentName ?? stageDetail).font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .help(progress.currentName ?? stageDetail)
                        Spacer(minLength: 0)
                        if progress.currentName != nil && !model.isPaused { ProgressView().controlSize(.small) }
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
                    metric("Unsupported", value: progress.unsupportedFiles.formatted())
                    Divider().frame(height: 34).padding(.horizontal, 20)
                    metric("Failed", value: progress.failedFiles.formatted())
                    Divider().frame(height: 34).padding(.horizontal, 20)
                    metric(model.externalDuplicatesOnly ? "Identical pairs" : "Scores saved", value: (model.externalDuplicatesOnly ? progress.matches : progress.scoresRetained).formatted())
                    if model.source == .cloud {
                        Divider().frame(height: 34).padding(.horizontal, 20)
                        metric("Downloaded", value: SimilarityScanProgress.bytes(progress.downloadedBytes))
                    } else {
                        Divider().frame(height: 34).padding(.horizontal, 20)
                        metric("Read", value: SimilarityScanProgress.bytes(progress.bytesRead))
                    }
                }
                if !model.externalDuplicatesOnly && (progress.vectorsEncoded > 0 || progress.cacheHits > 0) {
                    Label("\(progress.vectorsEncoded.formatted()) newly analysed · \(progress.cacheHits.formatted()) reused", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Unchanged file IDs and revisions reuse saved vectors before downloading. New or changed files are read and checked by content hash.")
                }
                if model.runResources != nil && !model.externalDuplicatesOnly {
                    Label("Automatic memory", systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Ready files start when their estimated RAM fits. Larger decoders reserve more memory; reservations are released when each file finishes.")
                }
                Text(model.isPaused ? "Keep this app open to retain downloads in RAM. Quitting or a helper crash releases RAM; saved analysis can still be resumed. Only Delete Scan removes saved progress."
                     : model.isFinishing ? "Finishing files already being analysed, then creating a report. Remaining files can be scanned later with Resume Scan." : model.isCancelling ? "Deleting this scan record and releasing original buffers."
                     : "Keep browsing while this runs. Closing this window pauses and saves the scan. Delete Report removes the saved scan record and results.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
    }
    private var stageDetail: String {
        if model.isRestoringProgress { return "Restoring saved progress and checking cached files…" }
        switch progress.stage {
        case .checking: return "New files will be analysed and removed files excluded before results are finalized"
        case .inventory: return "Building the file list before reading content"
        case .downloading: return "Fetching originals into memory"
        case .analysing: return progress.hasWorkPhases ? progress.phaseSummary : progress.total == nil ? "Discovering and analysing files · total not known yet" : "Analysing the file inventory"
        case .comparison: return "\(progress.pairsCompared.formatted()) compatible comparisons · saving individual scores"
        case .grouping: return "Organising identical-copy evidence"
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
        let seconds = max(0, Int(model.elapsedSeconds(at: date)))
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
                    Text(coordinator.activeCoordinator.duplicatesOnly ? "Check for Duplicates" : coordinator.activeCoordinator.acrossDrives != nil ? "Find Similarity Across Drives" : "Find Similar Files").font(.title2.weight(.semibold))
                    Text(coordinator.activeCoordinator.duplicatesOnly ? "Review files with identical content." : "Scan once. Group, compare and review.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            SimilarityScanView(model: coordinator.activeModel, coordinator: coordinator.activeCoordinator)
                .id(coordinator.selectedDriveID + coordinator.activeModel.sessionID.uuidString)
          }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(minWidth: 940, idealWidth: 1320, minHeight: 740, idealHeight: 900)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(FinderAppearance.accent).accentColor(FinderAppearance.accent)
        .buttonStyle(FinderButtonStyle())
    }
}

private struct SimilarityScanView: View {
    @ObservedObject var model: SimilarityScanModel
    @ObservedObject var coordinator: FileSimilarityCoordinator
    @State private var showsScanSettings = true
    @State private var showsIssues = false
    @State private var showsResources = false
    @State private var resourceSettings = SimilarityResourceSettings.current
    @State private var showsActiveDetails = false

    private var hasActiveScan: Bool { model.isRunning || model.isPaused }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                if model.report != nil && !hasActiveScan {
                    pageContent(scroll: scroll)
                } else {
                    ScrollView {
                        pageContent(scroll: scroll)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }.accessibilityIdentifier("similarity-scan-page")
                }
            }
        }
        .onReceive(model.$report) { report in
            showsScanSettings = report == nil
            coordinator.preview.close()
        }
        .onReceive(model.$sessionID.dropFirst()) { _ in
            showsScanSettings = true; showsActiveDetails = false; showsIssues = false; showsResources = false
            resourceSettings = .current; coordinator.preview.close()
        }
        .onChange(of: model.isRunning) { running in
            if running { showsActiveDetails = false }
        }
        .sheet(isPresented: $showsIssues) { issuesSheet }
        .sheet(item: $coordinator.scopePicker) { picker in
            SimilarityScopePickerView(model: picker) { coordinator.scopePicker = nil }
        }
        .sheet(isPresented: $showsResources) {
            SimilarityResourceSettingsView(settings: resourceSettings) { value in
                value.save(); resourceSettings = value; showsResources = false
            } cancel: { showsResources = false }
        }
    }

    private func pageContent(scroll: ScrollViewProxy) -> some View {
        VStack(spacing: 14) {
            if !model.isRunning && !model.isPaused && !model.recoverableSessions.isEmpty {
                VStack(alignment:.leading,spacing:10) {
                    Label("Saved scans",systemImage:"clock.arrow.circlepath").font(.headline)
                    ForEach(model.recoverableSessions) { session in
                        HStack {
                            VStack(alignment:.leading,spacing:3) {
                                Text(session.scope).lineLimit(1).truncationMode(.middle)
                                Text(session.updatedAt,style:.date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(["completed","partial","failed","finished"].contains(session.state) ? "Open Report" : "Resume") { coordinator.resume(model,session:session) }
                            Button("Delete Report") { coordinator.discardRecovery(model,session:session) }
                                .help("Remove this saved scan and its results; original files are kept")
                        }
                    }
                }.padding(14).background(FinderAppearance.accent.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
            }
            if model.report != nil && !hasActiveScan {
                HStack {
                    Label(model.report?.scope.joined(separator: ", ") ?? model.scopeLabel, systemImage: coordinator.externalTitle == nil ? model.source.symbol : coordinator.externalSymbol)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { showsScanSettings.toggle() } label: {
                        Label("Scan Settings", systemImage: showsScanSettings ? "chevron.up" : "slider.horizontal.3")
                    }
                    if model.canResumeReport {
                        Button("Resume Scan") { coordinator.resume(model) }
                            .help("Continue the saved scan, reusing completed analysis")
                    }
                    Button("Scan Again") { coordinator.start(model) }.disabled(!model.canStart)
                    Button("Delete Report") { model.clearSession() }.help("Delete this saved scan record and report; files on the drive are kept")
                }
            }
            if hasActiveScan {
                activeScanControls
                if showsActiveDetails { scopeCard }
            } else if showsScanSettings || model.report == nil {
                scopeCard
                scanControls
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss message")
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            resultArea(scroll: scroll).frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }.padding(18)
    }

    private var activeScanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(model.scopeLabel, systemImage: model.externalTitle == nil ? model.source.symbol : coordinator.externalSymbol)
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(model.scopeLabel)
                Spacer(minLength: 8)
                scanActionButtons
            }
            HStack(spacing: 10) {
                if model.runResources != nil && !coordinator.duplicatesOnly {
                    Label("Automatic memory", systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !coordinator.duplicatesOnly {
                    Text("\(Int((model.threshold * 100).rounded()))% similarity")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { showsActiveDetails.toggle() } label: {
                    Label("Scan Details", systemImage: showsActiveDetails ? "chevron.up" : "chevron.down")
                }.buttonStyle(.borderless)
            }
            if model.usesPhotosPreviews {
                Text("Fast Previews · Photo previews and video thumbnails · Visual matches only")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsActiveDetails {
                Text("All supported files\(model.exactDuplicates ? " · Includes identical copies" : "") · Dotfiles excluded")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.processingLabel.isEmpty { Text(model.processingLabel).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
    }

    private func openResourceSettings() {
        guard !hasActiveScan else { return }
        resourceSettings = .current
        showsResources = true
    }

    @ViewBuilder private var scopeCard: some View {
        if let across = coordinator.acrossDrives {
            SimilarityAcrossDriveScopeView(across: across)
        } else {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.source.symbol).foregroundStyle(FinderAppearance.accent)
                Text(model.externalTitle.map { "\($0) scan scope" } ?? (model.source == .cloud ? "Cloud scan scope" : "Files and folders on this Mac")).font(.headline)
                Spacer()
                if let chooseFolder = coordinator.chooseFolderScope {
                    Button(action: chooseFolder) { Label(coordinator.scopePickerButtonTitle, systemImage: "folder.badge.plus") }
                        .help("Choose the scan location independently of Browser")
                } else {
                    Button { model.chooseLocalFiles() } label: { Label("Choose Files or Folders…", systemImage: "plus") }
                }
            }.disabled(model.isRunning || model.isPaused)
            scopeLocations
            Text(coordinator.preferredDriveID == "local" ? "Includes all subfolders. Files are read directly from this Mac while you keep browsing."
                 : model.externalTitle != nil ? "Files are found and analysed together. Scan copies stay in memory and are released after each file."
                 : model.source == .cloud
                 ? "Includes all subfolders. Downloads fill a RAM queue while analysis runs. Each original is released after processing."
                 : "Selected folders include their subfolders. Analysis runs on this Mac; local file content is not uploaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder private var scopeLocations: some View {
        let isEmpty = model.source == .local ? model.localURLs.isEmpty : model.cloudRoots.isEmpty
        if model.externalTitle != nil {
            Text(model.externalScopeNames.joined(separator: ", ")).lineLimit(2).truncationMode(.middle)
                .help(model.externalScopeNames.joined(separator: "\n"))
        } else if isEmpty {
            Text(model.source == .cloud ? "Choose a PikPak folder to scan. Sign in from Settings → Accounts if needed."
                 : "Choose two or more files, or a folder containing files to compare.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        } else {
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
        }
    }

    private func scopeRow(_ path: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(FinderAppearance.accent)
            Text(path).lineLimit(1).truncationMode(.middle).help(path)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).disabled(model.isRunning || model.isPaused).help("Remove this location from the scan")
        }.padding(.horizontal, 3).frame(height: 22)
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.duplicatesOnly {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Identical copies · all file types").font(.headline)
                        Text("Compare file sizes and SHA-256 content hashes. Review results before removing anything.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    scanActionButtons
                }
            } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("All supported files", systemImage: "doc.on.doc").font(.headline)
                    Text("Documents, images, audio and video").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("MINIMUM SCORE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", model.threshold * 100)).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: Binding(get: { model.threshold }, set: { model.threshold = ($0 * 100).rounded() / 100 }), in: 0.05...1).frame(width: 185).disabled(model.isRunning || model.isPaused)
                        .accessibilityLabel("Minimum similarity score")
                        .accessibilityValue(String(format: "%.0f percent", model.threshold * 100))
                        .help("Choose a score from 5% to 100%. Higher scores show closer matches. Scores are experimental cosine similarity, not probabilities.")
                }
                scanActionButtons
            }
            if model.nativeScope?.drive == .photos && model.photosPreviewsSupported {
                HStack {
                    Picker("Apple Photos scan", selection: Binding(get: { model.photosUsePreviews }, set: { model.choosePhotosPreviews($0) })) {
                        Text("Fast Previews").tag(true)
                        Text("Originals").tag(false)
                    }.pickerStyle(.segmented).frame(maxWidth: 350).disabled(!model.canChoosePhotosMode)
                    Text(model.usesPhotosPreviews
                         ? "Photo previews and video thumbnails. Compares appearance; cannot verify identical originals."
                         : "Fetches full originals. Supports byte-identical checks and sampled video frames.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("Include byte-identical copies (all file types)", isOn: $model.exactDuplicates).disabled(model.isRunning || model.isPaused || coordinator.duplicatesOnly || model.usesPhotosPreviews)
                    .font(.callout).help("Also compare SHA-256 content hashes, including formats without a similarity decoder")
                Spacer()
                Text("Files and folders starting with “.” are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Dotfiles such as .gitignore and .DS_Store, and hidden folders such as .git, are excluded from analysis and skipped-file warnings.")
            }
            if SimilarityScanModel.mediaTool("ffmpeg") == nil || SimilarityScanModel.mediaTool("ffprobe") == nil {
                Text("Audio, video and HEIF images require FFmpeg 9 and ffprobe on this Mac. Missing decoders are reported in Scan Coverage.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !SimilarityScanModel.visualSimilarityAvailable {
                Text("Image and video similarity requires macOS 14 or later. Document, audio and byte-identical comparisons are available on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            if !coordinator.duplicatesOnly {
            HStack(spacing: 9) {
                Image(systemName: "cpu").foregroundStyle(FinderAppearance.accent)
                Text("Automatic memory · \(resourceSettings.processingMode.title) processing")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !hasActiveScan {
                    Button("Processing Options…", action: openResourceSettings)
                        .help("Choose automatic acceleration or CPU processing for new scans")
                }
            }
            if !model.processingLabel.isEmpty { Text(model.processingLabel).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func resultArea(scroll: ScrollViewProxy) -> some View {
        if model.isRunning || model.retainsOriginalsInRAM {
            VStack(spacing:10) {
                if model.isPausing {
                    Label("Pausing · keeping downloads in RAM…",systemImage:"pause.circle").foregroundStyle(FinderAppearance.accent)
                } else if let deadline = model.autoResumeDeadline {
                    autoResumeNotice(deadline)
                } else if model.isPaused {
                    Label("Downloads are retained in RAM. Work already analysing may finish; no new files start until Resume.", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.waitingForNetwork || model.progress.retryingDownloadFiles > 0 {
                    Label("Waiting for the drive. Downloads retry automatically; ready files continue analysing.",systemImage:"wifi.exclamationmark")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SimilarityProgressView(model: model) {
                    withAnimation { scroll.scrollTo("similarity-downloads", anchor: .top) }
                }
            }
        } else if model.isPaused {
            VStack(spacing: 10) {
                emptyState(symbol:model.interrupted ? "arrow.clockwise.circle" : "pause.circle",title:model.message,
                    message:"Analysed files: \(model.progress.analysed.formatted()) · Saved comparisons: \(model.progress.pairsCompared.formatted()). The previous helper stopped. Resume reuses saved analysis and fetches unfinished originals again.")
                if let deadline = model.autoResumeDeadline { autoResumeNotice(deadline).padding(.bottom, 20) }
            }
        } else if let report = model.report {
            SimilarityResultsView(results: model.results, report: report, coordinator: coordinator)
        } else {
            emptyState(symbol: "doc.on.doc", title: "Find related content, even with different names",
                       message: "Choose a scope and start a scan. Browse the resulting file tree, then select a file to review its matches and scores.")
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    @ViewBuilder private var scanActionButtons: some View {
        HStack(spacing:8) {
            if model.isRunning {
                if !model.externalDuplicatesOnly {
                    Button(model.isPausing ? "Pausing…" : "Pause") { model.pause() }.disabled(!model.canPause)
                }
                Button("Delete Scan") { model.clearSession() }
                if model.externalDuplicatesOnly {
                    Button("Cancel Check") { model.cancel() }.disabled(model.isCancelling)
                } else {
                    Button(model.isFinishing ? "Finishing…" : "Finish Scan") { model.finishScan() }.disabled(!model.canFinish)
                        .help("Finish files already being analysed and generate a resumable report")
                }
            } else if model.isPaused {
                Button { coordinator.resume(model) } label: {
                    Label(model.isAutoResuming ? "Resume Now" : "Resume",systemImage:"play.fill")
                }.buttonStyle(.borderedProminent)
                if model.retainsOriginalsInRAM {
                    Button("New Window") { WorkspaceSessionManager.current?.newWindow() }
                        .help("Start another scan while keeping this scan’s downloads in RAM")
                } else {
                    Button("New Scan") { model.detachPausedForRecovery(); coordinator.refreshRecovery() }
                }
                Button("Delete Scan") { model.clearSession() }
                Button("Finish Scan") { model.finishScan() }.disabled(!model.canFinish)
            } else {
                Button { coordinator.start(model) } label: { Label("Start Scan",systemImage:"magnifyingglass") }
                    .buttonStyle(.borderedProminent).disabled(!model.canStart)
                    .accessibilityIdentifier("similarity-start-scan")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let report = model.report {
                HStack(spacing: 12) {
                    Image(systemName: report.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(report.status == "completed" ? Color.green : Color.orange)
                    Text("\(report.status == "finished" ? "Finished early · " : report.status == "cancelled" ? "Cancelled · " : report.status == "failed" ? "Incomplete · " : "")\(report.outcomeSummary) · \(Int(report.elapsedSeconds))s")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Coverage…") { showsIssues = true }
                    Button("Export Scan Summary…") { model.exportReport() }
                }
                if report.truncated {
                    Text("Some results exceed the scan or display limits. Review coverage, or narrow the scope for complete results. The exported summary contains the displayed inventory and identical-copy evidence.")
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
                Text("\(report.scannedFiles.formatted()) discovered · \(report.outcomeSummary)")
                    .foregroundStyle(.secondary)
                if let summary = report.issueSummary, !summary.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(summary.sorted { $0.count > $1.count }.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(item.count.formatted()).font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 35, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.category == "unsupported" ? "Unsupported for similarity" : "Failed to analyse").font(.caption.weight(.semibold))
                                        Text(item.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }.padding(12)
                    }.frame(height: min(170, CGFloat(summary.count) * 62 + 24)).background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
                if !report.issues.isEmpty {
                    List(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.path).font(.callout.weight(.medium)).lineLimit(2).truncationMode(.middle)
                            Text(issue.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                } else { Text("No unsupported files or analysis failures were reported.").foregroundStyle(.secondary); Spacer() }
                Text("Reason totals cover the full scan; up to 500 individual files are listed. Unsupported content can still appear in identical-copy groups. Audio uses sampled sound; video uses sampled frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 740, height: 610)
    }

    /// An interrupted scan recovers on its own. Show the countdown so the wait
    /// reads as deliberate, and how much of the budget is left before it stops.
    private func autoResumeNotice(_ deadline: Date) -> some View {
        let now = Date()
        return HStack(spacing: 5) {
            Image(systemName: "arrow.clockwise.circle")
            Text("Resuming automatically in")
            Text(timerInterval: SimilarityRecoveryCountdown.interval(until: deadline, now: now), countsDown: true).monospacedDigit()
            Text("· attempt \(model.autoResumeAttempt) of \(model.autoResumeDelays.count)")
        }
        .font(.callout).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(FinderAppearance.accent.opacity(0.7))
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct SimilarityResourceSettingsView: View {
    @State var settings: SimilarityResourceSettings
    let save: (SimilarityResourceSettings) -> Void
    let cancel: () -> Void
    private let hardware = SimilarityHardware.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.title).foregroundStyle(FinderAppearance.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processing Options").font(.title2.weight(.semibold))
                    Text(hardware.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Processing", selection: $settings.processingMode) {
                ForEach(SimilarityAcceleration.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("Choose how new scans process image and video content.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Automatic memory", systemImage: "memorychip").font(.headline)
            Text("The app grows its RAM buffer as files need it and slows acquisition when macOS reports memory pressure. Downloads and analysis share the allowance; completed originals move into analysis without a second copy.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(hardware.backendDescription).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(settings) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540).tint(FinderAppearance.accent)
    }
}
