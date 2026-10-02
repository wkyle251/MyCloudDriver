import Darwin
import Foundation

/// What the system resolver is returning for the hosts this engine announces to.
enum TorrentDNSState: Equatable {
    /// Nothing has been resolved yet. Claims neither health nor interference.
    case unknown
    case clean
    /// A proxy answered with a placeholder address instead of the real one.
    case placeholder(String)
}

/// Recognises the addresses a proxy hands out when it answers DNS itself.
///
/// Clash, mihomo, sing-box and Surge default to "fake-IP" mode: every hostname
/// resolves to a synthetic address that exists only inside the proxy's own
/// routing table. A capable tunnel forwards both TCP and UDP through these
/// addresses. Their presence identifies proxy DNS; it cannot establish whether
/// trackers, DHT or peer connections are blocked.
enum TorrentFakeIP {
    /// 198.18.0.0/15 — RFC 2544 benchmark space, and the default pool for every
    /// one of those tools.
    private static let poolBase: UInt32 = 0xC612_0000
    private static let poolMask: UInt32 = 0xFFFE_0000

    static func isPlaceholder(_ address: String) -> Bool {
        var value = in_addr()
        guard inet_pton(AF_INET, address, &value) == 1 else { return false }
        return UInt32(bigEndian: value.s_addr) & poolMask == poolBase
    }

    /// Reports the first placeholder answer among `hosts`.
    ///
    /// A resolver that answers nothing at all — no network, no DNS — reports
    /// `.unknown` rather than `.clean`. Silence is not evidence of health, and
    /// claiming otherwise would clear a warning that may still be warranted.
    static func probe(_ hosts: [String], resolve: (String) -> [String] = TorrentFakeIP.addresses(of:)) -> TorrentDNSState {
        var answered = false
        for host in hosts {
            let found = resolve(host)
            answered = answered || !found.isEmpty
            if let placeholder = found.first(where: isPlaceholder) { return .placeholder(placeholder) }
        }
        return answered ? .clean : .unknown
    }

    /// The IPv4 addresses the system resolver returns for `host`. Blocking.
    static func addresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let raw = entry.pointee.ai_addr, raw.pointee.sa_family == UInt8(AF_INET) else { continue }
            var value = UnsafeRawPointer(raw).loadUnaligned(as: sockaddr_in.self).sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            found.append(String(cString: text))
        }
        return found
    }
}
