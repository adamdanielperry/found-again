import AVKit
import DataRecoverCore
import ImageIO
import SwiftUI

/// A large look at one found file, read straight off the disk. Photos are decoded at screen size; videos stream through AVFoundation.
struct PreviewSheet: View {
    let session: RecoverySession
    @State var file: RecoverableFile
    let recover: (RecoverableFile) -> Void
    let openElsewhere: (RecoverableFile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var picture: NSImage?
    @State private var player: AVPlayer?
    @State private var asset: DiskAsset?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else if loading {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    VStack(spacing: 12) {
                        Image(nsImage: ThumbnailCache.icon(for: file))
                            .resizable()
                            .frame(width: 96, height: 96)
                        Text("No preview for this kind of file")
                            .foregroundStyle(.white.opacity(0.8))
                        Button("Open with Quick Look") { openElsewhere(file) }
                    }
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            details
        }
        .frame(width: 900, height: 680)
        .task(id: file.id) { await load() }
        .onDisappear { player?.pause() }
        // Key presses only reach a focused view, so the sheet takes focus when it opens.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    @FocusState private var focused: Bool

    private var details: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if file.quality != .good {
                QualityBadge(quality: file.quality)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous file (←)")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help("Next file (→)")
            Button(session.selection.contains(file.id) ? "Deselect" : "Select") { session.toggle(file) }
            Button("Recover…") { recover(file) }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .background(.bar)
    }

    private var detail: String {
        var parts = [ByteText.string(file.size)]
        if let date = file.modified { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let device = file.device { parts.append(device) }
        if !file.folder.isEmpty { parts.append(file.folder) }
        return parts.joined(separator: " · ")
    }

    private func step(_ delta: Int) {
        let files = session.visibleFiles
        guard let index = files.firstIndex(of: file) else { return }
        let next = index + delta
        guard files.indices.contains(next) else { return }
        player?.pause()
        file = files[next]
    }

    private func load() async {
        loading = true
        picture = nil
        player = nil
        asset = nil
        let file = self.file
        let reader = session.reader
        if ThumbnailCache.isPlayableVideo(file), let diskAsset = DiskAsset(file: file, reader: reader) {
            asset = diskAsset
            let item = AVPlayerItem(asset: diskAsset.asset)
            player = AVPlayer(playerItem: item)
            loading = false
            return
        }
        guard file.kind.hasImagePreview else {
            loading = false
            return
        }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = Previews.imageData(for: file, reader: reader, maxBytes: 120 << 20),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        guard file.id == self.file.id else { return }
        picture = image
        loading = false
    }
}
