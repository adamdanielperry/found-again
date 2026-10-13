import Foundation

struct FATGeometry {
    enum Kind { case fat16, fat32 }

    var kind: Kind
    var partitionOffset: UInt64
    var bytesPerSector: Int
    var sectorsPerCluster: Int
    var reservedSectors: UInt64
    var fatCount: Int
    var fatSectors: UInt64
    var rootEntryCount: Int
    var rootCluster: UInt32
    var clusterCount: UInt32
    var fat: [UInt32]

    var clusterSize: UInt64 { UInt64(bytesPerSector * sectorsPerCluster) }

    var fatByteOffset: UInt64 {
        partitionOffset + reservedSectors * UInt64(bytesPerSector)
    }

    var rootByteOffset: UInt64 {
        fatByteOffset + UInt64(fatCount) * fatSectors * UInt64(bytesPerSector)
    }

    var rootSectors: UInt64 {
        (UInt64(rootEntryCount) * 32 + UInt64(bytesPerSector) - 1) / UInt64(bytesPerSector)
    }

    var dataByteOffset: UInt64 {
        rootByteOffset + rootSectors * UInt64(bytesPerSector)
    }

    func offsetOfCluster(_ cluster: UInt32) -> UInt64 {
        dataByteOffset + UInt64(cluster - 2) * clusterSize
    }

    func isEnd(_ value: UInt32) -> Bool {
        switch kind {
        case .fat16: return value >= 0xFFF8
        case .fat32: return value >= 0x0FFFFFF8
        }
    }

    func isBad(_ value: UInt32) -> Bool {
        switch kind {
        case .fat16: return value == 0xFFF7
        case .fat32: return value == 0x0FFFFFF7
        }
    }
}

enum FATScanner {
    /// Lists deleted files. Files still in use are added to `used` so the deep scan doesn't report them as found.
    static func scan(
        reader: BlockReader,
        volume: FoundVolume,
        options: ScanOptions,
        sink: inout [RecoverableFile],
        used: inout [ByteRange]
    ) throws {
        guard volume.kind == .fat16 || volume.kind == .fat32 else { return }
        let geometry = try load(reader: reader, volume: volume)
        var walker = Walker(geometry: geometry, reader: reader, options: options)
        if geometry.kind == .fat32 {
            let clusters = geometry.clusters(startingAt: geometry.rootCluster, freeMeansOneCluster: true)
            try walker.walk(clusters: clusters, directory: "")
        } else {
            let bytes = Int(geometry.rootSectors * UInt64(geometry.bytesPerSector))
            let data = try reader.read(at: geometry.rootByteOffset, count: bytes)
            try walker.walk(image: DirectoryImage(data: data, diskOffset: { geometry.rootByteOffset + UInt64($0) }), directory: "")
        }
        sink.append(contentsOf: walker.found)
        used.append(contentsOf: walker.used)
        // The tables and directories themselves aren't free space either.
        used.append(ByteRange(offset: volume.offset, length: geometry.dataByteOffset - volume.offset))
    }

