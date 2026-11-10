import Foundation

/// Who may talk to the Computer Use server and under which Host name. Pure functions without any networking, so they
/// are unit-tested on Linux. Everything here fails closed: text that cannot be parsed strictly is "not allowed".
public enum ComputerUseNetworkPolicy {

    // MARK: address parsing

    private enum IPAddress {
        case v4([UInt8])    // 4 octets
        case v6([UInt16])   // 8 groups
    }

    /// Strict dotted-quad: exactly four decimal parts of 1-3 digits, no leading zeros (the "010" form is ambiguous
    /// between decimal and octal), each 0-255.
    private static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else { return nil }
            if part.count > 1 && part.first == "0" { return nil }
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func parseHexGroups(_ text: Substring) -> [UInt16]? {
        if text.isEmpty { return [] }
        var groups: [UInt16] = []
        for piece in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard (1...4).contains(piece.count),
                  piece.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) || ($0.value >= 65 && $0.value <= 70) }),
                  let value = UInt16(piece, radix: 16) else { return nil }
            groups.append(value)
        }
        return groups
    }

    /// An IPv6 literal without brackets and without zone id. An embedded IPv4 tail ("::ffff:1.2.3.4") is accepted.
    private static func parseIPv6(_ text: String) -> [UInt16]? {
        guard text.contains(":") else { return nil }
        var body = text
        if text.contains(".") {
            guard let lastColon = text.lastIndex(of: ":"), let v4 = parseIPv4(String(text[text.index(after: lastColon)...])) else { return nil }
            let high = String(UInt16(v4[0]) << 8 | UInt16(v4[1]), radix: 16)
            let low = String(UInt16(v4[2]) << 8 | UInt16(v4[3]), radix: 16)
            body = String(text[...lastColon]) + high + ":" + low
        }
        let halves = body.components(separatedBy: "::")
        switch halves.count {
        case 1:
            guard let groups = parseHexGroups(Substring(body)), groups.count == 8 else { return nil }
            return groups
        case 2:
            guard let left = parseHexGroups(Substring(halves[0])), let right = parseHexGroups(Substring(halves[1])),
                  left.count + right.count <= 7 else { return nil }
            return left + [UInt16](repeating: 0, count: 8 - left.count - right.count) + right
        default:
            return nil
        }
    }

    /// `allowZone`: an IPv6 literal may carry "%en0" (link-local peers do). Anything else with a "%" is rejected.
    private static func parseAddress(_ raw: String, allowBrackets: Bool, allowZone: Bool) -> IPAddress? {
        var text = raw
        if text.hasPrefix("[") || text.hasSuffix("]") {
            guard allowBrackets, text.hasPrefix("["), text.hasSuffix("]"), text.count >= 3 else { return nil }
            text = String(text.dropFirst().dropLast())
            guard text.contains(":") else { return nil }   // brackets are for IPv6 only
        }
        if let percent = text.firstIndex(of: "%") {
            let zone = text[text.index(after: percent)...]
            guard allowZone, !zone.isEmpty, zone.count <= 32,
                  zone.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "." || $0 == "-" || $0 == "_" }) else { return nil }
            text = String(text[..<percent])
            guard text.contains(":") else { return nil }   // zones exist only on IPv6
        }
        if let octets = parseIPv4(text) { return .v4(octets) }
        if let groups = parseIPv6(text) { return .v6(groups) }
        return nil
    }

    /// IPv4-mapped IPv6 ("::ffff:a.b.c.d") is judged by the IPv4 address inside it.
    private static func unmapped(_ address: IPAddress) -> IPAddress {
        guard case .v6(let g) = address, g[0...4].allSatisfy({ $0 == 0 }), g[5] == 0xffff else { return address }
        return .v4([UInt8(g[6] >> 8), UInt8(g[6] & 0xff), UInt8(g[7] >> 8), UInt8(g[7] & 0xff)])
    }

    private static func isLoopback(_ address: IPAddress) -> Bool {
        switch unmapped(address) {
        case .v4(let o): return o[0] == 127
        case .v6(let g): return g[0...6].allSatisfy({ $0 == 0 }) && g[7] == 1
        }
    }

    private static func isPrivate(_ address: IPAddress) -> Bool {
        if isLoopback(address) { return true }
        switch unmapped(address) {
        case .v4(let o):
            return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
        case .v6(let g):
            return (g[0] & 0xfe00) == 0xfc00 || (g[0] & 0xffc0) == 0xfe80   // fc00::/7, fe80::/10
        }
    }

    // MARK: addresses

    /// RFC 1918 (10/8, 172.16/12, 192.168/16), link-local (169.254/16, fe80::/10), unique local (fc00::/7) and
    /// loopback (127/8, ::1). IPv4-mapped IPv6 is judged by the IPv4 inside. Malformed text is never private.
    public static func isPrivateAddress(_ address: String) -> Bool {
        guard let parsed = parseAddress(address, allowBrackets: true, allowZone: true) else { return false }
        return isPrivate(parsed)
    }

    public static func isLoopbackAddress(_ address: String) -> Bool {
        guard let parsed = parseAddress(address, allowBrackets: true, allowZone: true) else { return false }
        return isLoopback(parsed)
    }

    /// May a connection from `clientID` (the peer IP) be served at all? Local-only: loopback peers only.
    /// LAN mode: private-network peers only. Public or unparsable peers are refused in both modes.
    public static func isRemoteAddressAllowed(_ clientID: String, _ config: ComputerUseSettings) -> Bool {
        switch config.listenMode {
        case .localOnly: return isLoopbackAddress(clientID)
        case .lan: return isPrivateAddress(clientID)
        }
    }

    /// One canonical spelling per address, so the same computer cannot dodge a lockout or a rate limit by changing the
    /// notation ("::ffff:192.168.0.9" = "192.168.0.9", upper/lower case, zone id, brackets). Unparsable text is
    /// lower-cased and cut to 64 characters so a hostile value cannot grow the limiter tables.
    public static func normalizeClientID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard let parsed = parseAddress(trimmed, allowBrackets: true, allowZone: true) else { return String(trimmed.lowercased().prefix(64)) }
        switch unmapped(parsed) {
        case .v4(let o): return o.map { String($0) }.joined(separator: ".")
        case .v6(let g): return canonical(g)
        }
    }

    /// RFC 5952: lower-case hex without leading zeros, the longest run (>= 2) of zero groups becomes "::".
    private static func canonical(_ g: [UInt16]) -> String {
        var bestStart = -1, bestLength = 0, i = 0
        while i < 8 {
            if g[i] == 0 {
                var j = i
                while j < 8 && g[j] == 0 { j += 1 }
                if j - i > bestLength { bestStart = i; bestLength = j - i }
                i = j
            } else { i += 1 }
        }
        func join(_ range: Range<Int>) -> String { range.map { String(g[$0], radix: 16) }.joined(separator: ":") }
        guard bestLength >= 2 else { return join(0..<8) }
        return join(0..<bestStart) + "::" + join((bestStart + bestLength)..<8)
    }

    // MARK: Host header (DNS rebinding)

    private struct HostParts { let name: String; let bracketed: Bool }

    /// "name", "name:port", "[v6]" or "[v6]:port". Anything else (userinfo, paths, bare IPv6, empty port, junk) is nil.
    private static func splitHostHeader(_ value: String) -> HostParts? {
        let v = value.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !v.isEmpty else { return nil }
        func validPort(_ s: Substring) -> Bool {
            (1...5).contains(s.count) && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }
        if v.hasPrefix("[") {
            guard let close = v.firstIndex(of: "]") else { return nil }
            let inside = String(v[v.index(after: v.startIndex)..<close])
            let rest = v[v.index(after: close)...]
            guard !inside.isEmpty else { return nil }
            if !rest.isEmpty { guard rest.hasPrefix(":"), validPort(rest.dropFirst()) else { return nil } }
            return HostParts(name: inside.lowercased(), bracketed: true)
        }
        let pieces = v.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let name = pieces.first, !name.isEmpty else { return nil }
        if pieces.count == 2 { guard validPort(pieces[1]) else { return nil } }
        return HostParts(name: name.lowercased(), bracketed: false)
    }

    /// `something.local` with proper DNS labels (mDNS / Bonjour names).
    private static func isLocalDomainName(_ name: String) -> Bool {
        guard name.hasSuffix(".local"), name.count <= 253 else { return false }
        let prefix = String(name.dropLast(".local".count))
        for label in prefix.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" }) else { return false }
        }
        return true
    }

    /// Is this Host (or an Origin's authority) acceptable?
    /// - local-only: localhost, 127.0.0.1, [::1] and the user's `allowedHosts`, exactly as before.
    /// - LAN: additionally IP literals of private ranges, `*.local` names and `localhost`. Public IP literals and
    ///   ordinary DNS names are refused (a rebinding page on the internet always arrives with its own name), unless the
    ///   user listed that name in `allowedHosts`.
    public static func isHostAllowed(_ hostHeader: String, _ config: ComputerUseSettings) -> Bool {
        guard var parts = splitHostHeader(hostHeader) else { return false }
        if !parts.bracketed, parts.name.hasSuffix("."), !parts.name.hasSuffix("..") {
            parts = HostParts(name: String(parts.name.dropLast()), bracketed: false)
        }
        let name = parts.name
        guard !name.isEmpty else { return false }

        if config.allowedHosts.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == name }) { return true }

        if parts.bracketed {
            guard let parsed = parseAddress(name, allowBrackets: false, allowZone: false), name.contains(":") else { return false }
            return config.listenMode == .lan ? isPrivate(parsed) : isLoopback(parsed) && !isMappedV4(parsed)
        }
        if let octets = parseIPv4(name) {
            return config.listenMode == .lan ? isPrivate(.v4(octets)) : name == "127.0.0.1"
        }
        if name == "localhost" { return true }
        return config.listenMode == .lan && isLocalDomainName(name)
    }

    private static func isMappedV4(_ address: IPAddress) -> Bool {
        if case .v4 = unmapped(address), case .v6 = address { return true }
        return false
    }
}
