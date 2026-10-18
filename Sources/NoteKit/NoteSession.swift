import Foundation

/// One open note and its file. The file is the truth: edits are written back after a short pause, only when the
/// text changed, and never over a version another app (Obsidian, iCloud) wrote in the meantime.
@MainActor public final class NoteSession: ObservableObject {
    public enum Status: Equatable {
        case loading, ready
        /// Edits typed but not yet written; they go out after a short pause.
        case editing
        case saved
        /// Another app changed the file while this one had unsaved edits. Nothing is written until it's resolved.
        case changedElsewhere
        case unreadable(String)
        case failed(String)
    }

    public let url: URL
    @Published public private(set) var status: Status = .loading
    /// Bumps whenever the text is replaced from the file, so the editor knows to take it.
    @Published public private(set) var revision = 0
    public private(set) var text = ""
    /// Where the caret is, as the text view last reported it (UTF-16 offset). A session opened to continue this one
    /// elsewhere, say in a panel beside your work, starts its caret here.
    public var caret = 0
    private var note: NoteText?
    private var stamp: FileStamp?
    private var pendingSave: Task<Void, Never>?
    /// The save reading and writing now, if one is; the next waits for it.
    private var saving: Task<Void, Never>?
    /// Counts saves begun, so a check for an outside change can tell one began under it.
    private var saves = 0
    private var watch: Task<Void, Never>?

    /// Every open note, so quitting can write what was typed in the last moment.
    private static let live = NSHashTable<NoteSession>.weakObjects()

    public init(url: URL) { self.url = url; Self.live.add(self) }

    /// The open session on `url`, if one is showing: so another view of the same note can start where it is.
    public static func live(for url: URL) -> NoteSession? {
        live.allObjects.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    public var hasUnsavedEdits: Bool { note.map { $0.data(for: text) != nil } ?? false }

    /// Writes every open note's pending edits, for quitting.
    public static func saveAll() async {
        for session in live.allObjects { await session.save() }
    }

    public func open() async {
        // Opened again while a save is still writing (a page left and come back to): read what it wrote.
        await saving?.value
        do {
            let (data, stamp) = try await NoteFile.read(url)
            guard let note = NoteText(data: data) else {
                status = .unreadable("This note isn’t UTF-8 text, so it can’t be edited here. Obsidian can still open it.")
                return
            }
            self.note = note; self.stamp = stamp; text = note.text; revision += 1; status = .ready
            startWatching()
        } catch { status = .failed(error.localizedDescription) }
    }

    public func edited(_ newText: String) {
        text = newText
        guard status != .changedElsewhere else { return }
        if hasUnsavedEdits { status = .editing }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes the edits now, unless the file changed underneath them. One write at a time: a save begun while another
    /// reads and writes waits for it, so it compares the file with what that one wrote, not with what came before.
    public func save() async {
        pendingSave?.cancel()
        saves += 1
        let previous = saving
        let current = Task {
            await previous?.value
            await write()
        }
        saving = current
        await current.value
    }

    private func write() async {
        guard let note, let data = note.data(for: text), status != .changedElsewhere else { return }
        do {
            let (current, _) = try await NoteFile.read(url)
            guard note.matches(current) else { status = .changedElsewhere; return }
            stamp = try await NoteFile.write(data, to: url)
            self.note?.saved(data)
            status = .saved
        } catch { status = .failed(error.localizedDescription) }
    }

    /// After another app changed the file under unsaved edits: keep these edits (overwriting theirs) or take theirs.
    public func resolve(keepMine: Bool) async {
        do {
            let (current, stamp) = try await NoteFile.read(url)
            guard let theirs = NoteText(data: current) else { status = .unreadable("The other version isn’t UTF-8 text."); return }
            if keepMine {
                let mine = text
                note = theirs; text = mine; self.stamp = stamp; status = .ready
                await save()
            } else {
                note = theirs; text = theirs.text; self.stamp = stamp; revision += 1; status = .ready
            }
        } catch { status = .failed(error.localizedDescription) }
    }

    public func close() async {
        watch?.cancel()
        await save()
    }

    /// Obsidian writes without file coordination, so a cheap check of the file's date and size every moment catches
    /// its edits as well as iCloud's.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self else { return }
                await self.checkForOutsideChange()
            }
        }
    }

    public func checkForOutsideChange() async {
        // A save in progress has written, or is about to write, a version that's this app's own.
        await saving?.value
        guard status != .changedElsewhere, let now = NoteFile.stamp(url), now != stamp else { return }
        let begun = saves
        guard let (data, stamp) = try? await NoteFile.read(url) else { return }
        // A save begun during the read writes over what it read: the next check sees the file as it is then.
        guard begun == saves, let note, status != .changedElsewhere else { return }
        self.stamp = stamp
        guard !note.matches(data) else { return }
        guard let theirs = NoteText(data: data) else { status = .unreadable("Another app saved this note as something other than UTF-8 text."); return }
        if hasUnsavedEdits {
            status = .changedElsewhere
        } else {
            self.note = theirs; text = theirs.text; revision += 1
        }
    }
}

struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int?
}

/// Coordinated reads and writes, so iCloud downloads a note before it's read and knows when it's written.
enum NoteFile {
    static func stamp(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
    }

    static func read(_ url: URL) async throws -> (Data, FileStamp?) {
        try await Task.detached {
            var coordinationError: NSError?, result: Result<(Data, FileStamp?), Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
                result = Result { (try Data(contentsOf: url), stamp(url)) }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Writes the whole note to a temporary file beside it and swaps it in, so a crash mid-write can't leave half a
    /// note. The swap keeps the file's own creation date, which Obsidian sorts by; a test fails if that regresses.
    static func write(_ data: Data, to url: URL) async throws -> FileStamp? {
        try await Task.detached {
            var coordinationError: NSError?, result: Result<FileStamp?, Error> = .failure(CocoaError(.fileWriteUnknown))
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
                result = Result {
                    let draft = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).notekit-\(UUID().uuidString.prefix(8))")
                    try data.write(to: draft, options: [.withoutOverwriting])
                    do {
                        _ = try FileManager.default.replaceItemAt(url, withItemAt: draft, backupItemName: nil, options: [])
                    } catch {
                        try? FileManager.default.removeItem(at: draft)
                        throw error
                    }
                    return stamp(url)
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }
}
