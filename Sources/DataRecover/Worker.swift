import AppKit
import CoreGraphics
import Darwin
import DataRecoverCore
import Foundation
import ImageIO

struct WorkerJob {
    var action: String
    var device: String?
    var image: String?
    var manifest: String
    var previews: String?
    var output: String?
    var progress: String?
    var cancel: String?
    var status: String?
    var uid: uid_t
    var gid: gid_t
    var deep: Bool
    var photosOnly: Bool
    var saveAll: Bool
    var ids: Set<String>
    var stopNames: Set<String> = []

    func commandArguments() -> [String] {
        var args = [action, "--manifest", manifest, "--uid", String(uid), "--gid", String(gid)]
        if let device { args += ["--device", device] }
        if let image { args += ["--image", image] }
        if let previews { args += ["--previews", previews] }
        if let output { args += ["--output", output] }
        if let progress { args += ["--progress", progress] }
        if let cancel { args += ["--cancel", cancel] }
        if let status { args += ["--status", status] }
        if deep { args.append("--deep") }
        if photosOnly {
            args.append("--photos-only")
        } else {
            args.append("--all-files")
        }
        if saveAll { args.append("--all") }
        if !stopNames.isEmpty {
            args += ["--names", stopNames.sorted().joined(separator: ",")]
        }
        for id in ids.sorted() {
            args += ["--id", id]
        }
        return args
    }
}

enum WorkerCLI {
    static func main(_ args: [String]) {
        do {
            let job = try parse(args)
            try WorkerLogic.run(job)
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }

    static func parse(_ args: [String]) throws -> WorkerJob {
        var action = ""
        var values: [String: String] = [:]
        var flags = Set<String>()
        var ids = Set<String>()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--all" || arg == "--deep" || arg == "--photos-only" || arg == "--all-files" {
                flags.insert(arg)
                index += 1
                continue
            }
            if arg == "--id" {
                index += 1
                guard index < args.count else { throw RecoverError.message("Missing a file id.") }
                ids.insert(args[index])
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                index += 1
                guard index < args.count else { throw RecoverError.message("Missing a value for \(arg).") }
                values[arg] = args[index]
                index += 1
                continue
            }
            if action.isEmpty {
                action = arg
            }
            index += 1
        }
        guard action == "scan" || action == "save" || action == "recover" else {
            throw RecoverError.message("Use scan, save, or recover.")
        }
        guard let manifest = values["--manifest"] else {
            throw RecoverError.message("A manifest path is required.")
        }
        let uid = uid_t(Int(values["--uid"] ?? "") ?? Int(getuid()))
        let gid = gid_t(Int(values["--gid"] ?? "") ?? Int(getgid()))
        return WorkerJob(
            action: action,
            device: values["--device"],
            image: values["--image"],
            manifest: manifest,
            previews: values["--previews"],
            output: values["--output"],
            progress: values["--progress"],
            cancel: values["--cancel"],
            status: values["--status"],
            uid: uid,
            gid: gid,
            deep: flags.contains("--deep"),
            photosOnly: !flags.contains("--all-files"),
            saveAll: flags.contains("--all"),
            ids: ids,
            stopNames: Set((values["--names"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })
        )
    }
}

enum WorkerLogic {
    static func run(_ job: WorkerJob) throws {
        do {
            try perform(job)
            writeStatus(job, ok: true, message: nil, cancelled: false)
        } catch let error as RecoverError {
            let cancelled = { if case .cancelled = error { return true }; return false }()
            writeStatus(job, ok: false, message: error.localizedDescription, cancelled: cancelled, code: statusCode(error))
            if !cancelled { throw error }
        } catch {
            writeStatus(job, ok: false, message: error.localizedDescription, cancelled: false, code: statusCode(error))
            throw error
        }
    }

    private static func perform(_ job: WorkerJob) throws {
        switch job.action {
        case "scan":
            try scan(job)
        case "save":
            try save(job)
        case "recover":
            try recover(job)
        default:
            throw RecoverError.message("Unknown action.")
        }
    }

    private static func scan(_ job: WorkerJob) throws {
        try withReader(job) { reader in
            let previews = job.previews.map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let previews {
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                adopt(previews, uid: job.uid, gid: job.gid, directory: true)
            }
            var written = Set<String>()
            let options = ScanOptions(
                photosOnly: job.photosOnly,
                deepScan: job.deep,
                progress: { fraction, message in
                    writeProgress(job, fraction: fraction, message: message)
                },
                isCancelled: { cancelled(job) },
                onUpdate: { files in
                    publish(files, job: job, reader: reader, previews: previews, written: &written)
                },
                stopWhenFound: job.stopNames
            )
            let result = try PhotoRecovery.scan(reader: reader, options: options)
            publish(result.files, job: job, reader: reader, previews: previews, written: &written)
            let manifest = URL(fileURLWithPath: job.manifest)
            try ManifestStore.write(result, to: manifest)
            adopt(manifest, uid: job.uid, gid: job.gid, directory: false)
        }
    }

