import SwiftUI

/// Keep the Links identity stable for cached workspace state. The removed
/// Tasks section (2) is never a valid navigation destination.
enum FinderWorkspaceSection: Int, CaseIterable, Identifiable {
    case browser = 0, transfers = 1, links = 3
    var id: Int { rawValue }
    var title: String {
        switch self { case .browser: return "Browser"; case .transfers: return "Transfers"; case .links: return "Links" }
    }
    var symbol: String {
        switch self { case .browser: return "cloud"; case .transfers: return "arrow.up.arrow.down"; case .links: return "link" }
    }
    var shortcut: Int { self == .links ? 3 : rawValue + 1 }
}

@MainActor
final class FinderWorkspaceLoadingState: ObservableObject {
    @Published fileprivate(set) var request: FinderWorkspaceNavigation.Request?
}

/// Highlight a requested workspace before preparing a large view. A newer
/// request cancels the old one; only the view that actually appears can finish it.
@MainActor
final class FinderWorkspaceNavigation: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let section: Int
        var title: String { section == 3 ? "Opening Links…" : "Opening Browser…" }
    }

    @Published private(set) var section = 0
    let loading = FinderWorkspaceLoadingState()
    // Loading has its own observable object: showing/hiding a spinner must
    // not invalidate every row in the underlying file view.
    private(set) var request: Request? {
        get { loading.request }
        set { loading.request = newValue }
    }
    private var preparation: Task<Void, Never>?
    var highlightedSection: Int { request?.section ?? section }
    var isSwitching: Bool { request != nil }
    var presentationKey: String { "\(section):\(request?.id.uuidString ?? "ready")" }

    func select(_ target: Int, needsLoading: Bool, prepare: @escaping @MainActor () -> Bool) {
        guard FinderWorkspaceSection(rawValue: target) != nil, request?.section != target else { return }
        cancel()
        guard target != section else { return }
        guard needsLoading else {
            if prepare() { section = target }
            return
        }
        let next = Request(section: target)
        request = next
        preparation = Task { [weak self] in
            // Allow the requested tab and loading overlay to paint first.
            // This is one frame opportunity, not a minimum spinner duration.
            #if WORKSPACE_SWITCH_PROFILING
            // An offline visual fixture can hold this state for inspection.
            let inspectionDelay = Bundle.main.object(forInfoDictionaryKey: "WorkspaceSwitchInspectionDelay") as? Double ?? 0
            let delay = UInt64(max(0.02, inspectionDelay) * 1_000_000_000)
            #else
            let delay: UInt64 = 20_000_000
            #endif
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.request?.id == next.id, !Task.isCancelled else { return }
            if prepare() { self.section = target }
            else { self.cancel() }
        }
    }

    func didPresent(_ id: UUID) {
        guard request?.id == id, request?.section == section else { return }
        request = nil
        preparation = nil
    }

    func showImmediately(_ target: Int) {
        guard FinderWorkspaceSection(rawValue: target) != nil else { return }
        cancel()
        if section != target { section = target }
    }

    func cancel() {
        preparation?.cancel()
        preparation = nil
        request = nil
    }

    #if FINDER_WORKSPACE_TESTS
    func waitForPreparation() async { await preparation?.value }
    #endif
}

struct FinderWorkspaceSidebarTab: View {
    @ObservedObject var loading: FinderWorkspaceLoadingState
    let title: String
    let symbol: String
    let section: Int
    let currentSection: Int
    let action: () -> Void

    var body: some View {
        FinderSidebarTab(title: title, symbol: symbol,
            selected: (loading.request?.section ?? currentSection) == section, action: action)
    }
}

struct FinderWorkspaceTransitionOverlay: View {
    @ObservedObject var loading: FinderWorkspaceLoadingState

    var body: some View {
        if let request = loading.request { FinderWorkspaceLoadingOverlay(title: request.title) }
    }
}

struct FinderWorkspaceLoadingOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor).opacity(0.88)
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular).tint(FinderAppearance.accent)
                Text(title).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
