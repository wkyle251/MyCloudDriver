import Darwin
import Foundation

/// Whether an IPv4 address can be reached from the public internet.
///
/// A port mapping onto a private or carrier-NAT address is not reachability: the
/// router opened a door onto a network that is itself behind another door.
enum TorrentIPv4 {
    private static let unroutable: [(base: UInt32, mask: UInt32)] = [
        (0x0000_0000, 0xFF00_0000), // 0.0.0.0/8       this network
        (0x0A00_0000, 0xFF00_0000), // 10.0.0.0/8      RFC 1918
        (0x7F00_0000, 0xFF00_0000), // 127.0.0.0/8     loopback
        (0x6440_0000, 0xFFC0_0000), // 100.64.0.0/10   RFC 6598 carrier-grade NAT
        (0xAC10_0000, 0xFFF0_0000), // 172.16.0.0/12   RFC 1918
        (0xA9FE_0000, 0xFFFF_0000), // 169.254.0.0/16  link-local
        (0xC0A8_0000, 0xFFFF_0000), // 192.168.0.0/16  RFC 1918
        (0xE000_0000, 0xF000_0000), // 224.0.0.0/4     multicast and above
    ]

    static func isRoutable(_ address: String) -> Bool {
        var value = in_addr()
        guard inet_pton(AF_INET, address, &value) == 1 else { return false }
        let host = UInt32(bigEndian: value.s_addr)
        return !unroutable.contains { host & $0.mask == $0.base }
    }
}

/// Minimal UPnP Internet Gateway Device client, for routers that do not answer
/// NAT-PMP.
///
/// The two protocols cover largely disjoint hardware — most consumer routers ship
/// UPnP and no NAT-PMP — so a client speaking only one reports perfectly capable
/// routers as offering no port mapping at all.
enum TorrentUPnP {
    struct Gateway: Equatable {
        /// Absolute SOAP endpoint, resolved against the description's own URL.
        let control: URL
        /// The exact serviceType string, which every SOAPAction must echo back.
        let service: String
    }

    /// Either spelling of the connection service; a gateway offers one or the other.
    private static let connectionServices = ["urn:schemas-upnp-org:service:WANIPConnection:1",
                                             "urn:schemas-upnp-org:service:WANPPPConnection:1"]

    // MARK: - Description parsing

    /// Finds the connection service inside a device description.
    ///
    /// The useful service sits two device levels down and is never the first
    /// listed, so the whole tree is walked rather than the first `controlURL` taken.
    static func gateway(describedBy data: Data, at location: URL) -> Gateway? {
        let reader = ServiceReader(wanted: connectionServices)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let found = reader.found,
              let control = URL(string: found.path, relativeTo: location)?.absoluteURL else { return nil }
        return Gateway(control: control, service: found.service)
    }

    /// The text of the first element with this name, or nil when absent.
    /// Used for both ordinary replies and the `errorCode` inside a SOAP fault.
    static func value(_ name: String, in data: Data) -> String? {
        let reader = ValueReader(wanted: name)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.found
    }

    private final class ServiceReader: NSObject, XMLParserDelegate {
        private let wanted: [String]
        private var element = ""
        private var serviceType = ""
        private var controlURL = ""
        private var insideService = false
        var found: (service: String, path: String)?

        init(wanted: [String]) { self.wanted = wanted }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            element = name
            if name == "service" { insideService = true; serviceType = ""; controlURL = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideService else { return }
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if element == "serviceType" { serviceType += text }
            if element == "controlURL" { controlURL += text }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == "service" {
                if found == nil, wanted.contains(serviceType), !controlURL.isEmpty {
                    found = (serviceType, controlURL)
                }
                insideService = false
            }
            element = ""
        }
    }

    private final class ValueReader: NSObject, XMLParserDelegate {
        private let wanted: String
        private var capturing = false
        var found: String?

