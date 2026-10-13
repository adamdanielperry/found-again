import AppKit
import CDiskAccess
import DataRecoverCore
import Foundation

/// Opens a disk for reading. The password prompt comes from macOS; the app never runs as root
/// and never holds a descriptor that can write.
enum DiskAccess {
    enum Failure: Error, LocalizedError {
        case cancelled
        case denied
        /// macOS privacy settings blocked the read. Removable Volumes or Full Disk Access fixes it.
        case privacy
        case other(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Reading the disk needs your Mac's password. Nothing was changed."
            case .denied:
                return "macOS didn't accept that password, or this account can't approve it. Ask someone with an administrator account to enter theirs."
            case .privacy:
                return "macOS privacy settings are blocking \(Brand.name) from reading the disk."
            case .other(let detail):
                return detail
            }
        }
    }

    /// Prompts for a password, then returns a reader for the whole raw disk.
    static func open(_ device: Device) throws -> FileBlockReader {
        // Disk images you attached yourself are already readable, so don't ask for a password.
        let direct = Darwin.open(device.rawNode, O_RDONLY)
        if direct >= 0 {
            return try FileBlockReader(descriptor: direct, blockSize: device.blockSize, alignReads: true, expectedSize: device.size)
        }
        if errno == EPERM {
            throw Failure.privacy
        }
        let prompt = "\(Brand.name) needs permission to read “\(device.name)”. It only reads; nothing on the disk is changed."
        var fd: Int32 = -1
        var detail: Int32 = 0
        let result = device.rawNode.withCString { path in
            prompt.withCString { text in
                disk_access_open_readonly(path, text, &fd, &detail)
            }
        }
        switch result {
        case DiskAccessOK:
            return try FileBlockReader(descriptor: fd, blockSize: device.blockSize, alignReads: true, expectedSize: device.size)
        case DiskAccessCancelled:
            throw Failure.cancelled
        case DiskAccessDenied:
            throw Failure.denied
        case DiskAccessPrivacyBlocked:
            throw Failure.privacy
        default:
            throw Failure.other("macOS couldn't open the disk (code \(detail)). Unplug it, plug it back in, and try again.")
        }
    }

    /// Opens a disk image, or a disk image's device when testing.
    static func open(image url: URL) throws -> FileBlockReader {
        let path = url.path
        if path.hasPrefix("/dev/") {
            throw RecoverError.unsafeDevice("Open a disk image file, not a device.")
        }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw RecoverError.message("That file can't be read as a disk image.")
        }
        return try FileBlockReader(path: path)
    }

    /// Opens the privacy pane where Removable Volumes and Full Disk Access are switched on.
    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }
}
