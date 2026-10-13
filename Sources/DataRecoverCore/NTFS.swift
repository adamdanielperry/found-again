import Foundation

/// Where an NTFS volume keeps things, from its boot sector.
struct NTFSGeometry {
    var partitionOffset: UInt64
    var bytesPerSector: Int
    var clusterSize: UInt64
    var totalSectors: UInt64
    var totalClusters: UInt64
    var mftCluster: UInt64
    /// $MFTMirr: a spare copy of the first MFT records, used when record 0 itself is damaged.
    var mirrorCluster: UInt64
    var recordSize: Int

    var volumeBytes: UInt64 { totalSectors * UInt64(bytesPerSector) }

    /// Nil unless `boot` is a believable NTFS boot sector. Everything the scanner relies on is checked here,
    /// so a stray "NTFS" in the wrong place can't send it off reading nonsense.
    static func parse(boot: Data, at offset: UInt64) -> NTFSGeometry? {
        guard boot.count >= 512, boot[510] == 0x55, boot[511] == 0xAA else { return nil }
        guard boot.subdata(in: 3..<11) == Data("NTFS    ".utf8) else { return nil }
        guard let sectorBytes = Binary.u16le(boot, 0x0B), [512, 1024, 2048, 4096].contains(sectorBytes) else { return nil }
        let rawSectorsPerCluster = Int(boot[0x0D])
        let sectorsPerCluster: Int
        if rawSectorsPerCluster >= 0xF4 {
            // Clusters over 64 KB store a power of two as a negative number: 0xF4 means 2^12 sectors.
            sectorsPerCluster = 1 << (256 - rawSectorsPerCluster)
        } else if (1...128).contains(rawSectorsPerCluster), rawSectorsPerCluster & (rawSectorsPerCluster - 1) == 0 {
            sectorsPerCluster = rawSectorsPerCluster
        } else {
            return nil
        }
        let clusterSize = Int(sectorBytes) * sectorsPerCluster
        guard clusterSize <= 2 * 1024 * 1024 else { return nil }
        guard let totalSectors = Binary.u64le(boot, 0x28), totalSectors > 0, totalSectors < (1 << 48) else { return nil }
        let totalClusters = totalSectors / UInt64(sectorsPerCluster)
        guard let mftCluster = Binary.u64le(boot, 0x30), mftCluster > 0, mftCluster < totalClusters else { return nil }
        let mirror = Binary.u64le(boot, 0x38) ?? 0
        let rawRecord = Int(Int8(bitPattern: boot[0x40]))
        let recordSize: Int
        if rawRecord > 0 {
            recordSize = rawRecord * clusterSize
        } else if rawRecord < 0, -rawRecord <= 16 {
            // Records smaller than a cluster store a power of two as a negative number: -10 means 1024 bytes.
            recordSize = 1 << -rawRecord
        } else {
            return nil
        }
        guard (512...65536).contains(recordSize), recordSize & (recordSize - 1) == 0 else { return nil }
        return NTFSGeometry(
            partitionOffset: offset,
            bytesPerSector: Int(sectorBytes),
            clusterSize: UInt64(clusterSize),
            totalSectors: totalSectors,
            totalClusters: totalClusters,
            mftCluster: mftCluster,
            mirrorCluster: mirror < totalClusters ? mirror : 0,
            recordSize: recordSize
        )
    }

    func offset(ofCluster lcn: UInt64) -> UInt64 {
        partitionOffset + lcn * clusterSize
    }

    /// True when `count` clusters from `lcn` all lie on the volume.
    func contains(lcn: UInt64, count: UInt64) -> Bool {
        let (end, overflow) = lcn.addingReportingOverflow(count)
        return !overflow && end <= totalClusters
    }

