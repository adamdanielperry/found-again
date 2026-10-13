import Foundation

struct ExFATGeometry {
    var partitionOffset: UInt64
    var bytesPerSector: Int
    var sectorsPerCluster: Int
    var clusterHeapOffsetSectors: UInt64
    var clusterCount: UInt32
    var rootCluster: UInt32
    var fat: [UInt32]

    var clusterSize: UInt64 { UInt64(bytesPerSector * sectorsPerCluster) }

    func offsetOfCluster(_ cluster: UInt32) -> UInt64 {
        let heap = partitionOffset + clusterHeapOffsetSectors * UInt64(bytesPerSector)
        return heap + UInt64(cluster - 2) * clusterSize
    }

    func isEnd(_ value: UInt32) -> Bool { value >= 0xFFFFFFF8 }
    func isBad(_ value: UInt32) -> Bool { value == 0xFFFFFFF7 }
}

enum ExFATScanner {
    static func scan(
        reader: BlockReader,
        volume: FoundVolume,
        options: ScanOptions,
        sink: inout [RecoverableFile],
        used: inout [ByteRange]
    ) throws {
        let geometry = try load(reader: reader, volume: volume)
        var visited = Set<UInt32>()
        try walk(
            start: geometry.rootCluster,
            byteCount: nil,
            noFatChain: false,
            geometry: geometry,
            reader: reader,
            directory: "",
            depth: 0,
            options: options,
            visited: &visited,
            sink: &sink,
            used: &used
        )
    }

    /// Byte range of the cluster heap. Photos start on these boundaries.
    static func heapRegion(reader: BlockReader, volume: FoundVolume) -> CarveRegion? {
        guard let geometry = try? load(reader: reader, volume: volume) else { return nil }
        let origin = geometry.offsetOfCluster(2)
        let end = min(reader.size, origin + UInt64(geometry.clusterCount) * geometry.clusterSize)
        guard end > origin, geometry.clusterSize >= 512 else { return nil }
        return CarveRegion(start: origin, end: end, origin: origin, stride: geometry.clusterSize)
    }

    private static func load(reader: BlockReader, volume: FoundVolume) throws -> ExFATGeometry {
        let boot = try reader.read(at: volume.offset, count: 512)
        guard boot.count >= 512, boot.subdata(in: 3..<11) == Data("EXFAT   ".utf8) else {
            throw RecoverError.message("The ExFAT boot sector is unreadable.")
        }
        let bytesShift = Int(boot[108])
        let clusterShift = Int(boot[109])
        guard (9...12).contains(bytesShift), (0...16).contains(clusterShift) else {
            throw RecoverError.message("The ExFAT card uses an unexpected sector size.")
        }
        let bytesPerSector = 1 << bytesShift
        let sectorsPerCluster = 1 << clusterShift
        guard let fatOffset = Binary.u32le(boot, 80),
              let fatLength = Binary.u32le(boot, 84),
              let heapOffset = Binary.u32le(boot, 88),
              let clusterCount = Binary.u32le(boot, 92),
              let root = Binary.u32le(boot, 96)
        else {
            throw RecoverError.message("The ExFAT boot sector is incomplete.")
        }
        let fatBytes = Int(fatLength) * bytesPerSector
        guard fatBytes > 0, fatBytes <= 64 * 1024 * 1024 else {
            throw RecoverError.message("The ExFAT allocation table is an unexpected size.")
        }
        let table = try reader.read(at: volume.offset + UInt64(fatOffset) * UInt64(bytesPerSector), count: fatBytes)
        var entries = [UInt32](repeating: 0, count: Int(clusterCount) + 2)
        let available = min(entries.count, table.count / 4)
        for index in 0..<available {
            entries[index] = Binary.u32le(table, index * 4) ?? 0
        }
        return ExFATGeometry(
            partitionOffset: volume.offset,
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            clusterHeapOffsetSectors: UInt64(heapOffset),
            clusterCount: clusterCount,
            rootCluster: root,
            fat: entries
        )
    }

