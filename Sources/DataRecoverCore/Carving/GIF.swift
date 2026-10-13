import Foundation

/// GIF: a header, optional colour table, then extension and image blocks made of length-prefixed
/// sub-blocks, ending with a 0x3B trailer.
struct GIFCarver: FormatCarver {
    static let maxSize: UInt64 = 100 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x47] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 13, head.starts(with: "GIF87a") || head.starts(with: "GIF89a") else { return nil }
        guard head.u16le(6) > 0, head.u16le(8) > 0 else { return nil }
        return .gif
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end)
        guard let packed = bytes.byte(at: start + 10) else { return nil }
        var position = start + 13
        if packed & 0x80 != 0 {
            position += 3 << (UInt64(packed & 0x07) + 1)
        }
        var images = 0
        while position < end {
            guard let introducer = bytes.byte(at: position) else { return nil }
            switch introducer {
            case 0x21:
                guard let label = bytes.byte(at: position + 1), let first = bytes.byte(at: position + 2) else { return nil }
                // Graphic control, plain text, application and comment extensions have fixed first blocks.
                switch label {
                case 0xF9: guard first == 4 else { return nil }
                case 0x01: guard first == 12 else { return nil }
                case 0xFF: guard first == 11 else { return nil }
                case 0xFE: break
                default: return nil
                }
                guard let after = Self.skipSubBlocks(bytes, from: position + 2) else { return nil }
                position = after
            case 0x2C:
                guard let descriptor = bytes.bytes(at: position + 1, count: 9), descriptor.count == 9 else { return nil }
                var cursor = position + 10
                if descriptor[8] & 0x80 != 0 {
                    cursor += 3 << (UInt64(descriptor[8] & 0x07) + 1)
                }
                guard let codeSize = bytes.byte(at: cursor), (1...11).contains(codeSize) else { return nil }
                guard let after = Self.skipSubBlocks(bytes, from: cursor + 1) else { return nil }
                images += 1
                position = after
            case 0x3B:
                guard images > 0 else { return nil }
                return Carved(kind: .gif, size: position + 1 - start)
            default:
                return nil
            }
        }
        return nil
    }

    /// Steps over a chain of sub-blocks, each a length byte and that many bytes, ending with a zero length.
    private static func skipSubBlocks(_ bytes: ByteWindow, from offset: UInt64) -> UInt64? {
        var position = offset
        while let length = bytes.byte(at: position) {
            if length == 0 { return position + 1 }
            position += 1 + UInt64(length)
        }
        return nil
    }
}
