import Foundation

/// Older Office files (.doc, .xls, .ppt) are compound documents: a small file system of fixed-size sectors
/// with its own allocation table. The highest sector the table marks as used is the end of the file.
struct OLE2Carver: FormatCarver {
    static let maxSize: UInt64 = 512 * 1024 * 1024
    private static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let free: UInt32 = 0xFFFF_FFFF
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let lastRegular: UInt32 = 0xFFFF_FFFA

    var leadBytes: [UInt8]? { [0xD0] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 32, head.starts(with: Self.magic), head.u16le(28) == 0xFFFE else { return nil }
        let major = head.u16le(26)
        let shift = head.u16le(30)
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else { return nil }
        // Which Office program made it only shows in the directory, which carve reads.
        return .doc
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        guard let header = try? reader.read(at: start, count: 512), header.count == 512,
              let major = Binary.u16le(header, 26), let shift = Binary.u16le(header, 30),
              (major == 3 && shift == 9) || (major == 4 && shift == 12),
              Binary.u16le(header, 32) == 6, Binary.u32le(header, 56) == 4096,
              let fatCount = Binary.u32le(header, 44), let firstDirectory = Binary.u32le(header, 48),
              let firstDIFAT = Binary.u32le(header, 68), let difatCount = Binary.u32le(header, 72)
        else { return nil }
        let sectorSize = 1 << Int(shift)
        let perSector = sectorSize / 4
        let limit = min(Self.maxSize, reader.size - start)
        let maxSectors = UInt32(min(limit >> UInt64(shift), UInt64(Self.lastRegular)))
        guard fatCount > 0, UInt64(fatCount) * UInt64(perSector) <= UInt64(maxSectors) + UInt64(perSector),
              difatCount <= fatCount
        else { return nil }

        func sector(_ index: UInt32) -> Data? {
            guard index < maxSectors else { return nil }
            let offset = start + (UInt64(index) + 1) << UInt64(shift)
            guard let data = try? reader.read(at: offset, count: sectorSize), data.count == sectorSize else { return nil }
            return data
        }

        // Where the allocation table lives: 109 slots in the header, the rest in a chain of DIFAT sectors.
        var fatSectors: [UInt32] = []
        for slot in 0..<min(Int(fatCount), 109) {
            guard let value = Binary.u32le(header, 76 + slot * 4) else { return nil }
            fatSectors.append(value)
        }
        var difat = firstDIFAT
        var difatRead = 0
        var tableSectors: [UInt32] = []
        while fatSectors.count < Int(fatCount) {
            guard difatRead < Int(difatCount), let block = sector(difat) else { return nil }
            tableSectors.append(difat)
            for slot in 0..<(perSector - 1) where fatSectors.count < Int(fatCount) {
                guard let value = Binary.u32le(block, slot * 4) else { return nil }
                fatSectors.append(value)
            }
            guard let next = Binary.u32le(block, (perSector - 1) * 4) else { return nil }
            difat = next
            difatRead += 1
        }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * perSector)
        for index in fatSectors {
            guard let block = sector(index) else { return nil }
            block.withUnsafeBytes { raw in
                for slot in 0..<perSector { fat.append(raw.u32le(slot * 4)) }
            }
        }
        // Writers should mark the table's own sectors FATSECT, but Cocoa marks them end-of-chain and some exporters
        // chain them like a stream, so they count towards the end however they're marked.
        var highest = (fatSectors + tableSectors).max() ?? 0
        // Every entry must be free, a special marker, or a link to a sector the table covers.
        for (index, entry) in fat.enumerated() where entry != Self.free {
            guard entry <= Self.lastRegular ? entry < UInt32(fat.count) : entry >= 0xFFFF_FFFC else { return nil }
            highest = max(highest, UInt32(index))
        }
        guard highest < maxSectors else { return nil }
        let size = (UInt64(highest) + 2) << UInt64(shift)
        guard size <= limit else { return nil }

        // The directory names the streams; the main stream's name says which program wrote the file.
        var names = Set<String>()
        var modified: Date?
        var current = firstDirectory
        var visited = 0
        while current <= Self.lastRegular, visited < 4096 {
            guard let block = sector(current) else { return nil }
            for slot in 0..<(sectorSize / 128) {
                let entry = block.subdata(in: (slot * 128)..<(slot * 128 + 128))
                guard let nameLength = Binary.u16le(entry, 64), nameLength >= 2, nameLength <= 64 else { continue }
                let units = (0..<(Int(nameLength) / 2 - 1)).compactMap { Binary.u16le(entry, $0 * 2) }
                let name = String(decoding: units, as: UTF16.self)
                names.insert(name)
                if visited == 0, slot == 0, entry[66] == 5, let stamp = Binary.u64le(entry, 108) {
                    modified = Self.date(fileTime: stamp)
                }
            }
            guard Int(current) < fat.count else { return nil }
            current = fat[Int(current)]
            visited += 1
        }
        guard current == Self.endOfChain else { return nil }

        let found: FileKind
        if names.contains("WordDocument") {
            found = .doc
        } else if names.contains("Workbook") || names.contains("Book") {
            found = .xls
        } else if names.contains("PowerPoint Document") {
            found = .ppt
        } else {
            // Other compound files (Outlook messages, installers, thumbnail caches) aren't reported.
            return nil
        }
        return Carved(kind: found, size: size, modified: modified)
    }

    /// Windows FILETIME: 100-nanosecond steps since 1601.
    private static func date(fileTime: UInt64) -> Date? {
        guard fileTime > 0 else { return nil }
        let seconds = Double(fileTime) / 10_000_000 - 11_644_473_600
        let date = Date(timeIntervalSince1970: seconds)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return (1995...2100).contains(year) ? date : nil
    }
}
