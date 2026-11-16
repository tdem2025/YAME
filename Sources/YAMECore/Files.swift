import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - File naming

public enum NamingStyle: String, CaseIterable, Identifiable, Sendable {
    case artistTitle   // "01 Artist - Title.mp3"
    case title         // "01 Title.mp3"
    case keepName      // "01 <current name without its number>.mp3"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .artistTitle: return "01 Artist - Title"
        case .title: return "01 Title"
        case .keepName: return "01 Current name"
        }
    }
}

public enum FileNaming {
    /// Characters that are illegal on FAT32/exFAT car USB drives (and on macOS for "/" and ":").
    static let illegal: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// Makes a string safe for a file name on any drive: NFC, no illegal or control characters.
    public static func sanitize(_ s: String, maxLength: Int = 150) -> String {
        var out = ""
        for scalar in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            if illegal.contains(scalar) || scalar.value < 32 || scalar.value == 0x7F { continue }
            // Full-width look-alikes ("：", "｜") that some downloaders insert.
            if scalar.value == 0xFF1A || scalar.value == 0xFF5C { out.unicodeScalars.append(" "); continue }
            out.unicodeScalars.append(scalar)
        }
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if out.count > maxLength { out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return out
    }

    /// Removes a leading track number like "01 ", "1. ", "03 - ".
    public static func stripNumberPrefix(_ name: String) -> String {
        var s = Substring(name)
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return name }
        s = s.dropFirst(digits.count)
        let sep = s.prefix(while: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        guard !sep.isEmpty else { return name }
        let rest = String(s.dropFirst(sep.count))
        return rest.isEmpty ? name : rest
    }

