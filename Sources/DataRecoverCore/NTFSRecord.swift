import Foundation

/// NTFS file references pack a 48-bit MFT record number with a 16-bit sequence number. The sequence number
/// changes whenever a record is freed, so a reference to a record that has since been reused can be spotted.
enum NTFSReference {
    static func record(_ reference: UInt64) -> UInt64 { reference & 0x0000_FFFF_FFFF_FFFF }

    static func sequence(_ reference: UInt64) -> UInt16 { UInt16(truncatingIfNeeded: reference >> 48) }

    /// Windows adds one to a record's sequence number when it frees the record, skipping zero.
    static func afterFree(_ sequence: UInt16) -> UInt16 {
        let next = sequence &+ 1
        return next == 0 ? 1 : next
    }

    /// True when a record now holding `sequence` is still the one a reference made with `expected` meant.
    /// A record deleted together with the files pointing at it is one ahead of their references.
    static func matches(sequence: UInt16, inUse: Bool, expected: UInt16) -> Bool {
        if sequence == expected { return true }
        return !inUse && sequence == afterFree(expected)
    }
}

/// One run from an attribute's run list. `lcn` is nil for a sparse run: a stretch of the file that reads
/// as zeros and has no clusters on disk.
struct NTFSRun: Equatable {
    var lcn: UInt64?
    var length: UInt64
}

/// The clusters of a non-resident attribute, or the piece of it one record holds when a large or very
/// fragmented file needs more than one record to list them all.
struct NTFSStream {
    /// First virtual cluster of the file this piece covers. Zero for the first or only piece.
    var firstVCN: UInt64
    var runs: [NTFSRun]
    /// The file's real length. Only meaningful in the piece that starts at VCN 0.
    var dataSize: UInt64
    /// Bytes past this were never written. Windows reads them as zeros, the disk may hold anything.
    var initializedSize: UInt64
    /// Compressed contents are stored in LZNT1 blocks, so the clusters can't be copied out as they are.
    var compressed: Bool
    /// Encrypted (EFS) contents can't be read without the owner's key.
    var encrypted: Bool

    var clusterCount: UInt64 {
        runs.reduce(UInt64(0)) { total, run in
            let (sum, overflow) = total.addingReportingOverflow(run.length)
            return overflow ? UInt64.max : sum
        }
    }
}

enum NTFSRunList {
    /// Decodes a packed run list ("mapping pairs"). Each run starts with a byte whose low four bits give the
    /// size of the length field and whose high four bits give the size of the offset field. The offset is
    /// signed and relative to the previous run's start; a zero-size offset marks a sparse run. Nil when the
    /// list is malformed.
    static func decode(_ data: Data, from start: Int, to end: Int) -> [NTFSRun]? {
        guard start >= 0, start <= end, end <= data.count else { return nil }
        var runs: [NTFSRun] = []
        var position = start
        var lcn: Int64 = 0
        while position < end {
            let header = data[position]
            if header == 0 { return runs }
            let lengthBytes = Int(header & 0x0F)
            let offsetBytes = Int(header >> 4)
            guard (1...8).contains(lengthBytes), offsetBytes <= 8 else { return nil }
            guard position + 1 + lengthBytes + offsetBytes <= end else { return nil }
            let length = signed(data, at: position + 1, count: lengthBytes)
            guard length > 0 else { return nil }
            if offsetBytes == 0 {
                runs.append(NTFSRun(lcn: nil, length: UInt64(length)))
            } else {
                let delta = signed(data, at: position + 1 + lengthBytes, count: offsetBytes)
                let (next, overflow) = lcn.addingReportingOverflow(delta)
                guard !overflow, next >= 0 else { return nil }
                lcn = next
                runs.append(NTFSRun(lcn: UInt64(next), length: UInt64(length)))
            }
            position += 1 + lengthBytes + offsetBytes
        }
        // Ran into the end of the attribute without the terminating zero. What was read is still usable.
        return runs
    }

    /// A little-endian two's-complement number `count` bytes long. The caller has checked the bounds.
    private static func signed(_ data: Data, at offset: Int, count: Int) -> Int64 {
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(data[offset + index]) << (8 * UInt64(index))
        }
        if count < 8, data[offset + count - 1] & 0x80 != 0 {
            value |= UInt64.max << (8 * UInt64(count))
        }
        return Int64(bitPattern: value)
    }
}

/// A $FILE_NAME attribute: one of the names a file is known by, and the folder it was in.
struct NTFSFileName {
    var parent: UInt64
    var name: String
    var namespace: UInt8
    var modified: Date?

    /// Win32 names are the ones Explorer shows. POSIX names are also full names. DOS 8.3 names are a last resort.
    var rank: Int {
        switch namespace {
        case 1, 3: return 3
        case 0: return 2
        default: return 1
        }
    }
}

