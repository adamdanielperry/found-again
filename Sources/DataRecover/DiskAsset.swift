import AVFoundation
import DataRecoverCore
import Foundation
import UniformTypeIdentifiers

/// Lets AVFoundation read a deleted video straight off the disk, a byte range at a time,
/// so thumbnails and playback never need the whole file copied first.
final class DiskAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "recovered-file"

    let file: RecoverableFile
    let reader: BlockReader
    let asset: AVURLAsset
    private let queue = DispatchQueue(label: "DiskAsset", qos: .userInitiated)

    /// Nil for formats AVFoundation can't play, such as AVI or MKV.
    init?(file: RecoverableFile, reader: BlockReader) {
        guard Self.contentType(for: file) != nil,
              let url = URL(string: "\(Self.scheme)://\(UUID().uuidString)/\(file.kind.fileExtension)")
        else { return nil }
        self.file = file
        self.reader = reader
        self.asset = AVURLAsset(url: url)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    static func contentType(for file: RecoverableFile) -> String? {
        switch file.kind {
        case .mov: return UTType.quickTimeMovie.identifier
        case .mp4: return UTType.mpeg4Movie.identifier
        case .m4v: return "com.apple.m4v-video"
        case .threegp: return "public.3gpp"
        case .m4a: return UTType.mpeg4Audio.identifier
        default: return nil
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.contentType(for: file)
            info.contentLength = Int64(file.size)
            info.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            var offset = UInt64(max(request.currentOffset, request.requestedOffset))
            let end: UInt64 = request.requestsAllDataToEndOfResource
                ? file.size
                : min(file.size, UInt64(request.requestedOffset) + UInt64(request.requestedLength))
            while offset < end {
                if loadingRequest.isCancelled { return true }
                let count = Int(min(end - offset, 1024 * 1024))
                guard let chunk = try? RecoveryEngine.read(file, from: reader, fileOffset: offset, maxBytes: count), !chunk.isEmpty else {
                    loadingRequest.finishLoading(with: RecoverError.readFailed("Couldn't read the video from the disk."))
                    return true
                }
                request.respond(with: chunk)
                offset += UInt64(chunk.count)
            }
        }
        loadingRequest.finishLoading()
        return true
    }

    /// A frame about a second in, or the first frame for short clips.
    func thumbnail(maxPixels: CGFloat) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let done = DispatchSemaphore(value: 0)
        var result: CGImage?
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { image, _, _ in
            result = image
            done.signal()
        }
        if done.wait(timeout: .now() + 20) == .timedOut {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return result
    }
}
