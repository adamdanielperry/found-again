import Foundation

/// Photoshop documents: a fixed header, three length-prefixed sections, then the merged image,
/// whose size follows from the dimensions or, when run-length compressed, from its table of row lengths.
struct PSDCarver: FormatCarver {
    static let maxSize: UInt64 = 2 * 1024 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x38] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 26, head.starts(with: "8BPS") else { return nil }
        let version = head.u16be(4)
        guard version == 1 || version == 2, (6..<12).allSatisfy({ head[$0] == 0 }) else { return nil }
        let channels = head.u16be(12)
        let height = head.u32be(14)
        let width = head.u32be(18)
        let depth = head.u16be(22)
        let mode = head.u16be(24)
        let largest: UInt32 = version == 1 ? 30_000 : 300_000
        guard (1...56).contains(channels), (1...largest).contains(height), (1...largest).contains(width),
              [1, 8, 16, 32].contains(depth), [0, 1, 2, 3, 4, 7, 8, 9].contains(mode)
        else { return nil }
        return .psd
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end, windowSize: 256 * 1024)
        guard let header = bytes.bytes(at: start, count: 26), header.count == 26,
              let version = Binary.u16be(header, 4), let channels = Binary.u16be(header, 12),
              let height = Binary.u32be(header, 14), let width = Binary.u32be(header, 18), let depth = Binary.u16be(header, 22)
        else { return nil }
        let large = version == 2

        var position = start + 26
        guard let colourLength = bytes.u32be(at: position), colourLength <= 16 * 1024 * 1024 else { return nil }
        position += 4 + UInt64(colourLength)

        guard let resourcesLength = bytes.u32be(at: position) else { return nil }
        let resourcesStart = position + 4
        position = resourcesStart + UInt64(resourcesLength)
        var summary: EXIF.Summary?
        if resourcesLength > 0 {
            guard bytes.bytes(at: resourcesStart, count: 4) == Data("8BIM".utf8) else { return nil }
            summary = Self.exif(bytes, from: resourcesStart, to: position)
        }

        // Layer and mask information; its length field is twice as wide in large documents.
        if large {
            guard let value = bytes.u64be(at: position), value <= Self.maxSize else { return nil }
            position += 8 + value
        } else {
            guard let value = bytes.u32be(at: position) else { return nil }
            position += 4 + UInt64(value)
        }

        guard position + 2 <= end, let compression = bytes.u16be(at: position) else { return nil }
        position += 2
        let rows = UInt64(height) * UInt64(channels)
        let rowBytes = depth == 1 ? (UInt64(width) + 7) / 8 : UInt64(width) * UInt64(depth) / 8
        switch compression {
        case 0:
            position += rowBytes * rows
        case 1:
            // A table of compressed row lengths, then the rows.
            let entry: UInt64 = large ? 4 : 2
            guard let total = Self.sumRowLengths(bytes, at: position, rows: rows, entry: entry, rowBytes: rowBytes) else { return nil }
            position += rows * entry + total
        default:
            // Zip-compressed image data has no length to go by.
            return nil
        }
        guard position <= end else { return nil }
        return Carved(kind: .psd, size: position - start, modified: summary?.date, device: summary?.device)
    }

    private static func sumRowLengths(_ bytes: ByteWindow, at offset: UInt64, rows: UInt64, entry: UInt64, rowBytes: UInt64) -> UInt64? {
        // PackBits never grows a row by more than one byte in 128, plus one.
        let worst = rowBytes + rowBytes / 128 + 2
        var total: UInt64 = 0
        var done: UInt64 = 0
        while done < rows {
            let batch = min(rows - done, 16 * 1024)
            let ok = bytes.withBytes(at: offset + done * entry, count: Int(batch * entry)) { raw -> Bool in
                for index in 0..<Int(batch) {
                    let length = entry == 2 ? UInt64(raw.u16be(index * 2)) : UInt64(raw.u32be(index * 4))
                    guard length <= worst else { return false }
                    total += length
                }
                return true
            }
            guard ok == true else { return nil }
            done += batch
        }
        return total
    }

    /// Image resources are "8BIM" blocks; resource 1058 holds the photo's EXIF as a TIFF block.
    private static func exif(_ bytes: ByteWindow, from start: UInt64, to end: UInt64) -> EXIF.Summary? {
        var position = start
        var count = 0
        while position + 12 <= end, count < 1000 {
            guard bytes.bytes(at: position, count: 4) == Data("8BIM".utf8),
                  let id = bytes.u16be(at: position + 4), let nameLength = bytes.byte(at: position + 6)
            else { return nil }
            // A Pascal string padded to an even length, counting its length byte.
            let nameSpan = (UInt64(nameLength) + 2) & ~1
            let sizeAt = position + 6 + nameSpan
            guard let size = bytes.u32be(at: sizeAt) else { return nil }
            let dataStart = sizeAt + 4
            if id == 1058, size <= 256 * 1024, let tiff = bytes.bytes(at: dataStart, count: Int(size)) {
                return EXIF.summary(inTIFF: tiff)
            }
            position = dataStart + ((UInt64(size) + 1) & ~1)
            count += 1
        }
        return nil
    }
}
