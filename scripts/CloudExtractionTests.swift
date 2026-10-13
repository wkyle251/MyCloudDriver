import Foundation
import Combine

@main
struct CloudExtractionTests {
    static func item(_ id: String) -> BrowserItem {
        BrowserItem(id: id, name: "\(id).zip", size: 12288, kind: .file, parentId: "parent-\(id)",
                    mimeType: "application/zip", createdTime: nil, modifiedTime: nil, fileExtension: "zip",
                    iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: "gcid-\(id)", md5Checksum: nil)
    }

    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            precondition(Date() < deadline, "fixture timed out")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor static func main() async throws {
        let engine = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-extraction-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DownloaderModel(archiveTestEngineURL: engine, directory: root)
        let token = SavedPikPakAccount(id: UUID(), profile: .init(sub: "fixture-owner", name: nil), needsSignIn: false,
            lastChecked: nil, credentialKind: .personalAccessToken)
        let normal = SavedPikPakAccount(id: UUID(), profile: token.profile, needsSignIn: false,
            lastChecked: nil, credentialKind: .desktopOAuth)
        let other = SavedPikPakAccount(id: UUID(), profile: .init(sub: "different-owner", name: nil), needsSignIn: false,
            lastChecked: nil, credentialKind: .desktopOAuth)
        let permission = DownloaderModel(archiveTestEngineURL: engine, directory: root)
        defer { permission.stopArchiveTestHelpers() }
        permission.setArchiveTestConnections([token, normal], activeID: token.id)
        permission.openArchiveExtraction(item("permission"))
        try await waitFor { permission.archiveTasks.first?.error != nil }
        let denied = permission.archiveTasks.first!
        precondition(denied.needsNormalLogin && permission.canRetryArchiveWithNormalLogin(denied),
            "Permission fixture: \(denied.error?.displayText ?? "no error"), connection: \(denied.connectionKind?.rawValue ?? "none"), account captured: \(denied.accountID == token.id)")
        precondition(denied.error?.code == "HTTP 403 • API 7" && !permission.hasActiveArchiveTasks)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(permission.archiveTasks.first?.generation == denied.generation,
            "a permission failure must not automatically retry or change credentials")
        permission.setArchiveTestConnections([token, other], activeID: token.id)
        precondition(!permission.canRetryArchiveWithNormalLogin(denied))
        permission.retryArchiveWithNormalLogin(denied.id)
        precondition(!permission.hasActiveArchiveTasks && permission.archiveTasks.first?.connectionAccountID == nil)
        var expiredNormal = normal; expiredNormal.needsSignIn = true
        permission.setArchiveTestConnections([token, expiredNormal], activeID: token.id)
        precondition(!permission.canRetryArchiveWithNormalLogin(denied))
        permission.setArchiveTestConnections([token, normal], activeID: token.id)
        permission.retryArchiveWithNormalLogin(denied.id)
        try await waitFor { permission.archiveTasks.first?.result != nil }
        precondition(permission.archiveTasks.count == 1 && permission.archiveTasks.first?.id == denied.id)
        precondition(permission.archiveTasks.first?.connectionAccountID == normal.id)
        precondition(permission.activeAccountID == token.id && permission.activeCredentialKind == .personalAccessToken)
        permission.openArchiveExtraction(item("permission-always"))
        try await waitFor { permission.archiveTasks.last?.error != nil }
        let stillDenied = permission.archiveTasks.last!
        permission.retryArchiveWithNormalLogin(stillDenied.id)
        try await waitFor { permission.archiveTasks.last?.error != nil }
        precondition(permission.archiveTasks.last?.needsNormalLogin == false && !permission.hasActiveArchiveTasks)
        precondition(permission.activeAccountID == token.id && !permission.requiresDedicatedSignIn)
        permission.stopArchiveTestHelpers()
        print("PASS: permission denial waits for explicit Normal login retry, same-account checks, selected Token login retained, persistent 403 stays failed")
        // An enabled-looking button must never silently ignore a request that
        // cannot start. Keep the archive and its selection available to retry.
        let feedbackDirectory = root.appendingPathComponent("feedback")
        try FileManager.default.createDirectory(at: feedbackDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let feedback = DownloaderModel(archiveTestEngineURL: engine, directory: feedbackDirectory)
        feedback.startArchiveExtraction(password: "", selectedIndices: [0])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_NOT_SELECTED")
        feedback.inspectArchive(item("feedback-ready"))
        try await waitFor { !feedback.hasActiveArchiveTasks }
        precondition(feedback.archiveInspection?.ready == true, feedback.status)
        feedback.selectedArchiveEntryIndices = [1]
        feedback.startArchiveExtraction(password: "", selectedIndices: [])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_SELECTION_EMPTY")
        feedback.startArchiveExtraction(password: "", selectedIndices: [999])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_SELECTION_EMPTY")
        feedback.isLoginPresented = true
        feedback.startArchiveExtraction(password: "", selectedIndices: [1])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_SIGN_IN_REQUIRED")
        precondition(feedback.selectedArchiveEntryIndices == [1] && !feedback.hasActiveArchiveTasks)
        feedback.isLoginPresented = false
        feedback.inspectArchive(item("protected-feedback"))
        try await waitFor { !feedback.hasActiveArchiveTasks }
        feedback.startArchiveExtraction(password: "", selectedIndices: [0])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_NOT_READY")
        feedback.stopArchiveTestHelpers()
        feedback.startArchiveExtraction(password: "", selectedIndices: [0])
        precondition(feedback.statusErrorDiagnostic?.code == "ARCHIVE_WINDOW_CLOSING")
        try FileManager.default.removeItem(at: feedbackDirectory)
        print("PASS: blocked extraction requests explain the reason; sign-in/selection failures keep the task and do not start a helper")

        model.inspectArchive(item("slow"))
        let slowID = model.selectedArchiveTaskID!
        model.inspectArchive(item("fast"))
        let fastID = model.selectedArchiveTaskID!
        precondition(model.activeArchiveTaskCount == 2 && !model.isRunning)
        try await waitFor { !model.hasActiveArchiveTasks }
        precondition(model.archiveTasks.allSatisfy { $0.inspection?.ready == true },
                     model.archiveTasks.map { $0.error?.displayText ?? $0.statusText }.joined(separator: "\n"))
        precondition(model.selectedArchiveTaskID == fastID && model.archiveTasks[0].parentFolderID == "parent-slow")
        model.selectArchiveTask(slowID)
        model.selectedArchiveEntryIndices = [1]
        model.selectArchiveTask(fastID)
        precondition(model.selectedArchiveEntryIndices == [0, 1])
        model.selectArchiveTask(slowID)
        precondition(model.selectedArchiveEntryIndices == [1])
        model.startArchiveExtraction(password: "", selectedIndices: [1])
        model.selectArchiveTask(fastID)
        model.startArchiveExtraction(password: "", selectedIndices: [0, 1])
        precondition(model.activeArchiveTaskCount == 2 && !model.isRunning && model.canUploadFiles)
        model.inspectArchive(item("slow"))
        precondition(model.archiveTasks.count == 2 && model.activeArchiveTaskCount == 2)
        model.selectArchiveTask(fastID)
        try await waitFor { model.archiveTasks.allSatisfy { $0.progress > 0 } }
        precondition(model.activeArchiveTaskCount == 2)
        try await waitFor { model.archiveTasks.first { $0.id == fastID }?.result != nil }
        precondition(model.archiveTasks.first { $0.id == slowID }?.isExtracting == true)
        try await waitFor { !model.hasActiveArchiveTasks }
        precondition(model.selectedArchiveTaskID == fastID)
        precondition(model.archiveTasks.allSatisfy { $0.result?.archiveFileId == $0.item.id && $0.progress == 100 })
        print("PASS: parallel inspection + extraction, independent progress/results/selection, browsing lane free, uploads enabled")

        model.inspectArchive(item("protected-a"))
        let protectedA = model.selectedArchiveTaskID!
        model.inspectArchive(item("protected-b"))
        let protectedB = model.selectedArchiveTaskID!
        try await waitFor { !model.hasActiveArchiveTasks }
        model.selectArchiveTask(protectedA); model.archivePassword = "draft-a"
        model.selectArchiveTask(protectedB); model.archivePassword = "draft-b"
        model.selectArchiveTask(protectedA); precondition(model.archivePassword == "draft-a")
        model.inspectArchive(item("protected-a"), password: "fixture-password")
        model.selectArchiveTask(protectedB)
        try await waitFor { !model.hasActiveArchiveTasks }
        precondition(model.archivePassword == "draft-b" && model.archiveInspection?.requiredPassword == true)
        model.selectArchiveTask(protectedA); precondition(model.archiveInspection?.ready == true)
        model.startArchiveExtraction(password: model.archivePassword, selectedIndices: [0])
        precondition(model.archivePassword == "fixture-password")
        print("PASS: separate password prompts/drafts; private requests; retry password stays memory-only")

        model.inspectArchive(item("cancel"))
        let cancelID = model.selectedArchiveTaskID!
        model.cancelArchiveInspection(cancelID)
        model.inspectArchive(item("fail"))
        let failID = model.selectedArchiveTaskID!
        try await waitFor { model.archiveTasks.first { $0.id == failID }?.inspection?.ready == true }
        model.startArchiveExtraction(password: "", selectedIndices: [0])
        try await waitFor { model.archiveTasks.first { $0.id == failID }?.error != nil }
        precondition(model.archiveTasks.first { $0.id == protectedA }?.isExtracting == true)
        try await waitFor { !model.hasActiveArchiveTasks }
        precondition(model.archiveTasks.first { $0.id == cancelID }?.phase == "Inspection cancelled")
        precondition(model.archiveTasks.first { $0.id == protectedA }?.result != nil)
        precondition(model.archiveTasks.first { $0.id == protectedA }?.password.isEmpty == true)
        model.removeArchiveTask(failID)
        precondition(model.archiveTasks.first { $0.id == failID } == nil && model.archiveTasks.count == 5)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(remaining.isEmpty, "private request files were not cleaned up")
        print("PASS: cancellation and API failure stay in their task; other extractions finish; requests cleaned")

        let batch = DownloaderModel(archiveTestEngineURL: engine, directory: root)
        defer { batch.stopArchiveTestHelpers() }
        batch.archiveConcurrencyLimit = 2
        let archives = [item("slow"), item("fast"), item("third"), item("fourth"), item("protected-a"), item("protected-b"), item("remove-queued")]
        batch.setArchiveTestBrowserItems(archives, selectedIDs: Set(archives.map(\.id)))
        precondition(Set(batch.archivesForExtraction(contextItem: archives[0]).map(\.id)) == Set(archives.map(\.id)))
        precondition(batch.archivesForExtraction(contextItem: item("unselected")).map(\.id) == ["unselected"])
        // An archive already being inspected must still join the batch intent.
        batch.inspectArchive(archives[0])
        batch.extractArchives(archives + [archives[0]])
        precondition(batch.archiveTasks.count == 7 && batch.activeArchiveTaskCount == 2)
        precondition(batch.archiveTasks.filter { $0.queuedAction != nil }.count == 5)
        let removedID = batch.archiveTasks.last!.id
        batch.removeArchiveTask(removedID)
        precondition(batch.archiveTasks.count == 6)
        let selected = batch.selectedArchiveTaskID
        while batch.hasActiveArchiveTasks {
            precondition(batch.activeArchiveTaskCount <= 2 && !batch.isRunning)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(batch.archiveTasks.filter { $0.result != nil }.count == 4)
        precondition(batch.archiveTasks.filter { $0.inspection?.requiredPassword == true }.count == 2)
        precondition(batch.selectedArchiveTaskID == selected)
        batch.extractArchives(Array(archives.prefix(4)))
        precondition(!batch.hasActiveArchiveTasks && batch.archiveTasks.count == 6)
        print("PASS: multi-selection, bounded batch inspection/extraction, already-inspecting archive joins batch, locked archives wait, queue removal and no duplicate jobs")

        let automatic = DownloaderModel(archiveTestEngineURL: engine, directory: root)
        defer { automatic.stopArchiveTestHelpers() }
        automatic.archiveConcurrencyLimit = Int.min
        precondition(automatic.archiveConcurrencyLimit == 1)
        automatic.archiveConcurrencyLimit = Int.max
        precondition(automatic.archiveConcurrencyLimit == 8)
        automatic.archiveConcurrencyLimit = 2
        automatic.openArchiveExtraction(item("single"))
        try await waitFor { automatic.archiveTasks.first?.result != nil }
        precondition(automatic.archiveTasks.first?.selectedIndices == [0, 1])
        print("PASS: a single Extract action inspects and extracts every entry automatically")

        automatic.extractArchives([item("protected-a")])
        try await waitFor { automatic.extractionActivity.passwordRequest != nil }
        let firstPrompt = automatic.extractionActivity.passwordRequest!
        automatic.extractArchives([item("protected-b"), item("unlocked")])
        try await waitFor {
            automatic.archiveTasks.first { $0.item.id == "protected-b" }?.needsPassword == true
                && automatic.archiveTasks.first { $0.item.id == "unlocked" }?.result != nil
        }
        precondition(automatic.activeArchiveTaskCount == 0, "password prompts must not occupy worker slots")
        automatic.submitArchivePassword("", for: firstPrompt)
        precondition(automatic.extractionActivity.passwordRequest == firstPrompt)
        automatic.submitArchivePassword("incorrect", for: firstPrompt)
        automatic.archivePasswordSheetDidDismiss()
        try await waitFor { automatic.extractionActivity.passwordRequest != nil && automatic.extractionActivity.passwordRequest?.taskID != firstPrompt.taskID }
        let deferred = automatic.extractionActivity.passwordRequest!
        automatic.deferArchivePasswordRequest(deferred)
        automatic.archivePasswordSheetDidDismiss()
        try await waitFor { automatic.extractionActivity.passwordRequest?.taskID == firstPrompt.taskID }
        let retryPrompt = automatic.extractionActivity.passwordRequest!
        precondition(retryPrompt.retry && retryPrompt.id != firstPrompt.id)
        automatic.submitArchivePassword("fixture-password", for: retryPrompt)
        automatic.archivePasswordSheetDidDismiss()
        try await waitFor { automatic.archiveTasks.first { $0.item.id == "protected-a" }?.result != nil }
        precondition(automatic.extractionActivity.passwordRequest == nil, "Later must leave this archive waiting without repeating the popup")
        automatic.submitArchivePassword("stale", for: firstPrompt)
        precondition(!automatic.hasActiveArchiveTasks)
        automatic.requestArchivePassword(deferred.taskID)
        let secondPrompt = automatic.extractionActivity.passwordRequest!
        automatic.submitArchivePassword("fixture-second", for: secondPrompt)
        automatic.archivePasswordSheetDidDismiss()
        try await waitFor { automatic.archiveTasks.allSatisfy { $0.result != nil } }
        precondition(automatic.archiveTasks.allSatisfy { $0.password.isEmpty })
        precondition(!automatic.log.contains("fixture-password") && !automatic.log.contains("fixture-second") && !automatic.log.contains("incorrect"))
        print("PASS: queued password popups, wrong-password retry, Later/resume, stale and empty submissions, unrelated jobs finish, passwords cleared")

        automatic.clearFinishedArchiveTasks()
        precondition(automatic.archiveTasks.isEmpty)
        automatic.extractArchives([item("protected-removed")])
        try await waitFor { automatic.extractionActivity.passwordRequest != nil }
        let removedPrompt = automatic.extractionActivity.passwordRequest!
        automatic.removeArchiveTask(removedPrompt.taskID)
        automatic.archivePasswordSheetDidDismiss()
        automatic.submitArchivePassword("fixture-password", for: removedPrompt)
        precondition(automatic.archiveTasks.isEmpty && automatic.extractionActivity.passwordRequest == nil)
        print("PASS: clearing history and removing a waiting archive cannot start a stale password request")

        let parallel = DownloaderModel(archiveTestEngineURL: engine, directory: root)
        defer { parallel.stopArchiveTestHelpers() }
        let unrelated = item("unrelated")
        let folder = BrowserItem(id: "other-folder", name: "Other folder", size: 0, kind: .folder,
            parentId: "", mimeType: nil, createdTime: nil, modifiedTime: nil, fileExtension: nil,
            iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        let nestedArchive = BrowserItem(id: "nested-archive", name: "Nested.zip", size: 100, kind: .file,
            parentId: folder.id, mimeType: "application/zip", createdTime: nil, modifiedTime: nil,
            fileExtension: "zip", iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        parallel.setArchiveTestBrowserItems([folder, nestedArchive, unrelated], selectedIDs: [folder.id, unrelated.id])
        precondition(parallel.isBrowserItemSelected(nestedArchive.id))
        precondition(parallel.archivesForExtraction(contextItem: nestedArchive).map(\.id) == [nestedArchive.id],
            "right-clicking an archive inside a selected folder must extract that archive only")
        parallel.setArchiveTestBrowserItems([item("slow"), unrelated, folder], selectedIDs: [unrelated.id])
        parallel.openArchiveExtraction(item("slow"))
        try await waitFor { parallel.archiveTasks.first?.isExtracting == true }
        precondition(parallel.canCreateFolder && parallel.canScanCurrentFolderForDuplicates
            && parallel.canRemoveEmptyFolders && parallel.canRemoveDSStoreFiles
            && parallel.canRenameBrowserItem(unrelated) && parallel.canTrashSelectedBrowserItem
            && parallel.canMeasureFolder(folder) && parallel.canUploadFiles && !parallel.isRunning,
            "background extraction must not disable unrelated actions")
        precondition(!parallel.canRenameBrowserItem(item("slow")), "the active source archive stays protected")
        parallel.setArchiveTestBrowserItems([item("slow"), unrelated, folder], selectedIDs: ["slow"])
        precondition(parallel.canDownloadSelectedBrowserItem && !parallel.canTrashSelectedBrowserItem,
            "read-only downloads can use the source, while deletion waits")
        parallel.setArchiveTestBrowserItems([item("slow"), unrelated, folder], selectedIDs: [unrelated.id])
        parallel.isRunning = true
        parallel.extractArchives([item("another")])
        precondition(parallel.activeArchiveTaskCount == 2, "new extraction can start while a foreground request is active")
        parallel.isRunning = false
        try await waitFor { parallel.archiveTasks.allSatisfy { $0.isExtracting && $0.hasReportedProgress } }
        var parentUpdates = 0
        var activityUpdates = 0
        let parentObserver = parallel.objectWillChange.sink { parentUpdates += 1 }
        let activityObserver = parallel.extractionActivity.objectWillChange.sink { activityUpdates += 1 }
        let previous = parallel.archiveTasks[0].progress
        try await waitFor { parallel.archiveTasks[0].progress > previous }
        precondition(activityUpdates > 0 && parentUpdates == 0, "progress must not invalidate the Browser model")
        parentObserver.cancel(); activityObserver.cancel()
        try await waitFor { !parallel.hasActiveArchiveTasks }
        precondition(parallel.archiveTasks.allSatisfy { $0.isComplete && $0.progress == 100 })
        print("PASS: concurrent foreground work and file actions stay available; progress updates do not redraw the Browser model")
        let privateFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(privateFiles.isEmpty)
    }
}
