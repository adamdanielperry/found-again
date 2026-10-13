import DataRecoverCore
import SwiftUI

/// First screen: pick the card or drive the files were on.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    devices
                    otherPlaces
                    Spacer(minLength: 12)
                    promise
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: 860, minHeight: geometry.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where were the files?")
                .font(Brand.title(30))
            Text("Choose the memory card or drive they were deleted from. \(Brand.name) only reads it — nothing on it is changed.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var devices: some View {
        if model.devices.isEmpty {
            EmptyDeviceCard(loading: !model.loadedDevices)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(model.devices) { device in
                    DeviceCard(device: device, opening: model.opening == device.id, disabled: model.opening != nil) {
                        model.open(device)
                    } saveCopy: {
                        model.saveCopy(of: device)
                    }
                }
            }
        }
    }

    private var otherPlaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Something else?")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                PlaceButton(symbol: "laptopcomputer", title: "Deleted from this Mac", detail: "Where to look instead") {
                    model.showMacGuide = true
                }
                PlaceButton(symbol: "opticaldiscdrive", title: "Open a disk image", detail: ".dmg, .img, .iso or .dd") {
                    model.chooseImage()
                }
            }
        }
    }

    private var promise: some View {
        HStack(spacing: 18) {
            Label("Read-only", systemImage: "lock")
            Label("Nothing leaves your Mac", systemImage: "wifi.slash")
            Label("Free, with no limits", systemImage: "gift")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(PromiseLabelStyle())
    }
}

private struct PromiseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Brand.accent)
            configuration.title
        }
    }
}

struct DeviceCard: View {
    let device: Device
    let opening: Bool
    let disabled: Bool
    let action: () -> Void
    let saveCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        card
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    Button("Scan for Deleted Files", action: action)
                    Button("Save a Copy of This Disk…", action: saveCopy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(14)
                .disabled(disabled)
                .help("More options")
            }
            .contextMenu {
                Button("Scan for Deleted Files", action: action)
                Button("Save a Copy of This Disk…", action: saveCopy)
            }
    }

    private var card: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    DeviceGlyph(kind: device.kind, size: 52)
                    Spacer()
                    if device.camera != nil {
                        Pill(text: "Camera card", tint: Brand.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(device.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    if opening {
                        ProgressView().controlSize(.small)
                        Text("Waiting for permission…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scan")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Brand.accent)
                        Image(systemName: "arrow.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Brand.accent)
                            .offset(x: hovering ? 3 : 0)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 12 : 4, y: hovering ? 4 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hovering ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: hovering ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside && !disabled }
        }
        .accessibilityLabel("Scan \(device.name), \(device.detail)")
    }
}

/// Shown until a card or drive is plugged in. Updates on its own.
struct EmptyDeviceCard: View {
    let loading: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Brand.accentSoft)
                    .frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.08 : 0.94)
                Image(systemName: "sdcard")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Brand.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(loading ? "Looking for disks…" : "Insert a memory card or plug in a drive")
                    .font(.title3.weight(.semibold))
                Text("It appears here by itself. Use a card reader rather than connecting the camera with a cable.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Until your files are back, don't take new photos on the card or copy anything onto the drive.")
                    .font(.callout)
                    .foregroundStyle(Brand.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(Color.primary.opacity(0.18))
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct PlaceButton: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Brand.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Brand.accentSoft : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DeviceGlyph: View {
    let kind: Device.Kind
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Brand.accentSoft)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(Brand.accent)
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch kind {
        case .memoryCard: return "sdcard"
        case .usbDrive: return "mediastick"
        case .externalDrive: return "externaldrive"
        case .diskImage: return "opticaldiscdrive"
        }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}
