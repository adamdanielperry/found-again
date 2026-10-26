import DataRecoverCore
import SwiftUI

/// Choose where files go, copy them, then show the result. The tip request only ever appears here, after it worked.
struct RecoverSheet: View {
    @Bindable var job: RecoveryJob
    let device: Device?
    /// Called with true when the person asked to eject the disk.
    let close: (Bool) -> Void

    var body: some View {
        Group {
            switch job.state {
            case .ready: ready
            case .running: running
            case .done(let report): done(report)
            case .failed(let message): failed(message)
            }
        }
        .frame(width: 520)
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.files.count == 1 ? "Recover “\(job.files[0].name)”" : "Recover \(job.files.count.formatted()) files")
                    .font(Brand.title(22))
                    .lineLimit(2)
                Text("\(ByteText.string(job.totalBytes)) will be copied to this Mac. The disk itself isn't changed.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Save to")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Brand.accent)
                    Text(Self.display(job.destination))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") { job.chooseDestination() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                if let problem = job.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Brand.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if job.hasFolders {
                    Toggle("Keep the folders the files were in", isOn: $job.keepFolders)
                        .padding(.top, 4)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Recover") { job.start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!job.canStart)
            }
        }
        .padding(24)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recovering…")
                .font(Brand.title(22))
            ProgressView(value: job.fraction)
                .tint(Brand.accent)
            Text(job.currentName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Stop") { job.stop() }
            }
        }
        .padding(24)
    }

    private func done(_ report: RestoreReport) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Brand.good)
                    .symbolEffect(.bounce, value: report.saved.count)
                Text(headline(report))
                    .font(Brand.title(24))
                    .multilineTextAlignment(.center)
                Text("Saved in “\(job.destination.lastPathComponent)”")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !report.failed.isEmpty || report.saved.contains(where: { $0.unreadableBytes > 0 }) {
                    Text("Some files couldn't be fully read. “About these files.txt” in the folder lists them.")
                        .font(.callout)
                        .foregroundStyle(Brand.caution)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    job.reveal()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
                .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 22)

            if !report.saved.isEmpty {
                DonationCard()
                    .padding(.horizontal, 20)
            }

            HStack {
                if let device {
                    Button("Eject “\(device.name)”") { close(true) }
                }
                Spacer()
                Button("Done") { close(false) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recovery didn't finish", systemImage: "exclamationmark.triangle.fill")
                .font(Brand.title(20))
                .foregroundStyle(Brand.caution)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Folder") { job.reveal() }
                Spacer()
                Button("Close") { close(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func headline(_ report: RestoreReport) -> String {
        let saved = report.saved.count
        if report.failed.isEmpty {
            return saved == 1 ? "Your file is back" : "\(saved.formatted()) files are back"
        }
        return "\(saved.formatted()) of \(job.files.count.formatted()) files recovered"
    }

    static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The only place the app asks for money: after files came back.
struct DonationCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Brand.accentSoft).frame(width: 44, height: 44)
                Image(systemName: "heart.fill")
                    .foregroundStyle(Brand.marigold)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Did \(Brand.name) help?")
                    .font(.headline)
                Text("It's free — no trial, no limits, no account. If it got your files back, a small tip keeps it that way for the next person.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        openURL(Brand.donate)
                    } label: {
                        Label("Leave a Tip", systemImage: "cup.and.saucer")
                    }
                    ShareLink(item: Brand.website, subject: Text(Brand.name), message: Text("\(Brand.name) got my deleted photos back for free:")) {
                        Label("Tell a Friend", systemImage: "square.and.arrow.up")
                    }
                }
                .padding(.top, 4)
                Button("Tell us what you got back") {
                    openURL(Brand.story)
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accentSoft.opacity(0.6)))
    }
}
