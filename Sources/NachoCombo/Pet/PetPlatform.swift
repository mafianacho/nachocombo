import AppKit
import AuthenticationServices
import AVFoundation
import NachoComboCore
import Security
import Speech

// macOS pieces of Nacho Pet that the Core cannot have: the Keychain, the system browser sheet for login and
// dictation. Ported from nacho-gadget-app (PR #1 @1d685fa) DictationController; the Keychain store and the login
// sheet are new (the gadget app had no login yet).

/// Pet secrets (tokens, connector binding) in the login Keychain, this Mac only, readable after first unlock.
final class KeychainSecretStore: PetSecretStore {
    static let service = "com.mafianacho.nachocombo.pet"

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainSecretStore.service,
         kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func write(_ key: String, _ value: Data) throws {
        let attrs: [String: Any] = [kSecValueData as String: value,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            for (k, v) in attrs { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

/// Keycloak login in the system's web authentication sheet (shares the browser's session, so a signed-in user just
/// confirms). The custom-scheme callback is caught by the sheet itself: no URL scheme is registered for the app.
final class PetWebLogin: NSObject, PetAuthBrowser, ASWebAuthenticationPresentationContextProviding {
    var anchor: () -> NSWindow? = { nil }
    private var session: ASWebAuthenticationSession?

    func authorize(url: URL, callbackScheme: String, completion: @escaping (Result<URL, AuthProblem>) -> Void) {
        DispatchQueue.main.async {
            self.session?.cancel()
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                self?.session = nil
                if let callback = callback {
                    completion(.success(callback))
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    completion(.failure(.canceled))
                } else {
                    completion(.failure(.network))
                }
            }
            s.presentationContextProvider = self
            self.session = s
            NSApp.activate(ignoringOtherApps: true)
            if !s.start() {
                self.session = nil
                completion(.failure(.network))
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor() ?? NSApp.keyWindow ?? NSWindow()
    }
}

enum PetDictationEvent {
    case permissionGranted
    case denied(DictationDenial)
    case unavailable(String)
    case hypothesis(String, Bool)
    case ended
}

/// macOS speech recognition (SFSpeechRecognizer, ko-KR) fed by the default microphone, only while the mic button is
/// on. Text only: the app never stores audio. Recognition may run on Apple's servers when ko-KR is not on-device.
final class PetDictationController {
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    /// `handler` is called on the main thread.
    func start(handler: @escaping (PetDictationEvent) -> Void) {
        stop()
        generation += 1
        let gen = generation
        let main: (PetDictationEvent) -> Void = { e in DispatchQueue.main.async { handler(e) } }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                guard status == .authorized else { main(.denied(.speech)); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        guard granted else { main(.denied(.microphone)); return }
                        self.begin(generation: gen, handler: main)
                    }
                }
            }
        }
    }

    private func begin(generation gen: Int, handler: @escaping (PetDictationEvent) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")), recognizer.isAvailable else {
            handler(.unavailable("한국어 음성 인식을 지금 사용할 수 없어요. (네트워크 또는 시스템 설정 확인)"))
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            handler(.unavailable("사용할 수 있는 마이크를 찾지 못했어요."))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            handler(.unavailable("마이크를 시작하지 못했어요."))
            return
        }
        self.recognizer = recognizer
        self.engine = engine
        self.request = request
        handler(.permissionGranted)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                if let result = result { handler(.hypothesis(result.bestTranscription.formattedString, result.isFinal)) }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardown()
                    handler(.ended)
                }
            }
        }
    }

    func stop() {
        generation += 1
        teardown()
    }

    private func teardown() {
        if let e = engine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        recognizer = nil
    }
}

/// The Nacho character art bundled in Contents/Resources/Nacho (all rights reserved, see Resources/Nacho/LICENSE).
enum PetArt {
    private static var cache: [String: NSImage] = [:]

    static func image(_ face: PetFace) -> NSImage? { image(named: face.assetName) }

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Nacho/\(name).png"),
                          // `swift run` during development: the repository's copy.
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Nacho/\(name).png")]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) {
                cache[name] = image
                return image
            }
        }
        return nil
    }
}
