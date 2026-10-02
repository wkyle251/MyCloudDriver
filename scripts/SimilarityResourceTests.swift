import Foundation

@main struct SimilarityResourceTests {
    static func main() throws {
        for (cores, gib, expectedWorkers, expectedMemory) in [(2, 4, 1, 1024), (8, 8, 3, 2048), (18, 64, 8, 16384), (64, 128, 12, 16384)] {
            let hardware = SimilarityHardware(cpuCount: cores, memoryBytes: UInt64(gib) << 30, gpuName: "Test GPU")
            let settings = SimilarityResourceSettings(hardware: hardware)
            let limits = settings.limits(for: hardware)
            precondition(limits.workers == expectedWorkers && limits.memoryMiB == expectedMemory)
            precondition(limits.memoryScheduling == true && limits.effectiveWorkers == max(1, Int(limits.analysisMemoryBytes / (128 << 20))))
            precondition(limits.memoryBytes <= hardware.memoryBytes / 4)
            var cpuOnly = hardware; cpuOnly.gpuName = nil
            precondition(SimilarityResourceSettings(hardware:cpuOnly).limits(for:cpuOnly) == limits, "Available GPU memory must not increase a CPU backend's RAM allowance")
        }
        precondition(SimilarityResourceSettings().processingMode == .automatic)
        var cpuSettings=SimilarityResourceSettings(); cpuSettings.processingMode = .cpu
        precondition(cpuSettings.limits.acceleration == .cpu)
        let hardware = SimilarityHardware(cpuCount: 18, memoryBytes: 64 << 30, gpuName: nil)
        var custom = SimilarityResourceSettings(hardware: hardware)
        custom.usesAutomatic = false
        custom.workers = 64; custom.memoryMiB = 512; custom.batchFiles = 3; custom.batchMiB = 1
        let snapshot = custom.limits(for: hardware)
        precondition(snapshot.effectiveWorkers == 3, "Memory admission must ignore the old worker count and use the analysis budget")
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(object["memory_bytes"] as! UInt64 == 512 << 20)
        precondition(object["batch_files"] as! Int == 3)
        precondition(object["batch_bytes"] as! UInt64 == 1 << 20)
        let decoded = try JSONDecoder().decode(SimilarityResourceLimits.self, from: encoded)
        precondition(decoded == snapshot)

        custom.workers = Int.max; custom.memoryMiB = Int.max; custom.batchFiles = Int.max; custom.batchMiB = Int.max
        let upper = custom.limits(for: hardware)
        precondition(upper.workers == 64 && upper.memoryMiB == 65_536 && upper.batchFiles == 4_096 && upper.batchMiB == 1_048_576)
        custom.workers = Int.min; custom.memoryMiB = Int.min; custom.batchFiles = Int.min; custom.batchMiB = Int.min
        let lower = custom.limits(for: hardware)
        precondition(lower.workers == 1 && lower.memoryMiB == 512 && lower.batchFiles == 1 && lower.batchMiB == 1)
        precondition(snapshot.workers == 64 && snapshot.memoryMiB == 512, "Editing settings must not alter a running scan's snapshot")
        custom.usesAutomatic = true
        precondition(custom.limits(for: hardware) == SimilarityResourceSettings(hardware:hardware).limits(for:hardware), "Automatic mode must ignore stale custom values")

        let current = SimilarityHardware.current
        custom = SimilarityResourceSettings(hardware: current); custom.usesAutomatic = false
        custom.workers = 1; custom.memoryMiB = 512; custom.batchFiles = 1; custom.batchMiB = 1
        precondition(custom.validationMessage == nil)
        custom.workers = 0; precondition(custom.validationMessage == nil); custom.workers = 1
        custom.memoryMiB = current.maximumMemoryMiB + 1; precondition(custom.validationMessage != nil); custom.memoryMiB = 512
        custom.batchFiles = 4_097; precondition(custom.validationMessage == nil); custom.batchFiles = 1
        custom.batchMiB = 0; precondition(custom.validationMessage == nil); custom.batchMiB = 1
        let settingsData = try JSONEncoder().encode(custom)
        let restoredSettings = try JSONDecoder().decode(SimilarityResourceSettings.self, from: settingsData)
        precondition(restoredSettings == custom)

        custom.memoryMiB = 65_536; custom.downloadMemoryMiB = 12_288; custom.workers = 52
        precondition(custom.validationMessage(for: hardware) == nil)
        let fullMemory = custom.limits(for: hardware)
        precondition(fullMemory.memoryBytes == 64 << 30 && fullMemory.downloadBudgetBytes == 12 << 30)
        precondition(fullMemory.analysisMemoryBytes == 52 << 30 && fullMemory.effectiveWorkers == 416)
        let fullWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fullMemory)) as! [String: Any]
        precondition(fullWire["download_memory_bytes"] as! UInt64 == 12 << 30)
        let restoredFull = try JSONDecoder().decode(SimilarityResourceLimits.self, from: JSONEncoder().encode(fullMemory))
        precondition(restoredFull == fullMemory)
        let scanSettings = SimilarityResourceSettings(limits: fullMemory)
        precondition(!scanSettings.usesAutomatic && scanSettings.limits(for: hardware) == fullMemory,
                     "Editing a saved scan must begin with its own worker, RAM and processing limits")
        var oldCPULimits = fullMemory; oldCPULimits.acceleration = nil
        precondition(SimilarityResourceSettings(limits: oldCPULimits).processingMode == .cpu,
                     "Older checkpoints must keep their CPU encoding profile")
        custom.downloadMemoryMiB = 0; precondition(custom.validationMessage(for: hardware) != nil)
        custom.downloadMemoryMiB = 65_536; precondition(custom.validationMessage(for: hardware) != nil)
        custom.downloadMemoryMiB = nil
        let legacy = Data(#"{"usesAutomatic":false,"workers":52,"memoryMiB":49152,"batchFiles":128,"batchMiB":4096}"#.utf8)
        let migrated = try JSONDecoder().decode(SimilarityResourceSettings.self, from: legacy)
        precondition(migrated.memoryMiB == 49_152 && migrated.workers == 52 && migrated.downloadMemoryMiB == nil)
        precondition(migrated.limits(for: hardware).downloadBudgetBytes == 12 << 30)
        precondition(migrated.limits(for: hardware).analysisMemoryBytes == 36 << 30)
        var memoryOnly = SimilarityResourceSettings(hardware: hardware); memoryOnly.usesAutomatic = false
        memoryOnly.analysisMemoryMiB = 32_768
        precondition(memoryOnly.memoryMiB == 36_864 && memoryOnly.downloadBudgetMiB == 4_096)
        memoryOnly.downloadBudgetMiB = 12_288
        precondition(memoryOnly.analysisMemoryMiB == 32_768 && memoryOnly.memoryMiB == 45_056)
        memoryOnly.workers = 1
        let memoryCapacity = memoryOnly.limits(for: hardware).effectiveWorkers
        memoryOnly.workers = 52
        precondition(memoryOnly.limits(for: hardware).effectiveWorkers == memoryCapacity)
        memoryOnly.analysisMemoryMiB = 65_536
        precondition(memoryOnly.validationMessage(for: hardware) != nil)
        print("PASS full physical-memory ceiling, independent 12 GB originals budget, decoder remainder, validation and legacy preferences")

        let memoryLabel = hardware.recommendedLimits.memoryLabel
        let memoryHardware = SimilarityHardware(cpuCount: 18, memoryBytes: 16 << 30, gpuName: nil)
        precondition(memoryHardware.summary.contains(memoryLabel), "Configured and physical memory must use the same binary units")
        let fileLabel = ByteCountFormatter.string(fromByteCount: 16 << 30, countStyle: .file)
        precondition(memoryLabel != fileLabel, "Memory allowance must not display the decimal file-transfer value")
        let english = Locale(identifier: "en_US"), german = Locale(identifier: "de_DE")
        precondition(SimilarityGigabytes.text(mib: 16_384, locale: english) == "16")
        precondition(SimilarityGigabytes.text(mib: 4_096, locale: english) == "4")
        precondition(SimilarityGigabytes.mebibytes(from: "0.5", locale: english) == 512)
        precondition(SimilarityGigabytes.mebibytes(from: "1.5", locale: english) == 1_536)
        precondition(SimilarityGigabytes.mebibytes(from: "1,5", locale: german) == 1_536)
        for locale in [english, german] {
            for mib in [1, 21, 511, 512, 1_536, 6_553, 16_384, 49_152, 1_048_576] {
                let displayed = SimilarityGigabytes.text(mib: mib, locale: locale)
                precondition(SimilarityGigabytes.mebibytes(from: displayed, locale: locale) == mib,
                             "Displaying and saving an old MiB preference in GB must preserve the limit")
            }
        }
        for invalid in ["", ".", "nan", "inf", "-1", "1e999", "99999999999999999999"] {
            precondition(SimilarityGigabytes.mebibytes(from: invalid, locale: english) == nil)
        }
        custom.memoryMiB = 0
        precondition(custom.validationMessage!.contains("GB") && !custom.validationMessage!.contains("MiB"))
        print("PASS similarity resources: hardware defaults, bounds, byte protocol, admission, snapshots, GB display/edit conversion, fractional and localized input, and unchanged persisted limits")
    }
}
