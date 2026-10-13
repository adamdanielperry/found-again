import DataRecoverCore
import SwiftUI

struct ImagingSheet: View {
    let job: ImagingJob
    let finish: (_ scan: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch job.state {
            case .running:
                Text("Copying “\(job.device.name)”")
                    .font(Brand.title(22))
                Text("Every part of the disk is copied into one file. Once that's done, you can scan the copy as often as you like without touching the disk again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: job.progress.fraction)
                    .tint(Brand.accent)
                HStack {
                    Text("\(ByteText.string(job.progress.bytesDone)) of \(ByteText.string(job.progress.bytesTotal))")
                        .monospacedDigit()
                    Spacer()
                    if let remaining = job.secondsRemaining {
                        Text(ScanStatusBar.remainingText(remaining))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if job.progress.unreadable > 0 {
                    Label("\(ByteText.string(job.progress.unreadable)) couldn't be read so far. The disk may be failing; the copy carries on around those parts.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Brand.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Stop") { job.stop() }
                }
            case .done(let result):
                Label("Copy saved", systemImage: "checkmark.circle.fill")
                    .font(Brand.title(22))
                    .foregroundStyle(Brand.good)
                Text("“\(job.destination.lastPathComponent)” holds everything that was on the disk. You can unplug the disk now.")
                    .fixedSize(horizontal: false, vertical: true)
                if result.unreadable > 0 {
                    Text("\(ByteText.string(result.unreadable)) couldn't be read and were filled with blanks. Files in those spots may be damaged.")
                        .font(.callout)
                        .foregroundStyle(Brand.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Show in Finder") { job.reveal() }
                    Spacer()
                    Button("Close") { finish(false) }
                    Button("Scan the Copy") { finish(true) }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.accent)
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("The copy didn't finish", systemImage: "exclamationmark.triangle.fill")
                    .font(Brand.title(20))
                    .foregroundStyle(Brand.caution)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { finish(false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }
}
