import Foundation

// Wire format between host and guest agent: a 4-byte big-endian length, then
// that many bytes of JSON. Must match guest/agent/main.go.
//
// Everything arriving from the guest is untrusted. Sizes are capped and
// anything that does not decode is treated as a broken channel.

public enum GuestProtocol {
    public static let version = 5
    public static let controlPortName = "labbox.control"
    public static let netPortName = "labbox.net"
    public static let maxFrame = 1 << 20
}

public struct GuestRequest: Encodable, Equatable {
    public var id: Int
    public var op: String
    public var argv: [String]?
    public var env: [String: String]?
    public var cwd: String?
    public var timeoutMs: Int?
    public var stdin: Data?
    public var watch: Bool?
    public var live: Bool?

    enum CodingKeys: String, CodingKey {
        case id, op, argv, env, cwd, stdin, watch, live
        case timeoutMs = "timeout_ms"
    }

    public init(id: Int, op: String, argv: [String]? = nil, env: [String: String]? = nil,
                cwd: String? = nil, timeoutMs: Int? = nil, stdin: Data? = nil, watch: Bool? = nil, live: Bool? = nil) {
        self.watch = watch
        self.live = live
        self.id = id
        self.op = op
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.timeoutMs = timeoutMs
        self.stdin = stdin
    }
}

public struct GuestEvent: Decodable, Equatable {
    public var id: Int
    public var event: String
    public var data: Data?
    public var code: Int?
    public var timedOut: Bool?
    public var error: String?
    public var version: Int?
    public var created: Bool?
    public var bytes: Int?
    public var trace: GuestTrace?
    public var kernel: String?
    public var files: Int?
    public var decoys: Int?
    public var what: String?
    public var path: String?
    public var by: String?

    enum CodingKeys: String, CodingKey {
        case id, event, data, code, error, version, created, bytes, trace, kernel, files, decoys, what, path, by
        case timedOut = "timed_out"
    }
}

public enum Frame {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case badSize(Int)

        public var description: String {
            switch self {
            case let .badSize(n): return "guest sent a frame of \(n) bytes (limit \(GuestProtocol.maxFrame))"
            }
        }
    }

    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        out.append(payload)
        return out
    }
}

/// Turns a byte stream into whole frames. Feed it whatever arrives.
public struct FrameDecoder {
    private var buffer = [UInt8]()

    public init() {}

    public mutating func feed(_ bytes: Data) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let size = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16
                | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            guard size > 0, size <= GuestProtocol.maxFrame else { throw Frame.Problem.badSize(size) }
            guard buffer.count - offset - 4 >= size else { break }
            frames.append(Data(buffer[(offset + 4)..<(offset + 4 + size)]))
            offset += 4 + size
        }
        buffer.removeFirst(offset)
        return frames
    }
}

/// Makes guest output safe to print on a real terminal.
///
/// Keeps newline, tab and printable bytes. Drops every other control byte,
/// including ESC (so no cursor moves, title changes or clipboard writes) and
/// the two-byte UTF-8 forms of the C1 controls.
public struct OutputSanitizer {
    private var pendingC2 = false

    public init() {}

    public mutating func clean(_ input: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        for byte in input {
            if pendingC2 {
                pendingC2 = false
                if (0x80...0x9f).contains(byte) { continue }
                out.append(0xc2)
            }
            switch byte {
            case 0x0a, 0x09: out.append(byte)
            case 0x00..<0x20, 0x7f: continue
            case 0xc2: pendingC2 = true
            default: out.append(byte)
            }
        }
        return Data(out)
    }
}
