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
    var automaticMemory: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case workers
        case memoryBytes = "memory_bytes"
        case batchFiles = "batch_files"
        case batchBytes = "batch_bytes"
        case downloadMemoryBytes = "download_memory_bytes"
        case acceleration
        case memoryScheduling = "memory_scheduling"
        case automaticMemory = "automatic_memory"
    }

    var downloadBudgetBytes: UInt64 { downloadMemoryBytes ?? min(12 << 30, memoryBytes / 4) }
    var analysisMemoryBytes: UInt64 { memoryBytes > downloadBudgetBytes ? memoryBytes - downloadBudgetBytes : 0 }
    var effectiveWorkers: Int {
        memoryScheduling == true ? max(1, min(automaticMemory == true ? workers : 8_192, Int(analysisMemoryBytes / (128 << 20))))
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

    /// A starting allowance only. The helper grows it on demand and responds
    /// to system pressure; these values never set a fixed scan RAM ceiling.
    var recommendedLimits: SimilarityResourceLimits {
        let initial = min(memoryBytes, max(512 << 20, min(2 << 30, memoryBytes / 8)))
        return SimilarityResourceLimits(workers: max(1, min(cpuCount, Int(memoryBytes / (128 << 20)))),
                                        memoryBytes: initial, batchFiles: 128, batchBytes: 1 << 30,
                                        downloadMemoryBytes: initial / 2, memoryScheduling: true, automaticMemory: true)
    }

    var maximumMemoryMiB: Int { max(512, min(1_048_576, Int(memoryBytes / (1_024 * 1_024)))) }

    var summary: String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: memoryBytes), countStyle: .memory)
        return "\(cpuCount) CPU cores · \(memory) memory"
    }

    var backendDescription: String {
        if let gpuName { return "Automatic checks CoreML for image and video analysis on \(gpuName). Memory and processing concurrency adapt to each file’s needs and system memory pressure." }
        return "Automatic uses CPU processing when CoreML acceleration is unavailable."
    }
}

/// Processing preferences. Legacy RAM fields remain decodable, but every
/// app scan now uses automatic memory admission.
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

    /// Preserve the encoding backend of a saved scan. Old RAM amounts are ignored.
    init(limits: SimilarityResourceLimits) {
        usesAutomatic = true
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
        var automatic = Self()
        automatic.processingMode = saved.processingMode
        return automatic
    }

    var limits: SimilarityResourceLimits { limits(for: .current) }

    func limits(for hardware: SimilarityHardware) -> SimilarityResourceLimits {
        var limits = hardware.recommendedLimits
        limits.acceleration = processingMode
        return limits
    }

    var validationMessage: String? { nil }
    func validationMessage(for hardware: SimilarityHardware) -> String? { nil }

    func save() {
        var automatic = Self()
        automatic.processingMode = processingMode
        guard let data = try? JSONEncoder().encode(automatic) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
