import Darwin
import DataRecoverCore
import Foundation
import SwiftUI

@main
enum AppLaunch {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "worker" {
            WorkerCLI.main(Array(args.dropFirst()))
            return
        }
        if args.first == "recover" {
            RecoverCommand.main()
            return
        }
        if args.first == "list-cards" {
            do {
                let cards = try DiskCatalog.cards()
                if cards.isEmpty {
                    print("No memory card found.")
                }
                for card in cards {
                    print("\(card.id)\t\(card.name)\t\(card.summary)")
                }
            } catch {
                fputs((error.localizedDescription) + "\n", stderr)
                exit(1)
            }
            return
        }
        RecoverApp.main()
    }
}

enum RecoverCommand {
    static func main() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Recovered Photos", isDirectory: true)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("datarecover-named", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let names: Set<String> = ["DSCF0003.JPG", "DSCF0004.JPG", "DSCF0005.JPG", "DSCF0007.JPG"]
        let card = (try? DiskCatalog.cards().first { $0.isCamera }) ?? (try? DiskCatalog.cards().first)
        guard let card else {
            fputs("No memory card found. Insert the SD card and try again.\n", stderr)
            exit(1)
        }
        let job = WorkerJob(
            action: "recover",
            device: card.id,
            image: nil,
            manifest: work.appendingPathComponent("manifest.json").path,
            previews: work.appendingPathComponent("previews", isDirectory: true).path,
            output: folder.path,
            progress: work.appendingPathComponent("progress.json").path,
            cancel: work.appendingPathComponent("cancel").path,
            status: work.appendingPathComponent("status.json").path,
            uid: getuid(),
            gid: getgid(),
            deep: true,
            photosOnly: true,
            saveAll: true,
            ids: [],
            stopNames: names
        )
        do {
            try Admin.run(["worker"] + job.commandArguments())
            print("Saved the photos to \(folder.path)")
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
}

struct RecoverApp: App {
    var body: some Scene {
        WindowGroup {
            RecoverView()
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
    }
}
