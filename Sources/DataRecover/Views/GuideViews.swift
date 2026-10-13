import SwiftUI

/// Honest answer for files deleted from the Mac's own drive, which no app can scan for.
struct MacGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deleted from this Mac?")
                    .font(Brand.title(24))
                Text("Your Mac's own drive erases deleted files within minutes, and it's always encrypted. That means no app — free or paid — can scan it and get them back, whatever the ads say. These places often still have a copy:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                GuideRow(symbol: "trash", title: "The Trash", detail: "Files stay there until it's emptied.", action: "Open Trash") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
                Divider()
                GuideRow(symbol: "photo.on.rectangle", title: "Photos › Recently Deleted", detail: "Photos and videos are kept for 30 days.", action: "Open Photos") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                Divider()
                GuideRow(symbol: "icloud", title: "iCloud Drive › Recently Deleted", detail: "Kept for 30 days on iCloud.com.", action: "Open iCloud.com") {
                    openURL(URL(string: "https://www.icloud.com/iclouddrive/")!)
                }
                Divider()
                GuideRow(symbol: "clock.arrow.circlepath", title: "Time Machine", detail: "If you back up, older versions are there.", action: "Open Time Machine") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.backup.launcher") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                Divider()
                GuideRow(symbol: "doc.badge.clock", title: "The app you made it in", detail: "Pages, Word and others keep versions: File › Revert To › Browse All Versions.", action: nil) {}
                Divider()
                GuideRow(symbol: "cloud", title: "Dropbox, Google Drive, OneDrive", detail: "Their websites keep deleted files for at least 30 days.", action: nil) {}
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            Label("Ever copied them to a memory card, USB stick or external drive? Plug that in and scan it instead — those can usually be recovered.", systemImage: "lightbulb")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct GuideRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action, action: perform)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Shown when macOS privacy settings block reading the disk.
struct PrivacyHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(Brand.accent)
            Text("Let \(Brand.name) read the disk")
                .font(Brand.title(22))
            Text("macOS keeps apps away from memory cards and drives until you allow it. This is a one-time step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click Open Settings below. It opens Privacy & Security › Full Disk Access.")
                step(2, "Turn on \(Brand.name). If it isn't listed, click +, then choose it in Applications.")
                step(3, "Come back here and click the disk again.")
            }
            Text("\(Brand.name) still only reads the disk. It has no internet access and never changes or uploads your files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Settings") {
                    DiskAccess.openPrivacySettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Brand.accent))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
