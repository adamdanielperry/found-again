import Foundation

public enum FileKind: String, Codable {
    case jpeg
    case raf
    case movie
    case heic
    case png
    case tiff
    case other
}

public enum RecoveryConfidence: String, Codable {
    /// The card's file record still points at the photo.
    case named
    /// The file record remained, but the card forgot the block map. Cameras write a photo in one continuous run, so the bytes are read that way.
    case estimated
    /// No file name was left. The photo was recognized by its contents.
    case carved
}

public struct ByteRange: Codable, Equatable {
    public var offset: UInt64
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }
}

public struct RecoverableFile: Codable, Identifiable {
    public var id: String
    public var name: String
    /// Path on the card, such as DCIM/100_FUJI/DSCF0001.JPG.
    public var originalPath: String
    public var size: UInt64
    public var modified: Date?
    public var kind: FileKind
    public var confidence: RecoveryConfidence
    /// Nil when the file's contents were not checked. False when the bytes no longer look like this kind of file.
    public var headerLooksValid: Bool?
    /// False when the card's block map no longer covers the whole file.
    public var complete: Bool
    public var previewFile: String?
    var ranges: [ByteRange]

    public init(
        id: String,
        name: String,
        originalPath: String,
        size: UInt64,
        modified: Date?,
        kind: FileKind,
        confidence: RecoveryConfidence,
        headerLooksValid: Bool?,
        complete: Bool,
        previewFile: String?,
        ranges: [ByteRange]
    ) {
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.size = size
        self.modified = modified
        self.kind = kind
        self.confidence = confidence
        self.headerLooksValid = headerLooksValid
        self.complete = complete
        self.previewFile = previewFile
        self.ranges = ranges
    }
}

public struct ScanResult: Codable {
    public var files: [RecoverableFile]
    public var filesystem: String
    public var volumeCount: Int
    public var warnings: [String]
    /// True when the scan read the card's contents, not only its file list.
    public var searchedContents: Bool

    public init(files: [RecoverableFile], filesystem: String, volumeCount: Int, warnings: [String], searchedContents: Bool = false) {
        self.files = files
        self.filesystem = filesystem
        self.volumeCount = volumeCount
        self.warnings = warnings
        self.searchedContents = searchedContents
    }
}

public struct RestoredFile: Codable {
    public var url: URL
    public var bytes: UInt64
    public var name: String

    public init(url: URL, bytes: UInt64, name: String) {
        self.url = url
        self.bytes = bytes
        self.name = name
    }
}

public struct RestoreReport {
    public var saved: [RestoredFile]
    public var failed: [String]

    public init(saved: [RestoredFile], failed: [String]) {
        self.saved = saved
        self.failed = failed
    }
}

public struct ScanOptions {
    public var photosOnly: Bool
    public var deepScan: Bool
    public var progress: ((Double?, String) -> Void)?
    public var isCancelled: (() -> Bool)?
    public var onUpdate: (([RecoverableFile]) -> Void)?
    /// Uppercased file names. Content search stops once every one of these has been found.
    public var stopWhenFound: Set<String>

    public init(
        photosOnly: Bool = true,
        deepScan: Bool = false,
        progress: ((Double?, String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        onUpdate: (([RecoverableFile]) -> Void)? = nil,
        stopWhenFound: Set<String> = []
    ) {
        self.photosOnly = photosOnly
        self.deepScan = deepScan
        self.progress = progress
        self.isCancelled = isCancelled
        self.onUpdate = onUpdate
        self.stopWhenFound = stopWhenFound
    }
}

enum FileTyping {
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "raf", "heic", "heif", "hif", "png", "tif", "tiff", "dng", "mov", "mp4", "avi",
    ]

    static func kind(name: String, header: Data) -> FileKind {
        switch extensionOf(name) {
        case "jpg", "jpeg", "jpe":
            return .jpeg
        case "raf":
            return .raf
        case "mov", "mp4", "avi":
            return .movie
        case "heic", "heif", "hif":
            return .heic
        case "png":
            return .png
        case "tif", "tiff", "dng":
            return .tiff
        default:
            if header.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
            if header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)) { return .raf }
            if header.count >= 8, header.subdata(in: 4..<8) == Data("ftyp".utf8) { return .movie }
            if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
            if header.starts(with: Data("II*\u{0}".utf8)) || header.starts(with: Data("MM\u{0}*".utf8)) { return .tiff }
            return .other
        }
    }

    static func headerMatches(_ kind: FileKind, header: Data) -> Bool {
        switch kind {
        case .jpeg:
            return header.starts(with: [0xFF, 0xD8, 0xFF])
        case .raf:
            return header.starts(with: Data("FUJIFILMCCD-RAW ".utf8))
        case .movie, .heic:
            return header.count >= 8 && header.subdata(in: 4..<8) == Data("ftyp".utf8)
        case .png:
            return header.starts(with: [0x89, 0x50, 0x4E, 0x47])
        case .tiff:
            return header.starts(with: Data("II*\u{0}".utf8)) || header.starts(with: Data("MM\u{0}*".utf8))
        case .other:
            return true
        }
    }

    static func include(_ kind: FileKind, photosOnly: Bool) -> Bool {
        if !photosOnly { return true }
        return kind != .other
    }

    static func skipName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return true }
        if name.hasPrefix(".") { return true }
        return false
    }

    static func extensionOf(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext
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

    static func sanitize(_ component: String) -> String {
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
