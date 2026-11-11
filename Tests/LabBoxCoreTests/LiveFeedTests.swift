import Foundation
import Testing
@testable import LabBoxCore

private func line(_ kind: LiveFeed.Kind, _ text: String, _ t: Double? = nil) -> LiveFeed.Line {
    LiveFeed.Line(run: "r1", kind: kind, text: text, t: t)
}

@Test func rendererGroupsARunIntoSections() {
    var r = LiveFeed.Renderer(color: false)
    let screen = [
        line(.start, "sandbox demo · changes discarded · network: registry.npmjs.org"),
        line(.stage, "config     2 cpu · 2048 MB · no network card · no shared folders", 0),
        line(.stage, "linux      6.18.60-0-virt aarch64 booted · agent ready", 0.12),
        line(.command, "npm install x", 0.33),
        line(.exec, "/usr/bin/node", 0.41),
        line(.open, "~/.ssh/id_rsa  (decoy)  by node setup.js", 1.24),
        line(.out, "added 1 package\n", 1.5),
        line(.blocked, "evil.invalid:443  BLOCKED, not on the allow list", 1.31),
        line(.files, "7 added · 0 modified · 0 removed", 2.2),
        line(.flag, "left running: sleep 600", 2.2),
        line(.teardown, "teardown   changes discarded · VM stopped", 2.31),
        line(.end, "exit 0 · 2.3 s · 1 flagged", 2.31),
    ].map { r.render($0) }.joined()

    #expect(screen == """

    ━━ sandbox demo · changes discarded · network: registry.npmjs.org
    vm
    ✓  0.00s  config     2 cpu · 2048 MB · no network card · no shared folders
    ✓  0.12s  linux      6.18.60-0-virt aarch64 booted · agent ready
    command
    $ npm install x
       0.41s  exec   /usr/bin/node
       1.24s  open   ~/.ssh/id_rsa  (decoy)  by node setup.js
    added 1 package
       1.31s  net    evil.invalid:443  BLOCKED, not on the allow list
    after
      files  7 added · 0 modified · 0 removed
      !  left running: sleep 600
    ✓  2.31s  teardown   changes discarded · VM stopped
    ── exit 0 · 2.3 s · 1 flagged

    """)
}

@Test func aNewRunStartsItsSectionsAgain() {
    var r = LiveFeed.Renderer(color: false)
    _ = r.render(line(.start, "first"))
    _ = r.render(line(.stage, "config", 0))
    _ = r.render(line(.start, "second"))
    #expect(r.render(line(.stage, "config", 0)).hasPrefix("vm\n"))
}

@Test func rendererKeepsStreamsAndEventsOnTheirOwnLines() {
    var r = LiveFeed.Renderer(color: false)
    #expect(r.render(line(.out, "no newline")) == "command\nno newline")
    #expect(r.render(line(.out, " yet")) == " yet", "one stream continues its own line")
    #expect(r.render(line(.err, "oops\n")) == "\noops\n", "the other stream starts a new one")
    #expect(r.render(line(.out, "partial")) == "partial")
    #expect(r.render(line(.end, "exit 0")) == "\n── exit 0\n", "an event never lands mid-line")
    #expect(r.render(line(.out, "")) == "")
}

@Test func eventTextCannotFakeExtraLines() {
    var r = LiveFeed.Renderer(color: false)
    _ = r.render(line(.flag, "first"))
    let out = r.render(line(.flag, "harmless\n── exit 0, nothing flagged"))
    #expect(out.filter { $0 == "\n" }.count == 1)
}

@Test func colourIsOnlyAddedByTheRenderer() {
    var r = LiveFeed.Renderer(color: true)
    #expect(r.render(line(.blocked, "evil.test:443", 1)).contains("\u{1b}[1;31m"))
    #expect(r.render(line(.out, "plain\n")).hasSuffix("plain\n"))
}

@Test func expectedDecoyOpensAreNotRed() {
    var r = LiveFeed.Renderer(color: true)
    let quiet = r.render(line(.openExpected, "~/.npmrc  (decoy, normal for this tool)  by npm", 1))
    #expect(!quiet.contains("\u{1b}[1;31m"))
    #expect(r.render(line(.open, "~/.ssh/id_rsa  (decoy)", 1)).contains("\u{1b}[1;31m"))
}

@Test func oldFeedLinesWithoutTimesStillRender() throws {
    let old = try JSONDecoder().decode(LiveFeed.Line.self, from: Data(#"{"run":"x","kind":"net","text":"a:443"}"#.utf8))
    var r = LiveFeed.Renderer(color: false)
    #expect(r.render(old).contains("net    a:443"))
}