    /// Byte ranges of the runs that lie on the volume. Sparse runs and anything past the end are left out.
    func ranges(of runs: [NTFSRun]) -> [ByteRange] {
        var result: [ByteRange] = []
        for run in runs {
            guard let lcn = run.lcn, lcn < totalClusters else { continue }
            let count = min(run.length, totalClusters - lcn)
            result.appendJoined(ByteRange(offset: offset(ofCluster: lcn), length: count * clusterSize))
        }
        return result
    }
}

/// Lists deleted files on an NTFS volume from its master file table (MFT). Deleting a file marks its MFT
/// record free but leaves the name, folder, dates and cluster list in place until the record is reused, so
/// recently deleted files usually come back with their names and folders.
enum NTFSScanner {
    /// Far more than an external drive usually holds. Stops a damaged size field from running away.
    static let maxRecords: UInt64 = 4_000_000
    /// Records below this belong to NTFS itself: $MFT, $LogFile, $Bitmap, the root folder and reserved spares.
    static let firstUserRecord: UInt64 = 24
    static let rootRecord: UInt64 = 5
    static let bitmapRecord: UInt64 = 6
    private static let chunkBytes: UInt64 = 4 * 1024 * 1024
    private static let fileCap = 100_000

    /// Lists deleted files. Clusters of live files and NTFS's own structures are added to `used` so the deep
    /// scan doesn't report them as found.
    static func scan(
        reader: BlockReader,
        volume: FoundVolume,
        options: ScanOptions,
        sink: inout [RecoverableFile],
        used: inout [ByteRange]
    ) throws {
        let boot = try reader.read(at: volume.offset, count: 512)
        guard let geometry = NTFSGeometry.parse(boot: boot, at: volume.offset) else {
            throw RecoverError.message("The NTFS boot sector is unreadable.")
        }
        used.append(contentsOf: reservedAreas(geometry))
        let mft = try loadMFT(reader: reader, geometry: geometry)
        used.append(contentsOf: geometry.ranges(of: mft.runs))
        var catalog = MFTCatalog(options: options)
        try walkMFT(reader: reader, geometry: geometry, mft: mft, options: options, catalog: &catalog, used: &used)
        try recover(catalog: catalog, reader: reader, geometry: geometry, options: options, sink: &sink)
    }

    /// The boot sector and its loader at the start of the volume, and the backup boot sector just past the end.
    private static func reservedAreas(_ geometry: NTFSGeometry) -> [ByteRange] {
        let start = min(geometry.volumeBytes, max(8192, geometry.clusterSize))
        return [
            ByteRange(offset: geometry.partitionOffset, length: start),
            ByteRange(offset: geometry.partitionOffset + geometry.volumeBytes, length: UInt64(geometry.bytesPerSector)),
        ]
    }

    /// Record 0 describes the MFT itself: where its clusters are and how long it is. If that record is torn,
    /// the mirror copy is tried.
    private static func loadMFT(reader: BlockReader, geometry: NTFSGeometry) throws -> NTFSStream {
        for cluster in [geometry.mftCluster, geometry.mirrorCluster] where cluster > 0 {
            let raw = try reader.readTolerant(at: geometry.offset(ofCluster: cluster), count: geometry.recordSize).data
            guard raw.count == geometry.recordSize,
                  let parsed = MFTRecord.parse(raw),
                  parsed.record.inUse,
                  let stream = parsed.record.dataStreams.first(where: { $0.firstVCN == 0 }),
                  !stream.runs.isEmpty
            else { continue }
            return stream
        }
        throw RecoverError.message("The NTFS file table couldn't be read.")
    }

