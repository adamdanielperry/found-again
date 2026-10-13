import AppKit
import DataRecoverCore
import Foundation

/// Developer commands that exercise the app's own code paths without the window.
///   Unerase --render-thumbnails <disk image> <output folder>
enum DevTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
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
}
