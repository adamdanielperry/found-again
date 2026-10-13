import Foundation

/// Every format the deep scan can recognize. Order matters only for speed.
enum Registry {
    static let all: [FormatCarver] = [
        JPEGCarver(),
        RAFCarver(),
        ISOMediaCarver(),
        TIFFRawCarver(),
        PNGCarver(),
        GIFCarver(),
        RIFFCarver(),
        PDFCarver(),
        ZIPCarver(),
        OLE2Carver(),
        MP3Carver(),
        FLACCarver(),
        MatroskaCarver(),
        PSDCarver(),
        BMPCarver(),
    ]

    /// Carvers that can start with each possible first byte, so most sectors are rejected with one lookup.
    static let byLeadByte: [[FormatCarver]] = {
        var table = Array(repeating: [FormatCarver](), count: 256)
        for carver in all {
            if let lead = carver.leadBytes {
                for byte in lead { table[Int(byte)].append(carver) }
            } else {
                for index in 0..<256 { table[index].append(carver) }
            }
        }
        return table
    }()
}

extension FormatCarver {
    /// First bytes this format can start with. Nil means any.
    var leadBytes: [UInt8]? { nil }
}

/// Searches raw bytes for files by their contents. Files always start on a sector boundary, so only those are checked.
/// That keeps the search fast and still finds files after the card was reformatted with a different layout.
enum Carver {
    static let sector: UInt64 = 512
    private static let chunkSize = 8 * 1024 * 1024

    struct Outcome {
        var unreadableBytes: UInt64 = 0
    }

