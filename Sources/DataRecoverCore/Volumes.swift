import Foundation

enum VolumeKind {
    case fat12
    case fat16
    case fat32
    case exfat
    case ntfs
}

struct FoundVolume {
    var offset: UInt64
    var kind: VolumeKind
}

enum VolumeFinder {
    static func find(in reader: BlockReader) throws -> [FoundVolume] {
        if reader.size < 512 { return [] }
        let sector0 = try reader.read(at: 0, count: 512)
        if let volume = detect(boot: sector0, at: 0, diskSize: reader.size) {
            return [volume]
        }
        guard sector0.count >= 512, sector0[510] == 0x55, sector0[511] == 0xAA else {
            return []
        }
        let parts = mbrPartitions(sector0)
        if parts.contains(where: { $0.type == 0xEE }) || isGPT(reader) {
            return try gptVolumes(reader)
        }
        var volumes: [FoundVolume] = []
        var seen = Set<UInt64>()
        for part in parts where part.type != 0 && part.lba > 0 {
            if part.type == 0x05 || part.type == 0x0F {
                for lba in extendedLBAs(reader, extendedStart: part.lba) {
                    try appendProbe(reader, lba: lba, into: &volumes, seen: &seen)
                }
            } else {
                try appendProbe(reader, lba: part.lba, into: &volumes, seen: &seen)
            }
        }
        return volumes
    }

    private static func appendProbe(
        _ reader: BlockReader,
        lba: UInt64,
        into volumes: inout [FoundVolume],
        seen: inout Set<UInt64>
    ) throws {
        let offset = lba * 512
        if offset >= reader.size || !seen.insert(offset).inserted { return }
        let boot = try reader.read(at: offset, count: 512)
        if let volume = detect(boot: boot, at: offset, diskSize: reader.size) {
            volumes.append(volume)
        }
    }

    private static func detect(boot: Data, at offset: UInt64, diskSize: UInt64) -> FoundVolume? {
        guard boot.count >= 512, boot[510] == 0x55, boot[511] == 0xAA else { return nil }
        guard offset < diskSize else { return nil }
        if boot.subdata(in: 3..<11) == Data("NTFS    ".utf8) {
            // Windows-formatted drives. NTFS leaves the FAT fields zero, so it never passes the FAT checks below.
            guard let geometry = NTFSGeometry.parse(boot: boot, at: offset) else { return nil }
            let volumeBytes = geometry.volumeBytes
            if volumeBytes > diskSize || offset + volumeBytes > diskSize + 1024 * 1024 { return nil }
            guard geometry.offset(ofCluster: geometry.mftCluster) < diskSize else { return nil }
            return FoundVolume(offset: offset, kind: .ntfs)
        }
        if boot.subdata(in: 3..<11) == Data("EXFAT   ".utf8) {
            guard let sectors = Binary.u64le(boot, 72) else { return nil }
            let shift = Int(boot[108])
            guard (9...12).contains(shift) else { return nil }
            let bytesPerSector = UInt64(1 << shift)
            if sectors == 0 || sectors > (diskSize / bytesPerSector) + 4096 { return nil }
            let clusterShift = Int(boot[109])
            guard (0...16).contains(clusterShift) else { return nil }
            guard let root = Binary.u32le(boot, 96), root >= 2 else { return nil }
            guard let clusters = Binary.u32le(boot, 92), clusters > 0 else { return nil }
            return FoundVolume(offset: offset, kind: .exfat)
        }

        guard boot[0] == 0xEB || boot[0] == 0xE9 else { return nil }
        guard let bytesPerSector16 = Binary.u16le(boot, 11) else { return nil }
        let bytesPerSector = Int(bytesPerSector16)
        guard [512, 1024, 2048, 4096].contains(bytesPerSector) else { return nil }
        let sectorsPerCluster = Int(boot[13])
        guard sectorsPerCluster > 0, sectorsPerCluster <= 128, sectorsPerCluster & (sectorsPerCluster - 1) == 0 else {
            return nil
        }
        guard let reserved = Binary.u16le(boot, 14), reserved > 0 else { return nil }
        let fats = Int(boot[16])
        guard fats == 1 || fats == 2 else { return nil }
        let media = boot[21]
        guard media >= 0xF0 else { return nil }
        guard let rootEntries = Binary.u16le(boot, 17) else { return nil }
        guard let total16 = Binary.u16le(boot, 19), let total32 = Binary.u32le(boot, 32) else { return nil }
        let total = total16 != 0 ? UInt64(total16) : UInt64(total32)
        guard let fat16 = Binary.u16le(boot, 22), let fat32 = Binary.u32le(boot, 36) else { return nil }
        let fatSectors = fat16 != 0 ? UInt64(fat16) : UInt64(fat32)
        guard total > 0, fatSectors > 0 else { return nil }
        let rootSectors = (UInt64(rootEntries) * 32 + UInt64(bytesPerSector) - 1) / UInt64(bytesPerSector)
        let reservedAndTables = UInt64(reserved) + UInt64(fats) * fatSectors + rootSectors
        guard total > reservedAndTables else { return nil }
        let dataSectors = total - reservedAndTables
        let clusterCount = dataSectors / UInt64(sectorsPerCluster)
        guard clusterCount >= 1 else { return nil }
        let volumeBytes = total * UInt64(bytesPerSector)
        if volumeBytes > diskSize || offset + volumeBytes > diskSize + 1024 * 1024 { return nil }

        let kind: VolumeKind
        if clusterCount < 4085 {
            kind = .fat12
        } else if clusterCount < 65525 {
            kind = .fat16
        } else {
            kind = .fat32
        }
        return FoundVolume(offset: offset, kind: kind)
    }

