import Darwin
import Foundation

/// Sandboxes on disk.
///
///     <root>/<name>/meta.json
///     <root>/<name>/disk.img            the sandbox's saved state
///     <root>/<name>/snapshots/<s>.img   copies of disk.img
///     <root>/<name>/run.img             working copy while a run is in flight
///     <root>/<name>/run.lock            held for the length of a run
///
/// Copies are APFS clones, so a snapshot is instant and takes no extra space
/// until the two files drift apart.
public struct SandboxStore {
    public let root: URL

    public init(root: URL = LabBoxPaths.root.appendingPathComponent("sandboxes", isDirectory: true)) {
        self.root = root
    }

    public struct Meta: Codable, Equatable {
        public var name: String
        public var created: Date
        public var diskMB: Int
    }

    public struct Info: Equatable {
        public var meta: Meta
        public var snapshots: [String]
        /// Bytes the sandbox really takes on the host, snapshots included.
        public var bytesOnDisk: Int
        public var hasState: Bool
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case badName(String)
        case exists(String)
        case notFound(String)
        case snapshotExists(String)
        case snapshotNotFound(String)
        case busy(String)
        case badDiskSize(Int)
        case io(String)

        public var description: String {
            switch self {
            case let .badName(n): return "'\(n)' is not a valid name; use 1-32 of a-z, 0-9 and '-', starting with a letter or digit"
            case let .exists(n): return "sandbox '\(n)' already exists"
            case let .notFound(n): return "no sandbox named '\(n)'"
            case let .snapshotExists(n): return "snapshot '\(n)' already exists"
            case let .snapshotNotFound(n): return "no snapshot named '\(n)'"
            case let .busy(n): return "sandbox '\(n)' is in use by another run"
            case let .badDiskSize(mb): return "disk size must be between \(SandboxStore.minDiskMB) and \(SandboxStore.maxDiskMB) MB, got \(mb)"
            case let .io(what): return what
            }
        }
    }

    public static let minDiskMB = 64
    public static let maxDiskMB = 65_536
    public static let defaultDiskMB = 2048

    // MARK: Names and paths

