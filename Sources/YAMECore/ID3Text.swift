import Foundation

/// Text encoding helpers for ID3 frames.
enum ID3Text {
    // MARK: Decoding

    /// Decodes one string in the given ID3 encoding (0 Latin-1, 1 UTF-16+BOM, 2 UTF-16BE, 3 UTF-8).
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String {
        var b = Array(bytes)
        switch encoding {
        case 1, 2:
            // Drop a trailing null terminator / odd byte.
            if b.count % 2 == 1 { b.removeLast() }
            while b.count >= 2, b[b.count - 1] == 0, b[b.count - 2] == 0 { b.removeLast(2) }
            var bigEndian = encoding == 2
            if b.count >= 2 {
                if b[0] == 0xFF && b[1] == 0xFE { bigEndian = false; b.removeFirst(2) }
                else if b[0] == 0xFE && b[1] == 0xFF { bigEndian = true; b.removeFirst(2) }
            }
            var units: [UInt16] = []
            units.reserveCapacity(b.count / 2)
            var i = 0
            while i + 1 < b.count {
                let u = bigEndian ? (UInt16(b[i]) << 8 | UInt16(b[i + 1])) : (UInt16(b[i + 1]) << 8 | UInt16(b[i]))
                units.append(u)
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 3:
            while let last = b.last, last == 0 { b.removeLast() }
            return String(decoding: b, as: UTF8.self)
        default:
            while let last = b.last, last == 0 { b.removeLast() }
            var s = ""
            s.unicodeScalars.reserveCapacity(b.count)
            for byte in b { s.unicodeScalars.append(Unicode.Scalar(byte)) }
            return s
        }
    }

    /// Splits a text frame body (first byte = encoding) into its null-separated strings.
    static func decodeStrings(_ body: ArraySlice<UInt8>) -> [String] {
        guard let enc = body.first else { return [] }
        let rest = body.dropFirst()
        return split(rest, encoding: enc).map { decode($0, encoding: enc) }
    }

    /// Splits on the terminator for the encoding (1 zero byte, or 2 aligned zero bytes for UTF-16).
    static func split(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> [ArraySlice<UInt8>] {
        var parts: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        if encoding == 1 || encoding == 2 {
            var i = bytes.startIndex
            while i + 1 < bytes.endIndex {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    parts.append(bytes[start..<i])
                    start = i + 2
                }
                i += 2
            }
        } else {
            for i in bytes.indices where bytes[i] == 0 {
                parts.append(bytes[start..<i])
                start = i + 1
            }
        }
        if start < bytes.endIndex { parts.append(bytes[start..<bytes.endIndex]) }
        // Drop empty trailing parts produced by terminators / padding.
        while let last = parts.last, last.isEmpty, parts.count > 1 { parts.removeLast() }
        return parts
    }

    /// Finds the end of a terminated string starting at `from`; returns (stringBytes, indexAfterTerminator).
    static func readTerminated(_ bytes: [UInt8], from: Int, encoding: UInt8) -> (ArraySlice<UInt8>, Int) {
        if encoding == 1 || encoding == 2 {
            var i = from
            while i + 1 < bytes.count {
                if bytes[i] == 0 && bytes[i + 1] == 0 { return (bytes[from..<i], i + 2) }
                i += 2
            }
            return (bytes[from..<bytes.count], bytes.count)
        } else {
            var i = from
            while i < bytes.count {
                if bytes[i] == 0 { return (bytes[from..<i], i + 1) }
                i += 1
            }
            return (bytes[from..<bytes.count], bytes.count)
        }
    }

    // MARK: Encoding (ID3v2.3: Latin-1 or UTF-16 with BOM)

    /// Returns (encodingByte, bytes) choosing Latin-1 when possible, else UTF-16LE with BOM.
    static func encode(_ string: String) -> (UInt8, [UInt8]) {
        let s = string.precomposedStringWithCanonicalMapping
        if s.unicodeScalars.allSatisfy({ $0.value < 256 }) {
            return (0, s.unicodeScalars.map { UInt8($0.value) })
        }
        var out: [UInt8] = [0xFF, 0xFE]
        for u in s.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return (1, out)
    }

    static func terminator(for encoding: UInt8) -> [UInt8] { encoding == 1 || encoding == 2 ? [0, 0] : [0] }

    /// A text-information frame body ("T***").
    static func textFrameBody(_ string: String) -> [UInt8] {
        let (enc, bytes) = encode(string)
        return [enc] + bytes
    }

    /// Encodes several strings into one body using a single shared encoding.
    static func multiStringBody(_ strings: [String]) -> [UInt8] {
        let joined = strings.joined(separator: "\u{0}")
        let needsUTF16 = !joined.precomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy { $0.value < 256 }
        var out: [UInt8] = [needsUTF16 ? 1 : 0]
        for (i, s) in strings.enumerated() {
            if i > 0 { out += terminator(for: needsUTF16 ? 1 : 0) }
            let n = s.precomposedStringWithCanonicalMapping
            if needsUTF16 {
                out += [0xFF, 0xFE]
                for u in n.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
            } else {
                out += n.unicodeScalars.map { UInt8($0.value) }
            }
        }
        return out
    }

    /// ASCII/Latin-1 approximation for ID3v1 (accents removed, others become "?").
    static func latin1Approximation(_ string: String, maxBytes: Int) -> [UInt8] {
        let folded = string.precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [UInt8] = []
        for scalar in folded.unicodeScalars {
            if out.count >= maxBytes { break }
            if scalar.value < 32 { continue }
            out.append(scalar.value < 256 ? UInt8(scalar.value) : 0x3F)
        }
        return out
    }
}

/// The standard ID3v1 genre list (with the common Winamp extensions).
public enum ID3Genres {
    public static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass",
        "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic",
        "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove",
        "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall",
    ]

    /// Resolves "(17)", "17", "(17)Rock" or a plain name to a display name.
    public static func resolve(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s), names.indices.contains(n) { return names[n] }
        if s.hasPrefix("("), let close = s.firstIndex(of: ")") {
            let inner = s[s.index(after: s.startIndex)..<close]
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            if inner == "RX" { return "Remix" }
            if inner == "CR" { return "Cover" }
            if let n = Int(inner), names.indices.contains(n) { return names[n] }
        }
        return s
    }

    public static func index(of name: String) -> UInt8? {
        let lower = name.lowercased()
        guard let i = names.firstIndex(where: { $0.lowercased() == lower }) else { return nil }
        return UInt8(i)
    }
}
