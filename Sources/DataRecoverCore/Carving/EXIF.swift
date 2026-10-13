import Foundation

/// Bounds-checked reads from TIFF-structured bytes, in whichever byte order the header says.
struct TIFFBytes {
    let data: Data
    let little: Bool

    init?(_ data: Data) {
        guard data.count >= 8 else { return nil }
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        if first == 0x49 && second == 0x49 {
            little = true
        } else if first == 0x4D && second == 0x4D {
            little = false
        } else {
            return nil
        }
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    func u16(_ offset: Int) -> UInt16? {
        little ? Binary.u16le(data, offset) : Binary.u16be(data, offset)
    }

    func u32(_ offset: Int) -> UInt32? {
        little ? Binary.u32le(data, offset) : Binary.u32be(data, offset)
    }

    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        /// The value itself when it fits in four bytes, otherwise where it is.
        var valueOffset: UInt32
        /// Position of the four value bytes inside the entry.
        var fieldPosition: Int
    }

    func entries(ifd: Int) -> [Entry] {
        guard ifd >= 0, let count = u16(ifd), count > 0, count < 1000 else { return [] }
        var out: [Entry] = []
        for index in 0..<Int(count) {
            let base = ifd + 2 + index * 12
            guard let tag = u16(base), let type = u16(base + 2), let count = u32(base + 4), let value = u32(base + 8) else { break }
            out.append(Entry(tag: tag, type: type, count: count, valueOffset: value, fieldPosition: base + 8))
        }
        return out
    }

    func entry(ifd: Int, tag: UInt16) -> Entry? {
        entries(ifd: ifd).first { $0.tag == tag }
    }

    func nextIFD(after ifd: Int) -> Int? {
        guard let count = u16(ifd) else { return nil }
        guard let next = u32(ifd + 2 + Int(count) * 12), next > 0 else { return nil }
        return Int(next)
    }

    /// An ASCII value, trimmed of padding.
    func string(_ entry: Entry) -> String? {
        guard entry.type == 2, entry.count > 0, entry.count < 4096 else { return nil }
        let length = Int(entry.count)
        let start = length <= 4 ? entry.fieldPosition : Int(entry.valueOffset)
        guard start >= 0, start + length <= data.count else { return nil }
        let bytes = data.subdata(in: start..<(start + length)).prefix { $0 != 0 }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum EXIF {
    struct Summary {
        var date: Date?
        var make: String?
        var model: String?

        /// "Fujifilm X-T5", without the maker repeated when the model already says it.
        var device: String? {
            guard let model else { return make.map(Self.tidyMake) }
            guard let make else { return model }
            let tidy = Self.tidyMake(make)
            if model.lowercased().hasPrefix(tidy.lowercased()) || model.lowercased().hasPrefix(make.lowercased()) {
                return model
            }
            return "\(tidy) \(model)"
        }

        private static func tidyMake(_ make: String) -> String {
            let lower = make.lowercased()
            let known: [(String, String)] = [
                ("fujifilm", "Fujifilm"), ("nikon", "Nikon"), ("canon", "Canon"), ("sony", "Sony"),
                ("olympus", "Olympus"), ("om digital", "OM System"), ("panasonic", "Panasonic"),
                ("pentax", "Pentax"), ("ricoh", "Ricoh"), ("leica", "Leica"), ("samsung", "Samsung"),
                ("apple", "Apple"), ("gopro", "GoPro"), ("dji", "DJI"), ("hasselblad", "Hasselblad"),
                ("sigma", "Sigma"), ("google", "Google"),
            ]
            for (prefix, name) in known where lower.hasPrefix(prefix) {
                return name
            }
            return make
        }
    }

    static func summary(inAPP1 payload: Data) -> Summary? {
        let prefix = Data("Exif\u{0}\u{0}".utf8)
        guard payload.starts(with: prefix), payload.count > prefix.count + 8 else { return nil }
        return summary(inTIFF: payload.subdata(in: prefix.count..<payload.count))
    }

    static func summary(inTIFF data: Data) -> Summary? {
        guard let tiff = TIFFBytes(data), let magic = tiff.u16(2), magic == 42 || magic == 0x4F52 || magic == 0x5352 || magic == 0x55,
              let ifd0 = tiff.u32(4)
        else { return nil }
        var summary = Summary()
        let first = tiff.entries(ifd: Int(ifd0))
        for entry in first {
            switch entry.tag {
            case 0x010F: summary.make = tiff.string(entry)
            case 0x0110: summary.model = tiff.string(entry)
            default: break
            }
        }
        if let exifIFD = first.first(where: { $0.tag == 0x8769 }) {
            let exif = tiff.entries(ifd: Int(exifIFD.valueOffset))
            for tag: UInt16 in [0x9003, 0x9004] {
                if summary.date == nil, let entry = exif.first(where: { $0.tag == tag }), let text = tiff.string(entry) {
                    summary.date = parseDate(text)
                }
            }
        }
        if summary.date == nil, let entry = first.first(where: { $0.tag == 0x0132 }), let text = tiff.string(entry) {
            summary.date = parseDate(text)
        }
        if summary.date == nil && summary.make == nil && summary.model == nil { return nil }
        return summary
    }

    /// "2024:05:06 07:08:09"
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" }
        guard parts.count >= 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Int(parts[5].prefix(2))
        else { return nil }
        return Binary.makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }
}
