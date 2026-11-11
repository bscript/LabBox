import Foundation
import Testing
@testable import LabBoxCore

/// Builds a real tar archive from a folder of files, the way a sandbox disk
/// holds one, padded with zeros like a disk image.
private final class Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labbox-archive-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: dir.appendingPathComponent("tree"), withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
        let url = dir.appendingPathComponent("tree/\(path)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent("tree/\(path)"))
    }

    func image(_ name: String) throws -> URL {
        let out = dir.appendingPathComponent(name)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--format", "pax", "-cf", out.path, "-C", dir.appendingPathComponent("tree").path, "."]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        let handle = try FileHandle(forWritingTo: out)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 64 * 1024))
        try handle.close()
        return out
    }
}

private func clean(_ index: [String: SandboxArchive.Entry]) -> [String: SandboxArchive.Entry] {
    // bsdtar stores "./name"; the guest agent stores "name".
    Dictionary(uniqueKeysWithValues: index.compactMap { key, value in
        let k = key.hasPrefix("./") ? String(key.dropFirst(2)) : key
        return k == "." || k.isEmpty ? nil : (k, value)
    })
}

@Test func archiveIndexListsFilesWithDigests() throws {
    let f = try Fixture()
    try f.write("work/hello.txt", "hello\n")
    try f.write("usr/bin/tool", "#!/bin/sh\n", mode: 0o755)
    let long = "deep/" + String(repeating: "x", count: 150) + "/file.txt"
    try f.write(long, "long path")
    let index = clean(try SandboxArchive.index(try f.image("a.img")))

    #expect(index["work/hello.txt"]?.kind == .file)
    #expect(index["work/hello.txt"]?.size == 6)
    #expect(index["work/hello.txt"]?.digest == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    #expect(index["usr/bin/tool"]?.mode == 0o755)
    #expect(index["work"]?.kind == .directory)
    #expect(index[long]?.kind == .file, "long names come through the extended header")
}

@Test func blankAndBrokenDisksAreHandled() throws {
    let f = try Fixture()
    let blank = f.dir.appendingPathComponent("blank.img")
    try Data(count: 1 << 20).write(to: blank)
    #expect(try SandboxArchive.index(blank).isEmpty)

    // A header that claims a file far larger than the disk.
    var header = [UInt8](repeating: 0, count: 512)
    header.replaceSubrange(0..<4, with: Array("evil".utf8))
    header.replaceSubrange(124..<135, with: Array("77777777777".utf8))
    header[156] = UInt8(ascii: "0")
    let lying = f.dir.appendingPathComponent("lying.img")
    try Data(header + [UInt8](repeating: 0, count: 2048)).write(to: lying)
    #expect(throws: SandboxArchive.Problem.self) { try SandboxArchive.index(lying) }

    header.replaceSubrange(124..<135, with: Array("not a size!".utf8))
    let garbage = f.dir.appendingPathComponent("garbage.img")
    try Data(header + [UInt8](repeating: 0, count: 2048)).write(to: garbage)
    #expect(throws: SandboxArchive.Problem.corrupt("bad size field")) { try SandboxArchive.index(garbage) }

    #expect(throws: SandboxArchive.Problem.self) { try SandboxArchive.index(f.dir.appendingPathComponent("missing.img")) }
}

@Test func diffFindsAddedModifiedAndRemoved() throws {
    let f = try Fixture()
    try f.write("work/keep.txt", "same")
    try f.write("work/edit.txt", "before")
    try f.write("work/gone.txt", "bye")
    try f.write("usr/bin/tool", "x", mode: 0o755)
    let before = clean(try SandboxArchive.index(try f.image("before.img")))

    try f.write("work/edit.txt", "after!")
    try f.remove("work/gone.txt")
    try f.write("work/new.sh", "#!/bin/sh\n", mode: 0o755)
    try f.write("usr/bin/tool", "x", mode: 0o4755)
    let after = clean(try SandboxArchive.index(try f.image("after.img")))

    let changes = SandboxArchive.diff(before: before, after: after)
    #expect(changes.map(\.path) == ["usr/bin/tool", "work/edit.txt", "work/gone.txt", "work/new.sh"])
    #expect(changes.map(\.change) == [.modified, .modified, .removed, .added])
    #expect(changes[0].setuid, "a mode change alone counts, and setuid is called out")
    #expect(changes[3].executable)
    #expect(SandboxArchive.diff(before: before, after: before).isEmpty)
}

private func change(_ path: String, _ kind: SandboxArchive.Change = .added, setuid: Bool = false) -> SandboxArchive.FileChange {
    SandboxArchive.FileChange(path: path, change: kind, executable: false, setuid: setuid)
}

@Test func notableFileRules() {
    for path in ["root/.profile", "root/.bashrc", "root/.ssh/authorized_keys", "etc/passwd", "etc/profile.d/x.sh",
                 "etc/crontabs/root", "etc/init.d/backdoor", "etc/ld.so.preload", "var/spool/cron/root"] {
        #expect(RunReport.isNotable(change(path)), "\(path)")
    }
    for path in ["work/app/node_modules/x/index.js", "root/.npm/_cacache/a", "usr/lib/node_modules/y/z.js",
                 "root/project/.profile", "etc/apk/world", "tmp/x"] {
        #expect(!RunReport.isNotable(change(path)), "\(path)")
    }
    #expect(RunReport.isNotable(change("usr/bin/thing", setuid: true)))
    #expect(!RunReport.isNotable(change("usr/bin/thing", .removed, setuid: true)))
}