    /// Zero-padded number for a playlist of `total` songs (at least two digits).
    public static func number(_ n: Int, total: Int) -> String {
        let width = max(2, String(total).count)
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// The new file name for a song at position `index` (1-based).
    public static func fileName(index: Int, total: Int, style: NamingStyle, fields: TagFields,
                                currentName: String, ext: String = "mp3") -> String {
        let num = number(index, total: total)
        let currentBase = stripNumberPrefix((currentName as NSString).deletingPathExtension)
        let artist = sanitize(fields.artist)
        let title = sanitize(fields.title)
        var base: String
        switch style {
        case .artistTitle:
            if !artist.isEmpty && !title.isEmpty { base = "\(artist) - \(title)" }
            else if !title.isEmpty { base = title }
            else { base = sanitize(currentBase) }
        case .title:
            base = title.isEmpty ? sanitize(currentBase) : title
        case .keepName:
            base = sanitize(currentBase)
        }
        if base.isEmpty { base = "Track" }
        return "\(num) \(base).\(ext)"
    }

    public struct Rename: Equatable, Sendable {
        public let from: URL
        public let to: URL
        public init(from: URL, to: URL) { self.from = from; self.to = to }
    }

    /// Renames in two phases (via temporary names) so swapping names never collides.
    /// Also moves macOS "._" sidecar files out of the way.
    public static func perform(_ renames: [Rename]) throws {
        let fm = FileManager.default
        let changes = renames.filter { $0.from.standardizedFileURL != $0.to.standardizedFileURL }
        guard !changes.isEmpty else { return }

        // Destinations must be unique (case-insensitively: FAT, exFAT and APFS usually are).
        var seen = Set<String>()
        for r in changes {
            let key = r.to.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            if !seen.insert(key).inserted {
                throw ID3Error.renameConflict("Two songs would both be named “\(r.to.lastPathComponent)”.")
            }
        }
        // A destination may only exist if it is one of the files being renamed.
        let sources = Set(changes.map { $0.from.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() })
        for r in changes where fm.fileExists(atPath: r.to.path) {
            let key = r.to.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            if !sources.contains(key) {
                throw ID3Error.renameConflict("“\(r.to.lastPathComponent)” already exists in this folder.")
            }
        }

        var staged: [(URL, URL)] = []
        for r in changes {
            let tmp = r.from.deletingLastPathComponent().appendingPathComponent(".yame-rename-\(UUID().uuidString)")
            if rename(r.from.path, tmp.path) != 0 {
                // Roll back what was staged so far.
                for (t, original) in staged.reversed() { _ = rename(t.path, original.path) }
                throw ID3Error.writeFailed("Couldn’t rename \(r.from.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            staged.append((tmp, r.from))
            try? fm.removeItem(at: r.from.deletingLastPathComponent().appendingPathComponent("._" + r.from.lastPathComponent))
        }
        for (i, r) in changes.enumerated() {
            if rename(staged[i].0.path, r.to.path) != 0 {
                throw ID3Error.writeFailed("Couldn’t rename to \(r.to.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Folder scanning / clean-up

public struct FolderScan: Equatable, Sendable {
    /// MP3s, sorted in Finder order.
    public var songs: [URL] = []
    /// macOS "._name" AppleDouble files (created when a Mac writes to a USB drive).
    public var appleDouble: [URL] = []
    /// .DS_Store, Thumbs.db, desktop.ini, leftover temp files.
    public var system: [URL] = []
    /// Everything else that is not a song (pasted .tiff images, PNGs, text files…).
    public var other: [URL] = []
    public var subfolders: [URL] = []

    public var junkCount: Int { appleDouble.count + system.count + other.count }

    public init() {}
}

public enum FolderScanner {
    public static let songExtensions: Set<String> = ["mp3"]
    static let systemNames: Set<String> = [".ds_store", "thumbs.db", "desktop.ini", ".localized"]

    public static func scan(_ folder: URL) throws -> FolderScan {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: folder.path)
        var scan = FolderScan()
        for name in names {
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let lower = name.lowercased()
            if isDir.boolValue {
                if name == ".yame-trash" { scan.system.append(url) }   // YAME's undo holding area on drives without a Trash
                else if !name.hasPrefix(".") { scan.subfolders.append(url) }
                continue
            }
            if name.hasPrefix("._") { scan.appleDouble.append(url) }
            else if systemNames.contains(lower) || lower.hasPrefix(".yame-") { scan.system.append(url) }
            else if name.hasPrefix(".") { continue }
            else if songExtensions.contains(url.pathExtension.lowercased()) { scan.songs.append(url) }
            else { scan.other.append(url) }
        }
        let finder: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        scan.songs.sort(by: finder)
        scan.appleDouble.sort(by: finder)
        scan.system.sort(by: finder)
        scan.other.sort(by: finder)
        scan.subfolders.sort(by: finder)
        return scan
    }

    /// Files that are almost certainly accidental (pasted screenshots, image dumps).
    public static func isLikelyJunk(_ url: URL) -> Bool {
        ["tif", "tiff", "heic", "png", "webp", "gif", "bmp"].contains(url.pathExtension.lowercased())
    }
}

// MARK: - YouTube thumbnails

public enum YouTube {
    /// Extracts the 11-character video id from a link or a bare id.
    public static func videoID(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isID(s) { return s }
        let withScheme = s.contains("://") ? s : "https://" + s
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased() else { return nil }
        let path = comps.path.split(separator: "/").map(String.init)
        if host.hasSuffix("youtu.be") { return path.first.flatMap { isID($0) ? $0 : nil } }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, isID(v) { return v }
        if path.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(path[0]), isID(path[1]) { return path[1] }
        return nil
    }

    /// Thumbnail URLs from best to worst quality.
    public static func thumbnailURLs(for id: String) -> [URL] {
        ["maxresdefault", "sddefault", "hqdefault", "mqdefault"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg")
        }
    }

    static func isID(_ s: String) -> Bool {
        s.count == 11 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }
}

// MARK: - Car compatibility

public struct CarCheck: Equatable, Sendable {
    public struct Issue: Equatable, Hashable, Sendable {
        public let message: String
        public let isProblem: Bool
    }

    /// Things that commonly stop a car head unit (Mercedes NTG/MBUX, etc.) showing info or artwork.
    public static func issues(for f: TagFields, maxCoverSide: Int = 800) -> [Issue] {
        var out: [Issue] = []
        if f.title.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(message: "No song title", isProblem: true)) }
        if f.artist.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(message: "No artist", isProblem: true)) }
        if f.album.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.init(message: "No album", isProblem: false)) }
        if f.trackNumber == nil { out.append(.init(message: "No track number (play order may be alphabetical)", isProblem: false)) }
        if let c = f.cover {
            if !c.isJPEG { out.append(.init(message: "Cover is \(c.mimeType.replacingOccurrences(of: "image/", with: "").uppercased()), not JPEG", isProblem: true)) }
            if c.isProgressiveJPEG { out.append(.init(message: "Cover is a progressive JPEG", isProblem: true)) }
            if let s = c.pixelSize {
                if max(s.width, s.height) > maxCoverSide { out.append(.init(message: "Cover is \(s.width)×\(s.height) (over \(maxCoverSide) px)", isProblem: true)) }
                if s.width != s.height { out.append(.init(message: "Cover isn’t square", isProblem: false)) }
                if min(s.width, s.height) < 300 { out.append(.init(message: "Cover is small and may look blurry", isProblem: false)) }
            }
            if c.data.count > 400_000 { out.append(.init(message: "Cover file is large (\(c.data.count / 1000) KB)", isProblem: false)) }
        } else {
            out.append(.init(message: "No cover", isProblem: false))
        }
        return out
    }
}
