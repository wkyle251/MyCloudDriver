import Foundation

enum ActivityLogLevel: String, CaseIterable, Identifiable {
    case debug, info, warning, error
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static func inferred(from message: String) -> Self {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:\d{4}-\d{2}-\d{2}[T ][\d:.+\-]+Z?\s+)?\[?(TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR)(?:\]|:|\s)"#
        if let match = value.range(of: pattern, options: .regularExpression) {
            let prefix = value[match].lowercased()
            if prefix.contains("error") { return .error }
            if prefix.contains("warn") { return .warning }
            if prefix.contains("debug") || prefix.contains("trace") { return .debug }
        }
        if value.hasPrefix("Could not ") || value.hasPrefix("Failed to ") { return .error }
        return .info
    }
}

enum ActivityLogFilter: String, CaseIterable, Identifiable {
    case all, debug, info, warning, error
    var id: String { rawValue }
    var title: String { self == .all ? "All levels" : rawValue.capitalized }
    func includes(_ level: ActivityLogLevel) -> Bool { self == .all || rawValue == level.rawValue }
}

struct ActivityLogEntry: Identifiable, Equatable {
    let id: UInt64
    let timestamp: Date
    var level: ActivityLogLevel
    var message: String
}

/// Bounded, chronological activity. Pipe reads can split a line anywhere;
/// finish that line before assigning its level. Retain errors when routine
/// download output fills the buffer so the Error filter stays useful.
struct ActivityLogBuffer {
    private(set) var entries: [ActivityLogEntry] = []
    private(set) var revision: UInt64 = 0
    private var nextID: UInt64 = 0
    private var pendingEntryID: UInt64?
    private var characterCount = 0
    private(set) var trimmed = false

    var text: String { entries.map(\.message).joined(separator: "\n") }
    var errorCount: Int { entries.lazy.filter { $0.level == .error }.count }
    var latestErrorID: UInt64? { entries.last(where: { $0.level == .error })?.id }
    func entries(matching filter: ActivityLogFilter) -> [ActivityLogEntry] {
        entries.filter { filter.includes($0.level) }
    }

    mutating func append(_ output: String, at timestamp: Date = Date()) {
        guard !output.isEmpty else { return }
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = normalized.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if let pendingEntryID, entries.last?.id == pendingEntryID {
                let last = entries.count - 1
                characterCount -= entries[last].message.count
                entries[last].message = bounded(entries[last].message + line)
                entries[last].level = .inferred(from: entries[last].message)
                characterCount += entries[last].message.count
            } else if !line.isEmpty {
                add(line, level: .inferred(from: line), at: timestamp)
                pendingEntryID = entries.last?.id
            }
            if index < lines.count - 1 { pendingEntryID = nil }
        }
        trim()
        revision &+= 1
    }

    mutating func record(_ message: String, level: ActivityLogLevel, at timestamp: Date = Date()) {
        guard !message.isEmpty else { return }
        pendingEntryID = nil
        add(message.trimmingCharacters(in: .newlines), level: level, at: timestamp)
        trim()
        revision &+= 1
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        pendingEntryID = nil
        characterCount = 0
        trimmed = false
        revision &+= 1
    }

    private func bounded(_ message: String) -> String {
        message.count > 16_000 ? String(message.prefix(16_000)) + "\n… message trimmed …" : message
    }

    private mutating func add(_ message: String, level: ActivityLogLevel, at timestamp: Date) {
        let message = bounded(message)
        nextID &+= 1
        entries.append(.init(id: nextID, timestamp: timestamp, level: level, message: message))
        characterCount += message.count
    }

    private mutating func trim() {
        guard characterCount > 120_000 || entries.count > 1_500 else { return }
        trimmed = true
        // Drop routine activity first, then warnings, then the oldest errors.
        var remove = Set<UInt64>()
        var retainedCount = entries.count
        for levels: Set<ActivityLogLevel> in [[.debug, .info], [.warning], [.error]] {
            for entry in entries where levels.contains(entry.level) {
                if characterCount <= 90_000 && retainedCount <= 1_000 { break }
                remove.insert(entry.id)
                characterCount -= entry.message.count
                retainedCount -= 1
            }
        }
        entries.removeAll { remove.contains($0.id) }
        if let pendingEntryID, remove.contains(pendingEntryID) { self.pendingEntryID = nil }
    }
}
