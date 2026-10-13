import Foundation

/// What the person is looking for. The results view filters by this.
public enum FileCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo
    case raw
    case video
    case audio
    case document
    case archive
    case other

    public var id: String { rawValue }
}

/// A specific format. Carved files get their extension from here; named files keep the one they had.
public enum FileKind: String, Codable, CaseIterable, Sendable {
    // Photos
    case jpeg, heic, avif, png, gif, tiff, webp, bmp, psd
    // Camera raw
    case raf, cr2, cr3, nef, arw, dng, orf, rw2, pef, srw
    // Video
    case mov, mp4, m4v, threegp, avi, mkv, webm
    // Audio
    case mp3, wav, m4a, flac, aiff
    // Documents
    case pdf, docx, xlsx, pptx, pages, numbers, keynote, doc, xls, ppt, epub
    // Archives
    case zip
    case other

    public var category: FileCategory {
        switch self {
        case .jpeg, .heic, .avif, .png, .gif, .tiff, .webp, .bmp, .psd:
            return .photo
        case .raf, .cr2, .cr3, .nef, .arw, .dng, .orf, .rw2, .pef, .srw:
            return .raw
        case .mov, .mp4, .m4v, .threegp, .avi, .mkv, .webm:
            return .video
        case .mp3, .wav, .m4a, .flac, .aiff:
            return .audio
        case .pdf, .docx, .xlsx, .pptx, .pages, .numbers, .keynote, .doc, .xls, .ppt, .epub:
            return .document
        case .zip:
            return .archive
        case .other:
            return .other
        }
    }

    /// Extension used when the file had to be named by the app.
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .threegp: return "3gp"
        case .keynote: return "key"
        case .tiff: return "tif"
        case .other: return "bin"
        default: return rawValue
        }
    }

    /// True when ImageIO can usually draw a thumbnail from the file's bytes.
    public var hasImagePreview: Bool {
        category == .photo || category == .raw
    }
}

public enum RecoveryConfidence: String, Codable, Sendable {
    /// The file record still points at the data.
    case named
    /// The file record remained, but the block map was cleared. Cameras write files in one continuous run, so the bytes are read that way.
    case estimated
    /// No file record was left. The file was recognized by its contents.
    case carved
}

public struct ByteRange: Codable, Equatable, Sendable {
    public var offset: UInt64
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }

    public var end: UInt64 { offset + length }
}

public struct RecoverableFile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Path on the source, such as DCIM/100_FUJI/DSCF0001.JPG. Equal to `name` for carved files.
    public var originalPath: String
    public var size: UInt64
    /// When the photo was taken or the file was last changed, whichever the source still records.
    public var modified: Date?
    public var kind: FileKind
    public var category: FileCategory
    public var confidence: RecoveryConfidence
    /// Nil when the contents were not checked. False when the bytes no longer look like this kind of file.
    public var headerLooksValid: Bool?
    /// False when the block map no longer covers the whole file.
    public var complete: Bool
    /// Camera or device model, when the file says.
    public var device: String?
    public var ranges: [ByteRange]

    public init(
        id: String,
        name: String,
        originalPath: String,
        size: UInt64,
        modified: Date?,
        kind: FileKind,
        category: FileCategory? = nil,
        confidence: RecoveryConfidence,
        headerLooksValid: Bool?,
        complete: Bool,
        device: String? = nil,
        ranges: [ByteRange]
    ) {
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.size = size
        self.modified = modified
        self.kind = kind
        self.category = category ?? kind.category
        self.confidence = confidence
        self.headerLooksValid = headerLooksValid
        self.complete = complete
        self.device = device
        self.ranges = ranges
    }

    public static func == (lhs: RecoverableFile, rhs: RecoverableFile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// How likely the saved file is to open.
    public var quality: Quality {
        if headerLooksValid == false { return .damaged }
        if !complete { return .partial }
        return .good
    }

    public enum Quality: String, Codable, Sendable {
        case good
        case partial
        case damaged
    }

    /// The folder the file was in, without the file name. Empty for carved files.
    public var folder: String {
        guard confidence != .carved else { return "" }
        let parts = originalPath.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }
}

