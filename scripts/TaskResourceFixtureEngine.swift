import Darwin
import Foundation

/// Bounded, offline CPU work for resource attribution and Settings visual QA.
/// The nested helper exits if its parent is closed; neither reads any files.
@main
struct TaskResourceFixtureEngine {
    static func main() throws {
        let parent = getppid()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        if CommandLine.arguments.contains("--worker") {
            var value = 1.0
            while getppid() == parent && ProcessInfo.processInfo.systemUptime < deadline {
                let busyUntil = ProcessInfo.processInfo.systemUptime + 0.075
                while ProcessInfo.processInfo.systemUptime < busyUntil { value = sin(value) + 1 }
                Thread.sleep(forTimeInterval: 0.425)
            }
            print(value)
        } else {
            let worker = Process()
            worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            worker.arguments = ["--worker"]
            worker.standardOutput = FileHandle.nullDevice
            try worker.run()
            defer { if worker.isRunning { worker.terminate(); worker.waitUntilExit() } }
            while getppid() == parent && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}
