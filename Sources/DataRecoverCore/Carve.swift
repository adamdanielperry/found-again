import Foundation

struct CarveRegion {
    var start: UInt64
    var end: UInt64
    var origin: UInt64
    var stride: UInt64
}

enum Carver {
    private static let maxJPEG: UInt64 = 80 * 1024 * 1024
    private static let maxRAF: UInt64 = 512 * 1024 * 1024
    private static let maxMovie: UInt64 = 100 * 1024 * 1024 * 1024
    private static let chunkSize = 8 * 1024 * 1024

    static func carve(
        reader: BlockReader,
        regions: [CarveRegion],
        covered: RangeCover,
        options: ScanOptions,
        sink: inout [RecoverableFile]
    ) throws {
        let scopes = regions.isEmpty
            ? [CarveRegion(start: 0, end: reader.size, origin: 0, stride: 1)]
            : regions
        let total = scopes.reduce(UInt64(0)) { $0 + ($1.end > $1.start ? $1.end - $1.start : 0) }
        var finished: UInt64 = 0
        var sequence = sink.count
        for region in scopes {
            if options.isCancelled?() == true { return }
            try carve(
                reader: reader,
                region: region,
                covered: covered,
                options: options,
                sink: &sink,
                sequence: &sequence,
                finished: &finished,
                total: max(total, 1)
            )
        }
    }

    private static func carve(
        reader: BlockReader,
        region: CarveRegion,
        covered: RangeCover,
        options: ScanOptions,
        sink: inout [RecoverableFile],
        sequence: inout Int,
        finished: inout UInt64,
        total: UInt64
    ) throws {
        if region.end <= region.start { return }
        var cursor = region.start
        while cursor < region.end {
            if options.isCancelled?() == true { return }
            let fraction = Double(finished + (cursor - region.start)) / Double(total)
            options.progress?(0.05 + fraction * 0.9, "Searching the card for photos, \(ByteText.string(finished + (cursor - region.start))) of \(ByteText.string(total)). Found \(sink.count).")
            let count = Int(min(UInt64(chunkSize), region.end - cursor))
            let data = try reader.read(at: cursor, count: count)
            if data.isEmpty { return }
            var local = 0
            if region.stride > 1 {
                let origin = region.origin
                if cursor > origin {
                    let mod = (cursor - origin) % region.stride
                    if mod != 0 { local = Int(region.stride - mod) }
                }
            }
            var jumped: UInt64?
            if region.stride > 1 {
                let step = Int(region.stride)
                while local + 16 <= data.count {
                    let absolute = cursor + UInt64(local)
                    let head = data.subdata(in: local..<min(local + 16, data.count))
                    let interesting = head.starts(with: [0xFF, 0xD8, 0xFF])
                        || head.starts(with: Data("FUJIFILMCCD-RAW ".utf8))
                        || (head.count >= 8 && head.subdata(in: 4..<8) == Data("ftyp".utf8))
                    if interesting, !covered.contains(absolute), let carved = try extract(reader: reader, at: absolute, sequence: &sequence, sample: data, sampleOffset: local) {
                        sink.append(carved.file)
                        options.onUpdate?(sink)
                        if Self.foundEverything(sink, named: options.stopWhenFound) { return }
                        let next = absolute + carved.size
                        if next > cursor + UInt64(data.count) {
                            jumped = next
                            break
                        }
                        var advance = Int(next - cursor)
                        let mod = (next - region.origin) % region.stride
                        if mod != 0 { advance += Int(region.stride - mod) }
                        local = max(local + 1, advance)
                    } else {
                        local += step
                    }
                    if sink.count >= 50_000 { return }
                }
            } else {
                while local + 16 < data.count {
                    guard let found = findSignature(data, from: local) else { break }
                    let absolute = cursor + UInt64(found)
                    if covered.contains(absolute) {
                        local = found + 1
                        continue
                    }
                    if let carved = try extract(reader: reader, at: absolute, sequence: &sequence, sample: data, sampleOffset: found) {
                        sink.append(carved.file)
                        options.onUpdate?(sink)
                        if Self.foundEverything(sink, named: options.stopWhenFound) { return }
                        let next = absolute + carved.size
                        if next <= cursor { break }
                        if next > cursor + UInt64(data.count) {
                            jumped = next
                            break
                        }
                        local = Int(next - cursor)
                    } else {
                        local = found + 1
                    }
                    if sink.count >= 50_000 { return }
                }
            }
            if let jumped {
                cursor = jumped
            } else if data.count < count {
                finished += region.end - region.start
                return
            } else {
                let advance = UInt64(max(data.count - 32, 1))
                cursor += region.stride > 1 ? UInt64(data.count) : advance
            }
        }
        finished += region.end - region.start
    }