    /// Reads the MFT front to back in large chunks, following its run list across fragments.
    private static func walkMFT(
        reader: BlockReader,
        geometry: NTFSGeometry,
        mft: NTFSStream,
        options: ScanOptions,
        catalog: inout MFTCatalog,
        used: inout [ByteRange]
    ) throws {
        let recordSize = UInt64(geometry.recordSize)
        let recordCount = min(mft.dataSize / recordSize, maxRecords)
        let chunkClusters = max(1, chunkBytes / geometry.clusterSize)
        var extents = mft.runs
        var mappedClusters = mft.clusterCount
        var buffer = MFTBuffer()
        var number: UInt64 = 0
        var index = 0
        reading: while index < extents.count, number < recordCount {
            let extent = extents[index]
            index += 1
            var done: UInt64 = 0
            while done < extent.length, number < recordCount {
                if options.cancelled { throw RecoverError.cancelled }
                let missing = (recordCount - number) * recordSize - UInt64(buffer.pending)
                let wanted = (missing + geometry.clusterSize - 1) / geometry.clusterSize
                let take = min(extent.length - done, chunkClusters, max(wanted, 1))
                let count = Int(take * geometry.clusterSize)
                if let lcn = extent.lcn {
                    guard geometry.contains(lcn: lcn, count: done + take) else { break reading }
                    let disk = geometry.offset(ofCluster: lcn + done)
                    buffer.append(try reader.readTolerant(at: disk, count: count).data, disk: disk, expected: count)
                } else {
                    // The MFT is never sparse, so this is damage. Zeros keep the record numbers in step.
                    buffer.append(Data(), disk: nil, expected: count)
                }
                done += take
                while number < recordCount, let next = buffer.next(geometry.recordSize) {
                    let current = number
                    number += 1
                    guard let parsed = MFTRecord.parse(next.bytes) else { continue }
                    let record = parsed.record
                    if record.inUse {
                        used.append(contentsOf: geometry.ranges(of: record.allocated))
                        if record.baseReference != 0, NTFSReference.record(record.baseReference) == 0 {
                            // An $MFT too fragmented for one record lists the rest of its runs in extension records.
                            for stream in record.dataStreams.sorted(by: { $0.firstVCN < $1.firstVCN })
                            where stream.firstVCN == mappedClusters {
                                extents.append(contentsOf: stream.runs)
                                let (sum, overflow) = mappedClusters.addingReportingOverflow(stream.clusterCount)
                                mappedClusters = overflow ? UInt64.max : sum
                            }
                        }
                    }
                    catalog.add(number: current, record: record, bytes: parsed.bytes) { piece in
                        buffer.diskRanges(recordStart: next.start, piece)
                    }
                }
                buffer.compact()
            }
        }
    }

    /// A deleted file's place on disk, and how far it can be trusted.
    private struct Layout {
        var ranges: [ByteRange]
        var confidence: RecoveryConfidence
        var complete: Bool
    }

    private struct Planned {
        var number: UInt64
        var name: String
        var folder: String
        var modified: Date?
        var layout: Layout
    }

    /// Turns the deleted files the walk collected into results, now that every folder and $Bitmap are known.
    private static func recover(
        catalog: MFTCatalog,
        reader: BlockReader,
        geometry: NTFSGeometry,
        options: ScanOptions,
        sink: inout [RecoverableFile]
    ) throws {
        var bitmap = ClusterBitmap(source: catalog.bitmap, geometry: geometry, reader: reader)
        var paths = NTFSPathResolver(folders: catalog.folders, recycled: catalog.recycled)
        var planned: [Planned] = []
        for candidate in catalog.candidates {
            if options.cancelled { throw RecoverError.cancelled }
            guard let place = place(candidate, catalog: catalog, paths: &paths, options: options),
                  let layout = try layout(candidate, catalog: catalog, geometry: geometry, bitmap: &bitmap)
            else { continue }
            planned.append(Planned(number: candidate.number, name: place.name, folder: place.folder, modified: candidate.modified, layout: layout))
        }
        // Checking each file's first bytes in disk order spares a spinning drive from seeking back and forth.
        planned.sort { ($0.layout.ranges.first?.offset ?? 0) < ($1.layout.ranges.first?.offset ?? 0) }
        for file in planned {
            if sink.count >= fileCap { break }
            if options.cancelled { throw RecoverError.cancelled }
            let size = file.layout.ranges.reduce(UInt64(0)) { $0 + $1.length }
            if let made = try FileBuilder.make(
                id: "ntfs-\(geometry.partitionOffset)-\(file.number)",
                name: file.name,
                directory: file.folder,
                size: size,
                modified: file.modified,
                confidence: file.layout.confidence,
                complete: file.layout.complete,
                ranges: file.layout.ranges,
                reader: reader,
                options: options
            ) {
                sink.append(made)
            }
        }
    }

