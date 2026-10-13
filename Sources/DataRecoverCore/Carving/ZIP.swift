import Foundation

/// ZIP and the formats built on it: Office documents, EPUB and iWork.
/// The walk follows each entry's local header to the central directory and its end record, which must agree.
struct ZIPCarver: FormatCarver {
    static let maxSize: UInt64 = 2 * 1024 * 1024 * 1024

    private static let localSignature: UInt32 = 0x0403_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let descriptorSignature: UInt32 = 0x0807_4B50
    private static let extraDataSignature: UInt32 = 0x0806_4B50
    /// Stored, shrunk, imploded, deflate, deflate64, bzip2, LZMA, zstd, xz, PPMd and AES.
    private static let methods: Set<UInt16> = [0, 1, 6, 8, 9, 12, 14, 93, 95, 98, 99]

    var leadBytes: [UInt8]? { [0x50] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 30, head.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return nil }
        guard head[4] <= 63, Self.methods.contains(head.u16le(8)) else { return nil }
        let nameLength = head.u16le(26)
        guard nameLength > 0, nameLength <= 4096 else { return nil }
        return .zip
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let bytes = ByteWindow(reader: reader, end: min(reader.size, start + Self.maxSize), windowSize: 256 * 1024)
        var names = NameClues()
        guard let local = Self.walkLocalEntries(bytes, from: start, clues: &names) else { return nil }
        let carved: (end: UInt64, clues: NameClues)?
        if let cdStart = local.centralDirectory {
            carved = Self.finish(bytes, start: start, cdStart: cdStart, expectedEntries: local.entries, clues: names)
        } else {
            carved = Self.searchForEnd(bytes, start: start, from: local.reached, clues: names)
        }
        guard let carved else { return nil }
        return Carved(kind: carved.clues.kind, size: carved.end - start)
    }

    // MARK: Local entries

    private struct LocalWalk {
        var entries: Int
        /// Where the central directory starts, or nil when the walk hit something it didn't understand.
        var centralDirectory: UInt64?
        /// How far the walk got.
        var reached: UInt64
    }

    private static func walkLocalEntries(_ bytes: ByteWindow, from start: UInt64, clues: inout NameClues) -> LocalWalk? {
        var position = start
        var entries = 0
        while entries < 1_000_000 {
            guard let signature = bytes.u32le(at: position) else {
                return entries == 0 ? nil : LocalWalk(entries: entries, centralDirectory: nil, reached: position)
            }
            if signature == centralSignature {
                return LocalWalk(entries: entries, centralDirectory: position, reached: position)
            }
            if signature == extraDataSignature, let length = bytes.u32le(at: position + 4) {
                position += 8 + UInt64(length)
                continue
            }
            guard signature == localSignature,
                  let header = bytes.bytes(at: position, count: 30), header.count == 30,
                  let flags = Binary.u16le(header, 6), let method = Binary.u16le(header, 8),
                  let compressed32 = Binary.u32le(header, 18), let uncompressed32 = Binary.u32le(header, 22),
                  let nameLength = Binary.u16le(header, 26), let extraLength = Binary.u16le(header, 28),
                  methods.contains(method), nameLength > 0
            else {
                // Something sits between the entries and the central directory, such as an APK signing block.
                return entries == 0 ? nil : LocalWalk(entries: entries, centralDirectory: nil, reached: position)
            }
            let nameStart = position + 30
            let dataStart = nameStart + UInt64(nameLength) + UInt64(extraLength)
            if entries == 0, let name = bytes.bytes(at: nameStart, count: Int(nameLength)) {
                clues.firstName = String(decoding: name, as: UTF8.self)
                if clues.firstName == "mimetype", method == 0, let content = bytes.bytes(at: dataStart, count: Int(min(compressed32, 64))) {
                    clues.mimetype = String(decoding: content, as: UTF8.self)
                }
            }
            var compressed = UInt64(compressed32)
            var zip64 = false
            if compressed32 == 0xFFFF_FFFF || uncompressed32 == 0xFFFF_FFFF {
                guard let extra = bytes.bytes(at: nameStart + UInt64(nameLength), count: Int(extraLength)),
                      let wide = zip64Sizes(extra, uncompressedWide: uncompressed32 == 0xFFFF_FFFF, compressedWide: compressed32 == 0xFFFF_FFFF)
                else { return nil }
                if let wideCompressed = wide.compressed {
                    guard wideCompressed <= maxSize else { return nil }
                    compressed = wideCompressed
                }
                zip64 = true
            }
            let next: UInt64?
            if flags & 0x08 != 0 {
                // Streamed entry: sizes come in a descriptor after the data.
                if compressed > 0, let end = descriptorEnd(bytes, dataStart: dataStart, dataEnd: dataStart + compressed, zip64: zip64) {
                    next = end
                } else {
                    next = searchDescriptor(bytes, dataStart: dataStart)
                }
            } else {
                next = dataStart + compressed
            }
            guard let next, next <= bytes.end else {
                return entries == 0 ? nil : LocalWalk(entries: entries, centralDirectory: nil, reached: position)
            }
            entries += 1
            position = next
        }
        return nil
    }

    /// Reads the ZIP64 extra field, which holds the real sizes when the header says 0xFFFFFFFF.
    private static func zip64Sizes(_ extra: Data, uncompressedWide: Bool, compressedWide: Bool) -> (uncompressed: UInt64?, compressed: UInt64?)? {
        var offset = 0
        while offset + 4 <= extra.count {
            guard let id = Binary.u16le(extra, offset), let length = Binary.u16le(extra, offset + 2) else { return nil }
            if id == 0x0001 {
                var field = offset + 4
                var uncompressed: UInt64?
                var compressed: UInt64?
                if uncompressedWide {
                    uncompressed = Binary.u64le(extra, field)
                    field += 8
                }
                if compressedWide {
                    compressed = Binary.u64le(extra, field)
                    guard compressed != nil else { return nil }
                }
                return (uncompressed, compressed)
            }
            offset += 4 + Int(length)
        }
        return nil
    }

    /// The end of a data descriptor that sits exactly at `dataEnd`, when one does and the next record follows it.
    private static func descriptorEnd(_ bytes: ByteWindow, dataStart: UInt64, dataEnd: UInt64, zip64: Bool) -> UInt64? {
        let signed = bytes.u32le(at: dataEnd) == descriptorSignature
        let lengths: [UInt64] = zip64 ? [20, 12] : [12, 20]
        for length in lengths {
            let end = dataEnd + length + (signed ? 4 : 0)
            if let next = bytes.u32le(at: end), next == localSignature || next == centralSignature {
                return end
            }
        }
        return nil
    }

    /// Finds the data descriptor of a streamed entry by looking for the next record and checking that the
    /// compressed size just before it matches the distance from the data start.
    private static func searchDescriptor(_ bytes: ByteWindow, dataStart: UInt64) -> UInt64? {
        let patterns: [[UInt8]] = [[0x50, 0x4B, 0x07, 0x08], [0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x01, 0x02]]
        var position = dataStart
        while let hit = bytes.findFirst(of: patterns, from: position) {
            let at = hit.offset
            if hit.index == 0 {
                if let size = bytes.u32le(at: at + 8), UInt64(size) == at - dataStart,
                   let next = bytes.u32le(at: at + 16), next == localSignature || next == centralSignature {
                    return at + 16
                }
                if let size = bytes.u64le(at: at + 8), size == at - dataStart,
                   let next = bytes.u32le(at: at + 24), next == localSignature || next == centralSignature {
                    return at + 24
                }
            } else {
                if at >= dataStart + 12, let size = bytes.u32le(at: at - 8), UInt64(size) == at - 12 - dataStart {
                    return at
                }
                if at >= dataStart + 20, let size = bytes.u64le(at: at - 16), size == at - 20 - dataStart {
                    return at
                }
                // Another archive starting on a sector boundary: this entry was cut short, so stop looking.
                if hit.index == 1, at % Carver.sector == 0 { return nil }
            }
            position = at + 1
        }
        return nil
    }

    // MARK: Central directory and end record

    /// Walks the central directory from `cdStart` and checks the end record after it agrees.
    private static func finish(_ bytes: ByteWindow, start: UInt64, cdStart: UInt64, expectedEntries: Int?, clues initial: NameClues) -> (end: UInt64, clues: NameClues)? {
        var clues = initial
        var position = cdStart
        var entries = 0
        while bytes.u32le(at: position) == centralSignature {
            guard entries < 1_000_000, let header = bytes.bytes(at: position, count: 46), header.count == 46,
                  let nameLength = Binary.u16le(header, 28), let extraLength = Binary.u16le(header, 30),
                  let commentLength = Binary.u16le(header, 32), nameLength > 0
            else { return nil }
            if let name = bytes.bytes(at: position + 46, count: Int(nameLength)) {
                clues.add(String(decoding: name, as: UTF8.self))
            }
            position += 46 + UInt64(nameLength) + UInt64(extraLength) + UInt64(commentLength)
            entries += 1
        }
        let cdEnd = position
        guard entries > 0 else { return nil }
        if let expectedEntries, expectedEntries != entries { return nil }

        var zip64 = false
        if bytes.u32le(at: position) == zip64EndSignature {
            guard let recordSize = bytes.u64le(at: position + 4), recordSize >= 44, recordSize < 1024 * 1024,
                  let wideCount = bytes.u64le(at: position + 32), wideCount == UInt64(entries),
                  let wideSize = bytes.u64le(at: position + 40), wideSize == cdEnd - cdStart,
                  let wideOffset = bytes.u64le(at: position + 48), wideOffset == cdStart - start
            else { return nil }
            position += 12 + recordSize
            guard bytes.u32le(at: position) == zip64LocatorSignature else { return nil }
            position += 20
            zip64 = true
        }
        guard bytes.u32le(at: position) == endSignature,
              let record = bytes.bytes(at: position, count: 22), record.count == 22,
              let disk = Binary.u16le(record, 4), let cdDisk = Binary.u16le(record, 6),
              let count = Binary.u16le(record, 10), let cdSize = Binary.u32le(record, 12),
              let cdOffset = Binary.u32le(record, 16), let commentLength = Binary.u16le(record, 20)
        else { return nil }
        // Archives split over several disks can't be put back together from one.
        guard zip64 || (disk == 0 && cdDisk == 0) else { return nil }
        guard (zip64 && count == 0xFFFF) || Int(count) == entries & 0xFFFF else { return nil }
        guard (zip64 && cdSize == 0xFFFF_FFFF) || UInt64(cdSize) == cdEnd - cdStart else { return nil }
        guard (zip64 && cdOffset == 0xFFFF_FFFF) || UInt64(cdOffset) == cdStart - start else { return nil }
        let end = position + 22 + UInt64(commentLength)
        guard end <= bytes.end else { return nil }
        return (end, clues)
    }

    /// When the entries can't be walked, finds the end record by searching and checks it points back here.
    private static func searchForEnd(_ bytes: ByteWindow, start: UInt64, from: UInt64, clues: NameClues) -> (end: UInt64, clues: NameClues)? {
        let pattern: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var position = from
        while let at = bytes.find(pattern, from: position) {
            position = at + 1
            if at >= start + 20, bytes.u32le(at: at - 20) == zip64LocatorSignature {
                // ZIP64: the locator says where the wide end record is, relative to this archive's start.
                if let relative = bytes.u64le(at: at - 12), relative < maxSize, start + relative < at,
                   bytes.u32le(at: start + relative) == zip64EndSignature,
                   let cdOffset = bytes.u64le(at: start + relative + 48), cdOffset < relative,
                   let found = finish(bytes, start: start, cdStart: start + cdOffset, expectedEntries: nil, clues: clues) {
                    return found
                }
                continue
            }
            guard let cdSize = bytes.u32le(at: at + 12), let cdOffset = bytes.u32le(at: at + 16) else { return nil }
            let span = UInt64(cdSize) + UInt64(cdOffset)
            if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF || span > at {
                continue
            }
            let owner = at - span
            if owner == start {
                return finish(bytes, start: start, cdStart: start + UInt64(cdOffset), expectedEntries: nil, clues: clues)
            }
            // A complete archive that starts after this one: this one ended before it.
            if owner > start { return nil }
        }
        return nil
    }

    /// What the entry names say about the document type.
    struct NameClues {
        var firstName: String?
        var mimetype: String?
        var word = false
        var excel = false
        var powerPoint = false
        var iWork = false
        var keynote = false
        var numbers = false

        mutating func add(_ name: String) {
            if name.hasPrefix("word/") { word = true }
            if name.hasPrefix("xl/") { excel = true }
            if name.hasPrefix("ppt/") { powerPoint = true }
            if name == "Index/Document.iwa" { iWork = true }
            if name.hasPrefix("Index/Slide") { keynote = true }
            if name == "Index/CalculationEngine.iwa" || name.hasPrefix("Index/Tables/") { numbers = true }
        }

        var kind: FileKind {
            if firstName == "mimetype", mimetype?.hasPrefix("application/epub+zip") == true { return .epub }
            if iWork {
                if keynote { return .keynote }
                if numbers { return .numbers }
                return .pages
            }
            if word { return .docx }
            if excel { return .xlsx }
            if powerPoint { return .pptx }
            return .zip
        }
    }
}