    private struct Extracted {
        var file: RecoverableFile
        var size: UInt64
    }

    private static func extract(
        reader: BlockReader,
        at offset: UInt64,
        sequence: inout Int,
        sample: Data,
        sampleOffset: Int
    ) throws -> Extracted? {
        let header: Data
        if sampleOffset >= 0, sampleOffset + 16 <= sample.count {
            header = sample.subdata(in: sampleOffset..<(sampleOffset + 16))
        } else {
            header = try reader.read(at: offset, count: 16)
        }
        guard header.count >= 3 else { return nil }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) {
            guard let found = jpeg(reader: reader, at: offset) else { return nil }
            let head = try reader.read(at: offset, count: min(512 * 1024, Int(found.size)))
            sequence += 1
            return Extracted(
                file: make(offset: offset, size: found.size, kind: .jpeg, modified: found.date, sequence: sequence, preferredName: cameraName(in: head)),
                size: found.size
            )
        }
        if header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)) {
            guard let size = rafSize(reader: reader, at: offset) else { return nil }
            let head = try reader.read(at: offset, count: min(512 * 1024, Int(size)))
            sequence += 1
            return Extracted(
                file: make(offset: offset, size: size, kind: .raf, modified: nil, sequence: sequence, preferredName: cameraName(in: head)),
                size: size
            )
        }
        if let movie = movieSize(reader: reader, at: offset) {
            sequence += 1
            return Extracted(file: make(offset: offset, size: movie.size, kind: movie.kind, modified: nil, sequence: sequence, preferredName: nil), size: movie.size)
        }
        return nil
    }

    private static func foundEverything(_ files: [RecoverableFile], named wanted: Set<String>) -> Bool {
        guard !wanted.isEmpty else { return false }
        let have = Set(files.map { $0.name.uppercased() })
        return wanted.allSatisfy { have.contains($0.uppercased()) }
    }

    /// Fujifilm stores DSCF0001.JPG inside the photo's header even after the directory entry is gone.
    private static func cameraName(in data: Data) -> String? {
        if let name = cameraName(in: data, utf16: false) { return name }
        return cameraName(in: data, utf16: true)
    }

    private static func cameraName(in data: Data, utf16: Bool) -> String? {
        let bytes = [UInt8](data)
        let step = utf16 ? 2 : 1
        func at(_ index: Int) -> UInt8? {
            let offset = utf16 ? index * 2 : index
            guard offset + (utf16 ? 1 : 0) < bytes.count else { return nil }
            if utf16, bytes[offset + 1] != 0 { return nil }
            return bytes[offset]
        }
        guard bytes.count > 12 * step else { return nil }
        var index = 0
        let limit = bytes.count / step
        while index + 12 < limit {
            if at(index) == 0x44, at(index + 1) == 0x53, at(index + 2) == 0x43, at(index + 3) == 0x46,
               let d0 = at(index + 4), let d1 = at(index + 5), let d2 = at(index + 6), let d3 = at(index + 7),
               d0 >= 48, d0 <= 57, d1 >= 48, d1 <= 57, d2 >= 48, d2 <= 57, d3 >= 48, d3 <= 57,
               at(index + 8) == 0x2E,
               let e0 = at(index + 9), let e1 = at(index + 10), let e2 = at(index + 11) {
                let ext = String(bytes: [e0, e1, e2], encoding: .ascii)?.uppercased() ?? ""
                if ["JPG", "RAF", "MOV", "HIF"].contains(ext) {
                    let number = String(bytes: [d0, d1, d2, d3], encoding: .ascii) ?? ""
                    return "DSCF\(number).\(ext)"
                }
            }
            index += 1
        }
        return nil
    }

    private static func make(offset: UInt64, size: UInt64, kind: FileKind, modified: Date?, sequence: Int, preferredName: String?) -> RecoverableFile {
        let ext: String
        switch kind {
        case .jpeg: ext = "JPG"
        case .raf: ext = "RAF"
        case .heic: ext = "HEIC"
        case .movie: ext = "MOV"
        case .png: ext = "PNG"
        case .tiff: ext = "TIFF"
        case .other: ext = "BIN"
        }
        let name: String
        if let preferredName {
            name = preferredName
        } else if let modified {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            name = "CARVED_\(formatter.string(from: modified))_\(String(format: "%04d", sequence)).\(ext)"
        } else {
            name = "CARVED_\(String(format: "%04d", sequence)).\(ext)"
        }
        return RecoverableFile(
            id: "carve-\(offset)",
            name: name,
            originalPath: name,
            size: size,
            modified: modified,
            kind: kind,
            confidence: .carved,
            headerLooksValid: true,
            complete: true,
            previewFile: (kind == .movie || kind == .other) ? nil : String(format: "%05d.jpg", sequence),
            ranges: [ByteRange(offset: offset, length: size)]
        )
    }

    private static func findSignature(_ data: Data, from start: Int) -> Int? {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let count = raw.count
            var index = max(start, 0)
            while index + 16 < count {
                let byte = base[index]
                if byte == 0xFF && base[index + 1] == 0xD8 && base[index + 2] == 0xFF {
                    return index
                }
                if byte == 0x46 && matches(base, index, count, ascii: "FUJIFILMCCD-RAW ") {
                    return index
                }
                if base[index + 4] == 0x66 && base[index + 5] == 0x74 && base[index + 6] == 0x79 && base[index + 7] == 0x70 {
                    if movieBrand(base, index, count) != nil {
                        return index
                    }
                }
                index += 1
            }
            return nil
        }
    }

    private static func matches(_ base: UnsafePointer<UInt8>, _ index: Int, _ count: Int, ascii: String) -> Bool {
        let bytes = Array(ascii.utf8)
        if index + bytes.count >= count { return false }
        for (offset, byte) in bytes.enumerated() where base[index + offset] != byte {
            return false
        }
        return true
    }

    private static let movieBrands: Set<String> = [
        "qt  ", "mp41", "mp42", "isom", "iso2", "avc1", "M4V ", "M4A ",
        "3gp4", "3gp5", "heic", "heix", "hevc", "mif1", "msf1", "avif",
        "XAVC", "MSNV", "f4v ",
    ]

    private static func movieBrand(_ base: UnsafePointer<UInt8>, _ index: Int, _ count: Int) -> String? {
        if index + 12 >= count { return nil }
        let size = (UInt32(base[index]) << 24) | (UInt32(base[index + 1]) << 16) | (UInt32(base[index + 2]) << 8) | UInt32(base[index + 3])
        guard size >= 16 && size <= 512 else { return nil }
        let brand = String(bytes: [base[index + 8], base[index + 9], base[index + 10], base[index + 11]], encoding: .ascii) ?? ""
        return movieBrands.contains(brand) ? brand : nil
    }

    private static func jpeg(reader: BlockReader, at start: UInt64) -> (size: UInt64, date: Date?)? {
        let limit = min(reader.size, start + maxJPEG)
        let cursor = ForwardReader(reader: reader, end: limit, offset: start)
        guard let soi = cursor.read(2), soi.count == 2, soi[0] == 0xFF, soi[1] == 0xD8 else { return nil }
        var sawSOF = false
        var date: Date?
        while cursor.offset < limit {
            guard let mark = cursor.read(1), mark[0] == 0xFF else { return nil }
            guard var markerByte = cursor.read(1)?.first else { return nil }
            while markerByte == 0xFF {
                guard let next = cursor.read(1)?.first else { return nil }
                markerByte = next
            }
            if markerByte == 0xD8 || markerByte == 0xD9 { return nil }
            if markerByte == 0x01 || (markerByte >= 0xD0 && markerByte <= 0xD7) { continue }
            guard let lengthBytes = cursor.read(2), let length = Binary.u16be(lengthBytes, 0), length >= 2 else { return nil }
            if markerByte == 0xDA {
                guard sawSOF, cursor.skip(UInt64(length - 2)) else { return nil }
                guard scanEntropy(cursor) else { return nil }
                let size = cursor.offset - start
                guard size >= 32 else { return nil }
                return (size, date)
            }
            if markerByte == 0xC0 || markerByte == 0xC1 || markerByte == 0xC2 || markerByte == 0xC3 {
                sawSOF = true
            }
            let payloadCount = Int(length - 2)
            if markerByte == 0xE1, let payload = cursor.read(payloadCount) {
                if date == nil {
                    date = EXIF.date(inAPP1: payload)
                }
                continue
            }
            guard cursor.skip(UInt64(payloadCount)) else { return nil }
        }
        return nil
    }

    private static func scanEntropy(_ cursor: ForwardReader) -> Bool {
        while cursor.offset < cursor.end {
            guard let byte = cursor.read(1)?.first else { return false }
            if byte != 0xFF { continue }
            guard let next = cursor.read(1)?.first else { return false }
            if next == 0x00 { continue }
            if next == 0xD9 { return true }
            if next >= 0xD0 && next <= 0xD7 { continue }
            if next == 0xFF {
                cursor.offset -= 1
                continue
            }
            // Keep going. Some camera JPEGs contain a marker the strict rules would reject before the real end.
            continue
        }
        return false
    }

    private static func rafSize(reader: BlockReader, at start: UInt64) -> UInt64? {
        guard let header = try? reader.read(at: start, count: 128), header.count >= 0x6C else { return nil }
        guard header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)) else { return nil }
        guard let jpegOffset = Binary.u32be(header, 0x54),
              let jpegLength = Binary.u32be(header, 0x58),
              let metaOffset = Binary.u32be(header, 0x5C),
              let metaLength = Binary.u32be(header, 0x60),
              let cfaOffset = Binary.u32be(header, 0x64),
              let cfaLength = Binary.u32be(header, 0x68)
        else { return nil }
        let ends = [
            UInt64(jpegOffset) + UInt64(jpegLength),
            UInt64(metaOffset) + UInt64(metaLength),
            UInt64(cfaOffset) + UInt64(cfaLength),
        ]
        guard let size = ends.max(), size > 0x80, size <= maxRAF, start + size <= reader.size else { return nil }
        guard jpegOffset > 0x70, UInt64(jpegOffset) + 3 < size else { return nil }
        guard let magic = try? reader.read(at: start + UInt64(jpegOffset), count: 3),
              magic.count >= 3,
              magic[0] == 0xFF,
              magic[1] == 0xD8
        else { return nil }
        return size
    }

    private static func movieSize(reader: BlockReader, at start: UInt64) -> (size: UInt64, kind: FileKind)? {
        var position = start
        var atoms = 0
        var brand = ""
        let diskEnd = min(reader.size, start + maxMovie)
        while atoms < 10_000 && position + 8 <= diskEnd {
            guard let header = try? reader.read(at: position, count: 16), header.count >= 8 else { return nil }
            let size32 = Binary.u32be(header, 0) ?? 0
            let type = header.subdata(in: 4..<8)
            guard type.allSatisfy({ $0 >= 32 && $0 < 127 }) else { break }
            let atom: UInt64
            if size32 == 1 {
                guard let wide = Binary.u64be(header, 8), wide >= 16 else { return nil }
                atom = wide
            } else if size32 < 8 {
                break
            } else {
                atom = UInt64(size32)
            }
            if atoms == 0 {
                guard type == Data("ftyp".utf8) else { return nil }
                guard let brandData = try? reader.read(at: position + 8, count: 4),
                      let text = String(data: brandData, encoding: .ascii),
                      movieBrands.contains(text)
                else { return nil }
                brand = text
            }
            if position + atom > reader.size { return nil }
            position += atom
            atoms += 1
        }
        let size = position - start
        guard atoms >= 2, size >= 8 * 1024 else { return nil }
        let heic: Set<String> = ["heic", "heix", "hevc", "mif1", "msf1", "avif"]
        let kind: FileKind = heic.contains(brand) ? .heic : .movie
        return (size, kind)
    }
}

