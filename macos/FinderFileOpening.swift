import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FinderFileOpenConfiguration {
    let executable: URL
    let environment: [String: String]
    let arguments: [String]
    var requestData: Data? = nil
    let exchangeDirectory: URL
    let copiesDirectory: URL
    let proxyURL: String
}

enum FinderFileOpenStorage {
    static func safeFilename(_ name: String) -> String {
        let component = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        let safe = component.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "_")
        return safe.isEmpty || safe == "." || safe == ".." ? "PikPak File" : safe
    }

    static func originalURL(_ info: PreviewInfo) -> URL? {
        // Never hand another app an HLS playlist or a transcoded replacement.
        let sources = info.sources ?? []
        let originals = sources.filter(\.isOrigin)
        // The direct download has no codec metadata. Prefer it over media
        // streams; contentLink itself normally points at a preview transcode.
        let candidates = originals.filter { $0.videoCodec == nil }.map(\.contentURL)
            + originals.filter { $0.videoCodec != nil }.map(\.contentURL)
            + (sources.isEmpty ? [info.contentURL] : [])
        return candidates.compactMap { $0 }.first { $0.pathExtension.lowercased() != "m3u8" }
    }

    static func preserveDownload(_ temporary: URL, name: String, expectedSize: UInt64,
                                 directory: URL) throws -> URL {
        let manager = FileManager.default
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard expectedSize == 0 || UInt64(size) == expectedSize else {
            throw NSError(domain: "PikPakOpen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The file download was incomplete. Try Open again."])
        }
        let copyDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: copyDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = copyDirectory.appendingPathComponent(safeFilename(name), isDirectory: false)
        do {
            try manager.moveItem(at: temporary, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? manager.removeItem(at: copyDirectory)
            throw error
        }
    }
}

/// Opens complete local copies using Launch Services, just like Finder.
/// Requests capture their source and outlive selection/preview changes.
@MainActor
final class FinderFileOpener: ObservableObject {
    @Published private(set) var activeNames: [String: String] = [:]
    var onStatus: (String, Bool) -> Void = { _, _ in }
    private var tasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: Process] = [:]
    private var localCopies: [String: URL] = [:]
    private var generation = UUID()

    var resourceProcessNames: [Int32: String] {
        Dictionary(processes.compactMap { identity, process in
            guard process.isRunning else { return nil }
            return (process.processIdentifier, activeNames[identity] ?? "File")
        }, uniquingKeysWith: { _, new in new })
    }

    // Injection points let offline tests exercise cancellation and handoff.
    var resolve: ((FinderFileOpenConfiguration) async throws -> PreviewInfo)?
    var download: ((URL, String) async throws -> (URL, URLResponse))?
    var launch: (URL, URL?) async throws -> Void = { file, application in
        let configuration = NSWorkspace.OpenConfiguration()
        if let application {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(file, configuration: configuration)
        }
    }

    func open(identity: String, name: String, application: URL?, configuration: FinderFileOpenConfiguration) {
        guard tasks[identity] == nil else {
            onStatus("\(name) is already downloading to open.", false)
            return
        }
        let requestGeneration = generation
        activeNames[identity] = name
        tasks[identity] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration {
                    self.tasks[identity] = nil
                    self.activeNames[identity] = nil
                    self.processes[identity] = nil
                }
            }
            var unopenedCopy: URL?
            do {
                let file: URL
                if let cached = self.localCopies[identity], FileManager.default.fileExists(atPath: cached.path) {
                    file = cached
                } else {
                    self.onStatus("Downloading \(name) to open…", false)
                    let info: PreviewInfo
                    if let resolve = self.resolve { info = try await resolve(configuration) }
                    else { info = try await self.fetchInfo(configuration, identity: identity) }
                    try Task.checkCancellation()
                    guard let source = FinderFileOpenStorage.originalURL(info) else {
                        throw NSError(domain: "PikPakOpen", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "PikPak has not provided an original file to open."])
                    }
                    let session = URLSession(configuration: PreviewTransport.configuration(proxyURL: configuration.proxyURL))
                    defer { session.invalidateAndCancel() }
                    let result: (URL, URLResponse)
                    if let download = self.download { result = try await download(source, configuration.proxyURL) }
                    else {
                        var request = URLRequest(url: source)
                        for (field, value) in PreviewTransport.mediaHeaders { request.setValue(value, forHTTPHeaderField: field) }
                        request.setValue("*/*", forHTTPHeaderField: "Accept")
                        result = try await session.download(for: request)
                    }
                    defer { try? FileManager.default.removeItem(at: result.0) }
                    try Task.checkCancellation()
                    guard let response = result.1 as? HTTPURLResponse, response.statusCode == 200 else {
                        throw NSError(domain: "PikPakOpen", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "PikPak's file server could not return the complete file. Try Open again."])
                    }
                    file = try FinderFileOpenStorage.preserveDownload(result.0, name: name, expectedSize: info.size,
                                                                      directory: configuration.copiesDirectory)
                    unopenedCopy = file
                }
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { throw CancellationError() }
                try await self.launch(file, application)
                // External apps may keep the document open and edit it. Keep
                // this copy across app exit; never apply Quick Look's expiry.
                unopenedCopy = nil
                guard self.generation == requestGeneration, !Task.isCancelled else { return }
                self.localCopies[identity] = file
                self.onStatus("Opened \(name). Changes to this local copy stay on this Mac.", false)
            } catch {
                if self.generation == requestGeneration, !Task.isCancelled {
                    self.onStatus("Could not open \(name): \(error.localizedDescription)", true)
                }
            }
            if let unopenedCopy { try? FileManager.default.removeItem(at: unopenedCopy.deletingLastPathComponent()) }
        }
    }

    func cancelAll() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        for process in processes.values where process.isRunning { process.terminate() }
        tasks.removeAll()
        processes.removeAll()
        activeNames.removeAll()
    }

    func reset() {
        cancelAll()
        localCopies.removeAll()
    }

    private func fetchInfo(_ configuration: FinderFileOpenConfiguration, identity: String) async throws -> PreviewInfo {
        let directory = configuration.exchangeDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        var arguments = configuration.arguments
        if let data = configuration.requestData {
            let request = directory.appendingPathComponent("request.json")
            try data.write(to: request)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
            arguments += ["--request-file", request.path]
        }
        let output = directory.appendingPathComponent("response.json")
        guard manager.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = configuration.executable
        process.currentDirectoryURL = directory
        process.environment = configuration.environment
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        processes[identity] = process
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        guard code == 0 else {
            throw NSError(domain: "PikPakOpen", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "PikPak could not prepare the file (code \(code)). Check your connection and account, then retry."])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PreviewInfo.self, from: Data(contentsOf: output))
    }
}

