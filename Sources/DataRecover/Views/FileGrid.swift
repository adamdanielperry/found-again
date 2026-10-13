import DataRecoverCore
import SwiftUI

struct FileGrid: View {
    let session: RecoverySession
    let tileSize: Double
    let preview: (RecoverableFile) -> Void
    let recover: (RecoverableFile) -> Void

    @State private var lastClicked: RecoverableFile?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 14, alignment: .top)],
                alignment: .leading,
                spacing: 18,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(session.sections) { section in
                    Section {
                        ForEach(section.files) { file in
                            Button {
                                session.toggle(file)
                                lastClicked = file
                                focused = true
                            } label: {
                                FileTile(
                                    file: file,
                                    thumbnails: session.thumbnails,
                                    selected: session.selection.contains(file.id),
                                    recovered: session.recoveredIDs.contains(file.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { preview(file) })
                            .accessibilityAction(named: "Quick Look") { preview(file) }
                            .contextMenu {
                                Button("Quick Look") { preview(file) }
                                Button(session.selection.contains(file.id) ? "Deselect" : "Select") { session.toggle(file) }
                                Divider()
                                Button("Recover This File…") { recover(file) }
                            }
                        }
                    } header: {
                        if !section.title.isEmpty {
                            SectionHeader(section: section, session: session)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let file = lastClicked else { return .ignored }
            preview(file)
            return .handled
        }
    }
}

private struct SectionHeader: View {
    let section: RecoverySession.Section
    let session: RecoverySession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(.headline)
            Text("\(section.files.count.formatted())")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "Deselect" : "Select") {
                let ids = section.files.map(\.id)
                if allSelected {
                    session.selection.subtract(ids)
                } else {
                    session.selection.formUnion(ids)
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.92))
    }

    private var allSelected: Bool {
        section.files.allSatisfy { session.selection.contains($0.id) }
    }
}

struct FileTile: View {
    let file: RecoverableFile
    let thumbnails: ThumbnailCache
    let selected: Bool
    var recovered = false

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                picture
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Brand.accent : Color.primary.opacity(hovering ? 0.22 : 0.08), lineWidth: selected ? 3 : 1)
                    )
                HStack(alignment: .top) {
                    if selected || hovering {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .medium))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Brand.accent : Color.black.opacity(0.35))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .transition(.opacity)
                    }
                    Spacer()
                    if recovered {
                        Label("Recovered", systemImage: "checkmark")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Brand.good))
                            .foregroundStyle(.white)
                    } else if file.quality != .good {
                        QualityBadge(quality: file.quality)
                    }
                }
                .padding(7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .task(id: file.id) {
            if let cached = thumbnails.cached(file) {
                image = cached
                return
            }
            image = await thumbnails.image(for: file)
        }
        .help(file.originalPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.name), \(caption)\(file.quality == .good ? "" : ", \(file.quality.rawValue)")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var picture: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 6) {
                    Image(nsImage: ThumbnailCache.icon(for: file))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                    Text(FileTyping.extensionOf(file.name).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var caption: String {
        var parts = [ByteText.string(file.size)]
        if let modified = file.modified {
            parts.append(modified.formatted(date: .omitted, time: .shortened))
        }
        if let device = file.device {
            parts.append(device)
        }
        return parts.joined(separator: " · ")
    }
}

struct QualityBadge: View {
    let quality: RecoverableFile.Quality

    var body: some View {
        Text(quality == .damaged ? "Damaged" : "Partial")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.65)))
            .foregroundStyle(quality == .damaged ? Color(red: 1, green: 0.55, blue: 0.5) : Color(red: 1, green: 0.85, blue: 0.45))
            .help(quality == .damaged
                ? "The start of this file has been overwritten. It probably won't open."
                : "Part of this file couldn't be traced. It may open with missing sections.")
    }
}