final class ForwardReader {
    let reader: BlockReader
    let end: UInt64
    var offset: UInt64
    private var window = Data()
    private var windowStart: UInt64 = 0

    init(reader: BlockReader, end: UInt64, offset: UInt64) {
        self.reader = reader
        self.end = end
        self.offset = offset
    }

    func read(_ count: Int) -> Data? {
        if count <= 0 { return Data() }
        var output = Data()
        var left = count
        while left > 0 {
            if offset >= windowStart && offset < windowStart + UInt64(window.count) {
                let local = Int(offset - windowStart)
                let take = min(left, window.count - local)
                output.append(window.subdata(in: local..<(local + take)))
                offset += UInt64(take)
                left -= take
                continue
            }
            if offset >= end { return nil }
            let fill = min(256 * 1024, Int(end - offset))
            guard fill > 0, let chunk = try? reader.read(at: offset, count: fill), !chunk.isEmpty else { return nil }
            window = chunk
            windowStart = offset
        }
        return output
    }

    func skip(_ count: UInt64) -> Bool {
        if count == 0 { return true }
        if offset + count > end { return false }
        offset += count
        return true
    }
}

enum EXIF {
    static func date(inAPP1 payload: Data) -> Date? {
        let prefix = Data("Exif\u{0}\u{0}".utf8)
        guard payload.starts(with: prefix), payload.count > prefix.count + 8 else { return nil }
        return date(inTIFF: payload.subdata(in: prefix.count..<payload.count))
    }

