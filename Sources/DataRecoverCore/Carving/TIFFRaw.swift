import Foundation

/// TIFF and the camera raw formats built on it: CR2, NEF, ARW, DNG, PEF, SRW, ORF and RW2.
/// None of them record their own length, so the size is the furthest byte any directory points at.
struct TIFFRawCarver: FormatCarver {
    static let maxSize: UInt64 = 400 * 1024 * 1024

    var leadBytes: [UInt8]? { [0x49, 0x4D] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 16 else { return nil }
        let little = head[0] == 0x49
        guard little || head[0] == 0x4D, head[1] == head[0] else { return nil }
        let ifd = little ? head.u32le(4) : head.u32be(4)
        guard ifd >= 8, UInt64(ifd) < Self.maxSize else { return nil }
        if little {
            if head.starts(with: [0x49, 0x49, 0x2A, 0x00]) {
                // Canon writes "CR" and major version 2 straight after the header.
                return head[8] == 0x43 && head[9] == 0x52 && head[10] == 2 ? .cr2 : .tiff
            }
            if head.starts(with: "IIRO") || head.starts(with: "IIRS") { return .orf }
            if head.starts(with: [0x49, 0x49, 0x55, 0x00]) { return .rw2 }
            return nil
        }
        if head.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if head.starts(with: "MMOR") { return .orf }
        return nil
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        guard let layout = Self.layout(reader, at: start, sniffed: kind) else { return nil }
        return Carved(
            kind: layout.kind,
            size: layout.size,
            modified: layout.exif?.date,
            device: layout.exif?.device,
            complete: layout.complete
        )
    }

    struct Layout {
        var kind: FileKind
        var size: UInt64
        var complete: Bool
        var exif: EXIF.Summary?
        /// Places that may hold an embedded JPEG preview, relative to the file start. Unchecked.
        var previews: [ByteRange]
    }

    /// How far the bytes read up front reach. Camera raws keep all their directories near the start.
    static let headerSpan = 256 * 1024

    /// `measure` false skips finding where Panasonic sensor data ends, for callers that only want the previews.
    static func layout(_ reader: BlockReader, at start: UInt64, sniffed: FileKind? = nil, measure: Bool = true) -> Layout? {
        guard start < reader.size else { return nil }
        let limit = min(maxSize, reader.size - start)
        guard limit >= 16,
              let header = try? reader.read(at: start, count: Int(min(UInt64(headerSpan), limit))),
              header.count >= 16
        else { return nil }
        let head = Data(header)
        let sniffedKind: FileKind? = sniffed ?? head.withUnsafeBytes { TIFFRawCarver().sniff($0) }
        guard let sniffedKind else { return nil }
        let source = TIFFSource(reader: reader, start: start, limit: limit, header: head, little: head[0] == 0x49)
        guard let firstIFD = source.u32(head, 4) else { return nil }

        var walk = TIFFWalk(source: source)
        guard walk.run(firstIFD: UInt64(firstIFD)), !walk.truncated else { return nil }
        guard walk.sawImageData || walk.rawDataStart != nil else { return nil }

        var size = walk.maxEnd
        var complete = true
        if measure, let rawStart = walk.rawDataStart, walk.rawDataLength == nil {
            // Panasonic leaves the sensor data's length out; it simply runs to the end of the file.
            guard let end = Self.panasonicRawEnd(walk, rawStart: rawStart, source: source) else { return nil }
            size = max(size, end.offset)
            complete = end.certain
        }
        guard size > 8, size <= limit else { return nil }

        let kind = Self.kind(sniffed: sniffedKind, head: head, walk: walk)
        let exif = EXIF.summary(inTIFF: head)
        return Layout(kind: kind, size: size, complete: complete, exif: exif, previews: walk.previews)
    }

