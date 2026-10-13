import AppKit
import Darwin
import DataRecoverCore
import Foundation

@MainActor
final class RecoverModel: ObservableObject {
    @Published var cards: [MemoryCard] = []
    @Published var selectedCardID: String?
    @Published var imageURL: URL?
    @Published var folder: URL
    @Published var photosOnly = true
    @Published var deepScan = false
    @Published var files: [RecoverableFile] = []
    @Published var selection = Set<String>()
    @Published var warnings: [String] = []
    @Published var filesystem = ""
    @Published var busy = false
    @Published var progress: Double?
    @Published var status = ""
    @Published var errorText: String?
    @Published var savedMessage: String?
    @Published var thumbs: [String: NSImage] = [:]
    @Published var didScan = false
    @Published var needsDiskAccess = false

    private var workDirectory: URL?
    private var poll: Task<Void, Never>?

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Recovered Photos", isDirectory: true)
        refresh()
    }

    var selectedCard: MemoryCard? {
        cards.first { $0.id == selectedCardID }
    }

    var sourceTitle: String {
        if let imageURL { return imageURL.lastPathComponent }
        return selectedCard?.name ?? "No card"
    }

    var sourceDetail: String {
        if let imageURL { return imageURL.path }
        return selectedCard?.summary ?? "Insert the SD card, then click Refresh."
    }

    var selectedFiles: [RecoverableFile] {
        files.filter { selection.contains($0.id) }
    }

    var selectedByteCount: UInt64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    func refresh() {
        Task.detached {
            let found = (try? DiskCatalog.cards()) ?? []
            await MainActor.run {
                self.cards = found
                if let selected = self.selectedCardID, found.contains(where: { $0.id == selected }) {
                    return
                }
                self.selectedCardID = found.first(where: \.isCamera)?.id ?? found.first?.id
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Recovered photos will be saved in this folder."
        panel.directoryURL = folder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.prompt = "Open"
        panel.message = "Open a disk image of the card if you already made one."
        if panel.runModal() == .OK {
            imageURL = panel.url
        }
    }

    func clearImage() {
        imageURL = nil
    }

    func scan() {
        savedMessage = nil
        errorText = nil
        needsDiskAccess = false
        startJob(action: "scan", ids: [], saveAll: false)
    }

    func saveSelected() {
        save(ids: selection, saveAll: false)
    }

    func saveAll() {
        save(ids: [], saveAll: true)
    }

    func cancel() {
        guard let workDirectory else { return }
        FileManager.default.createFile(atPath: workDirectory.appendingPathComponent("cancel").path, contents: Data())
        status = "Canceling…"
    }

    func revealFolder() {
        NSWorkspace.shared.open(folder)
    }

    private func save(ids: Set<String>, saveAll: Bool) {
        guard didScan, manifestExists else {
            errorText = "Look for deleted photos before saving."
            return
        }
        if !saveAll && ids.isEmpty {
            errorText = "Select at least one photo."
            return
        }
        savedMessage = nil
        startJob(action: "save", ids: ids, saveAll: saveAll)
    }

    private var manifestExists: Bool {
        guard let workDirectory else { return false }
        return FileManager.default.fileExists(atPath: workDirectory.appendingPathComponent("manifest.json").path)
    }

    private func startJob(action: String, ids: Set<String>, saveAll: Bool) {
        if busy { return }
        if action == "scan" && imageURL == nil && selectedCard == nil {
            errorText = "Insert the SD card, or open a disk image."
            return
        }
        busy = true
        progress = nil
        status = action == "scan" ? "Looking for deleted photos…" : "Saving photos…"
        if action == "scan" {
            files = []
            selection = []
            thumbs = [:]
            warnings = []
            didScan = false
        }
        let folder = self.folder
        let image = self.imageURL
        let card = self.selectedCard
        let photosOnly = self.photosOnly
        let deepScan = self.deepScan
        let directory = prepareWork(resetScan: action == "scan")
        let job = WorkerJob(
            action: action,
            device: image == nil ? card?.id : nil,
            image: image?.path,
            manifest: directory.appendingPathComponent("manifest.json").path,
            previews: directory.appendingPathComponent("previews", isDirectory: true).path,
            output: folder.path,
            progress: directory.appendingPathComponent("progress.json").path,
            cancel: directory.appendingPathComponent("cancel").path,
            status: directory.appendingPathComponent("status.json").path,
            uid: getuid(),
            gid: getgid(),
            deep: deepScan,
            photosOnly: photosOnly,
            saveAll: saveAll,
            ids: ids
        )
        beginPolling(directory.appendingPathComponent("progress.json"))
        Task.detached {
            do {
                if image == nil {
                    try Admin.run(["worker"] + job.commandArguments())
                } else {
                    try WorkerLogic.run(job)
                }
                await MainActor.run { self.finish(directory: directory, action: action) }
            } catch {
                await MainActor.run {
                    self.stopPolling()
                    self.busy = false
                    let blocked = self.diskAccessDenied(error, in: directory)
                    if blocked {
                        self.needsDiskAccess = true
                        self.status = "macOS is blocking access to the card."
                    } else if let recover = error as? RecoverError, case .cancelled = recover {
                        self.status = "Canceled."
                        self.loadManifest(in: directory)
                    } else {
                        self.status = ""
                        self.errorText = error.localizedDescription
                        self.loadManifest(in: directory)
                    }
                }
            }
        }
    }

    private func finish(directory: URL, action: String) {
        stopPolling()
        busy = false
        let statusURL = directory.appendingPathComponent("status.json")
        let status = (try? JSONDecoder().decode(JobStatus.self, from: Data(contentsOf: statusURL)))
        if status?.code == "disk-access" {
            needsDiskAccess = true
            self.status = "macOS is blocking access to the card."
            progress = nil
            return
        }
        if status?.cancelled == true {
            self.status = "Canceled."
        } else if status?.ok == false {
            errorText = status?.error ?? "The card could not be read."
        }
        let progressNote = progressMessage(in: directory)
        if action == "scan" || status?.ok == true {
            loadManifest(in: directory)
        }
        if action == "save", status?.ok != false, errorText == nil {
            savedMessage = progressNote ?? "Saved the photos."
            self.status = savedMessage ?? ""
        }
        progress = nil
    }

    private func progressMessage(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("progress.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String,
              message.hasPrefix("Saved")
        else { return nil }
        return message
    }

    private func loadManifest(in directory: URL) {
        let url = directory.appendingPathComponent("manifest.json")
        guard let result = try? ManifestStore.read(from: url) else { return }
        files = result.files
        filesystem = result.filesystem
        warnings = result.warnings
        didScan = true
        selection = Set(result.files.filter { $0.headerLooksValid != false && $0.complete }.map(\.id))
        loadThumbs(in: directory.appendingPathComponent("previews", isDirectory: true))
        if result.files.isEmpty && !busy {
            status = emptyMessage(result)
        } else if !busy {
            status = "Found \(result.files.count) deleted \(result.files.count == 1 ? "photo" : "photos")."
        }
    }

    private func emptyMessage(_ result: ScanResult) -> String {
        if result.searchedContents {
            return "No photos were found. Their space on the card may already have been reused by newer shots."
        }
        if result.volumeCount == 0 {
            return "This doesn't look like a camera card."
        }
        return "No deleted photos were found."
    }

    func allowDiskAccess() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for text in urls {
            guard let url = URL(string: text) else { continue }
            NSWorkspace.shared.open(url)
            break
        }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func diskAccessDenied(_ error: Error, in directory: URL) -> Bool {
        let statusURL = directory.appendingPathComponent("status.json")
        if let status = try? JSONDecoder().decode(JobStatus.self, from: Data(contentsOf: statusURL)), status.code == "disk-access" {
            return true
        }
        if let recover = error as? RecoverError, case .needsDiskAccess = recover { return true }
        let text = error.localizedDescription
        return text.contains("Full Disk Access") || text.contains("Operation not permitted")
    }

    private func loadThumbs(in directory: URL) {
        let files = self.files
        Task.detached {
            var loaded: [String: NSImage] = [:]
            for file in files {
                guard let name = file.previewFile else { continue }
                let url = directory.appendingPathComponent(name)
                if let image = NSImage(contentsOf: url) {
                    loaded[file.id] = image
                }
            }
            let snapshot = loaded
            await MainActor.run { self.thumbs = snapshot }
        }
    }

    private func prepareWork(resetScan: Bool) -> URL {
        if resetScan, let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
            self.workDirectory = nil
        }
        if let workDirectory { return workDirectory }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("datarecover-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("previews", isDirectory: true), withIntermediateDirectories: true)
        workDirectory = url
        return url
    }

    private func beginPolling(_ url: URL) {
        poll?.cancel()
        poll = Task { @MainActor in
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: url),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let message = object["message"] as? String {
                        self.status = message
                    }
                    if let number = object["fraction"] as? NSNumber {
                        let value = number.doubleValue
                        self.progress = value < 0 ? nil : value
                    }
                    self.loadManifest(in: url.deletingLastPathComponent())
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }
}

private struct JobStatus: Decodable {
    var ok: Bool
    var cancelled: Bool?
    var error: String?
    var code: String?
}
