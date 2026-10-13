import AppKit
import SwiftUI

@main
struct RecoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.openURL) private var openURL

    init() {
        DevTools.runIfRequested()
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 600)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)") { AboutPanel.show() }
                // No built-in updater: the app never connects to the internet by itself.
                Button("Check for Updates…") { openURL(Brand.updates) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Disk Image…") { model.chooseImage() }
                    .keyboardShortcut("o")
                    .disabled(model.session != nil)
            }
            CommandGroup(replacing: .help) {
                Button("\(Brand.name) Help") { openURL(Brand.help) }
                Button("Deleted from This Mac?") { model.showMacGuide = true }
                Divider()
                Button("Leave a Tip…") { openURL(Brand.donate) }
                Button("Send Feedback…") { openURL(Brand.support) }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let session = model.session {
                SessionView(session: session)
                    .id(session.id)
            } else {
                HomeView()
                    .navigationTitle(Brand.name)
            }
        }
        .sheet(isPresented: $model.showMacGuide) { MacGuideView() }
        .sheet(isPresented: $model.showPrivacyHelp) { PrivacyHelpView() }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Put the disk's volumes back so Finder shows it again.
        MainActor.assumeIsolated {
            model?.prepareToQuit()
        }
    }
}

enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(
            string: "Free recovery for deleted photos and files. No trial, no limits, no account.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: Brand.website.host() ?? "",
            attributes: [.link: Brand.website, .font: NSFont.systemFont(ofSize: 11)]
        ))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
