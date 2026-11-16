import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads and writes tags on MP3 files without touching the audio.
public enum MP3File {
    /// Reads only the tag bytes (fast, even on USB drives).
    public static func readTag(at url: URL) throws -> ID3Tag {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var tag = ID3Tag()
        let header = [UInt8](try handle.read(upToCount: 10) ?? Data())
        if let size = ID3Reader.tagSize(header: header) {
            try handle.seek(toOffset: 0)
            let bytes = [UInt8](try handle.read(upToCount: size) ?? Data())
            tag = ID3Reader.parse(bytes)
        }

        // Fall back to / fill gaps from ID3v1.
        let end = try handle.seekToEnd()
        if end >= 128 {
            try handle.seek(toOffset: end - 128)
            if let v1 = ID3Reader.parseV1([UInt8](try handle.read(upToCount: 128) ?? Data())) {
                if tag.version == 0 { tag.version = 1 }
                if tag.fields.title.isEmpty { tag.fields.title = v1.title }
                if tag.fields.artist.isEmpty { tag.fields.artist = v1.artist }
                if tag.fields.album.isEmpty { tag.fields.album = v1.album }
                if tag.fields.year.isEmpty { tag.fields.year = v1.year }
                if tag.fields.genre.isEmpty { tag.fields.genre = v1.genre }
                if tag.fields.trackNumber == nil { tag.fields.trackNumber = v1.trackNumber }
            }
        }
        return tag
    }

    /// Rewrites the file with a fresh ID3v2.3 tag (+ optional ID3v1), keeping the audio bytes identical.
    /// - Parameter otherFrames: frames to preserve; pass nil to re-read them from the file.
    public static func write(_ fields: TagFields, to url: URL, otherFrames: [ID3Frame]? = nil,
                             writeV1: Bool = true, padding: Int = 1024) throws {
        if try writeInPlace(fields, to: url, otherFrames: otherFrames, writeV1: writeV1) { return }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (start, end) = audioRange(of: data)
        guard end > start else { throw ID3Error.writeFailed("\(url.lastPathComponent) has no audio data.") }

        let keep = try otherFrames ?? readTag(at: url).otherFrames
        var out = Data(ID3Writer.buildV23(fields, otherFrames: keep, padding: padding))
        out.append(data[start..<end])
        if writeV1 { out.append(contentsOf: ID3Writer.buildV1(fields)) }

        try replace(url, with: out)
    }

    /// Fast path: when the new tag fits in the space the old one takes up (thanks to padding),
    /// overwrite just the tag bytes instead of rewriting the whole file. Returns false if it can't.
    /// Small edits such as track numbers then cost ~1 KB of writing instead of the whole song.
    @discardableResult
    public static func writeInPlace(_ fields: TagFields, to url: URL, otherFrames: [ID3Frame]? = nil,
                                    writeV1: Bool = true) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let header = [UInt8](try handle.read(upToCount: 10) ?? Data())
        guard header.count == 10, header[3] == 3 || header[3] == 4, header[5] & 0x10 == 0,
              let size = ID3Reader.tagSize(header: header) else { return false }
        let end = try handle.seekToEnd()
        guard end > UInt64(size) + 128 else { return false }
        // Don't touch files with a second tag stacked after the first.
        try handle.seek(toOffset: UInt64(size))
        if [UInt8](try handle.read(upToCount: 3) ?? Data()) == [0x49, 0x44, 0x33] { return false }

        let keep = try otherFrames ?? readTag(at: url).otherFrames
        let minimal = ID3Writer.buildV23(fields, otherFrames: keep, padding: 0)
        guard minimal.count <= size else { return false }
        let tag = ID3Writer.buildV23(fields, otherFrames: keep, padding: size - minimal.count)
        guard tag.count == size else { return false }

        try handle.seek(toOffset: end - 128)
        let hasV1 = [UInt8](try handle.read(upToCount: 3) ?? Data()) == [0x54, 0x41, 0x47]

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(tag))
        if writeV1 {
            try handle.seek(toOffset: hasV1 ? end - 128 : end)
            try handle.write(contentsOf: Data(ID3Writer.buildV1(fields)))
        } else if hasV1 {
            try handle.truncate(atOffset: end - 128)
        }
        try handle.synchronize()
        return true
    }

    /// Byte range of the audio: after any leading ID3v2 tags, before a trailing ID3v1 tag.
    public static func audioRange(of data: Data) -> (Int, Int) {
        let base = data.startIndex
        var start = 0
        // Skip one or more stacked ID3v2 tags.
        while start + 10 <= data.count {
            let header = [UInt8](data[(base + start)..<(base + start + 10)])
            guard let size = ID3Reader.tagSize(header: header), start + size <= data.count else { break }
            start += size
        }
        var end = data.count
        if end - start >= 128 {
            let t = [UInt8](data[(base + end - 128)..<(base + end - 125)])
            if t == [0x54, 0x41, 0x47] {
                end -= 128
                // "TAG+" enhanced tag sits just before the v1 tag.
                if end - start >= 227 {
                    let p = [UInt8](data[(base + end - 227)..<(base + end - 223)])
                    if p == [0x54, 0x41, 0x47, 0x2B] { end -= 227 }
                }
            }
        }
        return (start, end)
    }

    /// Writes next to the original, then atomically renames over it.
    /// (Works on FAT32/exFAT USB drives, where exchange-style replacement is not supported.)
    static func replace(_ url: URL, with data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".yame-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.writeFailed("Couldn’t write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if rename(tmp.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.writeFailed("Couldn’t replace \(url.lastPathComponent): \(reason)")
        }
        // A "._" sidecar for the temp name may have been created on FAT drives.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("._" + tmp.lastPathComponent))
    }
}
