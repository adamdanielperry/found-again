import Foundation

/// AVI, WAV and WebP share RIFF: "RIFF", a 32-bit length, a form type, then chunks.
/// The length is in the header, and walking the chunks checks it holds up.
struct RIFFCarver: FormatCarver {
    /// Long AVI recordings continue in further "AVIX" RIFF blocks, each under 4 GB.
    static let maxAVI: UInt64 = 64 * 1024 * 1024 * 1024
    static let maxWebP: UInt64 = 256 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x52] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 20, head.starts(with: "RIFF"), head.u32le(4) >= 12, Self.isChunkID(head, at: 12) else { return nil }
        if head.starts(with: "AVI ", at: 8) { return .avi }
        if head.starts(with: "WAVE", at: 8) { return .wav }
        if head.starts(with: "WEBP", at: 8) { return .webp }
        return nil
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let cap: UInt64 = kind == .avi ? Self.maxAVI : (kind == .webp ? Self.maxWebP : 0x1_0000_0008)
        let bytes = ByteWindow(reader: reader, end: min(reader.size, start + cap), windowSize: 64 * 1024)
        guard var walked = Self.walk(bytes, at: start) else { return nil }
        switch kind {
        case .avi:
            guard walked.chunks.first == "LIST", walked.lists.contains("hdrl"), walked.lists.contains("movi") else { return nil }
            // OpenDML: recordings over 1 GB carry on in "RIFF....AVIX" blocks straight after.
            while let extra = bytes.bytes(at: walked.end + 8, count: 4), extra == Data("AVIX".utf8),
                  bytes.bytes(at: walked.end, count: 4) == Data("RIFF".utf8),
                  let more = Self.walk(bytes, at: walked.end) {
                walked.end = more.end
            }
        case .wav:
            guard walked.chunks.contains("fmt "), walked.chunks.contains("data") else { return nil }
        case .webp:
            guard let first = walked.chunks.first, ["VP8 ", "VP8L", "VP8X"].contains(first) else { return nil }
        default:
            return nil
        }
        return Carved(kind: kind, size: walked.end - start, modified: walked.date, device: walked.device)
    }

    struct Walked {
        var end: UInt64
        var chunks: [String] = []
        /// List types of top-level LIST chunks, such as "hdrl" and "movi".
        var lists: [String] = []
        var date: Date?
        var device: String?
    }

    /// Steps through the top-level chunks of one RIFF block. They must land exactly on its declared end,
    /// which rejects a header whose length field is stale or belongs to something else.
    private static func walk(_ bytes: ByteWindow, at start: UInt64) -> Walked? {
        guard let riffSize = bytes.u32le(at: start + 4), riffSize >= 12 else { return nil }
        let end = start + 8 + UInt64(riffSize)
        guard end <= bytes.end else { return nil }
        var walked = Walked(end: min(end + UInt64(riffSize & 1), bytes.end))
        var position = start + 12
        var oddBefore = false
        while position + 8 <= end {
            guard walked.chunks.count < 100_000, let header = bytes.bytes(at: position, count: 12), header.count >= 8 else { return nil }
            if !header.withUnsafeBytes({ isChunkID($0, at: 0) }) {
                // Some writers leave out the pad byte after an odd-sized chunk.
                guard oddBefore, let unpadded = bytes.bytes(at: position - 1, count: 4),
                      unpadded.withUnsafeBytes({ isChunkID($0, at: 0) })
                else { return nil }
                position -= 1
                oddBefore = false
                continue
            }
            guard let size = Binary.u32le(header, 4) else { return nil }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            walked.chunks.append(id)
            if id == "LIST", header.count >= 12 {
                walked.lists.append(String(decoding: header.subdata(in: 8..<12), as: UTF8.self))
            }
            let dataStart = position + 8
            let next = dataStart + UInt64(size) + UInt64(size & 1)
            // The last chunk may run to the end without its pad byte.
            guard next <= end || dataStart + UInt64(size) == end else { return nil }
            readMetadata(id: id, bytes: bytes, at: dataStart, size: size, into: &walked)
            oddBefore = size & 1 == 1
            position = min(next, end)
        }
        return position == end ? walked : nil
    }

    private static func readMetadata(id: String, bytes: ByteWindow, at offset: UInt64, size: UInt32, into walked: inout Walked) {
        switch id {
        case "bext" where size >= 338:
            // Broadcast WAV: OriginationDate "yyyy-mm-dd" and OriginationTime "hh:mm:ss".
            guard let stamp = bytes.bytes(at: offset + 320, count: 18) else { return }
            let text = String(decoding: stamp, as: UTF8.self).replacingOccurrences(of: "/", with: "-")
            let date = String(text.prefix(10))
            let time = String(text.dropFirst(10).prefix(8)).replacingOccurrences(of: "-", with: ":")
            walked.date = walked.date ?? EXIF.parseDate("\(date) \(time)")
        case "EXIF" where size <= 256 * 1024:
            guard var tiff = bytes.bytes(at: offset, count: Int(size)) else { return }
            if tiff.starts(with: Data("Exif\u{0}\u{0}".utf8)) { tiff = tiff.subdata(in: 6..<tiff.count) }
            if let summary = EXIF.summary(inTIFF: tiff) {
                walked.date = walked.date ?? summary.date
                walked.device = walked.device ?? summary.device
            }
        default:
            break
        }
    }

    /// Chunk IDs are four printable ASCII characters, such as "fmt ", "LIST" or "VP8L".
    static func isChunkID(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        guard offset + 4 <= bytes.count, bytes[offset] != 0x20 else { return false }
        for index in offset..<(offset + 4) where !(0x20...0x7E).contains(bytes[index]) {
            return false
        }
        return true
    }
}
