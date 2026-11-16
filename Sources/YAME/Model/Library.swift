import AppKit
import AVFoundation
import Observation
import YAMECore
import SwiftUI
import UniformTypeIdentifiers

/// Which sheet is showing.
enum ActiveSheet: Identifiable {
    case cover(CoverRequest)
    case numbering
    case cleanup

    var id: String {
        switch self {
        case .cover(let r): return "cover-\(r.id)"
        case .numbering: return "numbering"
        case .cleanup: return "cleanup"
        }
    }
}

/// A request to (re)make a cover for one or more songs.
struct CoverRequest: Identifiable {
    let id = UUID()
    var source: CGImage?
    var targets: [TrackItem.ID]
    /// Start in "paste a YouTube link" mode.
    var startWithYouTube = false
}

struct Banner: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var isError = false
}

/// Values to apply to several songs at once (nil = leave as is).
struct BatchEdit {
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: String?
}

/// App settings keys (shared with SettingsView).
enum Pref {
    static let coverSize = "coverSize"
    static let jpegQuality = "jpegQuality"
    static let writeID3v1 = "writeID3v1"
    static let removeAppleDouble = "removeAppleDouble"
    static let namingStyle = "namingStyle"
    static let autoNumber = "autoNumber"
    static let autoRenameFiles = "autoRenameFiles"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            coverSize: 500, jpegQuality: 0.9, writeID3v1: true, removeAppleDouble: true,
            namingStyle: NamingStyle.artistTitle.rawValue, autoNumber: true, autoRenameFiles: true,
        ])
    }
}

/// Everything undo can restore: play order and each song's tags.
struct EditSnapshot: Equatable {
    var order: [UUID] = []
    var fields: [UUID: TagFields] = [:]
}

/// One step in the undo history.
enum HistoryEntry {
    /// Tag edits, covers, batch edits, reordering, numbering.
    case edits(before: EditSnapshot, after: EditSnapshot)
    /// Songs taken out of the list (files untouched).
    case removed([RemovedTrack])
    /// Files moved to the Trash (songs, or junk from Clean Up).
    case trashed([TrashedFile])
    /// Files renamed by Number & Rename.
    case renamed([RenameChange])

    var name: String {
        switch self {
        case .edits: return "Edit"
        case .removed(let r): return r.count == 1 ? "Remove from List" : "Remove \(r.count) Songs from List"
        case .trashed(let t): return t.count == 1 ? "Move to Trash" : "Move \(t.count) Files to Trash"
        case .renamed: return "Rename Files"
        }
    }
}

struct RemovedTrack {
    let track: TrackItem
    let index: Int
}

/// A file in the Trash that undo can put back. (A class: redo moves it to a new Trash location.)
final class TrashedFile {
    let originalURL: URL
    var trashedURL: URL?
    let track: TrackItem?
    let index: Int

    init(originalURL: URL, trashedURL: URL?, track: TrackItem?, index: Int) {
        self.originalURL = originalURL
        self.trashedURL = trashedURL
        self.track = track
        self.index = index
    }
}

struct RenameChange {
    let track: TrackItem
    let old: URL
    let new: URL
}

/// A song read from disk off the main thread.
struct LoadedSong: Sendable {
    let url: URL
    let tag: ID3Tag?
    let error: String?
    let modified: Date?

    static func load(_ url: URL) -> LoadedSong {
        let modified = fileModificationDate(url)
        do { return LoadedSong(url: url, tag: try MP3File.readTag(at: url), error: nil, modified: modified) }
        catch { return LoadedSong(url: url, tag: nil, error: error.localizedDescription, modified: modified) }
    }
}

func fileModificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

/// Compares file paths the way FAT/exFAT/APFS drives do (Unicode-normalized, case-insensitive).
func pathKey(_ url: URL) -> String {
    url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
}

@MainActor
@Observable
final class Library {
    static let shared = Library()

    var tracks: [TrackItem] = []
    var selection: Set<TrackItem.ID> = []
    var folderURL: URL?
    var isLoading = false
    var isSaving = false
    var sheet: ActiveSheet?
    var banner: Banner?
    var playingID: TrackItem.ID?

