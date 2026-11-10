import AppKit
import CoreAudio
import Foundation
import IOKit.ps
import NachoComboCore

// System information and the four high-risk tool groups. Not verified on a Mac yet (see ComputerUseBackend.swift).

/// Runs one child process with a time limit and an output cap. Output is read while the process runs, so a chatty
/// command cannot fill the pipe and hang. Only one command at a time is tracked (the service serialises tool calls).
final class ProcessRunner {
    struct Result {
        var status: Int32
        var output: String
        var timedOut: Bool
        var truncated: Bool
    }

    private let lock = NSLock()
    private var running: Process?

    func terminateRunning() {
        lock.lock(); let process = running; lock.unlock()
        if let process = process, process.isRunning { process.terminate() }
    }

    func run(executable: String, arguments: [String], cwd: String?, timeout: Int, maxBytes: Int) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + extraPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let dataLock = NSLock()
        var collected = Data()
        var truncated = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }   // EOF
            dataLock.lock()
            let room = maxBytes - collected.count
            if room > 0 { collected.append(chunk.prefix(room)) }
            if chunk.count > room { truncated = true }       // keep draining so the child never blocks on a full pipe
            dataLock.unlock()
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        lock.lock(); running = process; lock.unlock()
        defer { lock.lock(); running = nil; lock.unlock() }

        let timedOut = finished.wait(timeout: .now() + .seconds(timeout)) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        usleep(60_000)      // let the read handler deliver the last chunk
        pipe.fileHandleForReading.readabilityHandler = nil
        dataLock.lock()
        let output = String(decoding: collected, as: UTF8.self)
        let wasTruncated = truncated
        dataLock.unlock()
        return Result(status: process.terminationStatus, output: output, timedOut: timedOut, truncated: wasTruncated)
    }
}

extension MacComputerUseBackend {
    // MARK: system info

