import AppKit
import ApplicationServices
import CoreGraphics
import NachoComboCore

/// Computer Use (module 7): an MCP server through which a client holding an API key can look at and control this Mac.
/// By default it listens on loopback only; the LAN mode (settings switch, TLS with a pinned self-signed certificate,
/// private peers only) lets other computers on the same local network connect. OFF contract: `stop()` closes the port,
/// drops every connection, releases the emergency hotkey and the sleep guard and
/// stops a running shell command. Starting it asks the OS only for the permissions of the tool groups that are
/// switched on. A group whose permission is missing is left out of this run (its tools are not listed and calls to
/// it are refused); the server opens with the other groups, and stays closed only when every switched-on group is
/// blocked. The owner re-checks the permissions (app activation and a short poll) and restarts the module when one
/// is allowed, so the blocked groups join without a manual step.
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
    /// Permissions that were missing at the last start, and the switched-on groups left out because of them.
    private(set) var lastMissing: [OSPermission] = []
    private(set) var blockedGroups: [ToolGroup] = []
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
        return "Permissions needed by the enabled tool groups are missing: \(names). Every switched-on tool group needs one of them, so the server is not open yet. Allow Nacho Combo in System Settings ▸ Privacy & Security: the server opens by itself within a few seconds (or click “Check Permissions Again”)."
    }

    /// Permissions that the switched-on tool groups need and the system has not granted (asked live, never cached).
    var missingPermissions: [OSPermission] {
        currentSettings().requiredPermissions.filter { !ComputerUseModule.hasPermission($0) }
    }

    /// True when the permissions macOS reports now differ from the ones the last start saw (one was allowed or
    /// taken away), so a restart would change what the server serves.
    var permissionsChangedSinceStart: Bool { missingPermissions != lastMissing }

    /// Clears this app's entry for one permission with tccutil, then asks macOS for it again (the Accessibility
    /// dialog). Returns a problem to show, or nil when tccutil succeeded.
    static func resetPermission(_ permission: OSPermission) -> String? {
        guard let args = PermissionReset.arguments(for: permission, bundleID: Bundle.main.bundleIdentifier) else {
            return "This copy has no usable bundle id, so its permission cannot be reset."
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "Could not run tccutil (\(error.localizedDescription))." }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            return "tccutil could not reset \(permission.displayName) (exit \(task.terminationStatus)). Remove Nacho Combo "
                + "from the list in System Settings with the − button, then add it again with +."
        }
        request(permission)
        return nil
    }

    // MARK: FeatureModule

    /// Idempotent: every call first tears everything down and then rebuilds from the saved settings.
    func start() -> ModuleState {
        tearDown()
        let config = currentSettings()
        snapshotLock.lock(); snapshot = config; snapshotLock.unlock()

        let plan = config.permissionPlan { ComputerUseModule.hasPermission($0) }
        lastMissing = plan.missing
        blockedGroups = plan.blockedGroups
        for permission in plan.missing where allowPermissionPrompt && !promptedSinceEnabled.contains(permission) {
            promptedSinceEnabled.insert(permission)       // once per ON switch; re-checks never prompt again
            ComputerUseModule.request(permission)
        }
        if !plan.canOpen { return .needsPermission(ComputerUseModule.permissionMessage(plan.missing)) }
        // Tools of blocked groups are neither listed nor callable in this run; the saved settings keep them on.
        snapshotLock.lock(); snapshot = plan.servable; snapshotLock.unlock()

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
        lastMissing = []
        blockedGroups = []
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
        values["blockedGroups"] = blockedGroups.map { $0.rawValue }.joined(separator: ",")
        values["accessibilityTrusted"] = "\(AXIsProcessTrusted())"
        values["screenRecordingAllowed"] = "\(CGPreflightScreenCaptureAccess())"
        values["bundlePath"] = Bundle.main.bundleURL.path
        values["bundleID"] = Bundle.main.bundleIdentifier ?? "-"
        values["designatedRequirement"] = CodeSignature.designatedRequirement ?? "-"
        return values
    }
}
