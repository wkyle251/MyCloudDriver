import AppKit
import SwiftUI

/// A change to an existing cloud ID. Upload undo uses Trash, never a local path.
struct FinderFileMutation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case trash, move, rename }
    var id = UUID().uuidString
    let fileId: String
    let kind: Kind
    let before: String
    let after: String
    let parentId: String?
    let name: String?
    var requiresEmptyFolder = false

    var reversed: Self {
        Self(id: id, fileId: fileId, kind: kind, before: after, after: before,
             parentId: parentId, name: name, requiresEmptyFolder: requiresEmptyFolder)
    }
}

struct FinderUndoEntry: Identifiable, Equatable {
    var id = UUID()
    let title: String
    var mutations: [FinderFileMutation]
    var uploadBatchID: UUID?
}

struct FinderUndoRequest: Codable {
    let changes: [FinderFileMutation]
}

struct FinderUndoResult: Codable {
    let completed: [String]
    let error: String?
}

/// Separate from NSTextView's undo manager, so typing retains native undo.
struct FinderFileUndoHistory {
    private(set) var undoEntries: [FinderUndoEntry] = []
    private(set) var redoEntries: [FinderUndoEntry] = []
    private(set) var active: (entry: FinderUndoEntry, redo: Bool)?
    var undoTitle: String { undoEntries.last.map { "Undo \($0.title)" } ?? "Undo" }
    var redoTitle: String { redoEntries.last.map { "Redo \($0.title)" } ?? "Redo" }

    mutating func record(_ entry: FinderUndoEntry) {
        guard !entry.mutations.isEmpty else { return }
        // A resumed upload remains one logical action. Only that batch's own
        // IDs are combined; another upload with matching names is independent.
        var entry = entry
        if let batch = entry.uploadBatchID {
            let prior = undoEntries.filter { $0.uploadBatchID == batch }.flatMap(\.mutations)
            var merged = prior
            var positions = Dictionary(prior.enumerated().map { ($0.element.fileId, $0.offset) }, uniquingKeysWith: { first, _ in first })
            for mutation in entry.mutations {
                if let position = positions[mutation.fileId] { merged[position] = mutation }
                else { positions[mutation.fileId] = merged.count; merged.append(mutation) }
            }
            entry.mutations = merged
            undoEntries.removeAll { $0.uploadBatchID == batch }
        }
        undoEntries.append(entry)
        if undoEntries.count > 50 { undoEntries.removeFirst(undoEntries.count - 50) }
        redoEntries.removeAll()
    }

    mutating func begin(redo: Bool) -> FinderUndoRequest? {
        guard active == nil, let entry = redo ? redoEntries.last : undoEntries.last else { return nil }
        active = (entry, redo)
        return FinderUndoRequest(changes: redo ? entry.mutations : entry.mutations.reversed().map(\.reversed))
    }

    /// Advance only acknowledged IDs. A partially successful request leaves
    /// the remainder undoable and makes the completed portion redoable.
    mutating func finish(completed: [String]) -> [FinderFileMutation] {
        guard let active else { return [] }
        self.active = nil
        let confirmed = Set(completed)
        guard confirmed.isSubset(of: Set(active.entry.mutations.map(\.id))) else { return [] }
        let done = active.entry.mutations.filter { confirmed.contains($0.id) }
        guard !done.isEmpty else { return [] }
        let pending = active.entry.mutations.filter { !confirmed.contains($0.id) }
        if active.redo { _ = redoEntries.popLast() } else { _ = undoEntries.popLast() }
        if !pending.isEmpty {
            var rest = active.entry; rest.mutations = pending
            if active.redo { redoEntries.append(rest) } else { undoEntries.append(rest) }
        }
        var reversedEntry = active.entry; reversedEntry.id = UUID(); reversedEntry.mutations = done
        if active.redo { undoEntries.append(reversedEntry) } else { redoEntries.append(reversedEntry) }
        return active.redo ? done : done.reversed().map(\.reversed)
    }

    mutating func cancelRequest() { active = nil }
    mutating func reset() { self = Self() }
}

/// Refresh command validation after native focus or text-editing changes.
/// This does not intercept keystrokes or replace any text view's undo manager.
@MainActor final class FinderUndoCommandFocus: ObservableObject {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async { self?.objectWillChange.send() }
            return event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSText.didBeginEditingNotification, NSText.didEndEditingNotification, NSText.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
    }
    var editor: NSTextView? {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }
    var allowsFileActions: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return !window.isSheet && window.attachedSheet == nil && NSApp.modalWindow == nil && editor == nil
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
