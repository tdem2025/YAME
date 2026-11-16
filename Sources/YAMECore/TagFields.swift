import Foundation

/// An embedded picture (ID3 `APIC` frame).
public struct CoverArt: Equatable, Hashable, Sendable {
    public var data: Data
    public var mimeType: String
    /// ID3 picture type. 3 = front cover.
    public var pictureType: UInt8
    public var description: String

    public init(data: Data, mimeType: String? = nil, pictureType: UInt8 = 3, description: String = "") {
        self.data = data
        self.mimeType = mimeType ?? CoverArt.sniffMIMEType(data)
        self.pictureType = pictureType
        self.description = description
    }

    /// Detects the image format from its first bytes.
    public static func sniffMIMEType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "image/gif" }
        if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return "image/jpeg"
    }

    public var isJPEG: Bool { CoverArt.sniffMIMEType(data) == "image/jpeg" }

    /// Pixel size read straight from the JPEG or PNG header (no image decoding).
    public var pixelSize: (width: Int, height: Int)? { ImageHeader.size(of: data) }

    /// Progressive JPEGs are not shown by many car head units.
    public var isProgressiveJPEG: Bool { ImageHeader.isProgressiveJPEG(data) }
}

/// The tag fields YAME edits.
public struct TagFields: Equatable, Hashable, Sendable {
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var albumArtist: String = ""
    public var genre: String = ""
    public var year: String = ""
    public var trackNumber: Int? = nil
    public var trackTotal: Int? = nil
    public var cover: CoverArt? = nil

    public init(title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
                genre: String = "", year: String = "", trackNumber: Int? = nil, trackTotal: Int? = nil,
                cover: CoverArt? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.cover = cover
    }

    /// "3/12", "3" or "".
    public var trackString: String {
        guard let n = trackNumber else { return "" }
        if let t = trackTotal { return "\(n)/\(t)" }
        return "\(n)"
    }

    /// Parses "3/12", "03", " 3 / 12 ".
    public static func parseTrack(_ s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let n = parts.first.flatMap { Int($0) }
        let t = parts.count > 1 ? Int(parts[1]) : nil
        return (n, t)
    }
}

/// Minimal JPEG / PNG header reader.
public enum ImageHeader {
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data)
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50 {
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            return (w, h)
        }
        if let sof = jpegSOF(b) { return (sof.width, sof.height) }
        return nil
    }

    public static func isProgressiveJPEG(_ data: Data) -> Bool {
        jpegSOF([UInt8](data))?.progressive ?? false
    }

    private static func jpegSOF(_ b: [UInt8]) -> (width: Int, height: Int, progressive: Bool)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }               // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }    // end / start of scan before any SOF
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let isSOF = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF, i + 8 < b.count {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                let progressive = [0xC2, 0xC6, 0xCA, 0xCE].contains(marker)
                return (w, h, progressive)
            }
            guard len >= 2 else { return nil }
            i += 2 + len
        }
        return nil
    }
}
