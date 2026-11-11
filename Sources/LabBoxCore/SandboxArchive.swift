import CryptoKit
import Foundation

/// Reads a sandbox's saved state (a tar archive written onto a raw disk
/// image) on the host, without booting anything.
///
/// The archive was written inside the guest, so it is untrusted input: every
/// size is checked against the file, counts are capped, and anything odd
/// stops the read with an error instead of being guessed at.
public enum SandboxArchive {
    public enum Kind: String, Codable, Sendable {
        case file, directory, symlink, hardlink, other
    }

    public struct Entry: Equatable, Sendable {
        public var kind: Kind
        public var size: Int
        public var mode: Int
        public var link: String
        /// SHA-256 of the contents; empty for anything but regular files.
        public var digest: String
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case corrupt(String)
        case tooManyEntries

        public var description: String {
            switch self {
            case let .unreadable(why): return "cannot read sandbox archive: \(why)"
            case let .corrupt(why): return "sandbox archive is damaged: \(why)"
            case .tooManyEntries: return "sandbox archive has more than \(SandboxArchive.maxEntries) entries"
            }
        }
    }

    public static let maxEntries = 2_000_000
    static let block = 512
    static let maxPaxHeader = 1 << 20

    /// Path -> entry for everything in the archive. A blank disk gives [:].
    public static func index(_ url: URL) throws -> [String: Entry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Problem.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }
        let total = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)

        var entries: [String: Entry] = [:]
        var offset = 0
        var pax: [String: String] = [:]

        func read(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= total else { throw Problem.corrupt("runs past the end of the disk") }
            let data = (try? handle.read(upToCount: count)) ?? Data()
            guard data.count == count else { throw Problem.corrupt("short read") }
            offset += count
            return data
        }
        func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= total else { throw Problem.corrupt("runs past the end of the disk") }
            offset += count
            try? handle.seek(toOffset: UInt64(offset))
        }
        func padded(_ size: Int) -> Int { (size + block - 1) / block * block }

        while offset + block <= total {
            let header = [UInt8](try read(block))
            if header.allSatisfy({ $0 == 0 }) { break } // end of archive

            guard var size = octal(header[124..<136]) else { throw Problem.corrupt("bad size field") }
            let type = header[156]
            var name = text(header[0..<100])
            let prefix = text(header[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
            var link = text(header[157..<257])

            // Extended header: applies to the entry that follows.
            if type == UInt8(ascii: "x") || type == UInt8(ascii: "g") {
                guard size <= maxPaxHeader else { throw Problem.corrupt("oversized extended header") }
                let body = try read(padded(size)).prefix(size)
                if type == UInt8(ascii: "x") { pax = parsePax(body) }
                continue
            }
            if let p = pax["path"] { name = p }
            if let l = pax["linkpath"] { link = l }
            if let s = pax["size"] {
                guard let n = Int(s), n >= 0 else { throw Problem.corrupt("bad extended size") }
                size = n
            }
            pax = [:]

            let kind: Kind
            switch type {
            case 0, UInt8(ascii: "0"): kind = .file
            case UInt8(ascii: "1"): kind = .hardlink
            case UInt8(ascii: "2"): kind = .symlink
            case UInt8(ascii: "5"): kind = .directory
            default: kind = .other
            }

            var digest = ""
            if kind == .file {
                guard offset + size <= total else { throw Problem.corrupt("file runs past the end of the disk") }
                var hasher = SHA256()
                var left = size
                while left > 0 {
                    let chunk = try read(min(left, 1 << 20))
                    hasher.update(data: chunk)
                    left -= chunk.count
                }
                try skip(padded(size) - size)
                digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } else if kind == .other {
                try skip(padded(size))
            }
            // Links and directories carry no data, whatever the size says.

            while name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty else { continue }
            guard entries.count < maxEntries else { throw Problem.tooManyEntries }
            entries[name] = Entry(
                kind: kind,
                size: kind == .file ? size : 0,
                mode: (octal(header[100..<108]) ?? 0) & 0o7777,
                link: link,
                digest: digest
            )
        }
        return entries
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Octal number padded with spaces or NULs. Empty means zero.
    private static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for b in bytes {
            if b == 0 || b == 0x20 { if value > 0 { break } else { continue } }
            guard (0x30...0x37).contains(b), value < Int.max / 16 else { return nil }
            value = value * 8 + Int(b - 0x30)
        }
        return value
    }

    /// Records look like "27 path=some/long/name\n", the number being the
    /// length of the whole record.
    private static func parsePax(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        var rest = body[...]
        while let space = rest.firstIndex(of: 0x20),
              let length = Int(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)),
              length > 0, length <= rest.count {
            let record = rest.prefix(length)
            rest = rest.dropFirst(length)
            let field = record[record.index(after: space)...].dropLast() // trailing newline
            guard let equals = field.firstIndex(of: 0x3d) else { continue }
            let key = String(decoding: field[field.startIndex..<equals], as: UTF8.self)
            out[key] = String(decoding: field[field.index(after: equals)...], as: UTF8.self)
        }
        return out
    }

    // MARK: Diff

    public enum Change: String, Codable, Sendable {
        case added, modified, removed
    }

    public struct FileChange: Equatable, Codable, Sendable {
        public var path: String
        public var change: Change
        public var executable: Bool
        public var setuid: Bool
    }

    /// What differs between two archives. Directories are left out: a new
    /// directory only matters for what is in it.
    public static func diff(before: [String: Entry], after: [String: Entry]) -> [FileChange] {
        var changes: [FileChange] = []
        for (path, now) in after where now.kind != .directory {
            let flags = (now.mode & 0o111 != 0 && now.kind == .file, now.mode & 0o6000 != 0)
            if let was = before[path] {
                if was != now {
                    changes.append(FileChange(path: path, change: .modified, executable: flags.0, setuid: flags.1))
                }
            } else {
                changes.append(FileChange(path: path, change: .added, executable: flags.0, setuid: flags.1))
            }
        }
        for (path, was) in before where was.kind != .directory && after[path] == nil {
            changes.append(FileChange(path: path, change: .removed, executable: false, setuid: false))
        }
        return changes.sorted { $0.path < $1.path }
    }
}
