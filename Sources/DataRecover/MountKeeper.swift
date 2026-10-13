import DataRecoverCore
import Foundation

/// Unmounts disks for reading and puts them back, remembering what it unmounted
/// so a crash or force-quit never leaves a card hidden from Finder.
enum MountKeeper {
    private static let key = "DisksUnmountedForScan"
    private static let lock = NSLock()

    /// Unmounts the disk if it's mounted. Returns true when it was. A busy disk is read while mounted.
    static func unmountForReading(_ device: Device) -> Bool {
        let unmounted = (try? DeviceCatalog.unmount(device)) ?? false
        if unmounted { record(device.id, identity: identity(device)) }
        return unmounted
    }

    static func remount(_ device: Device) {
        DeviceCatalog.mount(device)
        forget(device)
    }

    /// Stops tracking a disk, for example because it's being ejected.
    static func forget(_ device: Device) {
        record(device.id, identity: nil)
    }

    /// Mounts disks a previous run left unmounted, if the same disk is still attached.
    static func remountAfterCrash() {
        let pending = stored()
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for device in (try? DeviceCatalog.devices()) ?? [] where pending[device.id] == identity(device) && !device.isMounted {
                remount(device)
            }
            lock.lock()
            UserDefaults.standard.removeObject(forKey: key)
            lock.unlock()
        }
    }

    /// The hardware's name and size. Display names can't be used: camera names come from folders
    /// that can only be read while the card is mounted.
    private static func identity(_ device: Device) -> String {
        "\(device.media)|\(device.size)"
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func record(_ id: String, identity: String?) {
        lock.lock()
        defer { lock.unlock() }
        var pending = stored()
        pending[id] = identity
        UserDefaults.standard.set(pending, forKey: key)
    }
}
