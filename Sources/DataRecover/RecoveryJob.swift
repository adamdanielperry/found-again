import AppKit
import DataRecoverCore
import Foundation
import Observation

/// Copies chosen files off the disk into a folder on this Mac.
@MainActor
@Observable
final class RecoveryJob: Identifiable {
    enum State {
        case ready
        case running
        case done(RestoreReport)
        case failed(String)
    }

    let id = UUID()
    let files: [RecoverableFile]
    let sessionTitle: String
    private let reader: BlockReader
    private let device: Device?

    var destination: URL { didSet { validate() } }
    var keepFolders = true
    private(set) var state: State = .ready
    private(set) var fraction: Double = 0
    private(set) var currentName = ""
    /// Why the destination can't be used, if it can't.
    private(set) var problem: String?
    private(set) var checking = false
    private(set) var freeSpace: UInt64?

    @ObservationIgnored private let stopFlag = StopFlag()

    init(files: [RecoverableFile], session: RecoverySession) {
        self.files = files
        self.sessionTitle = session.title
        self.reader = session.reader
        self.device = session.device
        self.destination = Self.defaultDestination(for: files, title: session.title)
        validate()
    }

    var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    var hasFolders: Bool { files.contains { !$0.folder.isEmpty } }
    var canStart: Bool { problem == nil && !checking }

    static func defaultDestination(for files: [RecoverableFile], title: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let visual = files.filter { [.photo, .raw, .video].contains($0.category) }.count
        var base = home.appendingPathComponent(visual * 2 >= files.count ? "Pictures" : "Documents", isDirectory: true)
        // Lets tests recover somewhere disposable instead of ~/Pictures.
        if let override = ProcessInfo.processInfo.environment["RECOVER_DEFAULT_DESTINATION"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        }
        let stamp: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
            return formatter.string(from: Date())
        }()
        let clean = OutputPath.relative(from: title).replacingOccurrences(of: "/", with: " ")
        return base
            .appendingPathComponent(Brand.recoveredFolderName, isDirectory: true)
            .appendingPathComponent("\(clean.isEmpty ? "Disk" : clean) \(stamp)", isDirectory: true)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Recover Here"
        panel.message = "Choose a folder on this Mac or another drive — not on the disk you're recovering from."
        panel.directoryURL = destination.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        }
    }

    private func validate() {
        checking = true
        problem = nil
        let target = destination
        let device = self.device
        let needed = totalBytes + 50 * 1024 * 1024
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var problem: String?
            if let device, DeviceCatalog.destination(target, isOn: device) {
                problem = RecoverError.destinationOnSource.localizedDescription
            }
            var probe = target
            while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
                probe.deleteLastPathComponent()
            }
            let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
            if problem == nil, let free, free < needed {
                problem = RecoverError.notEnoughSpace(needed: needed, available: free).localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, self.destination == target else { return }
                self.problem = problem
                self.freeSpace = free
                self.checking = false
            }
        }
    }

    func start() {
        guard canStart else { return }
        state = .running
        fraction = 0
        let reader = self.reader
        let flag = stopFlag
        let folder = destination
        let chosen = keepFolders ? files : files.map { file -> RecoverableFile in
            var flat = file
            flat.originalPath = file.name
            return flat
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try PhotoRestore.save(chosen, from: reader, to: folder, progress: { fraction, name in
                    DispatchQueue.main.async {
                        self?.fraction = fraction ?? 0
                        self?.currentName = name
                    }
                }, isCancelled: { flag.isSet })
                Self.writeNotes(report, in: folder)
                DispatchQueue.main.async { self?.state = .done(report) }
            } catch {
                DispatchQueue.main.async {
                    if let recover = error as? RecoverError, recover == .cancelled {
                        self?.state = .failed("Stopped. Files copied before you stopped are in the folder.")
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

    /// A plain note in the folder when some files couldn't be saved or had unreadable parts.
    nonisolated private static func writeNotes(_ report: RestoreReport, in folder: URL) {
        var lines: [String] = []
        let damaged = report.saved.filter { $0.unreadableBytes > 0 }
        if !report.failed.isEmpty {
            lines.append("These files couldn't be saved:")
            lines.append(contentsOf: report.failed.map { "  \($0)" })
            lines.append("")
        }
        if !damaged.isEmpty {
            lines.append("Parts of these files couldn't be read from the disk and were filled with blanks. They may open with gaps or glitches:")
            lines.append(contentsOf: damaged.map { "  \($0.name) (\(ByteText.string($0.unreadableBytes)) unreadable)" })
        }
        guard !lines.isEmpty else { return }
        let url = folder.appendingPathComponent("About these files.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