        init(wanted: String) { self.wanted = wanted }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            capturing = found == nil && name == wanted
            if capturing, found == nil { found = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing else { return }
            found = (found ?? "") + string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == wanted { capturing = false; found = found?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: - Discovery and SOAP

    private static let searchTarget = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
    private static let multicast = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900

    /// Locates the gateway: SSDP for the description URL, then fetch and parse it.
    static func gateway(session: URLSession = .shared) async -> Gateway? {
        guard let location = search() else { return nil }
        guard let data = try? await session.data(from: location).0 else { return nil }
        return gateway(describedBy: data, at: location)
    }

    /// One SSDP M-SEARCH, returning the first gateway's description URL.
    /// Blocking, with the same short budget the NAT-PMP probe uses.
    static func search(timeout: TimeInterval = 2) -> URL? {
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: \(multicast):\(multicastPort)\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: \(searchTarget)\r
        \r

        """
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return nil }
        defer { close(handle) }
        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = multicastPort.bigEndian
        guard inet_pton(AF_INET, multicast, &destination.sin_addr) == 1 else { return nil }

        let sent = Array(request.utf8).withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(handle, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = recv(handle, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        let reply = String(decoding: buffer[0..<received], as: UTF8.self)
        for line in reply.split(separator: "\r\n") where line.lowercased().hasPrefix("location:") {
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            return URL(string: value)
        }
        return nil
    }

    /// The SOAP envelope for one action. Its body is already-escaped XML fragments.
    static func envelope(action: String, service: String, body: String) -> String {
        """
        <?xml version="1.0"?>        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">        <s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
    }

    /// Sends one action. Returns the reply body, or nil on transport failure.
    /// A SOAP fault still returns its body so the caller can read `errorCode`.
    static func send(_ action: String, to gateway: Gateway, body: String = "",
                     session: URLSession = .shared) async -> Data? {
        var request = URLRequest(url: gateway.control)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(gateway.service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope(action: action, service: gateway.service, body: body).utf8)
        return try? await session.data(for: request).0
    }

    static func externalAddress(of gateway: Gateway, session: URLSession = .shared) async -> String? {
        guard let data = await send("GetExternalIPAddress", to: gateway, session: session) else { return nil }
        return value("NewExternalIPAddress", in: data)
    }

    /// Maps one port. Falls back to a permanent mapping when the gateway refuses
    /// a finite lease — error 725, which some firmware returns for any non-zero value.
    static func addMapping(_ gateway: Gateway, port: UInt16, proto: String, client: String,
                           lease: UInt32, session: URLSession = .shared) async -> Bool {
        func attempt(_ duration: UInt32) async -> (ok: Bool, code: String?) {
            let body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort>" +
                       "<NewProtocol>\(proto)</NewProtocol><NewInternalPort>\(port)</NewInternalPort>" +
                       "<NewInternalClient>\(client)</NewInternalClient><NewEnabled>1</NewEnabled>" +
                       "<NewPortMappingDescription>MyCloudDriver</NewPortMappingDescription>" +
                       "<NewLeaseDuration>\(duration)</NewLeaseDuration>"
            guard let data = await send("AddPortMapping", to: gateway, body: body, session: session) else { return (false, nil) }
            let code = value("errorCode", in: data)
            return (code == nil, code)
        }
        let first = await attempt(lease)
        if first.ok { return true }
        guard first.code == "725" else { return false }
        return await attempt(0).ok
    }

    static func deleteMapping(_ gateway: Gateway, port: UInt16, proto: String,
                              session: URLSession = .shared) async {
        let body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort>" +
                   "<NewProtocol>\(proto)</NewProtocol>"
        _ = await send("DeletePortMapping", to: gateway, body: body, session: session)
    }

    /// This Mac's address on the route to `host`, which is what the gateway must
    /// be told to forward to. Taken from a connected UDP socket, so it reflects
    /// the kernel's own source choice rather than a guess among interfaces.
    static func localAddress(towards host: String) -> String? {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return nil }
        defer { close(handle) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &destination) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &local) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &size) }
        }
        guard read == 0 else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}
