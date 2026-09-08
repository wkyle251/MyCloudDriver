import Foundation
import Combine

@main
struct WorkspaceSwitchingTests {
    @MainActor static func main() async throws {
        let navigation = FinderWorkspaceNavigation()
        var activated: [Int] = []
        navigation.select(1, needsLoading: false) { activated.append(1); return true }
        precondition(navigation.section == 1 && !navigation.isSwitching)
        var contentUpdates = 0
        let contentObservation = navigation.objectWillChange.sink { contentUpdates += 1 }
        defer { contentObservation.cancel() }
        navigation.select(3, needsLoading: true) { activated.append(3); return true }
        let cancelledID = navigation.request!.id
        precondition(navigation.highlightedSection == 3 && navigation.section == 1 && activated == [1])
        precondition(contentUpdates == 0, "showing the overlay must not invalidate the file view")
        navigation.select(0, needsLoading: true) { activated.append(0); return true }
        let latest = navigation.request!.id
        await navigation.waitForPreparation()
        precondition(activated == [1, 0] && navigation.section == 0 && navigation.isSwitching,
            "latest click wins and loading stays until the destination appears")
        navigation.didPresent(cancelledID)
        precondition(navigation.isSwitching, "stale completion cannot hide a newer overlay")
        navigation.didPresent(latest)
        precondition(!navigation.isSwitching)
        precondition(contentUpdates == 1, "only changing the displayed workspace invalidates the file view")
        navigation.select(3, needsLoading: true) { activated.append(3); return true }
        navigation.select(0, needsLoading: false) { preconditionFailure("returning to current tab should cancel") }
        await navigation.waitForPreparation()
        precondition(navigation.section == 0 && !navigation.isSwitching && activated == [1, 0])
        navigation.select(3, needsLoading: true) { false }
        await navigation.waitForPreparation()
        precondition(navigation.section == 0 && !navigation.isSwitching, "blocked source switch restores the current tab")
        navigation.select(3, needsLoading: true) { activated.append(3); return true }
        navigation.showImmediately(1)
        await navigation.waitForPreparation()
        precondition(navigation.section == 1 && !navigation.isSwitching && activated == [1, 0], "programmatic navigation cancels pending switches")
        navigation.select(3, needsLoading: true) { activated.append(3); return true }
        navigation.cancel()
        await navigation.waitForPreparation()
        precondition(activated == [1, 0] && !navigation.isSwitching, "closing cancels pending work")
        navigation.select(2, needsLoading: false) { preconditionFailure("removed Tasks destination") }
        navigation.showImmediately(2)
        precondition(navigation.section == 1, "removed Tasks cannot be presented")
        precondition(FinderWorkspaceSection.allCases.map(\.title) == ["Browser", "Transfers", "Links"])
        precondition(FinderWorkspaceSection.links.shortcut == 3)
        print("PASS tab loading: immediate small switches, early feedback, latest-click wins, cancelled/blocked switches, stale completion and closing")
        try DownloaderModel.testWorkspacePresentation()
        DownloaderModel.reportWorkspaceSwitchPerformance()
    }
}
