import AppKit
import Darwin
import SwiftUI

struct DuplicateLocalIdentity: Codable, Hashable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func read(_ path: String) -> Self? {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        return .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino),
            size: UInt64(max(0, value.st_size)), modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}

/// The selected folders to compare. Each scan reads the current files and metadata.
enum CrossDriveScope {
    static func object(cloudFolders: [(id: String, path: String)], localFolders: [URL]) -> [String: Any] {
        [
            "cloud_folders": cloudFolders.map { ["id": $0.id, "path": $0.path] },
            "local_paths": localFolders.map(\.path),
        ]
    }
}

enum CrossDriveDuplicatePolicy {
    static func recommendedIDs(_ files: [DuplicateFile]) -> [String] {
        let sorted = files.sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            if a.folderCreatedTime != b.folderCreatedTime {
                if let a = a.folderCreatedTime, let b = b.folderCreatedTime { return a < b }
                return a.folderCreatedTime == nil
            }
            let order = a.path.localizedStandardCompare(b.path)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        return sorted.dropFirst().filter { !$0.isLocal }.map(\.id)
    }

    static func validateKeepers(_ scan: DuplicateScan?, selected: Set<String>) throws {
        guard let scan else { throw CloudDriveError.message("Scan the selected drives again before moving duplicates to Trash.") }
        let known = Set(scan.groups.flatMap(\.files).filter { !$0.isLocal }.map(\.id))
        guard selected.isSubset(of: known) else {
            throw CloudDriveError.message("The deletion selection no longer belongs to this PikPak scan.")
        }
        for group in scan.groups where group.files.contains(where: { selected.contains($0.id) }) {
            let kept = group.files.filter { !selected.contains($0.id) }
            guard !kept.isEmpty else { throw CloudDriveError.message("Keep at least one copy from each duplicate group.") }
            if kept.contains(where: { !$0.isLocal }) { continue }
            guard kept.contains(where: { file in
                guard let identity = file.localIdentity else { return false }
                return DuplicateLocalIdentity.read(file.path) == identity
            }) else {
                throw CloudDriveError.message("The disk copy is disconnected or changed. Reconnect the disk and scan again before moving its PikPak copies to Trash.")
            }
        }
    }
}

#if FINDER_WORKSPACE_TESTS
extension CrossDriveDuplicatePolicy {
    static func testCrossDriveRecommendations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CrossDriveKeepers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("kept.txt")
        try Data("original".utf8).write(to: url)
        let disk = DuplicateFile(id: "local:" + url.path, name: "kept.txt", path: url.path, size: 8,
            modifiedTime: nil, source: "local", localIdentity: DuplicateLocalIdentity.read(url.path))
        let older = DuplicateFile(id: "old", name: "old.txt", path: "/Z/old.txt", size: 8,
            modifiedTime: nil, source: "pikpak", folderCreatedTime: "2020-01-01T00:00:00Z")
        let newer = DuplicateFile(id: "new", name: "new.txt", path: "/A/new.txt", size: 8,
            modifiedTime: nil, source: "pikpak", folderCreatedTime: "2026-01-01T00:00:00Z")
        precondition(recommendedIDs([newer, older]) == [newer.id], "Folder age must take priority over path order")
        precondition(Set(recommendedIDs([newer, disk, older])) == [newer.id, older.id])
        let group = DuplicateGroup(id: "exact", matchKind: .exactContent, size: 8, copies: 3, reclaimableBytes: 16,
            files: [newer, disk, older])
        let scan = DuplicateScan(rootPath: "Multiple drives", scannedFiles: 3, scannedFolders: 2, failedFolders: 0,
            duplicateFiles: 2, exactGroups: 1, possibleGroups: 0, reclaimableBytes: 16, groups: [group])
        try validateKeepers(scan, selected: [newer.id, older.id])
        func mustReject(_ ids: Set<String>) {
            do { try validateKeepers(scan, selected: ids); preconditionFailure("Unsafe keeper selection accepted") }
            catch { }
        }
        mustReject([disk.id])
        mustReject(["not-in-this-scan"])
        try Data("changed-content".utf8).write(to: url)
        mustReject([newer.id, older.id])
        try validateKeepers(scan, selected: [newer.id]) // The older PikPak copy is still kept.
        try FileManager.default.removeItem(at: url)
        mustReject([newer.id, older.id])
        print("PASS cross-drive duplicates: newer PikPak preference, disk copies kept, changed/offline keepers and invalid selections rejected before Trash")
    }
}
#endif

struct CrossDriveDuplicateScopeView: View {
    @ObservedObject var model: DownloaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check Duplicates Across Drives").font(.title2.weight(.semibold))
            Text("Compare the selected PikPak and disk folders, including their subfolders.")
                .foregroundStyle(.secondary)
            HStack {
                Label("PikPak folders", systemImage: "cloud")
                Spacer()
                Button("Add PikPak Folder…") { model.chooseDuplicateCloudFolder() }
            }
            ForEach(model.duplicateScopeCloudFolders) { folder in
                scopeRow("PikPak: \(folder.path)", symbol: "cloud") {
                    model.duplicateScopeCloudFolders.removeAll { $0.id == folder.id }
                }
            }
            Divider()
            HStack {
                Label("Folders on this Mac or external disks", systemImage: "externaldrive")
                Spacer()
                Button("Add Disk Folders…", action: chooseDiskFolders)
            }
            ForEach(model.duplicateScopeLocalFolders, id: \.self) { folder in
                scopeRow(folder.path, symbol: "externaldrive") { model.duplicateScopeLocalFolders.removeAll { $0 == folder } }
            }
            Text("Disk copies are kept. Recommended selections prefer redundant PikPak copies in newer folders. Review the selection before moving anything to Trash.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showsCrossDriveDuplicateScope = false }.keyboardShortcut(.cancelAction)
                Button("Check Duplicates") {
                    model.startCrossDriveDuplicateScan()
                    model.taskActivity.showsDetails = true
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.duplicateScopeCloudFolders.isEmpty && model.duplicateScopeLocalFolders.isEmpty)
            }
        }.padding(22).frame(width: 680)
            .sheet(item: $model.duplicateScopePicker, onDismiss: { model.duplicateScopePicker?.close() }) { picker in
                SimilarityScopePickerView(model: picker) { picker.close(); model.duplicateScopePicker = nil }
            }
    }

    private func scopeRow(_ path: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Label(path, systemImage: symbol).lineLimit(1).truncationMode(.middle).help(path)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this folder from the scan")
        }.padding(.horizontal, 8)
    }

    private func chooseDiskFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders on this Mac or external disks"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add Folders"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls where !model.duplicateScopeLocalFolders.contains(url) {
                    model.duplicateScopeLocalFolders.append(url)
                }
            }
        }
    }
}
