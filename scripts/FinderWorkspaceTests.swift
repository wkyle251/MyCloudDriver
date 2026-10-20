import AppKit
import Foundation

@main
struct FinderWorkspaceTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--resource-child") {
            let end = ProcessInfo.processInfo.systemUptime + 4.5
            var value = 1.0
            while ProcessInfo.processInfo.systemUptime < end { value = sin(value) + 1 }
            print(value)
            return
        }
        precondition(FinderAppVersion.displayText(info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "123"]) == "9.8.7 (build 123)")
        precondition(FinderAppVersion.displayText(info: ["CFBundleShortVersionString": " 9.8.7 \n"]) == "9.8.7")
        precondition(FinderAppVersion.displayText(info: ["CFBundleVersion": "123"]) == "Build 123")
        precondition(FinderAppVersion.displayText(info: ["CFBundleShortVersionString": "  ", "CFBundleVersion": "\n"]) == "Unavailable")
        precondition(FinderAppVersion.displayText(info: nil) == "Unavailable")
        print("PASS app version: bundle version/build formatting, missing metadata and whitespace")
        let suite = "com.wky.PikPakFinderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(48, forKey: "uploadConcurrentJobs")
        defaults.set(2, forKey: "concurrentJobs")
        let settings = FinderSettings(defaults: defaults)
        precondition(!settings.autoHideSidebar && settings.showsPreviewPane)
        precondition(settings.concurrentExtractions == 4)
        settings.setConcurrentExtractions(Int.min)
        precondition(settings.concurrentExtractions == 1)
        settings.setConcurrentExtractions(Int.max)
        precondition(settings.concurrentExtractions == 8)
        settings.setConcurrentExtractions(3)
        settings.autoHideSidebar = true
        settings.showsPreviewPane = false
        let restored = FinderSettings(defaults: defaults)
        precondition(restored.concurrentExtractions == 3)
        precondition(restored.autoHideSidebar && !restored.showsPreviewPane)
        precondition(defaults.integer(forKey: "uploadConcurrentJobs") == 48 && defaults.integer(forKey: "concurrentJobs") == 2)
        print("PASS settings: persistent sidebar/preview and extraction limits; legacy transfer keys untouched")
        defaults.set(0.9, forKey: "browserSplitFraction")
        defaults.set(2_000.0, forKey: "previewCanvasHeight")
        defaults.set(900.0, forKey: "previewCanvasWidth")
        defaults.set(700.0, forKey: "browserNameColumnWidth")
        defaults.set(false, forKey: "browserShowsSizeColumn")
        defaults.set(1, forKey: "browserViewMode"); defaults.set(1, forKey: "linksViewMode")
        defaults.set(1.7, forKey: "browserListItemZoom"); defaults.set(1.8, forKey: "browserItemZoom")
        defaults.set("synthetic-account", forKey: "activePikPakAccountID")
        defaults.set("/synthetic/downloads", forKey: "outputDirectory")
        settings.resetLayout()
        precondition(settings.layoutResetRevision == 1 && !settings.autoHideSidebar && settings.showsPreviewPane)
        precondition(defaults.double(forKey: "browserSplitFraction") == 0.64)
        precondition(defaults.object(forKey: "previewCanvasWidth") == nil && defaults.object(forKey: "previewCanvasHeight") == nil)
        precondition(defaults.double(forKey: "browserNameColumnWidth") == 250 && defaults.bool(forKey: "browserShowsSizeColumn"))
        precondition(defaults.integer(forKey: "browserViewMode") == 0 && defaults.integer(forKey: "linksViewMode") == 0)
        precondition(defaults.double(forKey: "browserListItemZoom") == 1 && defaults.double(forKey: "browserItemZoom") == 0)
        precondition(settings.concurrentExtractions == 3)
        precondition(defaults.string(forKey: "activePikPakAccountID") == "synthetic-account" && defaults.string(forKey: "outputDirectory") == "/synthetic/downloads")
        settings.resetLayout(); precondition(settings.layoutResetRevision == 2)
        print("PASS Reset Layout: restores presentation preferences, invalidates transient sizing, preserves accounts/destinations and can be repeated")
        precondition(FinderSidebarHoverPolicy.canReveal(automaticallyHidden: true, pressedMouseButtons: 0))
        precondition(!FinderSidebarHoverPolicy.canReveal(automaticallyHidden: false, pressedMouseButtons: 0))
        precondition(!FinderSidebarHoverPolicy.canReveal(automaticallyHidden: true, pressedMouseButtons: 1))
        precondition(!FinderSidebarHoverPolicy.canReveal(automaticallyHidden: true, pressedMouseButtons: 2))
        print("PASS sidebar: hover is opt-in; pressed buttons and drags cannot reveal it")

        var cursorEvents: [String] = []
        let cursors = FinderCursorTracker(push: { cursorEvents.append("push") }, pop: { cursorEvents.append("pop") })
        let firstCursor = UUID(), secondCursor = UUID()
        cursors.setActive(true, owner: firstCursor)
        cursors.setActive(true, owner: firstCursor)
        cursors.setActive(true, owner: secondCursor)
        cursors.setActive(false, owner: firstCursor)
        precondition(cursorEvents == ["push"], "overlapping targets retain the pointing cursor")
        cursors.setActive(false, owner: secondCursor)
        cursors.setActive(false, owner: secondCursor)
        precondition(cursorEvents == ["push", "pop"], "exiting, disabling or recycling a row releases its cursor once")
        print("PASS cursor ownership: overlapping targets, repeated events and balanced cleanup")

        var accumulator = TaskResourceAccumulator()
        func sample(_ cpu: UInt64, started: UInt64 = 1) -> TaskProcessSample {
            .init(pid: 17, name: "Fixture", started: started, cpuNanoseconds: cpu, residentBytes: 4096, threads: 1)
        }
        precondition(accumulator.update([sample(1_000_000_000)], at: 1)[0].cpuPercent == nil)
        precondition(accumulator.update([sample(3_000_000_000)], at: 3)[0].cpuPercent == 100)
        precondition(accumulator.update([sample(3_000_000_000)], at: 5)[0].cpuPercent == 0)
        precondition(accumulator.update([sample(4_000_000_000, started: 2)], at: 7)[0].cpuPercent == nil)
        precondition(accumulator.update([], at: 9).isEmpty)
        precondition(accumulator.update([sample(4_000_000_000, started: 2)], at: 11)[0].cpuPercent == nil)
        precondition(accumulator.update([sample(9_000_000_000, started: 2)], at: 30)[0].cpuPercent == nil)
        print("PASS resources: measured CPU deltas, idle=0%, PID reuse, exited processes and stale sample gaps")
        precondition(TaskResourceSampler.nanoseconds(fromMachTicks: 24_000_000, numerator: 125, denominator: 3) == 1_000_000_000)
        precondition(TaskResourceSampler.nanoseconds(fromMachTicks: 1_000_000_000, numerator: 1, denominator: 1) == 1_000_000_000)
        precondition(TaskResourceSampler.nanoseconds(fromMachTicks: UInt64.max / 2, numerator: 3, denominator: 3) == UInt64.max / 2,
                     "conversion must not overflow its intermediate product")
        print("PASS CPU units: Apple silicon Mach timebase, nanosecond timebase and large counters")

        precondition(TaskGPUSampler.utilization(from: ["Device Utilization %": 0]) == 0)
        precondition(TaskGPUSampler.utilization(from: ["Device Utilization %": 42.5]) == 42.5)
        precondition(TaskGPUSampler.utilization(from: ["Device Utilization %": 100]) == 100)
        for invalid in [-1, 101, Double.nan, Double.infinity, true, "42"] as [Any] {
            precondition(TaskGPUSampler.utilization(from: ["Device Utilization %": invalid]) == nil)
        }
        precondition(TaskGPUSampler.utilization(from: [:]) == nil)
        precondition(TaskGPUSampler.utilization(from: ["Renderer Utilization %": 50]) == nil,
                     "Partial GPU counters must not masquerade as whole-device usage")
        let gpus = TaskGPUSampler.sample()
        precondition(Set(gpus.map(\.id)).count == gpus.count)
        precondition(gpus.allSatisfy { !$0.name.isEmpty && ($0.utilization == nil || (0...100).contains($0.utilization!)) })
        print("PASS GPU samples: idle versus unavailable, malformed counters, device identity and live utilization")

        func row(_ pid: Int32, parent: Int32, cpu: Double?, memory: UInt64 = 1024) -> TaskResourceRow {
            .init(pid: pid, name: "helper", cpuPercent: cpu, residentBytes: memory, threads: 1, parentPID: parent)
        }
        let activity = TaskResourceActivity(name: "Scanning duplicate files", detail: "/Projects",
                                            processing: .init(backend: .coreml, activeJobs: 2, jobLimit: 2))
        let tree = [row(1, parent: 0, cpu: 5), row(2, parent: 1, cpu: 10),
                    row(3, parent: 2, cpu: 80), row(4, parent: 3, cpu: 20), row(5, parent: 1, cpu: 2)]
        let grouped = TaskResourceAttribution.group(tree, activities: [2: activity], rootPID: 1)
        precondition(grouped.count == 3 && grouped.first?.id == 2)
        precondition(grouped[0].cpuPercent == 110 && grouped[0].residentBytes == 3072)
        precondition(grouped[0].processIDs == [2, 3, 4] && grouped[0].activity == activity)
        precondition(grouped[0].activity.processing?.activeJobs == 2,
                     "CoreML jobs belong to the scan and are not multiplied by its helper count")
        precondition(grouped.flatMap(\.processIDs).sorted() == tree.map(\.pid).sorted(), "every process counted once")
        precondition(grouped.reduce(0) { $0 + $1.residentBytes } == tree.reduce(0) { $0 + $1.residentBytes })
        precondition(grouped.first { $0.id == 5 }?.activity.name == "Background helper", "unknown tasks remain visible")
        let nested = TaskResourceAttribution.group(tree, activities: [2: activity, 3: .init(name: "Nested task")], rootPID: 1)
        precondition(nested.first { $0.id == 3 }?.processIDs == [3, 4], "nearest named owner wins")
        let warming = TaskResourceAttribution.group([row(2, parent: 1, cpu: 10), row(3, parent: 2, cpu: nil)], activities: [2: activity], rootPID: 1)
        precondition(warming.count == 1 && warming[0].cpuPercent == nil, "new helper needs two samples; do not display an understated task total")
        precondition(TaskResourceAttribution.group([], activities: [2: activity], rootPID: 1).isEmpty, "finished tasks do not retain resource rows")
        print("PASS task attribution: descendants grouped once, CPU/memory totals, highest CPU first, nested owners and helper lifecycle")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--resource-child"]
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        try await Task.sleep(nanoseconds: 150_000_000)
        let firstTime = ProcessInfo.processInfo.systemUptime
        let first = TaskResourceSampler.sample()
        precondition(first.contains { $0.pid == getpid() && $0.residentBytes > 0 })
        let firstChild = first.first { $0.pid == child.processIdentifier }
        precondition(firstChild != nil, "own child process must be included")
        precondition(firstChild?.parentPID == getpid())
        try await Task.sleep(nanoseconds: 250_000_000)
        let nextChild = TaskResourceSampler.sample().first { $0.pid == child.processIdentifier }
        precondition((nextChild?.cpuNanoseconds ?? 0) > (firstChild?.cpuNanoseconds ?? UInt64.max))
        let childCPU = Double(nextChild!.cpuNanoseconds - firstChild!.cpuNanoseconds)
            / ((ProcessInfo.processInfo.systemUptime - firstTime) * 1_000_000_000) * 100
        precondition(childCPU > 20 && childCPU < 150, "a busy single-thread child must measure a substantial part of one CPU core, got \(childCPU)%")
        print("PASS live sampler: only own process tree, child CPU advances, memory is nonzero")
        let monitor = TaskResourceMonitor()
        #if FINDER_WORKSPACE_TESTS
        let resourceModel = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        resourceModel.setResourceScanFixture(child, files: 1200, folders: 40, path: "/Projects")
        let watching = Task { await monitor.watch { resourceModel.resourceActivities } }
        #else
        let watching = Task { await monitor.watch { [child.processIdentifier: activity] } }
        #endif
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(monitor.rows.contains { $0.pid == getpid() })
        precondition(monitor.tasks.contains { $0.id == child.processIdentifier && $0.activity.name == "Scanning duplicate files" })
        #if FINDER_WORKSPACE_TESTS
        precondition(monitor.tasks.first { $0.id == child.processIdentifier }?.activity.detail.contains("/Projects") == true)
        resourceModel.setResourceScanFixture(child, files: 2400, folders: 80, path: "/Projects/Drafts")
        try await Task.sleep(nanoseconds: 2_100_000_000)
        precondition(monitor.tasks.first { $0.id == child.processIdentifier }?.activity.detail.contains("/Projects/Drafts") == true,
                     "live task details refresh with the resource sample")
        precondition((monitor.tasks.first { $0.id == child.processIdentifier }?.cpuPercent ?? 0) > 0)
        child.terminate()
        child.waitUntilExit()
        precondition(resourceModel.resourceActivities[child.processIdentifier] == nil, "stopped scan immediately loses its task mapping")
        #endif
        watching.cancel()
        await watching.value
        precondition(monitor.rows.isEmpty && monitor.tasks.isEmpty && monitor.sampledAt == nil)
        print("PASS monitor lifecycle: real task labels and progress refresh; stopped tasks disappear; closing Resources stops polling")

        #if FINDER_WORKSPACE_TESTS
        try DownloaderModel.testFinderWorkspace(defaults: defaults)
        try await DownloaderModel.testAccountManagement()
        #endif
    }
}
