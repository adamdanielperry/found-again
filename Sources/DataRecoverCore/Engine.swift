import Foundation

/// Finds deleted files on a disk or disk image. Never writes to the source.
public enum RecoveryEngine {
    /// First reads the file system's own records, which is quick and keeps names and folders.
    /// Then, unless switched off, reads every sector looking for files by their contents.
    public static func scan(reader: BlockReader, options: ScanOptions) throws -> ScanResult {
        if options.cancelled { throw RecoverError.cancelled }
        options.progress?(ScanProgress(phase: .fileRecords, bytesTotal: reader.size))
        let volumes = try VolumeFinder.find(in: reader)
        var files: [RecoverableFile] = []
        var used: [ByteRange] = []
        var warnings: [String] = []
        var names: [String] = []
        if volumes.contains(where: { $0.kind == .fat12 }) {
            warnings.append("A very old FAT12 section was skipped.")
        }
        for volume in volumes {
            if options.cancelled { throw RecoverError.cancelled }
            do {
                switch volume.kind {
                case .fat12:
                    continue
                case .fat16:
                    names.append("FAT16")
                    try FATScanner.scan(reader: reader, volume: volume, options: options, sink: &files, used: &used)
                case .fat32:
                    names.append("FAT32")
                    try FATScanner.scan(reader: reader, volume: volume, options: options, sink: &files, used: &used)
                case .exfat:
                    names.append("ExFAT")
                    try ExFATScanner.scan(reader: reader, volume: volume, options: options, sink: &files, used: &used)
                }
            } catch let error as RecoverError where error == .cancelled || error == .deviceGone {
                throw error
            } catch {
                warnings.append("Part of the file list couldn't be read, so the deep scan will look for those files instead.")
            }
        }
        if !files.isEmpty {
            options.onFound?(files)
        }

        var searched = false
        var unreadable: UInt64 = 0
        if options.deepScan || files.isEmpty {
            searched = true
            let cover = RangeCover(files, extra: used)
            var carved: [RecoverableFile] = []
            let outcome = try Carver.carve(reader: reader, covered: cover, options: options, foundSoFar: files.count, sink: &carved)
            files.append(contentsOf: carved)
            unreadable = outcome.unreadableBytes
            if unreadable > 0 {
                warnings.append("\(ByteText.string(unreadable)) of the disk couldn't be read. Files in those areas may be damaged.")
            }
        }
        if options.cancelled && searched {
            warnings.append("The scan was stopped early. Files found until then are listed.")
        }
        options.progress?(ScanProgress(phase: .finished, bytesDone: reader.size, bytesTotal: reader.size, found: files.count))
        return ScanResult(
            files: files,
            filesystem: names.isEmpty ? "Unknown" : Array(Set(names)).sorted().joined(separator: " and "),
            volumeCount: volumes.filter { $0.kind != .fat12 }.count,
            warnings: warnings,
            searchedContents: searched,
            unreadableBytes: unreadable
        )
    }

    /// Reads part of a recovered file without saving it, for previews.
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
            let chunk = try reader.readTolerant(at: range.offset + into, count: Int(want)).data
            output.append(chunk)
            skipped += range.length
        }
        return output
    }
}

enum FileBuilder {
    /// A deleted file found through the file system's records, checked against its first bytes.
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
        if FileTyping.skipFile(trimmed) { return nil }
        guard size > 0, !ranges.isEmpty else { return nil }
        guard ranges.allSatisfy({ $0.offset < reader.size && $0.length > 0 && $0.end <= reader.size }) else {
            return nil
        }
        let probe = RecoverableFile(
            id: id, name: trimmed, originalPath: trimmed, size: size, modified: nil, kind: .other,
            confidence: confidence, headerLooksValid: nil, complete: complete, ranges: ranges
        )
        let header = try RecoveryEngine.read(probe, from: reader, maxBytes: Signatures.headLength)
        let kind = FileTyping.kind(name: trimmed, header: header)
        let category = FileTyping.category(name: trimmed, kind: kind)
        guard options.wants(category) else { return nil }
        let path = directory.isEmpty ? trimmed : directory + "/" + trimmed
        let valid: Bool? = header.isEmpty ? nil : FileTyping.headerMatches(kind, header: header)
        return RecoverableFile(
            id: id,
            name: trimmed,
            originalPath: path,
            size: size,
            modified: modified,
            kind: kind,
            category: category,
            confidence: confidence,
            headerLooksValid: valid,
            complete: complete,
            ranges: ranges
        )
    }
}

public enum ManifestStore {
    public static func write(_ result: ScanResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
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
