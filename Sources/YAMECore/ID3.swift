import Foundation

/// A frame kept in ID3v2.3 form (id, flags and body exactly as they will be written).
public struct ID3Frame: Equatable, Hashable, Sendable {
    public var id: String
    public var flags: UInt16
    public var body: [UInt8]

    public init(id: String, flags: UInt16 = 0, body: [UInt8]) {
        self.id = id
        self.flags = flags
        self.body = body
    }
}

/// The result of reading a file's tag.
public struct ID3Tag: Equatable, Sendable {
    /// 2, 3 or 4 for an ID3v2 tag; 1 when only ID3v1 was found; 0 when untagged.
    public var version: UInt8 = 0
    public var fields = TagFields()
    /// Frames YAME does not edit, converted to v2.3 so they survive a save.
    public var otherFrames: [ID3Frame] = []
    public init() {}
}

public enum ID3Error: LocalizedError {
    case writeFailed(String)
    case renameConflict(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let m): return m
        case .renameConflict(let m): return m
        }
    }
}

/// Frames that YAME manages itself; everything else is preserved untouched.
let managedFrameIDs: Set<String> = ["TIT2", "TPE1", "TALB", "TPE2", "TCON", "TYER", "TDRC", "TRCK", "APIC"]

/// v2.4-only frames that are not valid in v2.3 (dropped on conversion).
private let v24OnlyFrameIDs: Set<String> = [
    "TDRC", "TDOR", "TDRL", "TDTG", "TDEN", "TIPL", "TMCL", "TMOO", "TPRO", "TSOA", "TSOP", "TSOT", "TSST", "ASPI", "EQU2", "RVA2", "SEEK", "SIGN",
]

/// ID3v2.2 three-letter ids we understand, mapped to v2.3.
private let v22Map: [String: String] = [
    "TT2": "TIT2", "TP1": "TPE1", "TAL": "TALB", "TP2": "TPE2", "TCO": "TCON", "TYE": "TYER", "TRK": "TRCK",
    "COM": "COMM", "ULT": "USLT", "TCM": "TCOM", "TPA": "TPOS", "TBP": "TBPM", "TT1": "TIT1", "TT3": "TIT3", "PIC": "APIC",
]

// MARK: - Reading

public enum ID3Reader {
    /// Total size in bytes of the ID3v2 tag at the start of `header` (needs ≥ 10 bytes), or nil.
    public static func tagSize(header: [UInt8]) -> Int? {
        guard header.count >= 10, header[0] == 0x49, header[1] == 0x44, header[2] == 0x33,
              header[3] >= 2, header[3] <= 4 else { return nil }
        let size = syncsafe(header, 6)
        let footer = (header[3] == 4 && header[5] & 0x10 != 0) ? 10 : 0
        return 10 + size + footer
    }

    /// Parses a complete ID3v2 tag (header included).
    public static func parse(_ tag: [UInt8]) -> ID3Tag {
        var result = ID3Tag()
        guard tag.count >= 10, tagSize(header: tag) != nil else { return result }
        let major = tag[3]
        let flags = tag[5]
        let size = syncsafe(tag, 6)
        var body = Array(tag[10..<min(tag.count, 10 + size)])
        result.version = major

        if major < 4 && flags & 0x80 != 0 { body = deunsynchronise(body) }
        var pos = 0
        if flags & 0x40 != 0 {
            if major == 2 { return result }                  // v2.2 "compression": unsupported
            if major == 3, body.count >= 4 { pos = 4 + be32(body, 0) }
            if major == 4, body.count >= 4 { pos = syncsafe(body, 0) }
        }

        var frames: [ID3Frame] = []
        if major == 2 {
            while pos + 6 <= body.count {
                guard body[pos] != 0 else { break }
                let id = String(decoding: body[pos..<pos + 3], as: UTF8.self)
                let len = Int(body[pos + 3]) << 16 | Int(body[pos + 4]) << 8 | Int(body[pos + 5])
                let start = pos + 6
                guard len >= 0, start + len <= body.count else { break }
                var frameBody = Array(body[start..<start + len])
                if let mapped = v22Map[id] {
                    if mapped == "APIC", frameBody.count > 5 {
                        // PIC: enc, 3-char format, type, desc… → APIC: enc, mime\0, type, desc…
                        let fmt = String(decoding: frameBody[1..<4], as: UTF8.self).uppercased()
                        let mime = fmt == "PNG" ? "image/png" : "image/jpeg"
                        frameBody = [frameBody[0]] + Array(mime.utf8) + [0] + Array(frameBody[4...])
                    }
                    frames.append(ID3Frame(id: mapped, flags: 0, body: frameBody))
                }
                pos = start + len
            }
        } else {
            while pos + 10 <= body.count {
                guard isValidFrameID(body, pos) else { break }
                let id = String(decoding: body[pos..<pos + 4], as: UTF8.self)
                var len = major == 4 ? syncsafe(body, pos + 4) : be32(body, pos + 4)
                if major == 4 {
                    // Some writers (old iTunes) store plain 32-bit sizes in v2.4.
                    let plain = be32(body, pos + 4)
                    if plain != len, !nextIsValid(body, pos + 10 + len), nextIsValid(body, pos + 10 + plain) { len = plain }
                }
                let frameFlags = UInt16(body[pos + 8]) << 8 | UInt16(body[pos + 9])
                let start = pos + 10
                guard len >= 0, start + len <= body.count else { break }
                var frameBody = Array(body[start..<start + len])
                pos = start + len

                if major == 3 {
                    let compressedOrEncrypted = frameFlags & 0x00C0 != 0
                    if compressedOrEncrypted {
                        if !managedFrameIDs.contains(id) { frames.append(ID3Frame(id: id, flags: frameFlags, body: frameBody)) }
                        continue
                    }
                    if frameFlags & 0x0020 != 0 {
                        // Grouping byte: keep raw for preservation, strip for parsing.
                        if managedFrameIDs.contains(id) { frameBody = Array(frameBody.dropFirst()) }
                        else { frames.append(ID3Frame(id: id, flags: frameFlags, body: frameBody)); continue }
                    }
                    frames.append(ID3Frame(id: id, flags: managedFrameIDs.contains(id) ? 0 : frameFlags, body: frameBody))
                } else {
                    let fmt = UInt8(frameFlags & 0xFF)
                    if fmt & 0x0C != 0 { continue }                       // compressed / encrypted: drop
                    if fmt & 0x40 != 0 { frameBody = Array(frameBody.dropFirst()) }   // grouping id
                    if fmt & 0x01 != 0 { frameBody = Array(frameBody.dropFirst(4)) }  // data length indicator
                    if fmt & 0x02 != 0 { frameBody = deunsynchronise(frameBody) }
                    frames.append(ID3Frame(id: id, flags: 0, body: frameBody))
                }
            }
        }

        result.fields = fields(from: frames)
        result.otherFrames = frames.compactMap { convertForV23($0, sourceVersion: major) }
        return result
    }

