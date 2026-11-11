# How LabBox works

The detail behind the [README](../README.md): how each part is built, what was
tested, and where it falls short.

## The VM

Each run boots a fresh Linux VM with Apple's Virtualization.framework
([VMRunner.swift](../Sources/LabBoxCore/VMRunner.swift)). It gets CPU,
memory, a text console, a control port, a random-number source, one disk
image, and, only with `--allow`, a gated network port.

It gets no network card, no shared folders, no clipboard, no USB and no audio.
Nothing from your home folder is mounted. Each of those is left out on
purpose; adding one should be a reviewed change.

Memory is capped at half the host's and CPUs at the host's count. `--timeout`
kills the command after a set time, and Ctrl-C kills the VM at once. If the
VM ever refuses to stop, the `labbox` process exits and takes the VM with it.

The kernel and ramdisk are Alpine Linux's arm64 netboot files, downloaded
once by `scripts/fetch-alpine.sh`.

## Host and guest

The guest helper ([guest/agent/main.go](../guest/agent/main.go)) is a static
Go binary appended to Alpine's ramdisk and started as PID 1 with
`rdinit=/labbox-agent`. It mounts `/proc`, `/sys` and `/dev`, starts a copy of
itself as the server, reaps orphans, and powers off when the server exits.

Host and guest talk over one virtio console port named `labbox.control`,
backed by two pipes on the host. It is a plain byte stream with no sockets or
addresses. Messages are a 4-byte length plus JSON. The host caps a message at
1 MB, and treats anything that fails to decode as a broken channel and kills
the VM.

vsock was the first plan, but Alpine's stock ramdisk does not carry the vsock
drivers, while the virtio console driver is built into the kernel.

## Sandboxes and snapshots

Each sandbox is a folder under `~/Library/Application Support/LabBox/sandboxes`
holding `disk.img`, a `snapshots/` folder and `meta.json`.

`disk.img` is not a Linux filesystem. It is one tar archive written straight
onto the virtual disk ([state.go](../guest/agent/state.go)). At the start of a
run the helper unpacks it into memory at `/sandbox` and runs commands chrooted
there; at the end it writes the tree back. Alpine's ramdisk has no ext4
driver and no tool to format one, and this needs neither. It also lets macOS
read a sandbox's files without booting it, which is how file changes are
found.

Runs are all-or-nothing. The VM writes to a working copy (`run.img`); only a
clean save renames it over `disk.img`. A kill, crash or failed save drops the
working copy. Snapshot, restore and reset are APFS clones and renames, so
they are instant ([SandboxStore.swift](../Sources/LabBoxCore/SandboxStore.swift)).

## The network gate

There is no network unless you pass `--allow`. Even then the VM gets no
network card.

With `--allow`, the VM gets a second virtio port, `labbox.net`. Inside the
guest the helper runs a small HTTP proxy on `127.0.0.1:3128`
([net.go](../guest/agent/net.go)) and sets the usual proxy variables. Each
connection becomes a request to the host: "open host:port".

The host ([NetGate.swift](../Sources/LabBoxCore/NetGate.swift)) decides:

1. Is the host and port on the allow list
   ([NetPolicy.swift](../Sources/LabBoxCore/NetPolicy.swift))? Ports default
   to 80 and 443.
2. The host looks the name up itself. If any answer is a private, loopback or
   link-local address, the request is refused. No rule can lift this, so a
   sandbox can never reach your Mac or your local network.
3. Only then does the host connect and relay bytes.

Every request is logged on the host, allowed or not, where the guest cannot
edit it.

## The report

`--report` (text) and `--report-json FILE` need a named sandbox
(`--in NAME`). The report has four sources:

| Part | Observed where | Can hostile code tamper with it? |
|---|---|---|
| Network attempts, allowed and blocked | Host | No |
| Files added, modified, removed | Host, comparing the saved archive before and after by SHA-256 ([SandboxArchive.swift](../Sources/LabBoxCore/SandboxArchive.swift)) | Only by writing a false archive, as root |
| Decoy secrets opened or changed | Guest, via fanotify ([trace.go](../guest/agent/trace.go)) | Yes, as root |
| Programs started, processes left running | Guest | Yes, as root |

Decoys are fake key and credential files (`~/.ssh/id_rsa`,
`~/.aws/credentials`, `~/.npmrc` and six more) placed just before the command
and removed just after. They are only placed where the sandbox has no file of
its own, and never reach saved state.

They are made fresh for every run ([decoys.go](../guest/agent/decoys.go)) in
the shape of the real thing: OpenSSH key files, `AKIA...` key pairs,
`ghp_...` and `npm_...` tokens, and so on. Nothing in them is fixed, so the
public source doesn't let malware recognise them by content. The fake npm
token is tied to a registry under `.internal`, so npm never sends it to the
public registry. The VM's hostname is random too.

