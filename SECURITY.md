# Security

LabBox is a sandbox, so holes in it matter. If you find one, please tell us
privately first.

## Reporting

Use GitHub's private reporting: the **Security** tab of this repository, then
**Report a vulnerability**. Please don't open a public issue for a security
problem.

Include what you ran, what you expected, what happened, and the output of
`labbox doctor`. A small proof of concept helps a lot.

LabBox is an experimental project kept in spare time. Expect a reply within a
week, and a fix or a clear answer as soon as it can be done properly. Once
it's fixed, you're welcome to publish your findings, and we'll credit you if
you'd like.

## What counts

These are in scope, and we want to hear about them:

- Code in a sandbox reaching your Mac: its files, processes or memory.
- Code in a sandbox reaching your Mac's own services or your local network,
  or any host not on the allow list.
- Getting around the network gate, or changing what it logs.
- One sandbox reaching another sandbox's files.
- A run's changes being kept when they should have been thrown away, or the
  other way round.
- Guest output that injects terminal control codes into your terminal, the
  live pane or the report.
- The MCP server letting an agent reach hosts outside its `--hosts` list, or
  run anything other than a command inside the VM.
- A sandbox name, snapshot name or archive entry that reads or writes files
  outside LabBox's folders.

## What doesn't

These are known limits, described in
[docs/how-it-works.md](docs/how-it-works.md#limits):

- Malware that behaves while watched, waits, or notices it's in a VM. The
  report says what was seen; it never says "safe".
- Code running as root inside the VM interfering with the parts of the report
  gathered inside the VM. The network log, kept on the host, is in scope.
- Bugs in Apple's Virtualization.framework or in macOS itself. Report those to
  Apple; we're glad to hear about them too.