    /// Names become path components, so they are checked strictly.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (0x61...0x7a).contains(b) || (0x30...0x39).contains(b) }
        return alnum(bytes[0]) && bytes.allSatisfy { alnum($0) || $0 == 0x2d }
    }

    private func checked(_ name: String) throws -> String {
        guard Self.isValidName(name) else { throw Problem.badName(name) }
        return name
    }

    private func dir(_ name: String) throws -> URL {
        root.appendingPathComponent(try checked(name), isDirectory: true)
    }

    private func existingDir(_ name: String) throws -> URL {
        let d = try dir(name)
        guard FileManager.default.fileExists(atPath: d.appendingPathComponent("meta.json").path) else {
            throw Problem.notFound(name)
        }
        return d
    }

    private func snapshotURL(_ sandbox: URL, _ snapshot: String) throws -> URL {
        sandbox.appendingPathComponent("snapshots/\(try checked(snapshot)).img")
    }

    // MARK: Create, list, delete

    @discardableResult
    public func create(_ name: String, diskMB: Int = SandboxStore.defaultDiskMB) throws -> Meta {
        let d = try dir(name)
        guard (Self.minDiskMB...Self.maxDiskMB).contains(diskMB) else { throw Problem.badDiskSize(diskMB) }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: d.path) else { throw Problem.exists(name) }
        try fm.createDirectory(at: d.appendingPathComponent("snapshots"), withIntermediateDirectories: true)

        let meta = Meta(name: name, created: Date(), diskMB: diskMB)
        try Self.makeBlankDisk(at: d.appendingPathComponent("disk.img"), megabytes: diskMB)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: d.appendingPathComponent("meta.json"), options: .atomic)
        return meta
    }

    public func info(_ name: String) throws -> Info {
        let d = try existingDir(name)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(Meta.self, from: Data(contentsOf: d.appendingPathComponent("meta.json")))
        let fm = FileManager.default
        let snapshotFiles = (try? fm.contentsOfDirectory(atPath: d.appendingPathComponent("snapshots").path)) ?? []
        let snapshots = snapshotFiles.filter { $0.hasSuffix(".img") }.map { String($0.dropLast(4)) }.sorted()
        let disk = d.appendingPathComponent("disk.img")
        var bytes = Self.allocated(disk)
        for s in snapshots { bytes += Self.allocated(d.appendingPathComponent("snapshots/\(s).img")) }
        return Info(meta: meta, snapshots: snapshots, bytesOnDisk: bytes, hasState: Self.allocated(disk) > 0)
    }

    public func list() -> [Info] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { try? info($0) }
    }

    public func delete(_ name: String) throws {
        let d = try existingDir(name)
        let lock = try lock(d, name)
        defer { Self.unlock(lock) }
        try FileManager.default.removeItem(at: d)
    }

    // MARK: Snapshots

    public func snapshot(_ name: String, as snapshot: String) throws {
        let d = try existingDir(name)
        let target = try snapshotURL(d, snapshot)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Problem.snapshotExists(snapshot) }
        let lock = try lock(d, name)
        defer { Self.unlock(lock) }
        try Self.clone(d.appendingPathComponent("disk.img"), to: target)
    }

    public func restore(_ name: String, from snapshot: String) throws {
        let d = try existingDir(name)
        let source = try snapshotURL(d, snapshot)
        guard FileManager.default.fileExists(atPath: source.path) else { throw Problem.snapshotNotFound(snapshot) }
        let lock = try lock(d, name)
        defer { Self.unlock(lock) }
        try Self.replace(d.appendingPathComponent("disk.img"), bySwappingIn: { try Self.clone(source, to: $0) })
    }

    public func deleteSnapshot(_ name: String, _ snapshot: String) throws {
        let d = try existingDir(name)
        let target = try snapshotURL(d, snapshot)
        guard FileManager.default.fileExists(atPath: target.path) else { throw Problem.snapshotNotFound(snapshot) }
        try FileManager.default.removeItem(at: target)
    }

    /// Back to a blank disk. Snapshots are kept.
    public func reset(_ name: String) throws {
        let d = try existingDir(name)
        let mb = try info(name).meta.diskMB
        let lock = try lock(d, name)
        defer { Self.unlock(lock) }
        try Self.replace(d.appendingPathComponent("disk.img"), bySwappingIn: { try Self.makeBlankDisk(at: $0, megabytes: mb) })
    }

    // MARK: Runs

    /// One run against a sandbox. The VM writes to a working copy; `commit`
    /// makes it the sandbox's state, `abort` (or a crash) leaves the sandbox
    /// exactly as it was.
    public final class RunSession {
        public let workingDisk: URL
        /// The sandbox's state as it was before this run. Read-only use.
        public var savedDisk: URL { disk }
        private let disk: URL
        private var lock: Int32
        private var done = false

        fileprivate init(workingDisk: URL, disk: URL, lock: Int32) {
            self.workingDisk = workingDisk
            self.disk = disk
            self.lock = lock
        }

        public func commit() throws {
            guard !done else { return }
            guard rename(workingDisk.path, disk.path) == 0 else {
                throw Problem.io("cannot save sandbox state: \(String(cString: strerror(errno)))")
            }
            finish()
        }

        public func abort() {
            guard !done else { return }
            try? FileManager.default.removeItem(at: workingDisk)
            finish()
        }

        private func finish() {
            done = true
            SandboxStore.unlock(lock)
        }

        deinit { abort() }
    }

    public func beginRun(_ name: String) throws -> RunSession {
        let d = try existingDir(name)
        let lock = try lock(d, name)
        let working = d.appendingPathComponent("run.img")
        do {
            // Left over from a run that crashed; the lock proves it is dead.
            try? FileManager.default.removeItem(at: working)
            try Self.clone(d.appendingPathComponent("disk.img"), to: working)
        } catch {
            Self.unlock(lock)
            throw error
        }
        return RunSession(workingDisk: working, disk: d.appendingPathComponent("disk.img"), lock: lock)
    }

    // MARK: Files

    private func lock(_ sandbox: URL, _ name: String) throws -> Int32 {
        let fd = open(sandbox.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Problem.io("cannot open lock for '\(name)': \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Problem.busy(name)
        }
        return fd
    }

    /// Unlock before closing. Closing alone is not enough: a child process
    /// forked at the wrong moment holds a copy of the descriptor until it
    /// execs, and the lock would live on with it.
    static func unlock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    static func makeBlankDisk(at url: URL, megabytes: Int) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw Problem.io("cannot create \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        // Sparse: takes no space until the guest writes.
        guard ftruncate(fd, off_t(megabytes) * 1_048_576) == 0 else {
            throw Problem.io("cannot size \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    static func clone(_ source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) == 0 { return }
        // Not APFS (or cross-volume): fall back to a real copy.
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            throw Problem.io("cannot copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Builds the new file next to the old one, then renames over it, so the
    /// disk is never missing or half-written.
    static func replace(_ target: URL, bySwappingIn make: (URL) throws -> Void) throws {
        let staging = target.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: staging)
        try make(staging)
        guard rename(staging.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw Problem.io("cannot replace \(target.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    static func allocated(_ url: URL) -> Int {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return Int(st.st_blocks) * 512
    }
}
