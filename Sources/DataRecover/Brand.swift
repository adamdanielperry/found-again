import AppKit
import SwiftUI

/// Everything that changes with the product's name and look lives here.
enum Brand {
    static let name = "Unerase"
    static let domain = "unerase.app"
    static let tagline = "Get deleted photos and files back. Free."
    static let website = URL(string: "https://\(domain)")!
    static let donate = URL(string: "https://\(domain)/thanks")!
    static let help = URL(string: "https://\(domain)/help")!
    static let support = URL(string: "mailto:hello@\(domain)")!
    static var updates: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return URL(string: "https://\(domain)/download?from=\(version)")!
    }
    /// Default parent folder for recovered files, inside ~/Pictures or ~/Documents.
    static let recoveredFolderName = "Recovered with Unerase"

    /// Warm coral. Reads as hopeful rather than alarming, and holds contrast in both appearances.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.55, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.83, green: 0.33, blue: 0.18, alpha: 1)
    })

    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.55, blue: 0.40, alpha: 0.16)
            : NSColor(srgbRed: 0.83, green: 0.33, blue: 0.18, alpha: 0.10)
    })

    static let good = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.55, blue: 0.27, alpha: 1)
    })

    static let caution = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.80, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.45, blue: 0.00, alpha: 1)
    })

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
    }
}
