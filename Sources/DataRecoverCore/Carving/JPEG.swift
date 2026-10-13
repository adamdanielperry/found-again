import Foundation

struct JPEGCarver: FormatCarver {
    static let maxSize: UInt64 = 200 * 1024 * 1024

    var leadBytes: [UInt8]? { [0xFF] }

    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind? {
        guard head.count >= 4, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF else { return nil }
        let marker = head[3]
        // APPn, DQT, SOF0, DHT, or COM. Anything else right after SOI is not a real photo.
        guard (0xE0...0xEF).contains(marker) || marker == 0xDB || marker == 0xC0 || marker == 0xC4 || marker == 0xFE else {
            return nil
        }
        return .jpeg
    }

    func carve(_ reader: BlockReader, at start: UInt64, kind: FileKind) throws -> Carved? {
        guard let parsed = Self.measure(reader, at: start) else { return nil }
        return Carved(kind: .jpeg, size: parsed.size, modified: parsed.exif?.date, nameHint: parsed.nameHint, device: parsed.exif?.device)
    }

    struct Parsed {
        var size: UInt64
        var exif: EXIF.Summary?
        var nameHint: String?
    }

    static func measure(_ reader: BlockReader, at start: UInt64, limit: UInt64? = nil) -> Parsed? {
        let end = min(reader.size, start + (limit ?? maxSize))
        let bytes = ByteWindow(reader: reader, end: end)
        guard bytes.byte(at: start) == 0xFF, bytes.byte(at: start + 1) == 0xD8 else { return nil }
        var position = start + 2
        var sawFrame = false
        var exif: EXIF.Summary?
        var nameHint: String?
        var pictureEnds: [UInt64] = []

        while position < end {
            guard bytes.byte(at: position) == 0xFF else { return nil }
            var marker: UInt8 = 0xFF
            while marker == 0xFF {
                position += 1
                guard let next = bytes.byte(at: position) else { return nil }
                marker = next
            }
            position += 1
            if marker == 0xD8 || marker == 0xD9 { return nil }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            guard let length = bytes.u16be(at: position), length >= 2 else { return nil }
            let payloadStart = position + 2
            let payloadLength = Int(length) - 2
            if isFrame(marker) { sawFrame = true }
            switch marker {
            case 0xDA:
                guard sawFrame else { return nil }
                guard let after = scanEntropy(bytes, from: payloadStart + UInt64(payloadLength)) else { return nil }
                var size = after - start
                if let extended = pictureEnds.max(), extended > after, extended <= end {
                    size = extended - start
                }
                guard size >= 32 else { return nil }
                return Parsed(size: size, exif: exif, nameHint: nameHint)
            case 0xE1:
                if let payload = bytes.bytes(at: payloadStart, count: payloadLength) {
                    if exif == nil, let summary = EXIF.summary(inAPP1: payload) { exif = summary }
                    if nameHint == nil { nameHint = CameraNames.find(in: payload) }
                }
            case 0xE2:
                if let payload = bytes.bytes(at: payloadStart, count: payloadLength),
                   let ends = MPF.imageEnds(payload: payload, payloadStart: payloadStart, fileStart: start, bytes: bytes) {
                    pictureEnds.append(contentsOf: ends)
                }
            case 0xFE, 0xE3...0xEF:
                if nameHint == nil, payloadLength <= 256 * 1024, let payload = bytes.bytes(at: payloadStart, count: payloadLength) {
                    nameHint = CameraNames.find(in: payload)
                }
            default:
                break
            }
            position = payloadStart + UInt64(payloadLength)
        }
        return nil
    }

    private static func isFrame(_ marker: UInt8) -> Bool {
        switch marker {
        case 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
            return true
        default:
            return false
        }
    }

    /// Walks compressed image data to the end-of-image marker. Progressive photos have more segments between scans; those are stepped over.
    private static func scanEntropy(_ bytes: ByteWindow, from offset: UInt64) -> UInt64? {
        var position = offset
        while let ff = bytes.nextFF(from: position) {
            guard let next = bytes.byte(at: ff + 1) else { return nil }
            switch next {
            case 0x00, 0xD0...0xD7:
                position = ff + 2
            case 0xFF:
                position = ff + 1
            case 0xD9:
                return ff + 2
            case 0xC4, 0xDA, 0xDB, 0xDD, 0xFE, 0xE0...0xEF:
                guard let length = bytes.u16be(at: ff + 2), length >= 2 else { return nil }
                position = ff + 2 + UInt64(length)
            case 0xD8:
                // A new photo started before this one ended. The rest of this one is gone.
                return nil
            default:
                // Some cameras write markers a strict reader would reject. Keep going.
                position = ff + 2
            }
        }
        return nil
    }
}

/// Multi-Picture Format. Many cameras store a large preview as a second JPEG right after the main one.
enum MPF {
    static func imageEnds(payload: Data, payloadStart: UInt64, fileStart: UInt64, bytes: ByteWindow) -> [UInt64]? {
        guard payload.count > 16, payload.starts(with: Data("MPF\u{0}".utf8)) else { return nil }
        let tiff = payload.subdata(in: 4..<payload.count)
        let base = payloadStart + 4
        guard let reader = TIFFBytes(tiff) else { return nil }
        guard let ifd = reader.u32(4) else { return nil }
        guard let entries = reader.entry(ifd: Int(ifd), tag: 0xB002) else { return nil }
        let count = Int(entries.count) / 16
        guard count > 1, count < 64 else { return nil }
        var ends: [UInt64] = []
        for index in 1..<count {
            let entry = Int(entries.valueOffset) + index * 16
            guard let size = reader.u32(entry + 4), let offset = reader.u32(entry + 8), size > 0, offset > 0 else { continue }
            let imageStart = base + UInt64(offset)
            guard bytes.byte(at: imageStart) == 0xFF, bytes.byte(at: imageStart + 1) == 0xD8 else { continue }
            ends.append(imageStart + UInt64(size))
        }
        return ends.isEmpty ? nil : ends
    }
}

/// File names cameras store inside the photo, which survive after the directory entry is gone.
enum CameraNames {
    /// Looks for Fujifilm's DSCF1234.JPG, in ASCII or UTF-16.
    static func find(in data: Data) -> String? {
        if let name = find(in: data, utf16: false) { return name }
        return find(in: data, utf16: true)
    }

    private static func find(in data: Data, utf16: Bool) -> String? {
        data.withUnsafeBytes { raw -> String? in
            let step = utf16 ? 2 : 1
            let limit = raw.count / step
            guard limit >= 12 else { return nil }
            func at(_ index: Int) -> UInt8? {
                let offset = index * step
                guard offset + (utf16 ? 1 : 0) < raw.count else { return nil }
                if utf16, raw[offset + 1] != 0 { return nil }
                return raw[offset]
            }
            var index = 0
            while index + 12 <= limit {
                if at(index) == 0x44, at(index + 1) == 0x53, at(index + 2) == 0x43, at(index + 3) == 0x46,
                   let d0 = at(index + 4), let d1 = at(index + 5), let d2 = at(index + 6), let d3 = at(index + 7),
                   [d0, d1, d2, d3].allSatisfy({ $0 >= 48 && $0 <= 57 }),
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
    }
}
