import Foundation
import NachoComboCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// nacho-pet-cli: headless client on the same PetSession as the app (dev/test only; used by scripts/pet-roundtrip.sh
// against tools/mock-server). It never talks to production: --server must be a loopback URL.
//
//   nacho-pet-cli login     --server http://127.0.0.1:8791 --store DIR
//   nacho-pet-cli chat      --server … --store DIR "안녕 나초"
//   nacho-pet-cli ask-image --server … --store DIR capture.png "이거 뭐야?"     (Capture Float → pet)
//   nacho-pet-cli send-file --server … --store DIR notes.md "요약해 줘"        (File Shelf → pet)
//   nacho-pet-cli command   --server … --store DIR "창 왼쪽으로 붙여 줘"       (connector: window / gadget)
//   nacho-pet-cli stop      --server … --store DIR "/long"
//   nacho-pet-cli logout    --server … --store DIR
// Secrets go to 0600 files in DIR (0700); they are never printed.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

func stamp(_ s: String) {
    print("[\(ISO8601DateFormatter().string(from: Date()))] \(s)")
    fflush(stdout)
}

/// 0600 files named by the SHA-256 of the key, in a 0700 directory.
final class FileSecretStore: PetSecretStore {
    let dir: URL
    init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    private func file(_ key: String) -> URL {
        dir.appendingPathComponent(SHA256.hash(Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    func read(_ key: String) -> Data? { try? Data(contentsOf: file(key)) }
    func write(_ key: String, _ value: Data) throws {
        let f = file(key)
        FileManager.default.createFile(atPath: f.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try value.write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
    }
    func delete(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
}

/// The browser step without a browser: GET the login page and read the redirect (the mock login page approves at
/// once). Redirects are not followed, so the custom-scheme callback is only read.
final class HTTPBrowser: PetAuthBrowser {
    let http: PetHTTPClient
    init(http: PetHTTPClient) { self.http = http }
    func authorize(url: URL, callbackScheme: String, completion: @escaping (Result<URL, AuthProblem>) -> Void) {
        stamp("browser GET \(url.path) (client_id, redirect_uri, code_challenge S256, state)")
        http.send(PetHTTPRequest(method: "GET", url: url)) { r in
            guard case let .success(resp) = r, resp.status == 302, let loc = resp.header("Location"), let cb = URL(string: loc),
                  cb.scheme == callbackScheme
            else {
                if case let .success(resp) = r { stamp("browser: login page answered HTTP \(resp.status)") }
                completion(.failure(.network))
                return
            }
            stamp("browser redirected to \(cb.scheme ?? "")://\(cb.host ?? "")\(cb.path) (code + state)")
            completion(.success(cb))
        }
    }
}

/// Plays the Mac: keeps gadget switches in memory and "moves" a window. Prints what Nacho asked for.
final class SimulatedMac: PetCommandExecuting {
    var on: Set<ModuleID> = [.nachoPet]
    func execute(_ command: PetCommand, done: @escaping (PetCommandOutcome) -> Void) {
        switch command {
        case let .arrangeWindow(action, app):
            stamp("mac: arrange window \(action.rawValue) app=\(app ?? "front")")
            done(PetCommandOutcome(ok: true, message: "Moved the front window to \(action.displayName)."))
        case let .setGadget(id, value):
            if value { on.insert(id) } else { on.remove(id) }
            stamp("mac: gadget \(id.rawValue) -> \(value ? "on" : "off")")
            done(PetCommandOutcome(ok: true, message: "\(id.displayName) is now \(value ? "on" : "off")."))
        case .listGadgets:
            stamp("mac: list gadgets")
            var g: [String: String] = [:]
            for id in ModuleID.allCases { g[id.rawValue] = on.contains(id) ? "on" : "off" }
            done(PetCommandOutcome(ok: true, message: "\(on.count) gadgets on.", gadgets: g))
        }
    }
}

func makeTransport() -> WebSocketTransport {
    #if os(Linux)
    return SocketTransport()
    #else
    return URLSessionTransport()
    #endif
}

// MARK: arguments

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: nacho-pet-cli login|chat|ask-image|send-file|command|stop|logout|history|recover|task|remember|search|dictate|usage --server URL --store DIR …") }
args.removeFirst()
var server = ""
var storeDir = ""
var rest: [String] = []
var i = 0
while i < args.count {
    switch args[i] {
    case "--server" where i + 1 < args.count: server = args[i + 1]; i += 2
    case "--store" where i + 1 < args.count: storeDir = args[i + 1]; i += 2
    default: rest.append(args[i]); i += 1
    }
}
guard case let .success(endpoint) = ServerEndpoint.parse(server), let host = endpoint.base.host, ServerEndpoint.isLoopback(host) else {
    fail("--server must be a loopback http(s) URL (dev CLI; production is the app's job)")
}
guard !storeDir.isEmpty else { fail("--store DIR is required") }

var settings = PetSettings()
settings.serverMode = .custom
settings.customServerURL = endpoint.base.absoluteString
settings.customIssuerURL = endpoint.base.absoluteString + "/realms/nachotown"
guard settings.validationProblem() == nil else { fail(settings.validationProblem()!) }

let http = URLSessionPetHTTP()
let secrets: FileSecretStore
do { secrets = try FileSecretStore(dir: URL(fileURLWithPath: storeDir)) } catch { fail("store: \(error)") }
let browser = HTTPBrowser(http: http)
let mac = SimulatedMac()
if command != "command" { settings.allowComboControl = false }
let session = PetSession(settings: settings, http: http, secrets: secrets, browser: browser, makeTransport: makeTransport,
                         executor: mac)
let finished = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

func finish(_ code: Int32) {
    exitCode = code
    finished.signal()
}

// MARK: commands

switch command {
case "login":
    session.onChange = { st in
        switch st.auth {
        case .signedIn:
            session.onChange = nil
            stamp("auth signedIn (tokens stored, 0600)")
            // Same check the server lane uses: a signed-in token reads /api/v1/me.
            session.withAccessToken { tok in
                http.send(.get(endpoint.rest("/api/v1/me"), bearer: tok)) { r in
                    let status = (try? r.get())?.status ?? 0
                    stamp("GET /api/v1/me -> \(status)")
                    finish(status == 200 ? 0 : 1)
                }
            }
        case let .failed(m): stamp("auth failed: \(m)"); finish(1)
        default: break
        }
    }
    session.signIn()

case "logout":
    guard session.snapshot.auth == .signedIn else { stamp("not signed in"); exit(1) }
    session.signOut()
    session.flush()
    Thread.sleep(forTimeInterval: 0.5)
    stamp("auth \(session.snapshot.auth) notice=\(session.snapshot.notice ?? "-")")
    exit(session.snapshot.auth == .signedOut ? 0 : 1)

case "chat", "ask-image", "send-file", "command", "stop":
    var text = rest.joined(separator: " ")
    if command == "ask-image" || command == "send-file" {
        guard let path = rest.first else { fail("file path missing") }
        text = rest.dropFirst().joined(separator: " ")
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
        switch PetMedia.prepare(name: path, data: data) {
        case let .failure(p): stamp("refused file: \(p.koreanMessage)"); exit(1)
        case let .success(file):
            stamp("attach \(file.name) mime=\(file.mime) bytes=\(file.data.count) note=\(file.readability.koreanNote)")
            if let refusal = session.attach(file) { stamp("refused: \(refusal)"); exit(1) }
        }
    }
    guard session.snapshot.auth == .signedIn else { stamp("not signed in (run login first)"); exit(1) }
    var sent = false, stopped = false, printed = 0, lastPhase = ""
    var lastConnector = ""
    session.onChange = { st in
        let phase = "\(st.chat.phase)"
        if phase != lastPhase { lastPhase = phase; stamp("phase \(phase)") }
        let conn = "\(st.connector)"
        if conn != lastConnector { lastConnector = conn; stamp("connector \(conn)") }
        if st.auth != .signedIn { stamp("auth \(st.auth) \(st.notice ?? "")"); finish(1); return }
        let readyToSend = st.chat.phase == .connected && (command != "command" || st.connector == .ready)
        if readyToSend && !sent {
            sent = true
            DispatchQueue.global().async {
                session.send(text: text) { refusal in
                    if let r = refusal { stamp("refused: \(r)"); finish(1) } else { stamp("sent text=\(text) attachments=\(st.pending.count)") }
                }
            }
        }
        if st.uploading { stamp("uploading \(st.pending.count) file(s)") }
        guard sent, let t = st.chat.turns.last else { return }
        if t.assistantText.count > printed {
            let start = t.assistantText.index(t.assistantText.startIndex, offsetBy: printed)
            stamp("delta \(String(t.assistantText[start...]).debugDescription)")
            printed = t.assistantText.count
        }
        if st.chat.activity == .tool, let tool = st.chat.activeTool { stamp("activity tool \(tool)") }
        if command == "stop", !stopped, printed >= 24 {
            stopped = true
            stamp("stop requested")
            session.stop()
        }
        switch t.status {
        case .done: stamp("done text=\(t.assistantText.debugDescription) attachments=\(t.attachmentNames)"); finish(0)
        case .stopped: stamp("stopped partial=\(t.assistantText.debugDescription)"); finish(0)
        case let .failed(m): stamp("failed: \(m)"); finish(1)
        case .interrupted: stamp("interrupted"); finish(1)
        default: break
        }
    }
    session.open()

case "history", "usage", "dictate":
    guard session.snapshot.auth == .signedIn else { stamp("not signed in (run login first)"); exit(1) }
    var askedOlder = false, dictated = false
    session.onChange = { st in
        guard st.chat.phase == .connected, st.config != nil else { return }
        switch command {
        case "usage":
            guard let u = st.chat.usage else { return }
            session.onChange = nil
            stamp("config dictation=\(st.config!.dictationEnabled) max_sec=\(st.config!.dictationMaxSec) media_max=\(st.config!.mediaMaxBytes) service=\(st.config!.serviceState)")
            stamp("usage \(u.summary)")
            finish(0)
        case "dictate":
            guard !dictated else { return }
            dictated = true
            guard rest.count >= 2, let audio = FileManager.default.contents(atPath: rest[0]) else { fail("dictate <file> <mime>") }
            session.dictate(audio: audio, mime: rest[1], fileName: URL(fileURLWithPath: rest[0]).lastPathComponent, durationSec: 2.0) { r in
                switch r {
                case let .success(t): stamp("dictation text=\(t.debugDescription)"); finish(0)
                case let .failure(e): stamp("dictation refused code=\(e.code ?? "-") status=\(e.status) text=\(e.text)"); finish(2)
                }
            }
        default:  // history
            guard st.chat.historyLoaded, !st.loadingHistory else { return }
            if !askedOlder {
                askedOlder = true
                for m in st.chat.history { stamp("history seq=\(m.seq ?? -1) role=\(m.role) type=\(m.contentType) text=\(m.text.debugDescription)") }
                stamp("history count=\(st.chat.history.count) more=\(st.chat.hasMoreHistory)")
                if st.chat.hasMoreHistory { session.loadOlderHistory() } else { finish(0) }
                return
            }
            stamp("older count=\(st.chat.history.count) more=\(st.chat.hasMoreHistory) first_seq=\(st.chat.history.first?.seq ?? -1)")
            session.onChange = nil
            finish(0)
        }
    }
    session.open()

case "recover", "task", "remember", "search":
    guard session.snapshot.auth == .signedIn else { stamp("not signed in (run login first)"); exit(1) }
    let text: String
    switch command {
    case "recover": text = "/drop"
    case "task": text = "/task " + (rest.isEmpty ? "내일 저녁 파스타집 예약해 줘" : rest.joined(separator: " "))
    case "remember": text = "/remember " + (rest.isEmpty ? "고양이를 키워요" : rest.joined(separator: " "))
    default: text = "/search " + (rest.isEmpty ? "강남 파스타" : rest.joined(separator: " "))
    }
    var sent = false, answered = false, step = 0, sawInterrupted = false
    var forgetAt: Date?
    session.onChange = { st in
        guard st.chat.phase == .connected else { return }
        if !sent {
            sent = true
            DispatchQueue.global().async {
                session.send(text: text) { refusal in if let r = refusal { stamp("refused: \(r)"); finish(1) } else { stamp("sent \(text)") } }
            }
            return
        }
        guard let t = st.chat.turns.last else { return }
        if t.status == .interrupted, !sawInterrupted { sawInterrupted = true; stamp("interrupted (socket dropped)") }
        switch command {
        case "recover":
            if t.status == .done, sawInterrupted {
                stamp("recovered from delta text=\(t.assistantText.debugDescription) userSeq=\(t.userSeq ?? -1) answerSeq=\(t.answerSeq ?? -1)")
                session.onChange = nil
                finish(0)
            }
        case "search":
            if t.status == .done {
                stamp("tools \(t.tools.map { "\($0.name):\($0.finished ? ($0.isError ? "error" : "ok") : "running")" }.joined(separator: ","))")
                stamp("progress \(t.progress)")
                stamp("done text=\(t.assistantText.debugDescription)")
                session.onChange = nil
                finish(t.tools.isEmpty || t.progress.isEmpty ? 1 : 0)
            }
        case "task":
            if let card = st.chat.pendingCards.first, card.answerableHere, !answered {
                answered = true
                stamp("task \(t.taskID ?? "-") status=\(st.chat.task?.statusText ?? "-") progress=\(t.progress)")
                stamp("card \(card.kind) \(card.title.debugDescription) options=\(card.options.map { $0.label }) -> choose \(card.options[0].label)")
                session.answerCard(id: card.id, action: "choose", optionIDs: [card.options[0].id]) { r in stamp("answer \(r ?? "ok")") }
            }
            if answered, let task = st.chat.task, task.state == "done", !t.assistantText.isEmpty {
                stamp("card now \(st.chat.cards.first?.statusText ?? "-")")
                stamp("task done answer=\(t.assistantText.debugDescription) history=\(st.chat.history.count)")
                session.onChange = nil
                finish(0)
            }
        default:  // remember: memory line → forget → undo (10 s) → feedback on the answer that used it
            guard t.status == .done, let note = st.chat.memoryNotes.first else { return }
            switch step {
            case 0:
                step = 1
                stamp("memory \(note.text) used=\(t.usedMemoryIDs.count)")
                forgetAt = Date()
                session.forgetMemory(updateID: note.updateID)
            case 1 where note.action == "forgotten" && note.forgottenAt != nil:
                step = 2
                stamp("forgotten; undo possible=\(Date().timeIntervalSince(note.forgottenAt!) < PetSession.restoreWindow)")  // onChange runs on the session queue: no queue.sync calls here
                session.undoForget(updateID: note.updateID)
            case 2 where note.action == "created" && note.forgottenAt == nil:
                step = 3
                stamp("restored after \(String(format: "%.1f", Date().timeIntervalSince(forgetAt ?? Date())))s: \(note.text)")
                session.sendMemoryFeedback(turnID: t.clientMsgID, text: "이제 고양이 두 마리예요") { r in
                    stamp("feedback \(r ?? "ok")")
                    session.onChange = nil
                    finish(r == nil ? 0 : 1)
                }
            default: break
            }
        }
    }
    session.open()

default:
    fail("unknown command \(command)")
}

if finished.wait(timeout: .now() + 30) == .timedOut { stamp("timeout"); exitCode = 1 }
if command == "command" { stamp("commands handled: \(session.handledCommands.joined(separator: ", "))") }
session.shutdown()
exit(exitCode)
