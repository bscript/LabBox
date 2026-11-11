import Foundation
import Testing
@testable import LabBoxCore

/// A store in a fresh temp folder, removed when the test ends.
private final class TempStore {
    let store: SandboxStore
    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labbox-test-\(UUID().uuidString)")
        store = SandboxStore(root: dir)
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }

    func disk(_ name: String) -> URL { store.root.appendingPathComponent("\(name)/disk.img") }
    func write(_ text: String, to name: String) throws {
        let h = try FileHandle(forWritingTo: disk(name))
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }
    func read(_ name: String, _ count: Int) throws -> String {
        let h = try FileHandle(forReadingFrom: disk(name))
        defer { try? h.close() }
        return String(decoding: try h.read(upToCount: count) ?? Data(), as: UTF8.self)
    }
}

@Test func namesAreStrict() {
    for good in ["a", "node-22", "0day", String(repeating: "x", count: 32)] {
        #expect(SandboxStore.isValidName(good), "\(good)")
    }
    for bad in ["", "-a", "A", "a b", "a/b", "..", "a.b", "é", String(repeating: "x", count: 33), "a\n"] {
        #expect(!SandboxStore.isValidName(bad), "\(bad)")
    }
}

@Test func createMakesASparseDisk() throws {
    let t = TempStore()
    try t.store.create("box", diskMB: 128)
    let info = try t.store.info("box")
    #expect(info.meta.diskMB == 128)
    #expect(info.snapshots.isEmpty)
    #expect(!info.hasState)
    let size = try FileManager.default.attributesOfItem(atPath: t.disk("box").path)[.size] as? Int
    #expect(size == 128 * 1_048_576)
    #expect(info.bytesOnDisk < 1_048_576)
}

@Test func createRefusesBadInput() throws {
    let t = TempStore()
    #expect(throws: SandboxStore.Problem.badName("../x")) { try t.store.create("../x") }
    #expect(throws: SandboxStore.Problem.badDiskSize(1)) { try t.store.create("box", diskMB: 1) }
    try t.store.create("box")
    #expect(throws: SandboxStore.Problem.exists("box")) { try t.store.create("box") }
    #expect(throws: SandboxStore.Problem.notFound("nope")) { try t.store.info("nope") }
}

@Test func snapshotRestoreAndReset() throws {
    let t = TempStore()
    try t.store.create("box", diskMB: 64)
    try t.write("one", to: "box")
    try t.store.snapshot("box", as: "first")
    try t.write("two", to: "box")
    #expect(try t.read("box", 3) == "two")

    #expect(throws: SandboxStore.Problem.snapshotExists("first")) { try t.store.snapshot("box", as: "first") }
    #expect(throws: SandboxStore.Problem.snapshotNotFound("zzz")) { try t.store.restore("box", from: "zzz") }

    try t.store.restore("box", from: "first")
    #expect(try t.read("box", 3) == "one")
    #expect(try t.store.info("box").snapshots == ["first"])

    try t.store.reset("box")
    #expect(try t.read("box", 3) == "\0\0\0")
    #expect(try t.store.info("box").snapshots == ["first"], "reset keeps snapshots")

    try t.store.deleteSnapshot("box", "first")
    #expect(try t.store.info("box").snapshots.isEmpty)
}

@Test func runCommitsOnlyWhenAsked() throws {
    let t = TempStore()
    try t.store.create("box", diskMB: 64)
    try t.write("old", to: "box")

    let aborted = try t.store.beginRun("box")
    try Data("new".utf8).write(to: aborted.workingDisk)
    aborted.abort()
    #expect(try t.read("box", 3) == "old")
    #expect(!FileManager.default.fileExists(atPath: aborted.workingDisk.path))

    let committed = try t.store.beginRun("box")
    let h = try FileHandle(forWritingTo: committed.workingDisk)
    try h.write(contentsOf: Data("new".utf8))
    try h.close()
    try committed.commit()
    #expect(try t.read("box", 3) == "new")
}

@Test func aSandboxInUseIsLocked() throws {
    let t = TempStore()
    try t.store.create("box", diskMB: 64)
    let session = try t.store.beginRun("box")
    #expect(throws: SandboxStore.Problem.busy("box")) { _ = try t.store.beginRun("box") }
    #expect(throws: SandboxStore.Problem.busy("box")) { try t.store.snapshot("box", as: "s") }
    #expect(throws: SandboxStore.Problem.busy("box")) { try t.store.delete("box") }
    session.abort()
    try t.store.snapshot("box", as: "s")
}

@Test func deleteRemovesEverything() throws {
    let t = TempStore()
    try t.store.create("box", diskMB: 64)
    try t.store.snapshot("box", as: "s")
    try t.store.delete("box")
    #expect(t.store.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: t.store.root.appendingPathComponent("box").path))
}

@Test func listIsSortedAndSkipsJunk() throws {
    let t = TempStore()
    try t.store.create("zeta", diskMB: 64)
    try t.store.create("alpha", diskMB: 64)
    try FileManager.default.createDirectory(at: t.store.root.appendingPathComponent("Not A Sandbox"), withIntermediateDirectories: true)
    #expect(t.store.list().map(\.meta.name) == ["alpha", "zeta"])
}
