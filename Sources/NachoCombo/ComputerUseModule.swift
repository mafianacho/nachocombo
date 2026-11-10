import AppKit
import ApplicationServices
import CoreGraphics
import NachoComboCore

/// Computer Use (module 7): an MCP server through which a client holding an API key can look at and control this Mac.
/// By default it listens on loopback only; the LAN mode (settings switch, TLS with a pinned self-signed certificate,
/// private peers only) lets other computers on the same local network connect. OFF contract: `stop()` closes the port,
/// drops every connection, releases the emergency hotkey and the sleep guard and
/// stops a running shell command. Starting it asks the OS only for the permissions of the tool groups that are
/// switched on; if one is missing nothing is registered and the state says which one (no workaround).
///
/// Not run on a Mac yet - see docs/COMPUTER-USE-MCP.md for what is unverified.
final class ComputerUseModule: NSObject, FeatureModule, PermissionPrompting {
    var allowPermissionPrompt = false
    let id = ModuleID.computerUse
    static let emergencyLabel = "⌃⌥⌘."
    private static let emergencyKeyCode: UInt32 = 47      // "."

    let keys = APIKeyStore(url: APIKeyStore.defaultURL())
    let callLog = CallLog()
    /// Latest saved settings; read on the main thread when the module (re)starts.
    var currentSettings: () -> ComputerUseSettings = { ComputerUseSettings() }
    /// The emergency hotkey fired: the owner turns the module OFF (persisted).
    var onEmergencyStop: (() -> Void)?
    /// A call was logged: the owner may refresh its views.
    var onActivity: (() -> Void)?

    private let backend = MacComputerUseBackend()
    private let hotKeys = HotKeyCenter(signature: 0x4E43_4355)      // 'NCCU'
    private var service: ComputerUseService?
    private var server: ComputerUseServer?
    private let snapshotLock = NSLock()
    private var snapshot = ComputerUseSettings()
    private var promptedSinceEnabled = Set<OSPermission>()
    private let sleepGuard = SleepGuard()
    private(set) var endpoint = "-"
    /// Mode of the running server (nil while stopped) and, in LAN mode, the TLS certificate that clients pin.
    private(set) var activeMode: ComputerUseListenMode?
    private(set) var tlsIdentity: ComputerUseTLSIdentity?

    var isRunning: Bool { server != nil }

    override init() {
        super.init()
        callLog.onEntry = { [weak self] _ in DispatchQueue.main.async { self?.onActivity?() } }
    }

    private func settingsSnapshot() -> ComputerUseSettings {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }

    // MARK: permissions

    static func hasPermission(_ permission: OSPermission) -> Bool {
        switch permission {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        // Apple Events permission is asked by macOS per target app on first use and cannot be pre-checked.
        case .automation: return true
        }
    }

    private static func request(_ permission: OSPermission) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .automation:
            break
        }
    }

    static func permissionMessage(_ missing: [OSPermission]) -> String {
        let names = missing.map { $0.displayName }.joined(separator: ", ")
        return "Permissions needed by the enabled tool groups are missing: \(names). Allow Nacho Combo in System Settings ▸ Privacy & Security, then click “Check Permissions Again”. The server will not open until they are allowed."
    }

    /// Permissions that the switched-on tool groups need and the system has not granted.
    var missingPermissions: [OSPermission] {
        currentSettings().requiredPermissions.filter { !ComputerUseModule.hasPermission($0) }
    }

    // MARK: FeatureModule

    /// Idempotent: every call first tears everything down and then rebuilds from the saved settings.
    func start() -> ModuleState {
        tearDown()
        let config = currentSettings()
        snapshotLock.lock(); snapshot = config; snapshotLock.unlock()

        var missing: [OSPermission] = []
        for permission in config.requiredPermissions where !ComputerUseModule.hasPermission(permission) {
            missing.append(permission)
            if allowPermissionPrompt && !promptedSinceEnabled.contains(permission) {
                promptedSinceEnabled.insert(permission)       // once per ON switch; re-checks never prompt again
                ComputerUseModule.request(permission)
            }
        }
        if !missing.isEmpty { return .needsPermission(ComputerUseModule.permissionMessage(missing)) }

        // LAN mode needs its TLS identity first. If it cannot be loaded or created nothing is opened: no plain HTTP.
        var identity: ComputerUseTLSIdentity?
        if config.listenMode == .lan {
            let loaded = ComputerUseTLS.loadOrCreate()
            guard let found = loaded.identity else {
                return .failed(loaded.problem ?? "Could not prepare the TLS certificate for LAN mode. LAN mode never opens without encryption.")
            }
            identity = found
        }

        let registered = hotKeys.register(id: 1, keyCode: ComputerUseModule.emergencyKeyCode,
                                          modifiers: ToolShortcut.control | ToolShortcut.option | ToolShortcut.command) { [weak self] in
            self?.emergencyStop()
        }
        guard registered else {
            hotKeys.unregisterAll()
            return .failed("Could not register the emergency stop shortcut \(ComputerUseModule.emergencyLabel) (it may conflict with another app). The server will not open without an emergency stop.")
        }

        let newService = ComputerUseService(settings: { [weak self] in self?.settingsSnapshot() ?? ComputerUseSettings() },
                                            keys: keys, backend: backend, callLog: callLog)
        let newServer = ComputerUseServer(service: newService)
        if let problem = newServer.start(mode: config.listenMode, address: config.bindAddress, port: config.port, tls: identity,
                                         advertise: ComputerUseLANPrefs.advertiseBonjour, serviceName: ComputerUseLAN.bonjourName) {
            newService.stop()
            hotKeys.unregisterAll()
            return .failed(problem)
        }
        service = newService
        server = newServer
        activeMode = config.listenMode
        tlsIdentity = identity
        endpoint = ComputerUseLAN.urls(mode: config.listenMode, bindAddress: config.bindAddress, port: config.port).first ?? "-"
        if ComputerUseLANPrefs.preventSleep { sleepGuard.begin(reason: "Keeps the system awake while the Nacho Combo Computer Use server is on") }
        return .running
    }

    func stop() {
        tearDown()
        promptedSinceEnabled.removeAll()
    }

    private func tearDown() {
        hotKeys.unregisterAll()
        service?.stop()
        server?.stop()
        backend.shutdown()
        sleepGuard.end()
        service = nil
        server = nil
        activeMode = nil
        tlsIdentity = nil
        endpoint = "-"
    }

    /// Refuses every further tool call at once and tells the owner to switch the module OFF.
    func emergencyStop() {
        service?.emergencyStop()
        backend.shutdown()
        DispatchQueue.main.async { [weak self] in self?.onEmergencyStop?() }
    }

    var diagnostics: [String: String] {
        var values = service?.diagnostics ?? ["accepting": "false"]
        values["endpoint"] = endpoint
        values["connections"] = "\(server?.connectionCount ?? 0)"
        values["listenMode"] = activeMode.map { "\($0)" } ?? "stopped"
        values["tlsFingerprint"] = tlsIdentity?.fingerprint ?? "-"
        values["sleepGuard"] = "\(sleepGuard.isActive)"
        values["bonjour"] = "\(server?.isAdvertising ?? false)"
        values["emergencyHotkeys"] = "\(hotKeys.registeredCount)"
        values["enabledGroups"] = settingsSnapshot().enabledToolGroups.map { $0.rawValue }.joined(separator: ",")
        return values
    }
}
