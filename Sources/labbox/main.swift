import Foundation
import LabBoxCore

let usage = """
labbox: run Linux sandboxes on this Mac

USAGE
  labbox doctor
  labbox create NAME [--disk-mb N]
  labbox list
  labbox run [--in NAME] [--discard] [--allow HOST]... [--report]
             [--report-json FILE] [--raw] [options] -- COMMAND [ARGS...]
  labbox snapshot NAME SNAPSHOT
  labbox restore NAME SNAPSHOT
  labbox reset NAME
  labbox delete NAME
  labbox boot [options]
  labbox mcp [--hosts HOST,HOST,...] [--pane auto|off]
  labbox watch
  labbox demo [--rebuild]

  run       boots a VM, runs COMMAND in it through the guest agent, prints
            its output and exits with its exit code.
            Without --in the VM is blank and thrown away afterwards.
            With --in NAME the sandbox's files are loaded first and saved
            back when the command ends. If the run is killed or the save
            fails, the sandbox stays as it was before the run.
            --discard   with --in: never save, whatever happens
            --allow HOST[:PORT]   let the sandbox reach this host through
                        LabBox's gate. Repeat for more hosts. *.HOST covers
                        subdomains; '*' allows any public host (still logged).
                        Ports default to 80 and 443. Without --allow there is
                        no network at all. Private and local addresses are
                        always blocked. A summary of every attempt is printed
                        when the run ends.
            --report    with --in: watch the command and print what it did
                        when it ends: network attempts, decoy secrets it
                        opened, files it changed, programs it started and
                        anything it left running
            --report-json FILE    the same report as JSON, for other tools
            --raw       do not strip terminal control codes from output
            Exit 124 means the time limit hit; 125 means LabBox itself failed.
  snapshot  keeps a named copy of the sandbox's state
  restore   puts a snapshot back as the sandbox's state
  reset     back to a blank sandbox (snapshots are kept)
  delete    removes the sandbox and its snapshots
  mcp       serves LabBox to an AI agent over the Model Context Protocol
            (stdio). --hosts sets which hosts the agent may ask to reach;
            the default is the common package registries and GitHub.
            --pane auto (the default) opens a split pane beside the agent
            showing each run live, in Ghostty, iTerm2 or tmux.
  watch     follows what sandboxes are doing, live: commands, output,
            network decisions and flags. Read-only. Ctrl-C to stop.
  demo      sets up (or resets) a sandbox called "demo" for showing LabBox
            to people: Node, npm, and a harmless package that behaves like a
            credential stealer. Prints the prompts to use in Claude Code.
  boot      boots Alpine's stock ramdisk with the console on this terminal
            (a rescue shell; for debugging the VM itself)

OPTIONS (run and boot)
  --kernel PATH     arm64 Linux kernel Image   (default: downloaded Alpine)
  --initrd PATH     initial ramdisk
  --disk PATH       raw disk image to attach   (not with --in)
  --read-only       attach the disk read-only
  --cpus N          virtual CPUs               (default: 2)
  --memory MB       memory in MB               (default: 2048)
  --cmdline STR     kernel command line
  --timeout SEC     time limit for the command (run) or the VM (boot)

The VM has no network card and sees none of your files.
Ctrl-C kills it.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data(("[labbox] " + message + "\n").utf8))
}

/// Runs a store operation, turning its errors into a clean message.
func attempt<T>(_ work: () throws -> T) -> T {
    do { return try work() } catch { fail("\(error)", code: 1) }
}

func megabytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    return bytes < 1_048_576 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func parseBoot(_ args: [String], base: SandboxConfig? = nil) -> SandboxConfig {
    var config = base ?? SandboxConfig(kernel: LabBoxPaths.defaultKernel, initrd: LabBoxPaths.defaultInitrd)
    var explicitKernel = false
    var explicitInitrd = false
    var i = 0

    func value(for flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value") }
        return args[i]
    }
    func number(for flag: String) -> Int {
        let raw = value(for: flag)
        guard let n = Int(raw) else { fail("\(flag) needs a whole number, got \(raw)") }
        return n
    }
    func file(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    while i < args.count {
        switch args[i] {
        case "--kernel": config.kernel = file(value(for: "--kernel")); explicitKernel = true
        case "--initrd": config.initrd = file(value(for: "--initrd")); explicitInitrd = true
        case "--disk": config.disk = file(value(for: "--disk"))
        case "--read-only": config.diskReadOnly = true
        case "--cpus": config.cpus = number(for: "--cpus")
        case "--memory": config.memoryMB = number(for: "--memory")
        case "--cmdline": config.commandLine = value(for: "--cmdline")
        case "--timeout": config.timeoutSeconds = number(for: "--timeout")
        default: fail("unknown option \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    // A custom kernel should not silently pick up the default ramdisk.
    if explicitKernel && !explicitInitrd { config.initrd = nil }
    return config
}

func doctor() -> Never {
    let checks = Doctor.run()
    for c in checks {
        print("\(c.ok ? "ok  " : "FAIL")  \(c.name): \(c.detail)")
    }
    exit(checks.allSatisfy(\.ok) ? 0 : 1)
}

func boot(_ args: [String]) -> Never {
    let config = parseBoot(args)
    let runner: VMRunner
    do {
        runner = try VMRunner(
            config: config,
            input: .standardInput,
            output: .standardOutput
        ) { exitReason in
            switch exitReason {
            case .guestStopped:
                note("guest shut down")
                exit(0)
            case let .killed(reason):
                note("killed: \(reason)")
                exit(124)
            case let .failed(error):
                note("VM failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    } catch {
        fail("cannot boot:\n\(error)", code: 1)
    }

    // Ctrl-C and `kill` both end the VM. If the VM will not stop, the process
    // exit that follows ends it anyway.
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { runner.kill(reason: "signal \(sig)") }
        source.resume()
        sources.append(source)
    }

    note("booting: \(config.cpus) cpu, \(config.memoryMB) MB, network off, no shared folders")
    runner.start()
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: run

/// Request ids used by `run`.
enum Step {
    static let exec = 1
    static let mount = 2
    static let save = 3
    static let trace = 4
}

/// State shared by the callbacks of one `run`. Main queue only.
final class RunState {
    var exitCode: Int32?
    var commandCode: Int32?
    var ready = false
    var stdout = OutputSanitizer()
    var stderr = OutputSanitizer()
    var timedOut = false
    var trace: GuestTrace?
    var gaps: [String] = []
    var report: RunReport?
    var kept = false
    let started = Date()
}

/// Pulls `--flag VALUE` out of an argument list.
func take(_ flag: String, from args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
    guard args.contains(flag) else { return false }
    args.removeAll { $0 == flag }
    return true
}

func run(_ args: [String]) -> Never {
    guard let split = args.firstIndex(of: "--"), split + 1 < args.count else {
        fail("run needs a command after --\n\n\(usage)")
    }
    var options = Array(args[..<split])
    let command = Array(args[(split + 1)...])
    let raw = takeFlag("--raw", from: &options)
    let discard = takeFlag("--discard", from: &options)
    let sandboxName = take("--in", from: &options)
    var allowRules: [String] = []
    while let rule = take("--allow", from: &options) { allowRules.append(rule) }
    let policy = attempt { try NetPolicy(parsing: allowRules) }
    let reportText = takeFlag("--report", from: &options)
    let reportFile = take("--report-json", from: &options)
    let feed = takeFlag("--feed", from: &options) ? LiveFeed() : nil
    let reporting = reportText || reportFile != nil
    if reporting && sandboxName == nil { fail("--report needs a sandbox: add --in NAME (with --discard to keep it unchanged)") }

    var config = parseBoot(options, base: SandboxConfig(
        kernel: LabBoxPaths.defaultKernel,
        initrd: LabBoxPaths.agentInitrd,
        commandLine: "console=hvc0 rdinit=/labbox-agent loglevel=4"
    ))
    if discard && sandboxName == nil { fail("--discard only makes sense with --in NAME") }
    if sandboxName != nil && config.disk != nil { fail("--disk cannot be combined with --in") }

    let session: SandboxStore.RunSession? = sandboxName.map { name in
        attempt { try SandboxStore().beginRun(name) }
    }
    if let session { config.disk = session.workingDisk }

    var gate: NetGate?
    let state = RunState()

    /// Every exit goes through here so an unsaved run is always rolled back
    /// and the report (or at least the network summary) is always shown.
    func end(_ code: Int32) -> Never {
        session?.abort()
        if let feed {
            if let files = state.report?.files {
                feed.emit(.files, "\(files.added) added · \(files.modified) modified · \(files.removed) removed")
            }
            for flag in state.report?.flags ?? [] { feed.emit(.flag, flag) }
            let kept = sandboxName == nil ? "nothing kept" : (state.kept ? "changes kept" : "changes discarded")
            feed.emit(.teardown, "teardown   \(kept) · VM stopped")
            let took = String(format: "%.1f s", Date().timeIntervalSince(state.started))
            let flagged = state.report.map { $0.flags.isEmpty ? " · nothing flagged" : " · \($0.flags.count) flagged" } ?? ""
            feed.emit(.end, "exit \(code) · \(took)\(flagged)")
        }
        if let report = state.report {
            if reportText { FileHandle.standardError.write(Data(("\n" + report.text()).utf8)) }
            if let reportFile {
                do {
                    try report.json().write(to: URL(fileURLWithPath: (reportFile as NSString).expandingTildeInPath), options: .atomic)
                } catch {
                    note("could not write report to \(reportFile): \(error.localizedDescription)")
                }
            }
        } else {
            if reporting { note("no report: the run ended before it could be made") }
            if let gate { reportNetwork(gate.records()) }
        }
        exit(code)
    }

    // The command gets the time the user asked for; the VM gets more, so the
    // agent can report the timeout (and save) before the hard kill.
    let commandTimeout = config.timeoutSeconds
    if let t = commandTimeout, t > 0 { config.timeoutSeconds = t + (session == nil ? 10 : 120) }

    // Kernel and agent messages go to a log file, never to the terminal.
    let logURL = LabBoxPaths.logs.appendingPathComponent("last-console.log")
    try? FileManager.default.createDirectory(at: LabBoxPaths.logs, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    guard let consoleOut = FileHandle(forWritingAtPath: logURL.path),
          let consoleIn = FileHandle(forReadingAtPath: "/dev/null") else {
        note("cannot open console log at \(logURL.path)")
        end(125)
    }

    let runner: VMRunner
    do {
        runner = try VMRunner(
            config: config,
            input: consoleIn,
            output: consoleOut,
            controlChannel: true,
            networkPort: !policy.rules.isEmpty
        ) { exitReason in
            if let code = state.exitCode { end(code) }
            switch exitReason {
            case .guestStopped: note("VM stopped before the command finished; see \(logURL.path)")
            case let .killed(reason): note("killed: \(reason)"); end(124)
            case let .failed(error): note("VM failed: \(error.localizedDescription)")
            }
            end(125)
        }
    } catch {
        note("cannot boot:\n\(error)")
        end(125)
    }

    func finish(_ code: Int32, _ why: String) {
        guard state.exitCode == nil else { return }
        state.exitCode = code
        runner.kill(reason: why)
    }

    guard let channel = runner.channel else { note("no control channel"); end(125) }
    if let pipes = runner.networkPipes {
        let g = NetGate(policy: policy, toGuest: pipes.toGuest, fromGuest: pipes.fromGuest)
        if let feed {
            g.onDecision = { host, port, allowed, reason in
                feed.emit(allowed ? .net : .blocked, "\(host):\(port)  " + (allowed ? "allowed" : "BLOCKED, \(reason ?? "refused")"))
            }
        }
        g.start()
        gate = g
    }

    func send(_ request: GuestRequest) {
        do {
            try channel.send(request)
        } catch {
            note("cannot reach guest agent: \(error.localizedDescription)")
            finish(125, "send failed")
        }
    }
    // "sh -c <script>" reads better as just the script.
    let shownCommand: String = {
        let text = command.count == 3 && command[0] == "sh" && command[1] == "-c" ? command[2] : command.joined(separator: " ")
        return text.count > 300 ? String(text.prefix(297)) + "..." : text
    }()
    if let feed {
        let place = sandboxName.map { "sandbox \($0) · changes \(discard ? "discarded" : "kept")" } ?? "blank VM · nothing kept"
        let net = allowRules.isEmpty ? "network off" : "network: " + allowRules.joined(separator: ", ")
        feed.emit(.start, "\(place) · \(net)")
        feed.emit(.stage, "config     \(config.cpus) cpu · \(config.memoryMB) MB · no network card · no shared folders")
    }

    func startCommand() {
        feed?.emit(.command, shownCommand)
        send(GuestRequest(id: Step.exec, op: "exec", argv: command, timeoutMs: commandTimeout.map { $0 * 1000 }))
    }

    channel.onBroken = { problem in
        note("guest broke protocol: \(problem)")
        finish(125, "protocol error")
    }
    channel.onEvent = { event in
        switch (event.event, event.id) {
        case ("ready", _):
            guard event.version == GuestProtocol.version else {
                note("guest agent speaks protocol \(event.version ?? -1), host speaks \(GuestProtocol.version); rerun scripts/build-guest.sh")
                return finish(125, "version mismatch")
            }
            state.ready = true
            feed?.emit(.stage, "linux      \(event.kernel ?? "kernel") booted · agent ready")
            if session != nil {
                send(GuestRequest(id: Step.mount, op: "mount_state", watch: reporting ? true : nil,
                                  live: reporting && feed != nil ? true : nil))
            } else {
                startCommand()
            }

        case ("state", Step.mount):
            if let problem = event.error, !problem.isEmpty {
                note("cannot load sandbox: \(problem)")
                return finish(125, "state load failed")
            }
            if let feed {
                let count = (event.files ?? 0).formatted()
                let size = megabytes(event.bytes ?? 0)
                feed.emit(.stage, event.created == true
                    ? "sandbox    new, filled with Alpine: \(count) files, \(size)"
                    : "sandbox    loaded: \(count) files, \(size)")
                if reporting {
                    feed.emit(.stage, "decoys     \(event.decoys ?? 0) fake secrets planted in ~")
                    feed.emit(.stage, "watching   file opens · program starts · network")
                }
            }
            startCommand()

        case ("seen", Step.mount):
            guard let feed, let path = event.path else { return }
            if event.what == "open" {
                let by = event.by ?? ""
                let expected = !by.isEmpty && RunReport.isExpectedReader(decoy: path, reader: by)
                feed.emit(expected ? .openExpected : .open,
                          "\(RunReport.displayPath(path))  (decoy\(expected ? ", normal for this tool" : ""))" + (by.isEmpty ? "" : "  by \(by)"))
            } else {
                feed.emit(.exec, RunReport.displayPath(path))
            }

        case ("stdout", Step.exec):
            guard let data = event.data else { return }
            feed?.emit(.out, String(decoding: data, as: UTF8.self))
            FileHandle.standardOutput.write(raw ? data : state.stdout.clean(data))

        case ("stderr", Step.exec):
            guard let data = event.data else { return }
            feed?.emit(.err, String(decoding: data, as: UTF8.self))
            FileHandle.standardError.write(raw ? data : state.stderr.clean(data))

        case ("exit", Step.exec):
            if let problem = event.error, !problem.isEmpty { note("guest: \(problem)") }
            let code: Int32
            if event.timedOut == true {
                note("command hit the time limit of \(commandTimeout ?? 0)s")
                code = 124
            } else {
                // Exit codes are one byte; anything else from the guest is bogus.
                code = event.code.flatMap { (0...255).contains($0) ? Int32($0) : nil } ?? 125
            }
            state.commandCode = code
            state.timedOut = event.timedOut == true
            if reporting {
                send(GuestRequest(id: Step.trace, op: "trace_stop"))
            } else if session != nil, !discard {
                send(GuestRequest(id: Step.save, op: "save_state"))
            } else {
                finish(code, "command finished")
            }

        case ("trace", Step.trace):
            if let problem = event.error, !problem.isEmpty {
                state.gaps.append("the guest could not trace this run (\(problem)), so decoys, programs and leftover processes are missing")
            } else {
                state.trace = event.trace
            }
            // Saved even with --discard: the host compares it with the
            // earlier state to see which files changed. It is only kept
            // if the run is committed.
            send(GuestRequest(id: Step.save, op: "save_state"))

        case ("state", Step.save):
            guard let session, let code = state.commandCode else { return }
            let saveProblem = event.error.flatMap { $0.isEmpty ? nil : $0 }

            var changes: [SandboxArchive.FileChange]?
            if reporting {
                if let saveProblem {
                    state.gaps.append("the sandbox could not be saved (\(saveProblem)), so file changes are unknown")
                } else {
                    do {
                        let before = try SandboxArchive.index(session.savedDisk)
                        if before.isEmpty {
                            state.gaps.append("this was the sandbox's first run, so there is no earlier state to compare files against")
                        } else {
                            changes = SandboxArchive.diff(before: before, after: try SandboxArchive.index(session.workingDisk))
                        }
                    } catch {
                        state.gaps.append("file changes are unknown: \(error)")
                    }
                }
            }

            var kept = false
            var failure: String?
            if let saveProblem {
                if !discard { failure = "could not save sandbox state (\(saveProblem)); the sandbox is as it was before this run" }
            } else if !discard {
                do {
                    try session.commit()
                    kept = true
                    state.kept = true
                } catch {
                    failure = "\(error); the sandbox is as it was before this run"
                }
            }

            if reporting {
                state.report = RunReport(.init(
                    sandbox: sandboxName ?? "", command: command, exitCode: Int(code), timedOut: state.timedOut,
                    seconds: Date().timeIntervalSince(state.started), stateKept: kept,
                    network: gate?.records() ?? [], networkEnabled: gate != nil,
                    trace: state.trace, changes: changes, gaps: state.gaps
                ))
            }
            if let failure {
                note(failure)
                return finish(125, "state save failed")
            }
            finish(code, "command finished")

        default:
            break
        }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        guard !state.ready else { return }
        note("guest agent did not come up in 20s; see \(logURL.path)")
        finish(125, "agent not ready")
    }

    signal(SIGPIPE, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { finish(130, "signal \(sig)") }
        source.resume()
        sources.append(source)
    }

    runner.start()
    withExtendedLifetime(sources) { dispatchMain() }
}

/// One line per destination: what was reached, what was refused and why.
func reportNetwork(_ records: [NetGate.Record]) {
    guard !records.isEmpty else { return note("network: no connection attempts") }
    struct Line { var count = 0, up = 0, down = 0 }
    var order: [String] = []
    var lines: [String: Line] = [:]
    for r in records {
        let key = r.allowed ? "allowed  \(r.host):\(r.port)" : "BLOCKED  \(r.host):\(r.port)  (\(r.reason ?? "refused"))"
        if lines[key] == nil { order.append(key) }
        lines[key, default: Line()].count += 1
        lines[key]!.up += r.bytesUp
        lines[key]!.down += r.bytesDown
    }
    note("network:")
    for key in order {
        let l = lines[key]!
        let times = l.count == 1 ? "1 connection" : "\(l.count) connections"
        let traffic = key.hasPrefix("allowed") ? ", \(megabytes(l.down)) down, \(megabytes(l.up)) up" : ""
        // Host names come from the guest; keep them from drawing on the terminal.
        var cleaner = OutputSanitizer()
        let safe = String(decoding: cleaner.clean(Data(key.utf8)), as: UTF8.self)
        FileHandle.standardError.write(Data("  \(safe)  \(times)\(traffic)\n".utf8))
    }
}

// MARK: sandbox commands

func create(_ args: [String]) {
    var rest = args
    let diskMB = take("--disk-mb", from: &rest).map { raw -> Int in
        guard let n = Int(raw) else { fail("--disk-mb needs a whole number, got \(raw)") }
        return n
    }
    guard rest.count == 1 else { fail("usage: labbox create NAME [--disk-mb N]") }
    let meta = attempt { try SandboxStore().create(rest[0], diskMB: diskMB ?? SandboxStore.defaultDiskMB) }
    print("created \(meta.name) (state limit \(meta.diskMB) MB)")
}

func list() {
    let all = SandboxStore().list()
    guard !all.isEmpty else { return print("no sandboxes; make one with: labbox create NAME") }
    for info in all {
        let state = info.hasState ? megabytes(info.bytesOnDisk) : "blank"
        let snaps = info.snapshots.isEmpty ? "" : "  snapshots: " + info.snapshots.joined(separator: ", ")
        print("\(info.meta.name)  \(state)\(snaps)")
    }
}

func twoNames(_ args: [String], _ verb: String) -> (String, String) {
    guard args.count == 2 else { fail("usage: labbox \(verb) NAME SNAPSHOT") }
    return (args[0], args[1])
}

func oneName(_ args: [String], _ verb: String) -> String {
    guard args.count == 1 else { fail("usage: labbox \(verb) NAME") }
    return args[0]
}

// MARK: mcp

/// Runs this same binary with the given arguments and collects its output.
func launchSelf(_ arguments: [String]) -> MCPServer.Launched {
    guard let me = Bundle.main.executableURL else {
        return .init(status: 125, stdout: Data(), stderr: Data("cannot find the labbox binary".utf8))
    }
    let process = Process()
    process.executableURL = me
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .init(status: 125, stdout: Data(), stderr: Data("cannot start labbox: \(error.localizedDescription)".utf8))
    }
    // Our copies of the write ends must go, or the reads below never end.
    try? out.fileHandleForWriting.close()
    try? err.fileHandleForWriting.close()

    var outData = Data()
    var errData = Data()
    let readers = DispatchGroup()
    DispatchQueue.global().async(group: readers) { outData = out.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: readers) { errData = err.fileHandleForReading.readDataToEndOfFile() }
    process.waitUntilExit()
    readers.wait()
    return .init(status: process.terminationStatus, stdout: outData, stderr: errData)
}

// MARK: watch and the split pane

func watch(_ args: [String]) -> Never {
    var rest = args
    let untilPid = take("--until-pid", from: &rest).flatMap { Int32($0) }
    // Prints a saved feed the way the pane would, then exits. For checking
    // and rehearsing; not listed in the usage text.
    if let replay = take("--replay", from: &rest) {
        guard let data = FileManager.default.contents(atPath: (replay as NSString).expandingTildeInPath) else {
            fail("cannot read \(replay)", code: 1)
        }
        var renderer = LiveFeed.Renderer(color: isatty(STDOUT_FILENO) == 1)
        for raw in data.split(separator: 0x0a) {
            if let line = try? JSONDecoder().decode(LiveFeed.Line.self, from: raw) {
                FileHandle.standardOutput.write(Data(renderer.render(line).utf8))
            }
        }
        exit(0)
    }
    guard rest.isEmpty else { fail("usage: labbox watch") }
    guard let lock = LiveFeed.lockForWatching() else {
        print("labbox watch is already running in another pane or window.")
        exit(0)
    }
    defer { close(lock) }

    // Make sure the feed exists without disturbing one that does.
    close(open(LiveFeed.url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600))
    guard let handle = FileHandle(forReadingAtPath: LiveFeed.url.path) else { fail("cannot open \(LiveFeed.url.path)", code: 1) }
    var offset = (try? handle.seekToEnd()) ?? 0
    var pending = Data()
    let color = isatty(STDOUT_FILENO) == 1
    var renderer = LiveFeed.Renderer(color: color)
    setvbuf(stdout, nil, _IONBF, 0)
    let banner = "LabBox live view. Read-only: sandbox commands, output, network decisions and flags appear here. Ctrl-C to close."
    print(color ? "\u{1b}[2m\(banner)\u{1b}[0m" : banner)

    while true {
        let size = (try? handle.seekToEnd()) ?? offset
        if size < offset { offset = 0 } // the feed was trimmed
        if size > offset {
            try? handle.seek(toOffset: offset)
            pending.append((try? handle.read(upToCount: Int(size - offset))) ?? Data())
            offset = size
            while let newline = pending.firstIndex(of: 0x0a) {
                let raw = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                if let line = try? JSONDecoder().decode(LiveFeed.Line.self, from: raw) {
                    FileHandle.standardOutput.write(Data(renderer.render(line).utf8))
                }
            }
        }
        // Opened for one agent session: leave when that session's server does.
        if let untilPid, kill(untilPid, 0) != 0, errno == ESRCH { exit(0) }
        usleep(80_000)
    }
}

/// The terminal device this process (or the nearest ancestor that has one)
/// is attached to, e.g. "/dev/ttys003".
func controllingTTY() -> String? {
    var pid = getpid()
    for _ in 0..<8 {
        let found = launchTool("/bin/ps", ["-o", "tty=,ppid=", "-p", String(pid)])
        let fields = found.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count == 2, let parent = Int32(fields[1]) else { return nil }
        if fields[0].hasPrefix("ttys") { return "/dev/" + fields[0] }
        guard parent > 1 else { return nil }
        pid = parent
    }
    return nil
}

@discardableResult
func launchTool(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Opens `labbox watch` in a split beside the agent's terminal, if there is
/// no watcher yet and the terminal can be scripted. Failing is fine: the
/// run goes ahead without a live view.
func openWatchPane() {
    guard !LiveFeed.watcherIsRunning(), let me = Bundle.main.executableURL?.path else { return }
    // Only letters, digits and a few safe marks may reach a shell or script.
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
    guard me.unicodeScalars.allSatisfy(safe.contains) else {
        return note("live pane skipped: the labbox path has characters that are not safe to pass to a terminal")
    }
    let command = "\(me) watch --until-pid \(getpid())"
    let env = ProcessInfo.processInfo.environment

    if env["TMUX"] != nil {
        launchTool("/usr/bin/env", ["tmux", "split-window", "-h", "-d", "-l", "45%", command])
    } else if let tty = controllingTTY() {
        switch env["TERM_PROGRAM"] {
        case "ghostty":
            launchTool("/usr/bin/osascript", ["-e", """
                tell application "Ghostty"
                    repeat with t in terminals
                        if tty of t is "\(tty)" then
                            set cfg to new surface configuration
                            set command of cfg to "\(command)"
                            split t direction right with configuration cfg
                            focus t
                            return
                        end if
                    end repeat
                end tell
                """])
        case "iTerm.app":
            launchTool("/usr/bin/osascript", ["-e", """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            repeat with s in sessions of tb
                                if tty of s is "\(tty)" then
                                    tell s to split vertically with default profile command "\(command)"
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """])
        default:
            return
        }
    } else {
        return
    }
    // Give the watcher a moment to start, so it sees the run from the top.
    for _ in 0..<30 where !LiveFeed.watcherIsRunning() { usleep(50_000) }
}

func mcp(_ args: [String]) -> Never {
    var rest = args
    let hosts = take("--hosts", from: &rest).map { $0.split(separator: ",").map { String($0) } }
    let pane = take("--pane", from: &rest) ?? "auto"
    guard rest.isEmpty, ["auto", "off"].contains(pane) else { fail("usage: labbox mcp [--hosts HOST,HOST,...] [--pane auto|off]") }
    let config = MCPServer.Config(allowedHosts: hosts ?? MCPServer.defaultHosts, liveFeed: true)
    let server = attempt { try MCPServer(config: config, launch: launchSelf) }
    if pane == "auto" { server.beforeRun = openWatchPane }

    // stdout carries protocol messages only; anything else goes to stderr.
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let reply = server.handle(line: line) else { continue }
        print(reply)
    }
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
let rest = Array(args.dropFirst())
switch args.first {
case "doctor": doctor()
case "run": run(rest)
case "boot": boot(rest)
case "mcp": mcp(rest)
case "watch": watch(rest)
case "demo": demo(rest)
case "create": create(rest)
case "list": list()
case "snapshot":
    let (name, snap) = twoNames(rest, "snapshot")
    attempt { try SandboxStore().snapshot(name, as: snap) }
    print("snapshot '\(snap)' of \(name) saved")
case "restore":
    let (name, snap) = twoNames(rest, "restore")
    attempt { try SandboxStore().restore(name, from: snap) }
    print("\(name) restored to '\(snap)'")
case "reset":
    let name = oneName(rest, "reset")
    attempt { try SandboxStore().reset(name) }
    print("\(name) reset to blank")
case "delete":
    let name = oneName(rest, "delete")
    attempt { try SandboxStore().delete(name) }
    print("\(name) deleted")
case nil, "help", "-h", "--help": print(usage)
default: fail("unknown command \(args[0])\n\n\(usage)")
}