    /// Parses a 128-byte ID3v1 tag.
    public static func parseV1(_ b: [UInt8]) -> TagFields? {
        guard b.count == 128, b[0] == 0x54, b[1] == 0x41, b[2] == 0x47 else { return nil }
        func str(_ r: Range<Int>) -> String {
            ID3Text.decode(b[r], encoding: 0).trimmingCharacters(in: .whitespaces)
        }
        var f = TagFields()
        f.title = str(3..<33)
        f.artist = str(33..<63)
        f.album = str(63..<93)
        f.year = str(93..<97)
        if b[125] == 0 && b[126] != 0 { f.trackNumber = Int(b[126]) }
        if ID3Genres.names.indices.contains(Int(b[127])) { f.genre = ID3Genres.names[Int(b[127])] }
        return f
    }

    // MARK: Helpers

    static func fields(from frames: [ID3Frame]) -> TagFields {
        var f = TagFields()
        var covers: [CoverArt] = []
        for frame in frames {
            let text: () -> String = {
                ID3Text.decodeStrings(frame.body[...]).filter { !$0.isEmpty }.joined(separator: "; ")
            }
            switch frame.id {
            case "TIT2": f.title = text()
            case "TPE1": f.artist = text()
            case "TALB": f.album = text()
            case "TPE2": f.albumArtist = text()
            case "TCON": f.genre = ID3Text.decodeStrings(frame.body[...]).filter { !$0.isEmpty }.map(ID3Genres.resolve).joined(separator: "; ")
            case "TYER": if f.year.isEmpty { f.year = String(text().prefix(4)) }
            case "TDRC": f.year = String(text().prefix(4))
            case "TRCK": (f.trackNumber, f.trackTotal) = TagFields.parseTrack(text())
            case "APIC": if let c = parseAPIC(frame.body) { covers.append(c) }
            default: break
            }
        }
        f.cover = covers.first(where: { $0.pictureType == 3 }) ?? covers.first
        return f
    }

    static func parseAPIC(_ body: [UInt8]) -> CoverArt? {
        guard body.count > 4 else { return nil }
        let enc = body[0]
        let (mimeBytes, afterMime) = ID3Text.readTerminated(body, from: 1, encoding: 0)
        guard afterMime < body.count else { return nil }
        let type = body[afterMime]
        let (descBytes, afterDesc) = ID3Text.readTerminated(body, from: afterMime + 1, encoding: enc)
        guard afterDesc <= body.count else { return nil }
        let data = Data(body[afterDesc...])
        guard !data.isEmpty else { return nil }
        var mime = String(decoding: mimeBytes, as: UTF8.self).lowercased()
        if mime.isEmpty || mime == "image/jpg" || !mime.contains("/") { mime = CoverArt.sniffMIMEType(data) }
        return CoverArt(data: data, mimeType: mime, pictureType: type, description: ID3Text.decode(descBytes, encoding: enc))
    }