    private static func publish(
        _ files: [RecoverableFile],
        job: WorkerJob,
        reader: BlockReader,
        previews: URL?,
        written: inout Set<String>
    ) {
        if let previews {
            for file in files {
                guard let name = file.previewFile, !written.contains(file.id) else { continue }
                guard let payload = previewPayload(file, reader: reader) else { continue }
                let url = previews.appendingPathComponent(name)
                if writeThumbnail(payload, to: url) {
                    adopt(url, uid: job.uid, gid: job.gid, directory: false)
                    written.insert(file.id)
                }
            }
        }
        let manifest = URL(fileURLWithPath: job.manifest)
        let result = ScanResult(files: files, filesystem: "", volumeCount: 0, warnings: [], searchedContents: true)
        try? ManifestStore.write(result, to: manifest)
        adopt(manifest, uid: job.uid, gid: job.gid, directory: false)
    }

    private static func recover(_ job: WorkerJob) throws {
        guard let output = job.output else { throw RecoverError.message("Choose a folder for the recovered photos.") }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try withReader(job) { reader in
            let previews = job.previews.map { URL(fileURLWithPath: $0, isDirectory: true) }
            var written = Set<String>()
            let options = ScanOptions(
                photosOnly: true,
                deepScan: true,
                progress: { fraction, message in
                    writeProgress(job, fraction: fraction, message: message)
                },
                isCancelled: { cancelled(job) },
                onUpdate: { files in
                    publish(files, job: job, reader: reader, previews: previews, written: &written)
                },
                stopWhenFound: job.stopNames
            )
            let result = try PhotoRecovery.scan(reader: reader, options: options)
            let wanted = result.files.filter { file in
                job.stopNames.isEmpty || job.stopNames.contains(file.name.uppercased())
            }
            let report = try PhotoRestore.save(wanted.isEmpty ? result.files : wanted, from: reader, to: directory, progress: { fraction, message in
                writeProgress(job, fraction: fraction, message: message)
            }, isCancelled: { cancelled(job) })
            adoptTree(directory, urls: report.saved.map(\.url), uid: job.uid, gid: job.gid)
            if report.saved.isEmpty {
                throw RecoverError.message(report.failed.isEmpty ? "Those four photos were not found on the card." : report.failed.joined(separator: "\n"))
            }
            writeProgress(job, fraction: 1, message: "Saved \(report.saved.map(\.name).joined(separator: ", "))")
        }
    }