A line is flagged for: any blocked connection, any decoy opened by something
other than the tool that owns it (npm reading `~/.npmrc` is normal), any
decoy changed, anything left running, and file changes in places that alter
how the system behaves next time (shell start-up files, `/etc/passwd`, cron
and init folders, `~/.ssh`, setuid files). The rules are in
[RunReport.swift](../Sources/LabBoxCore/RunReport.swift). Anything the report
could not cover is listed under "Not covered".

## The MCP server and live pane

`labbox mcp` ([MCPServer.swift](../Sources/LabBoxCore/MCPServer.swift)) speaks
JSON-RPC over stdio and carries out each tool call by running the `labbox`
command itself, so the agent gets exactly the CLI's checks and nothing more.

- The agent can only ask for hosts on the server's list (`--hosts`). The
  default is the common package registries plus GitHub.
- Sandbox runs discard their changes unless the agent sets `keep_changes`.
- The command is passed as a single `sh -c` argument and can never turn into
  LabBox options.
- Every reply marks the sandbox output as untrusted data.

Runs started by the server write to a live feed
([LiveFeed.swift](../Sources/LabBoxCore/LiveFeed.swift)), cleaned of terminal
control codes. Before the first run, the server opens `labbox watch` in a
split beside the agent's terminal: through Ghostty's AppleScript interface
(found by tty), iTerm2's, or `tmux split-window`. Timings in the pane are
measured on the host as each event arrives. Live events are capped at 300 per
run; the report has the full list.

## Decisions

- **Virtualization.framework directly**, not Lima or Tart. Lima controls the
  guest over SSH and mounts the home folder by default, both wrong for hostile
  code. Going direct keeps the device list in our hands.
- **Never a network card.** A virtual card would need a firewall the guest
  could not be trusted to keep, or a full network stack on the host. The gate
  also gives the "which hosts did it call" log for free.
- **Sandbox state as a tar archive on a raw disk**, not ext4. See above.
- **No outside Swift packages.** Go for the guest helper, standard library
  only; it cross-compiles to a static Linux binary with no extra toolchain.
- **arm64 Linux guests only.**

## What was tested

On a real VM, by hand:

- A throwaway run takes about 0.25 s, a sandbox run about 0.4 s.
- Exit codes, separate stdout and stderr, and large or binary output (500,000
  lines, 1 MB of random bytes, checked by checksum).
- Files, modes, symlinks and hard links survive between runs; snapshot, wipe,
  restore brings them back; `--discard` never keeps changes.
- Ctrl-C mid-run leaves the sandbox untouched with nothing left running; a
  second run on a busy sandbox is refused; a full sandbox fails to save and
  stays as it was.
- Network: nothing without `--allow`; with `--allow '*'`, `127.0.0.1`,
  `localhost`, `192.168.1.1`, `10.0.0.1` and `169.254.169.254` are still
  blocked. `apk add nodejs npm` and `npm install` work through the gate.
- Report: the demo package gets 8 flags; `is-number` gets none; tampering
  with `/etc/passwd`, `/etc/profile.d` and setuid bits is flagged.
- MCP: driven over stdio by a test client and from a real Claude Code session.
- Live pane: tested in Ghostty 1.4.0. tmux and iTerm2 support is written but
  untested.

61 unit tests cover config checks, message framing, output cleaning, the
sandbox store, network rules, archive reading, report rules, the MCP server
and the live view. No automated test boots a VM yet.

## Limits

- The report never says "safe". Code that waits, or checks whether it is
  watched, can come out clean.
- Commands run as root in the guest, so hostile code could interfere with the
  guest-side parts of the report and with the saved archive. The network log
  cannot be touched.
- A process that lives a few milliseconds may show as `(exited)`.
- Opens of files that don't exist are not seen; that's why the decoys exist.
- A blank sandbox's first run has nothing to compare files against.
- Only web traffic (HTTP and HTTPS tunnels) can get out. A program that skips
  the proxy simply fails, and that attempt is not logged. For HTTPS the gate
  sees host names and byte counts, not URLs or content.
- A sandbox's files live in memory while it runs, so its size is bounded by
  the VM's memory. The whole state is rewritten at each saved run.
- Each run boots its own VM; there is no long-lived VM to attach to.
- Code can tell it's in a VM: Alpine Linux, proxy settings, no network card,
  the helper as PID 1. LabBox only avoids naming itself in the decoys and
  hostname; it doesn't try to hide the VM.

## Next

1. Run commands as a normal user in the guest.
2. Test the live pane in tmux and iTerm2.
3. A way to copy a project folder in and a diff back out, so an agent can do
   its real work in the sandbox.
4. The Mac app.
