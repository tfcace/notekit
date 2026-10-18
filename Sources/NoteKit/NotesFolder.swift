import Foundation

/// The folder of notes being edited (an Obsidian vault), remembered across launches where the app keeps it. The one
/// owner of that choice: an app's settings read `root` and call `choose` and `forget`, and every view of the notes
/// reads `entries`.
@MainActor public final class NotesFolder: ObservableObject {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        /// Relative to the folder, with the extension: "daily/2026-10-13.md".
        public let path: String
        public let modified: Date
        /// In bytes. With the date, a cheap stamp: a note another app rewrote differs in one or the other.
        public let size: Int
        public var id: URL { url }
        public var title: String { url.deletingPathExtension().lastPathComponent }
        public var folder: String { (path as NSString).deletingLastPathComponent }
        public init(url: URL, path: String, modified: Date, size: Int = 0) { self.url = url; self.path = path; self.modified = modified; self.size = size }
    }

    @Published public private(set) var root: URL?
    /// Every note under `root`, newest first. Published only when the listing changed (a note added, removed,
    /// renamed or rewritten), so whoever indexes the notes does so only then.
    @Published public private(set) var entries: [Entry] = []
    /// Whether `entries` is a listing of `root` yet: false from choosing a folder until its first scan lands, so a host
    /// that read the folder itself doesn't take the empty start for an empty vault. True with no folder.
    @Published public private(set) var listed = true
    @Published public private(set) var problem: String?
    /// Where the chosen folder is remembered, as a bookmark; nil for a folder that isn't (tests, a preview).
    private let defaults: UserDefaults?
    private let key: String
    /// Bumped by every change of root, so a scan that started on the old folder lands nowhere.
    private var generation = 0
    private var watcher: Task<Void, Never>?

    /// The folder remembered in `defaults` under `key`, if there is one; a folder chosen later is remembered there.
    public init(remembering defaults: UserDefaults, key: String) {
        self.defaults = defaults; self.key = key
        guard let data = defaults.data(forKey: key) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) {
            open(url, remember: stale)
        }
    }
    /// A folder for one place, remembered nowhere.
    public init(root: URL?) {
        defaults = nil; key = ""
        if let root { open(root, remember: false) }
    }

    public func choose(_ url: URL) { open(url, remember: true) }

    /// No vault: the listing empties and the remembered folder is forgotten.
    public func forget() {
        generation += 1
        root?.stopAccessingSecurityScopedResource()
        defaults?.removeObject(forKey: key)
        root = nil; entries = []; problem = nil; listed = true
    }

    private func open(_ url: URL, remember: Bool) {
        generation += 1
        root?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        if remember {
            let data = (try? url.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData())
            defaults?.set(data, forKey: key)
        }
        root = url; listed = false
        refresh()
    }

    #if os(macOS)
    private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Lists the folder again, off the main thread, and publishes the listing if it changed.
    public func refresh() {
        guard let root else { return }
        let generation = generation
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(root)
            await MainActor.run { self.take(found, from: generation) }
        }
    }
    private func take(_ found: [Entry], from scan: Int) {
        guard scan == generation else { return }
        // Listed first: whoever hears the entries change must already see that this is a listing, not the start.
        if !listed { listed = true }
        if found != entries { entries = found }
        let problem = found.isEmpty ? "No Markdown notes in this folder." : nil
        if problem != self.problem { self.problem = problem }
    }

    /// Lists the folder every `interval` (Obsidian and iCloud write without telling anyone), publishing only changes.
    /// The same beat as a session's check for an outside change to one note.
    public func watch(every interval: Duration = .milliseconds(1500)) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    public func stopWatching() { watcher?.cancel(); watcher = nil }

    /// Every Markdown note under the folder, newest first. Hidden folders (.obsidian, .trash) are skipped; a note iCloud
    /// hasn't downloaded yet is listed under its real name and downloads when it's opened.
    nonisolated public static func scan(_ root: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let base = root.standardizedFileURL.path
        var entries: [Entry] = []
        for case let url as URL in walker {
            var name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            var file = url
            if name.hasPrefix("."), name.hasSuffix(".md.icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                file = url.deletingLastPathComponent().appendingPathComponent(name)
            }
            guard !name.hasPrefix("."), name.lowercased().hasSuffix(".md") else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            entries.append(Entry(url: file, path: path, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0))
        }
        return entries.sorted { ($0.modified, $0.path) > ($1.modified, $1.path) }
    }
}
