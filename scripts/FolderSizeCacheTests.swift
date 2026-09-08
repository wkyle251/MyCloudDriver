import Foundation

@main
struct FolderSizeCacheTests {
    static func folder(_ id: String) -> FolderSizeEntry { .init(id: id, size: 999, isFolder: true) }
    static func file(_ id: String, _ size: UInt64) -> FolderSizeEntry { .init(id: id, size: size, isFolder: false) }
    static func size(_ bytes: UInt64, _ files: UInt64, _ folders: UInt64) -> FolderMeasurement {
        .init(totalBytes: bytes, fileCount: files, folderCount: folders)
    }
    static func fixture() -> FolderSizeIndex {
        var index = FolderSizeIndex()
        index.applyScan(rootID: "root", folders: [
            "root": size(175, 4, 4), "a": size(75, 3, 1), "nested": size(50, 2, 0),
            "b": size(100, 1, 0), "empty": .zero
        ], scannedListings: [
            "root": [folder("a"), folder("b"), folder("empty")],
            "a": [file("one", 25), folder("nested")],
            "nested": [file("two", 20), file("three", 30)], "b": [file("four", 100)], "empty": []
        ], parentIDs: [:])
        return index
    }
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) {
        precondition(condition(), text)
    }

    @MainActor static func main() throws {
        var cache = fixture()
        cache.remove(["two"])
        check(cache.measurements["root"] == size(155, 3, 4), "ancestor deletion delta")
        check(cache.measurements["a"] == size(55, 2, 1), "parent deletion delta")
        check(cache.measurements["nested"] == size(30, 1, 0), "direct deletion delta")
        check(cache.measurements["b"] == fixture().measurements["b"], "unrelated subtree survives")
        let afterDelete = cache
        cache.remove(["two"])
        check(cache == afterDelete, "replayed deletion is idempotent")
        check(cache.dirty.isEmpty, "known deletion requires zero API calls")
        print("PASS: exact deletion, all ancestors, sibling preservation, idempotence")

        cache = fixture()
        cache.remove(["a", "nested", "one", "two"])
        check(cache.measurements["root"] == size(100, 1, 2), "overlapping selected roots subtracted once")
        check(cache.measurements["nested"] == nil && cache.parents["three"] == nil, "descendant index removed")
        check(cache.measurements["b"] == size(100, 1, 0), "other branch retained")
        print("PASS: recursive folder deletion and overlapping multiselection")

        cache = fixture()
        cache.insertEmptyFolder(id: "new", parent: "nested")
        check(cache.measurements["root"] == size(175, 4, 5), "new empty folder changes only counts")
        check(cache.measurements["nested"] == size(50, 2, 1), "nested empty folder count")
        let afterCreate = cache
        cache.insertEmptyFolder(id: "new", parent: "nested")
        check(cache == afterCreate, "repeated create confirmation not counted twice")
        cache.reconcile(folderID: "new", entries: [file("added", 55)])
        check(cache.measurements["root"] == size(230, 5, 5), "new file propagated without recursion")
        check(cache.measurements["a"] == size(130, 4, 2), "new file reflected in intermediate folder")
        print("PASS: new folder/file and exact ancestor updates")

        cache = fixture()
        cache.move([folder("nested"), file("two", 20)], to: "b")
        check(cache.measurements["a"] == size(25, 1, 0), "move subtracts source")
        check(cache.measurements["b"] == size(150, 3, 1), "move adds destination")
        check(cache.measurements["root"] == size(175, 4, 4), "common ancestor net delta is zero")
        check(cache.measurements["nested"] == size(50, 2, 0), "moved subtree cache retained")
        let afterMove = cache
        cache.move([folder("nested")], to: "b")
        check(cache == afterMove, "replayed move is idempotent")
        print("PASS: moving folders, overlapping roots, common ancestor totals")

        cache = fixture()
        cache.markChanged("nested")
        check(cache.usableMeasurements["root"] == nil && cache.usableMeasurements["a"] == nil, "dirty ancestors excluded")
        check(cache.usableMeasurements["b"] == size(100, 1, 0), "clean branch still reusable")
        check(cache.repairRoot(for: "nested") == "root", "highest cached ancestor repaired")
        cache.applyScan(rootID: "root", folders: [
            "root": size(182, 5, 4), "a": size(82, 4, 1), "nested": size(57, 3, 0),
            "b": size(100, 1, 0), "empty": .zero
        ], scannedListings: ["nested": [file("two", 20), file("three", 30), file("added", 7)]], parentIDs: [:])
        check(cache.dirty.isEmpty && cache.entry("added") == file("added", 7), "incremental scan reconciles changed branch")
        check(cache.entry("four") == file("four", 100), "reused subtree keeps its original direct index")
        print("PASS: dirty-branch repair and clean-subtree reuse")

        cache = fixture()
        cache.reconcile(folderID: "nested", entries: [file("two", 27)])
        check(cache.measurements["root"] == size(152, 3, 4), "external changes from a complete listing")
        check(cache.parents["three"] == nil, "deleted external entry detached")
        let unchanged = cache
        check(!cache.reconcile(folderID: "nested", entries: [file("two", 27)]), "same listing produces no cache write")
        check(cache == unchanged, "listing retry is idempotent")
        cache.reconcile(folderID: "a", entries: [file("one", 25), folder("nested"), folder("unknown")])
        check(cache.dirty.contains("a") && cache.dirty.contains("root"), "unknown folder is not assumed empty")
        check(cache.usableMeasurements["b"] != nil, "unknown folder does not invalidate sibling")
        print("PASS: complete-listing reconciliation, idempotence, unknown-folder safety")

        let encoded = try JSONEncoder().encode(cache)
        let reopened = try JSONDecoder().decode(FolderSizeIndex.self, from: encoded)
        check(cache == reopened, "sizes, relationships, listing and dirty state survive relaunch")
        var legacy = FolderSizeIndex(measurements: ["parent": size(50, 2, 0), "other": size(60, 1, 0)])
        legacy.parents["old"] = "parent"
        legacy.remove(["old"])
        check(legacy.dirty == ["parent"], "legacy cache refreshes only the changed branch without guessing membership")
        check(legacy.measurements["other"] == size(60, 1, 0), "migration preserves unrelated old cache")
        legacy.move([file("not-in-baseline", 40)], to: "other")
        check(legacy.dirty.contains("other"), "legacy moves cannot guess whether an item was counted before")
        print("PASS: persistence round-trip and aggregate-only cache migration")

        cache = fixture()
        cache.parents["new-but-never-counted"] = "nested"
        cache.remove(["new-but-never-counted"])
        check(cache.measurements["root"] == size(175, 4, 4), "never subtract an item absent from the indexed baseline")

        cache = fixture()
        cache.measurements["nested"] = size(1, 1, 0)
        cache.remove(["two"])
        check(cache.dirty.contains("nested") && cache.dirty.contains("root"), "underflow triggers repair, not a fake zero")
        check(size(UInt64.max, 1, 0).replacing(.zero, with: size(1, 0, 0)) == nil, "overflow rejected")
        cache.parents["cycle-a"] = "cycle-b"
        cache.parents["cycle-b"] = "cycle-a"
        check(cache.ancestors(of: "cycle-a").count == 2, "malformed parent cycles terminate")
        print("PASS: overflow/underflow and cycle safety")

        var large = FolderSizeIndex()
        let entries = (0..<10_000).map { file("f\($0)", 10) }
        large.reconcile(folderID: "large", entries: entries)
        let start = Date()
        large.remove(Set((0..<2_000).map { "f\($0)" }))
        check(large.measurements["large"] == size(80_000, 8_000, 0), "large batch total")
        check(large.dirty.isEmpty, "large batch needs no rescan")
        print("PASS: 2,000 deletions from 10,000 items (\(Date().timeIntervalSince(start))s, zero rescans)")

        #if FOLDER_SIZE_TESTS
        try modelIntegrationTests()
        #endif
    }

    #if FOLDER_SIZE_TESTS
    @MainActor static func modelIntegrationTests() throws {
        try DownloaderModel.testIncrementalFolderSizes()
    }
    #endif
}
