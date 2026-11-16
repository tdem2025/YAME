import AppKit
import YAMECore
import SwiftUI

@main
struct YAMEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let library = Library.shared

    init() { Pref.registerDefaults() }

    var body: some Scene {
        Window("YAME", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { YAMECommands(library: library) }

        Settings {
            SettingsView()
        }
    }
}

/// Handles MP3s / folders opened from Finder ("Open With → YAME", dropping on the Dock icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Coming back to YAME after copying files in Finder: pick up anything that changed.
    func applicationDidBecomeActive(_ notification: Notification) {
        Library.shared.scheduleRefresh(after: .milliseconds(200))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let library = Library.shared
        library.stopPlayback()
        guard library.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "\(library.dirtyTracks.count) song(s) have unsaved edits."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await library.saveAll()
                sender.reply(toApplicationShouldTerminate: !library.hasUnsavedChanges)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

struct YAMECommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { library.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { library.undo() }
                .keyboardShortcut("z")
            Button("Redo") { library.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await library.saveSelected() } }
                .keyboardShortcut("s")
            Button("Save All") { Task { await library.saveAll() } }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert to Saved") { library.revert(library.selectedTracks) }
        }
        CommandMenu("Songs") {
            Button("Paste Cover") { library.pasteCover(for: Array(library.selection)) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Choose Cover Image…") { library.chooseCoverFile(for: Array(library.selection)) }
            Button("Cover from YouTube…") { library.beginCoverEdit(source: nil, for: Array(library.selection), youtube: true) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button("Number & Rename…") { library.sheet = .numbering }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Clean Up Folder…") { library.sheet = .cleanup }
            Divider()
            Button("Play / Stop Preview") {
                if let t = library.selectedTracks.first { library.togglePlayback(t) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Select All Songs") { library.selection = Set(library.tracks.map(\.id)) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button("Move to Trash") {
                // While typing, ⌘⌫ keeps its usual meaning (delete to the start of the line).
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.deleteToBeginningOfLine(nil)
                } else {
                    library.trashSongs(library.selection)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Remove from List") { library.removeFromList(library.selection) }
            Divider()
            Button("Reload Folder") { library.reload() }
                .keyboardShortcut("r")
            Button("Eject Drive") { library.eject() }
                .keyboardShortcut("e")
        }
    }
}