    @ObservationIgnored private var isRenaming = false
    /// Auto-number: keep "n of total" (and numbered file names) in step with the list order.
    private(set) var autoNumber = UserDefaults.standard.object(forKey: Pref.autoNumber) as? Bool ?? true
    @ObservationIgnored private var renumberTask: Task<Void, Never>?
    /// Songs the user took out of the list; live updates won't add them back.
    @ObservationIgnored private var hiddenPaths: Set<String> = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    // Undo / redo (snapshots of every song's tags and the play order).
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []
    @ObservationIgnored private var baseline = EditSnapshot()
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    @ObservationIgnored private var isObservingEdits = false

    // MARK: Derived

    var selectedTracks: [TrackItem] { tracks.filter { selection.contains($0.id) } }
    var dirtyTracks: [TrackItem] { tracks.filter(\.isDirty) }
    var hasUnsavedChanges: Bool { tracks.contains(where: \.isDirty) }
    var title: String { folderURL?.lastPathComponent ?? (tracks.isEmpty ? "YAME" : "Songs") }

    func track(_ id: TrackItem.ID) -> TrackItem? { tracks.first { $0.id == id } }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a Music Folder or MP3s"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mp3, .folder]
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    /// Opens folders and/or MP3 files (open panel, Finder, the Dock icon, drag and drop).
    func open(urls: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(url) }
            else if url.pathExtension.lowercased() == "mp3" { files.append(url) }
        }
        if let folder = folders.first {
            openFolder(folder)
        } else if !files.isEmpty {
            add(files: files)
        }
    }

    func openFolder(_ url: URL) {
        guard confirmDiscardingChanges() else { return }
        stopPlayback()
        stopWatching()
        folderURL = url
        tracks = []
        selection = []
        isLoading = true
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ((try? FolderScanner.scan(url).songs) ?? []).map(LoadedSong.load)
            }.value
            var items = loaded.map(TrackItem.init)
            // Keep the saved play order: numbered songs first (by number), then any new ones by name.
            let numbered = items.filter { $0.fields.trackNumber != nil }.count
            if numbered * 2 >= items.count, numbered > 0 {
                items = items.enumerated().sorted { a, b in
                    let x = a.element.fields.trackNumber ?? Int.max, y = b.element.fields.trackNumber ?? Int.max
                    return x != y ? x < y : a.offset < b.offset
                }.map(\.element)
            }
            hiddenPaths = []
            tracks = items
            selection = items.first.map { [$0.id] } ?? []
            isLoading = false
            resetHistory()
            if items.isEmpty { show("No MP3s in “\(url.lastPathComponent)” yet — add some and they’ll appear here.") }
            loadDurations(items)
            startWatching(url)
            // A playlist that's already numbered gets fixed up if songs were added while YAME was closed.
            if numbered * 2 >= items.count, numbered > 0 { scheduleRenumber() }
        }
    }

    /// Adds individual MP3s to the list (keeps whatever is already open).
    func add(files: [URL]) {
        let existing = Set(tracks.map { pathKey($0.url) })
        let newFiles = files.filter { !existing.contains(pathKey($0)) }
        guard !newFiles.isEmpty else {
            if let first = files.first, let t = tracks.first(where: { pathKey($0.url) == pathKey(first) }) {
                selection = [t.id]
            }
            return
        }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { newFiles.map(LoadedSong.load) }.value
            let items = loaded.map(TrackItem.init)
            checkpoint()
            tracks.append(contentsOf: items)
            selection = Set(items.map(\.id))
            loadDurations(items)
            rebaseline()
            for url in newFiles { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        }
    }

    func reload() {
        if let folderURL { openFolder(folderURL) }
    }

    private func loadDurations(_ items: [TrackItem]) {
        for item in items {
            let url = item.url
            Task {
                if let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric {
                    item.duration = d.seconds
                }
            }
        }
    }

    /// Asks before throwing away unsaved edits. Returns true to continue.
    func confirmDiscardingChanges() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "\(dirtyTracks.count) song(s) have edits that haven’t been saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Live folder updates

    /// Watches the open folder so songs added, removed or changed in Finder show up right away.
    private func startWatching(_ folder: URL) {
        stopWatching()
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        refreshTask?.cancel()
    }

    /// Batches bursts of file events (a Finder copy fires many) into one refresh.
    func scheduleRefresh(after delay: Duration = .milliseconds(800)) {
        guard folderURL != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refreshFromDisk()
        }
    }

    /// Merges the folder's current contents into the list without disturbing edits or play order.
    private func refreshFromDisk() async {
        guard let folder = folderURL, !isLoading else { return }
        if isSaving || isRenaming { scheduleRefresh(); return }

        guard FileManager.default.fileExists(atPath: folder.path) else {
            stopWatching()
            stopPlayback()
            let lost = dirtyTracks.count
            tracks = []
            selection = []
            folderURL = nil
            resetHistory()
            show(lost > 0 ? "The folder disappeared (drive unplugged?) — \(lost) unsaved edit(s) were lost."
                          : "The folder is no longer available.", error: true)
            return
        }

        // Which songs need (re)reading: new files, or files changed by another app.
        let known = Dictionary(tracks.map { (pathKey($0.url), $0.modified) }, uniquingKeysWith: { a, _ in a })
        let hidden = hiddenPaths
        let scanned = await Task.detached(priority: .utility) { () -> [(URL, LoadedSong?)] in
            let songs = (try? FolderScanner.scan(folder).songs) ?? []
            return songs.filter { !hidden.contains(pathKey($0)) }.map { url in
                let key = pathKey(url)
                if let old = known[key], old == fileModificationDate(url) { return (url, nil) }
                return (url, LoadedSong.load(url))
            }
        }.value
        guard folderURL == folder, !isSaving, !isRenaming else { return }

        checkpoint()   // keep the user's pending edits as their own undo step
        defer { rebaseline() }

        let onDisk = Set(scanned.map { pathKey($0.0) })
        let folderKey = pathKey(folder)
        var removed = 0
        var added: [TrackItem] = []

        // Songs that vanished from this folder (songs opened from elsewhere are left alone).
        for t in tracks where pathKey(t.url.deletingLastPathComponent()) == folderKey && !onDisk.contains(pathKey(t.url)) {
            if t.isDirty {
                t.errorMessage = "This file was moved or deleted. Your edits can’t be saved."
            } else {
                tracks.removeAll { $0.id == t.id }
                selection.remove(t.id)
                if playingID == t.id { stopPlayback() }
                removed += 1
            }
        }

        // Changed and new songs.
        for (url, loaded) in scanned {
            guard let loaded else { continue }
            if let existing = tracks.first(where: { pathKey($0.url) == pathKey(url) }) {
                if !existing.isDirty {
                    existing.reload(from: loaded)
                    loadDurations([existing])
                }
            } else {
                added.append(TrackItem(loaded))
            }
        }

        if !added.isEmpty {
            tracks.append(contentsOf: added)
            loadDurations(added)
            if selection.isEmpty { selection = [added[0].id] }
            // Files may still be copying; look again once they've finished.
            scheduleRefresh(after: .seconds(3))
        }
        if !added.isEmpty || removed > 0 { scheduleRenumber() }
        switch (added.count, removed) {
        case (0, 0): break
        case (let a, 0): show(a == 1 ? "Added “\(added[0].displayTitle)”" : "Added \(a) new songs")
        case (0, let r): show(r == 1 ? "A song was removed from the folder" : "\(r) songs were removed from the folder")
        case (let a, let r): show("Added \(a), removed \(r) songs")
        }
    }

    // MARK: Undo / redo

    /// Starts a fresh history (after opening a folder).
    func resetHistory() {
        checkpointTask?.cancel()
        undoStack = []
        redoStack = []
        baseline = currentSnapshot()
        updateUndoState()
        if !isObservingEdits { observeEdits() }
    }

    func undo() {
        checkpoint()
        guard let entry = undoStack.popLast() else { NSSound.beep(); return }
        do {
            try perform(entry, undoing: true)
            redoStack.append(entry)
            show("Undo \(entry.name)")
            scheduleRenumber()
        } catch {
            show("Couldn’t undo \(entry.name): \(error.localizedDescription)", error: true)
        }
        rebaseline()
    }

    func redo() {
        checkpoint()
        guard let entry = redoStack.popLast() else { NSSound.beep(); return }
        do {
            try perform(entry, undoing: false)
            undoStack.append(entry)
            show("Redo \(entry.name)")
            scheduleRenumber()
        } catch {
            show("Couldn’t redo \(entry.name): \(error.localizedDescription)", error: true)
        }
        rebaseline()
    }

    /// Records pending tag/order edits as one undo step (typing is grouped by pauses).
    func checkpoint() {
        checkpointTask?.cancel()
        let now = currentSnapshot()
        guard now != baseline else { return }
        record(.edits(before: baseline, after: now))
        baseline = now
    }

    private func record(_ entry: HistoryEntry) {
        undoStack.append(entry)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoState()
    }

    /// Accepts the current state without making an undo step (changes that came from disk, or file operations).
    private func rebaseline() {
        baseline = currentSnapshot()
        updateUndoState()
        if !isObservingEdits { observeEdits() }
    }

    private func perform(_ entry: HistoryEntry, undoing: Bool) throws {
        switch entry {
        case .edits(let before, let after):
            restore(undoing ? before : after)

        case .removed(let items):
            if undoing { reinsert(items) } else { detach(items.map(\.track)) }

        case .trashed(let files):
            if undoing {
                // Put each file back where it was, then its song back in the list.
                for f in files {
                    guard let from = f.trashedURL else { continue }
                    try FileManager.default.moveItem(at: from, to: f.originalURL)
                }
                reinsert(files.compactMap { f in f.track.map { RemovedTrack(track: $0, index: f.index) } })
            } else {
                for f in files {
                    f.trashedURL = try moveToTrash(f.originalURL)
                }
                detach(files.compactMap(\.track))
            }

        case .renamed(let changes):
            isRenaming = true
            defer { isRenaming = false }
            let renames = changes.map { c in
                undoing ? FileNaming.Rename(from: c.new, to: c.old) : FileNaming.Rename(from: c.old, to: c.new)
            }
            try FileNaming.perform(renames)
            for c in changes {
                c.track.url = undoing ? c.old : c.new
                c.track.modified = fileModificationDate(c.track.url)
            }
        }
    }

    private func currentSnapshot() -> EditSnapshot {
        EditSnapshot(order: tracks.map(\.id),
                     fields: Dictionary(tracks.map { ($0.id, $0.fields) }, uniquingKeysWith: { a, _ in a }))
    }

    private func restore(_ snapshot: EditSnapshot) {
        var byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = snapshot.order.compactMap { byID.removeValue(forKey: $0) }
        ordered += tracks.filter { byID[$0.id] != nil }   // songs added since keep their place at the end
        tracks = ordered
        for t in tracks {
            if let f = snapshot.fields[t.id], f != t.fields { t.restore(f) }
        }
    }

    private func reinsert(_ items: [RemovedTrack]) {
        for item in items.sorted(by: { $0.index < $1.index }) where !tracks.contains(where: { $0.id == item.track.id }) {
            tracks.insert(item.track, at: min(item.index, tracks.count))
            hiddenPaths.remove(pathKey(item.track.url))
        }
        if !items.isEmpty { selection = Set(items.map(\.track.id)) }
    }

    private func detach(_ items: [TrackItem]) {
        let ids = Set(items.map(\.id))
        if let playing = playingID, ids.contains(playing) { stopPlayback() }
        tracks.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty || currentSnapshot() != baseline
        canRedo = !redoStack.isEmpty
    }

    /// Watches every song's tags and the order; a short pause after a change makes an undo step.
    private func observeEdits() {
        isObservingEdits = true
        withObservationTracking {
            _ = currentSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.editsDidChange() }
        }
    }

    private func editsDidChange() {
        observeEdits()
        canUndo = true
        checkpointTask?.cancel()
        checkpointTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            checkpoint()
        }
    }

    // MARK: List editing

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        scheduleRenumber()
    }

    // MARK: Auto-number

    func setAutoNumber(_ on: Bool) {
        autoNumber = on
        UserDefaults.standard.set(on, forKey: Pref.autoNumber)
        if on { scheduleRenumber() }
    }

    /// Debounced so a burst of changes (dragging, copying many songs) renumbers once.
    func scheduleRenumber(after delay: Duration = .milliseconds(600)) {
        guard autoNumber, folderURL != nil else { return }
        renumberTask?.cancel()
        renumberTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await renumberNow()
        }
    }

    /// Writes "n of total" into every song of the folder in list order, touching only songs whose
    /// numbers changed, then keeps numbered file names ("07 …") in step. Other unsaved edits stay unsaved.
    private func renumberNow() async {
        guard autoNumber, let folder = folderURL, !isLoading else { return }
        if isSaving || isRenaming { scheduleRenumber(); return }
        let folderKey = pathKey(folder)
        let songs = tracks.filter { pathKey($0.url.deletingLastPathComponent()) == folderKey }
        let total = songs.count
        guard total > 0 else { return }

        // Wait for files that are still being copied in.
        let unsettled = songs.contains { t in
            guard let m = fileModificationDate(t.url) else { return true }
            return m != t.modified || Date().timeIntervalSince(m) < 2.5
        }
        let writeV1 = UserDefaults.standard.bool(forKey: Pref.writeID3v1)

        checkpoint()
        defer { rebaseline() }

        isSaving = true
        var updated = 0
        for (i, t) in songs.enumerated() where t.saved.trackNumber != i + 1 || t.saved.trackTotal != total {
            guard let m = fileModificationDate(t.url), m == t.modified, Date().timeIntervalSince(m) >= 2.5 else { continue }
            var f = t.saved
            f.trackNumber = i + 1
            f.trackTotal = total
            let url = t.url, frames = t.otherFrames
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MP3File.write(f, to: url, otherFrames: frames, writeV1: writeV1)
                }.value
                t.applySavedNumber(i + 1, of: total, modified: fileModificationDate(url))
                updated += 1
            } catch {
                t.errorMessage = error.localizedDescription
            }
        }
        isSaving = false

        let renamed = UserDefaults.standard.bool(forKey: Pref.autoRenameFiles) ? renumberFileNames(songs) : 0
        if updated > 0 || renamed > 0 {
            show("Track numbers updated: 1–\(total)")
        }
        if unsettled { scheduleRenumber(after: .seconds(3)) }
    }

    /// If the folder uses numbered file names ("01 …"), renames files so the numbers match the order.
    private func renumberFileNames(_ songs: [TrackItem]) -> Int {
        let total = songs.count
        let numberedNames = songs.filter {
            let base = $0.url.deletingPathExtension().lastPathComponent
            return FileNaming.stripNumberPrefix(base) != base
        }.count
        guard numberedNames * 2 >= total else { return 0 }   // this folder doesn't number its files

        let plan: [(TrackItem, URL)] = songs.enumerated().compactMap { i, t in
            let base = t.url.deletingPathExtension().lastPathComponent
            let name = FileNaming.number(i + 1, total: total) + " " + FileNaming.sanitize(FileNaming.stripNumberPrefix(base))
                + "." + t.url.pathExtension
            return name == t.url.lastPathComponent ? nil : (t, t.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        guard !plan.isEmpty else { return 0 }
        isRenaming = true
        defer { isRenaming = false }
        do {
            try FileNaming.perform(plan.map { FileNaming.Rename(from: $0.0.url, to: $0.1) })
            for (t, newURL) in plan {
                t.url = newURL
                t.modified = fileModificationDate(newURL)
            }
            return plan.count
        } catch {
            show("Couldn’t renumber file names: \(error.localizedDescription)", error: true)
            return 0
        }
    }

    /// Takes songs out of the list (the files stay on disk). Undoable.
    func removeFromList(_ ids: Set<TrackItem.ID>) {
        let items = tracks.enumerated().filter { ids.contains($0.element.id) }
            .map { RemovedTrack(track: $0.element, index: $0.offset) }
        guard !items.isEmpty else { return }
        checkpoint()
        detach(items.map(\.track))
        hiddenPaths.formUnion(items.map { pathKey($0.track.url) })
        record(.removed(items))
        scheduleRenumber()
        rebaseline()
        show(items.count == 1 ? "Removed from list — ⌘Z to undo" : "Removed \(items.count) songs from list — ⌘Z to undo")
    }

    /// Moves songs' files to the Trash. Undoable: ⌘Z puts them back.
    func trashSongs(_ ids: Set<TrackItem.ID>) {
        let items = tracks.enumerated().filter { ids.contains($0.element.id) }
        guard !items.isEmpty else { return }
        checkpoint()
        var done: [TrashedFile] = []
        var failed = 0
        for (index, track) in items {
            do {
                let trashed = try moveToTrash(track.url)
                done.append(TrashedFile(originalURL: track.url, trashedURL: trashed, track: track, index: index))
            } catch { failed += 1 }
        }
        detach(done.compactMap(\.track))
        if !done.isEmpty { record(.trashed(done)) }
        rebaseline()
        scheduleRenumber()
        if failed > 0 { show("\(failed) file(s) couldn’t be moved to the Trash.", error: true) }
        else { show(done.count == 1 ? "Moved to Trash — ⌘Z to undo" : "Moved \(done.count) songs to Trash — ⌘Z to undo") }
    }

    /// Moves a file to the Trash (or, on drives without one, to a hidden ".yame-trash" folder beside it).
    private func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { return result as URL }
        } catch {}
        let holding = url.deletingLastPathComponent().appendingPathComponent(".yame-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        let target = holding.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Applies the same values to several songs.
    func apply(_ edit: BatchEdit, to items: [TrackItem]) {
        for t in items {
            if let v = edit.artist { t.fields.artist = v }
            if let v = edit.album { t.fields.album = v }
            if let v = edit.albumArtist { t.fields.albumArtist = v }
            if let v = edit.genre { t.fields.genre = v }
            if let v = edit.year { t.fields.year = v }
        }
    }

    // MARK: Covers

    func setCover(_ cover: CoverArt?, for ids: [TrackItem.ID]) {
        for id in ids { track(id)?.setCover(cover) }
    }

    func beginCoverEdit(source: CGImage?, for ids: [TrackItem.ID], youtube: Bool = false) {
        guard !ids.isEmpty else { return }
        sheet = .cover(CoverRequest(source: source, targets: ids, startWithYouTube: youtube))
    }

    func pasteCover(for ids: [TrackItem.ID]) {
        guard let image = CoverProcessor.imageFromPasteboard() else {
            show("There’s no image on the clipboard.", error: true)
            return
        }
        beginCoverEdit(source: image, for: ids)
    }

    func chooseCoverFile(for ids: [TrackItem.ID]) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Cover Image"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let image = CoverProcessor.cgImage(from: data) else {
            show("That image couldn’t be opened.", error: true)
            return
        }
        beginCoverEdit(source: image, for: ids)
    }

    func exportCover(of track: TrackItem) {
        guard let cover = track.fields.cover else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileNaming.sanitize(track.displayTitle) + (cover.mimeType == "image/png" ? ".png" : ".jpg")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try cover.data.write(to: url) } catch { show(error.localizedDescription, error: true) }
    }

    // MARK: Saving

    func save(_ items: [TrackItem]) async {
        let toSave = items.filter(\.isDirty)
        guard !toSave.isEmpty else { return }
        let defaults = UserDefaults.standard
        let writeV1 = defaults.bool(forKey: Pref.writeID3v1)
        let cleanSidecars = defaults.bool(forKey: Pref.removeAppleDouble)
        isSaving = true
        defer { isSaving = false }

        var failed = 0
        for t in toSave {
            let fields = t.fields, url = t.url, frames = t.otherFrames
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MP3File.write(fields, to: url, otherFrames: frames, writeV1: writeV1)
                }.value
                t.markSaved(modified: fileModificationDate(url))
                if cleanSidecars { removeSidecar(of: url) }
            } catch {
                t.errorMessage = error.localizedDescription
                failed += 1
            }
        }
        if failed > 0 {
            show("\(failed) song(s) couldn’t be saved.", error: true)
        } else {
            show(toSave.count == 1 ? "Saved “\(toSave[0].displayTitle)”" : "Saved \(toSave.count) songs")
        }
    }

    func saveSelected() async { await save(selectedTracks) }
    func saveAll() async { await save(tracks) }
    func revert(_ items: [TrackItem]) { items.forEach { $0.revert() } }

    private func removeSidecar(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent))
    }

    // MARK: Numbering & renaming

    func plannedNames(style: NamingStyle) -> [(TrackItem, String)] {
        let total = tracks.count
        return tracks.enumerated().map { i, t in
            var f = t.fields
            f.trackNumber = i + 1
            f.trackTotal = total
            return (t, FileNaming.fileName(index: i + 1, total: total, style: style, fields: f, currentName: t.fileName))
        }
    }

    /// Writes "n of total" into every song in list order, then optionally renames the files to match.
    func applyNumbering(setNumbers: Bool, renameFiles: Bool, style: NamingStyle) async {
        if setNumbers {
            let total = tracks.count
            for (i, t) in tracks.enumerated() {
                t.fields.trackNumber = i + 1
                t.fields.trackTotal = total
            }
        }
        await save(tracks)
        guard renameFiles else { return }
        guard !hasUnsavedChanges else {
            show("Some songs couldn’t be saved, so nothing was renamed.", error: true)
            return
        }
        let plan = plannedNames(style: style).map { t, name in
            (t, t.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        checkpoint()
        isRenaming = true
        defer { isRenaming = false }
        do {
            try FileNaming.perform(plan.map { FileNaming.Rename(from: $0.0.url, to: $0.1) })
            let changes = plan.filter { pathKey($0.0.url) != pathKey($0.1) || $0.0.url.lastPathComponent != $0.1.lastPathComponent }
                .map { RenameChange(track: $0.0, old: $0.0.url, new: $0.1) }
            for (t, newURL) in plan {
                t.url = newURL
                t.modified = fileModificationDate(newURL)
            }
            if !changes.isEmpty { record(.renamed(changes)) }
            rebaseline()
            show("Numbered and renamed \(plan.count) songs — ⌘Z to undo")
        } catch {
            show(error.localizedDescription, error: true)
            isRenaming = false
            reload()
        }
    }

    // MARK: Clean-up

    func scanFolder() -> FolderScan? {
        guard let folderURL else { return nil }
        return try? FolderScanner.scan(folderURL)
    }

    /// Clean Up: hidden "._" sidecars and system files are deleted outright (macOS recreates them anyway);
    /// everything else goes to the Trash so ⌘Z can bring it back.
    func delete(_ urls: [URL]) {
        checkpoint()
        var trashed: [TrashedFile] = []
        var failed = 0
        for url in urls {
            let name = url.lastPathComponent
            let disposable = name.hasPrefix("._") || name == ".DS_Store" || name.hasPrefix(".yame-")
            do {
                if disposable {
                    try FileManager.default.removeItem(at: url)
                } else {
                    trashed.append(TrashedFile(originalURL: url, trashedURL: try moveToTrash(url), track: nil, index: 0))
                }
            } catch { failed += 1 }
        }
        if !trashed.isEmpty { record(.trashed(trashed)) }
        rebaseline()
        if failed > 0 {
            show("\(failed) file(s) couldn’t be removed", error: true)
        } else {
            show("Removed \(urls.count) file(s)" + (trashed.isEmpty ? "" : " — ⌘Z to restore"))
        }
    }

    // MARK: Drive

    private var volumeValues: URLResourceValues? {
        guard let url = folderURL ?? tracks.first?.url else { return nil }
        return try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeNameKey])
    }

    var canEject: Bool {
        guard let v = volumeValues else { return false }
        return (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false)
    }

    var volumeName: String? { volumeValues?.volumeName }

    func eject() {
        guard let volume = volumeValues?.volume, confirmDiscardingChanges() else { return }
        let name = volumeValues?.volumeName ?? "Drive"
        stopPlayback()
        stopWatching()
        tracks = []
        selection = []
        folderURL = nil
        resetHistory()
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            show("“\(name)” ejected. It’s safe to unplug.")
        } catch {
            show("Couldn’t eject “\(name)”: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Playback preview

    func togglePlayback(_ track: TrackItem) {
        if playingID == track.id { stopPlayback(); return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: track.url)
            p.play()
            player = p
            playingID = track.id
        } catch {
            show("Can’t play \(track.fileName).", error: true)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    // MARK: Messages

    func show(_ text: String, error: Bool = false) {
        withAnimation(.snappy) { banner = Banner(text: text, isError: error) }
    }
}