    /// The folder and name to show for a deleted file, or nil when it shouldn't be listed.
    private static func place(
        _ candidate: MFTCatalog.Candidate,
        catalog: MFTCatalog,
        paths: inout NTFSPathResolver,
        options: ScanOptions
    ) -> (folder: String, name: String)? {
        if candidate.name.hasPrefix("$") {
            // Only Recycle Bin files whose original names survived are listed. Other $ files are NTFS's own.
            guard let original = catalog.recycled[RecycleBin.key(parent: candidate.parent, name: candidate.name)] else {
                return nil
            }
            let place = RecycleBin.split(original)
            if FileTyping.skipFile(place.name) || ruledOut(place.name, options: options) { return nil }
            return place
        }
        guard let folder = paths.path(for: candidate.parent) else { return nil }
        return (folder, candidate.name)
    }

    private static func layout(
        _ candidate: MFTCatalog.Candidate,
        catalog: MFTCatalog,
        geometry: NTFSGeometry,
        bitmap: inout ClusterBitmap
    ) throws -> Layout? {
        switch candidate.content {
        case .resident(let ranges):
            // Small files live inside their MFT record, which stays intact until the record is reused.
            return ranges.isEmpty ? nil : Layout(ranges: ranges, confidence: .named, complete: true)
        case .clusters(let own):
            guard let stream = catalog.joinedStream(candidate, own: own) else { return nil }
            return try clusterLayout(stream, geometry: geometry, bitmap: &bitmap)
        }
    }

    /// Maps a deleted file's runs to disk ranges and checks them against the allocation bitmap. Compressed
    /// and encrypted files are left out: their clusters can't be copied out as they are.
    private static func clusterLayout(_ stream: NTFSStream, geometry: NTFSGeometry, bitmap: inout ClusterBitmap) throws -> Layout? {
        guard !stream.compressed, !stream.encrypted, stream.dataSize > 0 else { return nil }
        var ranges: [ByteRange] = []
        var left = stream.dataSize
        var complete = true
        var outside = false
        var reused = false
        for run in stream.runs {
            if left == 0 { break }
            guard let lcn = run.lcn else {
                // A sparse stretch reads as zeros, which byte ranges can't express. Keep what comes before it.
                complete = false
                break
            }
            guard geometry.contains(lcn: lcn, count: run.length) else {
                outside = true
                break
            }
            let take = min(run.length * geometry.clusterSize, left)
            let clusters = (take + geometry.clusterSize - 1) / geometry.clusterSize
            if try bitmap.anyAllocated(from: lcn, count: clusters) {
                // A file whose first cluster now belongs to a live file has lost its start, and with it what
                // kind of file it was. Stale records like that are common on a well-used drive, so they're skipped.
                if ranges.isEmpty, try bitmap.isAllocated(lcn) { return nil }
                reused = true
            }
            ranges.appendJoined(ByteRange(offset: geometry.offset(ofCluster: lcn), length: take))
            left -= take
        }
        guard !ranges.isEmpty else { return nil }
        let whole = complete && !outside && !reused && left == 0 && stream.initializedSize >= stream.dataSize
        return Layout(ranges: ranges, confidence: outside || reused ? .estimated : .named, complete: whole)
    }