    private static func load(reader: BlockReader, volume: FoundVolume) throws -> FATGeometry {
        let boot = try reader.read(at: volume.offset, count: 512)
        guard boot.count >= 512 else { throw RecoverError.message("The FAT boot sector is unreadable.") }
        let bytesPerSector = Int(Binary.u16le(boot, 11) ?? 0)
        let sectorsPerCluster = Int(boot[13])
        let reserved = UInt64(Binary.u16le(boot, 14) ?? 0)
        let fatCount = Int(boot[16])
        let rootEntries = Int(Binary.u16le(boot, 17) ?? 0)
        let total16 = UInt64(Binary.u16le(boot, 19) ?? 0)
        let total32 = UInt64(Binary.u32le(boot, 32) ?? 0)
        let total = total16 != 0 ? total16 : total32
        let fat16 = UInt64(Binary.u16le(boot, 22) ?? 0)
        let fat32 = UInt64(Binary.u32le(boot, 36) ?? 0)
        let fatSectors = fat16 != 0 ? fat16 : fat32
        let rootSectors = (UInt64(rootEntries) * 32 + UInt64(bytesPerSector) - 1) / UInt64(bytesPerSector)
        let dataSectors = total - (reserved + UInt64(fatCount) * fatSectors + rootSectors)
        let clusterCount64 = dataSectors / UInt64(sectorsPerCluster)
        guard clusterCount64 < UInt64(UInt32.max) else {
            throw RecoverError.message("The FAT on this card looks damaged.")
        }
        let clusterCount = UInt32(clusterCount64)
        let kind: FATGeometry.Kind = volume.kind == .fat32 ? .fat32 : .fat16
        let rootCluster = kind == .fat32 ? (Binary.u32le(boot, 44) ?? 2) : 0

        let entryWidth = kind == .fat16 ? 2 : 4
        let tableBytes = Int(fatSectors) * bytesPerSector
        guard tableBytes > 0, tableBytes <= 64 * 1024 * 1024 else {
            throw RecoverError.message("The FAT on this card is an unexpected size.")
        }
        let fatOffset = volume.offset + reserved * UInt64(bytesPerSector)
        let table = try reader.read(at: fatOffset, count: tableBytes)
        var entries = [UInt32](repeating: 0, count: Int(clusterCount) + 2)
        let available = min(entries.count, table.count / entryWidth)
        if kind == .fat16 {
            for index in 0..<available {
                entries[index] = UInt32(Binary.u16le(table, index * 2) ?? 0)
            }
        } else {
            for index in 0..<available {
                entries[index] = (Binary.u32le(table, index * 4) ?? 0) & 0x0FFFFFFF
            }
        }

        return FATGeometry(
            kind: kind,
            partitionOffset: volume.offset,
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            reservedSectors: reserved,
            fatCount: fatCount,
            fatSectors: fatSectors,
            rootEntryCount: rootEntries,
            rootCluster: rootCluster,
            clusterCount: clusterCount,
            fat: entries
        )
    }

