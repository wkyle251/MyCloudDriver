import Foundation
import IOKit
import Metal

struct TaskGPUUsage: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let utilization: Double?
}

/// Driver-reported device utilization covers the whole Mac. CoreML's private
/// command buffers cannot be attributed to our individual helper processes.
/// Unsupported or malformed counters remain unavailable instead of showing 0%.
enum TaskGPUSampler {
    static func utilization(from statistics: [String: Any]) -> Double? {
        guard let value = statistics["Device Utilization %"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let percent = value.doubleValue
        return percent.isFinite && (0...100).contains(percent) ? percent : nil
    }

    static func sample() -> [TaskGPUUsage] {
        let devices = MTLCopyAllDevices()
        var counters: [UInt64: Double] = [:]
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
                      let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                      let statistics = property as? [String: Any], let percent = utilization(from: statistics) else { continue }
                counters[id] = percent
            }
        }
        return devices.map { TaskGPUUsage(id: $0.registryID, name: $0.name, utilization: counters[$0.registryID]) }
            .sorted { $0.id < $1.id }
    }
}

struct TaskResourceProcessing: Equatable, Sendable {
    enum Backend: String, Sendable { case checking, cpu, coreml }
    let backend: Backend
    var activeJobs: UInt64 = 0
    var jobLimit: UInt64 = 0

    var title: String {
        switch backend {
        case .checking: return "Checking CoreML…"
        case .cpu: return "CPU"
        case .coreml: return "CPU + CoreML"
        }
    }
    var detail: String {
        guard backend == .coreml else { return "" }
        return jobLimit > 0 ? "\(activeJobs) / \(jobLimit) CoreML jobs" : "Waiting for visual work"
    }
    var help: String {
        switch backend {
        case .checking: return "Checking whether CoreML is available for this scan."
        case .cpu: return "This scan is processing on the CPU."
        case .coreml: return "Active CoreML model jobs. CoreML chooses the CPU, GPU or Neural Engine; other scan work continues on the CPU."
        }
    }
}
