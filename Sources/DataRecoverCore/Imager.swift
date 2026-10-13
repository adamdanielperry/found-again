import Darwin
import Foundation

/// Copies a whole disk into an image file, sector by sector. For failing cards: read them once, then scan the copy as often as needed.
public enum DiskImager {
    public struct Progress: Sendable {
        public var bytesDone: UInt64
        public var bytesTotal: UInt64
        public var unreadable: UInt64

        public init(bytesDone: UInt64, bytesTotal: UInt64, unreadable: UInt64) {
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.unreadable = unreadable
        }

        public var fraction: Double {
            bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
        }
    }

    /// Writes `reader` into a new file at `url`. Unreadable sectors are written as zeros and counted.
    @discardableResult
    public static func copy(
        _ reader: BlockReader,
        to url: URL,
        progress: ((Progress) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Progress {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
        if fd < 0 {
            throw RecoverError.message("Couldn't create \(url.lastPathComponent). \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var state = Progress(bytesDone: 0, bytesTotal: reader.size, unreadable: 0)
        let chunk = 8 * 1024 * 1024
        var lastReport = Date.distantPast
        do {
            while state.bytesDone < reader.size {
                if isCancelled?() == true { throw RecoverError.cancelled }
                let count = Int(min(UInt64(chunk), reader.size - state.bytesDone))
                let (data, missing) = try reader.readTolerant(at: state.bytesDone, count: count)
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                state.bytesDone += UInt64(data.count)
                state.unreadable += UInt64(missing)
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    progress?(state)
                }
            }
            try handle.synchronize()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        progress?(state)
        return state
    }
}
