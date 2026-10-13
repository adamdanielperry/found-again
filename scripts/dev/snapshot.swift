// Renders a web page offscreen with WebKit and saves a full-length PNG. Needs no screen access.
//   swift scripts/dev/snapshot.swift <url> <output.png> [width] [dark]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]) else {
    print("usage: snapshot.swift <url> <output.png> [width] [dark]")
    exit(2)
}
let output = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3]) ?? 1280 : 1280
let dark = args.count > 4 && args[4] == "dark"

final class Snapper: NSObject, WKNavigationDelegate {
    let view: WKWebView
    init(width: Double, dark: Bool) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        super.init()
        view.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
                let height = min((value as? Double) ?? 900, 12000)
                webView.frame.size.height = height
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let config = WKSnapshotConfiguration()
                    config.rect = NSRect(x: 0, y: 0, width: webView.frame.width, height: height)
                    webView.takeSnapshot(with: config) { image, error in
                        guard let image, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                            print("snapshot failed: \(error?.localizedDescription ?? "unknown")")
                            exit(1)
                        }
                        try? png.write(to: output)
                        print("saved \(output.path) (\(Int(webView.frame.width))x\(Int(height)))")
                        exit(0)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("load failed: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let snapper = Snapper(width: width, dark: dark)
let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = snapper.view
window.orderBack(nil)
snapper.view.load(URLRequest(url: url))
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timed out"); exit(1) }
app.run()
