import AppKit
import DataRecoverCore
import Foundation
import Observation

/// One open disk: the scan, its results, and what the person has picked to recover.
@MainActor
@Observable
final class RecoverySession: Identifiable {
    enum Source {
        case device(Device)
        case image(URL)
    }

    enum State: Equatable {
        case scanning
        case finished
        case stopped
        case failed(String)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case date = "Date"
        case name = "Name"
        case size = "Size"
        var id: String { rawValue }
    }

    struct Section: Identifiable {
        var id: String
        var title: String
        var files: [RecoverableFile]
    }

    let id = UUID()
    let source: Source
    @ObservationIgnored let reader: BlockReader
    /// True when the disk's volumes were unmounted for the scan and should come back afterwards.
    let unmountedForScan: Bool

    private(set) var files: [RecoverableFile] = []
    private(set) var state: State = .scanning
    private(set) var progress = ScanProgress(phase: .fileRecords)
    private(set) var warnings: [String] = []
    private(set) var counts: [FileCategory: Int] = [:]
    private(set) var sections: [Section] = []
    private(set) var visibleCount = 0
    private(set) var contentsStartedAt: Date?
    let startedAt = Date()

    var selection = Set<String>()
    /// Files already copied off the disk in this session, shown with a tick.
    private(set) var recoveredIDs = Set<String>()
    var category: FileCategory? { didSet { rebuild() } }
    var search = "" { didSet { rebuild() } }
    var sort: Sort = .date { didSet { rebuild() } }
    var hideDamaged = false { didSet { rebuild() } }

    @ObservationIgnored private let stopFlag = StopFlag()
    @ObservationIgnored private var pendingRebuild = false
    @ObservationIgnored private var knownIDs = Set<String>()
    @ObservationIgnored let thumbnails: ThumbnailCache

    init(source: Source, reader: BlockReader, unmountedForScan: Bool) {
        self.source = source
        self.reader = reader
        self.unmountedForScan = unmountedForScan
        self.thumbnails = ThumbnailCache(reader: reader)
    }