/// The parts of one MFT FILE record the scanner needs. Every value has been bounds-checked against the record.
struct MFTRecord {
    var sequence: UInt16
    var inUse: Bool
    var isDirectory: Bool
    /// Non-zero for an extension record: a spill-over record holding more attributes of the file it points to.
    var baseReference: UInt64
    var fileName: NTFSFileName?
    /// Last change to the contents, from $STANDARD_INFORMATION, or from $FILE_NAME when that is missing.
    var modified: Date?
    /// Where the unnamed $DATA value sits inside the record, for small files stored in the record itself.
    var residentData: Range<Int>?
    /// Pieces of the unnamed $DATA attribute when the contents are in clusters.
    var dataStreams: [NTFSStream]
    /// The file's attributes are spread over more records than this one.
    var hasAttributeList: Bool
    /// Runs of every non-resident attribute, collected only for records in use so the deep scan can skip them.
    var allocated: [NTFSRun]
    var updateSequenceOffset: Int
    var updateSequenceCount: Int
}

extension MFTRecord {
    private static let magic = Data("FILE".utf8)
    private static let block = 512

    private enum Attribute {
        static let standardInformation: UInt32 = 0x10
        static let attributeList: UInt32 = 0x20
        static let fileName: UInt32 = 0x30
        static let data: UInt32 = 0x80
        static let end: UInt32 = 0xFFFF_FFFF
    }

    /// Reads one FILE record, exactly as stored on disk and starting at index 0. Returns the record and its
    /// bytes with the fixups undone, or nil when it isn't a FILE record or one of its sectors was torn.
    static func parse(_ raw: Data) -> (record: MFTRecord, bytes: Data)? {
        guard raw.count >= block, raw.starts(with: magic) else { return nil }
        var bytes = raw
        guard let fixups = applyFixups(&bytes),
              let flags = Binary.u16le(bytes, 0x16),
              let sequence = Binary.u16le(bytes, 0x10),
              let firstAttribute16 = Binary.u16le(bytes, 0x14),
              let bytesInUse = Binary.u32le(bytes, 0x18),
              let base = Binary.u64le(bytes, 0x20)
        else { return nil }
        let limit = bytesInUse >= 0x30 && bytesInUse <= UInt32(bytes.count) ? Int(bytesInUse) : bytes.count
        let firstAttribute = Int(firstAttribute16)
        guard firstAttribute >= fixups.offset + fixups.count * 2, firstAttribute + 8 <= limit else { return nil }

        var record = MFTRecord(
            sequence: sequence,
            inUse: flags & 0x0001 != 0,
            isDirectory: flags & 0x0002 != 0,
            baseReference: base,
            fileName: nil,
            modified: nil,
            residentData: nil,
            dataStreams: [],
            hasAttributeList: false,
            allocated: [],
            updateSequenceOffset: fixups.offset,
            updateSequenceCount: fixups.count
        )
        var nameModified: Date?
        var offset = firstAttribute
        var seen = 0
        while offset + 16 <= limit, seen < 512 {
            seen += 1
            guard let type = Binary.u32le(bytes, offset), type != Attribute.end else { break }
            guard let length32 = Binary.u32le(bytes, offset + 4), length32 >= 16, length32 <= UInt32(limit - offset) else {
                break
            }
            let length = Int(length32)
            let attribute = offset..<(offset + length)
            let nonResident = bytes[offset + 8] != 0
            let unnamed = bytes[offset + 9] == 0
            let clusters = nonResident ? stream(bytes, attribute) : nil
            switch type {
            case Attribute.standardInformation where !nonResident:
                if let value = residentValue(bytes, attribute), value.count >= 0x10 {
                    record.modified = Binary.fileTimeDate(Binary.u64le(bytes, value.lowerBound + 0x08) ?? 0)
                }
            case Attribute.attributeList:
                record.hasAttributeList = true
            case Attribute.fileName where !nonResident:
                if let value = residentValue(bytes, attribute), let name = fileName(bytes, value) {
                    if record.fileName == nil || name.rank > (record.fileName?.rank ?? 0) {
                        record.fileName = name
                        nameModified = name.modified
                    }
                }
            case Attribute.data where unnamed:
                if let clusters {
                    record.dataStreams.append(clusters)
                } else if !nonResident, let value = residentValue(bytes, attribute) {
                    record.residentData = value
                }
            default:
                break
            }
            if record.inUse, let clusters {
                record.allocated.append(contentsOf: clusters.runs)
            }
            offset += length
        }
        if record.modified == nil { record.modified = nameModified }
        return (record, bytes)
    }

