import Foundation

/// Which destinations a sandbox may reach. Decided on the host; the guest
/// only gets the answer.
///
/// Two layers:
/// 1. The allow list: host patterns the user named for this run.
/// 2. A fixed block on private, loopback and link-local addresses, applied to
///    what a name resolves to. No rule can lift it, so a sandbox can never
///    reach the Mac itself or the local network, even with `--allow '*'`.
public struct NetPolicy: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        /// "example.com", "*.example.com" (subdomains only) or "*".
        public var host: String
        public var ports: Set<Int>
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(String)
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case badRule(String)

        public var description: String {
            switch self {
            case let .badRule(r):
                return "'\(r)' is not a valid --allow rule; use HOST, *.HOST or '*', with an optional :PORT"
            }
        }
    }

    public static let defaultPorts: Set<Int> = [80, 443]
    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    public init(parsing texts: [String]) throws {
        self.rules = try texts.map(Self.parseRule)
    }

    static func parseRule(_ text: String) throws -> Rule {
        var host = text
        var ports = defaultPorts
        if let colon = text.lastIndex(of: ":") {
            guard let port = Int(text[text.index(after: colon)...]), (1...65535).contains(port) else {
                throw Problem.badRule(text)
            }
            host = String(text[..<colon])
            ports = [port]
        }
        // Only lowercase here. Trimming dots would turn a mistyped "*." into
        // "*", which allows everything.
        host = host.lowercased()
        let name = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        guard host == "*" || isHostname(name) else { throw Problem.badRule(text) }
        return Rule(host: host, ports: ports)
    }

    public static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Letters, digits, '-' and '.', with no empty labels. Covers IPv4
    /// literals too. IPv6 literals are not supported as destinations.
    static func isHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.allSatisfy { b in
                (0x61...0x7a).contains(b) || (0x30...0x39).contains(b) || b == 0x2d
            }
        }
    }

    public func decide(host rawHost: String, port: Int) -> Decision {
        let host = Self.normalize(rawHost)
        guard Self.isHostname(host) else { return .deny("not a valid host name") }
        guard (1...65535).contains(port) else { return .deny("not a valid port") }

        var hostMatched = false
        for rule in rules {
            let matches: Bool
            if rule.host == "*" {
                matches = true
            } else if rule.host.hasPrefix("*.") {
                matches = host.hasSuffix(rule.host.dropFirst(1))
            } else {
                matches = host == rule.host
            }
            guard matches else { continue }
            if rule.ports.contains(port) { return .allow }
            hostMatched = true
        }
        return .deny(hostMatched ? "port \(port) is not allowed for this host" : "not on the allow list")
    }

    // MARK: Address block

    /// True only for addresses on the public internet.
    public static func isPublic(ipv4 a: [UInt8]) -> Bool {
        guard a.count == 4 else { return false }
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _): return false          // this network, private, loopback
        case (100, 64...127): return false                     // carrier-grade NAT
        case (169, 254): return false                          // link-local
        case (172, 16...31): return false                      // private
        case (192, 168): return false                          // private
        case (192, 0) where a[2] == 0: return false            // protocol assignments
        case (198, 18...19): return false                      // benchmarking
        case (224...255, _): return false                      // multicast, reserved, broadcast
        default: return true
        }
    }

    public static func isPublic(ipv6 a: [UInt8]) -> Bool {
        guard a.count == 16 else { return false }
        if a.allSatisfy({ $0 == 0 }) { return false }                                    // ::
        if a[0..<15].allSatisfy({ $0 == 0 }) && a[15] == 1 { return false }              // ::1
        if a[0] & 0xfe == 0xfc { return false }                                          // fc00::/7 unique local
        if a[0] == 0xfe && a[1] & 0xc0 == 0x80 { return false }                          // fe80::/10 link-local
        if a[0] == 0xff { return false }                                                 // multicast
        // IPv4 carried inside IPv6: judge the IPv4 address.
        if a[0..<10].allSatisfy({ $0 == 0 }) && a[10] == 0xff && a[11] == 0xff {         // ::ffff:a.b.c.d
            return isPublic(ipv4: Array(a[12..<16]))
        }
        if a[0..<12].allSatisfy({ $0 == 0 }) { return false }                            // ::a.b.c.d (deprecated)
        if Array(a[0..<12]) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {           // 64:ff9b::/96 NAT64
            return isPublic(ipv4: Array(a[12..<16]))
        }
        return true
    }
}
