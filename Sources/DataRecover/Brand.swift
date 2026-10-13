import AppKit
import SwiftUI

/// Everything that changes with the product's name and look lives here.
enum Brand {
    static let name = "Found Again"
    static let domain = "foundagain.app"
    static let tagline = "Lost photos, found again. Free."
    static let website = URL(string: "https://\(domain)")!
    static let donate = URL(string: "https://\(domain)/thanks")!
    static let help = URL(string: "https://\(domain)/help")!
    static let support = URL(string: "mailto:hello@\(domain)")!
    static var updates: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return URL(string: "https://\(domain)/download?from=\(version)")!
    }
    /// Default parent folder for recovered files, inside ~/Pictures or ~/Documents.
    static let recoveredFolderName = "Found Again"

    /// Ink navy for anything you click. In dark mode it lifts to a mid blue that still carries white button labels.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.30, green: 0.48, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.118, green: 0.208, blue: 0.341, alpha: 1)
    })

    /// The marigold of the luggage tag, as a wash behind icons and highlights.
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 0.18)
            : NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 0.28)
    })

    /// The home screen's ground: warm paper in light mode, deep navy in dark, matching the website.
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.059, green: 0.102, blue: 0.169, alpha: 1)
            : NSColor(srgbRed: 0.969, green: 0.953, blue: 0.918, alpha: 1)
    })

    /// Cards that sit on `paper`.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.090, green: 0.165, blue: 0.267, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.992, blue: 0.973, alpha: 1)
    })

    /// Marigold itself, for small marks that should feel like the brand rather than a control.
    static let marigold = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.55, blue: 0.08, alpha: 1)
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

    /// Apple's New York serif, the closest system face to the website's Young Serif.
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
    }
}
