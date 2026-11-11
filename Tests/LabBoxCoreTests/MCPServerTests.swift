import Foundation
import Testing
@testable import LabBoxCore

/// A server whose "labbox" is a closure that records what it was asked to run.
private final class Harness {
    var calls: [[String]] = []
    var next = MCPServer.Launched(status: 0, stdout: Data("out".utf8), stderr: Data())
    var reportJSON: String? = #"{"flags":[]}"#
    let reportPath = NSTemporaryDirectory() + "labbox-mcp-test-\(UUID().uuidString).json"
    private(set) var server: MCPServer!

    init(hosts: [String] = ["registry.npmjs.org", "*.example.com"]) throws {
        server = try MCPServer(config: .init(allowedHosts: hosts, maxOutput: 50), launch: { [unowned self] arguments in
            self.calls.append(arguments)
            if let json = self.reportJSON, arguments.contains("--report-json") {
                try? Data(json.utf8).write(to: URL(fileURLWithPath: self.reportPath))
            }
            return self.next
        }, makeReportPath: { [unowned self] in self.reportPath })
    }

    func send(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) -> [String: Any]? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        guard let reply = server.handle(line: line) else { return nil }
        #expect(!reply.contains("\n"), "one message per line")
        return try! JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
    }

    /// Calls a tool and returns (text, isError).
    func tool(_ name: String, _ arguments: [String: Any] = [:]) -> (String, Bool) {
        let result = send("tools/call", ["name": name, "arguments": arguments])?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first
        return (content?["text"] as? String ?? "", result?["isError"] as? Bool ?? true)
    }
}

@Test func handshakeAndToolList() throws {
    let h = try Harness()
    let hello = h.send("initialize", ["protocolVersion": "2025-03-26"])?["result"] as? [String: Any]
    #expect(hello?["protocolVersion"] as? String == "2025-03-26")
    #expect((hello?["serverInfo"] as? [String: Any])?["name"] as? String == "labbox")
    #expect(h.send("notifications/initialized", id: nil) == nil, "notifications get no reply")
    #expect(h.send("ping")?["result"] != nil)

    let tools = (h.send("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    #expect(tools.compactMap { $0["name"] as? String }.sorted() == [
        "labbox_create_sandbox", "labbox_delete_sandbox", "labbox_list_sandboxes", "labbox_reset",
        "labbox_restore", "labbox_run", "labbox_snapshot",
    ])
    #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
}

@Test func badMessagesGetProperErrors() throws {
    let h = try Harness()
    let parse = try JSONSerialization.jsonObject(with: Data(h.server.handle(line: "not json")!.utf8)) as? [String: Any]
    #expect((parse?["error"] as? [String: Any])?["code"] as? Int == -32700)
    #expect((h.send("no/such/method")?["error"] as? [String: Any])?["code"] as? Int == -32601)
    #expect((h.send("tools/call", ["name": "nope"])?["error"] as? [String: Any])?["code"] as? Int == -32602)
    #expect(h.calls.isEmpty)
}

@Test func runInASandboxDiscardsByDefaultAndReturnsTheReport() throws {
    let h = try Harness()
    let (text, isError) = h.tool("labbox_run", ["command": "npm install x", "sandbox": "node", "allow": ["registry.npmjs.org"]])
    #expect(h.calls == [["run", "--timeout", "120", "--in", "node", "--report-json", h.reportPath, "--discard",
                         "--allow", "registry.npmjs.org", "--", "sh", "-c", "npm install x"]])
    #expect(!isError)
    #expect(text.contains("exit_code: 0"))
    #expect(text.contains("changes discarded"))
    #expect(text.contains("untrusted"))
    #expect(text.contains(#"{"flags":[]}"#))
    #expect(!FileManager.default.fileExists(atPath: h.reportPath), "the report file is cleaned up")
}