    /// NTFS guards each record against half-finished writes: before writing, it copies the last two bytes of
    /// every 512-byte block into the update sequence array and stores a shared check value there instead.
    /// A block whose last two bytes don't hold the check value was only partly written, so the record is
    /// rejected. Returns where the array is, needed later to map resident bytes back to the disk.
    static func applyFixups(_ bytes: inout Data) -> (offset: Int, count: Int)? {
        guard let offset16 = Binary.u16le(bytes, 4), let count16 = Binary.u16le(bytes, 6) else { return nil }
        let offset = Int(offset16)
        let count = Int(count16)
        let blocks = count - 1
        guard offset >= 0x28, offset % 2 == 0, blocks >= 1, offset + count * 2 <= block, blocks * block <= bytes.count else {
            return nil
        }
        let check0 = bytes[offset]
        let check1 = bytes[offset + 1]
        for index in 1...blocks {
            let tail = index * block - 2
            guard bytes[tail] == check0, bytes[tail + 1] == check1 else { return nil }
            bytes[tail] = bytes[offset + index * 2]
            bytes[tail + 1] = bytes[offset + index * 2 + 1]
        }
        return (offset, count)
    }

    /// Where the true bytes of `value` (a range of the fixed-up record) sit in the record as stored on disk.
    /// On disk the last two bytes of each protected block hold the check value; the real bytes are in the
    /// update sequence array, so those two bytes are taken from there.
    func storedPieces(of value: Range<Int>) -> [Range<Int>] {
        let block = Self.block
        let protectedBlocks = updateSequenceCount - 1
        var pieces: [Range<Int>] = []
        var position = value.lowerBound
        while position < value.upperBound {
            let index = position / block
            let tail = index * block + block - 2
            let piece: Range<Int>
            let advance: Int
            if index < protectedBlocks, position >= tail {
                let entry = updateSequenceOffset + (index + 1) * 2 + (position - tail)
                advance = min(value.upperBound, tail + 2) - position
                piece = entry..<(entry + advance)
            } else {
                let stop = index < protectedBlocks ? min(value.upperBound, tail) : min(value.upperBound, (index + 1) * block)
                advance = stop - position
                piece = position..<stop
            }
            if let last = pieces.last, last.upperBound == piece.lowerBound {
                pieces[pieces.count - 1] = last.lowerBound..<piece.upperBound
            } else {
                pieces.append(piece)
            }
            position += advance
        }
        return pieces
    }

    /// The value of a resident attribute, as a range of the record.
    private static func residentValue(_ bytes: Data, _ attribute: Range<Int>) -> Range<Int>? {
        guard attribute.count >= 0x18,
              let length = Binary.u32le(bytes, attribute.lowerBound + 0x10),
              let start = Binary.u16le(bytes, attribute.lowerBound + 0x14)
        else { return nil }
        let lower = attribute.lowerBound + Int(start)
        guard Int(start) >= 0x18, UInt64(lower) + UInt64(length) <= UInt64(attribute.upperBound) else { return nil }
        return lower..<(lower + Int(length))
    }

    private static func fileName(_ bytes: Data, _ value: Range<Int>) -> NTFSFileName? {
        let base = value.lowerBound
        guard value.count >= 0x42, let parent = Binary.u64le(bytes, base) else { return nil }
        let characters = Int(bytes[base + 0x40])
        let namespace = bytes[base + 0x41]
        guard characters > 0, 0x42 + characters * 2 <= value.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(characters)
        for index in 0..<characters {
            units.append(Binary.u16le(bytes, base + 0x42 + index * 2) ?? 0)
        }
        let name = String(utf16CodeUnits: units, count: units.count)
        guard !name.isEmpty else { return nil }
        let modified = Binary.fileTimeDate(Binary.u64le(bytes, base + 0x10) ?? 0)
        return NTFSFileName(parent: parent, name: name, namespace: namespace, modified: modified)
    }

    /// The header and run list of a non-resident attribute.
    private static func stream(_ bytes: Data, _ attribute: Range<Int>) -> NTFSStream? {
        let base = attribute.lowerBound
        guard attribute.count >= 0x40,
              bytes[base + 8] != 0,
              let flags = Binary.u16le(bytes, base + 0x0C),
              let firstVCN = Binary.u64le(bytes, base + 0x10),
              let runOffset = Binary.u16le(bytes, base + 0x20),
              let dataSize = Binary.u64le(bytes, base + 0x30),
              let initializedSize = Binary.u64le(bytes, base + 0x38),
              Int(runOffset) >= 0x40, Int(runOffset) < attribute.count,
              let runs = NTFSRunList.decode(bytes, from: base + Int(runOffset), to: attribute.upperBound)
        else { return nil }
        return NTFSStream(
            firstVCN: firstVCN,
            runs: runs,
            dataSize: dataSize,
            initializedSize: initializedSize,
            compressed: flags & 0x00FF != 0,
            encrypted: flags & 0x4000 != 0
        )
    }
}
