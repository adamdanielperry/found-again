import DataRecoverCore
import QuickLook
import SwiftUI

/// Scanning and results share one screen: files appear as they're found and can be recovered at any point.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: RecoverySession
    @State private var job: RecoveryJob?
    @State private var previewURL: URL?
    @State private var previewing: RecoverableFile?
    @State private var tileSize: Double = 150
    @State private var confirmLeave = false

    var body: some View {
        NavigationSplitView {
            SessionSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if session.isScanning {
                        ScanStatusBar(session: session)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    RecoverBar(session: session) {
                        job = RecoveryJob(files: session.recoverTargets, session: session)
                    }
                }
                .navigationTitle(session.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .searchable(text: $session.search, placement: .toolbar, prompt: "Search names")
        }
        .sheet(item: $job) { job in
            RecoverSheet(job: job, device: session.device) { eject in
                if case .done(let report) = job.state, !report.saved.isEmpty {
                    session.markRecovered(job.files)
                }
                self.job = nil
                if eject, let device = session.device {
                    model.eject(device)
                }
            }
        }
        .sheet(item: $previewing) { file in
            PreviewSheet(session: session, file: file) { chosen in
                previewing = nil
                // Let the preview finish closing before the next sheet opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    job = RecoveryJob(files: [chosen], session: session)
                }
            } openElsewhere: { chosen in
                previewing = nil
                quickLook(chosen)
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(leaveTitle, isPresented: $confirmLeave) {
            Button(session.isScanning ? "Stop and Choose Another Disk" : "Choose Another Disk", role: .destructive) {
                model.closeSession()
            }
        } message: {
            Text(leaveMessage)
        }
    }

    private var leaveTitle: String {
        session.isScanning ? "Stop scanning “\(session.title)”?" : "Leave “\(session.title)”?"
    }

    private var leaveMessage: String {
        if session.recoveredIDs.isEmpty {
            return "The list of found files will be cleared, and nothing has been recovered yet. You can scan again later."
        }
        return "The list of found files will be cleared. Files you've recovered stay where you saved them."
    }

    private var subtitle: String {
        let count = session.files.count
        switch session.state {
        case .scanning: return count == 0 ? "Scanning…" : "Scanning… \(count.formatted()) found"
        case .finished: return "\(count.formatted()) \(count == 1 ? "file" : "files") found"
        case .stopped: return "Stopped · \(count.formatted()) found"
        case .failed: return "Scan failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.sections.isEmpty {
            EmptyResults(session: session)
        } else {
            FileGrid(session: session, tileSize: tileSize) { file in
                preview(file)
            } recover: { file in
                job = RecoveryJob(files: [file], session: session)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if session.isScanning || !session.files.isEmpty {
                    confirmLeave = true
                } else {
                    model.closeSession()
                }
            } label: {
                Label("All Disks", systemImage: "chevron.backward")
            }
            .help("Choose another disk")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Slider(value: $tileSize, in: 100...260)
                .frame(width: 90)
                .help("Thumbnail size")
            Menu {
                Picker("Sort By", selection: $session.sort) {
                    ForEach(RecoverySession.Sort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                Toggle("Hide Damaged Files", isOn: $session.hideDamaged)
                Divider()
                Button("Select All Showing") { session.selectAllVisible() }
                Button("Select None") { session.selectNone() }
                    .disabled(session.selection.isEmpty)
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    /// Photos and playable videos open in the app's own viewer, read straight off the disk.
    /// Everything else goes through Quick Look, which needs a temporary copy.
    private func preview(_ file: RecoverableFile) {
        if file.kind.hasImagePreview || ThumbnailCache.isPlayableVideo(file) {
            previewing = file
        } else {
            quickLook(file)
        }
    }

    private func quickLook(_ file: RecoverableFile) {
        let reader = session.reader
        DispatchQueue.global(qos: .userInitiated).async {
            let url = QuickLookExport.export(file, reader: reader)
            DispatchQueue.main.async { previewURL = url }
        }
    }
}

/// Copies one file to a private temporary folder so Quick Look can show it.
enum QuickLookExport {
    static func export(_ file: RecoverableFile, reader: BlockReader) -> URL? {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Preview", isDirectory: true)
            .appendingPathComponent(file.id.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        var flat = file
        flat.originalPath = file.name
        guard let report = try? PhotoRestore.save([flat], from: reader, to: base) else { return nil }
        return report.saved.first?.url
    }
}

struct SessionSidebar: View {
    @Bindable var session: RecoverySession

    private enum Filter: Hashable {
        case all
        case category(FileCategory)
    }

    private var filter: Binding<Filter?> {
        Binding(
            get: { session.category.map(Filter.category) ?? .all },
            set: { value in
                if case .category(let category) = value {
                    session.category = category
                } else {
                    session.category = nil
                }
            }
        )
    }

    var body: some View {
        List(selection: filter) {
            Section {
                SourceHeader(session: session)
                    .listRowSeparator(.hidden)
            }
            Section("Show") {
                row(nil, title: "Everything", symbol: "square.grid.2x2", count: session.files.count)
                ForEach(FileCategory.allCases.filter { (session.counts[$0] ?? 0) > 0 }) { category in
                    row(category, title: category.title, symbol: category.symbol, count: session.counts[category] ?? 0)
                }
            }
            if !session.warnings.isEmpty {
                Section("Notes") {
                    ForEach(session.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ category: FileCategory?, title: String, symbol: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(category.map(Filter.category) ?? .all)
    }
}

private struct SourceHeader: View {
    let session: RecoverySession

    var body: some View {
        HStack(spacing: 10) {
            DeviceGlyph(kind: session.device?.kind ?? .diskImage, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.device?.detail ?? "Disk image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ScanStatusBar: View {
    let session: RecoverySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.headline)
                Spacer()
                if let remaining = session.secondsRemaining {
                    Text(Self.remainingText(remaining))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Stop") { session.stop() }
                    .help("Stop searching. You can still recover everything found so far.")
            }
            if let fraction = session.progress.fraction {
                ProgressView(value: fraction)
                    .tint(Brand.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Brand.accent)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var headline: String {
        switch session.progress.phase {
        case .fileRecords: return "Reading the file list…"
        case .contents:
            let percent = Int(((session.progress.fraction ?? 0) * 100).rounded())
            return "Searching every part of the disk · \(percent)%"
        case .finished: return "Finishing…"
        }
    }

    private var detail: String {
        if session.progress.phase == .contents {
            return "\(ByteText.string(session.progress.bytesDone)) of \(ByteText.string(session.progress.bytesTotal)) checked. You can recover files while this runs, or stop at any time."
        }
        return "Deleted files that still have their names show up first."
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute left" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return "About \(formatter.string(from: seconds) ?? "") left"
    }
}

struct RecoverBar: View {
    let session: RecoverySession
    let recover: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.callout.weight(.medium))
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !session.selection.isEmpty {
                Button("Clear Selection") { session.selectNone() }
            }
            Button(action: recover) {
                Text(buttonTitle)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session.recoverTargets.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var targets: [RecoverableFile] { session.recoverTargets }

    private var summary: String {
        let size = ByteText.string(targets.reduce(0) { $0 + $1.size })
        if session.selection.isEmpty {
            return "\(session.visibleCount.formatted()) showing · \(size)"
        }
        return "\(session.selection.count.formatted()) selected · \(size)"
    }

    private var hint: String {
        session.selection.isEmpty
            ? "Click files to choose some, or recover everything showing."
            : "Double-click a file or press Space to preview it."
    }

    private var buttonTitle: String {
        let count = targets.count
        if session.selection.isEmpty {
            return count == 1 ? "Recover 1 File…" : "Recover All \(count.formatted())…"
        }
        return count == 1 ? "Recover 1 File…" : "Recover \(count.formatted()) Files…"
    }
}

struct EmptyResults: View {
    let session: RecoverySession

    var body: some View {
        VStack(spacing: 14) {
            if session.isScanning {
                ProgressView()
                    .controlSize(.large)
                Text("Looking for deleted files…")
                    .font(Brand.title(20))
                Text("They'll appear here as soon as they're found.")
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = session.state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(Brand.caution)
                Text("The scan couldn't finish")
                    .font(Brand.title(20))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            } else if !session.files.isEmpty {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Nothing matches")
                    .font(Brand.title(20))
                Text("Try another category or clear the search.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No deleted files were found")
                    .font(Brand.title(20))
                VStack(alignment: .leading, spacing: 8) {
                    reason("New photos or files may have been saved over them.")
                    reason("Some cameras wipe the card completely when they format it.")
                    reason("Fast SSDs erase deleted data automatically, so they rarely have anything left.")
                }
                .frame(maxWidth: 460)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reason(_ text: String) -> some View {
        Label(text, systemImage: "circle.fill")
            .labelStyle(BulletLabelStyle())
            .foregroundStyle(.secondary)
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension FileCategory {
    var title: String {
        switch self {
        case .photo: return "Photos"
        case .raw: return "RAW Photos"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .other: return "Other Files"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .raw: return "camera.aperture"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }
}
