import XCTest
@testable import YAMECore

final class YAMECoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("yame-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Fake MPEG audio: frame-sync-looking bytes so we can check they survive untouched.
    func audioBytes(_ n: Int = 50_000) -> Data {
        var d = Data(count: n)
        for i in 0..<n { d[i] = UInt8((i * 31 + 7) & 0xFF) }
        d[0] = 0xFF; d[1] = 0xFB
        return d
    }

    func tinyJPEG(width: Int = 500, height: Int = 500, progressive: Bool = false) -> Data {
        // SOI, APP0, SOFn with dimensions, EOI — enough for header parsing.
        var b: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
        b += [0xFF, progressive ? 0xC2 : 0xC0, 0x00, 0x11, 0x08,
              UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
              0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        b += [0xFF, 0xD9]
        return Data(b)
    }

    func testRoundTripPreservesAudio() throws {
        let url = dir.appendingPathComponent("song.mp3")
        let audio = audioBytes()
        try audio.write(to: url)

        var f = TagFields()
        f.title = "Livin' On A Prayer"
        f.artist = "Bon Jovi"
        f.album = "THE MOST W CAR PLAYLIST OF ALL TIME"
        f.albumArtist = "Tigran Demirchyan"
        f.trackNumber = 26
        f.trackTotal = 50
        f.year = "1986"
        f.genre = "Rock"
        f.cover = CoverArt(data: tinyJPEG())
        try MP3File.write(f, to: url)

        let tag = try MP3File.readTag(at: url)
        XCTAssertEqual(tag.version, 3)
        XCTAssertEqual(tag.fields, f)

        let data = try Data(contentsOf: url)
        let (s, e) = MP3File.audioRange(of: data)
        XCTAssertEqual(data[s..<e], audio)
        XCTAssertEqual(data.count - e, 128, "ID3v1 tag appended")

        // Rewriting again must not grow the audio or stack tags.
        f.title = "Changed"
        f.cover = nil
        try MP3File.write(f, to: url)
        let data2 = try Data(contentsOf: url)
        let (s2, e2) = MP3File.audioRange(of: data2)
        XCTAssertEqual(data2[s2..<e2], audio)
        let tag2 = try MP3File.readTag(at: url)
        XCTAssertEqual(tag2.fields.title, "Changed")
        XCTAssertNil(tag2.fields.cover)
    }

    func testInPlaceUpdateKeepsSizeAndAudio() throws {
        let url = dir.appendingPathComponent("inplace.mp3")
        let audio = audioBytes(80_000)
        try audio.write(to: url)
        var f = TagFields(title: "Song", artist: "Artist", album: "Playlist", trackNumber: 7, trackTotal: 50,
                          cover: CoverArt(data: tinyJPEG()))
        try MP3File.write(f, to: url)                       // full rewrite, adds padding
        let size1 = try Data(contentsOf: url).count

        f.trackTotal = 51                                   // small change → in place
        XCTAssertTrue(try MP3File.writeInPlace(f, to: url))
        let data2 = try Data(contentsOf: url)
        XCTAssertEqual(data2.count, size1, "file size unchanged")
        let (s, e) = MP3File.audioRange(of: data2)
        XCTAssertEqual(data2[s..<e], audio)
        let back = try MP3File.readTag(at: url).fields
        XCTAssertEqual(back.trackString, "7/51")
        XCTAssertEqual(back.cover, f.cover)

        // Too big for the padding → in-place refuses, normal write still works.
        f.cover = CoverArt(data: tinyJPEG() + Data(count: 5000))
        XCTAssertFalse(try MP3File.writeInPlace(f, to: url))
        try MP3File.write(f, to: url)
        let data3 = try Data(contentsOf: url)
        let (s3, e3) = MP3File.audioRange(of: data3)
        XCTAssertEqual(data3[s3..<e3], audio)
        XCTAssertEqual(try MP3File.readTag(at: url).fields.cover?.data.count, f.cover?.data.count)

        // Without ID3v1 the trailer is removed in place.
        f.cover = nil
        try MP3File.write(f, to: url, writeV1: false)
        let data4 = try Data(contentsOf: url)
        XCTAssertNotEqual(Array(data4.suffix(128).prefix(3)), [0x54, 0x41, 0x47])
        let (s4, e4) = MP3File.audioRange(of: data4)
        XCTAssertEqual(data4[s4..<e4], audio)
    }

    func testUnicodeUsesUTF16AndSurvives() throws {
        let url = dir.appendingPathComponent("u.mp3")
        try audioBytes(2000).write(to: url)
        var f = TagFields()
        f.title = "We Are Young (feat. Janelle Mon\u{0061}\u{0301}e)"   // decomposed é
        f.artist = "fun."
        f.album = "Тест 🎵"
        try MP3File.write(f, to: url, writeV1: false)
        let back = try MP3File.readTag(at: url).fields
        XCTAssertEqual(back.title, "We Are Young (feat. Janelle Monáe)")
        XCTAssertEqual(back.album, "Тест 🎵")
        XCTAssertEqual(back.artist, "fun.")
    }

    func testReadsID3v24WithUTF8AndPreservesOtherFrames() throws {
        // Hand-build a v2.4 tag: TIT2 (UTF-8), TDRC, TXXX (UTF-8), PRIV.
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return Array(id.utf8) + [UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F), 0, 0] + body
        }
        var frames: [UInt8] = []
        frames += frame("TIT2", [3] + Array("Crème Brûlée".utf8))
        frames += frame("TDRC", [3] + Array("2019-05-01".utf8))
        frames += frame("TXXX", [3] + Array("MOOD".utf8) + [0] + Array("Happy ✓".utf8))
        frames += frame("PRIV", Array("owner".utf8) + [0, 1, 2, 3])
        let size = frames.count
        let tag: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)] + frames

        let url = dir.appendingPathComponent("v24.mp3")
        let audio = audioBytes(3000)
        try (Data(tag) + audio).write(to: url)

        let read = try MP3File.readTag(at: url)
        XCTAssertEqual(read.version, 4)
        XCTAssertEqual(read.fields.title, "Crème Brûlée")
        XCTAssertEqual(read.fields.year, "2019")
        XCTAssertEqual(Set(read.otherFrames.map(\.id)), ["TXXX", "PRIV"])

        var f = read.fields
        f.artist = "Someone"
        try MP3File.write(f, to: url, otherFrames: read.otherFrames)
        let again = try MP3File.readTag(at: url)
        XCTAssertEqual(again.version, 3)
        XCTAssertEqual(again.fields.title, "Crème Brûlée")
        XCTAssertEqual(again.fields.artist, "Someone")
        let txxx = try XCTUnwrap(again.otherFrames.first { $0.id == "TXXX" })
        XCTAssertEqual(ID3Text.decodeStrings(txxx.body[...]), ["MOOD", "Happy ✓"])
        XCTAssertEqual(again.otherFrames.first { $0.id == "PRIV" }?.body, Array("owner".utf8) + [0, 1, 2, 3])

        let data = try Data(contentsOf: url)
        let (s, e) = MP3File.audioRange(of: data)
        XCTAssertEqual(data[s..<e], audio)
    }

    func testReadsID3v22AndV1Only() throws {
        // v2.2: TT2 + TP1 + PIC
        func f22(_ id: String, _ body: [UInt8]) -> [UInt8] {
            Array(id.utf8) + [UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
        }
        let jpeg = [UInt8](tinyJPEG(width: 300, height: 300))
        var frames: [UInt8] = f22("TT2", [0] + Array("Old".utf8)) + f22("TP1", [0] + Array("Band".utf8))
        frames += f22("PIC", [0] + Array("JPG".utf8) + [3, 0] + jpeg)
        let size = frames.count
        let tag: [UInt8] = [0x49, 0x44, 0x33, 2, 0, 0, 0, 0, UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)] + frames
        let url = dir.appendingPathComponent("v22.mp3")
        try (Data(tag) + audioBytes(1000)).write(to: url)
        let t = try MP3File.readTag(at: url)
        XCTAssertEqual(t.fields.title, "Old")
        XCTAssertEqual(t.fields.artist, "Band")
        XCTAssertEqual(t.fields.cover?.data, Data(jpeg))
        XCTAssertEqual(t.fields.cover?.mimeType, "image/jpeg")

        // v1 only
        var v1 = TagFields()
        v1.title = "Only V1"; v1.artist = "Artist"; v1.trackNumber = 7; v1.genre = "Pop"
        let url2 = dir.appendingPathComponent("v1.mp3")
        try (audioBytes(1000) + Data(ID3Writer.buildV1(v1))).write(to: url2)
        let t2 = try MP3File.readTag(at: url2)
        XCTAssertEqual(t2.version, 1)
        XCTAssertEqual(t2.fields.title, "Only V1")
        XCTAssertEqual(t2.fields.trackNumber, 7)
        XCTAssertEqual(t2.fields.genre, "Pop")
    }

    func testUnsynchronisedV23() throws {
        // TIT2 "A\u{FF}B" style body containing 0xFF 0x00 after unsync.
        let body: [UInt8] = [0, 0x41, 0xFF, 0x00, 0x42]      // unsync'd form of [0, 'A', 0xFF, 'B']? (0xFF followed by 0x00 inserted)
        let frameBytes: [UInt8] = Array("TIT2".utf8) + [0, 0, 0, 4, 0, 0] + body
        let size = frameBytes.count
        let tag: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0x80, 0, 0, UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)] + frameBytes
        let parsed = ID3Reader.parse(tag)
        XCTAssertEqual(parsed.fields.title, "A\u{FF}B")
    }

    func testCoverHeaderParsing() {
        let c = CoverArt(data: tinyJPEG(width: 640, height: 360, progressive: true))
        XCTAssertEqual(c.mimeType, "image/jpeg")
        XCTAssertEqual(c.pixelSize?.width, 640)
        XCTAssertEqual(c.pixelSize?.height, 360)
        XCTAssertTrue(c.isProgressiveJPEG)
        let issues = CarCheck.issues(for: TagFields(title: "a", artist: "b", album: "c", trackNumber: 1, cover: c))
        XCTAssertTrue(issues.contains { $0.message.contains("progressive") })
        XCTAssertTrue(issues.contains { $0.message.contains("square") })
        let ok = CarCheck.issues(for: TagFields(title: "a", artist: "b", album: "c", trackNumber: 1, cover: CoverArt(data: tinyJPEG())))
        XCTAssertEqual(ok, [])
    }

    func testNaming() {
        XCTAssertEqual(FileNaming.sanitize("Weekend Whip： The Fold / LEGO? <Ninjago>"), "Weekend Whip The Fold LEGO Ninjago")
        XCTAssertEqual(FileNaming.sanitize("Mon\u{0061}\u{0301}e."), "Monáe")
        XCTAssertEqual(FileNaming.stripNumberPrefix("07 Mario Kart World - Crown City"), "Mario Kart World - Crown City")
        XCTAssertEqual(FileNaming.stripNumberPrefix("1999 - Prince"), "1999 - Prince")
        XCTAssertEqual(FileNaming.stripNumberPrefix("2. Song"), "Song")
        let f = TagFields(title: "Party In The U.S.A.", artist: "Miley Cyrus")
        XCTAssertEqual(FileNaming.fileName(index: 3, total: 50, style: .artistTitle, fields: f, currentName: "x.mp3"),
                       "03 Miley Cyrus - Party In The U.S.A.mp3")
        XCTAssertEqual(FileNaming.fileName(index: 3, total: 120, style: .title, fields: f, currentName: "x.mp3"),
                       "003 Party In The U.S.A.mp3")
        XCTAssertEqual(FileNaming.fileName(index: 9, total: 10, style: .keepName, fields: f, currentName: "12 Old Name.mp3"),
                       "09 Old Name.mp3")
        XCTAssertEqual(ID3Genres.resolve("(17)"), "Rock")
        XCTAssertEqual(ID3Genres.resolve("(17)Garage"), "Garage")
        XCTAssertEqual(ID3Genres.resolve("13"), "Pop")
    }

    func testRenameSwapAndScan() throws {
        let a = dir.appendingPathComponent("01 A.mp3"), b = dir.appendingPathComponent("02 B.mp3")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        try Data().write(to: dir.appendingPathComponent("._01 A.mp3"))
        try Data().write(to: dir.appendingPathComponent("Pasted 2026-10-23 at 5.51.23 PM.tiff"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        // Swap names: must not collide.
        try FileNaming.perform([.init(from: a, to: b), .init(from: b, to: a)])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "b")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "a")

        let scan = try FolderScanner.scan(dir)
        XCTAssertEqual(scan.songs.map(\.lastPathComponent), ["01 A.mp3", "02 B.mp3"])
        XCTAssertEqual(scan.appleDouble.count, 0, "sidecar removed during rename")
        XCTAssertEqual(scan.system.map(\.lastPathComponent), [".DS_Store"])
        XCTAssertEqual(scan.other.map(\.lastPathComponent), ["Pasted 2026-10-23 at 5.51.23 PM.tiff"])
        XCTAssertTrue(FolderScanner.isLikelyJunk(scan.other[0]))

        XCTAssertThrowsError(try FileNaming.perform([.init(from: a, to: dir.appendingPathComponent("x.mp3")),
                                                    .init(from: b, to: dir.appendingPathComponent("X.mp3"))]))
    }

    func testYouTubeIDs() {
        XCTAssertEqual(YouTube.videoID(from: "https://www.youtube.com/watch?v=EkHTsc9PU2A&list=PL1&index=57"), "EkHTsc9PU2A")
        XCTAssertEqual(YouTube.videoID(from: "youtu.be/yZNtYmdZ-4c?t=3"), "yZNtYmdZ-4c")
        XCTAssertEqual(YouTube.videoID(from: "https://youtube.com/shorts/2qvAxPqy2wA"), "2qvAxPqy2wA")
        XCTAssertEqual(YouTube.videoID(from: "https://music.youtube.com/watch?v=-KoXt9pZLGM"), "-KoXt9pZLGM")
        XCTAssertEqual(YouTube.videoID(from: "TMw9UNXVDG0"), "TMw9UNXVDG0")
        XCTAssertNil(YouTube.videoID(from: "https://example.com/watch?v=TMw9UNXVDG0"))
        XCTAssertNil(YouTube.videoID(from: "hello"))
    }
}
