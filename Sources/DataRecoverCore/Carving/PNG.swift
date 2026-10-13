import Foundation

/// PNG is a chain of length-prefixed chunks ending with IEND, so its length is exact.
struct PNGCarver: FormatCarver {
    static let maxSize: UInt64 = 200 * 1024 * 1024
    private static let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    var leadBytes: [UInt8]? { [0x89] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        // The first chunk is always a 13-byte IHDR.
        guard head.count >= 16, head.starts(with: Self.magic), head.u32be(8) == 13, head.starts(with: "IHDR", at: 12) else { return nil }
        return .png
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end)
        guard let ihdr = bytes.bytes(at: start + 8, count: 25), ihdr.count == 25, Self.validHeader(ihdr) else { return nil }
        var position = start + 8
        var sawData = false
        var modified: Date?
        var summary: EXIF.Summary?
        var chunks = 0
        while chunks < 1_000_000 {
            guard let length = bytes.u32be(at: position), length < 0x8000_0000,
                  let type = bytes.u32be(at: position + 4), Self.isChunkType(type)
            else { return nil }
            let next = position + 12 + UInt64(length)
            guard next <= end else { return nil }
            chunks += 1
            switch type {
            case 0x4944_4154: // IDAT
                sawData = true
            case 0x7449_4D45 where length == 7: // tIME, in UTC
                if let time = bytes.bytes(at: position + 8, count: 7), time.count == 7 {
                    modified = Self.date(time)
                }
            case 0x6558_4966 where length <= 256 * 1024: // eXIf
                if let tiff = bytes.bytes(at: position + 8, count: Int(length)) {
                    summary = EXIF.summary(inTIFF: tiff)
                }
            case 0x4945_4E44: // IEND
                guard length == 0, sawData else { return nil }
                return Carved(kind: .png, size: next - start, modified: summary?.date ?? modified, device: summary?.device)
            default:
                break
            }
            position = next
        }
        return nil
    }

    private static func validHeader(_ ihdr: Data) -> Bool {
        // Length, "IHDR", 13 bytes of fields, CRC.
        guard Binary.u32be(ihdr, 0) == 13, ihdr.subdata(in: 4..<8) == Data("IHDR".utf8),
              let width = Binary.u32be(ihdr, 8), let height = Binary.u32be(ihdr, 12),
              width > 0, height > 0, width < 0x8000_0000, height < 0x8000_0000,
              let stored = Binary.u32be(ihdr, 21)
        else { return false }
        let depth = ihdr[16]
        let colour = ihdr[17]
        let allowed: [UInt8: [UInt8]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard allowed[colour]?.contains(depth) == true, ihdr[18] == 0, ihdr[19] == 0, ihdr[20] <= 1 else { return false }
        return CRC32.checksum(ihdr.subdata(in: 4..<21)) == stored
    }

    /// Chunk types are four ASCII letters.
    private static func isChunkType(_ type: UInt32) -> Bool {
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((type >> UInt32(shift)) & 0xFF)
            guard (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) else { return false }
        }
        return true
    }

    private static func date(_ time: Data) -> Date? {
        guard let year = Binary.u16be(time, 0) else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(identifier: "UTC")
        parts.year = Int(year)
        parts.month = Int(time[2])
        parts.day = Int(time[3])
        parts.hour = Int(time[4])
        parts.minute = Int(time[5])
        parts.second = Int(time[6])
        guard (1995...2100).contains(Int(year)), (1...12).contains(Int(time[2])), (1...31).contains(Int(time[3])),
              time[4] < 24, time[5] < 60, time[6] < 61
        else { return nil }
        return parts.date
    }
}

/// The CRC used by PNG and ZIP.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
