import Foundation

/// Enumerates this device's reachable unicast IP addresses to embed in a pairing QR, so a scanner can
/// dial directly without mDNS/Bonjour discovery. Returns Wi-Fi/Ethernet (`en*`) first and IPv4 before
/// IPv6, excluding loopback, link-local (`169.254.*` / `fe80::`), and tunnel/VM interfaces (AWDL, utun,
/// bridges, …). Pure + dependency-free (`getifaddrs`), so it's unit-testable and shared by both ends.
public enum LocalAddresses {

    /// Current routable unicast addresses, most-likely-reachable first, capped to `limit`.
    public static func current(limit: Int = 4) -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        struct Candidate { let address: String; let isIPv4: Bool; let isEthernet: Bool }
        var candidates: [Candidate] = []

        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }

            let flags = Int32(bitPattern: p.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = p.pointee.ifa_addr else { continue }

            let family = sa.pointee.sa_family
            let isIPv4 = family == sa_family_t(AF_INET)
            let isIPv6 = family == sa_family_t(AF_INET6)
            guard isIPv4 || isIPv6 else { continue }

            let name = String(cString: p.pointee.ifa_name)
            guard !isExcludedInterface(name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            var address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) } // strip scope id
            guard !isLinkLocalOrUnspecified(address, isIPv4: isIPv4) else { continue }
            guard !candidates.contains(where: { $0.address == address }) else { continue }

            candidates.append(Candidate(address: address, isIPv4: isIPv4, isEthernet: name.hasPrefix("en")))
        }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.isEthernet != rhs.element.isEthernet { return lhs.element.isEthernet }
            if lhs.element.isIPv4 != rhs.element.isIPv4 { return lhs.element.isIPv4 }
            return lhs.offset < rhs.offset
        }.map(\.element.address)

        return Array(ordered.prefix(max(0, limit)))
    }

    private static func isExcludedInterface(_ name: String) -> Bool {
        ["lo", "awdl", "llw", "utun", "ipsec", "ppp", "bridge", "vmnet", "tap", "tun", "gif", "stf"]
            .contains { name.hasPrefix($0) }
    }

    private static func isLinkLocalOrUnspecified(_ address: String, isIPv4: Bool) -> Bool {
        if address.isEmpty { return true }
        if isIPv4 { return address.hasPrefix("169.254.") || address == "0.0.0.0" }
        let lower = address.lowercased()
        return lower.hasPrefix("fe80:") || lower == "::" || lower == "::1"
    }
}
