import Foundation

/// PDF has no length field. It ends with "startxref", an offset, and "%%EOF"; files edited in place
/// append updates after that, each ending with its own "%%EOF", so the search carries on while more objects follow.
struct PDFCarver: FormatCarver {
    static let maxSize: UInt64 = 512 * 1024 * 1024
    private static let endMarker = Array("%%EOF".utf8)
    private static let headerMarker = Array("%PDF-".utf8)

    var leadBytes: [UInt8]? { [0x25] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 9, head.starts(with: "%PDF-") else { return nil }
        guard head[5] == 0x31 || head[5] == 0x32, head[6] == 0x2E, (0x30...0x39).contains(head[7]) else { return nil }
        return .pdf
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        let bytes = ByteWindow(reader: reader, end: end, windowSize: 4 * 1024 * 1024)
        var position = start + 8
        while let hit = bytes.findFirst(of: [Self.endMarker, Self.headerMarker], from: position) {
            if hit.index == 1 {
                // Another PDF starting on a sector boundary means this one was cut short and overwritten.
                if hit.offset % Carver.sector == 0 { return nil }
                position = hit.offset + 5
                continue
            }
            var after = hit.offset + 5
            position = after
            guard Self.followsStartXref(bytes, eof: hit.offset, start: start) else { continue }
            if bytes.byte(at: after) == 0x0D { after += 1 }
            if bytes.byte(at: after) == 0x0A { after += 1 }
            if Self.updateFollows(bytes, at: after) {
                position = after
                continue
            }
            let size = after - start
            return Carved(kind: .pdf, size: size, modified: Self.date(bytes, start: start, end: after))
        }
        return nil
    }

    /// A real end marker comes straight after "startxref" and the offset of the cross-reference table.
    /// Any other "%%EOF" is inside a stream.
    private static func followsStartXref(_ bytes: ByteWindow, eof: UInt64, start: UInt64) -> Bool {
        let span = Int(min(64, eof - start))
        guard let tail = bytes.bytes(at: eof - UInt64(span), count: span),
              let keyword = tail.range(of: Data("startxref".utf8), options: .backwards)
        else { return false }
        let digits = tail[keyword.upperBound...].filter { $0 >= 0x30 && $0 <= 0x39 }
        let rest = tail[keyword.upperBound...].filter { !($0 >= 0x30 && $0 <= 0x39) && ![0x20, 0x0D, 0x0A, 0x09].contains($0) }
        guard !digits.isEmpty, digits.count <= 12, rest.isEmpty,
              let offset = UInt64(String(decoding: digits, as: UTF8.self))
        else { return false }
        return offset < eof - start
    }

    /// True when an update follows the end marker: writers append the next object ("12 0 obj") or
    /// cross-reference table ("xref") straight after it. Leftover bytes in the disk's slack space don't line up like that.
    private static func updateFollows(_ bytes: ByteWindow, at offset: UInt64) -> Bool {
        let available = Int(min(64, bytes.end > offset ? bytes.end - offset : 0))
        guard available > 0, let look = bytes.bytes(at: offset, count: available) else { return false }
        let text = [UInt8](look)
        let whitespace: Set<UInt8> = [0x20, 0x0D, 0x0A, 0x09, 0x0C]
        var index = 0
        while index < text.count, whitespace.contains(text[index]) { index += 1 }
        if text[index...].starts(with: Array("xref".utf8)) { return true }
        // Object number, generation number, "obj".
        for _ in 0..<2 {
            let digitsStart = index
            while index < text.count, (0x30...0x39).contains(text[index]) { index += 1 }
            guard index > digitsStart, index < text.count, whitespace.contains(text[index]) else { return false }
            while index < text.count, whitespace.contains(text[index]) { index += 1 }
        }
        return text[index...].starts(with: Array("obj".utf8))
    }

    /// The document's modification or creation date from its Info dictionary, when it's stored as plain text near either end.
    private static func date(_ bytes: ByteWindow, start: UInt64, end: UInt64) -> Date? {
        let span = UInt64(64 * 1024)
        var regions: [Data] = []
        if let head = bytes.bytes(at: start, count: Int(min(span, end - start))) { regions.append(head) }
        if end - start > span, let tail = bytes.bytes(at: end - span, count: Int(span)) { regions.append(tail) }
        for key in ["/ModDate", "/CreationDate"] {
            for region in regions {
                guard let found = region.range(of: Data(key.utf8)) else { continue }
                let after = region[found.upperBound...].prefix(40)
                if let date = parseDate(Data(after)) { return date }
            }
        }
        return nil
    }

    /// "(D:20240506070809+01'00')". Without a zone the time is local, like a camera's.
    static func parseDate(_ value: Data) -> Date? {
        var text = String(decoding: value, as: UTF8.self)
        guard let open = text.firstIndex(of: "(") else { return nil }
        text = String(text[text.index(after: open)...]).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("D:") { text.removeFirst(2) }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= 8 else { return nil }
        func number(_ from: Int, _ length: Int, _ fallback: Int) -> Int {
            guard digits.count >= from + length else { return fallback }
            let slice = digits.dropFirst(from).prefix(length)
            return Int(slice) ?? fallback
        }
        guard let local = Binary.makeDate(year: number(0, 4, 0), month: number(4, 2, 1), day: number(6, 2, 1),
                                          hour: number(8, 2, 0), minute: number(10, 2, 0), second: min(number(12, 2, 0), 58))
        else { return nil }
        let zone = text.dropFirst(digits.count)
        guard let sign = zone.first, sign == "Z" || sign == "+" || sign == "-" else { return local }
        // Convert from the stated zone to an absolute time.
        let zoneDigits = zone.dropFirst().filter { $0.isASCII && $0.isNumber }
        let hours = Int(zoneDigits.prefix(2)) ?? 0
        let minutes = Int(zoneDigits.dropFirst(2).prefix(2)) ?? 0
        let stated = (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
        let here = TimeZone.current.secondsFromGMT(for: local)
        return local.addingTimeInterval(TimeInterval(here - stated))
    }
}