    var title: String {
        switch source {
        case .device(let device): return device.name
        case .image(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    var device: Device? {
        if case .device(let device) = source { return device }
        return nil
    }

    var isScanning: Bool { state == .scanning }

    /// Everything the filters let through, in grid order. Rebuilt with `sections`.
    private(set) var visibleFiles: [RecoverableFile] = []
    private(set) var visibleBytes: UInt64 = 0

    var selectedFiles: [RecoverableFile] {
        files.filter { selection.contains($0.id) }
    }

    /// Seconds left in the deep scan, once there's enough history to estimate.
    var secondsRemaining: TimeInterval? {
        guard isScanning, progress.phase == .contents, let started = contentsStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 6, progress.bytesDone > 0, progress.bytesTotal > progress.bytesDone else { return nil }
        let rate = Double(progress.bytesDone) / elapsed
        return Double(progress.bytesTotal - progress.bytesDone) / rate
    }

    // MARK: Scanning

    func start() {
        let reader = self.reader
        let flag = stopFlag
        let options = ScanOptions(
            deepScan: true,
            progress: { [weak self] value in
                DispatchQueue.main.async { self?.update(progress: value) }
            },
            isCancelled: { flag.isSet },
            onFound: { [weak self] batch in
                DispatchQueue.main.async { self?.append(batch) }
            }
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<ScanResult, Error>
            do {
                outcome = .success(try RecoveryEngine.scan(reader: reader, options: options))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { self?.finish(outcome) }
        }
    }

    func stop() {
        stopFlag.set()
    }

    private func update(progress value: ScanProgress) {
        if value.phase == .contents && contentsStartedAt == nil {
            contentsStartedAt = Date()
        }
        if state == .scanning {
            progress = value
        }
    }

    private func append(_ batch: [RecoverableFile]) {
        let fresh = batch.filter { knownIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        files.append(contentsOf: fresh)
        for file in fresh {
            counts[file.category, default: 0] += 1
        }
        scheduleRebuild()
    }

    private func finish(_ outcome: Result<ScanResult, Error>) {
        switch outcome {
        case .success(let result):
            append(result.files)
            warnings = result.warnings
            state = stopFlag.isSet ? .stopped : .finished
        case .failure(let error):
            if let recover = error as? RecoverError, recover == .cancelled {
                state = .stopped
            } else {
                state = .failed(error.localizedDescription)
            }
        }
        progress = ScanProgress(phase: .finished, bytesDone: progress.bytesTotal, bytesTotal: progress.bytesTotal, found: files.count)
        rebuild()
    }

    // MARK: Filtering

    /// Batches arrive several times a second during a scan. Regroup at most twice a second.
    private func scheduleRebuild() {
        guard !pendingRebuild else { return }
        pendingRebuild = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pendingRebuild = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = files.filter { file in
            if let category, file.category != category { return false }
            if hideDamaged && file.quality == .damaged { return false }
            if !query.isEmpty && !file.name.lowercased().contains(query) && !file.originalPath.lowercased().contains(query) {
                return false
            }
            return true
        }
        visibleCount = list.count
        switch sort {
        case .date:
            list.sort { ($0.modified ?? .distantPast, $0.name) > ($1.modified ?? .distantPast, $1.name) }
            sections = Self.groupByDay(list)
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            sections = list.isEmpty ? [] : [Section(id: "all", title: "", files: list)]
        case .size:
            list.sort { $0.size > $1.size }
            sections = list.isEmpty ? [] : [Section(id: "all", title: "", files: list)]
        }
        // In display order, so stepping through previews follows the grid.
        visibleFiles = sections.flatMap(\.files)
        visibleBytes = visibleFiles.reduce(0) { $0 + $1.size }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func groupByDay(_ list: [RecoverableFile]) -> [Section] {
        let calendar = Calendar.current
        var sections: [Section] = []
        var undated: [RecoverableFile] = []
        for file in list {
            guard let date = file.modified else {
                undated.append(file)
                continue
            }
            let day = calendar.startOfDay(for: date)
            let key = String(Int(day.timeIntervalSince1970))
            if sections.last?.id == key {
                sections[sections.count - 1].files.append(file)
            } else {
                sections.append(Section(id: key, title: dayFormatter.string(from: day), files: [file]))
            }
        }
        if !undated.isEmpty {
            sections.append(Section(id: "undated", title: "No date", files: undated))
        }
        return sections
    }

    // MARK: Selection

    func toggle(_ file: RecoverableFile) {
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else {
            selection.insert(file.id)
        }
    }

    func selectAllVisible() {
        selection.formUnion(visibleFiles.map(\.id))
    }

    func selectNone() {
        selection.removeAll()
    }

    func markRecovered(_ files: [RecoverableFile]) {
        let ids = files.map(\.id)
        recoveredIDs.formUnion(ids)
        selection.subtract(ids)
    }

    /// What the Recover button will act on: the selection, or everything showing when nothing is selected.
    var recoverTargets: [RecoverableFile] {
        selection.isEmpty ? visibleFiles : selectedFiles
    }

    // MARK: Clean-up

    enum Remount {
        /// In the background, when the person moves on to another disk.
        case later
        /// Before returning, when the app is about to quit and background work would be cut off.
        case now
        /// Not at all, because the disk is about to be ejected.
        case never
    }

    /// Gives the disk back to macOS. Called when the person leaves this disk, ejects it or quits.
    func close(remount: Remount = .later) {
        stopFlag.set()
        thumbnails.clear()
        QuickLookExport.cleanUp()
        guard unmountedForScan, let device else { return }
        switch remount {
        case .later:
            DispatchQueue.global(qos: .utility).async { MountKeeper.remount(device) }
        case .now:
            MountKeeper.remount(device)
        case .never:
            MountKeeper.forget(device)
        }
    }
}

/// A flag the scan thread polls. Cheap enough to check at every chunk.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