    /// True when the extension alone settles the file's kind and it's one the person isn't looking for.
    /// Spares reading the first bytes of files that would be dropped anyway.
    static func ruledOut(_ name: String, options: ScanOptions) -> Bool {
        guard !options.categories.isEmpty else { return false }
        guard let kind = FileTyping.kind(forExtension: FileTyping.extensionOf(name)), kind != .other else { return false }
        return !options.wants(kind.category)
    }
}

/// What the MFT walk keeps: folders for building paths, deleted files to finish later, and the pieces needed
/// to finish them once every record has been seen.
struct MFTCatalog {
    /// Well above the file cap, because some candidates are dropped later (reused clusters, lost names).
    static let candidateCap = 500_000

    struct Folder {
        var name: String
        var parent: UInt64
        var sequence: UInt16
        var inUse: Bool
    }

    struct Candidate {
        enum Content {
            /// Disk ranges of contents stored inside the MFT record.
            case resident([ByteRange])
            /// $DATA pieces from the file's own record. More may be in extension records.
            case clusters([NTFSStream])
        }

        var number: UInt64
        var sequence: UInt16
        var name: String
        var parent: UInt64
        var modified: Date?
        var content: Content
        var hasAttributeList: Bool
    }

    /// $DATA pieces from a freed extension record, with the sequence number of the file it belonged to.
    struct Extension {
        var baseSequence: UInt16
        var streams: [NTFSStream]
    }

    enum BitmapSource {
        case resident(Data)
        case clusters(NTFSStream)
    }

    let options: ScanOptions
    private(set) var folders: [UInt64: Folder] = [:]
    private(set) var candidates: [Candidate] = []
    private(set) var extensions: [UInt64: [Extension]] = [:]
    /// Original paths from Recycle Bin $I files, keyed by folder and the shared random part of the name.
    private(set) var recycled: [String: String] = [:]
    private(set) var bitmap: BitmapSource?

    init(options: ScanOptions) {
        self.options = options
    }

    /// Takes in one parsed record. `locate` maps a range of the record as stored on disk to disk offsets.
    mutating func add(number: UInt64, record: MFTRecord, bytes: Data, locate: (Range<Int>) -> [ByteRange]?) {
        if record.baseReference != 0 {
            // A deleted file's extension records are freed with it. Live ones only matter for `used`.
            if !record.inUse, !record.dataStreams.isEmpty {
                let base = NTFSReference.record(record.baseReference)
                let spill = Extension(baseSequence: NTFSReference.sequence(record.baseReference), streams: record.dataStreams)
                extensions[base, default: []].append(spill)
            }
            return
        }
        if number == NTFSScanner.bitmapRecord, record.inUse {
            if let value = record.residentData {
                bitmap = .resident(bytes.subdata(in: value))
            } else if let first = record.dataStreams.first(where: { $0.firstVCN == 0 }) {
                bitmap = .clusters(first)
            }
        }
        guard let fileName = record.fileName else { return }
        let name = fileName.name.replacingOccurrences(of: "/", with: "_")
        if record.isDirectory {
            folders[number] = Folder(name: name, parent: fileName.parent, sequence: record.sequence, inUse: record.inUse)
            return
        }
        if name.hasPrefix("$I"), let value = record.residentData, let original = RecycleBin.originalPath(bytes.subdata(in: value)) {
            recycled[RecycleBin.key(parent: fileName.parent, name: name)] = original
        }
        guard !record.inUse, number >= NTFSScanner.firstUserRecord, candidates.count < Self.candidateCap else { return }
        if name.hasPrefix("$") {
            // Recycle Bin files ($R…) are kept until it's known whether their original names survived.
            guard name.hasPrefix("$R") else { return }
        } else if FileTyping.skipFile(name) || NTFSScanner.ruledOut(name, options: options) {
            return
        }
        let content: Candidate.Content
        if let value = record.residentData {
            guard !value.isEmpty else { return }
            var ranges: [ByteRange] = []
            for piece in record.storedPieces(of: value) {
                guard let disk = locate(piece) else { return }
                for range in disk { ranges.appendJoined(range) }
            }
            content = .resident(ranges)
        } else if !record.dataStreams.isEmpty || record.hasAttributeList {
            content = .clusters(record.dataStreams)
        } else {
            return
        }
        candidates.append(Candidate(
            number: number,
            sequence: record.sequence,
            name: name,
            parent: fileName.parent,
            modified: record.modified,
            content: content,
            hasAttributeList: record.hasAttributeList
        ))
    }