@Test func keepChangesAndTimeoutsArePassedThrough() throws {
    let h = try Harness()
    _ = h.tool("labbox_run", ["command": "apk add git", "sandbox": "dev", "keep_changes": true, "timeout_seconds": 99999])
    #expect(h.calls.first?.contains("--discard") == false)
    #expect(h.calls.first?[1...2] == ["--timeout", "900"], "capped at the server's maximum")

    _ = h.tool("labbox_run", ["command": "uname"])
    #expect(h.calls.last == ["run", "--timeout", "120", "--", "sh", "-c", "uname"])
}

@Test func theCommandIsOneArgumentNeverSplit() throws {
    let h = try Harness()
    let nasty = "echo hi; --allow '*' -- rm -rf / #"
    _ = h.tool("labbox_run", ["command": nasty])
    #expect(h.calls.last?.suffix(3) == ["sh", "-c", nasty])
    #expect(h.calls.last?.filter { $0 == "--allow" }.isEmpty == true)
}

@Test func hostsOutsideTheServerListAreRefusedWithoutRunning() throws {
    let h = try Harness()
    for bad in ["evil.test", "*", "*.npmjs.org", "registry.npmjs.org:22", "registry.npmjs.org.evil.test"] {
        let (text, isError) = h.tool("labbox_run", ["command": "true", "allow": [bad]])
        #expect(isError, "\(bad)")
        #expect(text.contains("not on this server's allowed hosts"), "\(bad)")
    }
    #expect(h.calls.isEmpty)

    for good in ["registry.npmjs.org", "REGISTRY.npmjs.org", "api.example.com", "*.example.com"] {
        #expect(!h.tool("labbox_run", ["command": "true", "allow": [good]]).1, "\(good)")
    }
    #expect(h.calls.count == 4)
}

@Test func badArgumentsAreRefusedWithoutRunning() throws {
    let h = try Harness()
    #expect(h.tool("labbox_run", [:]).1)
    #expect(h.tool("labbox_run", ["command": "true", "sandbox": "../etc"]).1)
    #expect(h.tool("labbox_run", ["command": "true", "sandbox": "--discard"]).1)
    #expect(h.tool("labbox_run", ["command": "true", "keep_changes": true]).1)
    #expect(h.tool("labbox_snapshot", ["name": "box"]).1)
    #expect(h.calls.isEmpty)
}

@Test func failuresAndLongOutputAreReported() throws {
    let h = try Harness()
    h.next = .init(status: 125, stdout: Data(), stderr: Data("[labbox] no sandbox named 'x'".utf8))
    h.reportJSON = nil
    let (failed, isError) = h.tool("labbox_run", ["command": "true", "sandbox": "x"])
    #expect(isError)
    #expect(failed.contains("LabBox itself failed"))
    #expect(failed.contains("No report was produced"))

    h.next = .init(status: 3, stdout: Data(String(repeating: "a", count: 500).utf8 + Data("THE-END".utf8)), stderr: Data())
    let (long, nonZero) = h.tool("labbox_run", ["command": "true"])
    #expect(!nonZero, "a failing command is a result, not a tool error")
    #expect(long.contains("exit_code: 3"))
    #expect(long.contains("earlier characters left out"))
    #expect(long.contains("THE-END"))

    h.next = .init(status: 124, stdout: Data(), stderr: Data())
    #expect(h.tool("labbox_run", ["command": "sleep 999", "timeout_seconds": 5]).0.contains("hit the 5s time limit"))
}

@Test func sandboxToolsMapToCommands() throws {
    let h = try Harness()
    _ = h.tool("labbox_list_sandboxes")
    _ = h.tool("labbox_create_sandbox", ["name": "box"])
    _ = h.tool("labbox_snapshot", ["name": "box", "snapshot": "clean"])
    _ = h.tool("labbox_restore", ["name": "box", "snapshot": "clean"])
    _ = h.tool("labbox_reset", ["name": "box"])
    _ = h.tool("labbox_delete_sandbox", ["name": "box"])
    #expect(h.calls == [["list"], ["create", "box"], ["snapshot", "box", "clean"], ["restore", "box", "clean"],
                        ["reset", "box"], ["delete", "box"]])
}
