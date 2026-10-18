import SwiftUI
import NoteKit
#if os(macOS)
import AppKit
#endif

/// The baseline notes app: the library's own UI, nothing else. Pick a folder, find a note, edit it, see it saved.
@main
struct NotesApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NotesAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("Notes", id: "notes") {
            NotesView()
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
        #endif
    }
}

#if os(macOS)
final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// A note edited a moment before ⌘Q is still waiting for its autosave; write it before the process goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await NoteSession.saveAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
