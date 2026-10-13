import AppKit
import SwiftUI

/// This observes extraction progress independently of the Browser's file list.
struct ArchiveActivityFooter: View {
    let model: DownloaderModel
    @ObservedObject var activity: CloudExtractionActivity
    let compact: Bool
    let revealOutput: (UUID) -> Void

    var body: some View {
        if !activity.tasks.isEmpty {
            Button { activity.showsActivity.toggle() } label: {
                HStack(spacing: 6) {
                    if activity.activeCount > 0 {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: activity.needsAttention ? "exclamationmark.circle" : "archivebox")
                    }
                    Text(compact && activity.needsAttention && activity.activeCount == 0
                        ? (activity.tasks.contains(where: \.needsPassword) ? "Password needed" : "Extraction failed")
                        : activity.summary)
                        .font(.caption).lineLimit(1)
                    if activity.activeCount > 0 && activity.needsAttention {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 7).frame(height: 24)
                .background(FinderAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .foregroundStyle(FinderAppearance.accent)
            .help("\(activity.summary). Show extraction progress and actions.")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Extractions: \(activity.summary)")
            .fixedSize()
            .popover(isPresented: $activity.showsActivity, arrowEdge: .top) {
                ArchiveActivityList(model: model, activity: activity, revealOutput: revealOutput)
            }
        }
    }
}

private struct ArchiveActivityList: View {
    let model: DownloaderModel
    @ObservedObject var activity: CloudExtractionActivity
    let revealOutput: (UUID) -> Void

    private var tasks: [CloudExtractionTask] {
        // Active and waiting work stays above history. Preserve submission
        // order within each group, including when individual rows update.
        activity.tasks.filter { !$0.isComplete } + activity.tasks.filter(\.isComplete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Extractions", systemImage: "archivebox").font(.headline)
                Spacer()
                if activity.tasks.contains(where: \.isComplete) {
                    Button("Clear Finished", action: model.clearFinishedArchiveTasks)
                        .buttonStyle(.borderless).pointingHandCursor().font(.caption)
                }
                Button { activity.showsActivity = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .help("Close extraction progress").accessibilityLabel("Close extraction progress")
            }
            .padding(16)
            Text("Extracting beside each original archive. You can keep working.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        ArchiveActivityRow(model: model, task: task, revealOutput: { revealOutput(task.id) })
                        if task.id != tasks.last?.id { Divider().padding(.horizontal, 16) }
                    }
                    if tasks.isEmpty {
                        Text("No extractions").foregroundStyle(.secondary).padding(30)
                    }
                }
            }
            .frame(height: min(520, max(300, CGFloat(tasks.count) * 106)))
            Divider()
            Text("Progress is reported by PikPak. Finished extractions stay here until cleared.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(12)
        }
        .frame(width: 480)
        .background(Color(nsColor: .controlBackgroundColor))
        .tint(FinderAppearance.accent)
    }
}

private struct ArchiveActivityRow: View {
    @ObservedObject var model: DownloaderModel
    let task: CloudExtractionTask
    let revealOutput: () -> Void
    @State private var showsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : (task.needsPassword ? "lock.fill" : "archivebox.fill"))
                    .foregroundStyle(task.isComplete ? Color.green : FinderAppearance.accent)
                    .font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.item.name).font(.callout.weight(.medium))
                        .lineLimit(2).truncationMode(.middle).help(task.item.name)
                    Text(task.statusText).font(.caption)
                        .foregroundStyle(task.error == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                if !task.isBusy {
                    Button { model.removeArchiveTask(task.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).pointingHandCursor()
                        .help("Remove from this list; keep the original archive and extracted files")
                        .accessibilityLabel("Remove \(task.item.name) from extraction history")
                }
            }
            if task.isExtracting && task.hasReportedProgress {
                ProgressView(value: task.progress, total: 100)
                    .accessibilityLabel("Extraction progress for \(task.item.name)")
                    .accessibilityValue("\(Int(task.progress)) percent")
            } else if task.isInspecting || task.isExtracting {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(task.isInspecting ? "Reading archive" : "Waiting for PikPak progress")
            }
            HStack(spacing: 12) {
                if task.needsPassword {
                    Button("Enter Password…") { model.requestArchivePassword(task.id) }
                } else if task.isComplete {
                    Button("Show in Browser", action: revealOutput)
                        .disabled(model.isRunning)
                } else if task.isInspecting || task.queuedAction != nil {
                    Button("Cancel") { model.cancelArchiveInspection(task.id) }
                } else if task.needsNormalLogin, model.canRetryArchiveWithNormalLogin(task) {
                    Button("Retry with Normal login") { model.retryArchiveWithNormalLogin(task.id) }
                } else if task.error != nil || !task.isBusy {
                    Button("Retry") { model.retryArchiveTask(task.id) }
                }
                if task.error != nil {
                    Button(showsError ? "Hide Details" : "Error Details") { showsError.toggle() }
                }
                Spacer(minLength: 0)
            }
            .font(.caption).buttonStyle(ArchiveActionButtonStyle())
            if task.needsNormalLogin {
                Text(model.canRetryArchiveWithNormalLogin(task)
                    ? "PikPak denied cloud extraction with Token login. Retry this archive using Normal login for the same account."
                    : "PikPak denied cloud extraction with Token login. Connect Normal login for this account, then retry the archive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showsError, let error = task.error {
                Text(error.displayText).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.copyText(summary: task.item.name), forType: .string)
                }.buttonStyle(.borderless).pointingHandCursor().font(.caption)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.item.name), \(task.statusText)")
    }
}

private struct ArchiveActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless).pointingHandCursor()
    }
}

struct ArchivePasswordPresentation: View {
    let model: DownloaderModel
    @ObservedObject var activity: CloudExtractionActivity

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: Binding(get: { activity.passwordRequest }, set: { value in
                if value == nil, let request = activity.passwordRequest { model.deferArchivePasswordRequest(request) }
            }), onDismiss: model.archivePasswordSheetDidDismiss) { request in
                ArchivePasswordSheet(model: model, request: request).id(request.id)
            }
            .onChange(of: model.isLoginPresented) { presented in
                if !presented { model.presentNextArchivePasswordRequest() }
            }
    }
}

private struct ArchivePasswordSheet: View {
    let model: DownloaderModel
    let request: ArchivePasswordRequest
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.title2).foregroundStyle(FinderAppearance.accent)
                    .frame(width: 44, height: 44)
                    .background(FinderAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archive password").font(.headline)
                    Text(request.name).font(.callout).lineLimit(3).truncationMode(.middle).help(request.name)
                }
            }
            Text(request.retry ? "That password didn’t unlock this archive. Try again."
                : "Enter the password to extract this archive in PikPak.")
                .font(.callout).foregroundStyle(request.retry ? Color.red : Color.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(submit)
            Text("Extraction will continue in the background. The password is used only for this extraction.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Later") { password = ""; model.deferArchivePasswordRequest(request) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Extract", action: submit)
                    .buttonStyle(.borderedProminent).disabled(password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 430)
        .tint(FinderAppearance.accent).buttonStyle(FinderButtonStyle())
        .onAppear { focused = true }
        .onDisappear { password = "" }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let submitted = password
        password = ""
        model.submitArchivePassword(submitted, for: request)
    }
}