    private static func kind(sniffed: FileKind, head: Data, walk: TIFFWalk) -> FileKind {
        if sniffed == .orf || sniffed == .rw2 { return sniffed }
        if head.count > 10, head[8] == 0x43, head[9] == 0x52, head[10] == 2 { return .cr2 }
        if walk.isDNG { return .dng }
        // A TIFF exported from a camera photo keeps the camera's Make, so only call it raw when it holds sensor data.
        guard walk.hasSensorData, let make = walk.make?.uppercased() else { return .tiff }
        if make.hasPrefix("NIKON") { return .nef }
        if make.hasPrefix("SONY") { return .arw }
        if make.hasPrefix("PENTAX") || make.hasPrefix("RICOH") { return .pef }
        if make.hasPrefix("SAMSUNG") { return .srw }
        if make.hasPrefix("OLYMPUS") || make.hasPrefix("OM DIGITAL") { return .orf }
        if make.hasPrefix("PANASONIC") { return .rw2 }
        return .tiff
    }

    /// Where Panasonic sensor data ends. Known packings give a lower bound from the sensor size; the data then
    /// ends at the first sector that is blank or starts another file.
    private static func panasonicRawEnd(_ walk: TIFFWalk, rawStart: UInt64, source: TIFFSource) -> (offset: UInt64, certain: Bool)? {
        guard let width = walk.panasonic[0x0002], let height = walk.panasonic[0x0003],
              (1...100_000).contains(width), (1...100_000).contains(height)
        else { return nil }
        let pixels = width * height
        let bits = walk.panasonic[0x000A] ?? 12
        let format = walk.panasonic[0x002D] ?? 4
        // Pixels packed into each 16-byte block, per Panasonic's raw format versions.
        let perBlock: UInt64?
        switch format {
        case ...4: perBlock = 14
        case 5, 7: perBlock = bits == 14 ? 9 : 10
        case 6: perBlock = bits == 12 ? 14 : 11
        default: perBlock = nil
        }
        let lower = perBlock.map { (pixels + $0 - 1) / $0 * 16 } ?? pixels / 2
        let upper = pixels * 2 + 1024 * 1024
        let from = rawStart + lower
        guard from <= source.limit else { return nil }
        let ceiling = min(source.limit, rawStart + upper)
        if let boundary = Boundaries.nextFileOrBlank(source.reader, from: source.start + from, before: source.start + ceiling) {
            return (boundary - source.start, true)
        }
        // Nothing follows before the end of the disk (or of a file being previewed), so the data runs to it.
        if ceiling == source.limit { return (source.limit, true) }
        return perBlock == nil ? nil : (from, false)
    }
}

/// Bounds-checked reads relative to the start of a TIFF file, preferring the bytes already read.
struct TIFFSource {
    let reader: BlockReader
    let start: UInt64
    /// Bytes available from `start`, already capped.
    let limit: UInt64
    let header: Data
    let little: Bool

    func data(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0, offset <= limit, UInt64(count) <= limit - offset else { return nil }
        if offset + UInt64(count) <= UInt64(header.count) {
            return header.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        guard let chunk = try? reader.read(at: start + offset, count: count), chunk.count == count else { return nil }
        return chunk.startIndex == 0 ? chunk : Data(chunk)
    }

    func u16(_ data: Data, _ offset: Int) -> UInt16? {
        little ? Binary.u16le(data, offset) : Binary.u16be(data, offset)
    }

    func u32(_ data: Data, _ offset: Int) -> UInt32? {
        little ? Binary.u32le(data, offset) : Binary.u32be(data, offset)
    }

    /// Bytes per value for each TIFF field type, or nil for types that never appear in a well-formed directory.
    static func typeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7, 129: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return nil
        }
    }
}

/// Follows every directory a TIFF points at and records the furthest byte each one uses.
struct TIFFWalk {
    let source: TIFFSource
    private(set) var maxEnd: UInt64 = 8
    private(set) var sawImageData = false
    private(set) var hasSensorData = false
    private(set) var isDNG = false
    private(set) var make: String?
    private(set) var previews: [ByteRange] = []
    /// Panasonic IFD0 values: sensor size, bit depth, raw format.
    private(set) var panasonic: [UInt16: UInt64] = [:]
    private(set) var rawDataStart: UInt64?
    private(set) var rawDataLength: UInt64?
    /// Set when some image data lies past the end of the disk or the size limit.
    private(set) var truncated = false