@MainActor
enum FinderFileApplications {
    struct Application: Identifiable {
        let id: URL
        let name: String
        let isDefault: Bool
        let icon: NSImage
    }
    private static var cache: [String: (Date, [Application])] = [:]

    static func applications(for item: BrowserItem) -> [Application] {
        #if BROWSER_SCROLL_PROFILING
        BrowserScrollDiagnostics.applicationLookups += 1
        #endif
        let type = UTType(filenameExtension: item.normalizedFileExtension)
            ?? item.mimeType.flatMap { UTType(mimeType: $0) } ?? .data
        if let cached = cache[type.identifier], Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        let workspace = NSWorkspace.shared
        let defaultURL = workspace.urlForApplication(toOpen: type)?.resolvingSymlinksInPath().standardizedFileURL
        let urls = Set((workspace.urlsForApplications(toOpen: type) + [defaultURL].compactMap { $0 })
            .map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let names = Dictionary(uniqueKeysWithValues: urls.map { url in
            (url, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        })
        let nameCounts = Dictionary(grouping: names.values, by: { $0 }).mapValues(\.count)
        let apps = urls.map { url in
            var name = names[url] ?? url.deletingPathExtension().lastPathComponent
            if (nameCounts[name] ?? 0) > 1,
               let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty { name += " (\(version))" }
            let icon = (workspace.icon(forFile: url.path).copy() as? NSImage) ?? NSImage(size: BrowserContextMenuStyle.iconSize)
            icon.size = BrowserContextMenuStyle.iconSize
            icon.isTemplate = false
            return Application(id: url, name: name, isDefault: url == defaultURL, icon: icon)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.path < $1.id.path : order == .orderedAscending
        }
        cache[type.identifier] = (Date(), apps)
        return apps
    }

    static func chooseApplication(for name: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Open \(name) With"
        panel.prompt = "Open"
        panel.message = "Choose an application to open “\(name)”."
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let application = panel.url {
                completion(application.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

struct FinderFileOpenMenu: View {
    let item: BrowserItem
    let enabled: Bool
    let open: (URL?) -> Void
    let chooseApplication: () -> Void

    var body: some View {
        Button { open(nil) } label: { BrowserContextMenuStyle.label("Open", systemImage: "arrow.up.forward.app") }
            .disabled(!enabled)
        Menu {
            let applications = FinderFileApplications.applications(for: item)
            ForEach(applications.filter(\.isDefault)) { applicationButton($0) }
            if applications.contains(where: \.isDefault), applications.contains(where: { !$0.isDefault }) { Divider() }
            ForEach(applications.filter { !$0.isDefault }) { applicationButton($0) }
            Divider()
            Button("Other…", action: chooseApplication)
                .help("Choose another application on this Mac")
        } label: {
            BrowserContextMenuStyle.label("Open With", systemImage: "app.dashed")
        }
        .disabled(!enabled)
        Divider()
    }

    private func applicationButton(_ application: FinderFileApplications.Application) -> some View {
        Button { open(application.id) } label: {
            Label {
                Text(application.name + (application.isDefault ? " (default)" : ""))
            } icon: {
                Image(nsImage: application.icon).renderingMode(.original)
            }
        }
        .help(application.id.path)
    }
}

struct FinderFileOpenStatus: View {
    @ObservedObject var opener: FinderFileOpener
    var compact = false
    var body: some View {
        if !opener.activeNames.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(compact ? "Opening \(opener.activeNames.count)" : "Opening \(opener.activeNames.count) file(s)…")
                    .font(.caption).lineLimit(1)
                Button { opener.cancelAll() } label: {
                    if compact { Image(systemName: "xmark.circle") }
                    else { Text("Cancel") }
                }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .help("Cancel opening files").accessibilityLabel("Cancel opening files")
            }
            .help(opener.activeNames.values.sorted().joined(separator: "\n"))
        }
    }
}

enum FinderQuickLookKeyAction: Equatable { case toggle, cancel, consumeRepeat, previous, next }

enum FinderQuickLookKeyboard {
    /// Match only unmodified preview keys. Device flags (Fn/numeric-pad and
    /// Caps Lock) do not turn Space into a different shortcut.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                       isFileWindow: Bool, isOwnedPreviewPanel: Bool,
                       hasSheet: Bool, isTextInput: Bool) -> FinderQuickLookKeyAction? {
        guard isFileWindow || isOwnedPreviewPanel, !hasSheet, !isTextInput,
              modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        if isOwnedPreviewPanel {
            if keyCode == 126 { return .previous }
            if keyCode == 125 { return .next }
        }
        guard keyCode == 49 || keyCode == 53 else { return nil }
        if isRepeat { return .consumeRepeat }
        return keyCode == 49 ? .toggle : .cancel
    }
}
