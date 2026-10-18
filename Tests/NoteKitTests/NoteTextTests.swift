import XCTest
@testable import NoteKit

final class NoteTextTests: XCTestCase {
    private func bytes(_ string: String) -> Data { Data(string.utf8) }

    func testUnchangedNoteWritesNothing() throws {
        let note = try XCTUnwrap(NoteText(data: bytes("# Measures\n\nCutlery drawer\n49.5 cm")))
        XCTAssertNil(note.data(for: note.text))
        XCTAssertEqual(note.data(for: note.text + "!"), bytes("# Measures\n\nCutlery drawer\n49.5 cm!"))
    }

    func testWindowsLineEndingsAreKept() throws {
        let note = try XCTUnwrap(NoteText(data: bytes("a\r\nb\r\n")))
        XCTAssertEqual(note.text, "a\nb\n", "the editor sees plain newlines")
        XCTAssertNil(note.data(for: "a\nb\n"))
        XCTAssertEqual(note.data(for: "a\nb\nc\n"), bytes("a\r\nb\r\nc\r\n"))
    }

    func testMixedLineEndingsAreLeftAsTheyAre() throws {
        let note = try XCTUnwrap(NoteText(data: bytes("a\r\nb\nc")))
        XCTAssertEqual(note.text, "a\r\nb\nc")
        XCTAssertNil(note.data(for: note.text))
        XCTAssertEqual(note.data(for: "a\r\nb\nc\nd"), bytes("a\r\nb\nc\nd"))
    }

    func testByteOrderMarkSurvivesAnEdit() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + bytes("hi")
        let note = try XCTUnwrap(NoteText(data: original))
        XCTAssertEqual(note.text, "hi")
        XCTAssertNil(note.data(for: "hi"))
        XCTAssertEqual(note.data(for: "hi!"), Data([0xEF, 0xBB, 0xBF]) + bytes("hi!"))
    }

    func testDecomposedAccentsAreWrittenAsTyped() throws {
        // Swift compares strings by canonical equivalence; the bytes written must still be the ones in the text.
        let decomposed = "cafe\u{301}"
        let note = try XCTUnwrap(NoteText(data: bytes(decomposed)))
        XCTAssertNil(note.data(for: "caf\u{E9}"), "canonically the same note, so nothing is written")
        XCTAssertEqual(note.data(for: decomposed + "!"), Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81, 0x21]))
    }

    func testNotUTF8CantBeEdited() {
        XCTAssertNil(NoteText(data: Data([0x68, 0xFF, 0xFE, 0x69])))
    }

    func testAfterSavingTheNewBytesAreTheBaseline() throws {
        var note = try XCTUnwrap(NoteText(data: bytes("a\r\nb")))
        let written = try XCTUnwrap(note.data(for: "a\nbc"))
        note.saved(written)
        XCTAssertEqual(note.text, "a\nbc")
        XCTAssertNil(note.data(for: "a\nbc"))
        XCTAssertTrue(note.matches(written))
        XCTAssertFalse(note.matches(bytes("a\r\nb")))
    }
}

final class ParagraphDirectionTests: XCTestCase {
    func testALineReadsTheWayMostOfItsWordsDo() {
        XCTAssertEqual(ParagraphDirection.of("Oura - טבעת מידה 12"), .rightToLeft)
        XCTAssertEqual(ParagraphDirection.of("Buy חלב for the soup tonight"), .leftToRight)
        XCTAssertEqual(ParagraphDirection.of("ראיתי את Claude Code של Anthropic"), .rightToLeft, "Latin names don't outvote Hebrew")
        XCTAssertEqual(ParagraphDirection.of("- [ ] לקנות [[clothing]] נעליים"), .rightToLeft)
        XCTAssertEqual(ParagraphDirection.of("[Oura](https://ouraring.com/sizing) מידות"), .rightToLeft, "an address isn't words")
        XCTAssertNil(ParagraphDirection.of("- [ ] 49.5 / 35.5"))
        XCTAssertEqual(ParagraphDirection.of("49.5 cm"), .leftToRight, "a unit is a word")
        XCTAssertNil(ParagraphDirection.of(""))
    }

    func testLinesWithoutWordsFollowTheLineAbove() {
        XCTAssertEqual(ParagraphDirection.lines(in: "12\nשלום\n\n49.5\nhello"), [.leftToRight, .rightToLeft, .rightToLeft, .rightToLeft, .leftToRight])
        XCTAssertEqual(ParagraphDirection.lines(in: "שלום\n"), [.rightToLeft, .rightToLeft], "a new empty last line starts on the right")
    }
}