    private struct MBRPart {
        var type: UInt8
        var lba: UInt64
    }

    private static func mbrPartitions(_ sector: Data) -> [MBRPart] {
        var parts: [MBRPart] = []
        for index in 0..<4 {
            let base = 446 + index * 16
            guard base + 16 <= sector.count else { continue }
            let type = sector[base + 4]
            let lba = UInt64(Binary.u32le(sector, base + 8) ?? 0)
            parts.append(MBRPart(type: type, lba: lba))
        }
        return parts
    }

    private static func extendedLBAs(_ reader: BlockReader, extendedStart: UInt64) -> [UInt64] {
        var found: [UInt64] = []
        var ebr = extendedStart
        var guardCount = 0
        while guardCount < 16 {
            guardCount += 1
            let offset = ebr * 512
            guard offset + 512 <= reader.size, let sector = try? reader.read(at: offset, count: 512) else { break }
            guard sector.count >= 512, sector[510] == 0x55, sector[511] == 0xAA else { break }
            let firstType = sector[446 + 4]
            let firstLBA = UInt64(Binary.u32le(sector, 446 + 8) ?? 0)
            if firstType != 0 && firstLBA > 0 {
                found.append(ebr + firstLBA)
            }
            let secondType = sector[462 + 4]
            let secondLBA = UInt64(Binary.u32le(sector, 462 + 8) ?? 0)
            if (secondType == 0x05 || secondType == 0x0F), secondLBA > 0 {
                ebr = extendedStart + secondLBA
            } else {
                break
            }
        }
        return found
    }

    private static func isGPT(_ reader: BlockReader) -> Bool {
        guard let header = try? reader.read(at: 512, count: 512), header.count >= 8 else { return false }
        return header.starts(with: Data("EFI PART".utf8))
    }

    private static func gptVolumes(_ reader: BlockReader) throws -> [FoundVolume] {
        guard let header = try? reader.read(at: 512, count: 512), header.starts(with: Data("EFI PART".utf8)) else {
            return []
        }
        guard let entryLBA = Binary.u64le(header, 72),
              let entryCount = Binary.u32le(header, 80),
              let entrySize = Binary.u32le(header, 84),
              entrySize >= 128,
              entryCount > 0
        else { return [] }
        let count = min(Int(entryCount), 128)
        let tableBytes = count * Int(entrySize)
        let table = try reader.read(at: entryLBA * 512, count: tableBytes)
        var volumes: [FoundVolume] = []
        var seen = Set<UInt64>()
        for index in 0..<count {
            let base = index * Int(entrySize)
            guard base + 48 <= table.count else { break }
            let typeEmpty = table.subdata(in: base..<base + 16).allSatisfy { $0 == 0 }
            if typeEmpty { continue }
            let first = Binary.u64le(table, base + 32) ?? 0
            if first == 0 { continue }
            try appendProbe(reader, lba: first, into: &volumes, seen: &seen)
        }
        return volumes
    }
}
