import Foundation

@main
struct TaskActivityTests {
    @MainActor static func main() throws {
        let suite = "com.wky.PikPakTaskActivityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try DownloaderModel.testTaskActivity(defaults: defaults)
        let navigation = FinderWorkspaceNavigation()
        navigation.select(3, needsLoading: false) { true }
        navigation.select(2, needsLoading: false) { preconditionFailure("removed task workspace") }
        navigation.showImmediately(2)
        precondition(navigation.section == 3)
        precondition(FinderWorkspaceSection.allCases.map(\.title) == ["Browser", "Transfers", "Links"])
        precondition(FinderWorkspaceSection.links.shortcut == 3)
        let store = FinderTaskActivityStore()
        store.begin(.duplicates, scope: "/A", message: "Checking A")
        store.begin(.emptyFolders, scope: "/B", message: "Checking B")
        precondition(store.summary == "2 operations in progress")
        store.finish(.emptyFolders, state: .completed, message: "Removed empty folders")
        precondition(store.summary == "Checking A", "active work stays visible over completed jobs")
        store.update(.duplicates, message: "Still checking", fraction: .nan)
        precondition(store.tasks.last?.fraction == nil)
        store.begin(.duplicates, scope: "/C", message: "Checking C")
        precondition(store.tasks.count == 2 && store.tasks.first?.scope == "/C", "replace previous run without retaining stale results")
        print("PASS removed Tasks navigation, visible workspace shortcuts and simultaneous activity ordering")
    }
}
