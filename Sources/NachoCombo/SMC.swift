import Foundation
import IOKit
import NachoComboCore

// Mirrors the AppleSMC user-client structs (SMCKeyData_t is 80 bytes). Swift packs fields by size,
// so the 9-byte key-info struct carries explicit padding to keep the C layout.
private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var limit = SMCPLimitData()
    var info = SMCKeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
    var index: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// Read-only System Management Controller access (temperatures, fans, power) through the public
/// IOKit user-client calls. Key names are undocumented, so every read may return nil.
final class SMCConnection {
    private enum Command: UInt8 { case readBytes = 5, keyAtIndex = 8, keyInfo = 9 }
    private static let selector: UInt32 = 2  // kSMCHandleYPCEvent

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private var missing = Set<UInt32>()

    init?() {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, SMCConnection.selector, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> SMCKeyInfo? {
        if let cached = infoCache[key] { return cached }
        if missing.contains(key) { return nil }
        var input = SMCKeyData()
        input.key = key
        input.command = Command.keyInfo.rawValue
        guard let output = call(&input) else { missing.insert(key); return nil }
        infoCache[key] = output.info
        return output.info
    }

    func read(_ name: String) -> Double? {
        let key = SMCDecoder.fourCC(name)
        guard let info = info(key) else { return nil }
        var input = SMCKeyData()
        input.key = key
        input.info.dataSize = info.dataSize
        input.command = Command.readBytes.rawValue
        guard let output = call(&input) else { return nil }
        var raw = output.bytes
        let count = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(count)) }
        return SMCDecoder.decode(type: SMCDecoder.string(fromFourCC: info.dataType), bytes: bytes)
    }

    /// Enumerates every key (≈2,000 on Apple silicon, ~0.5 s): call off the main thread.
    func keys(withPrefix prefix: String) -> [String] {
        guard let total = read("#KEY"), total > 0 else { return [] }
        var result: [String] = []
        for index in 0..<UInt32(total) {
            var input = SMCKeyData()
            input.command = Command.keyAtIndex.rawValue
            input.index = index
            guard let output = call(&input) else { continue }
            let name = SMCDecoder.string(fromFourCC: output.key)
            if name.hasPrefix(prefix) { result.append(name) }
        }
        return result
    }
}
