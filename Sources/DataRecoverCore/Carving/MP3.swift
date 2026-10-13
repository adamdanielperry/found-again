import Foundation

/// MP3 with an ID3v2 tag. The tag gives its own size; after it, MPEG audio frames are walked one by one,
/// since each frame header gives that frame's length. MP3s without a tag have no dependable signature.
struct MP3Carver: FormatCarver {
    static let maxSize: UInt64 = 100 * 1024 * 1024
    /// Fewer frames than this is more likely chance than music.
    static let minimumFrames = 10

    var leadBytes: [UInt8]? { [0x49] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 10, head.starts(with: "ID3"), (2...4).contains(head[3]), head[4] != 0xFF else { return nil }
        // Undefined flag bits are always clear, and the size is "syncsafe": seven bits per byte.
        guard head[5] & 0x0F == 0, head[6] < 0x80, head[7] < 0x80, head[8] < 0x80, head[9] < 0x80 else { return nil }
        return .mp3
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end)
        guard let tag = bytes.bytes(at: start, count: 10), tag.count == 10 else { return nil }
        let footer: UInt64 = tag[3] == 4 && tag[5] & 0x10 != 0 ? 10 : 0
        let tagSize = 10 + Self.syncsafe(tag, 6) + footer
        var position = start + tagSize
        // Some taggers write more padding than they declare.
        var skipped = 0
        while skipped < 4096, bytes.byte(at: position) == 0 {
            position += 1
            skipped += 1
        }
        guard let firstWord = bytes.u32be(at: position), let first = Frame(firstWord) else { return nil }
        var frames = 0
        while let word = bytes.u32be(at: position), let frame = Frame(word), frame.sameStream(as: first) {
            guard position + UInt64(frame.length) <= end else { break }
            position += UInt64(frame.length)
            frames += 1
        }
        guard frames >= Self.minimumFrames else { return nil }
        // An ID3v1 tag: "TAG" and 125 bytes of fixed fields at the very end.
        if position + 128 <= end, bytes.bytes(at: position, count: 3) == Data("TAG".utf8) {
            position += 128
        }
        let name = ID3.name(bytes, tagStart: start, tagSize: tagSize).map { $0 + ".mp3" }
        return Carved(kind: .mp3, size: position - start, nameHint: name)
    }

    static func syncsafe(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<4).reduce(UInt64(0)) { ($0 << 7) | UInt64(data[offset + $1] & 0x7F) }
    }

    /// One MPEG audio frame header.
    struct Frame {
        var version: UInt32
        var layer: UInt32
        var sampleRate: Int
        var length: Int

        private static let bitrates: [[Int]] = [
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // MPEG-1 layer I
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // MPEG-1 layer II
            [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // MPEG-1 layer III
            [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // MPEG-2/2.5 layer I
            [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // MPEG-2/2.5 layers II and III
        ]

        init?(_ word: UInt32) {
            guard word & 0xFFE0_0000 == 0xFFE0_0000 else { return nil }
            let version = (word >> 19) & 3 // 0: MPEG-2.5, 2: MPEG-2, 3: MPEG-1
            let layer = (word >> 17) & 3 // 1: III, 2: II, 3: I
            let bitrateIndex = Int((word >> 12) & 0xF)
            let rateIndex = Int((word >> 10) & 3)
            let padding = Int((word >> 9) & 1)
            guard version != 1, layer != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3, word & 3 != 2 else { return nil }
            let mpeg1 = version == 3
            let table: Int
            switch (mpeg1, layer) {
            case (true, 3): table = 0
            case (true, 2): table = 1
            case (true, _): table = 2
            case (false, 3): table = 3
            default: table = 4
            }
            let bitrate = Self.bitrates[table][bitrateIndex] * 1000
            let base = [44100, 48000, 32000][rateIndex]
            let sampleRate = version == 3 ? base : (version == 2 ? base / 2 : base / 4)
            switch layer {
            case 3: length = (12 * bitrate / sampleRate + padding) * 4
            case 2: length = 144 * bitrate / sampleRate + padding
            default: length = (mpeg1 ? 144 : 72) * bitrate / sampleRate + padding
            }
            guard length >= 21 else { return nil }
            self.version = version
            self.layer = layer
            self.sampleRate = sampleRate
        }

        /// Bit rate may change from frame to frame; version, layer and sample rate don't.
        func sameStream(as other: Frame) -> Bool {
            version == other.version && layer == other.layer && sampleRate == other.sampleRate
        }
    }
}

/// Reads the title and artist from an ID3v2 tag, so a recovered song keeps a useful name.
enum ID3 {
    static func name(_ bytes: ByteWindow, tagStart: UInt64, tagSize: UInt64) -> String? {
        guard let header = bytes.bytes(at: tagStart, count: 10), header.count == 10 else { return nil }
        let major = header[3]
        let flags = header[5]
        // Unsynchronised tags need undoing byte by byte; they're rare enough to skip.
        guard flags & 0x80 == 0 else { return nil }
        let end = tagStart + min(tagSize, 16 * 1024 * 1024)
        var position = tagStart + 10
        if flags & 0x40 != 0, major >= 3, let extended = bytes.bytes(at: position, count: 4), extended.count == 4 {
            position += major == 4 ? MP3Carver.syncsafe(extended, 0) : UInt64(Binary.u32be(extended, 0) ?? 0) + 4
        }
        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        var title: String?
        var artist: String?
        var count = 0
        while position + UInt64(headerLength) <= end, count < 512 {
            guard let frame = bytes.bytes(at: position, count: headerLength), frame.count == headerLength,
                  frame[0] != 0
            else { break }
            let id = String(decoding: frame.prefix(idLength), as: UTF8.self)
            let size: UInt64
            switch major {
            case 2: size = (UInt64(frame[3]) << 16) | (UInt64(frame[4]) << 8) | UInt64(frame[5])
            case 4: size = MP3Carver.syncsafe(frame, 4)
            default: size = UInt64(Binary.u32be(frame, 4) ?? 0)
            }
            guard size > 0, position + UInt64(headerLength) + size <= end else { break }
            if ["TIT2", "TT2"].contains(id) || ["TPE1", "TP1"].contains(id), size <= 1024,
               let value = bytes.bytes(at: position + UInt64(headerLength), count: Int(size)) {
                let text = decode(value)
                if id.hasPrefix("TT") || id == "TIT2" { title = title ?? text } else { artist = artist ?? text }
            }
            position += UInt64(headerLength) + size
            count += 1
        }
        guard let title else { return nil }
        let joined = artist.map { "\($0) - \(title)" } ?? title
        let cleaned = OutputPath.sanitize(joined)
        guard cleaned != "file" else { return nil }
        return String(cleaned.prefix(120))
    }

    /// A text frame: one encoding byte, then ISO-8859-1, UTF-16 with a byte order mark, UTF-16BE or UTF-8.
    private static func decode(_ value: Data) -> String? {
        guard let encoding = value.first else { return nil }
        let body = value.dropFirst()
        let text: String?
        switch encoding {
        case 0: text = String(bytes: body, encoding: .isoLatin1)
        case 1: text = String(bytes: body, encoding: .utf16)
        case 2: text = String(bytes: body, encoding: .utf16BigEndian)
        case 3: text = String(bytes: body, encoding: .utf8)
        default: text = nil
        }
        let trimmed = text?.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