    /// A deleted file's $DATA run list, joined from its own record and from freed extension records that still
    /// point back at it. Nil when the start of the list is missing.
    func joinedStream(_ candidate: Candidate, own: [NTFSStream]) -> NTFSStream? {
        var pieces = own
        if candidate.hasAttributeList {
            for spill in extensions[candidate.number] ?? []
            where NTFSReference.matches(sequence: candidate.sequence, inUse: false, expected: spill.baseSequence) {
                pieces.append(contentsOf: spill.streams)
            }
        }
        pieces.sort { $0.firstVCN < $1.firstVCN }
        guard var joined = pieces.first, joined.firstVCN == 0 else { return nil }
        var next = joined.clusterCount
        for piece in pieces.dropFirst() {
            // An overlapping piece is a stale copy. A gap means the rest of the list is gone.
            if piece.firstVCN < next { continue }
            if piece.firstVCN > next { break }
            joined.runs.append(contentsOf: piece.runs)
            joined.compressed = joined.compressed || piece.compressed
            joined.encrypted = joined.encrypted || piece.encrypted
            let (sum, overflow) = next.addingReportingOverflow(piece.clusterCount)
            next = overflow ? UInt64.max : sum
        }
        return joined
    }
}

/// MFT bytes read so far and where each part came from on disk. A record that straddles two fragments of the
/// MFT still comes out whole, and contents stored inside a record can be traced back to their disk offsets.
struct MFTBuffer {
    private struct Piece {
        var start: Int
        var disk: UInt64?
        var length: Int
    }

    private var data = Data()
    private var pieces: [Piece] = []
    private var cursor = 0

    /// Bytes read but not yet handed out as a record.
    var pending: Int { data.count - cursor }

    /// Adds a chunk read from `disk`. A short chunk (the end of the disk) is padded with zeros that map nowhere.
    mutating func append(_ chunk: Data, disk: UInt64?, expected: Int) {
        if !chunk.isEmpty {
            pieces.append(Piece(start: data.count, disk: disk, length: chunk.count))
            data.append(chunk)
        }
        if chunk.count < expected {
            pieces.append(Piece(start: data.count, disk: nil, length: expected - chunk.count))
            data.append(Data(count: expected - chunk.count))
        }
    }

    /// The next whole record and where it starts in the buffer.
    mutating func next(_ size: Int) -> (bytes: Data, start: Int)? {
        guard size > 0, pending >= size else { return nil }
        let start = cursor
        cursor += size
        return (data.subdata(in: start..<(start + size)), start)
    }

    /// Disk ranges for `range` of the record starting at `recordStart`. Nil when part of it has no disk location.
    func diskRanges(recordStart: Int, _ range: Range<Int>) -> [ByteRange]? {
        var result: [ByteRange] = []
        var position = recordStart + range.lowerBound
        let end = recordStart + range.upperBound
        while position < end {
            guard let piece = pieces.first(where: { position >= $0.start && position < $0.start + $0.length }),
                  let disk = piece.disk
            else { return nil }
            let stop = min(end, piece.start + piece.length)
            result.appendJoined(ByteRange(offset: disk + UInt64(position - piece.start), length: UInt64(stop - position)))
            position = stop
        }
        return result
    }

