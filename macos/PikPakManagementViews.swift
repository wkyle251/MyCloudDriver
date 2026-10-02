import AppKit
import SwiftUI

struct PikPakShareDraft: Identifiable {
    let id = UUID()
    var files: [PikPakManagedFile] = []
}

private struct PikPakManagementConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let operation: String
    let ids: [String]
    let section: Int
}

struct PikPakManagementWorkspace: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var management: PikPakManagementModel
    let section: Int
    let openBrowser: () -> Void
    var openLocalTransfers: () -> Void = {}
    @State private var showNewTask = false
    @State private var queuedLocalMagnet: String?
    @State private var localTorrentDraft: LocalTorrentDraft?
    @State private var shareDraft: PikPakShareDraft?
    @State private var editShare: PikPakOwnedShare?
    @State private var selectedTrash = Set<String>()
    @State private var confirmation: PikPakManagementConfirmation?

    private var destination: FinderWorkspaceSection { FinderWorkspaceSection(rawValue: section) ?? .cloudDownloads }
    private var busy: Bool { management.isLoading || management.isMutating }
    private var selectedFiles: [PikPakManagedFile] { management.trash.filter { selectedTrash.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.hasAccountSession {
                FinderDriveConnection(kind: .pikpak, busy: model.isCheckingAccount || model.isChangingAccount) {
                    model.beginAccountLogin(accountID: model.activeAccountID)
                }
            } else if !management.connected {
                VStack(spacing: 12) {
                    Text("Check your PikPak connection in Settings → Accounts.").foregroundStyle(.secondary)
                    FinderAccountSettingsLink(settings: model.finderSettings, pane: 2) { Text("Account Settings…") }
                        .buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let error = management.error { feedback(error, error: true) }
                if let notice = management.notice { feedback(notice, error: false) }
                if section == 6 { trashToolbar }
                if section == 4 { cloudInformation }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
                HStack {
                    if management.isMutating { ProgressView().controlSize(.mini); Text("Saving changes…") }
                    else if management.isLoading { ProgressView().controlSize(.mini); Text("Refreshing…") }
                    else if let updated = management.updatedAt {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                    if management.hasMore(section) {
                        Button("Load More") { Task { await management.load(section, more: true) } }.disabled(busy)
                    }
                }.font(.caption).foregroundStyle(.secondary).frame(height: 26)
            }
        }
        .task(id: "\(section):\(model.activeAccountID?.uuidString ?? ""): \(model.hasAccountSession)") {
            model.preparePikPakManagement()
            management.dismissNotice()
            selectedTrash = []
            await management.load(section)
            if section == 4 {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    // Keep older pages stable after Load More; Refresh returns
                    // to the newest page. Never interrupt a form submission.
                    if management.tasks.count <= 100 && management.hasActiveCloudTasks && !showNewTask && confirmation == nil {
                        await management.load(section, quietly: true)
                    }
                }
            }
        }
        .onChange(of: management.revision) { _ in
            selectedTrash = []; confirmation = nil; shareDraft = nil; editShare = nil; showNewTask = false
        }
        .onChange(of: management.trash) { rows in selectedTrash.formIntersection(rows.map(\.id)) }
        .sheet(isPresented: $showNewTask, onDismiss: {
            if let magnet = queuedLocalMagnet { queuedLocalMagnet = nil; localTorrentDraft = .init(magnet: magnet) }
        }) {
            PikPakNewCloudTaskSheet(management: management, openLocalTorrent: { queuedLocalMagnet = $0 })
        }
        .sheet(item: $localTorrentDraft) { draft in LocalTorrentAddSheet(draft: draft, pikpak: model, onStarted: openLocalTransfers) }
        .sheet(item: $shareDraft) { draft in PikPakCreateShareSheet(management: management, initialFiles: draft.files) }
        .sheet(item: $editShare) { share in PikPakShareExpirySheet(management: management, share: share) }
        .alert(item: $confirmation) { value in
            Alert(title: Text(value.title), message: Text(value.message),
                primaryButton: .destructive(Text(value.button)) {
                    Task {
                        _ = await management.mutate(value.operation,
                            values: ["ids":value.ids, "id":value.ids.first ?? "", "confirmed":true],
                            section: value.section, success: value.operation == "empty_trash" ? "Trash emptied." : "Changes saved.")
                    }
                }, secondaryButton: .cancel())
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: FinderSymbolImage.template(named: destination.symbol, style: .menu))
                .foregroundStyle(FinderAppearance.accent).padding(11)
                .background(FinderAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(destination.title).font(.title2.weight(.semibold))
                Text(section == 4 ? "Save links directly to your PikPak drive" : section == 5 ? "Links you’ve shared from this account" : "Restore files or remove them permanently")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { Task { model.preparePikPakManagement(); await management.load(section) } } label: {
                Image(nsImage: FinderSymbolImage.template(named: "arrow.clockwise", style: .menu))
            }.help("Refresh \(destination.title)").accessibilityLabel("Refresh \(destination.title)")
                .disabled(busy || !model.hasAccountSession)
            if section == 4 {
                Button { showNewTask = true } label: { Label("New Task", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(busy || !management.connected)
            } else if section == 5 {
                Button { shareDraft = .init() } label: { Label("Create Link", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(busy || !management.connected)
            } else {
                Button("Empty Trash…", role: .destructive) {
                    confirmation = .init(title: "Empty PikPak Trash?",
                        message: "All files and folders in Trash for \(model.accountDisplayName ?? "this account") will be permanently deleted. This cannot be undone.",
                        button: "Empty Trash", operation: "empty_trash", ids: [], section: 6)
                }.disabled(busy || !management.canPermanentlyDelete || management.trash.isEmpty)
            }
        }.padding(14).finderCard(padding: 0)
    }

    private var cloudInformation: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle").foregroundStyle(FinderAppearance.accent)
            Text("Tasks run on PikPak and use cloud-download traffic. You can close MyCloudDriver while they run.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Open Browser", action: openBrowser).font(.callout)
        }.padding(.horizontal, 8)
    }

    private var trashToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !management.canPermanentlyDelete {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Permanent deletion requires PikPak sign-in").font(.callout.weight(.medium))
                        Text("Your personal token supports Trash and Restore. To delete permanently or empty Trash, change this account’s connection in Settings → Accounts.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    FinderAccountSettingsLink(settings: model.finderSettings, pane: 2) { Text("Account Settings…") }
                        .buttonStyle(.bordered)
                }.padding(12).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack {
                Text("\(selectedTrash.count) selected").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Select All Loaded") { selectedTrash = Set(management.trash.prefix(100).map(\.id)) }
                    .disabled(busy || management.trash.isEmpty)
                Button("Restore") {
                    let ids = selectedFiles.map(\.id)
                    Task { _ = await management.mutate("restore_trash", values: ["ids":ids], section: 6, success: "Restored selected items to PikPak.") }
                }.disabled(busy || selectedFiles.isEmpty)
                Button("Delete Permanently…", role: .destructive) {
                    let files = selectedFiles
                    confirmation = .init(title: "Permanently delete \(files.count) item(s)?",
                        message: files.prefix(5).map(\.name).joined(separator: "\n") + (files.count > 5 ? "\n…and \(files.count - 5) more" : "") + "\n\nThis cannot be undone.",
                        button: "Delete Permanently", operation: "delete_trash", ids: files.map(\.id), section: 6)
                }.disabled(busy || selectedFiles.isEmpty || !management.canPermanentlyDelete)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if section == 4 {
            if management.tasks.isEmpty { empty("No cloud downloads", "Add an HTTP, HTTPS or magnet link to save it to PikPak.") }
            else { ScrollView { LazyVStack(spacing: 0) { ForEach(management.tasks) { task in taskRow(task); Divider() } } } }
        } else if section == 5 {
            if management.shares.isEmpty { empty("No shared links", "Create a link for files or folders in your PikPak drive.") }
            else { ScrollView { LazyVStack(spacing: 0) { ForEach(management.shares) { share in shareRow(share); Divider() } } } }
        } else {
            if management.trash.isEmpty { empty("Trash is empty", "Files you move to PikPak Trash will appear here.") }
            else {
                ScrollView { LazyVStack(spacing: 0) { ForEach(management.trash) { file in
                    HStack(spacing: 12) {
                        Toggle("Select \(file.name)", isOn: Binding(get: { selectedTrash.contains(file.id) }, set: { selected in
                            if selected && selectedTrash.count < 100 { selectedTrash.insert(file.id) }
                            else if !selected { selectedTrash.remove(file.id) }
                        })).labelsHidden().disabled(busy || (!selectedTrash.contains(file.id) && selectedTrash.count >= 100))
                        Image(systemName: file.isFolder ? "folder.fill" : "doc").foregroundStyle(FinderAppearance.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            if let date = PikPakManagementDate.parse(file.trashedTime) {
                                Text("Deleted \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(file.isFolder ? "Folder" : managementBytes(file.size)).font(.caption).foregroundStyle(.secondary)
                    }.padding(14)
                    Divider()
                } } }
            }
        }
    }

    private func taskRow(_ task: PikPakCloudTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.isComplete ? "checkmark.circle.fill" : task.isFailed ? "exclamationmark.circle" : "icloud.and.arrow.down")
                .foregroundStyle(task.isComplete ? .green : task.isFailed ? .orange : FinderAppearance.accent)
                .frame(width: 26).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(2).textSelection(.enabled)
                HStack {
                    Text(task.status)
                    if task.size > 0 { Text("· \(managementBytes(task.size))") }
                    Spacer()
                    Text("\(Int(task.progress))%").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value: task.progress, total: 100).tint(task.isFailed ? .orange : FinderAppearance.accent)
                if !task.message.isEmpty && task.isFailed {
                    if task.hasFileCountLimit {
                        Text(PikPakManagementError.taskFileLimitMessage).font(.caption).foregroundStyle(.orange)
                        Text(PikPakManagementError.taskFileLimitRecovery).font(.caption).foregroundStyle(.secondary)
                        Link("PikPak torrent limits", destination: PikPakManagementError.torrentHelpURL).font(.caption)
                    } else {
                        Text(task.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            if task.isFailed && !task.hasFileCountLimit {
                Button("Retry") { Task { _ = await management.mutate("retry_task", values: ["id":task.id], section: 4, success: "Retry requested.") } }.disabled(busy)
            }
            Menu {
                Button("Remove Task…", role: .destructive) {
                    confirmation = .init(title: "Remove this cloud task?", message: "\(task.title)\n\nAny file already saved in PikPak will be kept.",
                        button: "Remove Task", operation: "remove_task", ids: [task.id], section: 4)
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(busy)
                .accessibilityLabel("Actions for \(task.title)")
        }.padding(16)
    }

    private func shareRow(_ share: PikPakOwnedShare) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: share.passCode.isEmpty ? "link" : "lock.shield")
                .foregroundStyle(FinderAppearance.accent).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(share.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(share.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("\(share.passCode.isEmpty ? "Public link" : "Passcode protected") · Expires: \(share.expirationLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(share.views) views · \(share.saves) saves\(share.status.isEmpty ? "" : " · \(share.status.replacingOccurrences(of: "SHARE_STATUS_", with: "").capitalized)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy Link") { copyManagedShare(share) }.disabled(share.shareURL == nil)
            Menu {
                if let url = share.shareURL { Link("Open in PikPak", destination: url) }
                Button("Change Expiry…") { editShare = share }
                Divider()
                Button("Revoke Link…", role: .destructive) {
                    confirmation = .init(title: "Revoke this shared link?",
                        message: "The link for “\(share.displayTitle)” will stop working. Your files in PikPak will be kept.",
                        button: "Revoke Link", operation: "remove_shares", ids: [share.id], section: 5)
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(busy)
                .accessibilityLabel("Actions for \(share.displayTitle)")
        }.padding(16)
    }

    private func empty(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            if management.isLoading { ProgressView(); Text("Loading \(destination.title)…") }
            else if management.hasListError { Image(systemName: "wifi.exclamationmark").font(.largeTitle); Text("Could not load \(destination.title)") }
            else { Image(systemName: destination.symbol).font(.system(size: 34)); Text(title).font(.headline); Text(subtitle).font(.callout) }
        }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedback(_ message: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle" : "checkmark.circle")
            // Bound the banner's minimum height. An unbounded fixed-size text
            // can make the hosting window grow by thousands of points while a
            // sheet is open. Full recovery details stay in the task dialog.
            Text(message).textSelection(.enabled).lineLimit(4).help(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if !error { Button { management.dismissNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
        }.font(.callout).foregroundStyle(error ? .orange : .green).padding(10)
            .background((error ? Color.orange : Color.green).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PikPakNewCloudTaskSheet: View {
    @ObservedObject var management: PikPakManagementModel
    var openLocalTorrent: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var parent = PikPakManagedFile(id: "", name: "My PikPak", isFolder: true, size: 0)
    @State private var showFolders = false
    @State private var copiedLink = false
    @State private var expandedForRecovery = false
    @FocusState private var linkFocused: Bool
    private var failure: PikPakCloudTaskFailure? {
        guard let failure = management.cloudTaskFailure, failure.applies(to: link) else { return nil }
        return failure
    }
    private var valid: Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https", "magnet"].contains(url.scheme ?? "") && !link.contains("\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                form.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(management.isMutating)
                Spacer()
                if management.isMutating { ProgressView().controlSize(.small) }
                Button("Create Task") {
                    Task {
                        if await management.mutate("create_task", values: ["url":link, "parent_id":parent.id], section: 4,
                            success: "Cloud download created. PikPak will continue downloading even when you close the app.") != nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!valid || management.isMutating || failure?.requiresDifferentLink == true)
            }.padding(20)
        }.frame(width: 540, height: expandedForRecovery ? 640 : 360)
            .interactiveDismissDisabled(management.isMutating)
            .onChange(of: link) { _ in copiedLink = false }
            .onChange(of: failure?.source) { value in if value != nil { expandedForRecovery = true } }
            .sheet(isPresented: $showFolders) { PikPakFileChooser(management: management, foldersOnly: true) { parent = $0[0] } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Cloud Download").font(.title2.weight(.semibold))
            Text("PikPak fetches the link and saves it in your cloud drive.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Download link").font(.callout.weight(.medium))
                TextField("https://… or magnet:?xt=…", text: $link).textFieldStyle(.roundedBorder)
                    .focused($linkFocused).disabled(management.isMutating)
                Text("One HTTP, HTTPS or magnet link per task").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Text("Save to"); Spacer(); Button { showFolders = true } label: { Label(parent.name, systemImage: "folder") } }
                .disabled(management.isMutating)
            Text("Uses your account’s cloud-download quota. Connected Apps share a portion of that quota.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { failureCard(failure) }
            else if management.cloudTaskFailure == nil, let error = management.error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if failure == nil, LocalTorrentSource.infoHash(link) != nil, openLocalTorrent != nil {
                Button("Download to Mac Instead…", action: handOffToLocalTorrent).disabled(management.isMutating)
            }
        }
    }

    private func failureCard(_ failure: PikPakCloudTaskFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: failure.requiresDifferentLink ? "doc.on.doc" : "exclamationmark.circle")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(failure.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(failure.recovery).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if failure.requiresDifferentLink, LocalTorrentSource.infoHash(link) != nil, openLocalTorrent != nil {
                Button("Download to Mac…", action: handOffToLocalTorrent).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 12) {
                if failure.requiresDifferentLink {
                    Button("Edit Link") { linkFocused = true }
                    Button(copiedLink ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents()
                        copiedLink = NSPasteboard.general.setString(link.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
                    }
                    Spacer(minLength: 0)
                    Link("PikPak Help", destination: PikPakManagementError.torrentHelpURL)
                } else if failure.isUncertain {
                    Button("Review Cloud Downloads") {
                        Task { await management.load(4); dismiss() }
                    }.disabled(management.isLoading)
                }
            }.controlSize(.small)
            if let details = failure.reason.technicalDetails {
                Text(details).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
    private func handOffToLocalTorrent() {
        guard !management.isMutating, LocalTorrentSource.infoHash(link) != nil else { return }
        openLocalTorrent?(link.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss()
    }
}

struct PikPakCreateShareSheet: View {
    @ObservedObject var management: PikPakManagementModel
    @Environment(\.dismiss) private var dismiss
    @State private var files: [PikPakManagedFile]
    @State private var title: String
    @State private var days = 7
    @State private var password = false
    @State private var showFiles = false
    @State private var created: PikPakOwnedShare?
    init(management: PikPakManagementModel, initialFiles: [PikPakManagedFile]) {
        self.management = management; _files = State(initialValue: initialFiles)
        _title = State(initialValue: initialFiles.count == 1 ? initialFiles[0].name : initialFiles.isEmpty ? "" : "\(initialFiles.count) shared items")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(created == nil ? "Create Shared Link" : "Link Created").font(.title2.weight(.semibold))
            if let created {
                Label(created.displayTitle, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(created.url).textSelection(.enabled).font(.callout)
                if !created.passCode.isEmpty { LabeledContent("Passcode", value: created.passCode).textSelection(.enabled) }
                Text("Manage this link in My Shares.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Link") { copyManagedShare(created) }.disabled(created.shareURL == nil)
                    Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Text(files.isEmpty ? "Choose files or folders" : "\(files.count) item(s) selected").font(.callout.weight(.medium))
                    Spacer(); Button(files.isEmpty ? "Choose…" : "Change…") { showFiles = true }
                }
                if !files.isEmpty {
                    Text(files.prefix(4).map(\.name).joined(separator: "\n") + (files.count > 4 ? "\n…and \(files.count - 4) more" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(5)
                }
                TextField("Link title", text: $title).textFieldStyle(.roundedBorder)
                shareExpiryPicker(days: $days)
                Toggle("Require a passcode", isOn: $password)
                Text(password ? "PikPak will generate a passcode. Share it with the people who need access." : "Anyone with this link can access the selected items until it expires or you revoke it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = management.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(management.isMutating)
                    Spacer()
                    if management.isMutating { ProgressView().controlSize(.small) }
                    Button("Create Link") {
                        Task {
                            let result = await management.mutate("create_share", values: ["ids":files.map(\.id), "title":title,
                                "expiration_days":days, "password_protected":password], section: 5, success: "Shared link created.")
                            created = result?.share
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(files.isEmpty || files.count > 100 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 || management.isMutating)
                }
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(management.isMutating)
            .sheet(isPresented: $showFiles) {
                PikPakFileChooser(management: management, foldersOnly: false) { selected in
                    files = selected
                    if title.isEmpty { title = selected.count == 1 ? selected[0].name : "\(selected.count) shared items" }
                }
            }
    }
}

private struct PikPakShareExpirySheet: View {
    @ObservedObject var management: PikPakManagementModel
    let share: PikPakOwnedShare
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Link Expiry").font(.title2.weight(.semibold))
            Text(share.displayTitle).lineLimit(2)
            Text("Current expiry: \(share.expirationLabel)").font(.caption).foregroundStyle(.secondary)
            shareExpiryPicker(days: $days)
            Text("The new period starts when you save.").font(.caption).foregroundStyle(.secondary)
            if let error = management.error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(management.isMutating)
                Spacer()
                Button("Save") { Task {
                    if await management.mutate("update_share", values: ["id":share.id,"expiration_days":days], section: 5,
                        success: "Link expiry updated.") != nil { dismiss() }
                } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(management.isMutating)
            }
        }.padding(24).frame(width: 420).interactiveDismissDisabled(management.isMutating)
    }
}

/// Bounded folder paging independent of Browser navigation. Selection retains
/// names and IDs across folders, and only explicit Choose submits it.
struct PikPakFileChooser: View {
    @ObservedObject var management: PikPakManagementModel
    let foldersOnly: Bool
    let choose: ([PikPakManagedFile]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = [PikPakManagedFile(id: "", name: "My PikPak", isFolder: true, size: 0)]
    @State private var rows: [PikPakManagedFile] = []
    @State private var selection: [String: PikPakManagedFile] = [:]
    @State private var next = ""
    @State private var seen = Set<String>()
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(foldersOnly ? "Choose Destination" : "Choose Items to Share").font(.headline)
            HStack {
                Button { if path.count > 1 { path.removeLast() } } label: { Image(systemName: "chevron.left") }.disabled(path.count <= 1 || loading)
                Text(path.map(\.name).joined(separator: " / ")).lineLimit(1).truncationMode(.middle)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            if let error { HStack { Text(error).font(.caption).foregroundStyle(.orange); Button("Retry") { Task { await load() } } } }
            List {
                ForEach(rows.filter { !foldersOnly || $0.isFolder }) { file in
                    HStack {
                        if !foldersOnly {
                            Toggle("Select \(file.name)", isOn: Binding(get: { selection[file.id] != nil }, set: { selected in
                                if selected && selection.count < 100 { selection[file.id] = file }
                                else if !selected { selection.removeValue(forKey: file.id) }
                            })).labelsHidden().disabled(selection.count >= 100 && selection[file.id] == nil)
                        }
                        Image(systemName: file.isFolder ? "folder.fill" : "doc").foregroundStyle(FinderAppearance.accent)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if file.isFolder { Button { path.append(file) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Open \(file.name)").disabled(loading) }
                    }.padding(.vertical, 3)
                }
                if !next.isEmpty { Button("Load More") { Task { await load(more: true) } }.disabled(loading) }
                if rows.isEmpty && !loading && error == nil { Text("This folder is empty.").foregroundStyle(.secondary) }
            }.frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !foldersOnly { Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(foldersOnly ? "Use This Folder" : "Choose") {
                    choose(foldersOnly ? [path.last!] : selection.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || error != nil || (!foldersOnly && selection.isEmpty))
            }
        }.padding(20).frame(width: 500).task(id: path.last?.id) { await load() }
            .onDisappear { generation = UUID() }
    }
    private func load(more: Bool = false) async {
        let current = UUID(); generation = current; loading = true; error = nil
        if !more { rows = []; next = ""; seen = [] }
        let token = more ? next : ""
        defer { if generation == current { loading = false } }
        do {
            let result = try await management.pickFiles(parent: path.last?.id ?? "", pageToken: token)
            guard generation == current else { return }
            let nextToken = result.nextPageToken ?? ""
            guard nextToken.isEmpty || (!seen.contains(nextToken) && nextToken != token) else {
                throw PikPakManagementError.message("PikPak repeated a page. Try refreshing this folder.")
            }
            var ids = Set(rows.map(\.id))
            rows.append(contentsOf: (result.files ?? []).filter { ids.insert($0.id).inserted })
            next = nextToken; if !nextToken.isEmpty { seen.insert(nextToken) }
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }
}

struct PikPakAccountDetailsSection: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var management: PikPakManagementModel
    @ObservedObject var quotas: PikPakTransferQuotaMonitor
    var body: some View {
        Section("Account details and permissions") {
            if let profile = management.profile ?? model.accountProfile {
                LabeledContent("Account ID") { Text(profile.sub).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            }
            if let details = management.details {
                if let expiry = details.expiry {
                    LabeledContent("Token expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    if expiry.timeIntervalSinceNow < 7 * 24 * 3600 {
                        Label(expiry < Date() ? "This token has expired. Replace it to reconnect." : "This token expires soon. Replace it before the date above.", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else { LabeledContent("Session", value: details.kind == "desktop-oauth" ? "Automatically renewed" : "Expiry unavailable") }
                if let permissions = details.permissions {
                    ForEach(PikPakConnectionDetails.permissionNames, id: \.0) { key, title in
                        HStack {
                            Text(title); Spacer()
                            Label(permissions.contains(key) ? "Enabled" : "Not granted", systemImage: permissions.contains(key) ? "checkmark.circle.fill" : "minus.circle")
                                .font(.caption).foregroundStyle(permissions.contains(key) ? .green : .secondary)
                        }
                    }
                    Text("Permissions reported by your current token. PikPak checks access for each action.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !details.canPermanentlyDelete {
                    Label("Permanent deletion requires PikPak sign-in.", systemImage: "key").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("Refresh to load connection details.").font(.caption).foregroundStyle(.secondary) }
            if let error = management.accountError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Refresh Account Details") { Task { model.preparePikPakManagement(); await management.loadAccount(); await model.refreshTransferQuota(force: true) } }
                    .disabled(!model.hasAccountSession || management.isMutating || management.isLoadingAccount)
                if management.isLoadingAccount { ProgressView().controlSize(.mini) }
                Spacer()
                Link("Account & Security ↗", destination: URL(string: "https://mypikpak.com/drive/account")!)
            }
        }
        Section("Storage and transfer quota") {
            if let storage = quotas.snapshot?.storage ?? model.storageQuota {
                quotaLine("Storage", storage)
            }
            PikPakQuotaComparison(transfer: quotas.snapshot?.transfer, activeKind: model.activeCredentialKind, isRefreshing: quotas.isRefreshing)
            if let updated = quotas.updatedAt { Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if let error = quotas.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Connected Apps share a 25% limit across all personal tokens and other connected apps. This is part of the account allowance. Switching login methods does not reset usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(model.activeAccountID?.uuidString ?? ""):\(model.hasAccountSession)") {
            model.preparePikPakManagement()
            await management.loadAccount()
            await model.refreshTransferQuota(force: true)
        }
    }
    private func quotaLine(_ title: String, _ quota: StorageQuota) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title); Spacer(); Text("\(pikpakTrafficBytes(quota.used)) / \(pikpakTrafficBytes(quota.total))").monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: quota.usedFraction).tint(quota.used >= quota.total ? .orange : FinderAppearance.accent)
        }.padding(.vertical, 3)
    }
}

private func shareExpiryPicker(days: Binding<Int>) -> some View {
    Picker("Expires", selection: days) {
        Text("After 1 day").tag(1); Text("After 7 days").tag(7); Text("After 30 days").tag(30); Text("Never").tag(-1)
    }
}
private func managementBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
private func copyManagedShare(_ share: PikPakOwnedShare) {
    guard share.shareURL != nil else { return }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(share.copyText, forType: .string)
}
