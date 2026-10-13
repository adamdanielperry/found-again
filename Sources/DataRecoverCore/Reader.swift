import Darwin
import Foundation

public protocol BlockReader: AnyObject {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

public final class DataBlockReader: BlockReader {
    private let data: Data
    public let size: UInt64

    public init(_ data: Data) {
        self.data = data
        self.size = UInt64(data.count)
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        if offset >= size || count <= 0 { return Data() }
        let start = Int(offset)
        let end = min(data.count, start + count)
        return data.subdata(in: start..<end)
    }
}

/// Reads a disk image or a raw device. Device reads stay sector-aligned, which macOS requires for /dev/rdisk.
public final class FileBlockReader: BlockReader {
    private let fd: Int32
    public let size: UInt64
    private var blockSize: Int
    private let align: Bool

    /// `expectedSize` is used for memory cards. Asking a raw disk how big it is with lseek often returns 0, which made scans finish without reading any photos.
    public init(path: String, blockSize: Int = 512, alignReads: Bool = false, expectedSize: UInt64? = nil) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            if path.hasPrefix("/dev/") && (errno == EPERM || errno == EACCES) {
                throw RecoverError.needsDiskAccess
            }
            throw RecoverError.readFailed("Couldn't open \(path). \(String(cString: strerror(errno)))")
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 && (flags & O_ACCMODE) != O_RDONLY {
            close(fd)
            throw RecoverError.readFailed("Refusing to open \(path) because it is not read-only.")
        }
        let measured = Self.measuredSize(fd: fd, path: path)
        let resolved = (measured ?? 0) > 0 ? measured! : (expectedSize ?? 0)
        if resolved == 0 {
            close(fd)
            throw RecoverError.readFailed("Couldn't read the size of \(path).")
        }
        self.fd = fd
        self.size = resolved
        self.blockSize = max(blockSize, 512)
        self.align = alignReads
        if alignReads {
            _ = fcntl(fd, F_NOCACHE, 1)
        }
    }

    /// DKIOCGETBLOCKSIZE and DKIOCGETBLOCKCOUNT. Swift can't import those macros.
    private static func measuredSize(fd: Int32, path: String) -> UInt64? {
        if path.hasPrefix("/dev/") {
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            let sizeCommand = UInt(0x40046418)
            let countCommand = UInt(0x40086419)
            if ioctl(fd, sizeCommand, &blockSize) == 0,
               ioctl(fd, countCommand, &blockCount) == 0,
               blockSize > 0, blockCount > 0 {
                return UInt64(blockSize) * blockCount
            }
        }
        let end = lseek(fd, 0, SEEK_END)
        _ = lseek(fd, 0, SEEK_SET)
        if end > 0 { return UInt64(end) }
        return nil
    }

    deinit {
        close(fd)
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        if offset >= size || count <= 0 { return Data() }
        let available = Int(min(UInt64(count), size - offset))
        if !align {
            return try readExact(at: offset, count: available)
        }
        let step = UInt64(blockSize)
        let start = offset / step * step
        let end = min(size, ((offset + UInt64(available) + step - 1) / step) * step)
        let want = Int(end - start)
        let chunk: Data
        do {
            chunk = try readExact(at: start, count: want)
        } catch {
            if blockSize < 4096 {
                blockSize = 4096
                return try read(at: offset, count: available)
            }
            throw error
        }
        let inner = Int(offset - start)
        let upper = min(chunk.count, inner + available)
        guard inner < upper else { return Data() }
        return chunk.subdata(in: inner..<upper)
    }

    private func readExact(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            var done = 0
            while done < count {
                let n = pread(fd, base.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if n == 0 { break }
                done += n
            }
            return done
        }
        if got < 0 {
            throw RecoverError.readFailed("Read failed at byte \(offset). \(String(cString: strerror(errno)))")
        }
        if got < count {
            throw RecoverError.readFailed("The card ended early while reading at byte \(offset).")
        }
        return data
    }
}
