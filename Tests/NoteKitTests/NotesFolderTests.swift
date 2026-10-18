import XCTest
import Combine
@testable import NoteKit

/// The vault as a listing: every Markdown note with its stamp, published only when something about it changed, so a
/// host polling it can rebuild its own index only then.
@MainActor final class NotesFolderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notekit-folder-\(UUID().uuidString)")
        for folder in ["", "sub", ".obsidian"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try Data("# A\nbody".utf8).write(to: root.appendingPathComponent("a.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("sub/b.md"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".obsidian/c.md"))
        try Data("not a note".utf8).write(to: root.appendingPathComponent("d.txt"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testScanListsMarkdownNotesWithTheirStampsAndSkipsHiddenFolders() throws {
        let entries = NotesFolder.scan(root)
        XCTAssertEqual(Set(entries.map(\.path)), ["a.md", "sub/b.md"])
        let a = try XCTUnwrap(entries.first { $0.path == "a.md" })
        XCTAssertEqual(a.title, "a")
        XCTAssertEqual(a.size, 8)
        XCTAssertEqual(a.folder, "")
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.path == "sub/b.md" }).folder, "sub")
    }

    func testRefreshPublishesTheListingOnlyWhenItChanged() async throws {
        let folder = NotesFolder(root: root)
        XCTAssertFalse(folder.listed, "not listed until the first scan lands")
        var published: [[NotesFolder.Entry]] = [], listedWhenPublished: [Bool] = []
        let sink = folder.$entries.dropFirst().sink { published.append($0); listedWhenPublished.append(folder.listed) }
        defer { sink.cancel() }
        await waitUntil { folder.entries.count == 2 }
        XCTAssertEqual(published.count, 1, "the first listing")
        XCTAssertEqual(listedWhenPublished, [true], "a host hearing the entries must already see the folder as listed")
        folder.refresh()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(published.count, 1, "nothing changed, nothing published")
        // A note edited elsewhere (a later date, a different size) is a new listing.
        try Data("# A\nbody, longer".utf8).write(to: root.appendingPathComponent("a.md"))
        folder.refresh()
        await waitUntil { published.count == 2 }
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(folder.entries.first { $0.path == "a.md" }?.size, 16)
    }

    func testWatchingNoticesNotesThatAppearAndGo() async throws {
        let folder = NotesFolder(root: root)
        await waitUntil { folder.entries.count == 2 }
        folder.watch(every: .milliseconds(40))
        defer { folder.stopWatching() }
        try Data("new".utf8).write(to: root.appendingPathComponent("e.md"))
        await waitUntil { folder.entries.count == 3 }
        XCTAssertEqual(folder.entries.count, 3)
        try FileManager.default.removeItem(at: root.appendingPathComponent("sub/b.md"))
        await waitUntil { folder.entries.count == 2 }
        XCTAssertEqual(Set(folder.entries.map(\.path)), ["a.md", "e.md"])
    }

    func testForgettingTheFolderEmptiesTheListing() async throws {
        let folder = NotesFolder(root: root)
        await waitUntil { folder.entries.count == 2 }
        folder.forget()
        XCTAssertNil(folder.root)
        XCTAssertTrue(folder.entries.isEmpty); XCTAssertTrue(folder.listed)
        // A scan still in flight for the old root must not bring its notes back.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(folder.entries.isEmpty)
    }
}