public struct ScanResult: Codable, Sendable {
    public var files: [RecoverableFile]
    public var filesystem: String
    public var volumeCount: Int
    public var warnings: [String]
    /// True when the scan read the source's contents, not only its file records.
    public var searchedContents: Bool
    /// Bytes that couldn't be read because the media returned errors.
    public var unreadableBytes: UInt64

    public init(
        files: [RecoverableFile],
        filesystem: String,
        volumeCount: Int,
        warnings: [String],
        searchedContents: Bool = false,
        unreadableBytes: UInt64 = 0
    ) {
        self.files = files
        self.filesystem = filesystem
        self.volumeCount = volumeCount
        self.warnings = warnings
        self.searchedContents = searchedContents
        self.unreadableBytes = unreadableBytes
    }
}

public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable {
        /// Reading partition tables and directories. Quick.
        case fileRecords
        /// Reading every block, looking for files by their contents. Slow.
        case contents
        case finished
    }

    public var phase: Phase
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var found: Int

    public init(phase: Phase, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, found: Int = 0) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.found = found
    }

    public var fraction: Double? {
        guard phase == .contents, bytesTotal > 0 else { return phase == .finished ? 1 : nil }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

/// The callbacks are called from the scanning thread.
public struct ScanOptions: @unchecked Sendable {
    /// Read the whole source looking for files by their contents, even when file records were found.
    public var deepScan: Bool
    /// Categories to report. Empty means everything.
    public var categories: Set<FileCategory>
    public var progress: ((ScanProgress) -> Void)?
    public var isCancelled: (() -> Bool)?
    /// Called with files found since the last call.
    public var onFound: (([RecoverableFile]) -> Void)?

    public init(
        deepScan: Bool = true,
        categories: Set<FileCategory> = [],
        progress: ((ScanProgress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        onFound: (([RecoverableFile]) -> Void)? = nil
    ) {
        self.deepScan = deepScan
        self.categories = categories
        self.progress = progress
        self.isCancelled = isCancelled
        self.onFound = onFound
    }

    func wants(_ category: FileCategory) -> Bool {
        categories.isEmpty || categories.contains(category)
    }

    var cancelled: Bool { isCancelled?() == true }
}

public struct RestoredFile: Codable, Sendable {
    public var url: URL
    public var bytes: UInt64
    public var name: String
    /// Bytes that couldn't be read and were written as zeros.
    public var unreadableBytes: UInt64

    public init(url: URL, bytes: UInt64, name: String, unreadableBytes: UInt64 = 0) {
        self.url = url
        self.bytes = bytes
        self.name = name
        self.unreadableBytes = unreadableBytes
    }
}

public struct RestoreReport: Sendable {
    public var saved: [RestoredFile]
    public var failed: [String]

    public init(saved: [RestoredFile], failed: [String]) {
        self.saved = saved
        self.failed = failed
    }

    public var bytes: UInt64 { saved.reduce(0) { $0 + $1.bytes } }
}

public enum FileTyping {
    private static let categoryByExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.photo, ["jpg", "jpeg", "jpe", "heic", "heif", "hif", "avif", "png", "gif", "tif", "tiff", "webp", "bmp", "psd", "svg", "jxl"]),
            (.raw, ["raf", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "mrw", "rwl", "gpr"]),
            (.video, ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mkv", "webm", "3gp", "mpg", "mpeg", "wmv", "insv", "lrv", "lrf", "braw", "r3d", "mxf"]),
            (.audio, ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "ogg", "opus", "wma", "caf", "amr"]),
            (.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "csv", "odt", "ods", "odp", "epub", "html", "htm", "json", "xml"]),
            (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso"]),
        ]
        for (category, extensions) in groups {
            for ext in extensions { map[ext] = category }
        }
        return map
    }()

    public static func category(forExtension ext: String) -> FileCategory? {
        categoryByExtension[ext.lowercased()]
    }

    static func kind(forExtension ext: String) -> FileKind? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "heic", "heif", "hif": return .heic
        case "tif", "tiff": return .tiff
        case "mpg", "mpeg": return nil
        case "3gp": return .threegp
        case "key": return .keynote
        case "aif", "aiff": return .aiff
        default: return FileKind(rawValue: ext.lowercased())
        }
    }

    /// Best guess from a name and the first bytes of the file.
    static func kind(name: String, header: Data) -> FileKind {
        if let kind = kind(forExtension: extensionOf(name)) { return kind }
        return Signatures.kind(of: header) ?? .other
    }

    static func category(name: String, kind: FileKind) -> FileCategory {
        if kind != .other { return kind.category }
        return category(forExtension: extensionOf(name)) ?? .other
    }

    /// False when the bytes clearly aren't this kind of file. Nil when this kind can't be checked.
    static func headerMatches(_ kind: FileKind, header: Data) -> Bool? {
        if let seen = Signatures.kind(of: header) {
            return Signatures.compatible(seen, kind)
        }
        return verifiable.contains(kind) ? false : nil
    }

    /// Kinds the carvers can recognize from their first bytes. A named file of one of these kinds
    /// whose first bytes match nothing has been overwritten. Keep in step with `Registry.all`.
    static let verifiable: Set<FileKind> = [
        .jpeg, .heic, .avif, .png, .gif, .tiff, .webp, .bmp, .psd,
        .raf, .cr2, .cr3, .nef, .arw, .dng, .orf, .rw2, .pef, .srw,
        .mov, .mp4, .m4v, .threegp, .avi, .mkv, .webm,
        .wav, .m4a, .flac,
        .pdf, .docx, .xlsx, .pptx, .pages, .numbers, .keynote, .doc, .xls, .ppt, .epub, .zip,
    ]

    /// Names that are never worth showing: macOS and Windows housekeeping files.
    static func skipFile(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return true }
        if name.hasPrefix("._") || name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        return lower == "thumbs.db" || lower == "desktop.ini"
    }

    /// Folders the scan never walks into because they only hold system indexes.
    static func skipDirectory(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return true }
        let lower = name.lowercased()
        return lower == ".spotlight-v100" || lower == ".fseventsd" || lower == ".temporaryitems"
            || lower == "system volume information" || lower == ".documentrevisions-v100"
    }

    public static func extensionOf(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Fujifilm 8.3 names look like DSCF1234.JPG. Deleting a FAT file erases the first letter, which this puts back.
    static func repairFujifilmShortName(_ name: String) -> String {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return name }
        let stem = String(parts[0])
        let ext = String(parts[1]).uppercased()
        guard ["JPG", "RAF", "MOV", "HIF"].contains(ext) else { return name }
        guard stem.count == 8, stem.hasPrefix("_SCF") else { return name }
        let digits = stem.dropFirst(4)
        guard digits.count == 4, digits.allSatisfy(\.isNumber) else { return name }
        return "DSCF" + digits + "." + ext
    }
}

public enum OutputPath {
    public static func relative(from raw: String) -> String {
        let pieces = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let cleaned = pieces.compactMap { piece -> String? in
            if piece.isEmpty || piece == "." || piece == ".." { return nil }
            let sanitized = sanitize(piece)
            return sanitized.isEmpty ? nil : sanitized
        }
        return cleaned.joined(separator: "/")
    }

    public static func sanitize(_ component: String) -> String {
        var out = ""
        for scalar in component.unicodeScalars {
            if scalar.value < 32 || scalar == "/" || scalar == "\\" || scalar == ":" {
                out.append("_")
            } else {
                out.append(Character(scalar))
            }
        }
        var trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") || trimmed.hasSuffix(" ") {
            trimmed.removeLast()
        }
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "file" }
        if trimmed.count > 180 {
            trimmed = String(trimmed.prefix(180))
        }
        return trimmed
    }
}
