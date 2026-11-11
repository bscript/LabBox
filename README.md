# LabBox

**Try it in a box before it touches your Mac.**

LabBox gives AI agents a throwaway Linux VM on your Mac. Before Claude Code
installs a package or runs a script it doesn't know, it tries it in LabBox
and gets back what the code actually did: servers it called, secrets it went
for, files it changed, processes it left running.

> **Experimental.** It works and is tested, but it's young. See
> [Limits](#limits), and report holes privately as described in
> [SECURITY.md](SECURITY.md).

https://github.com/user-attachments/assets/9b589ba2-ef04-43a3-a2a3-a1b0fc336366

## Why

Agents run code nobody on your team wrote. One bad `postinstall` script can
read your SSH keys and cloud credentials and send them away the moment you
say yes. LabBox runs that code somewhere your keys aren't, and shows you what
it tried.

**Why not Claude Code's own sandbox?** It limits what a command can do, but
the command still runs on your Mac. LabBox moves it to another machine and
watches it. Use both.

| | Claude Code's sandbox | LabBox |
|---|---|---|
| Where code runs | On your Mac, next to your files | In a separate Linux VM |
| Your keys | On the same machine, behind rules | Not there; fake ones are planted as bait |
| Tells you what code tried | No, only allowed or denied | Yes: connections, keys read, files changed |
| If code gets past the rules | It's on your machine | It's in a VM deleted seconds later |

## How it works

<p align="center">
  <img src="docs/labbox-flow.svg" width="100%" alt="Claude Code asks LabBox to try a package. LabBox boots a throwaway Linux VM with fake keys, allows the download from npm, blocks the package's attempt to upload the keys, and sends back a report with 8 flags. The VM is destroyed and Claude advises not to install.">
</p>

- **Claude decides** what to run, through LabBox's MCP tools.
- **LabBox runs it** in a VM with no network card, no shared folders and
  fake keys as bait. Network access goes through a gate on your Mac that
  allows only the hosts you choose and logs every attempt.
- **Only text comes back**: the output and a report, marked untrusted. The
  VM is thrown away.

Details, test results and diagrams: [docs/how-it-works.md](docs/how-it-works.md).

## Quick start

Needs an Apple silicon Mac on macOS 13+, Swift and Go 1.22+.

```bash
./scripts/fetch-alpine.sh && ./scripts/build-guest.sh && ./scripts/build.sh
.build/debug/labbox doctor
claude mcp add --scope user labbox -- "$PWD/.build/debug/labbox" mcp
```

Then add this to your `CLAUDE.md` so Claude reaches for it on its own:

> Before installing or running an unfamiliar package, script or repository,
> try it in LabBox first and read the report.

In Ghostty, a live pane opens beside Claude to show each run as it happens.

## Try the demo

```bash
.build/debug/labbox demo
```

This sets up a sandbox with a harmless package that acts like a credential
stealer. Paste into Claude Code:

```text
A colleague sent me quickpdf-render-demo-1.0.0.tgz for PDF export. It's in /work in the LabBox sandbox "demo". Try installing it into /work/app there and tell me whether it's OK to use.
```

Then, for contrast:

```text
Now do the same check for the npm package is-number.
```

Run `labbox demo` again before each take to reset it.

## Limits

- It shows what code did in one run. Code that waits, or notices it's
  watched, can come out clean. A quiet report never means "safe".
- Linux on ARM only: macOS-only or Windows-only behaviour won't show.
- Commands run as root in the VM, so malware could tamper with the parts of
  the report gathered there. The network log, kept on your Mac, can't be.
- Only web traffic can leave the VM.

## License

Apache 2.0. See [LICENSE](LICENSE).
