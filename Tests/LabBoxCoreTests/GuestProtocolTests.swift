import Foundation
import Testing
@testable import LabBoxCore

private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Test func frameRoundTrip() throws {
    var decoder = FrameDecoder()
    let frames = try decoder.feed(Frame.encode(bytes("hello")) + Frame.encode(bytes("world!")))
    #expect(frames == [bytes("hello"), bytes("world!")])
}

@Test func framesSurviveBeingSplitAnywhere() throws {
    let stream = Frame.encode(bytes("first")) + Frame.encode(bytes("second"))
    for cut in 0...stream.count {
        var decoder = FrameDecoder()
        var got = try decoder.feed(stream.prefix(cut))
        got += try decoder.feed(stream.suffix(stream.count - cut))
        #expect(got == [bytes("first"), bytes("second")], "cut at \(cut)")
    }
}

@Test func oversizedFrameIsRefused() {
    var decoder = FrameDecoder()
    #expect(throws: Frame.Problem.badSize(0x7fff_ffff)) {
        try decoder.feed(Data([0x7f, 0xff, 0xff, 0xff, 1, 2, 3]))
    }
}

@Test func emptyFrameIsRefused() {
    var decoder = FrameDecoder()
    #expect(throws: Frame.Problem.badSize(0)) {
        try decoder.feed(Data([0, 0, 0, 0]))
    }
}

@Test func requestUsesTheAgentsFieldNames() throws {
    let request = GuestRequest(id: 7, op: "exec", argv: ["ls", "-l"], timeoutMs: 1500)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(json?["timeout_ms"] as? Int == 1500)
    #expect(json?["argv"] as? [String] == ["ls", "-l"])
    #expect(json?["stdin"] == nil)
}

@Test func eventDecodesAgentJSON() throws {
    let exit = try JSONDecoder().decode(GuestEvent.self, from: bytes(#"{"id":1,"event":"exit","code":3,"timed_out":true}"#))
    #expect(exit.code == 3)
    #expect(exit.timedOut == true)
    let out = try JSONDecoder().decode(GuestEvent.self, from: bytes(#"{"id":1,"event":"stdout","data":"aGkK"}"#))
    #expect(out.data == bytes("hi\n"))
}

@Test func sanitizerKeepsTextAndDropsControlCodes() {
    var s = OutputSanitizer()
    #expect(s.clean(bytes("plain\ttext\n")) == bytes("plain\ttext\n"))
    // Colour, window title, clipboard write, bell, carriage return, delete.
    #expect(s.clean(bytes("\u{1b}[31mred\u{1b}[0m")) == bytes("[31mred[0m"))
    #expect(s.clean(bytes("\u{1b}]0;title\u{07}x")) == bytes("]0;titlex"))
    #expect(s.clean(bytes("safe\rEVIL\u{7f}")) == bytes("safeEVIL"))
}

@Test func sanitizerKeepsUTF8ButDropsC1Controls() {
    var s = OutputSanitizer()
    #expect(s.clean(bytes("café ✓")) == bytes("café ✓"))
    // U+009B is the one-character form of ESC [.
    #expect(s.clean(bytes("a\u{9b}31mb")) == bytes("a31mb"))
    // The two bytes of a C1 control arriving in separate chunks.
    #expect(s.clean(Data([0x61, 0xc2])) == bytes("a"))
    #expect(s.clean(Data([0x9b, 0x62])) == bytes("b"))
    // 0xC2 that starts a normal character is kept.
    #expect(s.clean(Data([0xc2])) == Data())
    #expect(s.clean(Data([0xa9])) == bytes("©"))
}
