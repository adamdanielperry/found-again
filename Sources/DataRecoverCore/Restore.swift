import Darwin
import Foundation

public enum PhotoRestore {
    public static func save(
        _ files: [RecoverableFile],
        from reader: BlockReader,
        to directory: URL,
        progress: ((Double?, String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> RestoreReport {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var saved: [RestoredFile] = []
        var failed: [String] = []
        var used = Set<String>()
        let totalBytes = max(files.reduce(UInt64(0)) { $0 + $1.size }, 1)
        var doneBytes: UInt64 = 0
        for file in files {
            if isCancelled?() == true { throw RecoverError.cancelled }
            progress?(Double(doneBytes) / Double(totalBytes), file.name)
            do {
                let url = try destination(for: file, in: root, used: &used)
                let written = try write(file, from: reader, to: url)
                if let modified = file.modified {
                    try? FileManager.default.setAttributes([.creationDate: modified, .modificationDate: modified], ofItemAtPath: url.path)
                }
                saved.append(RestoredFile(url: url, bytes: written.bytes, name: url.lastPathComponent, unreadableBytes: written.unreadable))
            } catch let error as RecoverError where error == .deviceGone {
                throw error
            } catch {
                failed.append("\(file.name): \(error.localizedDescription)")
            }
            doneBytes += file.size
        }
        progress?(1, "Saved \(saved.count) \(saved.count == 1 ? "file" : "files")")
        return RestoreReport(saved: saved, failed: failed)
    }

    private static func destination(for file: RecoverableFile, in root: URL, used: inout Set<String>) throws -> URL {
        let relative = OutputPath.relative(from: file.originalPath.isEmpty ? file.name : file.originalPath)
        let fallback = OutputPath.relative(from: file.name)
        let chosen = relative.isEmpty ? (fallback.isEmpty ? "RECOVERED.BIN" : fallback) : relative
        var candidate = chosen
        var number = 2
        while used.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = numbered(chosen, number)
            number += 1
            if number > 10_000 { break }
        }
        used.insert(candidate.lowercased())
        var url = root
        for part in candidate.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        try assertInside(url, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func numbered(_ relative: String, _ number: Int) -> String {
        let parts = relative.split(separator: "/").map(String.init)
        guard let file = parts.last else { return "file \(number)" }
        let ext = (file as NSString).pathExtension
        let base = (file as NSString).deletingPathExtension
        let named = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
        let dirs = parts.dropLast()
        if dirs.isEmpty { return named }
        return dirs.joined(separator: "/") + "/" + named
    }

    private static func assertInside(_ url: URL, root: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        guard parentPath.hasPrefix(rootPath) || parent.path == resolvedRoot.path else {
            throw RecoverError.message("Refusing to save outside the folder you chose.")
        }
    }

    private static func write(_ file: RecoverableFile, from reader: BlockReader, to url: URL) throws -> (bytes: UInt64, unreadable: UInt64) {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
        if fd < 0 {
            throw RecoverError.message("Couldn't create \(url.lastPathComponent). \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var written: UInt64 = 0
        var unreadable: UInt64 = 0
        for range in file.ranges {
            var remaining = range.length
            var offset = range.offset
            while remaining > 0 {
                let chunkCount = Int(min(remaining, 8 * 1024 * 1024))
                let (chunk, missing) = try reader.readTolerant(at: offset, count: chunkCount)
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                written += UInt64(chunk.count)
                unreadable += UInt64(missing)
                offset += UInt64(chunk.count)
                remaining -= UInt64(chunk.count)
            }
        }
        try handle.synchronize()
        return (written, unreadable)
    }
}
