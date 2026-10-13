import SwiftUI

/// Folding affects presentation only. Header actions remain available and
/// paged row content is constructed only while its section is expanded.
struct DownloadTransferSection<Content: View, Actions: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int
    @Binding var isExpanded: Bool
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                        Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                        Text(title).font(.headline)
                        Text(count.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(color.opacity(0.10), in: Capsule())
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count.formatted()) files")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
                actions().buttonStyle(.borderless).controlSize(.small)
            }.padding(.horizontal, 13).padding(.vertical, 10)
            if isExpanded {
                Divider()
                content().frame(minHeight: 170, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .top)
    }
}