    private static func walk(
        start: UInt32,
        byteCount: UInt64?,
        noFatChain: Bool,
        geometry: ExFATGeometry,
        reader: BlockReader,
        directory: String,
        depth: Int,
        options: ScanOptions,
        visited: inout Set<UInt32>,
        sink: inout [RecoverableFile],
        used: inout [ByteRange]
    ) throws {
        if depth > 32 || sink.count >= 100_000 { return }
        if options.isCancelled?() == true { throw RecoverError.cancelled }
        guard start >= 2, start < geometry.clusterCount + 2 else { return }
        if !visited.insert(start).inserted { return }
        let clusters = geometry.directoryClusters(start: start, byteCount: byteCount, noFatChain: noFatChain)
        guard !clusters.isEmpty else { return }
        var data = Data()
        var map: [UInt32] = []
        for cluster in clusters {
            let chunk = try reader.read(at: geometry.offsetOfCluster(cluster), count: Int(geometry.clusterSize))
            data.append(chunk)
            map.append(cluster)
            if data.count > 32 * 1024 * 1024 { break }
        }
        if let byteCount, byteCount < UInt64(data.count) {
            data = Data(data.prefix(Int(byteCount)))
        }
        let clusterSize = Int(geometry.clusterSize)
        var index = 0
        while index + 32 <= data.count {
            if data[index] == 0 {
                let look = min(index + 256, data.count)
                if data[index..<look].allSatisfy({ $0 == 0 }) { return }
                index += 32
                continue
            }
            let primary = data.subdata(in: index..<(index + 32))
            let typeCode = primary[0] & 0x7F
            if typeCode != 0x05 {
                index += 32
                continue
            }
            let secondary = Int(primary[1])
            let setBytes = (1 + secondary) * 32
            guard secondary >= 2, secondary <= 18, index + setBytes <= data.count else {
                index += 32
                continue
            }
            let stream = data.subdata(in: (index + 32)..<(index + 64))
            guard stream[0] & 0x7F == 0x40 else {
                index += 32
                continue
            }
            let inUse = primary[0] & 0x80 != 0
            let attributes = Binary.u16le(primary, 4) ?? 0
            let isDirectory = attributes & 0x10 != 0
            let name = fileName(data: data, index: index, secondary: secondary, stream: stream)
            let firstCluster = Binary.u32le(stream, 20) ?? 0
            let validLength = Binary.u64le(stream, 8) ?? 0
            let dataLength = Binary.u64le(stream, 24) ?? 0
            let size = validLength > 0 ? validLength : dataLength
            let noChain = stream[1] & 0x02 != 0
            let entryOffset = diskOffset(index: index, map: map, clusterSize: clusterSize, geometry: geometry)

            if isDirectory, firstCluster >= 2, !FileTyping.skipName(name) {
                let next = directory.isEmpty ? name : directory + "/" + name
                try walk(
                    start: firstCluster,
                    byteCount: size > 0 ? size : nil,
                    noFatChain: noChain,
                    geometry: geometry,
                    reader: reader,
                    directory: next,
                    depth: depth + 1,
                    options: options,
                    visited: &visited,
                    sink: &sink,
                    used: &used
                )
            } else if inUse && !isDirectory {
                if let ranges = geometry.storedRanges(start: firstCluster, size: size, noFatChain: noChain) {
                    used.append(contentsOf: ranges)
                }
            } else if !inUse && !isDirectory {
                // macOS and cameras clear the top bit of the directory entry and leave the name and location in place.
                if let file = try record(
                    name: name,
                    entryOffset: entryOffset,
                    directory: directory,
                    firstCluster: firstCluster,
                    size: size,
                    noFatChain: noChain,
                    modified: modifiedDate(primary),
                    geometry: geometry,
                    reader: reader,
                    options: options
                ) {
                    sink.append(file)
                }
            }
            index += setBytes
        }
    }