    private static func save(_ job: WorkerJob) throws {
        guard let output = job.output else { throw RecoverError.message("Choose a folder for the recovered photos.") }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let result = try ManifestStore.read(from: URL(fileURLWithPath: job.manifest))
        let chosen: [RecoverableFile]
        if job.saveAll {
            chosen = result.files
        } else {
            chosen = result.files.filter { job.ids.contains($0.id) }
        }
        guard !chosen.isEmpty else { throw RecoverError.message("No photos are selected.") }
        if let device = job.device {
            let card = try DiskCatalog.requireCard(identifier: device)
            if DiskCatalog.destinationIsOnCard(directory, cardID: card.id, mounts: card.mountPoints) {
                throw RecoverError.destinationOnCard
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let needed = chosen.reduce(UInt64(0)) { $0 + $1.size } + 50 * 1024 * 1024
        if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available > 0,
           UInt64(available) < needed {
            throw RecoverError.notEnoughSpace(needed: needed, available: UInt64(available))
        }
        try withReader(job) { reader in
            let report = try PhotoRestore.save(chosen, from: reader, to: directory, progress: { fraction, message in
                writeProgress(job, fraction: fraction, message: message)
            }, isCancelled: { cancelled(job) })
            adoptTree(directory, urls: report.saved.map(\.url), uid: job.uid, gid: job.gid)
            if !report.failed.isEmpty && report.saved.isEmpty {
                throw RecoverError.message(report.failed.joined(separator: "\n"))
            }
            let note = report.failed.isEmpty
                ? "Saved \(report.saved.count) \(report.saved.count == 1 ? "file" : "files")."
                : "Saved \(report.saved.count). \(report.failed.count) could not be saved."
            writeProgress(job, fraction: 1, message: note)
            let sidecar = directory.appendingPathComponent("recovery-notes.txt")
            if !report.failed.isEmpty {
                try? report.failed.joined(separator: "\n").write(to: sidecar, atomically: true, encoding: .utf8)
                adopt(sidecar, uid: job.uid, gid: job.gid, directory: false)
            }
        }
    }

    private static func withReader(_ job: WorkerJob, _ body: (BlockReader) throws -> Void) throws {
        if let image = job.image {
            try validateImage(image)
            let reader = try FileBlockReader(path: image, blockSize: 512, alignReads: false)
            try body(reader)
            return
        }
        guard let device = job.device else {
            throw RecoverError.message("Choose a memory card or a disk image.")
        }
        let card = try DiskCatalog.requireCard(identifier: device)
        _ = try open(card)
        writeProgress(job, fraction: nil, message: "Setting the card aside so it can be read safely")
        let mounted = try DiskCatalog.unmount(card.partitionIDs)
        defer { DiskCatalog.mountBack(mounted) }
        let reader = try open(card)
        try body(reader)
    }

    private static func open(_ card: MemoryCard) throws -> FileBlockReader {
        let raw = "/dev/r\(card.id)"
        do {
            return try FileBlockReader(path: raw, blockSize: card.blockSize, alignReads: true, expectedSize: card.size)
        } catch let error as RecoverError {
            if case .needsDiskAccess = error { throw error }
        } catch {
            throw error
        }
        return try FileBlockReader(path: "/dev/\(card.id)", blockSize: card.blockSize, alignReads: false, expectedSize: card.size)
    }

    private static func statusCode(_ error: Error) -> String? {
        guard let error = error as? RecoverError else { return nil }
        if case .needsDiskAccess = error { return "disk-access" }
        return nil
    }

    private static func validateImage(_ path: String) throws {
        if path.hasPrefix("/dev/") {
            throw RecoverError.unsafeDevice("Open a disk image file, not a device.")
        }
        var info = stat()
        if stat(path, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG {
            throw RecoverError.message("That disk image can't be read.")
        }
    }

    private static func previewPayload(_ file: RecoverableFile, reader: BlockReader) -> Data? {
        if file.kind == .raf {
            guard let header = try? PhotoRecovery.read(file, from: reader, maxBytes: 160),
                  header.starts(with: Data("FUJIFILMCCD-RAW ".utf8)),
                  header.count >= 0x5C
            else { return nil }
            let jpegOffset = (UInt32(header[0x54]) << 24) | (UInt32(header[0x55]) << 16) | (UInt32(header[0x56]) << 8) | UInt32(header[0x57])
            let jpegLength = (UInt32(header[0x58]) << 24) | (UInt32(header[0x59]) << 16) | (UInt32(header[0x5A]) << 8) | UInt32(header[0x5B])
            guard jpegLength > 32 else { return nil }
            return try? PhotoRecovery.read(file, from: reader, fileOffset: UInt64(jpegOffset), maxBytes: min(Int(jpegLength), 4 * 1024 * 1024))
        }
        let cap = file.kind == .jpeg ? 1_500_000 : 4_000_000
        return try? PhotoRecovery.read(file, from: reader, maxBytes: min(Int(file.size), cap))
    }

    private static func writeThumbnail(_ data: Data, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func cancelled(_ job: WorkerJob) -> Bool {
        guard let path = job.cancel else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private static func writeProgress(_ job: WorkerJob, fraction: Double?, message: String) {
        guard let path = job.progress else { return }
        let payload: [String: Any] = [
            "fraction": fraction ?? -1,
            "message": message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        adopt(url, uid: job.uid, gid: job.gid, directory: false)
    }

    private static func writeStatus(_ job: WorkerJob, ok: Bool, message: String?, cancelled: Bool, code: String? = nil) {
        guard let path = job.status else { return }
        var payload: [String: Any] = ["ok": ok, "cancelled": cancelled]
        if let message { payload["error"] = message }
        if let code { payload["code"] = code }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        adopt(url, uid: job.uid, gid: job.gid, directory: false)
    }

    private static func adopt(_ url: URL, uid: uid_t, gid: gid_t, directory: Bool) {
        _ = chown(url.path, uid, gid)
        _ = chmod(url.path, directory ? 0o755 : 0o644)
    }

    private static func adoptTree(_ root: URL, urls: [URL], uid: uid_t, gid: gid_t) {
        adopt(root, uid: uid, gid: gid, directory: true)
        for url in urls {
            adopt(url, uid: uid, gid: gid, directory: false)
            var parent = url.deletingLastPathComponent()
            while parent.path != root.path && parent.path.hasPrefix(root.path) {
                adopt(parent, uid: uid, gid: gid, directory: true)
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
        }
    }
}

enum Admin {
    static func run(_ arguments: [String]) throws {
        let program = executablePath()
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("datarecover-\(UUID().uuidString).sh")
        let line = ([program] + arguments).map(shell).joined(separator: " ")
        let body = "#!/bin/bash\nset -euo pipefail\n\(line)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        _ = chmod(script.path, 0o755)
        defer { try? FileManager.default.removeItem(at: script) }
        let source = "do shell script \"/bin/bash \(script.path)\" with prompt \"Recover Photos needs to read the SD card to copy off DSCF0003, DSCF0004, DSCF0005, and DSCF0007. The card will not be changed.\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("User canceled") || text.contains("(-128)") {
                throw RecoverError.cancelled
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecoverError.message(trimmed.isEmpty ? "macOS didn't allow the card to be read." : trimmed)
        }
    }

    private static func executablePath() -> String {
        if let path = Bundle.main.executableURL?.path, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).path
    }

    static func shell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
