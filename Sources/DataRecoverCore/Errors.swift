import Foundation

public enum RecoverError: Error, LocalizedError {
    case readFailed(String)
    case unsafeDevice(String)
    case destinationOnCard
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case needsDiskAccess
    case cancelled
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let detail):
            return detail
        case .unsafeDevice(let detail):
            return detail
        case .destinationOnCard:
            return "Choose a folder on this Mac. Recovered photos can't be saved onto the same card."
        case .notEnoughSpace(let needed, let available):
            return "The folder you chose doesn't have enough free space. Recovery needs about \(ByteText.string(needed)) and \(ByteText.string(available)) is free."
        case .needsDiskAccess:
            return "macOS is blocking this app from reading the card. Allow Recover Photos in Full Disk Access, then scan again."
        case .cancelled:
            return "Canceled."
        case .message(let text):
            return text
        }
    }
}

public enum ByteText {
    public static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