    private static func record(
        name: String,
        entryOffset: UInt64,
        directory: String,
        firstCluster: UInt32,
        size: UInt64,
        noFatChain: Bool,
        modified: Date?,
        geometry: ExFATGeometry,
        reader: BlockReader,
        options: ScanOptions
    ) throws -> RecoverableFile? {
        if size == 0 || size > 128 * 1024 * 1024 * 1024 || firstCluster < 2 { return nil }
        guard let allocation = geometry.allocate(start: firstCluster, size: size, noFatChain: noFatChain) else { return nil }
        let byteCount = min(size, UInt64(allocation.clusters.count) * geometry.clusterSize)
        let ranges = ClusterMap.ranges(
            clusters: allocation.clusters,
            byteCount: byteCount,
            clusterSize: geometry.clusterSize,
            offsetOf: geometry.offsetOfCluster
        )
        guard !ranges.isEmpty else { return nil }
        return try FileBuilder.make(
            id: "exfat-\(geometry.partitionOffset)-\(entryOffset)",
            name: name,
            directory: directory,
            size: ranges.reduce(0) { $0 + $1.length },
            modified: modified,
            confidence: allocation.confidence,
            complete: allocation.complete,
            ranges: ranges,
            reader: reader,
            options: options
        )
    }

    private static func fileName(data: Data, index: Int, secondary: Int, stream: Data) -> String {
        let wanted = Int(stream[3])
        if wanted == 0 || wanted > 255 { return "" }
        var units: [UInt16] = []
        let nameEntries = secondary - 1
        for entryIndex in 0..<nameEntries {
            let start = index + 64 + entryIndex * 32
            guard start + 32 <= data.count else { break }
            let entry = data.subdata(in: start..<(start + 32))
            if entry[0] & 0x7F != 0x41 { break }
            for charIndex in 0..<15 {
                let offset = 2 + charIndex * 2
                units.append(UInt16(entry[offset]) | (UInt16(entry[offset + 1]) << 8))
            }
        }
        var chars: [UInt16] = []
        for unit in units.prefix(wanted) {
            if unit == 0 { break }
            chars.append(unit)
        }
        guard !chars.isEmpty else { return "" }
        return String(utf16CodeUnits: chars, count: chars.count)
    }

    private static func modifiedDate(_ primary: Data) -> Date? {
        let modified = Binary.u32le(primary, 12) ?? 0
        if let date = Binary.exfatDate(modified) { return date }
        return Binary.exfatDate(Binary.u32le(primary, 8) ?? 0)
    }

    private static func diskOffset(index: Int, map: [UInt32], clusterSize: Int, geometry: ExFATGeometry) -> UInt64 {
        guard clusterSize > 0 else { return 0 }
        let which = index / clusterSize
        let within = index % clusterSize
        guard which < map.count else { return 0 }
        return geometry.offsetOfCluster(map[which]) + UInt64(within)
    }
}

private extension ExFATGeometry {
    func directoryClusters(start: UInt32, byteCount: UInt64?, noFatChain: Bool) -> [UInt32] {
        if noFatChain {
            let count: Int
            if let byteCount, byteCount > 0 {
                count = Int((byteCount + clusterSize - 1) / clusterSize)
            } else {
                count = 1
            }
            return contiguous(start, max(count, 1)) ?? [start]
        }
        guard Int(start) < fat.count else { return [] }
        if fat[Int(start)] == 0 { return [start] }
        let chain = follow(start, 4096)
        return chain.isEmpty ? [start] : chain
    }

    func storedRanges(start: UInt32, size: UInt64, noFatChain: Bool) -> [ByteRange]? {
        guard let allocation = allocate(start: start, size: size, noFatChain: noFatChain) else { return nil }
        let byteCount = min(size, UInt64(allocation.clusters.count) * clusterSize)
        let ranges = ClusterMap.ranges(
            clusters: allocation.clusters,
            byteCount: byteCount,
            clusterSize: clusterSize,
            offsetOf: offsetOfCluster
        )
        return ranges.isEmpty ? nil : ranges
    }

    func allocate(start: UInt32, size: UInt64, noFatChain: Bool) -> (clusters: [UInt32], confidence: RecoveryConfidence, complete: Bool)? {
        let needed64 = (size + clusterSize - 1) / clusterSize
        guard needed64 > 0, needed64 <= UInt64(Int.max) else { return nil }
        let needed = Int(needed64)
        guard start >= 2, start < clusterCount + 2 else { return nil }
        if noFatChain {
            guard let run = contiguous(start, needed) else { return nil }
            return (run, .named, true)
        }
        guard Int(start) < fat.count else { return nil }
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
