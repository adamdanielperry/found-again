import Foundation

/// Matroska and WebM: an EBML header naming the document type, then one Segment element holding everything else.
/// The Segment's size gives the file's length. Live recordings leave it "unknown", so then the clusters are walked.
struct MatroskaCarver: FormatCarver {
    static let maxSize: UInt64 = 64 * 1024 * 1024 * 1024

    private static let ebmlID: UInt32 = 0x1A45_DFA3
    private static let segmentID: UInt32 = 0x1853_8067
    private static let clusterID: UInt32 = 0x1F43_B675
    private static let infoID: UInt32 = 0x1549_A966
    private static let tracksID: UInt32 = 0x1654_AE6B
    /// Elements that may sit directly inside a Segment.
    private static let topLevel: Set<UInt32> = [
        0x114D_9B74, infoID, tracksID, clusterID, 0x1C53_BB6B, 0x1941_A469, 0x1043_A770, 0x1254_C367, 0xEC, 0xBF,
    ]
    /// Elements that may sit directly inside a Cluster.
    private static let clusterChildren: Set<UInt32> = [0xE7, 0x5854, 0xA7, 0xAB, 0xA3, 0xA0, 0xAF, 0xEC, 0xBF]

    var leadBytes: [UInt8]? { [0x1A] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 16, head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]), head[4] != 0 else { return nil }
        // The DocType tells WebM apart; carve reads it.
        return .mkv
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end, windowSize: 256 * 1024)
        guard let header = Self.element(bytes, at: start), header.id == Self.ebmlID,
              let headerSize = header.size, headerSize >= 8, headerSize <= 4096,
              let fields = bytes.bytes(at: header.dataStart, count: Int(headerSize)), fields.count == Int(headerSize),
              let docType = Self.docType(fields)
        else { return nil }
        let found: FileKind
        switch docType {
        case "webm": found = .webm
        case "matroska": found = .mkv
        default: return nil
        }

        let segmentStart = header.dataStart + headerSize
        guard let segment = Self.element(bytes, at: segmentStart), segment.id == Self.segmentID else { return nil }
        var walk = SegmentWalk()
        if let size = segment.size {
            let segmentEnd = segment.dataStart + size
            guard segmentEnd <= end else { return nil }
            // Check the first few children make sense; trust the declared size for the rest.
            guard let stop = Self.walk(bytes, from: segment.dataStart, to: segmentEnd, maxElements: 64, into: &walk),
                  stop == segmentEnd || walk.elements >= 64, walk.sawInfo || walk.sawTracks
            else { return nil }
            return Carved(kind: found, size: segmentEnd - start, modified: walk.date)
        }
        guard let stop = Self.walk(bytes, from: segment.dataStart, to: end, maxElements: 10_000_000, into: &walk),
              walk.sawTracks, walk.clusters > 0
        else { return nil }
        return Carved(kind: found, size: stop - start, modified: walk.date)
    }

    struct SegmentWalk {
        var elements = 0
        var sawInfo = false
        var sawTracks = false
        var clusters = 0
        var date: Date?
    }

    /// Steps through Segment children. Returns where the Segment's content stops: at `limit`, or at the first element
    /// that can't be part of it when the size is unknown. Nil when an element overruns the limit.
    private static func walk(_ bytes: ByteWindow, from: UInt64, to limit: UInt64, maxElements: Int, into walk: inout SegmentWalk) -> UInt64? {
        var position = from
        var count = 0
        while position < limit, count < maxElements {
            // Void and CRC-32 have one-byte IDs that leftover data could mimic, so their sizes are held to what muxers write.
            guard let child = element(bytes, at: position), topLevel.contains(child.id),
                  child.id != 0xBF || child.size == 4, child.id != 0xEC || (child.size ?? .max) <= 16 * 1024 * 1024
            else {
                // Unknown-size segments end where something else begins.
                return count > 0 ? position : nil
            }
            count += 1
            walk.elements = count
            switch child.id {
            case infoID:
                walk.sawInfo = true
                if let size = child.size, size <= 64 * 1024, let data = bytes.bytes(at: child.dataStart, count: Int(size)) {
                    walk.date = walk.date ?? date(info: data)
                }
            case tracksID:
                walk.sawTracks = true
            case clusterID:
                walk.clusters += 1
            default:
                break
            }
            if let size = child.size {
                guard child.dataStart + size <= limit else { return nil }
                position = child.dataStart + size
            } else {
                // Only clusters may have unknown size: they end where an element that isn't a cluster child begins.
                guard child.id == clusterID, let after = clusterEnd(bytes, from: child.dataStart, limit: limit) else { return nil }
                position = after
            }
        }
        return position
    }

    private static func clusterEnd(_ bytes: ByteWindow, from: UInt64, limit: UInt64) -> UInt64? {
        var position = from
        while position < limit {
            guard let child = element(bytes, at: position), clusterChildren.contains(child.id) else { return position }
            guard let size = child.size, child.dataStart + size <= limit else { return nil }
            position = child.dataStart + size
        }
        return position
    }

    struct Element {
        var id: UInt32
        /// Nil for "unknown size", all value bits set.
        var size: UInt64?
        var dataStart: UInt64
    }

    /// Reads an element ID (marker bits kept, 1–4 bytes) and its variable-length size (1–8 bytes).
    private static func element(_ bytes: ByteWindow, at offset: UInt64) -> Element? {
        guard let first = bytes.byte(at: offset), first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1
        guard idLength <= 4 else { return nil }
        var id = UInt32(first)
        for index in 1..<idLength {
            guard let byte = bytes.byte(at: offset + UInt64(index)) else { return nil }
            id = (id << 8) | UInt32(byte)
        }
        let sizeAt = offset + UInt64(idLength)
        guard let lead = bytes.byte(at: sizeAt), lead != 0 else { return nil }
        let sizeLength = lead.leadingZeroBitCount + 1
        var value = UInt64(lead & (0xFF >> UInt8(sizeLength)))
        var allOnes = value == UInt64(0xFF >> UInt8(sizeLength))
        for index in 1..<sizeLength {
            guard let byte = bytes.byte(at: sizeAt + UInt64(index)) else { return nil }
            value = (value << 8) | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        let dataStart = sizeAt + UInt64(sizeLength)
        if allOnes { return Element(id: id, size: nil, dataStart: dataStart) }
        guard value <= maxSize else { return nil }
        return Element(id: id, size: value, dataStart: dataStart)
    }

    /// Finds DocType (0x4282) among the EBML header's fields.
    private static func docType(_ fields: Data) -> String? {
        let reader = DataBlockReader(fields)
        let bytes = ByteWindow(reader: reader, end: UInt64(fields.count))
        var position: UInt64 = 0
        while position < UInt64(fields.count) {
            guard let child = element(bytes, at: position), let size = child.size,
                  child.dataStart + size <= UInt64(fields.count)
            else { return nil }
            if child.id == 0x4282 {
                let text = fields.subdata(in: Int(child.dataStart)..<Int(child.dataStart + size)).prefix { $0 != 0 }
                return String(decoding: text, as: UTF8.self)
            }
            position = child.dataStart + size
        }
        return nil
    }

    /// DateUTC (0x4461) in the Info element: nanoseconds since the start of 2001, UTC.
    private static func date(info: Data) -> Date? {
        let reader = DataBlockReader(info)
        let bytes = ByteWindow(reader: reader, end: UInt64(info.count))
        var position: UInt64 = 0
        while position < UInt64(info.count) {
            guard let child = element(bytes, at: position), let size = child.size,
                  child.dataStart + size <= UInt64(info.count)
            else { return nil }
            if child.id == 0x4461, size == 8, let raw = Binary.u64be(info, Int(child.dataStart)) {
                let seconds = Double(Int64(bitPattern: raw)) / 1_000_000_000
                let date = Date(timeIntervalSinceReferenceDate: seconds)
                let year = Calendar(identifier: .gregorian).component(.year, from: date)
                return (1995...2100).contains(year) ? date : nil
            }
            position = child.dataStart + size
        }
        return nil
    }
}
