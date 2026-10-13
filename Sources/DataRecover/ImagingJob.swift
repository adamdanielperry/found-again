import AppKit
import DataRecoverCore
import Foundation
import Observation

/// Copies a whole card or drive into a disk image, so a failing disk only has to be read once.
@MainActor
@Observable
final class ImagingJob: Identifiable {
    enum State {
        case running
        case done(DiskImager.Progress)
        case failed(String)
    }

    let id = UUID()
    let device: Device
    let destination: URL
    private(set) var state: State = .running
    private(set) var progress = DiskImager.Progress(bytesDone: 0, bytesTotal: 0, unreadable: 0)
    private(set) var startedAt = Date()
    @ObservationIgnored private let stopFlag = StopFlag()

    init(device: Device, destination: URL) {
        self.device = device
        self.destination = destination
        self.progress.bytesTotal = device.size
    }

    var secondsRemaining: TimeInterval? {
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 5, progress.bytesDone > 0, progress.bytesTotal > progress.bytesDone else { return nil }
        return Double(progress.bytesTotal - progress.bytesDone) / (Double(progress.bytesDone) / elapsed)
    }

    /// Runs on a background queue with a reader that is already open.
    func start(reader: BlockReader, unmounted: Bool) {
        startedAt = Date()
        let flag = stopFlag
        let device = self.device
        let destination = self.destination
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<DiskImager.Progress, Error>
            do {
                outcome = .success(try DiskImager.copy(reader, to: destination, progress: { value in
                    DispatchQueue.main.async { self?.progress = value }
                }, isCancelled: { flag.isSet }))
            } catch {
                outcome = .failure(error)
            }
            if unmounted { DeviceCatalog.mount(device) }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let value):
                    self?.progress = value
                    self?.state = .done(value)
                case .failure(let error):
                    if let recover = error as? RecoverError, recover == .cancelled {
                        self?.state = .failed("Stopped. The partial copy was removed.")
                    } else {
                        self?.state = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stop() {
        stopFlag.set()
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}