    func systemInfo() -> ToolResult {
        let info = ProcessInfo.processInfo
        var model = ""
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { model = String(cString: buffer) }
        }
        var fields: [String: JSONValue] = [
            "macOS": .string(info.operatingSystemVersionString),
            "model": .string(model),
            "uptimeSeconds": .int(Int(info.systemUptime)),
            "memoryBytes": .int(Int(clamping: info.physicalMemory)),
            "cpuCores": .int(info.activeProcessorCount),
            "battery": batteryInfo(),
            "brightness": .string("Unsupported (no public API to read it without a permission)"),
        ]
        fields["volume"] = outputVolume().map { JSONValue.double($0) } ?? .string("Unavailable")
        return json(.object(fields))
    }

    private func batteryInfo() -> JSONValue {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] else {
            return .string("None")
        }
        var fields: [String: JSONValue] = [:]
        if let percent = description[kIOPSCurrentCapacityKey] as? Int { fields["percent"] = .int(percent) }
        if let charging = description[kIOPSIsChargingKey] as? Bool { fields["charging"] = .bool(charging) }
        if let state = description[kIOPSPowerSourceStateKey] as? String { fields["powerSource"] = .string(state) }
        return .object(fields)
    }

    /// Output volume 0...1 of the default device when it exposes a volume control; nil otherwise.
    private func outputVolume() -> Double? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                             mScope: kAudioDevicePropertyScopeOutput, mElement: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return Double(volume)
    }

    func processList() -> ToolResult {
        // `comm` is the executable path only; command-line arguments (which may hold secrets) are never listed.
        guard let result = try? shell.run(executable: "/bin/ps", arguments: ["-axo", "pid=,comm="], cwd: nil, timeout: 10, maxBytes: 1_000_000) else {
            return .error("Could not read the process list")
        }
        var items: [JSONValue] = []
        for line in result.output.split(separator: "\n").prefix(2000) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[trimmed.startIndex..<space]) else { continue }
            let path = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            items.append(.object(["pid": .int(pid), "name": .string((path as NSString).lastPathComponent)]))
        }
        return json(.object(["processes": .array(items)]))
    }

    // MARK: high risk

    func runAppleScript(_ args: ToolArguments) throws -> ToolResult {
        let source = try args.string("script")
        guard !source.isEmpty, source.count <= 50_000 else { throw PolicyError("Invalid script length") }
        // NSAppleScript is not thread safe: run it on the main thread.
        return onMain { () -> ToolResult in
            guard let script = NSAppleScript(source: source) else { return .error("Could not create the script") }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo = errorInfo {
                let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                return .error("AppleScript error: \(message)")
            }
            return .text(String((descriptor.stringValue ?? "").prefix(ShellPolicy.maxOutputBytes)))
        }
    }

    func runShell(_ args: ToolArguments) throws -> ToolResult {
        let command = try args.string("command")
        guard !command.isEmpty, command.count <= 20_000 else { throw PolicyError("Invalid command length") }
        let timeout = ShellPolicy.clampTimeout(try args.optionalInt("timeoutSeconds"))
        var cwd: String?
        if let requested = try args.optionalString("cwd") {
            try filePolicy.check(path: requested, write: false)
            let resolved = URL(fileURLWithPath: requested).resolvingSymlinksInPath().path
            try filePolicy.check(path: resolved, write: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PolicyError("Working directory not found")
            }
            cwd = resolved
        }
        let result = try shell.run(executable: "/bin/zsh", arguments: ["-c", command], cwd: cwd, timeout: timeout,
                                   maxBytes: ShellPolicy.maxOutputBytes)
        var text = "exit \(result.status)"
        if result.timedOut { text += " (stopped after exceeding the \(timeout)s time limit)" }
        if result.truncated { text += " (output truncated at \(ShellPolicy.maxOutputBytes) bytes)" }
        text += "\n" + result.output
        return ToolResult(content: [.text(text)], isError: result.timedOut || result.status != 0)
    }

    /// Lexical check first, then again on the real path, so a symlink cannot lead into a protected folder.
    private func checkedPath(_ path: String, write: Bool) throws -> String {
        try filePolicy.check(path: path, write: write)
        let url = URL(fileURLWithPath: path)
        let resolved: String
        if FileManager.default.fileExists(atPath: url.path) {
            resolved = url.resolvingSymlinksInPath().path
        } else {
            // A file that does not exist yet: resolve its folder instead.
            resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        try filePolicy.check(path: resolved, write: write)
        return resolved
    }

    func readFile(_ args: ToolArguments) throws -> ToolResult {
        let path = try checkedPath(try args.string("path"), write: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { throw PolicyError("Not a regular file") }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw PolicyError("Cannot open the file") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: FilePolicy.maxReadBytes + 1)) ?? Data()
        let truncated = data.count > FilePolicy.maxReadBytes
        guard let text = String(data: data.prefix(FilePolicy.maxReadBytes), encoding: .utf8) else {
            throw PolicyError("Not a UTF-8 text file")
        }
        return .text(truncated ? text + "\n…(truncated at \(FilePolicy.maxReadBytes) bytes)" : text)
    }

    func writeFile(_ args: ToolArguments) throws -> ToolResult {
        let path = try checkedPath(try args.string("path"), write: true)
        let content = try args.string("content")
        let append = try args.optionalBool("append") ?? false
        let data = Data(content.utf8)
        guard data.count <= FilePolicy.maxWriteBytes else { throw PolicyError("Content is too large (max \(FilePolicy.maxWriteBytes) bytes)") }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw PolicyError("Cannot write to a folder")
        }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw PolicyError("Parent folder not found") }
        if append, FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return .text("Wrote \(data.count) bytes")
    }

    func killProcess(_ args: ToolArguments) throws -> ToolResult {
        let signal = try ProcessPolicy.validateKill(pid: try args.int("pid"), signal: try args.optionalString("signal"),
                                                    ownPid: Int(ProcessInfo.processInfo.processIdentifier))
        let pid = pid_t(try args.int("pid"))
        guard kill(pid, signal) == 0 else {
            return .error(errno == EPERM ? "Permission denied; could not send the signal" : "Could not send the signal (the process may not exist)")
        }
        return .text("Sent signal \(signal)")
    }
}