    fileprivate struct Walker {
        let geometry: FATGeometry
        let reader: BlockReader
        let options: ScanOptions
        var visited = Set<UInt32>()
        var found: [RecoverableFile] = []
        var used: [ByteRange] = []

        init(geometry: FATGeometry, reader: BlockReader, options: ScanOptions) {
            self.geometry = geometry
            self.reader = reader
            self.options = options
        }

    mutating func walk(clusters: [UInt32], directory: String) throws {
        guard let first = clusters.first else { return }
        if !visited.insert(first).inserted { return }
        var data = Data()
        var map: [UInt32] = []
        for cluster in clusters {
            if cluster < 2 || cluster >= geometry.clusterCount + 2 { break }
            let chunk = try reader.read(at: geometry.offsetOfCluster(cluster), count: Int(geometry.clusterSize))
            data.append(chunk)
            map.append(cluster)
            if data.count > 32 * 1024 * 1024 { break }
        }
        let geometry = self.geometry
        let image = DirectoryImage(data: data) { index in
            let clusterSize = Int(geometry.clusterSize)
            guard clusterSize > 0 else { return 0 }
            let which = index / clusterSize
            let within = index % clusterSize
            guard which < map.count else { return 0 }
            return geometry.offsetOfCluster(map[which]) + UInt64(within)
        }
        try walk(image: image, directory: directory)
    }

    mutating func walk(image: DirectoryImage, directory: String) throws {
        if options.cancelled { throw RecoverError.cancelled }
        var index = 0
        var pendingLFN: [Data] = []
        while index + 32 <= image.data.count {
            if found.count >= 100_000 { return }
            let entry = image.data.subdata(in: index..<(index + 32))
            let first = entry[0]
            if first == 0x00 { return }
            let attr = entry[11]
            if attr == 0x0F {
                pendingLFN.append(entry)
                index += 32
                continue
            }
            let longNames = pendingLFN
            pendingLFN.removeAll()
            if attr & 0x08 != 0 {
                index += 32
                continue
            }
            if first == 0x2E {
                index += 32
                continue
            }
            let deleted = first == 0xE5
            let isDirectory = attr & 0x10 != 0
            let entryOffset = image.diskOffset(index)
            if isDirectory {
                let cluster = geometry.clusterNumber(entry)
                let name = FATScanner.displayName(entry: entry, longNames: longNames)
                if cluster >= 2 && !FileTyping.skipDirectory(name) {
                    let clusters = geometry.clusters(startingAt: cluster, freeMeansOneCluster: true)
                    try walk(clusters: clusters, directory: FATScanner.join(directory, name))
                }
            } else if deleted {
                if let file = try record(entry: entry, longNames: longNames, entryOffset: entryOffset, directory: directory) {
                    found.append(file)
                }
            } else {
                let cluster = geometry.clusterNumber(entry)
                let size = UInt64(Binary.u32le(entry, 28) ?? 0)
                if cluster >= 2 && size > 0 {
                    let needed = Int(min((size + geometry.clusterSize - 1) / geometry.clusterSize, 1 << 24))
                    let chain = geometry.follow(cluster, needed)
                    used.append(contentsOf: ClusterMap.ranges(clusters: chain, byteCount: size, clusterSize: geometry.clusterSize, offsetOf: geometry.offsetOfCluster))
                }
            }
            index += 32
        }
    }

    private func record(entry: Data, longNames: [Data], entryOffset: UInt64, directory: String) throws -> RecoverableFile? {
        let cluster = geometry.clusterNumber(entry)
        let size = UInt64(Binary.u32le(entry, 28) ?? 0)
        if size == 0 || size > 128 * 1024 * 1024 * 1024 || cluster < 2 { return nil }
        guard let allocation = geometry.allocate(start: cluster, size: size) else { return nil }
        let ranges = ClusterMap.ranges(
            clusters: allocation.clusters,
            byteCount: min(size, UInt64(allocation.clusters.count) * geometry.clusterSize),
            clusterSize: geometry.clusterSize,
            offsetOf: geometry.offsetOfCluster
        )
        guard !ranges.isEmpty else { return nil }
        var name = FATScanner.displayName(entry: entry, longNames: longNames)
        if longNames.isEmpty || FATScanner.bestLongName(longNames, short: entry) == nil {
            name = FileTyping.repairFujifilmShortName(name)
        }
        let when = Binary.fatDate(time: Binary.u16le(entry, 22) ?? 0, date: Binary.u16le(entry, 24) ?? 0)
        let covered = ranges.reduce(UInt64(0)) { $0 + $1.length }
        return try FileBuilder.make(
            id: "fat-\(geometry.partitionOffset)-\(entryOffset)",
            name: name,
            directory: directory,
            size: covered,
            modified: when,
            confidence: allocation.confidence,
            complete: allocation.complete && covered >= size,
            ranges: ranges,
            reader: reader,
            options: options
        )
    }
    }

    fileprivate static func displayName(entry: Data, longNames: [Data]) -> String {
        if let long = bestLongName(longNames, short: entry) { return long }
        return shortName(entry)
    }

    fileprivate static func bestLongName(_ entries: [Data], short: Data) -> String? {
        guard !entries.isEmpty else { return nil }
        for take in stride(from: entries.count, through: 1, by: -1) {
            let slice = Array(entries.suffix(take))
            if let name = longName(slice, short: short) { return name }
        }
        return nil
    }

    /// `entries` are in on-disk order. The entry closest to the short name is the start of the file name.
    private static func longName(_ entries: [Data], short: Data) -> String? {
        guard let checksum = entries.last?[13] else { return nil }
        guard entries.allSatisfy({ $0.count >= 32 && $0[11] == 0x0F && $0[13] == checksum }) else { return nil }
        var shortBytes = [UInt8](short.prefix(11))
        guard shortBytes.count == 11 else { return nil }
        var matched = false
        for candidate in 0...255 {
            shortBytes[0] = UInt8(candidate)
            if lfnChecksum(shortBytes) == checksum {
                matched = true
                break
            }
        }
        guard matched else { return nil }
        var units: [UInt16] = []
        for entry in entries.reversed() {
            units.append(contentsOf: lfnUnits(entry))
        }
        var chars: [UInt16] = []
        for unit in units {
            if unit == 0x0000 { break }
            if unit == 0xFFFF { continue }
            chars.append(unit)
        }
        guard !chars.isEmpty else { return nil }
        return String(utf16CodeUnits: chars, count: chars.count)
    }