    /// Converts a frame to valid v2.3 form for preservation, or nil to drop it.
    static func convertForV23(_ frame: ID3Frame, sourceVersion: UInt8) -> ID3Frame? {
        if managedFrameIDs.contains(frame.id) { return nil }
        if sourceVersion == 3 { return frame }
        if v24OnlyFrameIDs.contains(frame.id) { return nil }
        let id = frame.id
        if id.hasPrefix("T") {
            guard let enc = frame.body.first else { return nil }
            if enc <= 1 { return ID3Frame(id: id, flags: 0, body: frame.body) }
            let strings = ID3Text.decodeStrings(frame.body[...])
            if id == "TXXX" { return ID3Frame(id: id, flags: 0, body: ID3Text.multiStringBody(Array(strings.prefix(2)))) }
            return ID3Frame(id: id, flags: 0, body: ID3Text.textFrameBody(strings.joined(separator: "/")))
        }
        if id == "COMM" || id == "USLT" {
            guard frame.body.count >= 4 else { return nil }
            let enc = frame.body[0]
            if enc <= 1 { return frame }
            let lang = Array(frame.body[1..<4])
            let (descBytes, after) = ID3Text.readTerminated(frame.body, from: 4, encoding: enc)
            let desc = ID3Text.decode(descBytes, encoding: enc)
            let text = after < frame.body.count ? ID3Text.decode(frame.body[after...], encoding: enc) : ""
            let multi = ID3Text.multiStringBody([desc, text])
            return ID3Frame(id: id, flags: 0, body: [multi[0]] + lang + Array(multi.dropFirst()))
        }
        // Binary frames with identical layout in v2.3 and v2.4.
        if ["PRIV", "UFID", "GEOB", "PCNT", "POPM", "MCDI", "WXXX"].contains(id) || id.hasPrefix("W") {
            return frame
        }
        return nil
    }

    static func syncsafe(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 3 < b.count else { return 0 }
        return Int(b[i] & 0x7F) << 21 | Int(b[i + 1] & 0x7F) << 14 | Int(b[i + 2] & 0x7F) << 7 | Int(b[i + 3] & 0x7F)
    }

    static func be32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 3 < b.count else { return 0 }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    static func deunsynchronise(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 { i += 2 } else { i += 1 }
        }
        return out
    }

    static func isValidFrameID(_ b: [UInt8], _ i: Int) -> Bool {
        guard i + 4 <= b.count else { return false }
        for k in i..<i + 4 {
            let c = b[k]
            if !((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)) { return false }
        }
        return true
    }

    static func nextIsValid(_ b: [UInt8], _ i: Int) -> Bool {
        if i == b.count { return true }
        if i > b.count { return false }
        if b[i] == 0 { return true }   // padding
        return isValidFrameID(b, i)
    }
}

// MARK: - Writing

public enum ID3Writer {
    /// Builds a complete ID3v2.3 tag.
    public static func buildV23(_ f: TagFields, otherFrames: [ID3Frame] = [], padding: Int = 1024) -> [UInt8] {
        var frames: [ID3Frame] = []
        func text(_ id: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { frames.append(ID3Frame(id: id, body: ID3Text.textFrameBody(v))) }
        }
        text("TIT2", f.title)
        text("TPE1", f.artist)
        text("TALB", f.album)
        text("TPE2", f.albumArtist)
        text("TRCK", f.trackString)
        text("TYER", f.year)
        text("TCON", f.genre)
        if let c = f.cover, !c.data.isEmpty {
            var body: [UInt8] = [0]
            body += Array(c.mimeType.utf8) + [0]
            body.append(c.pictureType)
            let (enc, desc) = ID3Text.encode(c.description)
            body[0] = enc
            body += desc + ID3Text.terminator(for: enc)
            body += [UInt8](c.data)
            frames.append(ID3Frame(id: "APIC", body: body))
        }
        frames += otherFrames.filter { !managedFrameIDs.contains($0.id) }

        var out: [UInt8] = []
        for frame in frames {
            out += Array(frame.id.utf8.prefix(4))
            let n = frame.body.count
            out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += [UInt8(frame.flags >> 8), UInt8(frame.flags & 0xFF)]
            out += frame.body
        }
        out += [UInt8](repeating: 0, count: max(0, padding))
        let size = out.count
        let header: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0,
                               UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        return header + out
    }

    /// Builds a 128-byte ID3v1.1 tag.
    public static func buildV1(_ f: TagFields) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 128)
        b[0] = 0x54; b[1] = 0x41; b[2] = 0x47
        func put(_ s: String, _ at: Int, _ len: Int) {
            for (i, byte) in ID3Text.latin1Approximation(s, maxBytes: len).enumerated() { b[at + i] = byte }
        }
        put(f.title, 3, 30)
        put(f.artist, 33, 30)
        put(f.album, 63, 30)
        put(String(f.year.prefix(4)), 93, 4)
        b[125] = 0
        b[126] = UInt8(clamping: f.trackNumber ?? 0)
        b[127] = ID3Genres.index(of: f.genre) ?? 255
        return b
    }
}
