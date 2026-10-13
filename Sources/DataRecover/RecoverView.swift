import AppKit
import DataRecoverCore
import SwiftUI

struct RecoverView: View {
    @StateObject private var model = RecoverModel()

    private let columns = [GridItem(.adaptive(minimum: 156, maximum: 210), spacing: 18)]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 332, max: 400)
        } detail: {
            stage
                .navigationTitle("Recover Photos")
                .toolbar { detailToolbar }
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("Couldn't continue", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorText ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                wordmark
                cardBlock
                folderBlock
                optionBlock
                scanBlock
                Spacer(minLength: 12)
                Text("The card is only read. Photos are copied into the folder you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var wordmark: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recover")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            Text("Deleted photos, back on this Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var cardBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Card", trailing: {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look for a card again")
                .disabled(model.busy)
            })

            if let imageURL = model.imageURL {
                plate {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive")
                            .font(.title3)
                            .foregroundStyle(FilmColor.copper)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(imageURL.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            Text(imageURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Button("Use the card instead") { model.clearImage() }
                    .buttonStyle(.link)
                    .disabled(model.busy)
            } else if model.cards.isEmpty {
                plate {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No card inserted")
                            .font(.headline)
                        Text("Put the SD card in the reader, then refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                plate {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.cards.count > 1 {
                            Picker("Card", selection: $model.selectedCardID) {
                                ForEach(model.cards) { card in
                                    Text(card.name).tag(Optional(card.id))
                                }
                            }
                            .labelsHidden()
                            .disabled(model.busy)
                        } else {
                            Text(model.sourceTitle)
                                .font(.headline)
                        }
                        Text(model.sourceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button("Open a disk image…") { model.chooseImage() }
                .buttonStyle(.link)
                .disabled(model.busy)
        }
    }

    private var folderBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Save to")
            plate {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(FilmColor.copper)
                    Text(display(model.folder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Choose") { model.chooseFolder() }
                        .disabled(model.busy)
                }
            }
        }
    }

    private var optionBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Photos and videos only", isOn: $model.photosOnly)
                .disabled(model.busy)
            Toggle("Search the whole card even when names are found", isOn: $model.deepScan)
                .disabled(model.busy)
            if model.deepScan {
                Text(deepScanNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deepScanNote: String {
        if let card = model.selectedCard, model.imageURL == nil {
            return "This reads all \(ByteText.string(card.size)). Photos appear as they are found."
        }
        return "This reads the whole card. Photos appear as they are found."
    }

    private var scanBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.scan()
            } label: {
                Text(model.imageURL == nil ? "Look for photos" : "Look in this image")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(FilmColor.copper)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy || (model.imageURL == nil && model.selectedCard == nil))

            if model.busy || !model.status.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if model.busy {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                                .tint(FilmColor.copper)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if model.busy {
                            Button("Cancel") { model.cancel() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            stageBody
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private var stageBody: some View {
        if model.needsDiskAccess {
            stageMessage(
                symbol: "lock.rectangle.stack",
                title: "macOS is hiding the card",
                message: "Allow Recover Photos in Full Disk Access, then look for photos again. In that settings window, click + and choose this app."
            ) {
                Button("Allow card access") { model.allowDiskAccess() }
                    .buttonStyle(.borderedProminent)
                    .tint(FilmColor.copper)
            }
        } else if model.files.isEmpty {
            stageMessage(
                symbol: model.didScan ? "photo.on.rectangle.angled" : "sdcard",
                title: emptyTitle,
                message: emptyMessage
            ) {
                if model.didScan && !model.deepScan {
                    Button("Search the whole card") {
                        model.deepScan = true
                        model.scan()
                    }
                    .disabled(model.busy)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.files) { file in
                        PhotoTile(
                            file: file,
                            image: model.thumbs[file.id],
                            selected: model.selection.contains(file.id)
                        ) {
                            if model.selection.contains(file.id) {
                                model.selection.remove(file.id)
                            } else {
                                model.selection.insert(file.id)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var emptyTitle: String {
        if model.didScan { return "Nothing left to recover" }
        if model.selectedCard != nil || model.imageURL != nil { return "Ready to look" }
        return "Insert a card"
    }

    private var emptyMessage: String {
        if model.didScan {
            if let warning = model.warnings.first, !warning.isEmpty {
                return warning
            }
            return "The card was read. Photos whose space has already been reused will not come back."
        }
        if let card = model.selectedCard, model.imageURL == nil {
            return "Look for deleted photos on \(card.name). They show up here as a contact sheet. The card is not changed."
        }
        return "Put the SD card in the reader. Deleted pictures are copied into a folder on this Mac."
    }

    private func stageMessage<Actions: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(FilmColor.copper)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionSummary)
                    .font(.callout.weight(.medium))
                if let saved = model.savedMessage {
                    Button(saved) { model.revealFolder() }
                        .buttonStyle(.link)
                        .help("Show the folder in Finder")
                }
            }
            Spacer()
            Button("Save All") { model.saveAll() }
                .disabled(model.busy || model.files.isEmpty)
            Button("Save Selected") { model.saveSelected() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(FilmColor.copper)
                .disabled(model.busy || model.selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var selectionSummary: String {
        if model.files.isEmpty {
            if model.didScan { return "No photos" }
            if model.selectedCard != nil || model.imageURL != nil { return "No photos yet" }
            return "No card inserted"
        }
        let count = model.files.count
        let selected = model.selection.count
        let noun = count == 1 ? "photo" : "photos"
        if selected == 0 {
            return "\(count) \(noun)"
        }
        return "\(selected) of \(count) selected · \(ByteText.string(model.selectedByteCount))"
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.files.isEmpty {
                Button(model.selection.count == model.files.count ? "Select None" : "Select All") {
                    if model.selection.count == model.files.count {
                        model.selection = []
                    } else {
                        model.selection = Set(model.files.map(\.id))
                    }
                }
                .disabled(model.busy)
            }
            if model.savedMessage != nil {
                Button("Show in Finder") { model.revealFolder() }
            }
        }
    }

    private func sectionLabel<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            trailing()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        sectionLabel(title) { EmptyView() }
    }

    private func plate<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    private func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}

private struct PhotoTile: View {
    let file: RecoverableFile
    let image: NSImage?
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    thumb
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selected ? FilmColor.copper : Color.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: selected ? 3 : 1)
                        )
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.9), FilmColor.copper)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        Spacer()
                        if file.headerLooksValid == false || !file.complete {
                            Text(file.headerLooksValid == false ? "Damaged" : "Partial")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.62), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(file.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var thumb: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: file.kind == .movie ? "film" : "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        var parts = [ByteText.string(file.size)]
        if let modified = file.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}

private enum FilmColor {
    static var copper: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return dark
                ? NSColor(srgbRed: 0.90, green: 0.50, blue: 0.30, alpha: 1)
                : NSColor(srgbRed: 0.68, green: 0.30, blue: 0.14, alpha: 1)
        })
    }
}
