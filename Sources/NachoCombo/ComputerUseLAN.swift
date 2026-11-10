import Foundation
import IOKit.pwr_mgt
import SystemConfiguration
import NachoComboCore

/// Small macOS helpers of the LAN mode: this Mac's private addresses, the two local switches and the sleep guard.
///
/// Not run on a Mac yet - written to compile.
enum ComputerUseLAN {
    /// Private IPv4 addresses of the interfaces that are up (loopback and link-local 169.254/16 left out), sorted so
    /// that `en0`-style names come first. These are the addresses another computer on the LAN can use.
    static func privateIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let text = String(cString: buffer)
            guard !text.hasPrefix("169.254."), ComputerUseNetworkPolicy.isPrivateAddress(text) else { continue }
            found.append((String(cString: entry.pointee.ifa_name), text))
        }
        func rank(_ name: String) -> Int { name.hasPrefix("en") ? 0 : 1 }
        return found.sorted { (rank($0.name), $0.name, $0.address) < (rank($1.name), $1.name, $1.address) }.map { $0.address }
    }

    /// Private IPv6 addresses (unique-local fc00::/7 and link-local fe80::/10, zone removed) of the interfaces that are
    /// up and also carry a private IPv4 address - so the Wi-Fi/Ethernet the user means, not AirDrop or VPN tunnels.
    static func privateIPv6Addresses() -> [String] {
        let wanted = Set(interfaceNamesWithPrivateIPv4())
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  wanted.contains(String(cString: entry.pointee.ifa_name)),
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let text = String(cString: buffer)
            guard ComputerUseNetworkPolicy.isPrivateAddress(text), !ComputerUseNetworkPolicy.isLoopbackAddress(text) else { continue }
            if !found.contains(text) { found.append(text) }
        }
        return found.sorted()
    }

    private static func interfaceNamesWithPrivateIPv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var names: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil,
                  ComputerUseNetworkPolicy.isPrivateAddress(String(cString: buffer)) else { continue }
            names.append(String(cString: entry.pointee.ifa_name))
        }
        return names
    }

    /// `<LocalHostName>.local` (the Bonjour name of this Mac), nil when the name cannot be a DNS name.
    static func localHostName() -> String? {
        var raw = SCDynamicStoreCopyLocalHostName(nil) as String?
        if raw == nil {
            let host = ProcessInfo.processInfo.hostName
            if host.lowercased().hasSuffix(".local") { raw = String(host.dropLast(6)) }
        }
        guard let label = raw?.lowercased(), !label.isEmpty, label.count <= 63,
              label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
        return label + ".local"
    }

    /// Names the LAN certificate must list: loopback, this Mac's private addresses and its `.local` name. The
    /// certificate is created with exactly these; the card compares them with the stored certificate.
    static func certificateNames() -> (dns: [String], ips: [String]) {
        var dns = ["localhost"]
        if let local = localHostName() { dns.append(local) }
        let ips = ["127.0.0.1", "::1"] + privateIPv4Addresses() + privateIPv6Addresses()
        return (dns, ips)
    }

    /// Text of a packed IPv4 (4 bytes) / IPv6 (16 bytes) address.
    static func text(ofPackedAddress data: Data) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let bytes = [UInt8](data)
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        guard bytes.count == 4 || bytes.count == 16, inet_ntop(family, bytes, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    /// Names in `wanted` that the certificate does not list (human-readable). Empty = the certificate still fits.
    static func missingCertificateNames(in der: Data, wanted: (dns: [String], ips: [String])) -> [String] {
        guard let have = ComputerUseCertificate.subjectAltNames(der: der) else { return wanted.dns + wanted.ips }
        var missing = wanted.dns.filter { !have.dnsNames.contains($0) }
        for ip in wanted.ips {
            if let bytes = ComputerUseCertificate.ipBytes(ip), !have.ipAddresses.contains(bytes) { missing.append(ip) }
        }
        return missing
    }

    /// Connection URLs of the running or planned endpoint. LAN mode uses TLS (`https`), local-only mode plain HTTP on
    /// the loopback address.
    static func urls(mode: ComputerUseListenMode, bindAddress: String, port: Int) -> [String] {
        let path = ComputerUseService.endpointPath
        switch mode {
        case .localOnly:
            let host = bindAddress == "::1" ? "[::1]" : bindAddress
            return ["http://\(host):\(port)\(path)"]
        case .lan:
            let addresses = privateIPv4Addresses()
            if addresses.isEmpty { return ["https://localhost:\(port)\(path)"] }
            return addresses.map { "https://\($0):\(port)\(path)" }
        }
    }

    /// Bonjour service type of the optional advertisement (LAN mode only). The TXT record carries no secret.
    static let bonjourType = "_nacho-mcp._tcp"
    static var bonjourName: String { "Nacho Combo (\(Host.current().localizedName ?? ProcessInfo.processInfo.hostName))" }
}

/// Two switches that only the macOS layer uses. They live in `UserDefaults`, not in the shared settings file: they
/// change how this Mac behaves (sleep, advertising), not what the MCP service allows.
enum ComputerUseLANPrefs {
    private static let sleepKey = "computerUse.preventSleep"
    private static let bonjourKey = "computerUse.advertiseBonjour"

    /// Keep the Mac awake (no idle system sleep) while the module is ON. Default off.
    static var preventSleep: Bool {
        get { UserDefaults.standard.bool(forKey: sleepKey) }
        set { UserDefaults.standard.set(newValue, forKey: sleepKey) }
    }

    /// Advertise the endpoint over Bonjour while in LAN mode. Default off (advertising announces the Mac).
    static var advertiseBonjour: Bool {
        get { UserDefaults.standard.bool(forKey: bonjourKey) }
        set { UserDefaults.standard.set(newValue, forKey: bonjourKey) }
    }
}

/// Holds one `PreventUserIdleSystemSleep` power assertion. Idempotent: `begin()` twice keeps one, `end()` releases it.
/// The display may still sleep; a sleeping display cannot be captured, which is a limit of the screen tools.
final class SleepGuard {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isActive = false

    @discardableResult
    func begin(reason: String) -> Bool {
        if isActive { return true }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &assertionID)
        isActive = result == kIOReturnSuccess
        return isActive
    }

    func end() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    deinit { end() }
}
