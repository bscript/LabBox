import Foundation
import Testing
@testable import LabBoxCore

private func policy(_ rules: String...) throws -> NetPolicy { try NetPolicy(parsing: rules) }

@Test func nothingIsAllowedByDefault() {
    #expect(NetPolicy().decide(host: "example.com", port: 443) == .deny("not on the allow list"))
}

@Test func exactHostsMatchOnlyThemselves() throws {
    let p = try policy("registry.npmjs.org")
    #expect(p.decide(host: "registry.npmjs.org", port: 443) == .allow)
    #expect(p.decide(host: "REGISTRY.npmjs.org.", port: 80) == .allow)
    #expect(p.decide(host: "evil-registry.npmjs.org", port: 443) != .allow)
    #expect(p.decide(host: "registry.npmjs.org.evil.com", port: 443) != .allow)
    #expect(p.decide(host: "npmjs.org", port: 443) != .allow)
}

@Test func wildcardsCoverSubdomainsOnly() throws {
    let p = try policy("*.example.com")
    #expect(p.decide(host: "a.example.com", port: 443) == .allow)
    #expect(p.decide(host: "a.b.example.com", port: 443) == .allow)
    #expect(p.decide(host: "example.com", port: 443) != .allow)
    #expect(p.decide(host: "badexample.com", port: 443) != .allow)
}

@Test func portsDefaultToWebAndCanBeNarrowed() throws {
    #expect(try policy("example.com").decide(host: "example.com", port: 22)
        == .deny("port 22 is not allowed for this host"))
    let p = try policy("example.com:8080")
    #expect(p.decide(host: "example.com", port: 8080) == .allow)
    #expect(p.decide(host: "example.com", port: 443) != .allow)
}

@Test func starAllowsAnyNameOnWebPorts() throws {
    let p = try policy("*")
    #expect(p.decide(host: "anything.test", port: 443) == .allow)
    #expect(p.decide(host: "anything.test", port: 25) != .allow)
}

@Test func oddHostsAreRefused() throws {
    let p = try policy("*")
    for bad in ["", "a b", "a..b", "exa$mple.com", "[::1]", "a/b", "é.com", String(repeating: "a", count: 64) + ".com"] {
        #expect(p.decide(host: bad, port: 443) == .deny("not a valid host name"), "\(bad)")
    }
    #expect(p.decide(host: "example.com", port: 0) == .deny("not a valid port"))
}

@Test func badRulesAreRejected() {
    for bad in ["", "exa mple.com", "example.com:0", "example.com:http", "*.", "*.*", "http://example.com"] {
        #expect(throws: NetPolicy.Problem.badRule(bad)) { try NetPolicy(parsing: [bad]) }
    }
}

@Test func privateIPv4IsNeverPublic() {
    for local in [[127, 0, 0, 1], [10, 1, 2, 3], [192, 168, 1, 1], [172, 16, 0, 1], [172, 31, 255, 255],
                  [169, 254, 169, 254], [100, 64, 0, 1], [0, 0, 0, 0], [224, 0, 0, 1], [255, 255, 255, 255],
                  [198, 18, 0, 1], [192, 0, 0, 8]] as [[UInt8]] {
        #expect(!NetPolicy.isPublic(ipv4: local), "\(local)")
    }
    for open in [[1, 1, 1, 1], [8, 8, 8, 8], [172, 32, 0, 1], [172, 15, 0, 1], [100, 63, 0, 1], [192, 0, 1, 1], [151, 101, 1, 1]] as [[UInt8]] {
        #expect(NetPolicy.isPublic(ipv4: open), "\(open)")
    }
    #expect(!NetPolicy.isPublic(ipv4: [1, 2, 3]))
}

private func v6(_ text: String) -> [UInt8] {
    var addr = in6_addr()
    precondition(inet_pton(AF_INET6, text, &addr) == 1, text)
    return withUnsafeBytes(of: addr) { Array($0) }
}

@Test func privateIPv6IsNeverPublic() {
    for local in ["::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
                  "::ffff:127.0.0.1", "::ffff:192.168.1.1", "::10.0.0.1", "64:ff9b::a00:1"] {
        #expect(!NetPolicy.isPublic(ipv6: v6(local)), "\(local)")
    }
    for open in ["2606:4700::1111", "2a04:4e42::649", "::ffff:8.8.8.8", "64:ff9b::808:808"] {
        #expect(NetPolicy.isPublic(ipv6: v6(open)), "\(open)")
    }
}

@Test func localNamesResolveToNonPublicAddresses() {
    let answers = NetGate.resolve("localhost")
    #expect(!answers.isEmpty)
    #expect(answers.allSatisfy { !$0.isPublic })
    #expect(NetGate.resolve("127.0.0.1").allSatisfy { !$0.isPublic })
    #expect(NetGate.resolve("no-such-host.invalid").isEmpty)
}
