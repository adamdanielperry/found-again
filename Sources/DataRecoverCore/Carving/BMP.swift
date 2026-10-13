import Foundation

/// Windows bitmaps record their file size in the header. "BM" turns up by chance all the time,
/// so the size is only believed when every other header field agrees with it.
struct BMPCarver: FormatCarver {
    static let maxSize: UInt64 = 512 * 1024 * 1024
    private static let headerSizes: Set<UInt32> = [12, 40, 52, 56, 108, 124]

    var leadBytes: [UInt8]? { [0x42] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 30, head[0] == 0x42, head[1] == 0x4D, head.u32le(6) == 0 else { return nil }
        let fileSize = head.u32le(2)
        let pixelOffset = head.u32le(10)
        let dibSize = head.u32le(14)
        guard Self.headerSizes.contains(dibSize), pixelOffset >= 14 + dibSize, pixelOffset < fileSize,
              UInt64(fileSize) <= Self.maxSize
        else { return nil }
        if dibSize == 12 {
            guard head.u16le(18) > 0, head.u16le(20) > 0, head.u16le(22) == 1, [1, 4, 8, 24].contains(head.u16le(24)) else { return nil }
        } else {
            guard head.u32le(18) > 0, head.u32le(22) != 0, head.u16le(26) == 1, [1, 4, 8, 16, 24, 32].contains(head.u16le(28)) else { return nil }
        }
        return .bmp
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        guard start + 54 <= reader.size, let header = try? reader.read(at: start, count: 14 + 124), header.count >= 26,
              let fileSize = Binary.u32le(header, 2), let pixelOffset = Binary.u32le(header, 10),
              let dibSize = Binary.u32le(header, 14), header.count >= 14 + Int(dibSize)
        else { return nil }
        let width: UInt64
        let height: UInt64
        let bits: UInt64
        var compression: UInt32 = 0
        var imageSize: UInt64 = 0
        var colours: UInt64 = 0
        var trailing: UInt64 = 0
        if dibSize == 12 {
            guard let w = Binary.u16le(header, 18), let h = Binary.u16le(header, 20), let b = Binary.u16le(header, 24) else { return nil }
            width = UInt64(w)
            height = UInt64(h)
            bits = UInt64(b)
        } else {
            guard let w = Binary.u32le(header, 18), let h = Binary.u32le(header, 22), let b = Binary.u16le(header, 28),
                  let c = Binary.u32le(header, 30), let s = Binary.u32le(header, 34), let used = Binary.u32le(header, 46)
            else { return nil }
            // Height is negative for top-down bitmaps.
            let signedHeight = Int32(bitPattern: h)
            guard Int32(bitPattern: w) > 0, signedHeight != 0, signedHeight != Int32.min else { return nil }
            width = UInt64(w)
            height = UInt64(abs(signedHeight))
            bits = UInt64(b)
            compression = c
            imageSize = UInt64(s)
            colours = UInt64(used)
            // Version 5 headers can carry an ICC profile, which is stored after the pixels.
            if dibSize == 124, Binary.u32le(header, 14 + 56) == 0x4D42_4544,
               let profileOffset = Binary.u32le(header, 14 + 112), let profileSize = Binary.u32le(header, 14 + 116) {
                trailing = 14 + UInt64(profileOffset) + UInt64(profileSize)
            }
        }
        guard width <= 65_536, height <= 65_536 else { return nil }
        if bits <= 8 {
            guard colours <= 1 << bits else { return nil }
        }

        let pixelBytes: UInt64
        switch compression {
        case 0:
            pixelBytes = (width * bits + 31) / 32 * 4 * height
        case 3, 6:
            guard bits == 16 || bits == 32 else { return nil }
            pixelBytes = (width * bits + 31) / 32 * 4 * height
        case 1, 2:
            // Run-length data: only the header's image size says how long it is.
            guard (compression == 1 && bits == 8) || (compression == 2 && bits == 4), imageSize > 0 else { return nil }
            pixelBytes = imageSize
        default:
            return nil
        }
        let pixelEnd = UInt64(pixelOffset) + pixelBytes
        let needed = max(pixelEnd, trailing)
        // A few writers pad the end; anything much longer means the size field isn't this bitmap's.
        guard UInt64(fileSize) >= needed, UInt64(fileSize) <= needed + 1024 else { return nil }
        guard UInt64(fileSize) <= Self.maxSize, start + UInt64(fileSize) <= reader.size else { return nil }
        return Carved(kind: .bmp, size: UInt64(fileSize))
    }
}
