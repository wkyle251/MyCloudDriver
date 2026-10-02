import Foundation
#if canImport(Metal)
import Metal
#endif

/// Match macOS's memory-style GB display while preserving the existing MiB
/// preferences and byte-based engine protocol. Four decimal places round-trip
/// every whole-MiB value without changing a saved limit just by opening it.
enum SimilarityGigabytes {
    static func text(mib: Int, locale: Locale = .current) -> String {
        (Double(mib) / 1_024).formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...4)))
    }

    static func mebibytes(from text: String, locale: Locale = .current) -> Int? {
        let normalized = text.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let number = Double(normalized), number.isFinite, number >= 0 else { return nil }
        let rounded = (number * 1_024).rounded()
        guard rounded.isFinite, rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    static func numericText(_ text: String, locale: Locale = .current) -> String {
        let separator = locale.decimalSeparator ?? "."
        var result = "", hasSeparator = false
        for character in text.prefix(20) {
            if character.isASCII && character.isNumber { result.append(character) }
            else if (String(character) == separator || character == ".") && !hasSeparator {
                result += separator; hasSeparator = true
            }
        }
        return result
    }
}

enum SimilarityAcceleration: String, Codable, CaseIterable {
    case automatic, cpu
    var title: String { self == .automatic ? "Automatic" : "CPU Only" }
}

/// CPU and accelerator work share the same scan allowance.
struct SimilarityResourceLimits: Codable, Equatable {
    var workers: Int
    var memoryBytes: UInt64
    var batchFiles: Int
    var batchBytes: UInt64
    var downloadMemoryBytes: UInt64? = nil
    var acceleration: SimilarityAcceleration? = nil
    var memoryScheduling: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case workers
        case memoryBytes = "memory_bytes"
        case batchFiles = "batch_files"
        case batchBytes = "batch_bytes"
        case downloadMemoryBytes = "download_memory_bytes"
        case acceleration
        case memoryScheduling = "memory_scheduling"
    }

    var downloadBudgetBytes: UInt64 { downloadMemoryBytes ?? min(12 << 30, memoryBytes / 4) }
    var analysisMemoryBytes: UInt64 { memoryBytes > downloadBudgetBytes ? memoryBytes - downloadBudgetBytes : 0 }
    var effectiveWorkers: Int {
        memoryScheduling == true ? max(1, min(8_192, Int(analysisMemoryBytes / (128 << 20))))
            : min(workers, max(1, Int(analysisMemoryBytes / (512 << 20))))
    }
    var memoryMiB: Int { Int(memoryBytes / (1_024 * 1_024)) }
    var memoryLabel: String { "\(SimilarityGigabytes.text(mib: memoryMiB)) GB" }
    var downloadMemoryMiB: Int { Int(downloadBudgetBytes / (1_024 * 1_024)) }
    var downloadMemoryLabel: String { "\(SimilarityGigabytes.text(mib: downloadMemoryMiB)) GB" }
    var analysisMemoryLabel: String { "\(SimilarityGigabytes.text(mib: Int(analysisMemoryBytes / (1_024 * 1_024)))) GB" }
    var batchMiB: Int { Int(batchBytes / (1_024 * 1_024)) }
}

struct SimilarityHardware: Equatable {
    var cpuCount: Int
    var memoryBytes: UInt64
    var gpuName: String?

    static let current: Self = {
        #if canImport(Metal)
        let gpuName = MTLCreateSystemDefaultDevice()?.name
        #else
        let gpuName: String? = nil
        #endif
        return Self(cpuCount: max(1, ProcessInfo.processInfo.activeProcessorCount),
                    memoryBytes: ProcessInfo.processInfo.physicalMemory, gpuName: gpuName)
    }()

    /// Leave two logical cores for the interface/other work, then allow two
    /// inference threads per worker. Two windows can therefore scan without
    /// each independently claiming every core or most of the Mac's memory.
    var recommendedLimits: SimilarityResourceLimits {
        let memoryMiB = max(512, min(16_384, Int(memoryBytes / (4 * 1_024 * 1_024))))
        let cpuWorkers = max(1, (cpuCount - 2) / 2)
        let workers = min(12, cpuWorkers, max(1, memoryMiB / 512))
        return SimilarityResourceLimits(workers: workers,
                                        memoryBytes: UInt64(memoryMiB) * 1_024 * 1_024,
                                        batchFiles: max(32, min(512, workers * 16)),
                                        batchBytes: UInt64(max(256, min(4_096, memoryMiB / 2))) * 1_024 * 1_024)
    }

