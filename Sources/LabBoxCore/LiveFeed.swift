import Darwin
import Foundation

/// A running account of what sandboxes are doing, for `labbox watch`.
///
/// Runs append one JSON line per event to a shared file; a watcher follows
/// it. Text is cleaned of terminal control codes before it is written, so
/// the watcher can print it as is. The feed is for people to look at; the
/// report is the record. Every line carries the seconds since its run began,
/// measured on the host when the event arrived.
public struct LiveFeed {
    public struct Line: Codable, Equatable {
        public var run: String
        public var kind: Kind
        public var text: String
        public var t: Double?

        public init(run: String, kind: Kind, text: String, t: Double? = nil) {
            self.run = run
            self.kind = kind
            self.text = text
            self.t = t
        }
    }

    public enum Kind: String, Codable {
        /// Header for a new run.
        case start
        /// A step in getting the VM and sandbox ready, or tearing them down.
        case stage, teardown
        case command, out, err
        /// Seen while the command runs.
        case exec, open, net, blocked
        /// A decoy opened by the tool that owns it, e.g. npm and ~/.npmrc.
        case openExpected
        /// After the command: file summary, flags, final line.
        case files, flag, end
    }

    public static var url: URL { LabBoxPaths.logs.appendingPathComponent("live.jsonl") }
    public static var lockURL: URL { LabBoxPaths.logs.appendingPathComponent("watch.lock") }
    static let maxBytes = 4 << 20

    private let fd: Int32
    private let run: String
    private let started: Date

    /// Nil if the feed cannot be opened; a run carries on without it.
    public init?(started: Date = Date()) {
        try? FileManager.default.createDirectory(at: LabBoxPaths.logs, withIntermediateDirectories: true)
        let fd = open(Self.url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > Self.maxBytes { ftruncate(fd, 0) }
        self.fd = fd
        self.run = String(UUID().uuidString.prefix(8)).lowercased()
        self.started = started
    }

    /// One write per line, so lines from runs happening at once stay whole.
    /// Safe to call from any thread.
    public func emit(_ kind: Kind, _ text: String) {
        var cleaner = OutputSanitizer()
        let safe = String(decoding: cleaner.clean(Data(text.utf8)), as: UTF8.self)
        let line = Line(run: run, kind: kind, text: safe, t: Date().timeIntervalSince(started))
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: Watcher side

    /// Held by `labbox watch` for as long as it runs.
    public static func lockForWatching() -> Int32? {
        try? FileManager.default.createDirectory(at: LabBoxPaths.logs, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func watcherIsRunning() -> Bool {
        guard let fd = lockForWatching() else { return true }
        flock(fd, LOCK_UN)
        close(fd)
        return false
    }

    /// Turns feed lines into terminal text, grouped under "vm", "command"
    /// and "after". Output and events never run together on one line.
    public struct Renderer {
        private enum Section { case none, vm, command, after }

        private var midLine = false
        private var lastStream: Kind?
        private var section = Section.none
        private let color: Bool

        public init(color: Bool = true) {
            self.color = color
        }

        private func paint(_ code: String, _ text: String) -> String {
            color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
        }

        public mutating func render(_ line: Line) -> String {
            if line.kind == .out || line.kind == .err {
                guard !line.text.isEmpty else { return "" }
                var out = ""
                if section != .command {
                    section = .command
                    out += paint("2", "command") + "\n"
                }
                // stdout and stderr are separate streams: do not let one
                // finish the other's line.
                if midLine && lastStream != line.kind { out += "\n" }
                lastStream = line.kind
                midLine = !line.text.hasSuffix("\n")
                return out + (line.kind == .err ? paint("2", line.text) : line.text)
            }

            var out = midLine ? "\n" : ""
            midLine = false
            let text = line.text.replacingOccurrences(of: "\n", with: " ")
            let time = line.t.map { String(format: "%5.2fs", $0) } ?? "      "

            func enter(_ next: Section, _ label: String) {
                guard section != next else { return }
                section = next
                out += paint("2", label) + "\n"
            }

            switch line.kind {
            case .start:
                section = .none
                out += "\n" + paint("1;36", "━━ " + text) + "\n"
            case .stage:
                enter(.vm, "vm")
                out += paint("32", "✓") + " \(time)  \(text)\n"
            case .command:
                enter(.command, "command")
                out += paint("1", "$ " + text) + "\n"
            case .exec:
                enter(.command, "command")
                out += paint("2", "  \(time)  exec   \(text)") + "\n"
            case .open:
                enter(.command, "command")
                out += paint("1;31", "  \(time)  open   \(text)") + "\n"
            case .openExpected:
                enter(.command, "command")
                out += paint("2", "  \(time)  open   \(text)") + "\n"
            case .net:
                enter(.command, "command")
                out += paint("32", "  \(time)  net    \(text)") + "\n"
            case .blocked:
                enter(.command, "command")
                out += paint("1;31", "  \(time)  net    \(text)") + "\n"
            case .files:
                enter(.after, "after")
                out += "  files  \(text)\n"
            case .flag:
                enter(.after, "after")
                out += paint("31", "  !  \(text)") + "\n"
            case .teardown:
                enter(.after, "after")
                out += paint("32", "✓") + " \(time)  \(text)\n"
            case .end:
                out += paint("1;36", "── " + text) + "\n"
            case .out, .err:
                break
            }
            return out
        }
    }
}
