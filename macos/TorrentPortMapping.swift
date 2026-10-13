import Darwin
import Foundation

/// Outcome of the most recent NAT-PMP exchange. Surfaced in the torrent UI so an
/// unreachable listen port stops looking like an empty swarm.
enum TorrentPortMapState: Equatable {
    case idle
    /// No default gateway, or the gateway never answered on the NAT-PMP port.
    case unsupported
    case failed(String)
    case mapped(tcp: UInt16?, udp: UInt16? = nil, address: String?, lease: UInt32? = nil)

    var externalAddress: String? { if case .mapped(_, _, let address, _) = self { return address }; return nil }
    var tcpPort: UInt16? { if case .mapped(let port, _, _, _) = self { return port }; return nil }
    var udpPort: UInt16? { if case .mapped(_, let port, _, _) = self { return port }; return nil }
    var leaseSeconds: UInt32? { if case .mapped(_, _, _, let lease) = self { return lease }; return nil }
    /// A UDP-only mapping does not establish the TCP listening port.
    var isMapped: Bool { tcpPort != nil }
}

/// The IPv4 default gateway, read from the kernel routing table.
enum TorrentGateway {
    static func defaultIPv4() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let header = MemoryLayout<rt_msghdr>.size
            var offset = 0
            while offset + header <= size {
                let message = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(message.rtm_msglen)
                guard length >= header, offset + length <= size else { return nil }
                // Addresses follow the header in RTA_* bit order, each padded to 4 bytes.
                if message.rtm_flags & RTF_GATEWAY != 0, message.rtm_addrs & RTA_DST != 0, message.rtm_addrs & RTA_GATEWAY != 0 {
                    var cursor = offset + header
                    var destinationIsDefault = false
                    for bit in [RTA_DST, RTA_GATEWAY] {
                        guard message.rtm_addrs & bit != 0, cursor + MemoryLayout<sockaddr>.size <= offset + length else { break }
                        let address = raw.loadUnaligned(fromByteOffset: cursor, as: sockaddr.self)
                        let step = address.sa_len == 0 ? 4 : (Int(address.sa_len) + 3) & ~3
                        if address.sa_family == UInt8(AF_INET), cursor + MemoryLayout<sockaddr_in>.size <= offset + length {
                            let inet = raw.loadUnaligned(fromByteOffset: cursor, as: sockaddr_in.self)
                            if bit == RTA_DST { destinationIsDefault = inet.sin_addr.s_addr == 0 }
                            else if destinationIsDefault, let text = string(inet.sin_addr) { return text }
                        } else if bit == RTA_DST { destinationIsDefault = false }
                        cursor += step
                    }
                }
                offset += length
            }
            return nil
        }
    }

    private static func string(_ address: in_addr) -> String? {
        var value = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}