    static func date(inTIFF tiff: Data) -> Date? {
        guard tiff.count > 8 else { return nil }
        let little = tiff[0] == 0x49 && tiff[1] == 0x49
        let big = tiff[0] == 0x4D && tiff[1] == 0x4D
        guard little || big else { return nil }
        func u16(_ offset: Int) -> UInt16? { little ? Binary.u16le(tiff, offset) : Binary.u16be(tiff, offset) }
        func u32(_ offset: Int) -> UInt32? { little ? Binary.u32le(tiff, offset) : Binary.u32be(tiff, offset) }
        guard let magic = u16(2), magic == 42, let ifd0 = u32(4) else { return nil }
        if let exif = pointer(tiff: tiff, ifd: Int(ifd0), tag: 0x8769, u16: u16, u32: u32),
           let date = dateString(tiff: tiff, ifd: exif, tags: [0x9003, 0x9004], u16: u16, u32: u32) {
            return date
        }
        return dateString(tiff: tiff, ifd: Int(ifd0), tags: [0x0132], u16: u16, u32: u32)
    }

    private static func pointer(
        tiff: Data,
        ifd: Int,
        tag: UInt16,
        u16: (Int) -> UInt16?,
        u32: (Int) -> UInt32?
    ) -> Int? {
        guard let count = u16(ifd) else { return nil }
        for index in 0..<Int(count) {
            let entry = ifd + 2 + index * 12
            guard let entryTag = u16(entry), let type = u16(entry + 2), let field = u32(entry + 8) else { continue }
            if entryTag == tag && type == 4 { return Int(field) }
        }
        return nil
    }

