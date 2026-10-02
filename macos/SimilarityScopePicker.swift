import AppKit
import SwiftUI

struct SimilarityScopePage {
    let folders: [CloudDriveLocation]
    var nextPage: String?
}

@MainActor final class SimilarityScopePicker: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    @Published private(set) var stack: [CloudDriveLocation]
    @Published private(set) var folders: [CloudDriveLocation] = []
    @Published var selection: String?
    @Published var search = ""
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var nextPage: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pageTokens = Set<String>()
    private let load: (CloudDriveLocation, String?) async throws -> SimilarityScopePage
    private let accept: ([CloudDriveLocation]) -> Void
    var location: CloudDriveLocation { stack.last! }
    var path: String { stack.count == 1 ? "/" : "/" + stack.dropFirst().map(\.title).joined(separator: "/") }
    var visibleFolders: [CloudDriveLocation] { folders.filter { search.isEmpty || $0.title.localizedStandardContains(search) } }
    var choice: [CloudDriveLocation] {
        stack + (folders.first { $0.id == selection }.map { [$0] } ?? [])
    }
    init(title: String, prompt: String = "Use Folder", root: CloudDriveLocation,
         load: @escaping (CloudDriveLocation, String?) async throws -> SimilarityScopePage,
         accept: @escaping ([CloudDriveLocation]) -> Void) {
        self.title = title; self.prompt = prompt; self.stack = [root]; self.load = load; self.accept = accept
    }
    func reload(more: Bool = false) {
        if more && (isLoading || nextPage == nil) { return }
        task?.cancel(); let run = UUID(); generation = run
        let token = more ? nextPage : nil, folder = location
        if !more { folders = []; nextPage = nil; selection = nil; pageTokens = [] }
        isLoading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await AutomaticRecovery.read { try await self.load(folder, token) }
                try Task.checkCancellation()
                guard self.generation == run else { return }
                var seen = Set(self.folders.map(\.id))
                self.folders.append(contentsOf: page.folders.filter { seen.insert($0.id).inserted })
                self.folders.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                if let next = page.nextPage, !next.isEmpty {
                    guard self.pageTokens.insert(next).inserted else {
                        throw CloudDriveError.message("The drive repeated a page. Reload this folder to continue.")
                    }
                    self.nextPage = next
                } else { self.nextPage = nil }
            } catch {
                if self.generation == run && !(error is CancellationError) { self.error = FileSearchIndex.redacted(error.localizedDescription) }
            }
            if self.generation == run { self.isLoading = false; self.task = nil }
        }
    }
    func enter(_ folder: CloudDriveLocation) { stack.append(folder); search = ""; reload() }
    func back() { guard stack.count > 1 else { return }; stack.removeLast(); search = ""; reload() }
    func choose() { guard !isLoading && error == nil else { return }; accept(choice) }
    func close() { generation = UUID(); task?.cancel(); task = nil; isLoading = false }
}

struct SimilarityScopePickerView: View {
    @ObservedObject var model: SimilarityScopePicker
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title).font(.title2.weight(.semibold))
            Text("Choose the location to scan. Its contents and subfolders are included.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(model.stack.count == 1).help("Enclosing folder")
                Label(model.path == "/" ? model.location.title : model.path, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(model.path)
                Spacer()
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload folders")
            }
            TextField("Find a folder in this location", text: $model.search).textFieldStyle(.roundedBorder)
            List(selection: $model.selection) {
                ForEach(model.visibleFolders) { folder in
                    HStack {
                        Label(folder.title, systemImage: "folder.fill")
                        Spacer()
                        Button { model.enter(folder) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.borderless).help("Open \(folder.title)")
                    }.tag(folder.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.enter(folder) }
                }
            }.listStyle(.inset).overlay {
                if model.isLoading && model.folders.isEmpty { ProgressView("Loading folders…") }
                else if model.visibleFolders.isEmpty && model.error == nil {
                    Text(model.search.isEmpty ? "No subfolders here. You can use this location." : "No matching folders on this page.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.nextPage != nil {
                    Button("Load More Folders") { model.reload(more: true) }.disabled(model.isLoading)
                }
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(model.prompt) { model.choose(); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(model.isLoading || model.error != nil)
            }
        }.padding(22).frame(width: 600, height: 510)
            .buttonStyle(FinderButtonStyle()).tint(FinderAppearance.accent)
            .task { model.reload() }.onDisappear { model.close() }
    }
}
