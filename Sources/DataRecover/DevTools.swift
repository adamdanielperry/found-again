import AppKit
import DataRecoverCore
import Foundation

/// Developer commands that exercise the app's own code paths without the window.
///   FoundAgain --render-thumbnails <disk image> <output folder>
enum DevTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot-window"), index + 1 < args.count {
            let image = args.firstIndex(of: "--image").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let select = args.firstIndex(of: "--select").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
            MainActor.assumeIsolated {
                snapshotWindow(to: URL(fileURLWithPath: args[index + 1]), image: image, select: select)
            }
            return
        }
        guard let index = args.firstIndex(of: "--render-thumbnails"), index + 2 < args.count else { return }
        let image = args[index + 1]
        let output = URL(fileURLWithPath: args[index + 2], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let reader = try FileBlockReader(path: image)
            let result = try RecoveryEngine.scan(reader: reader, options: ScanOptions(deepScan: true))
            let cache = ThumbnailCache(reader: reader)
            let group = DispatchGroup()
            for file in result.files {
                group.enter()
                Task.detached {
                    let rendered = await cache.image(for: file)
                    if let rendered, let tiff = rendered.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let name = OutputPath.sanitize(file.name) + ".png"
                        try? png.write(to: output.appendingPathComponent(name))
                        print("thumbnail  \(file.name)  \(Int(rendered.size.width))x\(Int(rendered.size.height))")
                    } else {
                        print("no picture \(file.name) (\(file.kind.rawValue))")
                    }
                    group.leave()
                }
            }
            group.wait()
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Draws the main window offscreen and saves it as a PNG, for screenshots that don't need screen access.
    ///   FoundAgain --snapshot-window <out.png> [--image <disk image>] [--select <count>]
    @MainActor
    private static func snapshotWindow(to output: URL, image: String?, select: Int) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        if let image {
            model.open(image: URL(fileURLWithPath: image))
        }
        let host = NSHostingView(rootView: RootView().environment(model).frame(width: 1120, height: 760))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Brand.name
        window.contentView = host
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let session = model.session, select > 0 {
                for file in session.visibleFiles.filter({ $0.category == .photo }).prefix(select) {
                    session.toggle(file)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let frame = window.contentView?.superview ?? host
                guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                print("saved \(output.path)")
                exit(0)
            }
        }
        app.run()
    }
}

import SwiftUI
