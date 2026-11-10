import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).

#if os(Linux)
import Glibc

/// Plain-TCP WebSocket client for Linux (dev/CI round trips against the mock server only: ws:// on loopback, no TLS).
/// The shipped macOS app uses URLSessionTransport instead.
public final class SocketTransport: WebSocketTransport {
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closedByCaller = false
    private var reported = false
    private var handler: ((TransportEvent) -> Void)?

    public init() {}

    public func connect(url: URL, bearer: String?, handler: @escaping (TransportEvent) -> Void) {
        self.handler = handler
        let t = Thread { [weak self] in self?.run(url: url, bearer: bearer) }
        t.start()
    }

    public func send(_ text: String) {
        writeAll(WSEncoder.text(text, maskKey: SocketTransport.randomMask()))
    }

    public func close() {
        stateLock.lock(); closedByCaller = true; reported = true; stateLock.unlock()
        let f = fd
        if f >= 0 {
            writeAll(WSEncoder.close(maskKey: SocketTransport.randomMask()))
            shutdown(f, Int32(SHUT_RDWR))
        }
    }

    private static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }

    private func report(_ ev: TransportEvent) {
        stateLock.lock()
        if case .closed = ev {
            if reported { stateLock.unlock(); return }
            reported = true
        } else if closedByCaller {
            stateLock.unlock(); return
        }
        stateLock.unlock()
        handler?(ev)
    }

    private func writeAll(_ data: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n <= 0 { return }
            sent += n
        }
    }

    private func run(url: URL, bearer: String?) {
        guard url.scheme == "ws", let host = url.host, SocketTransport.isLoopback(host) else {
            report(.closed(TransportFailure(message: "SocketTransport는 loopback ws:// 만 지원해요 (개발·CI 전용)")))
            return
        }
        let port = url.port ?? 80
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            report(.closed(TransportFailure(message: "주소를 찾지 못했어요")))
            return
        }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        var s: Int32 = -1
        while let ai = p {
            let c = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if c >= 0 {
                if Glibc.connect(c, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { s = c; break }
                Glibc.close(c)
            }
            p = ai.pointee.ai_next
        }
        guard s >= 0 else {
            report(.closed(TransportFailure(message: "서버에 연결하지 못했어요")))
            return
        }
        fd = s
        defer { Glibc.close(s) }

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var req = "GET \(url.path.isEmpty ? "/" : url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        req += "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        if let b = bearer, !b.isEmpty, !b.contains("\r"), !b.contains("\n") { req += "Authorization: Bearer \(b)\r\n" }
        req += "\r\n"
        writeAll(Data(req.utf8))

        var head = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        var extra = Data()
        while true {
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { report(.closed(TransportFailure(message: "연결이 끊겼어요"))); return }
            head.append(contentsOf: buf[0..<n])
            if let r = head.range(of: Data("\r\n\r\n".utf8)) {
                extra = head.subdata(in: r.upperBound..<head.count)
                head = head.subdata(in: 0..<r.lowerBound)
                break
            }
            if head.count > 16384 { report(.closed(TransportFailure(message: "응답 헤더가 너무 커요"))); return }
        }
        let status = String(decoding: head, as: UTF8.self).split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) }
        guard status == 101 else {
            report(.closed(TransportFailure(httpStatus: status, message: "HTTP \(status ?? 0)")))
            return
        }
        report(.opened)
        var decoder = WSDecoder()
        var pending = extra
        while true {
            do {
                for m in try decoder.feed(pending) {
                    switch m {
                    case let .text(t): report(.text(t))
                    case let .ping(d): writeAll(WSEncoder.pong(d, maskKey: SocketTransport.randomMask()))
                    case .close: report(.closed(nil)); return
                    case .pong, .binary: break
                    }
                }
            } catch {
                report(.closed(TransportFailure(message: "프로토콜 오류: \(error)")))
                return
            }
            let n = recv(s, &buf, buf.count, 0)
            if n <= 0 { report(.closed(TransportFailure(message: "연결이 끊겼어요"))); return }
            pending = Data(buf[0..<n])
        }
    }

    static func isLoopback(_ h: String) -> Bool { ServerEndpoint.isLoopback(h) }
}
#endif
