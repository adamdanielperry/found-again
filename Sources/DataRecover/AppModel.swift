import AppKit
import DataRecoverCore
import Foundation
import Observation
import UniformTypeIdentifiers

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var devices: [Device] = []
    private(set) var loadedDevices = false
    private(set) var session: RecoverySession?
    /// The device whose password prompt or unmount is in progress.
    private(set) var opening: String?
    var alert: AppAlert?
    var showMacGuide = false
    var showPrivacyHelp = false

    @ObservationIgnored private var monitor: DeviceMonitor?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    init() {
        refresh()
        monitor = DeviceMonitor { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        // A change during a refresh (a card finishing mounting, say) gets its own pass afterwards.
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        refreshAgain = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = (try? DeviceCatalog.devices()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.loadedDevices = true
                if self.devices != found {
                    self.devices = found
                }
                if self.refreshAgain { self.refresh() }
            }
        }
    }

    func open(_ device: Device) {
        guard opening == nil, session == nil else { return }
        opening = device.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Touching the volume first lets macOS ask about removable-volume access now, in the app's name.
            for mount in device.mountPoints {
                _ = try? FileManager.default.contentsOfDirectory(atPath: mount)
            }
            do {
                let reader = try DiskAccess.open(device)
                // Stop macOS writing indexes onto the disk while it's read. If it's busy, read it anyway.
                let unmounted = (try? DeviceCatalog.unmount(device)) ?? false
                DispatchQueue.main.async {
                    self?.begin(RecoverySession(source: .device(device), reader: reader, unmountedForScan: unmounted))
                }
            } catch let failure as DiskAccess.Failure {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.opening = nil
                    switch failure {
                    case .cancelled:
                        break
                    case .privacy:
                        self.showPrivacyHelp = true
                    default:
                        self.alert = AppAlert(title: "Couldn't read “\(device.name)”", message: failure.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.opening = nil
                    self?.alert = AppAlert(title: "Couldn't read “\(device.name)”", message: error.localizedDescription)
                }
            }
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.prompt = "Scan"
        panel.message = "Choose a disk image of a card or drive, such as a .dmg, .img or .iso file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(image: url)
    }

    func open(image url: URL) {
        guard session == nil else { return }
        do {
            let reader = try DiskAccess.open(image: url)
            begin(RecoverySession(source: .image(url), reader: reader, unmountedForScan: false))
        } catch {
            alert = AppAlert(title: "Couldn't open that disk image", message: error.localizedDescription)
        }
    }

    private func begin(_ session: RecoverySession) {
        opening = nil
        self.session = session
        session.start()
    }

    func closeSession() {
        session?.close()
        session = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
        }
    }

    func eject(_ device: Device) {
        session?.close()
        session = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = DeviceCatalog.eject(device)
            DispatchQueue.main.async {
                if !ok {
                    self?.alert = AppAlert(title: "Couldn't eject “\(device.name)”", message: "Something is still using it. Close any windows showing its files, then eject it from Finder.")
                }
                self?.refresh()
            }
        }
    }

    func prepareToQuit() {
        session?.close()
    }
}
