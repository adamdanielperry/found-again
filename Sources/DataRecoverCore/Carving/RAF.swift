import Foundation

/// Fujifilm RAW. The header holds a table of where the preview, metadata, and sensor data sit.
struct RAFCarver: FormatCarver {
    static let maxSize: UInt64 = 512 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x46] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        head.starts(with: "FUJIFILMCCD-RAW ") ? .raf : nil
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        guard let layout = Self.layout(reader, at: start) else { return nil }
        guard start + layout.size <= reader.size else { return nil }
        var carved = Carved(kind: .raf, size: layout.size)
        // The embedded preview is an ordinary JPEG with the camera's EXIF, so it gives the date and model.
        if let preview = try? reader.read(at: start + layout.jpegOffset, count: Int(min(layout.jpegLength, 256 * 1024))) {
            let window = DataBlockReader(preview)
            if let summary = Self.exif(in: window) {
                carved.modified = summary.date
                carved.device = summary.device
            }
            carved.nameHint = CameraNames.find(in: preview).map { ($0 as NSString).deletingPathExtension + ".RAF" }
        }
        return carved
    }

    struct Layout {
        var size: UInt64
        var jpegOffset: UInt64
        var jpegLength: UInt64
    }

    static func layout(_ reader: BlockReader, at start: UInt64) -> Layout? {
        guard let header = try? reader.read(at: start, count: 128), header.count >= 0x6C else { return nil }
        guard header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)) else { return nil }
        guard let jpegOffset = Binary.u32be(header, 0x54),
              let jpegLength = Binary.u32be(header, 0x58),
              let metaOffset = Binary.u32be(header, 0x5C),
              let metaLength = Binary.u32be(header, 0x60),
              let cfaOffset = Binary.u32be(header, 0x64),
              let cfaLength = Binary.u32be(header, 0x68)
        else { return nil }
        let ends = [
            UInt64(jpegOffset) + UInt64(jpegLength),
            UInt64(metaOffset) + UInt64(metaLength),
            UInt64(cfaOffset) + UInt64(cfaLength),
        ]
        guard let size = ends.max(), size > 0x80, size <= maxSize else { return nil }
        guard jpegOffset >= 0x70, UInt64(jpegOffset) + 3 < size else { return nil }
        guard let magic = try? reader.read(at: start + UInt64(jpegOffset), count: 3),
              magic.count >= 3, magic[0] == 0xFF, magic[1] == 0xD8
        else { return nil }
        return Layout(size: size, jpegOffset: UInt64(jpegOffset), jpegLength: UInt64(jpegLength))
    }

    private static func exif(in preview: DataBlockReader) -> EXIF.Summary? {
        guard let parsed = JPEGCarver.measure(preview, at: 0) else {
            // The preview is cut short here; read its APP1 directly.
            guard let data = try? preview.read(at: 0, count: Int(preview.size)), data.count > 12,
                  data[2] == 0xFF, data[3] == 0xE1,
                  let length = Binary.u16be(data, 4), Int(length) + 4 <= data.count
            else { return nil }
            return EXIF.summary(inAPP1: data.subdata(in: 6..<(4 + Int(length))))
        }
        return parsed.exif
    }
}
