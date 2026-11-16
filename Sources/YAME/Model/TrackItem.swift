import AppKit
import Observation
import YAMECore

/// One song in the list, with its edited and last-saved tags.
@MainActor
@Observable
final class TrackItem: Identifiable {
    let id = UUID()
    var url: URL
    var fields: TagFields
    private(set) var saved: TagFields
    /// Frames YAME doesn't edit (comments, lyrics, ReplayGain…), written back unchanged.
    private(set) var otherFrames: [ID3Frame]
    private(set) var originalVersion: UInt8
    /// Decoded cover for display. Kept in sync through `setCover`.
    private(set) var coverImage: NSImage?
    /// The file's modification date when last read or saved (to spot changes made by other apps).
    var modified: Date?
    var duration: Double?
    var errorMessage: String?

    init(_ loaded: LoadedSong) {
        let tag = loaded.tag ?? ID3Tag()
        url = loaded.url
        fields = tag.fields
        saved = tag.fields
        otherFrames = tag.otherFrames
        originalVersion = tag.version
        coverImage = tag.fields.cover.flatMap { NSImage(data: $0.data) }
        modified = loaded.modified
        errorMessage = loaded.error
    }

    var isDirty: Bool { fields != saved }
    var fileName: String { url.lastPathComponent }
    var displayTitle: String { fields.title.isEmpty ? url.deletingPathExtension().lastPathComponent : fields.title }
    var carIssues: [CarCheck.Issue] { CarCheck.issues(for: fields) }

    func setCover(_ cover: CoverArt?) {
        fields.cover = cover
        coverImage = cover.flatMap { NSImage(data: $0.data) }
    }

    /// Puts back tags from undo/redo.
    func restore(_ f: TagFields) {
        let coverChanged = f.cover != fields.cover
        fields = f
        if coverChanged { coverImage = f.cover.flatMap { NSImage(data: $0.data) } }
    }

    func revert() {
        fields = saved
        coverImage = saved.cover.flatMap { NSImage(data: $0.data) }
        errorMessage = nil
    }

    func markSaved(modified: Date?) {
        saved = fields
        self.modified = modified
        errorMessage = nil
    }

    /// Records a track number written by auto-number, without touching other unsaved edits.
    func applySavedNumber(_ n: Int, of total: Int, modified: Date?) {
        saved.trackNumber = n
        saved.trackTotal = total
        fields.trackNumber = n
        fields.trackTotal = total
        self.modified = modified
    }

    /// Picks up changes another app made to the file.
    func reload(from loaded: LoadedSong) {
        let tag = loaded.tag ?? ID3Tag()
        fields = tag.fields
        saved = tag.fields
        otherFrames = tag.otherFrames
        originalVersion = tag.version
        coverImage = tag.fields.cover.flatMap { NSImage(data: $0.data) }
        modified = loaded.modified
        errorMessage = loaded.error
    }
}