    /// Forgets the bytes already handed out, keeping any partial record for the next chunk.
    mutating func compact() {
        guard cursor > 0 else { return }
        data = data.subdata(in: cursor..<data.count)
        pieces = pieces.compactMap { piece in
            let end = piece.start + piece.length
            guard end > cursor else { return nil }
            let start = max(piece.start, cursor)
            let skipped = UInt64(start - piece.start)
            return Piece(start: start - cursor, disk: piece.disk.map { $0 + skipped }, length: end - start)
        }
        cursor = 0
    }
}

/// Turns parent-folder references into paths, walking up through folders that still exist and folders that
/// were deleted along with the file.
struct NTFSPathResolver {
    static let lostFolders = "Lost folders"

    private struct Link {
        var reference: UInt64
        var name: String
    }

    let folders: [UInt64: MFTCatalog.Folder]
    let recycled: [String: String]
    private var known: [UInt64: String] = [:]
    private var hidden: Set<UInt64> = []

    init(folders: [UInt64: MFTCatalog.Folder], recycled: [String: String]) {
        self.folders = folders
        self.recycled = recycled
    }

    /// The folder path for a parent reference, or nil when it lies inside a folder that only holds system files.
    /// A folder whose record now belongs to something else can't be named, so its files go under "Lost folders".
    mutating func path(for reference: UInt64) -> String? {
        var chain: [Link] = []
        var visited = Set<UInt64>()
        var current = reference
        var base = ""
        while true {
            let record = NTFSReference.record(current)
            if record == NTFSScanner.rootRecord { break }
            if let path = known[current] {
                base = path
                break
            }
            if hidden.contains(current) {
                hide(chain)
                return nil
            }
            guard chain.count < 64, visited.insert(record).inserted,
                  let folder = folders[record],
                  NTFSReference.matches(sequence: folder.sequence, inUse: folder.inUse, expected: NTFSReference.sequence(current))
            else {
                base = Self.lostFolders + "/Folder \(record)"
                break
            }
            if FileTyping.skipDirectory(folder.name) {
                hidden.insert(current)
                hide(chain)
                return nil
            }
            if folder.name.hasPrefix("$R"), let original = recycled[RecycleBin.key(parent: folder.parent, name: folder.name)] {
                // A folder moved to the Recycle Bin: what was inside belongs under the folder's original path.
                base = original
                known[current] = original
                break
            }
            chain.append(Link(reference: current, name: folder.name))
            current = folder.parent
        }
        var path = base
        for link in chain.reversed() {
            path = path.isEmpty ? link.name : path + "/" + link.name
            known[link.reference] = path
        }
        return path
    }

    private mutating func hide(_ chain: [Link]) {
        for link in chain { hidden.insert(link.reference) }
    }
}

/// Windows renames a file moved to the Recycle Bin to $R plus random characters and the original extension,
/// and writes the original path into a small companion file named $I with the same characters, in the same
/// folder. Emptying the bin deletes both, but the $I file is small enough to be stored inside its MFT record,
/// so the original name and folder usually survive.
enum RecycleBin {
    static func key(parent: UInt64, name: String) -> String {
        "\(NTFSReference.record(parent))/\(name.dropFirst(2).uppercased())"
    }

