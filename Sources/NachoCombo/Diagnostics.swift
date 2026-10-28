import Foundation
import NachoComboCore
import Security

/// Writes a JSON snapshot of module state. Used to verify the ON/OFF contract
/// (timers, hotkeys and status items really are released) from outside the app.
enum Diagnostics {
    static var url: URL {
        SettingsStore.defaultURL().deletingLastPathComponent().appendingPathComponent("state.json")
    }

    static func write(manager: ModuleManager, extra: [String: Any] = [:]) {
        var modules: [String: Any] = [:]
        for id in ModuleID.allCases {
            let state = manager.states[id] ?? .off
            var entry: [String: Any] = [
                "enabled": manager.settings.isEnabled(id),
                "state": "\(state.label)",
            ]
            switch state {
            case .needsPermission(let m), .failed(let m): entry["message"] = m
            default: break
            }
            entry["detail"] = manager.module(id)?.diagnostics ?? [:]
            modules[id.rawValue] = entry
        }
        let root: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "written": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "modules": modules,
            "ui": extra,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// This copy's code signature hash (cdhash). The app is ad-hoc signed, so every build has a new one; macOS ties a
/// privacy permission to it, which is why an update needs the permission again.
enum CodeSignature {
    static let current: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let s = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }()
}
