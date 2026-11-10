import Foundation

/// Builds the self-signed X.509 certificate of the LAN mode (ECDSA P-256 / SHA-256) as DER bytes.
///
/// Foundation only on purpose: the macOS Security framework has no public call that creates a certificate, so the
/// bytes are assembled here and only the signature comes from the caller (`SecKeyCreateSignature` in
/// `ComputerUseTLS`). Because it needs nothing from Apple frameworks it can be checked on Linux with `openssl`
/// (see docs/COMPUTER-USE-MCP.md).
///
/// The certificate is not meant to be trusted through a CA chain. Clients pin its SHA-256 fingerprint, which the
/// settings card shows. It also lists the Mac's private addresses and `<name>.local` in the subject alternative name,
/// so a client that has the PEM can verify the host name too (`curl --cacert`). Addresses change (DHCP): when they no
/// longer match, the card says so and the owner regenerates the certificate - which changes the fingerprint.
enum ComputerUseCertificate {
    struct Parameters {
        var commonName: String
        /// Uncompressed X9.62 point `04 || X || Y` (65 bytes) of the P-256 public key.
        var publicKeyPoint: Data
        var notBefore: Date
        var notAfter: Date
        /// 1...20 bytes; the first byte is forced to a positive, non-zero value.
        var serial: Data
        var dnsNames: [String] = ["localhost"]
        /// IPv4/IPv6 literals (text). Unparsable entries are skipped; an IPv6 zone (`%en0`) is cut off.
        var ipAddresses: [String] = []
    }

    /// Names a certificate lists in its subject alternative name.
    struct SubjectAltNames: Equatable {
        var dnsNames: [String] = []
        /// 4 bytes (IPv4) or 16 bytes (IPv6) each.
        var ipAddresses: [Data] = []
    }

    /// DER of the certificate, or nil when the input is unusable or `sign` fails. `sign` receives the DER of the
    /// to-be-signed part and must return an ASN.1 DER `ECDSA-Sig-Value` (what `SecKeyCreateSignature` with
    /// `.ecdsaSignatureMessageX962SHA256` returns).
    static func makeDER(_ p: Parameters, sign: (Data) -> Data?) -> Data? {
        guard p.publicKeyPoint.count == 65, p.publicKeyPoint.first == 0x04 else { return nil }
        guard !p.serial.isEmpty, p.serial.count <= 20 else { return nil }
        guard p.notAfter > p.notBefore else { return nil }
        guard let notBefore = utcTime(p.notBefore), let notAfter = utcTime(p.notAfter) else { return nil }

        var serial = [UInt8](p.serial)
        serial[0] = (serial[0] & 0x7F) | 0x40                    // positive and never needs a padding byte

        let signatureAlgorithm = sequence([oidEcdsaWithSHA256])
        let name = sequence([set([sequence([oidCommonName, utf8String(p.commonName)])])])

        let spki = sequence([
            sequence([oidEcPublicKey, oidPrime256v1]),
            bitString(Data(p.publicKeyPoint)),
        ])

        var extensions: [[UInt8]] = [
            // CA:FALSE (empty SEQUENCE = defaults), critical
            sequence([oidBasicConstraints, boolTrue, octetString(sequence([]))]),
            // digitalSignature, critical
            sequence([oidKeyUsage, boolTrue, octetString(bitStringRaw(unusedBits: 7, bytes: [0x80]))]),
            // serverAuth
            sequence([oidExtKeyUsage, octetString(sequence([oidServerAuth]))]),
        ]
        var names = p.dnsNames.map { tlv(0x82, [UInt8]($0.utf8)) }              // [2] dNSName
        var seenIPs = Set<Data>()
        for text in p.ipAddresses {
            guard let bytes = ipBytes(text), seenIPs.insert(bytes).inserted else { continue }
            names.append(tlv(0x87, [UInt8](bytes)))                              // [7] iPAddress
        }
        if !names.isEmpty {
            extensions.append(sequence([oidSubjectAltName, octetString(sequence(names))]))
        }

        let tbs = sequence([
            tlv(0xA0, integerSmall(2)),                                          // [0] version v3
            tlv(0x02, serial),
            signatureAlgorithm,
            name,
            sequence([notBefore, notAfter]),
            name,                                                                // self-signed: subject == issuer
            spki,
            tlv(0xA3, sequence(extensions)),                                     // [3] extensions
        ])

        guard let signature = sign(Data(tbs)), !signature.isEmpty else { return nil }
        let certificate = sequence([tbs, signatureAlgorithm, bitString(signature)])
        return Data(certificate)
    }

