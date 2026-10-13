import Foundation

public enum PhotoRecovery {
    public static func scan(reader: BlockReader, options: ScanOptions) throws -> ScanResult {
        if options.isCancelled?() == true { throw RecoverError.cancelled }
        options.progress?(options.deepScan ? 0.02 : nil, "Reading the card's file list")
        let volumes = try VolumeFinder.find(in: reader)
        var files: [RecoverableFile] = []
        var used: [ByteRange] = []
        var warnings: [String] = []
        var names: [String] = []
        if volumes.isEmpty {
            warnings.append("No FAT or ExFAT filesystem was found on this card.")
        }
        if volumes.contains(where: { $0.kind == .fat12 }) {
            warnings.append("A very old FAT12 section was skipped.")
        }
        for volume in volumes {
            if options.isCancelled?() == true { throw RecoverError.cancelled }
            switch volume.kind {
            case .fat12:
                continue
            case .fat16:
                names.append("FAT16")
                try FATScanner.scan(reader: reader, volume: volume, options: options, sink: &files)
            case .fat32:
                names.append("FAT32")
                try FATScanner.scan(reader: reader, volume: volume, options: options, sink: &files)
            case .exfat:
                names.append("ExFAT")
                try ExFATScanner.scan(reader: reader, volume: volume, options: options, sink: &files, used: &used)
            }
        }
        let searchContents = options.deepScan || files.isEmpty
        if searchContents {
            if files.isEmpty {
                options.progress?(0.04, "The file names were removed. Searching the card for the photos…")
            }
            var regions: [CarveRegion] = []
            for volume in volumes {
                switch volume.kind {
                case .exfat:
                    if let region = ExFATScanner.heapRegion(reader: reader, volume: volume) { regions.append(region) }
                case .fat16, .fat32:
                    if let region = FATScanner.heapRegion(reader: reader, volume: volume) { regions.append(region) }
                case .fat12:
                    break
                }
            }
            let cover = RangeCover(files, extra: used)
            try Carver.carve(reader: reader, regions: regions, covered: cover, options: options, sink: &files)
            if options.isCancelled?() == true {
                warnings.append("The search was canceled. Photos already found are listed.")
            }
        }
        assignPreviews(&files)
        options.onUpdate?(files)
        let filesystem = names.isEmpty ? "Unknown" : names.joined(separator: " and ")
        options.progress?(1, "Found \(files.count) deleted \(files.count == 1 ? "photo" : "photos")")
        return ScanResult(
            files: files,
            filesystem: filesystem,
            volumeCount: volumes.filter { $0.kind != .fat12 }.count,
            warnings: warnings,
            searchedContents: searchContents
        )
    }

    public static func read(
        _ file: RecoverableFile,
        from reader: BlockReader,
        fileOffset: UInt64 = 0,
        maxBytes: Int
    ) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        var output = Data()
        var skipped: UInt64 = 0
        for range in file.ranges {
            if output.count >= maxBytes { break }
            if skipped + range.length <= fileOffset {
                skipped += range.length
                continue
            }
            let into = fileOffset > skipped ? fileOffset - skipped : 0
            let available = range.length - into
            let want = min(UInt64(maxBytes - output.count), available)
            let chunk = try reader.read(at: range.offset + into, count: Int(want))
            output.append(chunk)
            skipped += range.length
        }
        return output
    }

    private static func assignPreviews(_ files: inout [RecoverableFile]) {
        for index in files.indices {
            if files[index].previewFile != nil { continue }
            switch files[index].kind {
            case .jpeg, .raf, .heic, .png, .tiff:
                files[index].previewFile = String(format: "%05d.jpg", index + 1)
            case .movie, .other:
                break
            }
        }
    }
}

enum FileBuilder {
    static func make(
        id: String,
        name: String,
        directory: String,
        size: UInt64,
        modified: Date?,
        confidence: RecoveryConfidence,
        complete: Bool,
        ranges: [ByteRange],
        reader: BlockReader,
        options: ScanOptions
    ) throws -> RecoverableFile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileTyping.skipName(trimmed) { return nil }
        guard size > 0, !ranges.isEmpty else { return nil }
        guard ranges.allSatisfy({ $0.offset < reader.size && $0.length > 0 && $0.offset + $0.length <= reader.size }) else {
            return nil
        }
        let header = try PhotoRecovery.read(
            RecoverableFile(
                id: id,
                name: trimmed,
                originalPath: trimmed,
                size: size,
                modified: nil,
                kind: .other,
                confidence: confidence,
                headerLooksValid: nil,
                complete: complete,
                previewFile: nil,
                ranges: ranges
            ),
            from: reader,
            maxBytes: 32
        )
        let kind = FileTyping.kind(name: trimmed, header: header)
        guard FileTyping.include(kind, photosOnly: options.photosOnly) else { return nil }
        let path = directory.isEmpty ? trimmed : directory + "/" + trimmed
        let valid = header.isEmpty ? nil : FileTyping.headerMatches(kind, header: header)
        return RecoverableFile(
            id: id,
            name: trimmed,
            originalPath: path,
            size: size,
            modified: modified,
            kind: kind,
            confidence: confidence,
            headerLooksValid: valid,
            complete: complete,
            previewFile: nil,
            ranges: ranges
        )
    }
}

public enum ManifestStore {
    public static func write(_ result: ScanResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ScanResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ScanResult.self, from: data)
    }
}