/// NAT-PMP (RFC 6886) client for the torrent engine's listen ports.
///
/// aria2 cannot map its own ports. Without a mapping, peers behind NAT — most of
/// a typical swarm — can never open a connection to this Mac, so discovery falls
/// back to the few peers this Mac can reach outbound. Mappings expire on their
/// own, so a crashed app leaves nothing behind on the router.
actor TorrentPortMapper {
    private enum Proto: UInt8 { case udp = 1, tcp = 2 }

    private static let gatewayPort: UInt16 = 5351
    private static let lifetime: UInt32 = 3600
    /// RFC 6886 asks clients to renew at half the granted lifetime.
    private static let renewalFraction = 0.5

    private(set) var state: TorrentPortMapState = .idle
    private let gatewayOverride: String?
    private var renewal: Task<Void, Never>?
    private var granted: [(proto: Proto, internalPort: UInt16, externalPort: UInt16)] = []
    /// The UPnP gateway, once NAT-PMP has proved silent, and what it holds for us.
    private var upnp: TorrentUPnP.Gateway?
    private var upnpPorts: [(port: UInt16, proto: String)] = []

    struct UPnPOperations: Sendable {
        var discover: @Sendable () async -> TorrentUPnP.Gateway?
        var localAddress: @Sendable (String) -> String?
        var add: @Sendable (TorrentUPnP.Gateway, UInt16, String, String, UInt32) async -> UInt32?
        var remove: @Sendable (TorrentUPnP.Gateway, UInt16, String) async -> Void
        var address: @Sendable (TorrentUPnP.Gateway) async -> String?
        static let live = Self(discover: { await TorrentUPnP.gateway() },
            localAddress: { TorrentUPnP.localAddress(towards: $0) },
            add: { await TorrentUPnP.mappingLease($0, port: $1, proto: $2, client: $3, lease: $4) },
            remove: { await TorrentUPnP.deleteMapping($0, port: $1, proto: $2) },
            address: { await TorrentUPnP.externalAddress(of: $0) })
    }
    private let operations: UPnPOperations
    private let upnpOnly: Bool
    private var generation = UUID()

    init(gateway: String? = nil, upnpOperations: UPnPOperations? = nil) {
        gatewayOverride = gateway; operations = upnpOperations ?? .live
        upnpOnly = upnpOperations != nil
    }

    /// New work waits for prior requests and cleanup before touching the router.
    /// In particular, an old permanent mapping cannot outlive Stop or delete a
    /// mapping that a newer Start has just installed on the same port.
    func start(tcp: UInt16, udp: UInt16) {
        let token = UUID(); generation = token; state = .idle
        let previous = renewal; previous?.cancel()
        renewal = Task { [weak self] in
            await previous?.value
            guard let self, await self.isCurrent(token) else { return }
            await self.clearMappings()
            while await self.isCurrent(token) {
                let seconds = await self.renew(tcp: tcp, udp: udp, token: token)
                guard await self.isCurrent(token) else { return }
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            }
        }
    }

    func stop() async {
        let token = UUID(); generation = token; state = .idle
        let previous = renewal; previous?.cancel()
        let cleanup = Task { [weak self] in
            await previous?.value
            await self?.clearMappings()
        }
        renewal = cleanup
        await cleanup.value
        if generation == token { renewal = nil; state = .idle }
    }

    private func isCurrent(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }

    private func clearMappings() async {
        let found = upnp, ports = upnpPorts, mappings = granted
        upnp = nil; upnpPorts = []; granted = []
        if let found {
            for mapping in ports {
                let operation = operations.remove
                // Complete bounded cleanup even if this lifecycle is cancelled.
                await Task { await operation(found, mapping.port, mapping.proto) }.value
            }
        }
        if let gateway = gateway() {
            for mapping in mappings {
                _ = try? exchange(map: mapping.proto, internalPort: mapping.internalPort,
                                  externalPort: 0, lifetime: 0, gateway: gateway)
            }
        }
    }

    private func gateway() -> String? { gatewayOverride ?? TorrentGateway.defaultIPv4() }

    private func renew(tcp: UInt16, udp: UInt16, token: UUID) async -> Double {
        guard isCurrent(token) else { return 60 }
        if upnpOnly { return await renewViaUPnP(tcp: tcp, udp: udp, token: token) }
        guard let gateway = gateway() else { state = .unsupported; return 600 }
        var results: [(Proto, UInt16, UInt16)] = []
        var lifetimes: [UInt32] = []
        var failure: String?
        for (proto, port) in [(Proto.tcp, tcp), (Proto.udp, udp)] {
            guard isCurrent(token) else { return 60 }
            do {
                let reply = try exchange(map: proto, internalPort: port, externalPort: port,
                                         lifetime: Self.lifetime, gateway: gateway)
                results.append((proto, port, reply.externalPort)); lifetimes.append(reply.lifetime)
                granted.removeAll { $0.proto == proto && $0.internalPort == port }
                granted.append((proto, port, reply.externalPort))
            } catch let error as MapError {
                if error == .silent && results.isEmpty {
                    return await renewViaUPnP(tcp: tcp, udp: udp, token: token)
                }
                failure = error.message
            } catch { failure = error.localizedDescription }
        }
        guard isCurrent(token) else { return 60 }
        guard !results.isEmpty else { state = .failed(failure ?? "The router refused port mapping."); return 120 }
        let shortest = lifetimes.min() ?? Self.lifetime
        state = .mapped(tcp: results.first { $0.0 == .tcp }?.2,
                        udp: results.first { $0.0 == .udp }?.2,
                        address: try? externalAddress(gateway: gateway), lease: shortest)
        return max(60, Double(shortest) * Self.renewalFraction)
    }

    private func renewViaUPnP(tcp: UInt16, udp: UInt16, token: UUID) async -> Double {
        var discovered = upnp
        if discovered == nil { discovered = await operations.discover() }
        guard isCurrent(token) else { return 60 }
        guard let found = discovered else { state = .unsupported; return 600 }
        upnp = found
        guard let host = found.control.host, let client = operations.localAddress(host) else { state = .unsupported; return 600 }
        var held: [(port: UInt16, proto: String, lease: UInt32)] = []
        for (port, proto) in [(tcp, "TCP"), (udp, "UDP")] {
            guard isCurrent(token) else { return 60 }
            let operation = operations.add
            // Await the bounded reply even if Stop arrives after the router has
            // accepted it. Keep its receipt so Stop can remove the actual lease.
            let lease = await Task { await operation(found, port, proto, client, Self.lifetime) }.value
            if let lease {
                held.append((port, proto, lease))
                if !upnpPorts.contains(where: { $0.port == port && $0.proto == proto }) { upnpPorts.append((port, proto)) }
            }
            guard isCurrent(token) else { return 60 }
        }
        guard !held.isEmpty else { state = .failed("The router refused a UPnP port mapping."); return 120 }
        let address = await operations.address(found)
        guard isCurrent(token) else { return 60 }
        let shortest = held.map(\.lease).min() ?? Self.lifetime
        state = .mapped(tcp: held.first { $0.proto == "TCP" }?.port,
                        udp: held.first { $0.proto == "UDP" }?.port,
                        address: address, lease: shortest)
        return max(60, Double(shortest == 0 ? Self.lifetime : shortest) * Self.renewalFraction)
    }

    private func externalAddress(gateway: String) throws -> String? {
        let reply = try request([0, 0], gateway: gateway, expect: 12)
        guard reply.count >= 12, reply[1] == 128, UInt16(reply[2]) << 8 | UInt16(reply[3]) == 0 else { return nil }
        return "\(reply[8]).\(reply[9]).\(reply[10]).\(reply[11])"
    }

    private struct MapReply { let externalPort: UInt16; let lifetime: UInt32 }

    private enum MapError: Error, Equatable {
        /// The gateway does not speak NAT-PMP, or it is filtered.
        case silent
        case refused(UInt16)

        var message: String {
            switch self {
            case .silent: return "The router did not answer a port-mapping request."
            case .refused(let code):
                // RFC 6886 §3.5.
                let reasons = [1: "the router needs a newer NAT-PMP version",
                               2: "the router refused the request (port mapping may be disabled)",
                               3: "the router's network is down",
                               4: "the router is out of mapping resources",
                               5: "the router does not support this mapping"]
                return "Port mapping failed: " + (reasons[Int(code)] ?? "the router returned error \(code)") + "."
            }
        }
    }

    private func exchange(map proto: Proto, internalPort: UInt16, externalPort: UInt16,
                          lifetime: UInt32, gateway: String) throws -> MapReply {
        var payload: [UInt8] = [0, proto.rawValue, 0, 0]
        payload += [UInt8(internalPort >> 8), UInt8(internalPort & 0xFF)]
        payload += [UInt8(externalPort >> 8), UInt8(externalPort & 0xFF)]
        payload += [UInt8(lifetime >> 24 & 0xFF), UInt8(lifetime >> 16 & 0xFF), UInt8(lifetime >> 8 & 0xFF), UInt8(lifetime & 0xFF)]
        let reply = try request(payload, gateway: gateway, expect: 16)
        guard reply.count >= 16, reply[1] == 128 &+ proto.rawValue else { throw MapError.silent }
        let code = UInt16(reply[2]) << 8 | UInt16(reply[3])
        guard code == 0 else { throw MapError.refused(code) }
        let mapped = UInt16(reply[10]) << 8 | UInt16(reply[11])
        let granted = UInt32(reply[12]) << 24 | UInt32(reply[13]) << 16 | UInt32(reply[14]) << 8 | UInt32(reply[15])
        return .init(externalPort: mapped, lifetime: granted == 0 ? Self.lifetime : granted)
    }

    /// One UDP request with the retry schedule from RFC 6886 §3.1, shortened so a
    /// router without NAT-PMP does not hold up torrent startup.
    private func request(_ payload: [UInt8], gateway: String, expect: Int) throws -> [UInt8] {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = Self.gatewayPort.bigEndian
        guard inet_pton(AF_INET, gateway, &destination.sin_addr) == 1 else { throw MapError.silent }

        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw MapError.silent }
        defer { close(handle) }

        for milliseconds in [250, 500, 1000] {
            var timeout = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32(milliseconds % 1000) * 1000)
            setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let sent = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(handle, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == payload.count else { continue }
            var buffer = [UInt8](repeating: 0, count: 32)
            let received = recv(handle, &buffer, buffer.count, 0)
            if received >= expect { return Array(buffer[0..<received]) }
        }
        throw MapError.silent
    }
}