    private static let maxDirectories = 64
    private static let maxValues = 1 << 20

    init(source: TIFFSource) {
        self.source = source
    }

    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: UInt32
        /// Where the four value bytes sit in the directory data.
        var field: Int
    }

    /// False when the first directory is not sound. Later directories that don't parse are skipped.
    mutating func run(firstIFD: UInt64) -> Bool {
        var queue: [UInt64] = [firstIFD]
        var visited = Set<UInt64>()
        var isFirst = true
        while let offset = queue.first, visited.count < Self.maxDirectories {
            queue.removeFirst()
            guard !visited.contains(offset) else { continue }
            visited.insert(offset)
            let parsed = directory(at: offset, first: isFirst)
            if isFirst && parsed == nil { return false }
            isFirst = false
            if let parsed { queue.append(contentsOf: parsed) }
        }
        return true
    }

    /// Parses one directory and returns the directories it points to, or nil when it isn't a real one.
    private mutating func directory(at offset: UInt64, first: Bool) -> [UInt64]? {
        guard offset >= 8, let countData = source.data(at: offset, count: 2), let count = source.u16(countData, 0),
              count >= (first ? 3 : 1), count <= 1000
        else { return nil }
        let length = Int(count) * 12 + 4
        guard let table = source.data(at: offset + 2, count: length) else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let base = index * 12
            guard let tag = source.u16(table, base), let type = source.u16(table, base + 2),
                  let valueCount = source.u32(table, base + 4), let value = source.u32(table, base + 8)
            else { return nil }
            // Random bytes almost never form valid field types, so one bad entry means this is no directory.
            guard TIFFSource.typeSize(type) != nil else { return nil }
            entries.append(Entry(tag: tag, type: type, count: valueCount, value: value, field: base + 8))
        }
        var ends = [offset + 2 + UInt64(length)]
        for entry in entries {
            guard let size = TIFFSource.typeSize(entry.type) else { continue }
            let bytes = UInt64(size) * UInt64(entry.count)
            if bytes > 4 {
                let end = UInt64(entry.value) + bytes
                if end > source.limit {
                    // The first directory must be whole; vendor blocks elsewhere sometimes hold junk.
                    if first { return nil }
                    continue
                }
                ends.append(end)
            }
        }

        func values(_ tag: UInt16) -> [UInt64]? {
            guard let entry = entries.first(where: { $0.tag == tag }) else { return nil }
            return self.values(entry, table: table)
        }

        var next: [UInt64] = []
        if let link = source.u32(table, Int(count) * 12), link > 0 { next.append(UInt64(link)) }
        for tag: UInt16 in [0x014A, 0x8769, 0x8825, 0xA005] {
            if let pointers = values(tag) { next.append(contentsOf: pointers.filter { $0 >= 8 }) }
        }

        let compression = values(0x0103)?.first
        let photometric = values(0x0106)?.first
        // Colour filter array or linear raw: this directory holds sensor data.
        if let photometric, photometric == 32803 || photometric == 34892 { hasSensorData = true }
        if let compression, [34713, 32767, 32769, 32770, 32772, 65535, 34316].contains(compression) { hasSensorData = true }
        if entries.contains(where: { $0.tag == 0xC612 }) { isDNG = true }
        if first, make == nil, let entry = entries.first(where: { $0.tag == 0x010F }) {
            make = string(entry, table: table)
        }

        let panasonicRoot = first && source.header.starts(with: [0x49, 0x49, 0x55, 0x00])
        for (offsetsTag, countsTag) in [(UInt16(0x0111), UInt16(0x0117)), (0x0144, 0x0145)] {
            // Panasonic's sensor data is measured separately because its length is often left out.
            if panasonicRoot && offsetsTag == 0x0111 { continue }
            guard let starts = values(offsetsTag) else { continue }
            let lengths = values(countsTag) ?? []
            guard starts.count == lengths.count else {
                if first { return nil }
                continue
            }
            for (stripStart, stripLength) in zip(starts, lengths) where stripLength > 0 {
                // Image data past the end of the disk or the size limit means the file is cut short.
                guard stripStart >= 8, stripStart + stripLength <= source.limit else {
                    truncated = true
                    return nil
                }
                ends.append(stripStart + stripLength)
                sawImageData = true
            }
            // A single JPEG-compressed strip that isn't sensor data is a preview, unless its tables are kept
            // apart (JPEGTables), which leaves a stream ImageIO can't read on its own. 0xC640 marks Canon's sensor slices.
            let standalone = !entries.contains { $0.tag == 0xC640 || $0.tag == 0x015B }
            if starts.count == 1, let length = lengths.first, length > 0, compression == 6 || compression == 7,
               photometric != 32803, photometric != 34892, standalone {
                previews.append(ByteRange(offset: starts[0], length: length))
            }
        }
        if let jpegStart = values(0x0201)?.first, let jpegLength = values(0x0202)?.first, jpegStart >= 8, jpegLength > 0 {
            guard jpegStart + jpegLength <= source.limit else {
                truncated = true
                return nil
            }
            ends.append(jpegStart + jpegLength)
            previews.append(ByteRange(offset: jpegStart, length: jpegLength))
            sawImageData = true
        }

        if panasonicRoot {
            panasonicFields(entries, table: table)
        }
        maxEnd = max(maxEnd, ends.max() ?? 0)
        return next
    }

    private mutating func panasonicFields(_ entries: [Entry], table: Data) {
        for entry in entries {
            switch entry.tag {
            case 0x0002, 0x0003, 0x000A, 0x002D:
                if let value = values(entry, table: table)?.first { panasonic[entry.tag] = value }
            case 0x002E where entry.count > 0:
                // The large preview, stored as an opaque block.
                previews.append(ByteRange(offset: UInt64(entry.value), length: UInt64(entry.count)))
            default:
                break
            }
        }
        let stripStart = entries.first { $0.tag == 0x0111 }.flatMap { values($0, table: table)?.first }
        let explicitStart = entries.first { $0.tag == 0x0118 }.flatMap { values($0, table: table)?.first }
        guard let rawStart = explicitStart ?? stripStart, rawStart >= 8, rawStart < source.limit else { return }
        let length = entries.first { $0.tag == 0x0117 }.flatMap { values($0, table: table)?.first } ?? 0
        if length > 0 {
            if rawStart + length <= source.limit {
                rawDataStart = rawStart
                rawDataLength = length
                maxEnd = max(maxEnd, rawStart + length)
                sawImageData = true
            }
        } else {
            rawDataStart = rawStart
            maxEnd = max(maxEnd, rawStart)
        }
    }

    /// Unsigned integer values of a SHORT, LONG or IFD field.
    private func values(_ entry: Entry, table: Data) -> [UInt64]? {
        let size: Int
        switch entry.type {
        case 3: size = 2
        case 4, 13: size = 4
        default: return nil
        }
        let count = Int(entry.count)
        guard count > 0, count <= Self.maxValues else { return nil }
        let total = size * count
        let data: Data
        let base: Int
        if total <= 4 {
            data = table
            base = entry.field
        } else {
            guard let loaded = source.data(at: UInt64(entry.value), count: total) else { return nil }
            data = loaded
            base = 0
        }
        var out: [UInt64] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            if size == 2 {
                guard let value = source.u16(data, base + index * 2) else { return nil }
                out.append(UInt64(value))
            } else {
                guard let value = source.u32(data, base + index * 4) else { return nil }
                out.append(UInt64(value))
            }
        }
        return out
    }

    private func string(_ entry: Entry, table: Data) -> String? {
        guard entry.type == 2, entry.count > 0, entry.count < 256 else { return nil }
        let length = Int(entry.count)
        let bytes: Data
        if length <= 4 {
            bytes = table.subdata(in: entry.field..<(entry.field + length))
        } else {
            guard let loaded = source.data(at: UInt64(entry.value), count: length) else { return nil }
            bytes = loaded
        }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