@Test func onlyTheOwningToolIsAnExpectedReader() {
    #expect(RunReport.isExpected(decoy: "root/.npmrc", readers: ["npm"]))
    #expect(RunReport.isExpected(decoy: "root/.npmrc", readers: ["npm install left-pad"]))
    #expect(RunReport.isExpected(decoy: "root/.npmrc", readers: ["node /usr/bin/npm install"]))
    #expect(!RunReport.isExpected(decoy: "root/.npmrc", readers: ["npm", "node setup.js"]))
    #expect(!RunReport.isExpected(decoy: "root/.npmrc", readers: []))
    #expect(!RunReport.isExpected(decoy: "root/.ssh/id_rsa", readers: ["ssh"]), "no tool is excused for the private keys")
    #expect(!RunReport.isExpected(decoy: "root/.aws/credentials", readers: ["npm"]))
}

private func inputs(network: [NetGate.Record] = [], trace: GuestTrace? = GuestTrace(),
                    changes: [SandboxArchive.FileChange]? = [], networkEnabled: Bool = true) -> RunReport.Inputs {
    .init(sandbox: "box", command: ["npm", "install", "x"], exitCode: 0, timedOut: false, seconds: 1.234,
          stateKept: false, network: network, networkEnabled: networkEnabled, trace: trace, changes: changes, gaps: [])
}

@Test func aQuietRunHasNoFlagsAndSaysSo() {
    let report = RunReport(inputs(network: [.init(host: "registry.npmjs.org", port: 443, allowed: true, reason: nil, bytesUp: 10, bytesDown: 20)]))
    #expect(report.flags.isEmpty)
    #expect(report.gaps.isEmpty)
    #expect(report.text().contains("Nothing flagged. That is not the same as safe"))
    #expect(report.seconds == 1.23)
}

@Test func aNoisyRunIsFlaggedLineByLine() throws {
    let trace = GuestTrace(
        entries: [
            .init(path: "root/.ssh/id_rsa", count: 1, exec: nil, decoy: true, by: ["node setup.js"]),
            .init(path: "root/.npmrc", count: 2, exec: nil, decoy: true, by: ["npm"]),
            .init(path: "usr/bin/node", count: 3, exec: true, decoy: nil, by: ["sh"]),
        ],
        filesOpened: 40, leftRunning: ["sleep 600"],
        decoysPlaced: ["root/.ssh/id_rsa", "root/.npmrc", "root/.aws/credentials"],
        decoysChanged: ["root/.aws/credentials"], incomplete: true
    )
    let network: [NetGate.Record] = [
        .init(host: "evil.example", port: 443, allowed: false, reason: "not on the allow list"),
        .init(host: "evil.example", port: 443, allowed: false, reason: "not on the allow list"),
        .init(host: "registry.npmjs.org", port: 443, allowed: true, reason: nil, bytesUp: 5, bytesDown: 7),
    ]
    let report = RunReport(inputs(network: network, trace: trace, changes: [change("root/.profile"), change("work/a.js")]))

    #expect(report.flags == [
        "blocked connection to evil.example:443 (not on the allow list)",
        "opened decoy secret ~/.ssh/id_rsa by: node setup.js",
        "changed decoy secret ~/.aws/credentials",
        "left running: sleep 600",
        "added /root/.profile",
    ])
    #expect(report.network.first?.connections == 2)
    #expect(report.decoyReads.first { $0.path == "~/.npmrc" }?.expected == true)
    #expect(report.programs == ["usr/bin/node"])
    #expect(report.files?.byArea == ["root": 1, "work": 1])
    #expect(report.gaps.count == 1, "an overflowed trace is reported as a gap")

    let decoded = try JSONDecoder().decode(RunReport.self, from: report.json())
    #expect(decoded == report)
}

@Test func missingPartsAreListedAsGaps() {
    let report = RunReport(inputs(trace: nil, changes: nil, networkEnabled: false))
    #expect(report.files == nil)
    #expect(report.filesOpened == nil)
    #expect(report.gaps.contains { $0.contains("network was off") })
}

@Test func reportTextCannotCarryTerminalCodes() {
    let trace = GuestTrace(entries: [.init(path: "root/.ssh/id_rsa", count: 1, exec: nil, decoy: true, by: ["\u{1b}]0;pwned\u{07}node"])],
                           leftRunning: ["x\u{1b}[2J\nFlagged: nothing"])
    let text = RunReport(inputs(trace: trace)).text()
    #expect(!text.contains("\u{1b}"))
    #expect(!text.contains("\u{07}"))
    #expect(!text.contains("\nFlagged: nothing"), "a guest string cannot start its own report line")
}

@Test func guestTraceDecodingIsLenient() throws {
    let trace = try JSONDecoder().decode(GuestTrace.self, from: Data(#"{"entries":null,"left_running":null}"#.utf8))
    #expect(trace == GuestTrace())
}