    /// Packed address of an IPv4/IPv6 literal (zone id and brackets removed), nil when it is not an address.
    static func ipBytes(_ text: String) -> Data? {
        var literal = text.trimmingCharacters(in: .whitespaces)
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        if let zone = literal.firstIndex(of: "%") { literal = String(literal[literal.startIndex..<zone]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Data($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Data($0) }
        }
        return nil
    }

    /// Reads the subject alternative name of a DER certificate (nil when the DER is malformed). A minimal reader for
    /// the shape `makeDER` writes, tolerant of other certificates: it only walks SEQUENCE/[3]/extensions.
    static func subjectAltNames(der: Data) -> SubjectAltNames? {
        let bytes = [UInt8](der)
        func read(_ at: Int, _ end: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard at + 2 <= end else { return nil }
            let tag = bytes[at]
            var length = Int(bytes[at + 1])
            var start = at + 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count >= 1, count <= 3, start + count <= end else { return nil }
                length = 0
                for i in 0..<count { length = length << 8 | Int(bytes[start + i]) }
                start += count
            }
            guard start + length <= end else { return nil }
            return (tag, start, start + length)
        }
        func children(_ node: (tag: UInt8, start: Int, end: Int)) -> [(tag: UInt8, start: Int, end: Int)]? {
            var result: [(tag: UInt8, start: Int, end: Int)] = []
            var at = node.start
            while at < node.end {
                guard let child = read(at, node.end) else { return nil }
                result.append(child)
                at = child.end
            }
            return result
        }
        guard let certificate = read(0, bytes.count), certificate.tag == 0x30,
              let top = children(certificate), let tbs = top.first, tbs.tag == 0x30,
              let fields = children(tbs) else { return nil }
        var names = SubjectAltNames()
        for field in fields where field.tag == 0xA3 {
            guard let wrapper = children(field)?.first, wrapper.tag == 0x30, let extensionList = children(wrapper) else { return nil }
            for item in extensionList {
                guard let parts = children(item), let oid = parts.first, oid.tag == 0x06,
                      Array(bytes[oid.start..<oid.end]) == Array(oidSubjectAltName.dropFirst(2)),
                      let value = parts.last, value.tag == 0x04,
                      let inner = read(value.start, value.end), inner.tag == 0x30,
                      let general = children(inner) else { continue }
                for name in general {
                    switch name.tag {
                    case 0x82: names.dnsNames.append(String(decoding: bytes[name.start..<name.end], as: UTF8.self))
                    case 0x87 where name.end - name.start == 4 || name.end - name.start == 16:
                        names.ipAddresses.append(Data(bytes[name.start..<name.end]))
                    default: break
                    }
                }
            }
        }
        return names
    }

    /// `-----BEGIN CERTIFICATE-----` text of a DER certificate.
    static func pem(der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
    }

    /// `AB:CD:...` form of a lowercase/uppercase hex fingerprint (what `openssl x509 -fingerprint` prints).
    static func colonSeparated(hex: String) -> String {
        let upper = Array(hex.uppercased())
        var parts: [String] = []
        var index = 0
        while index < upper.count {
            parts.append(String(upper[index..<min(index + 2, upper.count)]))
            index += 2
        }
        return parts.joined(separator: ":")
    }

    // MARK: DER primitives

    private static func lengthBytes(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + lengthBytes(content.count) + content
    }

    private static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    private static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    private static func octetString(_ content: [UInt8]) -> [UInt8] { tlv(0x04, content) }
    private static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, [UInt8](text.utf8)) }
    private static func integerSmall(_ value: UInt8) -> [UInt8] { tlv(0x02, [value]) }
    private static let boolTrue: [UInt8] = [0x01, 0x01, 0xFF]

    private static func bitString(_ data: Data) -> [UInt8] { bitStringRaw(unusedBits: 0, bytes: [UInt8](data)) }
    private static func bitStringRaw(unusedBits: UInt8, bytes: [UInt8]) -> [UInt8] { tlv(0x03, [unusedBits] + bytes) }

    /// UTCTime `yyMMddHHmmssZ` (valid for 1950...2049; later dates return nil).
    private static func utcTime(_ date: Date) -> [UInt8]? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, (1950...2049).contains(year),
              let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let second = c.second
        else { return nil }
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let text = two(year % 100) + two(month) + two(day) + two(hour) + two(minute) + two(second) + "Z"
        return tlv(0x17, [UInt8](text.utf8))
    }

    // MARK: object identifiers (pre-encoded)

    private static let oidEcPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]       // 1.2.840.10045.2.1
    private static let oidPrime256v1: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]  // 1.2.840.10045.3.1.7
    private static let oidEcdsaWithSHA256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
    private static let oidCommonName: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]                                  // 2.5.4.3
    private static let oidBasicConstraints: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x13]                            // 2.5.29.19
    private static let oidKeyUsage: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x0F]                                    // 2.5.29.15
    private static let oidExtKeyUsage: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x25]                                 // 2.5.29.37
    private static let oidSubjectAltName: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x11]                              // 2.5.29.17
    private static let oidServerAuth: [UInt8] = [0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]   // 1.3.6.1.5.5.7.3.1
}
