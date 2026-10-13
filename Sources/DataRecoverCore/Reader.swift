import Darwin
import Foundation

public protocol BlockReader: AnyObject {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

public extension BlockReader {
    /// Reads like `read`, but a sector the media can't return comes back as zeros instead of stopping everything.
    /// Failing cards often have a few bad sectors. Losing one photo is better than losing the scan.
    func readTolerant(at offset: UInt64, count: Int, sector: Int = 4096) throws -> (data: Data, unreadable: Int) {
        do {
            return (try read(at: offset, count: count), 0)
        } catch let error as RecoverError {
            if case .deviceGone = error { throw error }
        }
        let available = Int(min(UInt64(max(count, 0)), size > offset ? size - offset : 0))
        var output = Data(capacity: available)
        var failed = 0
        var position = 0
        while position < available {
            let take = min(sector, available - position)
            do {
                let chunk = try read(at: offset + UInt64(position), count: take)
                output.append(chunk)
                if chunk.count < take {
                    output.append(Data(count: take - chunk.count))
                    failed += take - chunk.count
                }
            } catch let error as RecoverError {
                if case .deviceGone = error { throw error }
                output.append(Data(count: take))
                failed += take
            }
            position += take
        }
        return (output, failed)
    }
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
/// `pread` keeps no shared file position, so one reader can serve the scan and thumbnail loading at the same time.
public final class FileBlockReader: BlockReader {
    private let fd: Int32
    private let ownsDescriptor: Bool
    public let size: UInt64
    private let blockSize: Int
    private let align: Bool

    /// Opens a disk image or other regular file.
    public convenience init(path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            throw RecoverError.readFailed("Couldn't open \(path). \(String(cString: strerror(errno)))")
        }
        try self.init(descriptor: fd, blockSize: 512, alignReads: false, expectedSize: nil, owns: true)
    }

    /// Wraps a descriptor that is already open, such as one for /dev/rdiskN handed over by authopen.
    /// `expectedSize` is used when the device can't report its size.
    public init(descriptor fd: Int32, blockSize: Int, alignReads: Bool, expectedSize: UInt64?, owns: Bool = true) throws {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 && (flags & O_ACCMODE) != O_RDONLY {
            if owns { close(fd) }
            throw RecoverError.readFailed("Refusing to use a descriptor that can write.")
        }
        let measured = Self.measuredSize(fd: fd)
        let resolved = (measured ?? 0) > 0 ? measured! : (expectedSize ?? 0)
        if resolved == 0 {
            if owns { close(fd) }
            throw RecoverError.readFailed("Couldn't read the size of the disk.")
        }
        self.fd = fd
        self.ownsDescriptor = owns
        self.size = resolved
        self.blockSize = max(blockSize, 512)
        self.align = alignReads
        if alignReads {
            _ = fcntl(fd, F_NOCACHE, 1)
        }
    }

    /// DKIOCGETBLOCKSIZE and DKIOCGETBLOCKCOUNT, which Swift can't import as macros. Falls back to the file length.
    private static func measuredSize(fd: Int32) -> UInt64? {
        var info = stat()
        if fstat(fd, &info) == 0 {
            let type = info.st_mode & S_IFMT
            if type == S_IFCHR || type == S_IFBLK {
                var blockSize: UInt32 = 0
                var blockCount: UInt64 = 0
                if ioctl(fd, UInt(0x40046418), &blockSize) == 0,
                   ioctl(fd, UInt(0x40086419), &blockCount) == 0,
                   blockSize > 0, blockCount > 0 {
                    return UInt64(blockSize) * blockCount
                }
                return nil
            }
            if type == S_IFREG, info.st_size > 0 {
                return UInt64(info.st_size)
            }
        }
        return nil
    }

    deinit {
        if ownsDescriptor { close(fd) }
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
        let chunk = try readExact(at: start, count: Int(end - start))
        let inner = Int(offset - start)
        let upper = min(chunk.count, inner + available)
        guard inner < upper else { return Data() }
        if inner == 0 && upper == chunk.count { return chunk }
        return chunk.subdata(in: inner..<upper)
    }

    private func readExact(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        var failure: Int32 = 0
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            var done = 0
            while done < count {
                let n = pread(fd, base.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return -1
                }
                if n == 0 { break }
                done += n
            }
            return done
        }
        if got < 0 {
            if failure == ENXIO || failure == ENODEV || failure == EBADF {
                throw RecoverError.deviceGone
            }
            throw RecoverError.readFailed("Read failed at byte \(offset). \(String(cString: strerror(failure)))")
        }
        if got < count {
            data.count = got
        }
        return data
    }
}