    private static func dateString(
        tiff: Data,
        ifd: Int,
        tags: [UInt16],
        u16: (Int) -> UInt16?,
        u32: (Int) -> UInt32?
    ) -> Date? {
        guard ifd >= 0, ifd + 2 <= tiff.count, let count = u16(ifd) else { return nil }
        for wanted in tags {
            for index in 0..<Int(count) {
                let entry = ifd + 2 + index * 12
                guard entry + 12 <= tiff.count,
                      let tag = u16(entry),
                      let type = u16(entry + 2),
                      let valueCount = u32(entry + 4),
                      let value = u32(entry + 8)
                else { continue }
                guard tag == wanted, type == 2, valueCount >= 19 else { continue }
                let offset = Int(value)
                guard offset >= 0, offset + 19 <= tiff.count else { continue }
                let text = String(data: tiff.subdata(in: offset..<(offset + 19)), encoding: .ascii) ?? ""
                let parts = text.split { $0 == ":" || $0 == " " }
                guard parts.count >= 6,
                      let year = Int(parts[0]),
                      let month = Int(parts[1]),
                      let day = Int(parts[2]),
                      let hour = Int(parts[3]),
                      let minute = Int(parts[4]),
                      let second = Int(parts[5])
                else { continue }
                return Binary.makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            }
        }
        return nil
    }
}

struct RangeCover {
    private var ranges: [ByteRange]

    init(_ files: [RecoverableFile], extra: [ByteRange] = []) {
        let sorted = (files.flatMap(\.ranges) + extra).filter { $0.length > 0 }.sorted { $0.offset < $1.offset }
        var merged: [ByteRange] = []
        for range in sorted {
            if var last = merged.last, last.offset + last.length >= range.offset {
                let end = max(last.offset + last.length, range.offset + range.length)
                last.length = end - last.offset
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    func contains(_ offset: UInt64) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].offset + ranges[mid].length <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < ranges.count else { return false }
        let range = ranges[low]
        return offset >= range.offset && offset < range.offset + range.length
    }
}
