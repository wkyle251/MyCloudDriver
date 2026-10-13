import Foundation

/// Generated folders and injected folder listings only. Nothing is fetched to decide whether a folder is empty.
@main struct BrowserEmptyFoldersTests {
    private struct Node { let id: String; let isFolder: Bool; let matches: Bool }
    private static func file(_ id: String, matches: Bool) -> Node { .init(id: id, isFolder: false, matches: matches) }
    private static func folder(_ id: String) -> Node { .init(id: id, isFolder: true, matches: true) }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        try ruleTests()
        preferenceTests()
        try await nativeTests()
        let suite = "com.wky.MyCloudDriver.EmptyFoldersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testBrowserEmptyFolders(defaults: defaults)
    }

    // MARK: The rule

    private static func ruleTests() throws {
        // nil means the folder's contents are not known: never opened, still loading, failed or more pages to come.
        let listings: [String: [Node]?] = [
            "A": [file("a1", matches: true)],
            "B": [file("b1", matches: false)],
            "C": [],
            "D": [folder("D1")], "D1": [file("d1", matches: false)],
            "E": [folder("E1")], "E1": [file("e1", matches: true)],
            "F": [folder("F1")], "F1": nil,
            "G": nil,
            "H": [folder("H")],
            "I": [folder("J")], "J": [folder("I")],
            "K": [file("k1", matches: false), folder("K1")], "K1": [folder("K2")], "K2": [file("k2", matches: true)],
        ]
        func empty(_ ids: [String]) -> Set<String> {
            BrowserEmptyFolders.emptyFolderIDs(among: ids, children: { listings[$0] ?? nil }, id: \.id, isFolder: \.isFolder, matches: \.matches)
        }
        let all = ["A", "B", "C", "D", "D1", "E", "E1", "F", "F1", "G", "H", "I", "J", "K", "K1", "K2"]
        precondition(empty(all) == ["B", "C", "D", "D1"], "Only folders known to hold nothing are empty: \(empty(all).sorted())")
        precondition(empty(["D"]) == ["D"] && empty(["E"]).isEmpty && empty(["A"]).isEmpty)
        precondition(empty(["F"]).isEmpty && empty(["G"]).isEmpty, "A folder with an unopened subfolder, or itself unopened, stays")
        precondition(empty(["H", "I", "J"]).isEmpty, "A folder that leads back to itself is never hidden")
        precondition(empty(["K", "K1", "K2"]).isEmpty, "A match several levels down keeps every folder above it")
        precondition(empty([]).isEmpty && empty(["not-a-listed-folder"]).isEmpty)
        print("PASS empty-folder rule: nested empties, matches several levels down, unknown folders, cycles and subsets")
    }

    // MARK: The setting

    @MainActor private static func preferenceTests() {
        let suite = "com.wky.MyCloudDriver.EmptyFoldersPreference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(BrowserEmptyFolders.preference(in: defaults), "Hiding empty folders is on until it is turned off")
        BrowserEmptyFolders.setPreference(false, in: defaults)
        precondition(!BrowserEmptyFolders.preference(in: defaults))
        BrowserEmptyFolders.setPreference(true, in: defaults)
        precondition(BrowserEmptyFolders.preference(in: defaults))
        print("PASS setting: starts on, remembers off and on")
    }

    // MARK: Local Disk, external disks, network shares, iCloud (one model)

    @MainActor private static func nativeTests() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BrowserEmptyFoldersTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        for path in ["Pics/Deep", "Docs", "Void", "Mixed/Inner", "Unopened"] {
            try manager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["Pics/a.jpg", "Pics/Deep/b.jpg", "Pics/Deep/notes.txt", "Docs/c.txt", "Mixed/Inner/d.txt", "Mixed/e.txt", "Unopened/f.txt", "top.jpg", "top.txt"] {
            try Data("generated".utf8).write(to: root.appendingPathComponent(path))
        }
        let suite = "com.wky.MyCloudDriver.EmptyFoldersNative.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func idle(_ model: NativeDriveModel) async throws {
            for _ in 0..<500 {
                if !model.isLoading && !model.tree.isLoading { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Fixture did not finish loading")
        }
        func names(_ model: NativeDriveModel) -> [String] { model.visibleRows.map { $0.item.name } }

        let model = NativeDriveModel(kind: .local, preferences: defaults)
        defer { model.close() }
        model.connect(ICloudDriveProvider(rootURL: root, kind: .local)); try await idle(model)
        precondition(model.hidesEmptyFolders, "A new window hides empty folders")
        let opened = ["Pics", "Docs", "Void", "Mixed"].map { name in model.items.first { $0.name == name }! }
        model.expandAllLevels(opened); try await idle(model)

        precondition(model.visibleHiddenFolderCount == 1 && !names(model).contains("Void")
                     && model.visibleRows.count == model.tree.rows.count - 1, "All Types hides the known-empty folder")
        model.fileTypeFilter = .category(.images)
        precondition(names(model) == ["Pics", "Deep", "b.jpg", "a.jpg", "Unopened", "top.jpg"],
                     "Folders without images, and folders inside them, are hidden; an unopened folder stays: \(names(model))")
        precondition(model.visibleHiddenFolderCount == 4, "Docs, Mixed, Inner and Void: \(model.visibleHiddenFolderCount)")
        let unopened = model.items.first { $0.name == "Unopened" }!
        precondition(!model.tree.branch(for: unopened).loaded, "Hiding empty folders never opens a folder")

        model.hidesEmptyFolders = false
        precondition(names(model) == ["Docs", "Mixed", "Inner", "Pics", "Deep", "b.jpg", "a.jpg", "Unopened", "Void", "top.jpg"] && model.visibleHiddenFolderCount == 0,
                     "Turning the option off brings every folder back: \(names(model))")
        precondition(!BrowserEmptyFolders.preference(in: defaults), "The choice is remembered")
        model.hidesEmptyFolders = true
        precondition(!names(model).contains("Docs") && BrowserEmptyFolders.preference(in: defaults))

        model.viewMode = 1
        precondition(names(model) == ["Pics", "Unopened", "top.jpg"], "Thumbnails hide them the same way: \(names(model))")
        model.viewMode = 0

        model.fileTypeFilter = .all
        let docs = model.tree.rows.first { $0.item.name == "Docs" }!
        model.select(docs, extending: false, toggling: false)
        precondition(model.selection == [docs.item.id])
        model.fileTypeFilter = .category(.images)
        precondition(model.selection.isEmpty, "A selected folder that disappears leaves the selection")
        model.fileTypeFilter = .all
        model.hidesEmptyFolders = false
        model.select(model.tree.rows.first { $0.item.name == "Void" }!, extending: false, toggling: false)
        precondition(model.selection.count == 1)
        model.hidesEmptyFolders = true
        precondition(model.selection.isEmpty, "Turning the option on drops folders it now hides from the selection")
        model.fileTypeFilter = .fileExtension("txt")
        precondition(names(model).contains("Docs") && names(model).contains("Inner") && !names(model).contains("Void") && names(model).contains("Pics"),
                     "A folder stays while it holds a match for the current filter: \(names(model))")

        let second = NativeDriveModel(kind: .local, preferences: defaults)
        defer { second.close() }
        precondition(second.hidesEmptyFolders, "Another window starts with the saved choice")
        BrowserEmptyFolders.setPreference(false, in: defaults)
        let third = NativeDriveModel(kind: .local, preferences: defaults)
        defer { third.close() }
        precondition(!third.hidesEmptyFolders)
        print("PASS Local Disk model: hides folders left empty by a type filter in list and thumbnails, keeps unopened folders, never loads, updates selection and remembers the choice")
    }
}
