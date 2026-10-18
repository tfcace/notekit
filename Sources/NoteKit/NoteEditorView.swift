import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One note, open for as long as the pane is shown: it opens the session on appearing, saves when the app leaves the
/// foreground, and closes (saving) on disappearing. `editor` builds what shows the session; `NoteEditorView` unless
/// given.
public struct NoteEditorPane<Editor: View>: View {
    public let entry: NotesFolder.Entry
    @StateObject private var session: NoteSession
    @Environment(\.scenePhase) private var phase
    private let editor: (NoteSession) -> Editor

    public init(entry: NotesFolder.Entry, @ViewBuilder editor: @escaping (NoteSession) -> Editor) {
        self.entry = entry
        self.editor = editor
        _session = StateObject(wrappedValue: NoteSession(url: entry.url))
    }

    public var body: some View {
        editor(session)
            .navigationTitle(entry.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await session.open() }
            .onDisappear { Task { await session.close() } }
            .onChange(of: phase) { _, phase in if phase != .active { Task { await session.save() } } }
    }
}

extension NoteEditorPane where Editor == NoteEditorView {
    public init(entry: NotesFolder.Entry) {
        self.init(entry: entry) { NoteEditorView(session: $0) }
    }
}

/// The editor and everything that goes with it: the conflict banner above it, the save status in its corner, and a
/// word in place of the text while it loads or can't be read. Built of the public parts, so an app wanting something
/// else around the text builds its own from the same ones. The session's life (opening, closing) belongs to whoever
/// owns it, so the same text view can live in a pane that comes and goes or in a panel that stays.
public struct NoteEditorView: View {
    @ObservedObject var session: NoteSession
    /// False to show the note without editing it: no save status and no conflict banner; an outside change simply shows.
    /// Only a box ticked here (with `ticks`) is written, at once, and a conflict takes the other version.
    let editable: Bool
    /// Whether a task's box ticks; see `NoteTextView`.
    let ticks: Bool?
    /// Grown to the note's height rather than scrolling, on the phone; see `NoteTextView`.
    let fitsHeight: Bool

    public init(session: NoteSession, editable: Bool = true, ticks: Bool? = nil, fitsHeight: Bool = false) {
        self.session = session; self.editable = editable; self.ticks = ticks; self.fitsHeight = fitsHeight
    }

    public var body: some View {
        VStack(spacing: 0) {
            NoteConflictBanner(session: session)
            switch session.status {
            case .unreadable(let message):
                ContentUnavailableView("Can’t edit this note", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loading:
                ProgressView()
            default:
                // A failed write keeps the editor: the text is still here to fix, copy out, or try again.
                NoteTextView(session: session, editable: editable, ticks: ticks, fitsHeight: fitsHeight)
            }
        }
        .background(Color(note: textBackground))
        .overlay(alignment: .bottomTrailing) { if editable { NoteSaveStatus(session: session) } }
    }

    private var textBackground: NoteColors.Color {
        #if os(macOS)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }
}

/// The note changed in another app while it had unsaved edits here: a banner offering both ways out. Nothing while
/// there's no conflict.
public struct NoteConflictBanner: View {
    @ObservedObject var session: NoteSession
    @Environment(\.noteColors) private var colors
    public init(session: NoteSession) { self.session = session }

    public var body: some View {
        if session.status == .changedElsewhere {
            HStack(spacing: 10) {
                Text("This note changed in another app while you were editing it.").font(.callout)
                Spacer()
                Button("Use Theirs") { Task { await session.resolve(keepMine: false) } }
                Button("Keep Mine") { Task { await session.resolve(keepMine: true) } }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(note: colors.highlight))
        }
    }
}

/// A quiet word on where the file stands, for the corner of the page, only while there is one: "Unsaved" while edits
/// wait, "Saved" for a moment once they're written, and a failed write with its way out until it succeeds. On a chip
/// of the background style (`.backgroundStyle(_:)` sets it), so the word sits over the text rather than in it.
public struct NoteSaveStatus: View {
    @ObservedObject var session: NoteSession
    @Environment(\.noteColors) private var colors
    @State private var showSaved = false
    public init(session: NoteSession) { self.session = session }

    /// Whether there's a word to show: the chip is drawn only then.
    private var shown: Bool {
        switch session.status {
        case .editing, .failed: true
        case .saved: showSaved
        default: false
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch session.status {
            case .editing:
                Text("Unsaved").foregroundStyle(Color(note: colors.secondary))
            case .saved where showSaved:
                Text("Saved").foregroundStyle(Color(note: colors.secondary))
            case .failed(let message):
                Label("Couldn’t save. \(message)", systemImage: "exclamationmark.triangle.fill").lineLimit(1).truncationMode(.middle)
                Button("Try Again") { Task { await session.save() } }.buttonStyle(.plain).foregroundStyle(Color(note: colors.accent)).fontWeight(.medium)
            default:
                EmptyView()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
        // A failure on the highlight, to stand out until it's dealt with.
        .background {
            if case .failed = session.status { Capsule().fill(Color(note: colors.highlight)) }
            else { Capsule().fill(.background).shadow(color: .black.opacity(0.12), radius: 3, y: 1) }
        }
        .opacity(shown ? 1 : 0)
        .padding(12)
        .animation(.easeOut(duration: 0.2), value: session.status)
        .animation(.easeOut(duration: 0.4), value: showSaved)
        .task(id: session.status) {
            guard session.status == .saved else { showSaved = false; return }
            showSaved = true
            try? await Task.sleep(for: .seconds(1.5))
            showSaved = false
        }
        .allowsHitTesting({ if case .failed = session.status { return true } else { return false } }())
    }
}

extension Color {
    init(note color: NoteColors.Color) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}