    private static func lfnUnits(_ entry: Data) -> [UInt16] {
        let offsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        return offsets.map { UInt16(entry[$0]) | (UInt16(entry[$0 + 1]) << 8) }
    }

    private static func lfnChecksum(_ name: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in name.prefix(11) {
            let carry: UInt8 = (sum & 1) == 1 ? 0x80 : 0
            sum = carry &+ (sum >> 1) &+ byte
        }
        return sum
    }

    private static func shortName(_ entry: Data) -> String {
        var bytes = [UInt8](entry.prefix(11))
        if bytes.count < 11 { return "FILE" }
        if bytes[0] == 0xE5 { bytes[0] = 0x5F }
        if bytes[0] == 0x05 { bytes[0] = 0xE5 }
        let stem = ascii(bytes[0..<8])
        let ext = ascii(bytes[8..<11])
        if ext.isEmpty { return stem.isEmpty ? "FILE" : stem }
        return stem + "." + ext
    }

    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String {
        let kept = bytes.filter { $0 != 0x20 && $0 != 0x00 }
        return String(bytes: kept, encoding: .ascii) ?? "FILE"
    }

    fileprivate static func join(_ directory: String, _ name: String) -> String {
        if name.isEmpty || name == "." || name == ".." { return directory }
        if directory.isEmpty { return name }
        return directory + "/" + name
    }
}

private struct DirectoryImage {
    var data: Data
    var diskOffset: (Int) -> UInt64
}

private extension FATGeometry {
    func clusterNumber(_ entry: Data) -> UInt32 {
        let low = UInt32(Binary.u16le(entry, 26) ?? 0)
        if kind == .fat16 { return low }
        let high = UInt32(Binary.u16le(entry, 20) ?? 0)
        return (high << 16) | low
    }

    /// A camera often clears the FAT entries when a photo is deleted and leaves the file in one continuous run.
    func allocate(start: UInt32, size: UInt64) -> (clusters: [UInt32], confidence: RecoveryConfidence, complete: Bool)? {
        let needed64 = (size + clusterSize - 1) / clusterSize
        guard needed64 > 0, needed64 <= UInt64(Int.max) else { return nil }
        let needed = Int(needed64)
        guard start >= 2, start < clusterCount + 2, Int(start) < fat.count else { return nil }
        if fat[Int(start)] == 0 {
            guard let run = contiguous(start, needed) else { return nil }
            return (run, .estimated, true)
        }
        let chain = follow(start, needed)
        if chain.count >= needed {
            return (Array(chain.prefix(needed)), .named, true)
        }
        let prefixIsContiguous = chain.enumerated().allSatisfy { $0.element == start + UInt32($0.offset) }
        if prefixIsContiguous, let run = contiguous(start, needed) {
            return (run, .estimated, true)
        }
        if !chain.isEmpty {
            return (chain, .estimated, false)
        }
        return nil
    }

    func clusters(startingAt start: UInt32, freeMeansOneCluster: Bool) -> [UInt32] {
        guard start >= 2, start < clusterCount + 2, Int(start) < fat.count else { return [] }
        if fat[Int(start)] == 0 && freeMeansOneCluster { return [start] }
        let chain = follow(start, 4096)
        return chain.isEmpty ? [start] : chain
    }

    func follow(_ start: UInt32, _ maxCount: Int) -> [UInt32] {
        var out: [UInt32] = []
        var seen = Set<UInt32>()
        var current = start
        while out.count < maxCount {
            if current < 2 || current >= clusterCount + 2 || Int(current) >= fat.count { break }
            if !seen.insert(current).inserted { break }
            let next = fat[Int(current)]
            out.append(current)
            if isEnd(next) || next == 0 || isBad(next) { break }
            current = next
        }
        return out
    }

    func contiguous(_ start: UInt32, _ count: Int) -> [UInt32]? {
        let end = UInt64(start) + UInt64(count)
        if end > UInt64(clusterCount) + 2 { return nil }
        return (0..<count).map { start + UInt32($0) }
    }
}
