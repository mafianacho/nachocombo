import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).

// RFC 6455 framing, platform independent. Used by SocketTransport (the dev/CI transport); the macOS app itself uses
// URLSessionWebSocketTask (TLS, system proxy), which swift-corelibs-foundation on Linux does not implement.

public enum WSMessage: Equatable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?)
}

public enum WSFramingError: Error, Equatable {
    case maskedServerFrame, frameTooLarge, reservedBits, badOpcode, badUTF8, fragmentedControl
}

public enum WSEncoder {
    /// Client frames are always masked. `maskKey` must be 4 random bytes (injected for deterministic tests).
    public static func clientFrame(opcode: UInt8, payload: Data, maskKey: [UInt8]) -> Data {
        precondition(maskKey.count == 4)
        var out = Data()
        out.append(0x80 | (opcode & 0x0f))
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n < 65536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xff)) }
        }
        out.append(contentsOf: maskKey)
        for (i, b) in payload.enumerated() { out.append(b ^ maskKey[i % 4]) }
        return out
    }

    public static func text(_ s: String, maskKey: [UInt8]) -> Data { clientFrame(opcode: 1, payload: Data(s.utf8), maskKey: maskKey) }
    public static func pong(_ d: Data, maskKey: [UInt8]) -> Data { clientFrame(opcode: 10, payload: d, maskKey: maskKey) }
    public static func close(maskKey: [UInt8]) -> Data {
        clientFrame(opcode: 8, payload: Data([0x03, 0xe8]), maskKey: maskKey)  // 1000 normal closure
    }
}

/// Incremental decoder for server → client frames (unmasked, possibly fragmented, possibly split across reads).
public struct WSDecoder {
    public static let maxPayload = 1_000_000
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8?

    public init() {}

    public mutating func feed(_ chunk: Data) throws -> [WSMessage] {
        buffer.append(chunk)
        var out: [WSMessage] = []
        while let m = try next() { if let m = m { out.append(m) } }
        return out
    }

    /// Returns nil when more bytes are needed; `.some(nil)` for a consumed continuation fragment.
    private mutating func next() throws -> WSMessage?? {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        if b[0] & 0x70 != 0 { throw WSFramingError.reservedBits }
        let opcode = b[0] & 0x0f
        if b[1] & 0x80 != 0 { throw WSFramingError.maskedServerFrame }
        var len = Int(b[1] & 0x7f)
        var off = 2
        if len == 126 {
            guard b.count >= 4 else { return nil }
            len = Int(b[2]) << 8 | Int(b[3]); off = 4
        } else if len == 127 {
            guard b.count >= 10 else { return nil }
            var v: UInt64 = 0
            for i in 2..<10 { v = v << 8 | UInt64(b[i]) }
            if v > UInt64(WSDecoder.maxPayload) { throw WSFramingError.frameTooLarge }
            len = Int(v); off = 10
        }
        if len > WSDecoder.maxPayload { throw WSFramingError.frameTooLarge }
        guard b.count >= off + len else { return nil }
        let payload = Data(b[off..<(off + len)])
        buffer = Data(b[(off + len)...])

        switch opcode {
        case 0x8:
            if !fin { throw WSFramingError.fragmentedControl }
            let code: UInt16? = payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil
            return .some(.close(code: code))
        case 0x9:
            if !fin { throw WSFramingError.fragmentedControl }
            return .some(.ping(payload))
        case 0xA:
            if !fin { throw WSFramingError.fragmentedControl }
            return .some(.pong(payload))
        case 0x1, 0x2, 0x0:
            if opcode != 0 { fragmentOpcode = opcode; fragments = Data() } else if fragmentOpcode == nil { throw WSFramingError.badOpcode }
            fragments.append(payload)
            if fragments.count > WSDecoder.maxPayload { throw WSFramingError.frameTooLarge }
            if !fin { return .some(nil) }
            let op = fragmentOpcode!
            let data = fragments
            fragmentOpcode = nil; fragments = Data()
            if op == 0x1 {
                guard let s = String(data: data, encoding: .utf8) else { throw WSFramingError.badUTF8 }
                return .some(.text(s))
            }
            return .some(.binary(data))
        default:
            throw WSFramingError.badOpcode
        }
    }
}
