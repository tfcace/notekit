import SwiftUI
import UniformTypeIdentifiers
import NoteKit

/// The Notes app's window: a sidebar of the folder's notes with a filter, the editor for the chosen one, and a footer
/// naming the folder.
struct NotesView: View {
    @StateObject private var folder = NotesFolder.shared
    @State private var selection: NotesFolder.Entry?
    @State private var filter = ""
    @State private var choosing = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationSplitView {
            Group {
                if folder.root == nil {
                    ContentUnavailableView {
                        Label("Choose your notes", systemImage: "folder")
                    } description: {
                        Text("Pick your Obsidian vault. The Markdown files are edited where they are.")
                    } actions: {
                        Button("Choose Folder…") { choosing = true }
                    }
                } else {
                    List(shown, selection: $selection) { entry in
                        NavigationLink(value: entry) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).lineLimit(1)
                                if !entry.folder.isEmpty { Text(entry.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                    .searchable(text: $filter, placement: .sidebar, prompt: "Filter notes")
                    .overlay { if let problem = folder.problem { Text(problem).foregroundStyle(.secondary) } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { vaultFooter }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 460)
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { folder.refresh() } }
            }
        } detail: {
            if let selection {
                NoteEditorPane(entry: selection).id(selection.url)
            } else {
                Text("Choose a note").foregroundStyle(.secondary)
            }
        }
        #if DEBUG
        // Development: -NotesOpen opens a note by its path in the folder.
        .onChange(of: folder.entries) { _, entries in
            if selection == nil, let path = UserDefaults.standard.string(forKey: "NotesOpen") { selection = entries.first { $0.path == path } }
        }
        #endif
        // Notes made or renamed in Obsidian show up on coming back, without a refresh.
        .onChange(of: phase) { _, phase in if phase == .active { folder.refresh() } }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in folder.refresh() }
        #endif
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { selection = nil; folder.choose(url) }
        }
    }

    /// Which vault the list is, with the way to another one.
    private var vaultFooter: some View {
        HStack(spacing: 8) {
            Label(folder.root?.lastPathComponent ?? "", systemImage: "folder").lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Change…") { choosing = true }.buttonStyle(.plain).foregroundStyle(.tint)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var shown: [NotesFolder.Entry] {
        let words = filter.lowercased().split(separator: " ")
        guard !words.isEmpty else { return folder.entries }
        return folder.entries.filter { entry in words.allSatisfy { entry.path.lowercased().contains($0) } }
    }
}

extension NotesFolder {
    /// The app's folder, remembered across launches. Debug builds take `-NotesFolderPath <folder>` (a vault copy) to
    /// use a folder without replacing the remembered one.
    @MainActor static let shared: NotesFolder = {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "NotesFolderPath") { return NotesFolder(root: URL(fileURLWithPath: path)) }
        #endif
        return NotesFolder(remembering: .standard, key: "notesFolderBookmark")
    }()
}
