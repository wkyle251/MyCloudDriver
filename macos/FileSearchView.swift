import AppKit
import SwiftUI

/// Kept in a separate observed subtree: streaming search progress must not
/// invalidate every row of the Browser, Links, or Transfers views.
struct FileSearchOverlay: View {
    @ObservedObject var search: FileSearchModel
    let onReveal: (FileSearchNavigation) -> Void
    @State private var showsErrors = false

    var body: some View {
        if search.isPresented {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Color.black.opacity(0.14)
                        .contentShape(Rectangle())
                        .onTapGesture { search.close() }

                    palette(availableHeight: max(160, geometry.size.height - 80))
                        .frame(width: max(0, min(740, geometry.size.width - 32)))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                        .padding(.top, min(64, geometry.size.height * 0.08))
                }
            }
            .accessibilityIdentifier("fileSearchPalette")
            .onExitCommand { search.close() }
        }
    }

    private func palette(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                FileSearchField(
                    text: search.query,
                    placeholder: search.placeholder,
                    focusRequest: search.focusRequest,
                    onChange: search.updateQuery,
                    onMove: search.moveSelection,
                    onOpen: { search.openSelection(reveal: onReveal) },
                    onClose: search.close
                )
                .frame(minWidth: 0, minHeight: 30)
                if search.isScanning {
                    ProgressView().controlSize(.small)
                        .help("Searching the remaining folders; matches appear as they arrive")
                }
                Button("esc", action: search.close)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .buttonStyle(.bordered)
                    .help("Close search and stop its scan (Escape)")
                    .fixedSize()
            }
            .padding(12)

            Divider()
            HStack {
                Label(search.scopeTitle, systemImage: search.scope == .expanded ? "list.bullet.indent" : search.sourceSymbol)
                    .fixedSize()
                Text(search.contextName).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(search.scope.shortcut).font(.system(.caption, design: .monospaced)).fixedSize()
                if !search.query.isEmpty {
                    Text("\(search.totalMatches.formatted()) matches")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if search.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: search.query.isEmpty ? "text.magnifyingglass" : "doc.text.magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(emptyTitle).font(.headline)
                    Text(emptyDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .frame(maxHeight: min(190, availableHeight * 0.45))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(search.results) { result in
                                resultRow(result).id(result.id)
                            }
                            if search.totalMatches > search.results.count {
                                Button("Show more (\(search.results.count.formatted()) of \(search.totalMatches.formatted()))") {
                                    search.showMore()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .padding(12)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(height: min(CGFloat(search.results.count) * 54 + 10,
                                       min(400, max(100, availableHeight - (showsErrors ? 270 : 155)))))
                    .onChange(of: search.selectedID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }

            if !search.failures.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showsErrors) {
                    ScrollView {
                        Text(search.failures.joined(separator: "\n\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 100)
                } label: {
                    Label("Search needs attention · Show details", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if search.scope == .root && search.progress.discoveredFolders > 0 {
                        Text("\(search.indexedItems.formatted()) names · \(search.progress.scannedFolders.formatted()) of \(search.progress.discoveredFolders.formatted()) discovered folders scanned")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if search.isScanning {
                    Button("Stop Scan", action: search.stopScan).controlSize(.small)
                } else if search.scope == .root && !search.query.isEmpty {
                    Button(search.indexedItems == 0 ? "Scan" : "Scan Again", action: search.scanAgain)
                        .controlSize(.small)
                        .disabled(!search.canScan)
                }
                Text("↑↓ select   ↵ reveal")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(12)
        }
    }

    private var emptyTitle: String {
        if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Find a file or folder" }
        if search.scope == .expanded { return "No matching expanded items" }
        if search.isScanning { return search.isNative ? "Searching \(search.sourceName)…" : "Searching your PikPak…" }
        return search.isComplete ? "No matching names" : "No matches in the scanned folders yet"
    }

    private var emptyDetail: String {
        if search.scope == .expanded {
            if search.isNative {
                return search.query.isEmpty
                    ? "Search names already visible in the current tree. Use ⌘⇧F to search from this drive’s root."
                    : "Collapsed and not-yet-loaded items aren't included. Use ⌘⇧F to search from this drive’s root."
            }
            return search.query.isEmpty
                ? "Search names already visible in the current tree. Use ⌘⇧F to search your entire PikPak account."
                : "Collapsed and not-yet-loaded items aren't included. Use ⌘⇧F to search from PikPak root."
        }
        if search.query.isEmpty { return search.isNative
            ? "Start typing a name. Matches appear while the rest of this drive is scanned."
            : "Start typing a name. Matches appear while the rest of your account is scanned." }
        if search.isScanning { return "You don't need to wait for the scan to finish to open a result." }
        return search.isComplete ? "Try a shorter name or an abbreviation." : "Use Scan to keep searching, or check any error details below."
    }

    private var scanStatus: String {
        if search.scope == .expanded { return "\(search.indexedItems.formatted()) visible names · local search, no scan needed" }
        if search.isScanning { return search.indexedItems == 0 ? (search.isNative ? "Reading folder names…" : "Contacting PikPak…") : "Still searching · results update as folders arrive" }
        if search.isComplete { return "Scan complete · cached for this app session" }
        if search.indexedItems > 0 { return "Scan stopped or incomplete · showing cached matches" }
        return search.isNative ? "Searches file and folder names under the connected drive root; original content stays on the drive"
            : "Searches your account, excluding Trash and unsaved shared links"
    }

    private func resultRow(_ result: FileSearchMatch) -> some View {
        let selected = result.id == search.selectedID
        return Button {
            search.openSelection(result, reveal: onReveal)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: result.item.isFolder ? "folder.fill" : "doc")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? Color.white : (result.item.isFolder ? .accentColor : .secondary))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.item.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(result.parentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "return").font(.caption) }
            }
            .foregroundStyle(selected ? Color.white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(result.fullPath)
        .accessibilityLabel("\(result.item.name), \(result.parentPath)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A native text field keeps IME composition, selection and Command-A/C/V
/// intact, while routing only the palette's arrow/Return/Escape commands.
private struct FileSearchField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let focusRequest: UUID
    let onChange: (String) -> Void
    let onMove: (Int) -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.setAccessibilityLabel("Search files and folders by name")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FileSearchField
        var focusRequest: UUID?
        init(parent: FileSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onOpen()
            case #selector(NSResponder.cancelOperation(_:)): parent.onClose()
            default: return false
            }
            return true
        }
    }
}
