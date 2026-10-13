import Foundation
import Combine
import Darwin
import IOKit
import IOKit.storage.ata

@_silgen_name("mcd_nvme_temperature_kelvin")
private func taskNVMeTemperatureKelvin(_ service: io_service_t) -> UInt16
@_silgen_name("mcd_destination_bsd")
private func downloadDestinationBSD(_ path: UnsafePointer<CChar>, _ output: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32

enum TaskDiskRate {
    static func bytesPerSecond(_ current: UInt64?, previous: UInt64?, elapsed: TimeInterval?) -> Double? {
        guard let current, let previous, let elapsed, elapsed.isFinite,
              elapsed > 0, elapsed <= 10, current >= previous else { return nil }
        let rate = Double(current - previous) / elapsed
        return rate.isFinite ? rate : nil
    }

    static func text(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        return String(format: "%.2f MiB/s", rate / 1_048_576)
    }
}

struct TaskDiskSample: Identifiable, Sendable {
    let id: UInt64
    let deviceID: UInt64
    let name: String
    let device: String
    let location: String
    let interconnect: String
    let medium: String
    let readBytes: UInt64?
    let writtenBytes: UInt64?
}

struct TaskDiskUsage: Identifiable, Sendable {
    let sample: TaskDiskSample
    let readBytesPerSecond: Double?
    let writtenBytesPerSecond: Double?
    var id: UInt64 { sample.id }
    var detail: String {
        [sample.device, sample.location, sample.interconnect, sample.medium]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Registry identity prevents a reconnected disk reusing a BSD name from inheriting
/// the old disk's counters. Missing/reset counters and sleep gaps need a new baseline.
struct TaskDiskAccumulator {
    private var previous: [UInt64: TaskDiskSample] = [:]
    private var previousTime: TimeInterval?

    mutating func update(_ samples: [TaskDiskSample], at time: TimeInterval) -> [TaskDiskUsage] {
        let elapsed = previousTime.map { time - $0 }
        let rows = samples.map { sample in
            let old = previous[sample.id]
            return TaskDiskUsage(sample: sample,
                readBytesPerSecond: TaskDiskRate.bytesPerSecond(sample.readBytes, previous: old?.readBytes, elapsed: elapsed),
                writtenBytesPerSecond: TaskDiskRate.bytesPerSecond(sample.writtenBytes, previous: old?.writtenBytes, elapsed: elapsed))
        }
        previous = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        previousTime = time
        return rows
    }
}

/// Resolve only the destination's mounted device and I/O Registry ancestry.
/// No child paths, file data, disk benchmarks or SMART requests are involved.
enum DownloadDiskDestination {
    static func deviceID(_ destination: URL) -> UInt64? {
        guard destination.isFileURL else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MNAMELEN))
        guard destination.path.withCString({ downloadDestinationBSD($0, &buffer, buffer.count) }) == 0 else { return nil }
        let bsd = String(cString: buffer)
        guard let matching = bsd.withCString({ IOBSDNameMatching(kIOMainPortDefault, 0, $0) }) else { return nil }
        var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard current != 0 else { return nil }
        defer { IOObjectRelease(current) }
        for _ in 0..<64 {
            if IOObjectConformsTo(current, "IOBlockStorageDevice") != 0 { return TaskDiskSampler.registryID(current) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
            IOObjectRelease(current); current = parent
        }
        return nil
    }
}

/// Fast counters only, while the download dashboard is visible. Destination
/// identity is rechecked on each sample so reconnection cannot reuse old rates.
@MainActor final class DownloadDiskRateMonitor: ObservableObject {
    @Published private(set) var usage: TaskDiskUsage?
    private var generation = UUID()
    private let sample: @Sendable () -> [TaskDiskSample]
    private let resolve: @Sendable (URL) -> UInt64?
    private let interval: UInt64

    init(sample: @escaping @Sendable () -> [TaskDiskSample] = { TaskDiskSampler.sample() },
         resolve: @escaping @Sendable (URL) -> UInt64? = { DownloadDiskDestination.deviceID($0) },
         intervalNanoseconds: UInt64 = 2_000_000_000) {
        self.sample = sample; self.resolve = resolve; self.interval = max(1_000_000, intervalNanoseconds)
    }

    func watch(destination: URL) async {
        let ticket = UUID(); generation = ticket; usage = nil
        let sample = sample, resolve = resolve, interval = interval
        var sink: AsyncStream<TaskDiskUsage?>.Continuation!
        let snapshots = AsyncStream<TaskDiskUsage?>(bufferingPolicy: .bufferingNewest(1)) { sink = $0 }
        let continuation = sink!
        let worker = Task.detached(priority: .utility) {
            var accumulator = TaskDiskAccumulator()
            defer { continuation.finish() }
            while !Task.isCancelled {
                let device = resolve(destination)
                let samples = sample()
                let rows = accumulator.update(samples, at: ProcessInfo.processInfo.systemUptime)
                continuation.yield(device.flatMap { id in rows.first { $0.sample.deviceID == id } })
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
        continuation.onTermination = { _ in worker.cancel() }
        defer {
            worker.cancel()
            if generation == ticket { usage = nil }
        }
        for await snapshot in snapshots {
            guard !Task.isCancelled, generation == ticket else { return }
            usage = snapshot
        }
    }
}

/// Kernel counters and device metadata only: no volumes are listed, files opened,
/// benchmark writes issued, or disk contents scanned.
enum TaskDiskSampler {
    static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func counter(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return UInt64(number.stringValue)
    }

    static func registryID(_ service: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    static func sample() -> [TaskDiskSample] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [TaskDiskSample] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            var device: io_registry_entry_t = 0
            guard let id = registryID(driver),
                  IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(device) }
            guard IOObjectConformsTo(device, "IOBlockStorageDevice") != 0,
                  let deviceID = registryID(device) else { continue }
            let characteristics = property(device, "Device Characteristics") as? [String: Any] ?? [:]
            let transport = property(device, "Protocol Characteristics") as? [String: Any] ?? [:]
            let interconnect = transport["Physical Interconnect"] as? String ?? ""
            guard interconnect != "Virtual Interface", interconnect != "Disk Image" else { continue }
            var mediaIterator: io_iterator_t = 0
            var bsdName = ""
            if IORegistryEntryGetChildIterator(driver, kIOServicePlane, &mediaIterator) == KERN_SUCCESS {
                defer { IOObjectRelease(mediaIterator) }
                while case let media = IOIteratorNext(mediaIterator), media != 0 {
                    defer { IOObjectRelease(media) }
                    if IOObjectConformsTo(media, "IOMedia") != 0,
                       property(media, "Whole") as? Bool == true,
                       let name = property(media, "BSD Name") as? String {
                        bsdName = name
                        break
                    }
                }
            }
            // Empty card readers have drivers/counters but no attached medium.
            guard !bsdName.isEmpty else { continue }
            let vendor = (characteristics["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let product = (characteristics["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
            let stats = property(driver, "Statistics") as? [String: Any] ?? [:]
            let medium = characteristics["Medium Type"] as? String ?? ""
            result.append(.init(id: id, deviceID: deviceID, name: name.isEmpty ? "Disk" : name,
                device: bsdName, location: transport["Physical Interconnect Location"] as? String ?? "",
                interconnect: interconnect, medium: medium == "Rotational" ? "HDD" : medium == "Solid State" ? "SSD" : "",
                readBytes: counter(stats["Bytes (Read)"]), writtenBytes: counter(stats["Bytes (Write)"])))
        }
        return result.sorted {
            if $0.location != $1.location { return $0.location == "External" }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

struct TaskDiskTemperature: Sendable {
    let celsius: Double?
    let measuredAt: Date
    var issue: String? = nil
    var retryable = true

    private func validAge(at now: Date) -> TimeInterval? {
        let age = now.timeIntervalSince(measuredAt)
        return age.isFinite && age >= 0 && age < 300 ? age : nil
    }

    func isLastKnown(at now: Date = Date()) -> Bool {
        issue != nil || now.timeIntervalSince(measuredAt) >= 65
    }

    func text(at now: Date = Date()) -> String {
        guard let celsius, celsius.isFinite, (-40...125).contains(celsius),
              validAge(at: now) != nil else { return "Unavailable" }
        return String(format: "%.0f°C", celsius) + (isLastKnown(at: now) ? " · cached" : "")
    }

    var help: String {
        guard celsius != nil else { return issue ?? "This drive does not expose a readable temperature sensor to macOS." }
        let timestamp = measuredAt.formatted(date: .omitted, time: .standard)
        return "Last successful reading: \(timestamp)." + (issue.map { " \($0)" + (retryable ? " Retrying." : "") }
            ?? (isLastKnown() ? " Waiting for a fresh sensor reading." : ""))
    }
}

/// A brief busy/failed SMART request must not erase a known-good reading. Keep
/// its original timestamp and mark it cached; expire it after five minutes.
struct TaskDiskTemperatureCache {
    private(set) var values: [UInt64: TaskDiskTemperature] = [:]

    mutating func update(_ readings: [UInt64: TaskDiskTemperature], at now: Date) {
        if readings.isEmpty {
            values = values.compactMapValues { previous in
                guard previous.celsius != nil,
                      (0..<300).contains(now.timeIntervalSince(previous.measuredAt)) else { return nil }
                var retained = previous
                retained.issue = "Temperature sensors could not be queried."
                retained.retryable = true
                return retained
            }
            return
        }
        var next: [UInt64: TaskDiskTemperature] = [:]
        for (id, incoming) in readings {
            if incoming.celsius == nil, let previous = values[id], previous.celsius != nil,
               (0..<300).contains(now.timeIntervalSince(previous.measuredAt)) {
                var retained = previous
                retained.issue = incoming.issue ?? "The latest sensor request failed."
                retained.retryable = incoming.retryable
                next[id] = retained
            } else {
                next[id] = incoming
            }
        }
        values = next
    }

    static func retryNanoseconds(for readings: [UInt64: TaskDiskTemperature]) -> UInt64 {
        readings.isEmpty || readings.values.contains { $0.celsius == nil && $0.retryable }
            ? 5_000_000_000 : 30_000_000_000
    }
}

/// Read existing ATA/NVMe SMART pages through macOS's public interfaces.
/// Never enables SMART, changes settings, starts a self-test or reads file data.
/// USB bridges/SSDs without this interface remain explicitly unavailable.
enum TaskDiskTemperatureSampler {
    private static func uuid(_ value: String) -> CFUUID { CFUUIDCreateFromString(nil, value as CFString)! }

    static func celsius(from data: [UInt8]) -> Double? {
        guard data.count == 512, data.reduce(UInt8(0), &+) == 0 else { return nil }
        // ATA attributes occupy thirty 12-byte records after the revision word.
        // Prefer Temperature_Celsius (194) over Airflow_Temperature_Cel (190).
        for attribute: UInt8 in [194, 190] {
            for index in 0..<30 {
                let offset = 2 + index * 12
                let value = data[offset + 5]
                if data[offset] == attribute, value > 0, value <= 125 { return Double(value) }
            }
        }
        return nil
    }

    static func celsius(kelvin: UInt16) -> Double? {
        let temperature = Double(kelvin) - 273.15
        return (-40...125).contains(temperature) ? temperature : nil
    }

    private static func failure(_ code: Int32) -> TaskDiskTemperature {
        let reason: String
        switch code {
        case kIOReturnBusy, kIOReturnExclusiveAccess: reason = "The drive's sensor interface is busy."
        case kIOReturnNotPrivileged, kIOReturnNotPermitted: reason = "macOS denied access to the drive's sensor."
        case kIOReturnNoDevice, kIOReturnOffline: reason = "The drive's sensor is disconnected."
        default: reason = String(format: "The sensor request failed (0x%08x).", UInt32(bitPattern: code))
        }
        return .init(celsius: nil, measuredAt: Date(), issue: reason)
    }

    private static func readATA(_ service: io_service_t) -> TaskDiskTemperature {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(service,
            uuid("24514B7A-2804-11D6-8A02-003065704866"),
            uuid("C244E858-109C-11D4-91D4-0050E4C6426F"), &plugin, &score)
        guard created == KERN_SUCCESS else { return failure(created) }
        guard let plugin, let interface = plugin.pointee else {
            return .init(celsius: nil, measuredAt: Date(), issue: "The SMART sensor interface is unavailable.")
        }
        defer { IODestroyPlugInInterface(plugin) }
        var raw: UnsafeMutableRawPointer?
        let queried = interface.pointee.QueryInterface(plugin,
            CFUUIDGetUUIDBytes(uuid("08ABE21C-20D4-11D6-8DF6-0003935A76B2")), &raw)
        guard queried == 0, let raw else {
            return .init(celsius: nil, measuredAt: Date(), issue: "The SMART sensor interface could not be opened.")
        }
        let smart = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOATASMARTInterface>.self)
        defer { _ = smart.pointee.pointee.Release(smart) }
        var data = ATASMARTData()
        let status = smart.pointee.pointee.SMARTReadData(smart, &data)
        guard status == KERN_SUCCESS else { return failure(status) }
        let temperature = withUnsafeBytes(of: data) { celsius(from: Array($0)) }
        return .init(celsius: temperature, measuredAt: Date(),
            issue: temperature == nil ? "The drive returned no valid SMART temperature." : nil)
    }

    private static func readNVMe(_ service: io_service_t) -> Double? {
        celsius(kelvin: taskNVMeTemperatureKelvin(service))
    }

    static func sample() -> [UInt64: TaskDiskTemperature] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: TaskDiskTemperature] = [:]
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let id = TaskDiskSampler.registryID(device) else { continue }
            let temperature: TaskDiskTemperature
            if TaskDiskSampler.property(device, "NVMe SMART Capable") as? Bool == true {
                let value = readNVMe(device)
                temperature = .init(celsius: value, measuredAt: Date(),
                    issue: value == nil ? "The NVMe sensor request failed." : nil)
            } else if TaskDiskSampler.property(device, "SMART Capable") as? Bool == true {
                temperature = readATA(device)
            } else {
                temperature = .init(celsius: nil, measuredAt: Date(),
                    issue: "This drive does not expose a SMART temperature sensor to macOS.", retryable: false)
            }
            result[id] = temperature
        }
        return result
    }
}
