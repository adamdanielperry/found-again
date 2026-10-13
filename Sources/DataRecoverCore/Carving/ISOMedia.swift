import Foundation

/// MP4, MOV, HEIC, AVIF, CR3, M4A and 3GP all share the ISO base media layout: a chain of sized boxes starting with `ftyp`.
struct ISOMediaCarver: FormatCarver {
    static let maxSize: UInt64 = 256 * 1024 * 1024 * 1024

    /// The `ftyp` box is small, so its 32-bit size starts with a zero byte.
    var leadBytes: [UInt8]? { [0x00] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 16, head.starts(with: "ftyp", at: 4) else { return nil }
        let size = head.u32be(0)
        guard size >= 16, size <= 512, size % 4 == 0 else { return nil }
        let brand = String(decoding: UnsafeRawBufferPointer(rebasing: head[8..<12]), as: UTF8.self)
        return Self.kind(forBrand: brand)
    }

    static func kind(forBrand brand: String) -> FileKind? {
        switch brand {
        case "qt  ": return .mov
        case "mp41", "mp42", "isom", "iso2", "iso4", "iso5", "iso6", "avc1", "dash", "mmp4", "XAVC", "MSNV", "f4v ", "mp71", "NDAS", "CAEP", "niko":
            return .mp4
        case "M4V ", "M4VH", "M4VP": return .m4v
        case "M4A ", "M4B ", "M4P ": return .m4a
        case "3gp4", "3gp5", "3gp6", "3gp7", "3g2a", "3g2b", "3g2c": return .threegp
        case "heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1", "msf1": return .heic
        case "avif", "avis": return .avif
        case "crx ": return .cr3
        default: return nil
        }
    }

    private static let knownBoxes: Set<String> = [
        "ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "meta", "pnot", "PICT", "udta",
        "moof", "mfra", "sidx", "styp", "pdin", "prfl", "emsg", "junk", "pict", "idat", "iinf", "iloc",
    ]

    func carve(_ reader: BlockReader, at start: UInt64, kind sniffed: FileKind) throws -> Carved? {
        let end = min(reader.size, start + Self.maxSize)
        var position = start
        var boxes = 0
        var seen = Set<String>()
        var kind = sniffed
        var moovAt: (UInt64, UInt64)?
        while boxes < 10_000 && position + 8 <= end {
            guard let header = try? reader.read(at: position, count: 16), header.count >= 8 else { break }
            let size32 = Binary.u32be(header, 0) ?? 0
            let typeBytes = header.subdata(in: 4..<8)
            guard typeBytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { break }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let size: UInt64
            if size32 == 1 {
                guard header.count >= 16, let wide = Binary.u64be(header, 8), wide >= 16 else { return nil }
                size = wide
            } else if size32 == 0 {
                // "Runs to the end of the file", which a deleted file no longer has.
                return nil
            } else if size32 < 8 {
                break
            } else {
                size = UInt64(size32)
            }
            if boxes == 0 {
                guard type == "ftyp", size <= 512,
                      let ftyp = try? reader.read(at: position, count: Int(size)),
                      let refined = Self.refine(ftyp: ftyp, sniffed: sniffed)
                else { return nil }
                kind = refined
            } else if !Self.knownBoxes.contains(type) {
                break
            }
            guard position + size <= end else { return nil }
            if type == "moov" { moovAt = (position, size) }
            seen.insert(type)
            position += size
            boxes += 1
            if Self.complete(kind: kind, seen: seen), position + 8 > end { break }
        }
        // A recording cut short (battery out, card pulled) has its pictures but no index. Repair tools can often fix those.
        let indexless = kind.category == .video && seen.contains("mdat") && !seen.contains("moov")
        guard Self.complete(kind: kind, seen: seen) || indexless else { return nil }
        let size = position - start
        guard size >= 4 * 1024 else { return nil }
        var modified: Date?
        if let (moovStart, moovSize) = moovAt {
            modified = Self.creationDate(reader, moov: moovStart, size: moovSize)
        }
        return Carved(kind: kind, size: size, modified: modified, complete: !indexless)
    }

    /// Picks the kind from the compatible-brand list when the major brand is generic, such as AVIF files labelled `mif1`.
    private static func refine(ftyp: Data, sniffed: FileKind) -> FileKind? {
        guard ftyp.count >= 16 else { return nil }
        var brands: [String] = []
        var offset = 16
        while offset + 4 <= ftyp.count {
            brands.append(String(decoding: ftyp.subdata(in: offset..<(offset + 4)), as: UTF8.self))
            offset += 4
        }
        if sniffed == .heic && brands.contains("avif") { return .avif }
        if sniffed == .mp4 && brands.contains("crx ") { return .cr3 }
        return sniffed
    }

    private static func complete(kind: FileKind, seen: Set<String>) -> Bool {
        guard seen.contains("mdat") || seen.contains("idat") || seen.contains("moof") else {
            // HEIC may keep pixels in an item box inside `meta`.
            return (kind == .heic || kind == .avif) && seen.contains("meta")
        }
        switch kind {
        case .heic, .avif:
            return seen.contains("meta")
        default:
            return seen.contains("moov")
        }
    }

    /// The movie header's creation time, which cameras set to the recording time.
    private static func creationDate(_ reader: BlockReader, moov: UInt64, size: UInt64) -> Date? {
        let span = Int(min(size, 64 * 1024))
        guard let data = try? reader.read(at: moov, count: span) else { return nil }
        var offset = 8
        while offset + 8 <= data.count {
            guard let childSize = Binary.u32be(data, offset), childSize >= 8 else { return nil }
            let type = String(decoding: data.subdata(in: (offset + 4)..<(offset + 8)), as: UTF8.self)
            if type == "mvhd" {
                guard offset + 24 <= data.count else { return nil }
                let version = data[offset + 8]
                let seconds: UInt64
                if version == 1 {
                    seconds = Binary.u64be(data, offset + 12) ?? 0
                } else {
                    seconds = UInt64(Binary.u32be(data, offset + 12) ?? 0)
                }
                guard seconds > 0 else { return nil }
                let date = Date(timeIntervalSince1970: TimeInterval(seconds) - 2_082_844_800)
                let year = Calendar(identifier: .gregorian).component(.year, from: date)
                return (1995...2100).contains(year) ? date : nil
            }
            offset += Int(childSize)
        }
        return nil
    }
}
