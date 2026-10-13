import Foundation

/// Recognizes formats from their first bytes and picks the carver that can measure them.
enum Signatures {
    /// Bytes needed at a candidate offset to decide.
    static let headLength = 32

    /// Kinds that have no dependable signature, so a header that matches nothing is not a sign of damage.
    /// MP3s often start straight with audio frames; AIFF has no carver.
    static let unrecognizable: Set<FileKind> = [.mp3, .aiff, .other]

    static func kind(of header: Data) -> FileKind? {
        header.withUnsafeBytes { raw in
            kind(of: raw)
        }
    }

    static func kind(of head: UnsafeRawBufferPointer) -> FileKind? {
        carver(for: head)?.kind
    }

    /// A claimed kind (from a file name) is fine when the bytes are the same family.
    static func compatible(_ seen: FileKind, _ claimed: FileKind) -> Bool {
        if seen == claimed { return true }
        let tiffFamily: Set<FileKind> = [.tiff, .cr2, .nef, .arw, .dng, .pef, .srw, .orf, .rw2]
        if tiffFamily.contains(seen) && tiffFamily.contains(claimed) { return true }
        let isoFamily: Set<FileKind> = [.mov, .mp4, .m4v, .threegp, .m4a, .heic, .avif, .cr3]
        if isoFamily.contains(seen) && isoFamily.contains(claimed) { return true }
        let zipFamily: Set<FileKind> = [.zip, .docx, .xlsx, .pptx, .pages, .numbers, .keynote, .epub]
        if zipFamily.contains(seen) && zipFamily.contains(claimed) { return true }
        let oleFamily: Set<FileKind> = [.doc, .xls, .ppt]
        if oleFamily.contains(seen) && oleFamily.contains(claimed) { return true }
        if seen == .mkv && claimed == .webm { return true }
        return false
    }

    /// The carver for the bytes at a candidate offset, or nil when nothing starts here.
    /// `head` holds up to `headLength` bytes. Checks are ordered by how often each format turns up on cards.
    static func carver(for head: UnsafeRawBufferPointer) -> SniffedCarver? {
        guard head.count >= 12 else { return nil }
        for entry in Registry.byLeadByte[Int(head[0])] {
            if let kind = entry.sniff(head) {
                return SniffedCarver(kind: kind, carver: entry)
            }
        }
        return nil
    }
}

struct SniffedCarver {
    var kind: FileKind
    var carver: FormatCarver
}

/// Measures one format. Implementations must be strict: a false match makes the scan skip real data.
protocol FormatCarver {
    /// First bytes this format can start with, or nil for any. Declared here, not only in an extension,
    /// so the lead-byte table sees each carver's own list rather than the default.
    var leadBytes: [UInt8]? { get }
    /// The kind of file starting with `head`, or nil. Must be cheap: it runs at every sector.
    func sniff(_ head: UnsafeRawBufferPointer) -> FileKind?
    /// Where the file ends and what it says about itself. Nil when the structure doesn't hold up.
    func carve(_ reader: BlockReader, at offset: UInt64, kind: FileKind) throws -> Carved?
}

struct Carved {
    var kind: FileKind
    var size: UInt64
    var modified: Date?
    /// A file name stored inside the file, such as Fujifilm's DSCF0003.JPG.
    var nameHint: String?
    /// Camera or device model.
    var device: String?
    /// False when a part the file needs, such as a movie's index, is missing.
    var complete: Bool

    init(kind: FileKind, size: UInt64, modified: Date? = nil, nameHint: String? = nil, device: String? = nil, complete: Bool = true) {
        self.kind = kind
        self.size = size
        self.modified = modified
        self.nameHint = nameHint
        self.device = device
        self.complete = complete
    }
}

extension UnsafeRawBufferPointer {
    func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, offset + bytes.count <= count else { return false }
        for (index, byte) in bytes.enumerated() where self[offset + index] != byte {
            return false
        }
        return true
    }

    func starts(with text: StaticString, at offset: Int = 0) -> Bool {
        let length = text.utf8CodeUnitCount
        guard offset >= 0, offset + length <= count else { return false }
        return text.withUTF8Buffer { bytes in
            for index in 0..<length where self[offset + index] != bytes[index] {
                return false
            }
            return true
        }
    }

    func u16be(_ offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func u32be(_ offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16) | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }

    func u16le(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32le(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
