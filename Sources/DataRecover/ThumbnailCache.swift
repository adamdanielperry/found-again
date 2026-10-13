import AppKit
import DataRecoverCore
import ImageIO
import UniformTypeIdentifiers

/// Draws thumbnails straight from the disk, only for tiles on screen, a few at a time so the scan keeps its speed.
final class ThumbnailCache: @unchecked Sendable {
    private let reader: BlockReader
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var waiting: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    /// Files ImageIO couldn't draw. Not retried.
    private var failed = Set<String>()

    init(reader: BlockReader) {
        self.reader = reader
        cache.countLimit = 1500
    }

    func cached(_ file: RecoverableFile) -> NSImage? {
        cache.object(forKey: file.id as NSString)
    }

    func image(for file: RecoverableFile) async -> NSImage? {
        guard file.kind.hasImagePreview || Self.isPlayableVideo(file) else { return nil }
        if let hit = cached(file) { return hit }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if failed.contains(file.id) {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            if waiting[file.id] != nil {
                waiting[file.id]?.append(continuation)
                lock.unlock()
                return
            }
            waiting[file.id] = [continuation]
            lock.unlock()
            queue.addOperation { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = Self.render(file, reader: self.reader)
                if let image {
                    self.cache.setObject(image, forKey: file.id as NSString)
                }
                self.lock.lock()
                if image == nil { self.failed.insert(file.id) }
                let continuations = self.waiting.removeValue(forKey: file.id) ?? []
                self.lock.unlock()
                for waiter in continuations { waiter.resume(returning: image) }
            }
        }
    }

    func clear() {
        queue.cancelAllOperations()
        cache.removeAllObjects()
    }

    static func isPlayableVideo(_ file: RecoverableFile) -> Bool {
        file.category == .video && DiskAsset.contentType(for: file) != nil && file.quality != .damaged
    }

    /// Reads the whole picture (or its embedded preview). Partial reads draw half-grey thumbnails.
    private static func render(_ file: RecoverableFile, reader: BlockReader) -> NSImage? {
        if isPlayableVideo(file) {
            guard let asset = DiskAsset(file: file, reader: reader), let frame = asset.thumbnail(maxPixels: 420) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        }
        guard let data = PreviewBytes.data(for: file, reader: reader),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 420,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// The Finder icon for a file type, for documents, audio and anything without a picture.
    @MainActor
    static func icon(for file: RecoverableFile) -> NSImage {
        let ext = FileTyping.extensionOf(file.name)
        let type = UTType(filenameExtension: ext.isEmpty ? file.kind.fileExtension : ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// Bytes ImageIO can draw a thumbnail from, read from as little of the file as possible.
enum PreviewBytes {
    static let limit = 40 * 1024 * 1024

    static func data(for file: RecoverableFile, reader: BlockReader) -> Data? {
        if file.kind == .raf {
            return rafPreview(file, reader: reader)
        }
        guard file.size <= UInt64(limit) else {
            // Big raw files: ImageIO usually finds the embedded preview in the first part.
            return try? RecoveryEngine.read(file, from: reader, maxBytes: limit)
        }
        return try? RecoveryEngine.read(file, from: reader, maxBytes: Int(file.size))
    }

    /// Fujifilm RAW keeps a full-size JPEG at an offset given in its header.
    private static func rafPreview(_ file: RecoverableFile, reader: BlockReader) -> Data? {
        guard let header = try? RecoveryEngine.read(file, from: reader, maxBytes: 160),
              header.count >= 0x5C,
              header.starts(with: Data("FUJIFILMCCD-RAW ".utf8))
        else { return nil }
        func u32(_ at: Int) -> UInt32 {
            (UInt32(header[at]) << 24) | (UInt32(header[at + 1]) << 16) | (UInt32(header[at + 2]) << 8) | UInt32(header[at + 3])
        }
        let offset = u32(0x54)
        let length = u32(0x58)
        guard length > 32 else { return nil }
        return try? RecoveryEngine.read(file, from: reader, fileOffset: UInt64(offset), maxBytes: min(Int(length), limit))
    }
}
