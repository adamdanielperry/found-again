import Foundation

/// Bytes ImageIO can turn into a thumbnail quickly, read without saving the file.
/// Raw photos carry a full-size JPEG preview, which is far quicker to decode than the sensor data.
public enum Previews {
    /// Nil when the kind has no image to show or the image is larger than `maxBytes`.
    public static func imageData(for file: RecoverableFile, reader: BlockReader, maxBytes: Int = 40 << 20) -> Data? {
        guard file.size > 0, maxBytes > 0 else { return nil }
        switch file.kind {
        case .jpeg:
            return read(file, reader, at: 0, count: min(file.size, 2 << 20))
        case .raf:
            let contents = FileContents(file: file, source: reader)
            guard let layout = RAFCarver.layout(contents, at: 0), layout.jpegLength <= UInt64(maxBytes) else { return nil }
            return jpeg(file, reader, at: layout.jpegOffset, length: layout.jpegLength)
        case .tiff, .cr2, .nef, .arw, .dng, .orf, .rw2, .pef, .srw:
            if let preview = embeddedJPEG(file, reader, maxBytes: maxBytes) { return preview }
            // No usable preview: ImageIO can still decode a plain TIFF or most raws whole.
            return whole(file, reader, maxBytes: maxBytes)
        case .cr3, .png, .gif, .heic, .avif, .webp, .bmp, .psd:
            return whole(file, reader, maxBytes: maxBytes)
        default:
            return nil
        }
    }

    private static func whole(_ file: RecoverableFile, _ reader: BlockReader, maxBytes: Int) -> Data? {
        guard file.size <= UInt64(maxBytes) else { return nil }
        return read(file, reader, at: 0, count: file.size)
    }

    /// The largest embedded JPEG that ImageIO can draw, reading only the directories and that JPEG.
    private static func embeddedJPEG(_ file: RecoverableFile, _ reader: BlockReader, maxBytes: Int) -> Data? {
        let contents = FileContents(file: file, source: reader)
        guard let layout = TIFFRawCarver.layout(contents, at: 0, measure: false) else { return nil }
        let candidates = layout.previews
            .filter { $0.length >= 64 && $0.length <= UInt64(maxBytes) && $0.end <= file.size }
            .sorted { $0.length > $1.length }
        for candidate in candidates {
            // Raw sensor data can also be stored as lossless JPEG, which isn't a picture ImageIO can show.
            guard let head = read(file, reader, at: candidate.offset, count: min(candidate.length, 128 * 1024)),
                  JPEGFrames.isDisplayable(head)
            else { continue }
            if let data = jpeg(file, reader, at: candidate.offset, length: candidate.length) { return data }
        }
        return nil
    }

    private static func jpeg(_ file: RecoverableFile, _ reader: BlockReader, at offset: UInt64, length: UInt64) -> Data? {
        guard let data = read(file, reader, at: offset, count: length), data.count >= 4,
              data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8
        else { return nil }
        return data
    }

    private static func read(_ file: RecoverableFile, _ reader: BlockReader, at offset: UInt64, count: UInt64) -> Data? {
        guard count > 0, count <= UInt64(Int.max),
              let data = try? RecoveryEngine.read(file, from: reader, fileOffset: offset, maxBytes: Int(count)),
              !data.isEmpty
        else { return nil }
        return data
    }
}

/// A recovered file seen as its own disk, so parsers written for carving can read it through its byte ranges.
final class FileContents: BlockReader {
    let file: RecoverableFile
    let source: BlockReader
    let size: UInt64

    init(file: RecoverableFile, source: BlockReader) {
        self.file = file
        self.source = source
        self.size = min(file.size, file.ranges.reduce(UInt64(0)) { $0 + $1.length })
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        return try RecoveryEngine.read(file, from: source, fileOffset: offset, maxBytes: Int(min(UInt64(count), size - offset)))
    }
}

/// Checks the start of a JPEG for a baseline or progressive frame, the kinds ImageIO decodes.
enum JPEGFrames {
    static func isDisplayable(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var position = 2
        while position + 4 <= bytes.count {
            guard bytes[position] == 0xFF else { return false }
            let marker = bytes[position + 1]
            if marker == 0xFF {
                position += 1
                continue
            }
            switch marker {
            case 0xC0, 0xC1, 0xC2:
                return true
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF, 0xDA, 0xD9:
                return false
            default:
                let length = Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
                guard length >= 2 else { return false }
                position += 2 + length
            }
        }
        return false
    }
}
