import SwiftUI

struct BrowserFileFilterMenu: View {
    @Binding var filter: BrowserFileFilter
    let extensions: [String]

    private var extensionChoices: [String] {
        var values = Set(extensions)
        if case .fileExtension(let value) = filter { values.insert(value) }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Menu {
            choice(.all)
            Divider()
            ForEach(BrowserFileCategory.allCases, id: \.self) { choice(.category($0)) }
            if !extensionChoices.isEmpty {
                Divider()
                Menu("File Extension") {
                    ForEach(extensionChoices, id: \.self) { choice(.fileExtension($0)) }
                }
            }
        } label: {
            Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isActive ? FinderAppearance.accent : Color.primary)
                .fixedSize()
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Filter loaded files by type. Folders stay visible. Current filter: \(filter.title)")
        .accessibilityLabel("Filter by file type").accessibilityValue(filter.title)
    }

    private func choice(_ value: BrowserFileFilter) -> some View {
        Button { filter = value } label: {
            if filter == value { Label(value.title, systemImage: "checkmark") }
            else { Text(value.title) }
        }
    }
}

struct BrowserFileFilterBar: View {
    @Binding var filter: BrowserFileFilter
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(filter.title, systemImage: "line.3.horizontal.decrease.circle.fill")
                .fontWeight(.medium).foregroundStyle(FinderAppearance.accent)
            Text("\(count.formatted()) \(count == 1 ? "file" : "files") shown")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Clear Filter") { filter = .all }
                .buttonStyle(.borderless).pointingHandCursor()
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(FinderAppearance.accent.opacity(0.05))
            .help("Filters loaded files in this view, including expanded rows in List. Folders stay visible so you can open them.")
    }
}

struct BrowserFileFilterEmptyState: View {
    @Binding var filter: BrowserFileFilter
    var hasMore = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No matching files").font(.headline)
            Text("No loaded files match \(filter.title)."
                 + (hasMore ? " Load more items or choose another type." : " Choose another type or clear the filter."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Clear Filter") { filter = .all }.pointingHandCursor()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
