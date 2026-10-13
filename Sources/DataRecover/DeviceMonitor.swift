import DiskArbitration
import Foundation

/// Calls back when a disk is plugged in, removed, mounted or unmounted, so the device list never needs a refresh button.
final class DeviceMonitor {
    private let session: DASession?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        DARegisterDiskAppearedCallback(session, nil, changed, context)
        DARegisterDiskDisappearedCallback(session, nil, changed, context)
        let described: DADiskDescriptionChangedCallback = { _, _, context in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, described, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    /// Disks arrive as a burst of events (whole disk, then each partition, then mounts). Wait for it to settle.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
