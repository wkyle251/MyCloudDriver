import AppKit
import SwiftUI

@main struct PikPakManagementTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--ui") { launchUI(); return }
        try await paginationAndIsolation()
        try await mutationAndCredentials()
        try await emptyTrashReconciliation()
        try await emptyTrashPendingAndFailures()
        try await emptyTrashStaleRepliesAndAccountSwitch()
        try await emptyTrashSupersededByUndo()
        try await cloudTaskFailures()
        try await cloudTaskRemovalConfirmation()
        try await cloudTaskRemovalReconciliation()
        try DownloaderModel.testGuestMode()
        try await DownloaderModel.testPersonalAccessTokenConnection()
        print("PikPak management tests passed: confirmation dismissal, cloud-task removal, pagination, account isolation, stale replies, creation failures, Empty Trash, metadata and token connections.")
    }

    @MainActor static func context(_ owner: String = "owner", kind: PikPakCredentialKind = .personalAccessToken) -> PikPakManagementContext {
        .init(identity: UUID(), accountID: owner, engineURL: URL(fileURLWithPath: "/unused-fixture"), environment: [:], credentialKind: kind)
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func file(_ id: String, name: String = "Example.jpg", folder: Bool = false) -> [String: Any] {
        ["id":id,"name":name,"is_folder":folder,"size":4096,"parent_id":"","modified_time":"2026-09-16T10:00:00Z","trashed_time":"2026-09-16T10:00:00Z"]
    }

    @MainActor static func paginationAndIsolation() async throws {
        let model = PikPakManagementModel(); model.configure(context())
        var page = 0
        model.fixture = { input in
            precondition(input["account_id"] as? String == "owner")
            page += 1
            return try data(["account_id":"owner","files":page == 1 ? [file("a")] : [file("a"),file("b")],"next_page_token":page == 1 ? "page2" : "page3"])
        }
        await model.load(6)
        precondition(model.trash.count == 1 && model.hasMore(6))
        await model.load(6,more:true)
        precondition(model.trash.map(\.id) == ["a","b"], "Pages deduplicate IDs")
        await model.load(6,more:true)
        precondition(model.error?.contains("repeated") == true && model.trash.count == 2)
        model.fixture = { _ in try data(["account_id":"wrong","files":[file("leak")],"next_page_token":""]) }
        await model.load(6)
        precondition(!model.trash.contains { $0.id == "leak" } && model.error != nil)
        model.fixture = { _ in
            try await Task.sleep(nanoseconds: 40_000_000)
            return try data(["account_id":"owner","files":[file("stale")],"next_page_token":""])
        }
        let request = Task { await model.load(6) }
        try await Task.sleep(nanoseconds: 5_000_000)
        model.configure(context("other")); await request.value
        precondition(model.trash.isEmpty && model.error == nil && !model.isLoading)
        precondition(!model.canPermanentlyDelete)
        model.configure(context("other",kind:.desktopOAuth)); precondition(model.canPermanentlyDelete)
        precondition(FinderWorkspaceSection.standard.map(\.rawValue) == [0,7,1], "Links belongs to PikPak alone")
        precondition(FinderWorkspaceSection.allCases.contains(.links) && FinderWorkspaceSection.allCases.map(\.rawValue).prefix(4) == [0,7,1,3])
        precondition(FinderWorkspaceSection.allCases.map(\.shortcut) == [1,7,2,3,4,5,6])
        let navigation = FinderWorkspaceNavigation(); navigation.showImmediately(6); precondition(navigation.section == 6)
    }

    @MainActor static func mutationAndCredentials() async throws {
        let model = PikPakManagementModel(); model.configure(context())
        var attempts = 0, states: [Bool] = []
        model.onMutationState = { states.append($0) }
        model.fixture = { input in
            precondition(input["operation"] as? String == "create_task")
            attempts += 1
            throw PikPakManagementError.message("Connection closed")
        }
        let response = await model.mutate("create_task",values:["url":"https://example.test/file"],section:4,success:"Created")
        precondition(response == nil && attempts == 1 && states == [true,false] && !model.isMutating)
        precondition(model.notice == nil && model.error?.contains("before trying again") == true)
        model.fixture = { _ in try data(["account_id":"owner","credential":["kind":"personal-access-token","expires_at":1900000000,
            "permissions":["files:read","cloud_download","share"],"can_permanently_delete":false],"profile":["sub":"owner","name":"Example"]]) }
        await model.loadAccount()
        precondition(model.details?.expiry != nil && model.details?.permissions?.contains("share") == true)
        precondition(model.profile?.sub == "owner")
        let safe = PikPakManagementError.safeMessage("Error: Bearer private-token eyJzdWIiOiIxIn0.e30.signature")
        precondition(!safe.contains("private-token") && !safe.contains("eyJ"))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let share = try decoder.decode(PikPakOwnedShare.self, from: data(shareData()))
        precondition(share.copyText.contains("Passcode: abcd") && share.shareURL != nil)
        var bad = shareData(); bad["url"] = "file:///private/file"
        let badShare = try decoder.decode(PikPakOwnedShare.self,from:data(bad))
        precondition(badShare.shareURL == nil)
        var complete = false, invalidations = 0
        model.onFilesChanged = { invalidations += 1 }
        model.fixture = { _ in
            var task = taskData(); task["phase"] = complete ? "PHASE_TYPE_COMPLETE" : "PHASE_TYPE_RUNNING"
            return try data(["account_id":"owner","tasks":[task],"next_page_token":""])
        }
        await model.load(4); complete = true; await model.load(4); await model.load(4)
        precondition(invalidations == 1, "Finishing a cloud task refreshes account files once")
    }

    @MainActor static func emptyTrashReconciliation() async throws {
        let model = PikPakManagementModel(); model.configure(context(kind: .desktopOAuth))
        defer { model.clear() }
        var accepted = false, mutations = 0, confirmations = 0
        model.fixture = { input in
            if input["operation"] as? String == "empty_trash" {
                accepted = true; mutations += 1
                return try data(["account_id":"owner", "ok":true])
            }
            precondition(input["operation"] as? String == "list_trash")
            if accepted {
                confirmations += 1
                precondition(model.notice != "Trash emptied.", "Empty Trash cannot report completion before a fresh empty listing")
            }
            return try data(["account_id":"owner", "files":accepted && confirmations >= 3 ? [] : [file("remaining")], "next_page_token":""])
        }
        await model.load(6)
        _ = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
        precondition(model.trash.isEmpty && model.notice == "Trash emptied." && confirmations == 3 && mutations == 1,
                     "Only refreshes are repeated while PikPak finishes emptying Trash")
        print("PASS Empty Trash: completion waits for the server's empty listing without repeating permanent deletion")
        model.fixture = { _ in try data(["account_id":"owner", "files":[file("new-trash")], "next_page_token":""]) }
        await model.load(6)
        precondition(model.notice == nil && model.trash.count == 1,
                     "A later nonempty refresh cannot keep a stale Trash emptied notice")
    }

    @MainActor static func emptyTrashPendingAndFailures() async throws {
        let model = PikPakManagementModel(); model.configure(context(kind: .desktopOAuth))
        defer { model.clear() }
        var accepted = false, empty = false, failRead = false, failMutation = false
        var mutationCount = 0, readCount = 0, continuation = false
        model.fixture = { input in
            if input["operation"] as? String == "empty_trash" {
                mutationCount += 1
                if failMutation { throw PikPakManagementError.message("PikPak denied this action.") }
                accepted = true
                return try data(["account_id":"owner", "ok":true])
            }
            precondition(input["operation"] as? String == "list_trash")
            readCount += 1
            if failRead { throw PikPakManagementError.message("Trash response could not be read.") }
            return try data(["account_id":"owner", "files":empty || (accepted && continuation) ? [] : [file("remaining")],
                             "next_page_token":accepted && continuation && (input["page_token"] as? String ?? "").isEmpty ? "next" : ""])
        }
        await model.load(6)
        failMutation = true
        let rejected = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
        precondition(rejected == nil && model.trash.count == 1 && model.notice == nil && readCount == 1)
        failMutation = false; failRead = true
        let acceptedResponse = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
        precondition(acceptedResponse != nil && !model.isMutating && model.noticeIsPending && model.hasListError
                     && model.notice != "Trash emptied." && model.trash.count == 1)
        failRead = false
        let before = mutationCount
        _ = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
        precondition(!model.isMutating && model.noticeIsPending && model.hasPendingEmptyTrash
                     && model.trash.count == 1 && mutationCount == before + 1,
                     "Bounded verification keeps actual remaining rows and releases the mutation lane")
        empty = true; await model.load(6)
        precondition(model.trash.isEmpty && model.notice == "Trash emptied." && !model.noticeIsPending
                     && !model.hasPendingEmptyTrash && mutationCount == before + 1)
        empty = false; continuation = true
        _ = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
        precondition(model.trash.isEmpty && model.hasMore(6) && model.noticeIsPending && model.hasPendingEmptyTrash,
                     "An empty page with a continuation does not prove Trash is empty")
        await model.load(6, more:true)
        precondition(model.hasPendingEmptyTrash && model.notice != "Trash emptied.",
                     "The empty end of a paginated listing cannot confirm the whole Trash")
        continuation = false; empty = true; await model.load(6)
        precondition(model.notice == "Trash emptied." && !model.hasPendingEmptyTrash)
        print("PASS Empty Trash: failed checks and ongoing processing stay pending; a fresh first page confirms completion")
    }

    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(condition(), "Fixture did not reach its expected suspension")
    }

    @MainActor static func emptyTrashStaleRepliesAndAccountSwitch() async throws {
        let model = PikPakManagementModel(); model.configure(context(kind: .desktopOAuth))
        defer { model.clear() }
        for failOldRead in [false, true] {
            var accepted = false, slowRead = false, started = false, mutationCount = 0
            model.fixture = { input in
                if input["operation"] as? String == "empty_trash" {
                    accepted = true; mutationCount += 1
                    return try data(["account_id":"owner", "ok":true])
                }
                let captured = accepted
                if slowRead && !captured {
                    started = true
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if failOldRead { throw PikPakManagementError.message("An old Trash response could not be read.") }
                }
                return try data(["account_id":"owner", "files":captured ? [] : [file("stale")], "next_page_token":""])
            }
            await model.load(6)
            slowRead = true
            let oldRead = Task { await model.load(6) }
            try await waitFor { started }
            _ = await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.")
            await oldRead.value
            precondition(model.trash.isEmpty && model.notice == "Trash emptied." && model.error == nil && mutationCount == 1,
                         "An old listing or its failure cannot overwrite confirmed Empty Trash state")
        }
        var checking = false
        model.fixture = { input in
            if input["operation"] as? String == "empty_trash" { return try data(["account_id":"owner", "ok":true]) }
            checking = true
            try await Task.sleep(nanoseconds: 100_000_000)
            return try data(["account_id":"owner", "files":[], "next_page_token":""])
        }
        let pending = Task { await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.") }
        try await waitFor { checking }
        model.configure(context("other", kind:.desktopOAuth))
        _ = await pending.value
        precondition(model.trash.isEmpty && model.notice == nil && model.error == nil && !model.isMutating
                     && !model.isConfirmingEmptyTrash && !model.hasPendingEmptyTrash,
                     "A confirmation cannot cross an account switch")
        print("PASS Empty Trash: stale successes, stale failures and account-switch replies cannot restore old rows")
    }

    @MainActor static func emptyTrashSupersededByUndo() async throws {
        let model = PikPakManagementModel(); model.configure(context(kind: .desktopOAuth))
        defer { model.clear() }
        var accepted = false, checking = false, reads = 0
        var rows = [file("restored")]
        model.fixture = { input in
            if input["operation"] as? String == "empty_trash" {
                accepted = true
                return try data(["account_id":"owner", "ok":true])
            }
            reads += 1
            if accepted && !checking {
                checking = true
                try await Task.sleep(nanoseconds: 100_000_000)
                return try data(["account_id":"owner", "files":[], "next_page_token":""])
            }
            return try data(["account_id":"owner", "files":rows, "next_page_token":""])
        }
        await model.load(6)
        let pending = Task { await model.mutate("empty_trash", values:["confirmed":true], section:6, success:"Trash emptied.") }
        try await waitFor { checking }
        rows = [file("new-trash")]
        model.fileTrashChanged([FinderFileMutation(fileId:"restored", kind:.trash, before:"true", after:"false", parentId:nil, name:nil)])
        _ = await pending.value
        try await waitFor { reads >= 3 && !model.isLoading }
        precondition(model.trash.map(\.id) == ["new-trash"] && model.notice != "Trash emptied."
                     && !model.hasPendingEmptyTrash && !model.isMutating,
                     "An Undo supersedes an older Empty Trash confirmation and refreshes current rows")
        print("PASS Empty Trash: Undo supersedes an in-flight completion check")
    }

    static func fileLimitError() -> PikPakManagementError {
        .fromHelper(#"error: API error 416: {"error":"task_sub_task_num_limit","error_code":8,"error_description":"The current link contains too many files, which exceeds the processing capacity and cannot be added","error_details":[]}"#)
    }

    @MainActor static func cloudTaskFailures() async throws {
        let limit = fileLimitError()
        precondition(limit.isTaskFileLimit && limit.isDefiniteRejection)
        precondition(limit.technicalDetails?.contains("416") == true)
        precondition(!limit.localizedDescription.contains("error_details"))
        let other416 = PikPakManagementError.fromHelper(#"error: API error 416: {"error":"different_limit","error_code":8,"error_description":"Other rejection"}"#)
        precondition(!other416.isTaskFileLimit && other416.isDefiniteRejection, "HTTP 416 or numeric code 8 alone must not trigger torrent guidance")
        precondition(other416.localizedDescription == "Other rejection")
        let nestedBody = try data(["error":"monthly_limit", "error_description":String(decoding: data(["title":"Quota exceeded","description":"Review allowance","button_right":["text":"Untrusted","link":"https://example.test"]]),as:UTF8.self)])
        let nested = PikPakManagementError.fromHelper("error: API error 400: " + String(decoding:nestedBody,as:UTF8.self))
        precondition(nested.localizedDescription == "Quota exceeded\nReview allowance", "Provider dialog JSON becomes text, without its action links")
        let redacted = PikPakManagementError.fromHelper(#"error: API error 400: {"error":"invalid","error_description":"Bearer private-token eyJzdWIiOiIxIn0.e30.signature"}"#)
        precondition(!redacted.localizedDescription.contains("private-token") && !redacted.localizedDescription.contains("eyJ"))
        for status in [408, 500, 502, 503] {
            precondition(!PikPakManagementError.fromHelper("error: API error \(status): unavailable").isDefiniteRejection)
        }
        precondition(PikPakManagementError.fromHelper("error: authentication failed: PikPak denied this action.").isDefiniteRejection)

        let model = PikPakManagementModel(); model.configure(context())
        let source = "magnet:?xt=urn:btih:1111111111111111111111111111111111111111"
        var creates = 0, invalidations = 0
        model.onFilesChanged = { invalidations += 1 }
        model.fixture = { input in
            if input["operation"] as? String == "list_tasks" {
                return try data(["account_id":"owner","tasks":[],"next_page_token":""])
            }
            creates += 1
            throw fileLimitError()
        }
        let rejected = await model.mutate("create_task",values:["url":source],section:4,success:"Created")
        precondition(rejected == nil && creates == 1 && invalidations == 0 && model.notice == nil && !model.isMutating)
        precondition(model.cloudTaskFailure?.requiresDifferentLink == true && model.cloudTaskFailure?.isUncertain == false)
        precondition(model.error?.contains("7,000") == true && model.error?.contains("may have accepted") == false && !model.hasListError)
        await model.load(4)
        precondition(model.cloudTaskFailure != nil, "Refreshing the list does not remove guidance from the retained draft")
        _ = await model.mutate("create_task",values:["url":source + "&dn=Renamed&tr=https://example.test/tracker"],section:4,success:"Created")
        precondition(creates == 1, "Renaming the same torrent or changing its destination must not resubmit a file-count rejection")
        model.fixture = { input in
            if input["operation"] as? String == "create_task" { creates += 1; return try data(["account_id":"owner","task":taskData()]) }
            return try data(["account_id":"owner","tasks":[taskData()],"next_page_token":""])
        }
        let created = await model.mutate("create_task",values:["url":"https://example.test/smaller.zip"],section:4,success:"Created")
        precondition(created != nil && creates == 2 && model.cloudTaskFailure == nil && model.error == nil && model.notice == "Created")

        model.fixture = { _ in throw PikPakManagementError.fromHelper("error: API error 503: unavailable") }
        _ = await model.mutate("create_task",values:["url":source],section:4,success:"Created")
        precondition(model.cloudTaskFailure?.isUncertain == true && model.cloudTaskFailure?.requiresDifferentLink == false)
        precondition(model.error?.contains("before trying again") == true && model.error?.contains("may have accepted") == true)
        model.fixture = { _ in throw PikPakManagementError.fromHelper(#"error: API error 400: {"error":"invalid_url","error_description":"Invalid link"}"#) }
        _ = await model.mutate("create_share",values:[:],section:5,success:"Created")
        precondition(model.error == "Invalid link", "Definite share rejections also omit the uncertain-outcome warning")

        model.configure(context("other"))
        precondition(model.cloudTaskFailure == nil && model.error == nil, "A new account must not inherit a rejected draft")
        model.fixture = { _ in try await Task.sleep(nanoseconds:40_000_000); throw fileLimitError() }
        let pending = Task { await model.mutate("create_task",values:["url":source],section:4,success:"Created") }
        try await Task.sleep(nanoseconds:5_000_000)
        model.configure(context("next")); _ = await pending.value
        precondition(model.cloudTaskFailure == nil && model.error == nil && !model.isMutating, "Late rejections stay with the originating account")

        var task = taskData(); task["phase"] = "PHASE_TYPE_ERROR"; task["message"] = PikPakManagementError.taskFileLimitCode
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let failedTask = try decoder.decode(PikPakCloudTask.self,from:data(task))
        precondition(failedTask.hasFileCountLimit && failedTask.isFailed)
    }

    @MainActor static func cloudTaskRemovalConfirmation() async throws {
        let model = PikPakManagementModel(); model.configure(context())
        defer { model.clear() }
        var mutations = 0
        var confirmation: PikPakManagementConfirmation?
        model.fixture = { input in
            if input["operation"] as? String == "remove_task" {
                precondition(confirmation == nil, "The native dialog must be dismissed before removal begins")
                mutations += 1
                return try data(["account_id":"owner", "ok":true])
            }
            return try data(["account_id":"owner", "tasks":[taskData()], "next_page_token":""])
        }
        await model.load(4)
        let value = PikPakManagementConfirmation(revision: model.revision, title:"Remove this cloud task?", message:"Generated task",
            button:"Remove Task", operation:"remove_task", ids:["task"], section:4)
        confirmation = value
        let removal = PikPakManagementConfirmation.submit(value, confirmation:&confirmation, management:model)
        precondition(confirmation == nil && removal != nil, "The button must synchronously dismiss and claim its action")
        precondition(PikPakManagementConfirmation.submit(value, confirmation:&confirmation, management:model) == nil)
        let second = PikPakManagementConfirmation(revision:model.revision, title:"Second", message:"Generated", button:"Remove Task",
            operation:"remove_task", ids:["task"], section:4)
        confirmation = second
        precondition(PikPakManagementConfirmation.submit(second, confirmation:&confirmation, management:model) == nil,
                     "A second confirmation cannot dispatch before the first reserved mutation starts")
        _ = await removal!.value
        precondition(mutations == 1 && model.tasks.isEmpty && model.notice == "Task removed.")
        precondition(PikPakManagementConfirmation.submit(value, confirmation:&confirmation, management:model) == nil,
                     "A repeated callback after completion must not remove the task twice")
        let nativeDismissed = PikPakManagementConfirmation(revision:model.revision, title:"Native dismissed", message:"Generated", button:"Remove Task",
            operation:"remove_task", ids:["task"], section:4)
        confirmation = nil
        let nativeRemoval = PikPakManagementConfirmation.submit(nativeDismissed, confirmation:&confirmation, management:model)
        precondition(nativeRemoval != nil, "Hosts that clear the native binding before the button callback must still dispatch")
        _ = await nativeRemoval!.value
        precondition(mutations == 2)
        confirmation = value
        model.configure(context("other"))
        precondition(PikPakManagementConfirmation.submit(value, confirmation:&confirmation, management:model) == nil && confirmation == nil,
                     "An old dialog cannot remove a task from a newly selected account")
        let queued = PikPakManagementConfirmation(revision:model.revision, title:"Queued", message:"Generated", button:"Remove Task",
            operation:"remove_task", ids:["task"], section:4)
        confirmation = queued
        let pending = PikPakManagementConfirmation.submit(queued, confirmation:&confirmation, management:model)!
        model.configure(context("third"))
        let rejected = await pending.value
        precondition(rejected == nil && mutations == 2 && !model.isMutating,
                     "A queued button callback must remain bound to its original account")
        print("PASS cloud-task confirmation: synchronous dismissal, single dispatch, repeated clicks and stale/queued account rejection")
    }

    @MainActor static func cloudTaskRemovalReconciliation() async throws {
        let model = PikPakManagementModel()
        defer { model.clear() }
        for failOldRead in [false, true] {
            model.configure(context())
            var slow = false, started = false, mutations = 0, invalidations = 0
            model.onFilesChanged = { invalidations += 1 }
            model.fixture = { input in
                if input["operation"] as? String == "remove_task" {
                    mutations += 1
                    return try data(["account_id":"owner", "ok":true])
                }
                let capturedSlow = slow
                if capturedSlow {
                    started = true
                    try await Task.sleep(nanoseconds:100_000_000)
                    if failOldRead { throw PikPakManagementError.api(status:503, code:nil, message:"An older task listing failed") }
                }
                var removed = taskData(); removed["phase"] = mutations > 0 ? "PHASE_TYPE_COMPLETE" : "PHASE_TYPE_RUNNING"
                var other = taskData(); other["id"] = "other"
                return try data(["account_id":"owner", "tasks":[removed,other],
                                 "next_page_token":(input["page_token"] as? String ?? "").isEmpty ? "next" : ""])
            }
            await model.load(4)
            slow = true
            let oldRead = Task { await model.load(4) }
            try await waitFor { started }
            _ = await model.mutate("remove_task", values:["id":"task", "confirmed":true], section:4, success:"Task removed.")
            await oldRead.value
            precondition(model.tasks.map(\.id) == ["other"] && model.error == nil && model.notice == "Task removed.",
                         "Old task-list successes and failures cannot undo acknowledged removal")
            slow = false
            await model.load(4); await model.load(4, more:true)
            precondition(model.tasks.map(\.id) == ["other"] && mutations == 1 && invalidations == 0,
                         "Stale refreshes and older pages cannot resurrect a removed task or invalidate saved files")
            model.configure(context())
            await model.load(4)
            precondition(model.tasks.contains { $0.id == "task" }, "Removal exclusions belong only to their configured account context")
            model.fixture = { _ in throw PikPakManagementError.fromHelper("error: API error 403: Removal denied") }
            let denied = await model.mutate("remove_task", values:["id":"task"], section:4, success:"Task removed.")
            precondition(denied == nil && model.tasks.contains { $0.id == "task" } && model.notice == nil)
        }
        print("PASS cloud-task removal: acknowledged rows disappear, stale/in-flight/paginated replies stay excluded, failures preserve rows and accounts remain isolated")
    }

    static func taskData() -> [String: Any] {
        ["id":"task","name":"Travel photos.zip","file_name":"Travel photos.zip","file_id":"item","phase":"PHASE_TYPE_RUNNING",
         "progress":42,"size":1234567890,"message":"","created_time":"2026-09-16T10:00:00Z"]
    }
    static func shareData() -> [String: Any] {
        ["id":"share","title":"Summer photos","url":"https://mypikpak.com/s/fixture","pass_code":"abcd","status":"OK",
         "expires_at":"2026-09-23T10:00:00Z","created_time":"2026-09-16T10:00:00Z","views":24,"saves":3,"size":4096]
    }
    @MainActor static func launchUI() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 150,y:150,width:1150,height:790), styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "PikPak management · Offline fixture"
        window.contentView = NSHostingView(rootView: ManagementFixtureView())
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); app.run()
    }
}

@MainActor private struct ManagementFixtureView: View {
    @StateObject private var model: DownloaderModel
    @State private var section = 4
    @StateObject private var navigation = FinderWorkspaceNavigation()
    init() {
        let defaults = UserDefaults(suiteName:"com.wky.ManagementUI.fixture")!
        defaults.removePersistentDomain(forName:"com.wky.ManagementUI.fixture")
        let model = DownloaderModel.sharedSelectionFixture(defaults:defaults)
        model.pikpakManagement.configure(PikPakManagementTests.context())
        model.pikpakManagement.fixture = { input in
            var result: [String: Any] = ["account_id":"owner","next_page_token":""]
            switch input["operation"] as? String {
            case "list_tasks": result["tasks"] = [PikPakManagementTests.taskData()]
            case "list_shares": result["shares"] = [PikPakManagementTests.shareData()]
            case "list_trash", "pick_files": result["files"] = [PikPakManagementTests.file("a", name:"Holiday.jpg"),PikPakManagementTests.file("b",name:"Archive",folder:true)]
            case "create_share": result["share"] = PikPakManagementTests.shareData()
            case "create_task":
                if CommandLine.arguments.contains("--task-limit") { throw PikPakManagementTests.fileLimitError() }
                if CommandLine.arguments.contains("--task-uncertain") { throw PikPakManagementError.fromHelper("error: API error 503: PikPak is temporarily unavailable") }
                result["task"] = PikPakManagementTests.taskData()
            default: result["ok"] = true
            }
            return try PikPakManagementTests.data(result)
        }
        _model = StateObject(wrappedValue:model)
    }
    var body: some View {
        HStack(spacing:0) {
            FinderDriveSidebar(navigation:navigation,settings:model.finderSettings,accountSubtitle:"Offline fixture",showsContentMode:true,
                sections:FinderWorkspaceSection.allCases,select:{ section = max(4,$0); navigation.showImmediately(section) }) { Text("Fixture account\nNo network requests").font(.caption).padding() }
                .frame(width:195)
            Divider()
            PikPakManagementWorkspace(model:model, management:model.pikpakManagement, section:section,openBrowser:{})
                .padding(14).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.tint(FinderAppearance.accent).onAppear { navigation.showImmediately(4) }
    }
}
