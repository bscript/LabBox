import Foundation
import Network

/// The sandbox's only way out. Lives on the host.
///
/// The guest asks to open "host:port" over a virtio port. For each request
/// the gate checks the policy, resolves the name itself, refuses anything
/// that resolves to a non-public address, dials, and relays bytes. Every
/// request is recorded, allowed or not, and the guest cannot edit the record.
///
/// Frame (shared with guest/agent/net.go): 4-byte length, then 1 byte kind,
/// 4 bytes stream id, data.
public final class NetGate {
    public struct Record: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var allowed: Bool
        public var reason: String?
        public var bytesUp = 0
        public var bytesDown = 0
    }

    private enum Kind: UInt8 {
        case open = 1, openOK = 2, openFail = 3, data = 4, close = 5, eof = 6
    }

    private final class Stream {
        var connection: NWConnection?
        var record: Int
        var established = false
        init(record: Int) { self.record = record }
    }

    public static let maxStreams = 64

    private let policy: NetPolicy
    private let toGuest: FileHandle
    private let fromGuest: FileHandle
    private let queue = DispatchQueue(label: "labbox.net")
    private let writeQueue = DispatchQueue(label: "labbox.net.write")
    private var decoder = FrameDecoder()
    private var streams: [UInt32: Stream] = [:]
    private var log: [Record] = []
    private var broken = false

    /// Called (on the gate's own queue) as each destination is allowed or
    /// refused. For live display only; `records()` is the record.
    public var onDecision: ((_ host: String, _ port: Int, _ allowed: Bool, _ reason: String?) -> Void)?

    public init(policy: NetPolicy, toGuest: FileHandle, fromGuest: FileHandle) {
        self.policy = policy
        self.toGuest = toGuest
        self.fromGuest = fromGuest
    }

    public func start() {
        fromGuest.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(bytes) }
        }
    }

    /// Everything the sandbox tried to reach so far.
    public func records() -> [Record] {
        queue.sync { log }
    }

    // MARK: Guest -> host

    private func consume(_ bytes: Data) {
        guard !broken else { return }
        let frames: [Data]
        do {
            frames = try decoder.feed(bytes)
        } catch {
            // A guest that breaks framing loses its network, nothing more.
            broken = true
            fromGuest.readabilityHandler = nil
            streams.values.forEach { $0.connection?.cancel() }
            streams.removeAll()
            return
        }
        for frame in frames {
            guard frame.count >= 5, let kind = Kind(rawValue: frame[frame.startIndex]) else { continue }
            let b = frame.startIndex
            let id = UInt32(frame[b + 1]) << 24 | UInt32(frame[b + 2]) << 16 | UInt32(frame[b + 3]) << 8 | UInt32(frame[b + 4])
            let data = frame.dropFirst(5)
            switch kind {
            case .open: open(id, target: String(decoding: data, as: UTF8.self))
            case .data: forward(id, Data(data))
            case .close: drop(id)
            case .eof: finishSending(id)
            case .openOK, .openFail: break
            }
        }
    }

    private func open(_ id: UInt32, target: String) {
        guard streams[id] == nil else { return }
        guard let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) else {
            log.append(Record(host: String(target.prefix(253)), port: 0, allowed: false, reason: "malformed request"))
            return send(.openFail, id, "malformed request")
        }
        let host = NetPolicy.normalize(String(target[..<colon]))

        func refuse(_ reason: String) {
            log.append(Record(host: String(host.prefix(253)), port: port, allowed: false, reason: reason))
            onDecision?(String(host.prefix(253)), port, false, reason)
            send(.openFail, id, reason)
        }
        if case let .deny(reason) = policy.decide(host: host, port: port) { return refuse(reason) }
        guard streams.count < Self.maxStreams else { return refuse("too many open connections") }

        log.append(Record(host: host, port: port, allowed: true))
        let stream = Stream(record: log.count - 1)
        streams[id] = stream

        // Resolve here, not in the guest, so the address check below is ours.
        DispatchQueue.global().async { [weak self] in
            let addresses = Self.resolve(host)
            self?.queue.async { self?.connect(id, stream, addresses, port: port) }
        }
    }

    private func connect(_ id: UInt32, _ stream: Stream, _ addresses: [(text: String, isPublic: Bool)], port: Int) {
        guard streams[id] === stream else { return }
        func refuse(_ reason: String) {
            log[stream.record].allowed = false
            log[stream.record].reason = reason
            onDecision?(log[stream.record].host, port, false, reason)
            streams[id] = nil
            send(.openFail, id, reason)
        }
        guard !addresses.isEmpty else { return refuse("name does not resolve") }
        // One private answer poisons the lot: no picking through a mixed reply.
        guard addresses.allSatisfy(\.isPublic), let address = addresses.first,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return refuse("resolves to a private or local address")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let connection = NWConnection(host: NWEndpoint.Host(address.text), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        stream.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.streams[id] === stream else { return }
            switch state {
            case .ready:
                stream.established = true
                self.onDecision?(self.log[stream.record].host, port, true, nil)
                self.send(.openOK, id)
                self.receive(id, stream, connection)
            case let .failed(error), let .waiting(error):
                connection.cancel()
                if stream.established {
                    self.streams[id] = nil
                    self.send(.close, id)
                } else {
                    refuse("could not connect: \(error.localizedDescription)")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func forward(_ id: UInt32, _ data: Data) {
        guard let stream = streams[id], stream.established, let connection = stream.connection else { return }
        log[stream.record].bytesUp += data.count
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// The guest's client stopped sending but still wants the reply.
    private func finishSending(_ id: UInt32) {
        guard let stream = streams[id], stream.established, let connection = stream.connection else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func drop(_ id: UInt32) {
        streams.removeValue(forKey: id)?.connection?.cancel()
    }

    // MARK: Host -> guest

    private func receive(_ id: UInt32, _ stream: Stream, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, finished, error in
            guard let self, self.streams[id] === stream else { return }
            let ended = finished || error != nil
            let close = {
                self.streams[id] = nil
                connection.cancel()
                self.send(.close, id)
            }
            guard let data, !data.isEmpty else {
                if ended { close() }
                return
            }
            self.log[stream.record].bytesDown += data.count
            // Read the next chunk only once this one is written, so a slow
            // guest slows the download instead of filling host memory.
            self.send(.data, id, data) {
                self.queue.async {
                    guard self.streams[id] === stream else { return }
                    if ended { close() } else { self.receive(id, stream, connection) }
                }
            }
        }
    }

    private func send(_ kind: Kind, _ id: UInt32, _ text: String) {
        send(kind, id, Data(text.utf8))
    }

    private func send(_ kind: Kind, _ id: UInt32, _ data: Data = Data(), then: (() -> Void)? = nil) {
        var payload = Data([kind.rawValue, UInt8(id >> 24), UInt8((id >> 16) & 0xff), UInt8((id >> 8) & 0xff), UInt8(id & 0xff)])
        payload.append(data)
        let frame = Frame.encode(payload)
        writeQueue.async { [toGuest] in
            try? toGuest.write(contentsOf: frame)
            then?()
        }
    }

    // MARK: Name lookup

    static func resolve(_ host: String) -> [(text: String, isPublic: Bool)] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }

        var out: [(String, Bool)] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            defer { next = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let isPublic: Bool
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                isPublic = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { NetPolicy.isPublic(ipv4: Array($0)) }
                }
            case AF_INET6:
                isPublic = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    // A scoped address (fe80::1%en0) is never public.
                    $0.pointee.sin6_scope_id == 0
                        && withUnsafeBytes(of: $0.pointee.sin6_addr) { NetPolicy.isPublic(ipv6: Array($0)) }
                }
            default:
                isPublic = false
            }
            out.append((String(cString: text), isPublic))
        }
        return out
    }
}