    static func carve(
        reader: BlockReader,
        covered: RangeCover,
        options: ScanOptions,
        foundSoFar: Int,
        sink: inout [RecoverableFile]
    ) throws -> Outcome {
        var outcome = Outcome()
        let total = reader.size
        var cursor: UInt64 = 0
        var sequence = SequenceCounter()
        var pending: [RecoverableFile] = []
        var lastReport = Date.distantPast
        var coverIndex = 0

        func report(force: Bool = false) {
            let now = Date()
            if !force && now.timeIntervalSince(lastReport) < 0.25 { return }
            lastReport = now
            if !pending.isEmpty {
                options.onFound?(pending)
                pending.removeAll(keepingCapacity: true)
            }
            options.progress?(ScanProgress(phase: .contents, bytesDone: min(cursor, total), bytesTotal: total, found: foundSoFar + sink.count))
        }

        while cursor < total {
            if options.cancelled { break }
            report()
            let count = Int(min(UInt64(chunkSize), total - cursor))
            let (data, unreadable) = try reader.readTolerant(at: cursor, count: count)
            outcome.unreadableBytes += UInt64(unreadable)
            if data.isEmpty { break }

            var jumpTo: UInt64?
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var local = 0
                let headLength = Signatures.headLength
                while local + 16 <= raw.count {
                    let absolute = cursor + UInt64(local)
                    if let end = covered.coveredEnd(at: absolute, hint: &coverIndex) {
                        let next = align(end)
                        if next >= cursor + UInt64(raw.count) {
                            jumpTo = next
                            return
                        }
                        local = Int(next - cursor)
                        continue
                    }
                    let candidates = Registry.byLeadByte[Int(raw[local])]
                    if !candidates.isEmpty {
                        let head = UnsafeRawBufferPointer(rebasing: raw[local..<min(local + headLength, raw.count)])
                        for candidate in candidates {
                            guard let kind = candidate.sniff(head) else { continue }
                            // Unwanted kinds are still measured so the scan can step over them.
                            guard let found = try candidate.carve(reader, at: absolute, kind: kind) else { continue }
                            let file = make(found, at: absolute, sequence: &sequence)
                            if options.wants(file.category) {
                                sink.append(file)
                                pending.append(file)
                            }
                            let next = align(absolute + found.size)
                            if next >= cursor + UInt64(raw.count) {
                                jumpTo = next
                                return
                            }
                            local = Int(next - cursor) - Int(sector)
                            break
                        }
                    }
                    local += Int(sector)
                }
            }
            if let jumpTo {
                cursor = jumpTo
            } else {
                cursor += UInt64(data.count)
            }
            if sink.count >= 200_000 { break }
        }
        cursor = min(cursor, total)
        report(force: true)
        return outcome
    }

    private static func align(_ offset: UInt64) -> UInt64 {
        (offset + sector - 1) / sector * sector
    }

    /// Numbers carved files per category, so names read "Photo 0001.jpg", "Video 0001.mov".
    struct SequenceCounter {
        private var counts: [FileCategory: Int] = [:]

        mutating func next(_ category: FileCategory) -> Int {
            let value = (counts[category] ?? 0) + 1
            counts[category] = value
            return value
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func make(_ found: Carved, at offset: UInt64, sequence: inout SequenceCounter) -> RecoverableFile {
        let category = found.kind.category
        let ext = found.kind.fileExtension
        let name: String
        if let hint = found.nameHint {
            name = hint
        } else if let modified = found.modified {
            name = "\(dateFormatter.string(from: modified)).\(ext)"
        } else {
            name = String(format: "%@ %04d.%@", baseName(category), sequence.next(category), ext)
        }
        return RecoverableFile(
            id: "carve-\(offset)",
            name: name,
            originalPath: name,
            size: found.size,
            modified: found.modified,
            kind: found.kind,
            confidence: .carved,
            headerLooksValid: true,
            complete: found.complete,
            device: found.device,
            ranges: [ByteRange(offset: offset, length: found.size)]
        )
    }

    private static func baseName(_ category: FileCategory) -> String {
        switch category {
        case .photo: return "Photo"
        case .raw: return "Raw Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .archive: return "Archive"
        case .other: return "File"
        }
    }
}

/// Byte ranges that already belong to a known file, live or recovered. The deep scan skips them.
struct RangeCover {
    private(set) var ranges: [ByteRange]

    init(_ files: [RecoverableFile], extra: [ByteRange] = []) {
        let sorted = (files.flatMap(\.ranges) + extra).filter { $0.length > 0 }.sorted { $0.offset < $1.offset }
        var merged: [ByteRange] = []
        for range in sorted {
            if var last = merged.last, last.end >= range.offset {
                last.length = max(last.end, range.end) - last.offset
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    func contains(_ offset: UInt64) -> Bool {
        var hint = 0
        return coveredEnd(at: offset, hint: &hint) != nil
    }

    /// The end of the range covering `offset`, or nil. `hint` speeds up calls with rising offsets.
    func coveredEnd(at offset: UInt64, hint: inout Int) -> UInt64? {
        if ranges.isEmpty { return nil }
        if hint >= ranges.count || (hint > 0 && ranges[hint - 1].end > offset) {
            hint = firstIndex(endingAfter: offset)
        }
        while hint < ranges.count && ranges[hint].end <= offset {
            hint += 1
        }
        guard hint < ranges.count else { return nil }
        let range = ranges[hint]
        return offset >= range.offset ? range.end : nil
    }

    private func firstIndex(endingAfter offset: UInt64) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].end <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

/// Reads forward through a file in large windows so parsers can look at single bytes cheaply.
final class ByteWindow {
    let reader: BlockReader
    let end: UInt64
    private var window = Data()
    private var windowStart: UInt64 = 0
    private let windowSize: Int

    init(reader: BlockReader, end: UInt64, windowSize: Int = 1024 * 1024) {
        self.reader = reader
        self.end = min(end, reader.size)
        self.windowSize = windowSize
    }

    private func load(_ offset: UInt64) -> Bool {
        if offset >= windowStart && offset < windowStart + UInt64(window.count) { return true }
        guard offset < end else { return false }
        let fill = Int(min(UInt64(windowSize), end - offset))
        guard let chunk = try? reader.read(at: offset, count: fill), !chunk.isEmpty else { return false }
        window = chunk
        windowStart = offset
        return true
    }

    func byte(at offset: UInt64) -> UInt8? {
        guard load(offset) else { return nil }
        return window[window.startIndex + Int(offset - windowStart)]
    }

    func bytes(at offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        guard offset + UInt64(count) <= end else { return nil }
        if load(offset), offset + UInt64(count) <= windowStart + UInt64(window.count) {
            let local = Int(offset - windowStart)
            return window.subdata(in: (window.startIndex + local)..<(window.startIndex + local + count))
        }
        return try? reader.read(at: offset, count: count)
    }

    func u16be(at offset: UInt64) -> UInt16? {
        guard let a = byte(at: offset), let b = byte(at: offset + 1) else { return nil }
        return (UInt16(a) << 8) | UInt16(b)
    }

    /// Position of the next 0xFF at or after `offset`, or nil at the end.
    func nextFF(from offset: UInt64) -> UInt64? {
        var position = offset
        while position < end {
            guard load(position) else { return nil }
            let local = Int(position - windowStart)
            let found: Int? = window.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                let start = base.advanced(by: local)
                guard let hit = memchr(start, 0xFF, raw.count - local) else { return nil }
                return local + (UnsafeRawPointer(hit) - UnsafeRawPointer(start))
            }
            if let found {
                return windowStart + UInt64(found)
            }
            position = windowStart + UInt64(window.count)
        }
        return nil
    }

    /// Makes `count` bytes from `offset` sit inside one window, reading a fresh window from `offset` when they straddle its end.
    private func ensure(_ offset: UInt64, count: Int) -> Bool {
        let needEnd = offset + UInt64(count)
        if offset >= windowStart && needEnd <= windowStart + UInt64(window.count) { return true }
        guard count > 0, needEnd <= end else { return false }
        let fill = Int(min(UInt64(max(windowSize, count)), end - offset))
        guard let chunk = try? reader.read(at: offset, count: fill), chunk.count >= count else { return false }
        window = chunk
        windowStart = offset
        return true
    }

    /// Lends `count` bytes at `offset` without copying them. Nil past the end.
    func withBytes<T>(at offset: UInt64, count: Int, _ body: (UnsafeRawBufferPointer) -> T) -> T? {
        guard ensure(offset, count: count) else { return nil }
        let local = Int(offset - windowStart)
        return window.withUnsafeBytes { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[local..<(local + count)]))
        }
    }

    func u32be(at offset: UInt64) -> UInt32? {
        withBytes(at: offset, count: 4) { $0.u32be(0) }
    }

    func u16le(at offset: UInt64) -> UInt16? {
        withBytes(at: offset, count: 2) { $0.u16le(0) }
    }

    func u32le(at offset: UInt64) -> UInt32? {
        withBytes(at: offset, count: 4) { $0.u32le(0) }
    }

    func u64le(at offset: UInt64) -> UInt64? {
        withBytes(at: offset, count: 8) { UInt64($0.u32le(0)) | (UInt64($0.u32le(4)) << 32) }
    }

    func u64be(at offset: UInt64) -> UInt64? {
        withBytes(at: offset, count: 8) { (UInt64($0.u32be(0)) << 32) | UInt64($0.u32be(4)) }
    }

    /// Position of the first `pattern` at or after `offset` that ends by `limit`, or nil.
    func find(_ pattern: [UInt8], from offset: UInt64, before limit: UInt64? = nil) -> UInt64? {
        findFirst(of: [pattern], from: offset, before: limit)?.offset
    }

    /// The earliest match of any of `patterns`, with which one matched. Uses memmem over whole windows,
    /// so searching hundreds of megabytes costs about as much as reading them.
    func findFirst(of patterns: [[UInt8]], from offset: UInt64, before limit: UInt64? = nil) -> (index: Int, offset: UInt64)? {
        let stop = min(limit ?? end, end)
        let longest = patterns.map(\.count).max() ?? 0
        let shortest = patterns.map(\.count).min() ?? 0
        guard shortest > 0 else { return nil }
        var position = offset
        while position + UInt64(shortest) <= stop {
            guard ensure(position, count: Int(min(UInt64(longest), stop - position))) else { return nil }
            let local = Int(position - windowStart)
            let available = Int(min(UInt64(window.count - local), stop - position))
            var best: (index: Int, offset: Int)?
            window.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.advanced(by: local) else { return }
                for (index, pattern) in patterns.enumerated() where pattern.count <= available {
                    // Only an earlier match than the best so far matters.
                    let span = min(available, best.map { $0.offset + pattern.count } ?? available)
                    let hit: Int? = pattern.withUnsafeBytes { needle in
                        guard let needleBase = needle.baseAddress,
                              let found = memmem(base, span, needleBase, pattern.count)
                        else { return nil }
                        return UnsafeRawPointer(found) - base
                    }
                    if let hit, hit < (best?.offset ?? Int.max) {
                        best = (index, hit)
                    }
                }
            }
            if let best { return (best.index, position + UInt64(best.offset)) }
            // Step back by one pattern length so a match straddling the window's end is still seen.
            if position + UInt64(available) >= stop { return nil }
            position += UInt64(max(1, available - longest + 1))
        }
        return nil
    }
}
