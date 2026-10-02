import Foundation
import Darwin

/// Short-lived connection hints for public torrents. These never establish
/// connectivity on their own: each restored peer must complete a new handshake.
struct TorrentPeerCache {
    static let maximumPeers = 64
    static let lifetime: TimeInterval = 24 * 60 * 60
    let directory: URL

    struct Hint: Codable, Equatable {
        let host: String
        let port: UInt16
        let observedAt: TimeInterval
        let seeder: Bool
        let transferred: Bool
        var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
        var rpcValue: [String: Any] { ["ip": host, "port": Int(port)] }

        init?(peer: LocalTorrentPeer, now: Date) {
            guard let endpoint = Self.endpoint(peer.address) else { return nil }
            host = endpoint.0; port = endpoint.1; observedAt = now.timeIntervalSince1970
            seeder = peer.seeder; transferred = peer.active
        }

        private static func endpoint(_ address: String) -> (String, UInt16)? {
            let host: String, portText: String
            if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
                host = String(address[address.index(after: address.startIndex)..<end])
                let rest = address[address.index(after: end)...]
                guard rest.hasPrefix(":") else { return nil }
                portText = String(rest.dropFirst())
            } else {
                guard let colon = address.lastIndex(of: ":"), colon == address.firstIndex(of: ":") else { return nil }
                host = String(address[..<colon]); portText = String(address[address.index(after: colon)...])
            }
            guard let port = UInt16(portText), port > 0, let normalized = publicAddress(host) else { return nil }
            return (normalized, port)
        }

        static func publicAddress(_ host: String) -> String? {
            guard !host.isEmpty, host.utf8.count <= 45 else { return nil }
            var ipv4 = in_addr(), ipv6 = in6_addr()
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_pton(AF_INET, host, &ipv4) == 1 {
                let address = UInt32(bigEndian: ipv4.s_addr), first = address >> 24, second = (address >> 16) & 255
                guard first > 0, first < 224, first != 10, first != 127,
                      !(first == 100 && (64...127).contains(second)),
                      !(first == 169 && second == 254), !(first == 172 && (16...31).contains(second)),
                      !(first == 192 && second == 168), !(first == 198 && (18...19).contains(second)) else { return nil }
                guard inet_ntop(AF_INET, &ipv4, &output, socklen_t(output.count)) != nil else { return nil }
            } else if inet_pton(AF_INET6, host, &ipv6) == 1 {
                // Global unicast only; omit link-local, loopback, mapped IPv4,
                // multicast and virtual tunnel addresses from persistent hints.
                guard withUnsafeBytes(of: ipv6, { $0[0] & 0xe0 == 0x20 }) else { return nil }
                guard inet_ntop(AF_INET6, &ipv6, &output, socklen_t(output.count)) != nil else { return nil }
            } else { return nil }
            return String(cString: output)
        }

        func valid(at now: Date) -> Bool {
            let age = now.timeIntervalSince1970 - observedAt
            return observedAt.isFinite && age >= -60 && age < TorrentPeerCache.lifetime && port > 0
                && Self.publicAddress(host) == host
        }
    }

    private struct Saved: Codable {
        let version: Int
        let infoHash: String
        let peers: [Hint]
    }

    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func load(_ hash: String, now: Date = Date()) -> [Hint] {
        guard Self.validHash(hash),
              let folder = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              folder.isDirectory == true, folder.isSymbolicLink != true,
              let data = try? LocalTorrentStore.read(directory.appendingPathComponent(hash + ".json"), maximum: 32 * 1024),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1,
              saved.infoHash == hash, saved.peers.count <= Self.maximumPeers else { return [] }
        return ranked(saved.peers.filter { $0.valid(at: now) })
    }

    func record(_ hash: String, peers: [LocalTorrentPeer], now: Date = Date()) throws {
        guard Self.validHash(hash) else { return }
        var known = Dictionary(load(hash, now: now).map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        for peer in peers {
            guard let hint = Hint(peer: peer, now: now) else { continue }
            // Preserve proof of a transfer when a peer temporarily goes idle.
            let previous = known[hint.address]
            let remembered = LocalTorrentPeer(address: hint.address,
                downloadSpeed: hint.transferred || previous?.transferred == true ? 1 : 0,
                uploadSpeed: 0, seeder: hint.seeder)
            known[hint.address] = Hint(peer: remembered, now: now)
        }
        guard !known.isEmpty else { return }
        try LocalTorrentStore.protect(directory)
        let data = try JSONEncoder().encode(Saved(version: 1, infoHash: hash, peers: ranked(Array(known.values))))
        try LocalTorrentStore.write(data, to: directory.appendingPathComponent(hash + ".json"))
        prune(now: now)
    }

    private func ranked(_ peers: [Hint]) -> [Hint] {
        var seen = Set<String>()
        return Array(peers.sorted {
            if $0.transferred != $1.transferred { return $0.transferred }
            if $0.seeder != $1.seeder { return $0.seeder }
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            return $0.address < $1.address
        }.filter { seen.insert($0.address).inserted }.prefix(Self.maximumPeers))
    }

    private func prune(now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        let owned = files.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json", Self.validHash(url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in owned.enumerated() where index >= 128 || now.timeIntervalSince(entry.1) >= Self.lifetime {
            try? FileManager.default.removeItem(at: entry.0)
        }
    }
}
