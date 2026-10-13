import Foundation

public enum RecoverError: Error, LocalizedError, Equatable {
    case readFailed(String)
    case unsafeDevice(String)
    case destinationOnSource
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case accessDenied
    case deviceGone
    case cancelled
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let detail):
            return detail
        case .unsafeDevice(let detail):
            return detail
        case .destinationOnSource:
            return "Choose a folder on another disk. Saving onto the disk you're recovering from could overwrite the files you want back."
        case .notEnoughSpace(let needed, let available):
            return "That folder doesn't have enough free space. Recovery needs about \(ByteText.string(needed)) and \(ByteText.string(available)) is free."
        case .accessDenied:
            return "macOS didn't allow the disk to be read."
        case .deviceGone:
            return "The disk was disconnected. Plug it back in and scan again."
        case .cancelled:
            return "Stopped."
        case .message(let text):
            return text
        }
    }
}

public enum ByteText {
    public static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