    var maximumMemoryMiB: Int { max(512, min(1_048_576, Int(memoryBytes / (1_024 * 1_024)))) }

    var summary: String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: memoryBytes), countStyle: .memory)
        return "\(cpuCount) CPU cores · \(memory) memory"
    }

    var backendDescription: String {
        if let gpuName { return "Automatic checks CoreML for image and video analysis on \(gpuName). CPU and accelerated tasks share Analysis RAM. Concurrency adapts to this allowance and each file’s decoding needs." }
        return "Automatic uses CPU processing when CoreML acceleration is unavailable."
    }
}

/// Persisted app-wide defaults. A scan snapshots `limits`, so changing these
/// controls never mutates the settings of a running scan.
struct SimilarityResourceSettings: Codable, Equatable {
    var usesAutomatic: Bool
    var workers: Int
    var memoryMiB: Int
    var batchFiles: Int
    var batchMiB: Int
    /// Absent in older preferences: derive one quarter, capped at 12 GB.
    var downloadMemoryMiB: Int? = nil
    var acceleration: SimilarityAcceleration? = nil
    var processingMode: SimilarityAcceleration {
        get { acceleration ?? .automatic }
        set { acceleration = newValue }
    }
    var analysisMemoryMiB: Int {
        get {
            let remainder = memoryMiB.subtractingReportingOverflow(downloadMemoryMiB ?? min(12_288, memoryMiB / 4))
            return remainder.overflow ? 0 : max(0, remainder.partialValue)
        }
        set {
            let downloads = downloadMemoryMiB ?? min(12_288, memoryMiB / 4)
            downloadMemoryMiB = downloads
            let total = newValue.addingReportingOverflow(downloads)
            memoryMiB = total.overflow ? Int.max : total.partialValue
        }
    }
    var downloadBudgetMiB: Int {
        get { downloadMemoryMiB ?? min(12_288, memoryMiB / 4) }
        set {
            let analysis = analysisMemoryMiB
            downloadMemoryMiB = newValue
            analysisMemoryMiB = analysis
        }
    }

    private static let storageKey = "similarity.resourceSettings.v1"

    init(hardware: SimilarityHardware = .current) {
        let recommended = hardware.recommendedLimits
        usesAutomatic = true
        workers = recommended.workers
        memoryMiB = recommended.memoryMiB
        batchFiles = recommended.batchFiles
        batchMiB = recommended.batchMiB
    }

    /// Edit the paused scan's own allowance, independent of other windows or
    /// defaults that may have changed since it started.
    init(limits: SimilarityResourceLimits) {
        usesAutomatic = false
        workers = limits.workers
        memoryMiB = limits.memoryMiB
        batchFiles = limits.batchFiles
        batchMiB = limits.batchMiB
        downloadMemoryMiB = limits.downloadMemoryMiB
        acceleration = limits.acceleration ?? .cpu
    }

    static var current: Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    var limits: SimilarityResourceLimits { limits(for: .current) }

    func limits(for hardware: SimilarityHardware) -> SimilarityResourceLimits {
        if usesAutomatic {
            var limits = hardware.recommendedLimits; limits.acceleration = processingMode; limits.memoryScheduling = true; return limits
        }
        let total = max(512, min(hardware.maximumMemoryMiB, memoryMiB))
        let downloads = downloadMemoryMiB ?? min(12_288, total / 4)
        return SimilarityResourceLimits(workers: max(1, min(64, workers)),
                                        memoryBytes: UInt64(total) * 1_024 * 1_024,
                                        batchFiles: max(1, min(4_096, batchFiles)),
                                        batchBytes: UInt64(max(1, min(1_048_576, batchMiB))) * 1_024 * 1_024,
                                        downloadMemoryBytes: UInt64(max(1, min(total - 1, downloads))) * 1_024 * 1_024,
                                        acceleration: processingMode, memoryScheduling: true)
    }

    var validationMessage: String? { validationMessage(for: .current) }

    func validationMessage(for hardware: SimilarityHardware) -> String? {
        guard !usesAutomatic else { return nil }
        if !(512...hardware.maximumMemoryMiB).contains(memoryMiB) {
            return "Total scan memory must be from 0.5 to \(SimilarityGigabytes.text(mib: hardware.maximumMemoryMiB)) GB on this Mac."
        }
        if let downloadMemoryMiB, !(1..<memoryMiB).contains(downloadMemoryMiB) {
            return "Download RAM must be greater than zero and smaller than total scan memory."
        }
        return nil
    }

    func save() {
        guard validationMessage == nil, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
