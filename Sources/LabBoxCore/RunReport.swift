import Foundation

/// What the guest agent says it saw. Matches traceResult in
/// guest/agent/trace.go. Guest-reported, so treated as a claim, not a fact.
public struct GuestTrace: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var count: Int
        public var exec: Bool?
        public var decoy: Bool?
        public var by: [String]?
    }

    public var entries: [Entry]
    public var filesOpened: Int
    public var leftRunning: [String]
    public var decoysPlaced: [String]
    public var decoysChanged: [String]
    public var incomplete: Bool?

    enum CodingKeys: String, CodingKey {
        case entries, incomplete
        case filesOpened = "files_opened"
        case leftRunning = "left_running"
        case decoysPlaced = "decoys_placed"
        case decoysChanged = "decoys_changed"
    }
    public init(entries: [Entry] = [], filesOpened: Int = 0, leftRunning: [String] = [],
                decoysPlaced: [String] = [], decoysChanged: [String] = [], incomplete: Bool? = nil) {
        self.entries = entries
        self.filesOpened = filesOpened
        self.leftRunning = leftRunning
        self.decoysPlaced = decoysPlaced
        self.decoysChanged = decoysChanged
        self.incomplete = incomplete
    }

    /// Lenient on purpose: a missing or null list is an empty list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        filesOpened = try c.decodeIfPresent(Int.self, forKey: .filesOpened) ?? 0
        leftRunning = try c.decodeIfPresent([String].self, forKey: .leftRunning) ?? []
        decoysPlaced = try c.decodeIfPresent([String].self, forKey: .decoysPlaced) ?? []
        decoysChanged = try c.decodeIfPresent([String].self, forKey: .decoysChanged) ?? []
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete)
    }
}

