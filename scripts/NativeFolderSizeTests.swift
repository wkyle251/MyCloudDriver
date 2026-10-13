import Foundation
import AppKit

/// Calculate on a folder sizes every folder below it, shows a spinner while it
/// walks, and never keeps a size past the listing it was measured from. Uses
/// generated folders, plus a newly created disk image for the external-disk case.

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.lock(); opened = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
}

/// A real folder walk that waits at a gate, so the in-progress state is observable.
private final class GatedProvider: NativeCloudDrive, @unchecked Sendable {
    let inner: ICloudDriveProvider
    let gate = Gate()
    var kind: CloudDriveKind { inner.kind }
    var root: CloudDriveLocation { inner.root }
    init(root: URL) { inner = ICloudDriveProvider(rootURL: root, kind: .local) }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        try await inner.list(location, offset: offset, search: search)
    }
    func measureFiles(_ items: [CloudDriveItem], location: CloudDriveLocation, directory: URL,
                      progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveMeasurement {
        while !gate.isOpen { try await Task.sleep(nanoseconds: 10_000_000) }
        return try await inner.measureFiles(items, location: location, directory: directory, progress: progress)
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        try await inner.materialize(item, directory: directory, progress: progress)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor struct NativeFolderSizeTests {
    static func wait(_ condition: () -> Bool, _ message: String, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out: \(message)")
    }
    static func hdiutil(_ arguments: [String]) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CloudDriveError.message(String(decoding: data, as: UTF8.self)) }
    }

    /// Parent 10,700 B: a 1,000, Sub1 5,000 (b 2,000 + Deep 3,000), Sub2 4,000, "Sub ü 4" 700, EmptySub 0.
    /// Other 500 and "Café Photos" 300 stand alone. The accented names must keep the same identity in
    /// a listing and in the size walk on every file system, which store such names differently.
    static func buildFixture(in root: URL) throws {
        let manager = FileManager.default
        for (path, size) in [("Parent/a.bin", 1_000), ("Parent/Sub1/b.bin", 2_000), ("Parent/Sub1/Deep/c.bin", 3_000),
                             ("Parent/Sub2/d.bin", 4_000), ("Parent/Sub ü 4/e.bin", 700),
                             ("Other/o.bin", 500), ("Café Photos/p.bin", 300)] {
            let url = root.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        try manager.createDirectory(at: root.appendingPathComponent("Parent/EmptySub"), withIntermediateDirectories: true)
    }

    fileprivate static func makeModel(root: URL, staging: URL, defaults: UserDefaults) async -> (NativeDriveModel, GatedProvider) {
        let provider = GatedProvider(root: root)
        let model = NativeDriveModel(kind: .local, temporaryRoot: staging, playbackSettings: .init(defaults: defaults))
        model.connect(provider)
        await wait({ !model.isLoading && model.visibleRows.contains { $0.item.name == "Parent" } }, "root listing")
        return (model, provider)
    }

    static func scenarios(root: URL, label: String, defaults: UserDefaults) async throws {
        try buildFixture(in: root)
        let staging = root.deletingLastPathComponent().appendingPathComponent("Staging-\(UUID().uuidString)")

        // 1. A folder shows a spinner while it is measured; every subfolder, including ones expanded afterwards, then has its size.
        do {
            let (model, provider) = await makeModel(root: root, staging: staging, defaults: defaults)
            defer { model.close() }
            func row(_ name: String) -> NativeDriveRow? { model.visibleRows.first { $0.item.name == name } }
            func size(_ name: String) -> UInt64? { row(name)?.item.bytes }
            precondition(!model.isMeasuringSize(row("Parent")!), "No spinner before Calculate (\(label))")
            model.measure([row("Parent")!.item])
            await wait({ model.isMeasuringSize(row("Parent")!) }, "spinner on the measured folder (\(label))")
            precondition(!model.isMeasuringSize(row("Other")!), "An unrelated folder must not show the spinner (\(label))")
            provider.gate.open()
            await wait({ !model.isMeasuringSize(row("Parent")!) }, "spinner clears when the walk finishes (\(label))")
            precondition(size("Parent") == 10_700 && size("Other") == nil, "Parent \(String(describing: size("Parent"))) (\(label))")
            model.toggleExpansion(row("Parent")!)
            await wait({ row("Sub1") != nil && row("Sub2") != nil && row("EmptySub") != nil && row("Sub ü 4") != nil }, "Parent expands (\(label))")
            precondition(size("Sub ü 4") == 700, "A folder whose name has a space and an accent is sized (\(label)): \(String(describing: size("Sub ü 4")))")
            precondition(size("Sub1") == 5_000 && size("Sub2") == 4_000 && size("EmptySub") == 0,
                         "Subfolders must be sized by the parent's Calculate: \(String(describing: size("Sub1"))) \(String(describing: size("Sub2"))) \(String(describing: size("EmptySub"))) (\(label))")
            model.toggleExpansion(row("Sub1")!)
            await wait({ row("Deep") != nil }, "Sub1 expands (\(label))")
            precondition(size("Deep") == 3_000, "A folder expanded after Calculate is sized when listed (\(label))")
            print("PASS [\(label)] Calculate shows a spinner, then sizes the folder and every subfolder, loaded or expanded later")
        }

        // 2. Folders already expanded show the spinner too (they have no size yet) and are all sized together.
        do {
            let (model, provider) = await makeModel(root: root, staging: staging, defaults: defaults)
            defer { model.close() }
            func row(_ name: String) -> NativeDriveRow? { model.visibleRows.first { $0.item.name == name } }
            func size(_ name: String) -> UInt64? { row(name)?.item.bytes }
            model.toggleExpansion(row("Parent")!)
            await wait({ row("Sub1") != nil }, "Parent expands (\(label))")
            model.toggleExpansion(row("Sub1")!)
            await wait({ row("Deep") != nil }, "Sub1 expands (\(label))")
            model.measure([row("Parent")!.item])
            await wait({ model.isMeasuringSize(row("Parent")!) }, "spinner on Parent (\(label))")
            precondition(model.isMeasuringSize(row("Sub1")!) && model.isMeasuringSize(row("Deep")!) && model.isMeasuringSize(row("Sub2")!),
                         "Unsized folders under the measured one show the spinner (\(label))")
            precondition(!model.isMeasuringSize(row("a.bin")!), "Files never show the spinner (\(label))")
            provider.gate.open()
            await wait({ !model.isMeasuringSize(row("Parent")!) }, "spinner clears (\(label))")
            precondition(size("Parent") == 10_700 && size("Sub1") == 5_000 && size("Deep") == 3_000 && size("Sub2") == 4_000,
                         "Already loaded subfolders are sized in the same pass (\(label))")
            precondition(!model.isMeasuringSize(row("Sub1")!) && !model.isMeasuringSize(row("Deep")!), "Spinners clear together (\(label))")
            print("PASS [\(label)] already expanded subfolders show the spinner and are sized in the same pass")
        }

        // 3. Several selected folders are all updated, overlapping ones counted once.
        do {
            let (model, provider) = await makeModel(root: root, staging: staging, defaults: defaults)
            defer { model.close() }
            provider.gate.open()
            func row(_ name: String) -> NativeDriveRow? { model.visibleRows.first { $0.item.name == name } }
            func size(_ name: String) -> UInt64? { row(name)?.item.bytes }
            model.toggleExpansion(row("Parent")!)
            await wait({ row("Sub1") != nil && row("Sub2") != nil }, "Parent expands (\(label))")
            model.measure([row("Sub1")!.item, row("Sub2")!.item, row("Other")!.item, row("Café Photos")!.item])
            await wait({ size("Sub1") != nil && size("Sub2") != nil && size("Other") != nil && size("Café Photos") != nil }, "all selected folders are sized (\(label))")
            precondition(size("Sub1") == 5_000 && size("Sub2") == 4_000 && size("Other") == 500 && size("Café Photos") == 300 && size("Parent") == nil,
                         "Only the selected folders and their subfolders are sized (\(label))")
            print("PASS [\(label)] Recalculate on several folders sizes each of them")
        }

        // 4. A refresh drops measured sizes, so a changed folder never keeps a stale number.
        do {
            let (model, provider) = await makeModel(root: root, staging: staging, defaults: defaults)
            defer { model.close() }
            provider.gate.open()
            func row(_ name: String) -> NativeDriveRow? { model.visibleRows.first { $0.item.name == name } }
            model.measure([row("Parent")!.item])
            await wait({ row("Parent")?.item.bytes == 10_700 && !model.isMeasuringSize(row("Parent")!) }, "Parent sized (\(label))")
            model.reload()
            await wait({ !model.isLoading && row("Parent")?.item.bytes == nil }, "reload clears the measured size (\(label))")
            model.toggleExpansion(row("Parent")!)
            await wait({ row("Sub1") != nil }, "Parent expands after reload (\(label))")
            precondition(row("Sub1")?.item.bytes == nil, "A refresh must not resurrect a measured subfolder size (\(label))")
            print("PASS [\(label)] reload discards measured sizes")
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let manager = FileManager.default
        let suite = "MyCloudDriver.NativeFolderSizeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NativeFolderSizeTests-\(UUID().uuidString)")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }

        let plain = base.appendingPathComponent("Plain Folder")
        try manager.createDirectory(at: plain, withIntermediateDirectories: true)
        try await scenarios(root: plain, label: "folder on this Mac", defaults: defaults)

        // Newly created disk images stand in for an external disk. Never touches a real disk.
        for filesystem in ["APFS", "Case-sensitive APFS", "HFS+", "ExFAT"] {
            let mount = base.appendingPathComponent("Disk \(filesystem)"), image = base.appendingPathComponent("Synthetic-\(filesystem.filter(\.isLetter)).dmg")
            var mounted = false
            defer { if mounted { try? hdiutil(["detach", mount.path, "-force"]) } }
            do {
                try hdiutil(["create", "-size", "64m", "-fs", filesystem, "-volname", "SizeTest", image.path])
                try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path]); mounted = true
            } catch { print("SKIP \(filesystem) disk image could not be mounted: \(error)"); continue }
            precondition(LocalFileAccess.volumeID(mount) != LocalFileAccess.volumeID(base), "Fixture must be a separate mounted volume")
            try await scenarios(root: mount, label: "external disk \(filesystem)", defaults: defaults)
        }
    }
}
