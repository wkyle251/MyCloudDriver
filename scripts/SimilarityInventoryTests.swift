import AppKit
import Foundation

@main struct SimilarityInventoryTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("similarity-inventory-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let refresh = root.appendingPathComponent("inventory-generated.jsonl")
        try Data().write(to: refresh)
        let sourceRoot = root.appendingPathComponent("copies")
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot) != nil)
        let alias = root.appendingPathComponent("inventory-alias.jsonl")
        try manager.createSymbolicLink(at: alias, withDestinationURL: refresh)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":alias.path], sourceRoot: sourceRoot) == nil)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot.appendingPathComponent("outside")) == nil)
        try Data("occupied".utf8).write(to: refresh)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot) == nil)
        print("PASS provider refresh accepts only an empty regular inventory in the owning request directory")

        let progress = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        progress.setFixtureProgress(["event":"progress","stage":"analysing","completed":100,"total":100,
            "counts":["files_discovered":100,"files_ready":100]])
        progress.setFixtureProgress(["event":"inventory_check"])
        precondition(progress.progress.stage == .checking && progress.progress.fraction == nil)
        progress.setFixtureProgress(["event":"discovery","found":0,"complete":false])
        precondition(progress.progress.stage == .checking)
        progress.setFixtureProgress(["event":"inventory_changed","total":2,"added":0,"removed":98,"changed":0])
        precondition(progress.progress.foundFiles == 2 && progress.progress.total == 2 && progress.progress.completed == 0)
        print("PASS checking progress stays indeterminate and deleted files reduce the displayed inventory")

        let providerRoot = root.appendingPathComponent("provider")
        try manager.createDirectory(at: providerRoot, withIntermediateDirectories: true)
        let gone = providerRoot.appendingPathComponent("gone.txt"), kept = providerRoot.appendingPathComponent("kept.txt")
        try Data("gone".utf8).write(to: gone); try Data("kept".utf8).write(to: kept)
        let selected = try [ICloudDriveProvider.item(gone), ICloudDriveProvider.item(kept)]
        let provider = ICloudDriveProvider(rootURL: providerRoot, kind: .local)
        try manager.removeItem(at: gone)
        let listed = try await provider.scanItems(selected, location: provider.root, progress: { _ in })
        precondition(listed.map(\.name) == ["kept.txt"])
        let disconnected = root.appendingPathComponent("disconnected")
        try manager.moveItem(at: providerRoot, to: disconnected)
        do {
            _ = try await provider.scanItems([], location: provider.root, progress: { _ in })
            preconditionFailure("An unavailable scan root must not certify an empty inventory")
        } catch {}
        print("PASS selected-file deletion is skipped and an unavailable drive stays an error")

        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : resources.appendingPathComponent("pikpak")
        let files = root.appendingPathComponent("files")
        try manager.createDirectory(at: files, withIntermediateDirectories: true)
        let original = String(repeating: "The garden has a pond, flowers, oak trees and a wooden bench. ", count: 60)
        let edited = String(repeating: "The station has a train, platforms, signals and a ticket office. ", count: 60)
        for name in ["keep.txt", "remove.txt", "edit.txt"] {
            try original.write(to: files.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let scan = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        scan.externalTitle = "Generated local files"; scan.externalScopeNames = [files.path]
        scan.families = ["text"]; scan.threshold = 0.8
        var rounds = 0, resolves: [String:Int] = [:]
        scan.streamExternalSources = { emit in
            rounds += 1
            if rounds == 2 {
                try manager.removeItem(at: files.appendingPathComponent("remove.txt"))
                try original.write(to: files.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
                try edited.write(to: files.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
            } else if rounds == 4 {
                // This refresh follows comparison: changes here must also
                // invalidate its ordinals before the final report is returned.
                try manager.removeItem(at: files.appendingPathComponent("new.txt"))
                try original.write(to: files.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
            }
            for url in try manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let item = try ICloudDriveProvider.item(url)
                try await emit(.init(id:item.id, name:item.name, path:url.path, size:item.bytes ?? 0,
                    localPath:url.path, revision:item.modified.map { String($0.timeIntervalSince1970) }))
            }
        }
        scan.resolveExternalSource = { id, _, _ in
            let url = URL(string: id)!
            resolves[url.lastPathComponent, default: 0] += 1
            return url
        }
        let config = SimilarityConfiguration(executable:engine, models:resources.appendingPathComponent("FileTwinModels"),
            worker:resources.appendingPathComponent("filetwin-worker"), dataDirectory:root.appendingPathComponent("index"),
            temporaryDirectory:root.appendingPathComponent("temporary"), environment:[:])
        func finish() async throws {
            let deadline = Date().addingTimeInterval(90)
            while scan.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
            precondition(!scan.isRunning && !scan.isPaused && scan.error == nil, scan.error ?? "Generated scan did not complete")
        }
        scan.start(config)
        try await finish()
        precondition(rounds == 6, "Expected initial listing and checks around both changed analysis/comparison passes: \(rounds)")
        precondition(Set(scan.report?.files?.map(\.name) ?? []) == ["keep.txt", "edit.txt", "late.txt"])
        precondition(scan.report?.analysedFiles == 3 && scan.report?.failedFiles == 0)
        precondition(resolves["keep.txt"] == 1 && resolves["edit.txt"] == 2, "Unchanged originals must reuse analysis; edited ones must be read again: \(resolves)")
        precondition(scan.report?.scoresRetained == 3)
        print("PASS actual helper catches additions, deletions and edits during analysis and after comparison; unchanged originals are acquired once")

        let saved = scan.savedSession!
        try manager.removeItem(at: files.appendingPathComponent("late.txt"))
        scan.start(config, resuming:saved)
        try await finish()
        precondition(Set(scan.report?.files?.map(\.name) ?? []) == ["keep.txt", "edit.txt"])
        precondition(scan.report?.analysedFiles == 2 && scan.report?.scoresRetained == 1)
        precondition(resolves["keep.txt"] == 1 && resolves["edit.txt"] == 2)
        print("PASS a resumed sealed comparison refreshes membership and never reuses scores for removed files")

        for url in try manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil) { try manager.removeItem(at: url) }
        scan.start(config, resuming:scan.savedSession!)
        try await finish()
        precondition(scan.report?.files?.isEmpty == true && scan.report?.analysedFiles == 0 && scan.report?.scoresRetained == 0)
        print("PASS deleting the entire file set produces an empty result without stale groups or comparisons")
    }
}
