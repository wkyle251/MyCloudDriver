import Darwin
import Foundation
#if canImport(AppFixCore)
@testable import AppFixCore
#endif

private struct Failure: Error, CustomStringConvertible {
    let description: String
}
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
}

/// No request leaves URLSession: responses are generated in-process.
private final class SOAPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [(Int, String)] = []
    static var bodies: [String] = []
    static func configure(_ values: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }; replies = values; bodies = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < 16384 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        let reply = Self.replies.isEmpty ? (500, "fixture queue exhausted") : Self.replies.removeFirst()
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor MappingFixture {
    var events: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var gated = false
    var udpOnly = false
    func add(_ port: UInt16, _ proto: String) async -> UInt32? {
        events.append("add:\(port):\(proto)")
        if !udpOnly && !gated {
            gated = true
            await withCheckedContinuation { gate = $0 }
        }
        return udpOnly && proto == "TCP" ? nil : 0
    }
    func remove(_ port: UInt16, _ proto: String) { events.append("remove:\(port):\(proto)") }
    func release() { gate?.resume(); gate = nil }
    func useUDPOnly() { udpOnly = true }
    func snapshot() -> [String] { events }
}

@main @MainActor private struct TorrentSafetyTests {
    static let gateway = TorrentUPnP.Gateway(control: URL(string: "http://127.0.0.1:1/control")!, service: "urn:schemas-upnp-org:service:WANIPConnection:1")
    static func soap(_ body: String) -> String {
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>\(body)</s:Body></s:Envelope>"
    }
    static func response(_ action: String = "AddPortMapping") -> String {
        soap("<u:\(action)Response xmlns:u=\"\(gateway.service)\"/>")
    }
    static func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await predicate()) {
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure(description: "Fixture did not reach expected state") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func operations(_ fixture: MappingFixture) -> TorrentPortMapper.UPnPOperations {
        let found = gateway
        return .init(discover: { found }, localAddress: { _ in "192.168.1.2" },
              add: { _, port, proto, _, _ in await fixture.add(port, proto) },
              remove: { _, port, proto in await fixture.remove(port, proto) },
              address: { _ in "203.0.113.5" })
    }
    static func soapContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SOAPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for value in [(500, "<html>error</html>"), (404, "missing"), (200, ""), (200, response("DeletePortMapping")), (500, response()), (200, String(response().dropLast(5)))] {
            SOAPFixture.configure([value])
            let lease = await TorrentUPnP.mappingLease(gateway, port: 1234, proto: "TCP", client: "192.168.1.2", lease: 3600, session: session)
            try check(lease == nil, "Invalid HTTP/SOAP response accepted: \(value.0)")
        }
        SOAPFixture.configure([(200, response())])
        let finite = await TorrentUPnP.mappingLease(gateway, port: 1234, proto: "TCP", client: "192.168.1.2", lease: 3600, session: session)
        try check(finite == 3600, "Valid finite SOAP mapping rejected")
        let fault = soap("<s:Fault><faultcode>s:Client</faultcode><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>725</errorCode></UPnPError></detail></s:Fault>")
        SOAPFixture.configure([(500, fault), (200, response())])
        let permanent = await TorrentUPnP.mappingLease(gateway, port: 1234, proto: "TCP", client: "192.168.1.2", lease: 3600, session: session)
        try check(permanent == 0, "Fault 725 permanent fallback not recorded")
        try check(SOAPFixture.bodies.count == 2 && SOAPFixture.bodies[1].contains("<NewLeaseDuration>0</NewLeaseDuration>"), "Permanent fallback sent wrong lease")
        SOAPFixture.configure([(500, fault), (500, "failure")])
        let refused = await TorrentUPnP.mappingLease(gateway, port: 1234, proto: "TCP", client: "192.168.1.2", lease: 3600, session: session)
        try check(refused == nil, "Failed permanent fallback accepted")
        print("PASS strict SOAP acceptance and acknowledged permanent-lease fallback")
    }
    static func mappingLifecycle() async throws {
        let fixture = MappingFixture()
        let lifecycle = TorrentPortMapper(upnpOperations: operations(fixture))
        await lifecycle.start(tcp: 1234, udp: 1234)
        try await wait { await fixture.snapshot().contains("add:1234:TCP") }
        let stopped = Task { await lifecycle.stop() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await lifecycle.start(tcp: 2345, udp: 2345)
        await fixture.release()
        await stopped.value
        try await wait { await lifecycle.state.tcpPort == 2345 }
        let state = await lifecycle.state, events = await fixture.snapshot()
        try check(state.udpPort == 2345 && state.leaseSeconds == 0, "New generation lost protocol or permanent-lease state")
        try check(!events.contains("add:1234:UDP"), "Obsolete generation continued adding ports after Stop")
        try check(events.firstIndex(of: "remove:1234:TCP")! < events.firstIndex(of: "add:2345:TCP")!, "Old cleanup ran after new mapping")
        await lifecycle.stop()
        let cleanup = await fixture.snapshot()
        try check(cleanup.contains("remove:2345:TCP") && cleanup.contains("remove:2345:UDP"), "Stop did not remove both accepted permanent mappings")
        let udp = MappingFixture(); await udp.useUDPOnly()
        let partial = TorrentPortMapper(upnpOperations: operations(udp))
        await partial.start(tcp: 3456, udp: 3457)
        try await wait { await partial.state.udpPort == 3457 }
        let udpState = await partial.state
        try check(!udpState.isMapped && udpState.tcpPort == nil, "UDP-only acceptance reported TCP mapped")
        await partial.stop()
        print("PASS Stop/start generations, late mapping receipt cleanup and independent TCP/UDP states")
    }
    static func udpAdmission() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure(description: "Cannot create UDP fixture") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try check(result == 0, "UDP fixture could not bind")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) } }
        let port = UInt16(bigEndian: address.sin_port)
        try check(TorrentRPCEngine.bindable(port, tcp: true, udp: false), "UDP fixture unexpectedly blocked TCP")
        try check(!TorrentRPCEngine.bindable(port, tcp: true, udp: true), "Engine admitted an occupied UDP port")
        print("PASS UDP-only socket collision prevents engine port admission")
    }
    static func ramCommandBounds() async throws {
        let small = try await TorrentRAMDisk.command("/usr/bin/python3", ["-c", "print('fixture')"], timeout: 5, maximumOutput: 1024)
        try check(String(decoding: small, as: UTF8.self) == "fixture\n", "Bounded command lost stdout")
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await TorrentRAMDisk.command("/usr/bin/python3", ["-c", "import time; time.sleep(30)"], timeout: 0.2)
            throw Failure(description: "Command ignored deadline")
        } catch is Failure { throw Failure(description: "Command ignored deadline") } catch {}
        try check(ProcessInfo.processInfo.systemUptime - began < 3, "Timed out helper was not stopped promptly")
        do {
            _ = try await TorrentRAMDisk.command("/usr/bin/python3", ["-c", "import os; os.write(1,b'x'*100000)"], timeout: 5, maximumOutput: 1024)
            throw Failure(description: "Command ignored output limit")
        } catch is Failure { throw Failure(description: "Command ignored output limit") } catch {}
        let task = Task { try await TorrentRAMDisk.command("/usr/bin/python3", ["-c", "import time; time.sleep(30)"], timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; throw Failure(description: "Command ignored cancellation") }
        catch is CancellationError {} catch { throw error }
        print("PASS RAM command output/deadline bounds and caller cancellation")
    }
    static func relayContainment() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TorrentSafety-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload"), parent = payload.appendingPathComponent("parent"), outside = root.appendingPathComponent("outside")
        for directory in [parent, outside] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let original = parent.appendingPathComponent("cache.dat"), sentinel = outside.appendingPathComponent("cache.dat")
        try Data("owned".utf8).write(to: original); try Data("outside".utf8).write(to: sentinel)
        let held = try TorrentRelayStorage.openedFile("parent/cache.dat", under: payload)!
        let moved = root.appendingPathComponent("moved")
        try manager.moveItem(at: parent, to: moved)
        try manager.createSymbolicLink(at: parent, withDestinationURL: outside)
        try held.remove()
        try check(!manager.fileExists(atPath: moved.appendingPathComponent("cache.dat").path), "Held parent did not remove original file")
        try check(try Data(contentsOf: sentinel) == Data("outside".utf8), "Ancestor replacement deleted external file")
        do { try TorrentRelayStorage.removeFile("parent/cache.dat", under: payload); throw Failure(description: "Cleanup followed ancestor symlink") }
        catch is Failure { throw Failure(description: "Cleanup followed ancestor symlink") } catch {}
        try manager.removeItem(at: parent)
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: original)
        let stale = try TorrentRelayStorage.openedFile("parent/cache.dat", under: payload)!
        try manager.moveItem(at: original, to: parent.appendingPathComponent("retained.dat"))
        try Data("replacement".utf8).write(to: original)
        do { try stale.remove(); throw Failure(description: "Cleanup removed replacement inode") }
        catch is Failure { throw Failure(description: "Cleanup removed replacement inode") } catch {}
        try TorrentRelayStorage.clearPayload(payload)
        try check(try manager.contentsOfDirectory(atPath: payload.path).isEmpty, "Descriptor cleanup left payload contents")
        try check(manager.fileExists(atPath: sentinel.path), "Payload cleanup removed external sentinel")
        print("PASS held-directory cleanup rejects ancestor symlinks and replacement files")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try await soapContracts(); try await mappingLifecycle(); try udpAdmission()
        try await ramCommandBounds(); try relayContainment()
    }
}
