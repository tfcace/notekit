// swift-tools-version: 5.10
import PackageDescription

// NoteKit is the engine: the Markdown scanner, the byte-preserving note text, the note session that saves and watches
// the file, and the editor views. Notes is the baseline app on top of it, the reference for embedding the editor
// somewhere else.
let package = Package(
    name: "NoteKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NoteKit", targets: ["NoteKit"]),
        .executable(name: "Notes", targets: ["NotesApp"])
    ],
    targets: [
        .target(name: "NoteKit"),
        .executableTarget(name: "NotesApp", dependencies: ["NoteKit"]),
        .testTarget(name: "NoteKitTests", dependencies: ["NoteKit"])
    ]
)
