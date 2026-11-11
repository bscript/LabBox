import Foundation

/// Everything needed to boot one sandbox VM.
///
/// This file has no Virtualization import so the rules can be tested without
/// booting anything.
public struct SandboxConfig: Equatable, Sendable {
    public var kernel: URL
    public var initrd: URL?
    public var disk: URL?
    public var diskReadOnly: Bool
    public var cpus: Int
    public var memoryMB: Int
    public var commandLine: String
    /// Hard stop. The VM is killed when this many seconds have passed.
    public var timeoutSeconds: Int?

    public init(
        kernel: URL,
        initrd: URL? = nil,
        disk: URL? = nil,
        diskReadOnly: Bool = false,
        cpus: Int = 2,
        memoryMB: Int = 2048,
        commandLine: String = "console=hvc0",
        timeoutSeconds: Int? = nil
    ) {
        self.kernel = kernel
        self.initrd = initrd
        self.disk = disk
        self.diskReadOnly = diskReadOnly
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.commandLine = commandLine
        self.timeoutSeconds = timeoutSeconds
    }

    public static let minMemoryMB = 256

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missingFile(role: String, path: String)
        case compressedKernel(path: String)
        case cpusOutOfRange(asked: Int, max: Int)
        case memoryOutOfRange(askedMB: Int, minMB: Int, maxMB: Int)
        case badTimeout(Int)

        public var description: String {
            switch self {
            case let .missingFile(role, path):
                return "\(role) not found at \(path)"
            case let .compressedKernel(path):
                return "kernel at \(path) is compressed (gzip or EFI zboot); Virtualization.framework needs the raw arm64 Image (scripts/fetch-alpine.sh unpacks both)"
            case let .cpusOutOfRange(asked, max):
                return "cpus must be between 1 and \(max), got \(asked)"
            case let .memoryOutOfRange(asked, min, max):
                return "memory must be between \(min) and \(max) MB, got \(asked)"
            case let .badTimeout(t):
                return "timeout must be a positive number of seconds, got \(t)"
            }
        }
    }

    /// Host facts and file access are passed in so tests can fake them.
    public struct Host: Sendable {
        public var cpus: Int
        public var memoryMB: Int
        public var fileExists: @Sendable (URL) -> Bool
        public var firstBytes: @Sendable (URL, Int) -> [UInt8]

        public init(
            cpus: Int,
            memoryMB: Int,
            fileExists: @escaping @Sendable (URL) -> Bool,
            firstBytes: @escaping @Sendable (URL, Int) -> [UInt8]
        ) {
            self.cpus = cpus
            self.memoryMB = memoryMB
            self.fileExists = fileExists
            self.firstBytes = firstBytes
        }

        public static var current: Host {
            Host(
                cpus: ProcessInfo.processInfo.processorCount,
                memoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                firstBytes: { url, n in
                    guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
                    defer { try? h.close() }
                    return [UInt8]((try? h.read(upToCount: n)) ?? Data())
                }
            )
        }
    }

    /// Returns every problem found, so the user can fix them in one go.
    public func problems(host: Host = .current) -> [Problem] {
        var out: [Problem] = []

        if !host.fileExists(kernel) {
            out.append(.missingFile(role: "kernel", path: kernel.path))
        } else {
            let head = host.firstBytes(kernel, 8)
            let gzip = head.starts(with: [0x1f, 0x8b])
            let zboot = head.count == 8 && Array(head[4...]) == Array("zimg".utf8)
            if gzip || zboot { out.append(.compressedKernel(path: kernel.path)) }
        }
        if let initrd, !host.fileExists(initrd) {
            out.append(.missingFile(role: "initrd", path: initrd.path))
        }
        if let disk, !host.fileExists(disk) {
            out.append(.missingFile(role: "disk", path: disk.path))
        }
        if cpus < 1 || cpus > host.cpus {
            out.append(.cpusOutOfRange(asked: cpus, max: host.cpus))
        }
        // Never hand the guest all of the host's memory.
        let maxMB = max(Self.minMemoryMB, host.memoryMB / 2)
        if memoryMB < Self.minMemoryMB || memoryMB > maxMB {
            out.append(.memoryOutOfRange(askedMB: memoryMB, minMB: Self.minMemoryMB, maxMB: maxMB))
        }
        if let t = timeoutSeconds, t <= 0 {
            out.append(.badTimeout(t))
        }
        return out
    }
}

public enum LabBoxPaths {
    /// ~/Library/Application Support/LabBox. Sandbox data lives here, away
    /// from the user's own files.
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabBox", isDirectory: true)
    }
    public static var images: URL { root.appendingPathComponent("images", isDirectory: true) }
    public static var defaultKernel: URL { images.appendingPathComponent("alpine/vmlinuz") }
    public static var defaultInitrd: URL { images.appendingPathComponent("alpine/initramfs") }
    /// Alpine's ramdisk plus the guest agent; made by scripts/build-guest.sh.
    public static var agentInitrd: URL { images.appendingPathComponent("labbox/initramfs") }
    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
}
