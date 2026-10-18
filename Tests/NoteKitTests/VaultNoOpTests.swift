import XCTest
@testable import NoteKit

/// Every note in a real vault (a copy of one, never the live vault) opens, styles, and would write nothing back:
/// the editor's first promise, checked against the notes it will actually meet. Skipped unless NOTEKIT_VAULT names
/// the folder, as `NOTEKIT_VAULT=/tmp/bp-vault swift test --filter VaultNoOp`.
final class VaultNoOpTests: XCTestCase {
    func testEveryNoteOpensAndSavesWithoutAWrite() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEKIT_VAULT"] else { throw XCTSkip("NOTEKIT_VAULT not set") }
        let root = URL(fileURLWithPath: path)
        let notes = NotesFolder.scan(root)
        XCTAssertFalse(notes.isEmpty, "no notes under \(path)")
        var utf8 = 0, nonUTF8 = 0, wouldWrite = 0, roundTripMismatch = 0, crlf = 0, bom = 0, spans = 0
        for entry in notes {
            let data = try Data(contentsOf: entry.url)
            guard let note = NoteText(data: data) else { nonUTF8 += 1; continue }
            utf8 += 1
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { bom += 1 }
            if data.contains(0x0D) { crlf += 1 }
            // The text as loaded needs no write; the bytes behind it are the file's own, so an edit is the file plus the edit.
            if note.data(for: note.text) != nil { wouldWrite += 1 }
            if note.data(for: note.text + "!") != data + Data("!".utf8) { roundTripMismatch += 1 }
            let length = (note.text as NSString).length
            for span in MarkdownStyleScanner.spans(in: note.text) {
                spans += 1
                XCTAssertTrue(span.range.location >= 0 && NSMaxRange(span.range) <= length, "\(entry.path): \(span)")
            }
            // The session's own path: open, hand the text back unchanged, close. The file keeps its date.
            let before = try FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date
            let session = await NoteSession(url: entry.url)
            await session.open()
            await session.edited(session.text)
            await session.close()
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date, before, entry.path)
        }
        print("NOOP-CHECK notes=\(notes.count) utf8=\(utf8) nonUTF8=\(nonUTF8) wouldWrite=\(wouldWrite) roundTripMismatch=\(roundTripMismatch) crlf=\(crlf) bom=\(bom) spans=\(spans)")
        XCTAssertEqual(wouldWrite, 0)
        XCTAssertEqual(roundTripMismatch, 0)
    }
}
