import Foundation

@main struct SimilarityResourceTests {
    static func main() throws {
        for (cores, gib, initialMiB) in [(2, 4, 512), (8, 8, 1024), (18, 64, 2048), (64, 128, 2048)] {
            let hardware = SimilarityHardware(cpuCount: cores, memoryBytes: UInt64(gib) << 30, gpuName: "Test GPU")
            let settings = SimilarityResourceSettings(hardware: hardware)
            let limits = settings.limits(for: hardware)
            precondition(limits.memoryMiB == initialMiB)
            precondition(limits.automaticMemory == true && limits.memoryScheduling == true)
            precondition(limits.downloadBudgetBytes == limits.memoryBytes / 2)
            precondition(limits.workers == min(cores, Int(hardware.memoryBytes / (128 << 20))))
            var cpuOnly = hardware; cpuOnly.gpuName = nil
            precondition(settings.limits(for: cpuOnly) == limits)
            var legacy = settings
            legacy.usesAutomatic = false; legacy.workers = Int.max
            legacy.memoryMiB = Int.min; legacy.downloadMemoryMiB = Int.max
            legacy.batchFiles = 0; legacy.batchMiB = 0
            precondition(legacy.limits(for: hardware) == limits, "Old manual RAM values must not constrain new scans")
            precondition(legacy.validationMessage(for: hardware) == nil)
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(limits)) as! [String: Any]
            precondition(wire["automatic_memory"] as? Bool == true)
            let decoded = try JSONDecoder().decode(SimilarityResourceLimits.self, from: JSONEncoder().encode(limits))
            precondition(decoded == limits)
        }
        let hardware = SimilarityHardware(cpuCount: 18, memoryBytes: 64 << 30, gpuName: nil)
        let legacy = Data(#"{"usesAutomatic":false,"workers":52,"memoryMiB":49152,"batchFiles":128,"batchMiB":4096}"#.utf8)
        let migrated = try JSONDecoder().decode(SimilarityResourceSettings.self, from: legacy)
        precondition(migrated.limits(for: hardware).automaticMemory == true)
        precondition(migrated.limits(for: hardware).memoryBytes == 2 << 30)
        var oldLimits = hardware.recommendedLimits
        oldLimits.automaticMemory = nil; oldLimits.acceleration = nil
        oldLimits.memoryBytes = 512 << 20; oldLimits.downloadMemoryBytes = 12 << 30
        let checkpoint = SimilarityResourceSettings(limits: oldLimits)
        precondition(checkpoint.usesAutomatic && checkpoint.processingMode == .cpu,
                     "Saved vector backends must survive RAM migration")
        precondition(checkpoint.limits(for: hardware).automaticMemory == true)
        var cpu = SimilarityResourceSettings(); cpu.processingMode = .cpu
        precondition(cpu.limits.acceleration == .cpu)
        let oldWire = Data(#"{"workers":2,"memory_bytes":1073741824,"batch_files":128,"batch_bytes":1073741824}"#.utf8)
        let oldDecoded = try JSONDecoder().decode(SimilarityResourceLimits.self, from: oldWire)
        precondition(oldDecoded.automaticMemory == nil)
        precondition(SimilarityGigabytes.text(mib: 1536, locale: Locale(identifier: "en_US")) == "1.5")
        print("PASS automatic memory protocol, hardware starting allowances, ignored custom RAM preferences, legacy checkpoints and pinned backends")
    }
}
