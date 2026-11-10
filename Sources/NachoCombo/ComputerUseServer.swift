import Foundation
import Network
import Security
import NachoComboCore

/// The socket layer of the MCP endpoint (Network.framework). It only reads bytes, hands complete requests to the
/// Core `ComputerUseService` and writes the answer back. All policy (keys, switches, limits) lives in the Core.
///
/// - `.localOnly` (default): listens on a loopback address only, plain HTTP. Any non-loopback peer is dropped.
/// - `.lan`: listens on every interface, **TLS only** (self-signed identity, clients pin its fingerprint). A peer whose
///   address is not private (`ComputerUseNetworkPolicy.isPrivateAddress`) is dropped before the TLS handshake starts.
///   The remote IP is passed to the service as the client id, so failed-key lockouts and rate limits are per client.
/// - One request per connection (`Connection: close`), at most `maxConnections` at once (and `maxConnectionsPerClient`
///   per remote address), header/body size caps in the parser.
/// - `stop()` cancels the listener and every open connection: after it returns the port is closed.
final class ComputerUseServer {
    private static let maxConnections = 16
    private static let maxConnectionsPerClient = 4
    private static let requestTimeout: TimeInterval = 15

    private let service: ComputerUseService
    private let queue = DispatchQueue(label: "com.mafianacho.nachocombo.computeruse.net")
    private let toolQueue = DispatchQueue(label: "com.mafianacho.nachocombo.computeruse.tools")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (connection: NWConnection, client: String)] = [:]
    private var mode: ComputerUseListenMode = .localOnly
    private(set) var boundPort: Int?
    private(set) var isAdvertising = false

    init(service: ComputerUseService) { self.service = service }

    var connectionCount: Int { queue.sync { connections.count } }

    /// Starts listening and waits (up to 3 s) until the listener is ready. Returns nil on success, or a message.
    /// - `tls` is required for `.lan`; without it nothing is opened (no plain-HTTP fallback).
    /// - `advertise` publishes a Bonjour service in LAN mode only.
    func start(mode: ComputerUseListenMode, address: String, port: Int, tls: ComputerUseTLSIdentity?,
               advertise: Bool = false, serviceName: String = "Nacho Combo") -> String? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return "Invalid port" }
        let parameters: NWParameters
        switch mode {
        case .localOnly:
            guard ComputerUseSettings.isLoopback(address) else { return "Only loopback addresses are allowed" }
            parameters = NWParameters.tcp
            let host: NWEndpoint.Host = address == "::1" ? .ipv6(.loopback) : .ipv4(.loopback)
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: nwPort)
        case .lan:
            guard let tls = tls else { return "LAN mode never opens without a TLS certificate" }
            guard let secIdentity = sec_identity_create(tls.identity) else { return "Could not load the TLS certificate" }
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
            // No requiredLocalEndpoint: every interface. Cellular is never a LAN.
            parameters.prohibitedInterfaceTypes = [.cellular]
        }
        parameters.allowLocalEndpointReuse = true

        let created: NWListener
        do { created = try NWListener(using: parameters, on: nwPort) } catch { return "Could not create the server: \(error)" }
        let advertising = mode == .lan && advertise
        if advertising {
            created.service = NWListener.Service(name: serviceName, type: ComputerUseLAN.bonjourType)
        }

        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        var finished = false
        created.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !finished { finished = true; ready.signal() }
            case .failed(let error):
                if !finished { failure = "Cannot open port \(port): \(error)"; finished = true; ready.signal() }
                self?.queue.async { self?.stopLocked() }
            default: break
            }
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.mode = mode }
        created.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut {
            created.cancel()
            return "Opening port \(port) is taking too long"
        }
        if let failure = failure { created.cancel(); return failure }
        queue.sync { listener = created; boundPort = port; isAdvertising = advertising }
        return nil
    }

    func stop() { queue.sync { stopLocked() } }

    private func stopLocked() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        isAdvertising = false
        for (_, entry) in connections { entry.connection.cancel() }
        connections.removeAll()
    }

    // MARK: connections (all on `queue`)

    /// The remote IP as text in the Core's canonical spelling (IPv6 zone `%en0` removed, IPv4-mapped IPv6 turned back
    /// into IPv4, brackets/case unified), so one computer is one client id. nil when the peer is not an IP endpoint
    /// (then the connection is dropped).
    static func remoteAddress(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return ComputerUseNetworkPolicy.normalizeClientID("\(address)")
        case .ipv6(let address): return ComputerUseNetworkPolicy.normalizeClientID("\(address)")
        default: return nil
        }
    }

    /// Second line of defence next to the service's own check (`isRemoteAddressAllowed`, answered with 403 before any
    /// key check): a peer that does not belong to the selected mode never gets a TLS handshake or a read.
    private func isAllowedPeer(_ address: String) -> Bool {
        switch mode {
        case .localOnly: return ComputerUseNetworkPolicy.isLoopbackAddress(address)
        case .lan: return ComputerUseNetworkPolicy.isPrivateAddress(address)
        }
    }

    private func accept(_ connection: NWConnection) {
        // Decided before the handshake: nothing is read from, or sent to, a peer that is not allowed.
        guard let client = ComputerUseServer.remoteAddress(connection.endpoint), isAllowedPeer(client),
              connections.count < ComputerUseServer.maxConnections,
              connections.values.filter({ $0.client == client }).count < ComputerUseServer.maxConnectionsPerClient else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = (connection, client)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.connections[key] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        // A client that never finishes its handshake or request does not hold a slot forever.
        let received = ReceivedFlag()
        queue.asyncAfter(deadline: .now() + ComputerUseServer.requestTimeout) { [weak connection] in
            if !received.value { connection?.cancel() }
        }
        receive(connection, client: client, buffer: Data(), received: received)
    }

    private final class ReceivedFlag { var value = false }

    private func receive(_ connection: NWConnection, client: String, buffer: Data, received: ReceivedFlag) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if error != nil { connection.cancel(); return }
            switch HTTPParser.parse(buffer) {
            case .needMore:
                if isComplete { connection.cancel() } else { self.receive(connection, client: client, buffer: buffer, received: received) }
            case .invalid(let response):
                received.value = true
                self.send(response, on: connection)
            case .request(let request, _):
                received.value = true
                // Tools can take seconds (screenshots, shell): never block the network queue.
                self.toolQueue.async {
                    let response = self.service.handle(request, clientID: client)
                    self.queue.async { self.send(response, on: connection) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