/// The account of one run. It lists what was observed and never says "safe":
/// a quiet run only means nothing showed up this time.
public struct RunReport: Codable, Equatable, Sendable {
    public struct Network: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int
        public var allowed: Bool
        public var reason: String?
        public var connections: Int
        public var bytesUp: Int
        public var bytesDown: Int
    }

    public struct DecoyRead: Codable, Equatable, Sendable {
        public var path: String
        public var by: [String]
        /// True when the reader is the tool that owns that file (npm and
        /// its own .npmrc).
        public var expected: Bool
        public var changed: Bool
    }

    public struct Files: Codable, Equatable, Sendable {
        public var added: Int
        public var modified: Int
        public var removed: Int
        /// Change counts by top-level directory, e.g. ["work": 41].
        public var byArea: [String: Int]
        /// Changes worth a look: see `RunReport.isNotable`.
        public var notable: [SandboxArchive.FileChange]
        public var notableTruncated: Bool
    }

    public var sandbox: String
    public var command: [String]
    public var exitCode: Int
    public var timedOut: Bool
    public var seconds: Double
    public var stateKept: Bool
    /// One line per thing that deserves attention. Empty is not a verdict.
    public var flags: [String]
    public var network: [Network]
    public var decoyReads: [DecoyRead]
    public var files: Files?
    public var programs: [String]
    public var leftRunning: [String]
    public var filesOpened: Int?
    /// Parts of the report that could not be produced, and why.
    public var gaps: [String]

    public static let maxNotable = 100

    // MARK: Building

    public struct Inputs {
        public var sandbox: String
        public var command: [String]
        public var exitCode: Int
        public var timedOut: Bool
        public var seconds: Double
        public var stateKept: Bool
        public var network: [NetGate.Record]
        public var networkEnabled: Bool
        public var trace: GuestTrace?
        public var changes: [SandboxArchive.FileChange]?
        public var gaps: [String]

        public init(sandbox: String, command: [String], exitCode: Int, timedOut: Bool, seconds: Double,
                    stateKept: Bool, network: [NetGate.Record], networkEnabled: Bool, trace: GuestTrace?,
                    changes: [SandboxArchive.FileChange]?, gaps: [String]) {
            self.sandbox = sandbox
            self.command = command
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.seconds = seconds
            self.stateKept = stateKept
            self.network = network
            self.networkEnabled = networkEnabled
            self.trace = trace
            self.changes = changes
            self.gaps = gaps
        }
    }

    public init(_ input: Inputs) {
        sandbox = input.sandbox
        command = input.command
        exitCode = input.exitCode
        timedOut = input.timedOut
        seconds = (input.seconds * 100).rounded() / 100
        stateKept = input.stateKept
        gaps = input.gaps
        var flags: [String] = []

        // Network: one line per destination and outcome.
        var lines: [String: Network] = [:]
        var order: [String] = []
        for r in input.network {
            let key = "\(r.host):\(r.port):\(r.allowed):\(r.reason ?? "")"
            if lines[key] == nil {
                order.append(key)
                lines[key] = Network(host: r.host, port: r.port, allowed: r.allowed, reason: r.reason,
                                     connections: 0, bytesUp: 0, bytesDown: 0)
            }
            lines[key]!.connections += 1
            lines[key]!.bytesUp += r.bytesUp
            lines[key]!.bytesDown += r.bytesDown
        }
        network = order.map { lines[$0]! }
        for n in network where !n.allowed {
            flags.append("blocked connection to \(n.host):\(n.port) (\(n.reason ?? "refused"))")
        }

        // Guest trace.
        var reads: [DecoyRead] = []
        var programs: [String] = []
        if let trace = input.trace {
            let changed = Set(trace.decoysChanged)
            for e in trace.entries {
                if e.decoy == true {
                    let by = e.by ?? []
                    reads.append(DecoyRead(path: Self.homePath(e.path), by: by,
                                           expected: Self.isExpected(decoy: e.path, readers: by),
                                           changed: changed.contains(e.path)))
                } else if e.exec == true {
                    programs.append(e.path)
                }
            }
            // A decoy altered or deleted without a recorded open still counts.
            for path in trace.decoysChanged where !reads.contains(where: { $0.path == Self.homePath(path) }) {
                reads.append(DecoyRead(path: Self.homePath(path), by: [], expected: false, changed: true))
            }
            for r in reads where !r.expected || r.changed {
                let who = r.by.isEmpty ? "" : " by: " + r.by.joined(separator: "; ")
                flags.append("\(r.changed ? "changed" : "opened") decoy secret \(r.path)\(who)")
            }
            for p in trace.leftRunning { flags.append("left running: \(p)") }
            if trace.incomplete == true { gaps.append("the file trace overflowed; some opens and program starts are missing") }
            leftRunning = trace.leftRunning
            filesOpened = trace.filesOpened
        } else {
            leftRunning = []
            filesOpened = nil
        }
        decoyReads = reads
        self.programs = programs.sorted()

        // File changes.
        if let changes = input.changes {
            var byArea: [String: Int] = [:]
            for c in changes { byArea[Self.area(c.path), default: 0] += 1 }
            let notable = changes.filter(Self.isNotable)
            files = Files(
                added: changes.filter { $0.change == .added }.count,
                modified: changes.filter { $0.change == .modified }.count,
                removed: changes.filter { $0.change == .removed }.count,
                byArea: byArea,
                notable: Array(notable.prefix(Self.maxNotable)),
                notableTruncated: notable.count > Self.maxNotable
            )
            for c in notable.prefix(20) {
                flags.append("\(c.change.rawValue) \(c.setuid ? "setuid " : "")/\(c.path)")
            }
            if notable.count > 20 { flags.append("\(notable.count - 20) more notable file changes") }
        } else {
            files = nil
        }

        if !input.networkEnabled {
            gaps.append("network was off, so nothing could be reached and connection attempts are not listed")
        }
        self.flags = flags
    }

    // MARK: Rules

    /// How a sandbox path is shown to people: "~/.ssh/id_rsa", "/usr/bin/node".
    public static func displayPath(_ sandboxPath: String) -> String { homePath(sandboxPath) }

    static func homePath(_ sandboxPath: String) -> String {
        sandboxPath.hasPrefix("root/") ? "~/" + sandboxPath.dropFirst(5) : "/" + sandboxPath
    }

    static func area(_ path: String) -> String {
        String(path.split(separator: "/", maxSplits: 1).first ?? "")
    }

    public static func isExpectedReader(decoy: String, reader: String) -> Bool {
        isExpected(decoy: decoy, readers: [reader])
    }

    /// npm reads ~/.npmrc on every run, git reads ~/.git-credentials, and so
    /// on. Only a reader that is plainly that tool counts as expected.
    static func isExpected(decoy: String, readers: [String]) -> Bool {
        let owners: [String: [String]] = [
            "root/.npmrc": ["npm", "npx", "pnpm", "yarn"],
            "root/.netrc": ["curl", "wget", "git"],
            "root/.git-credentials": ["git"],
            "root/.docker/config.json": ["docker"],
            "root/.kube/config": ["kubectl"],
        ]
        guard let tools = owners[decoy], !readers.isEmpty else { return false }
        return readers.allSatisfy { reader in
            // "npm install x" or "node /usr/bin/npm install x".
            let words = reader.split(separator: " ").prefix(2).map { $0.split(separator: "/").last.map(String.init) ?? "" }
            return words.contains { tools.contains($0) }
        }
    }

    /// Places where a change means the sandbox will behave differently next
    /// time, or where installers have little business writing.
    static func isNotable(_ c: SandboxArchive.FileChange) -> Bool {
        if c.setuid && c.change != .removed { return true }
        let p = c.path
        let name = p.split(separator: "/").last.map(String.init) ?? p
        // Dotfiles in the home directory that shells and tools load.
        if p.hasPrefix("root/") {
            let startup = [".profile", ".bashrc", ".bash_profile", ".zshrc", ".ashrc", ".gitconfig", ".npmrc", ".netrc"]
            if startup.contains(name) && p.split(separator: "/").count == 2 { return true }
            if p.hasPrefix("root/.ssh/") || p.hasPrefix("root/.config/autostart/") { return true }
        }
        let sensitive = ["etc/passwd", "etc/shadow", "etc/group", "etc/sudoers", "etc/profile", "etc/hosts",
                         "etc/resolv.conf", "etc/ld.so.preload", "etc/inittab", "etc/crontab", "etc/environment"]
        if sensitive.contains(p) { return true }
        let sensitiveDirs = ["etc/profile.d/", "etc/cron", "etc/init.d/", "etc/sudoers.d/", "etc/ssh/",
                             "etc/periodic/", "etc/local.d/", "var/spool/cron/", "etc/systemd/"]
        return sensitiveDirs.contains { p.hasPrefix($0) }
    }

    // MARK: Text

    private static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return bytes < 1_048_576 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Plain text for a terminal. Guest-supplied strings are stripped of
    /// control codes before they are printed.
    public func text() -> String {
        var cleaner = OutputSanitizer()
        func safe(_ s: String) -> String {
            String(decoding: cleaner.clean(Data(s.utf8)), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        }
        var out: [String] = []
        let outcome = timedOut ? "timed out" : "exit \(exitCode)"
        var shown = safe(command.joined(separator: " "))
        if shown.count > 120 { shown = String(shown.prefix(117)) + "..." }
        out.append("LabBox report: \(shown)")
        out.append("  sandbox \(sandbox), \(outcome), \(seconds) s, changes \(stateKept ? "kept" : "discarded")")

        out.append("")
        if flags.isEmpty {
            out.append("Nothing flagged. That is not the same as safe: it covers this run only.")
        } else {
            out.append("Flagged (\(flags.count)):")
            for f in flags { out.append("  ! \(safe(f))") }
        }

        out.append("")
        out.append("Network:")
        if network.isEmpty { out.append("  no connection attempts seen") }
        for n in network {
            let times = n.connections == 1 ? "1 connection" : "\(n.connections) connections"
            if n.allowed {
                out.append("  allowed  \(safe(n.host)):\(n.port)  \(times), \(Self.size(n.bytesDown)) down, \(Self.size(n.bytesUp)) up")
            } else {
                out.append("  BLOCKED  \(safe(n.host)):\(n.port)  \(times)  (\(safe(n.reason ?? "refused")))")
            }
        }

        out.append("")
        out.append("Decoy secrets:")
        if decoyReads.isEmpty { out.append("  none opened") }
        for r in decoyReads {
            let who = r.by.isEmpty ? "unknown process" : r.by.map(safe).joined(separator: "; ")
            let tag = r.changed ? "CHANGED" : (r.expected ? "opened (expected)" : "OPENED")
            out.append("  \(tag)  \(safe(r.path))  by \(who)")
        }

        if let files {
            out.append("")
            out.append("Files: \(files.added) added, \(files.modified) modified, \(files.removed) removed")
            let areas = files.byArea.sorted { $0.value > $1.value }.prefix(8)
            if !areas.isEmpty {
                out.append("  by area: " + areas.map { "/\(safe($0.key)) \($0.value)" }.joined(separator: ", "))
            }
            for c in files.notable.prefix(20) {
                out.append("  notable: \(c.change.rawValue) /\(safe(c.path))\(c.setuid ? "  (setuid)" : "")")
            }
            if files.notable.count > 20 || files.notableTruncated { out.append("  (more notable changes in the JSON report)") }
        }

        if !programs.isEmpty {
            out.append("")
            let names = programs.prefix(30).map { "/" + safe($0) }
            out.append("Programs started (\(programs.count)): " + names.joined(separator: ", ") + (programs.count > 30 ? ", ..." : ""))
        }
        out.append("")
        out.append("Left running: " + (leftRunning.isEmpty ? "nothing" : leftRunning.map(safe).joined(separator: "; ")))

        if !gaps.isEmpty {
            out.append("")
            out.append("Not covered:")
            for g in gaps { out.append("  - \(safe(g))") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