    /// The original path stored in a $I file, relative and without the drive letter.
    static func originalPath(_ data: Data) -> String? {
        guard let version = Binary.u64le(data, 0) else { return nil }
        let start: Int
        let limit: Int
        switch version {
        case 1:
            // Windows Vista to 8.1: a fixed field of 260 characters.
            start = 0x18
            limit = 260
        case 2:
            // Windows 10 and later: a character count, then the path.
            guard let count = Binary.u32le(data, 0x18) else { return nil }
            start = 0x1C
            limit = Int(min(count, 32_768))
        default:
            return nil
        }
        var units: [UInt16] = []
        var position = start
        while units.count < limit, let unit = Binary.u16le(data, position), unit != 0 {
            units.append(unit)
            position += 2
        }
        guard !units.isEmpty else { return nil }
        let path = String(utf16CodeUnits: units, count: units.count)
        var parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        parts.removeAll { $0 == "." || $0 == ".." || $0 == "?" }
        if let first = parts.first, first.count == 2, first.hasSuffix(":") {
            parts.removeFirst()
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}

/// The volume's cluster allocation bitmap ($Bitmap), read a megabyte at a time as deleted files ask about their
/// clusters. A cluster marked in use belongs to a live file now, so a deleted file's bytes there are gone.
struct ClusterBitmap {
    private static let pageBytes: UInt64 = 1 << 20
    private let source: MFTCatalog.BitmapSource?
    private let geometry: NTFSGeometry
    private let reader: BlockReader
    private var pages: [UInt64: Data] = [:]

    init(source: MFTCatalog.BitmapSource?, geometry: NTFSGeometry, reader: BlockReader) {
        self.source = source
        self.geometry = geometry
        self.reader = reader
    }

    mutating func isAllocated(_ cluster: UInt64) throws -> Bool {
        guard let byte = try byte(cluster / 8) else { return false }
        return byte & (UInt8(1) << UInt8(cluster % 8)) != 0
    }

    /// The caller has checked that the clusters lie on the volume.
    mutating func anyAllocated(from start: UInt64, count: UInt64) throws -> Bool {
        var cluster = start
        let end = start + count
        while cluster < end {
            if cluster % 8 == 0, end - cluster >= 8 {
                if let byte = try byte(cluster / 8), byte != 0 { return true }
                cluster += 8
            } else {
                if try isAllocated(cluster) { return true }
                cluster += 1
            }
        }
        return false
    }

    /// Nil when the bitmap is missing or too short. Unknown clusters are treated as free.
    private mutating func byte(_ index: UInt64) throws -> UInt8? {
        switch source {
        case .none:
            return nil
        case .resident(let data)?:
            return index < UInt64(data.count) ? data[Int(index)] : nil
        case .clusters(let stream)?:
            guard index < stream.dataSize else { return nil }
            let page = index / Self.pageBytes
            let data: Data
            if let cached = pages[page] {
                data = cached
            } else {
                let start = page * Self.pageBytes
                let count = Int(min(Self.pageBytes, stream.dataSize - start))
                data = try stream.read(from: reader, geometry: geometry, at: start, count: count)
                pages[page] = data
            }
            let within = Int(index % Self.pageBytes)
            return within < data.count ? data[within] : nil
        }
    }
}

extension NTFSStream {
    /// Reads `count` bytes from `offset` bytes into the attribute. Sparse runs and runs off the volume read as
    /// zeros. The result is shorter when the run list ends first.
    func read(from reader: BlockReader, geometry: NTFSGeometry, at offset: UInt64, count: Int) throws -> Data {
        var output = Data()
        let end = offset + UInt64(max(count, 0))
        var position: UInt64 = 0
        for run in runs {
            guard position < end else { break }
            let (runBytes, tooLong) = run.length.multipliedReportingOverflow(by: geometry.clusterSize)
            let (runEnd, tooFar) = position.addingReportingOverflow(runBytes)
            guard !tooLong, !tooFar else { break }
            if runEnd > offset {
                let from = max(offset, position)
                let want = Int(min(end, runEnd) - from)
                if let lcn = run.lcn, geometry.contains(lcn: lcn, count: run.length) {
                    let chunk = try reader.readTolerant(at: geometry.offset(ofCluster: lcn) + (from - position), count: want).data
                    output.append(chunk)
                    if chunk.count < want { output.append(Data(count: want - chunk.count)) }
                } else {
                    output.append(Data(count: want))
                }
            }
            position = runEnd
        }
        return output
    }
}

extension Array where Element == ByteRange {
    /// Appends `range`, extending the last range instead when the two meet.
    mutating func appendJoined(_ range: ByteRange) {
        guard range.length > 0 else { return }
        if let last = last, last.end == range.offset {
            self[count - 1].length += range.length
        } else {
            append(range)
        }
    }
}
